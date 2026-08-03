#!/usr/bin/env bash
#
# provision-phone.sh — put the phone into the exact state notify-phone needs.
#
# Run this after every `terraform apply`. It is idempotent: re-running it is a
# no-op when the phone is already correct.
#
# What it does:
#   1. Installs the forced-command parser at ~/bin/notify-only (Pattern B).
#   2. Makes Termux's sshd survive a reboot (clears runit's 'down' file, installs
#      a Termux:Boot script).
#   3. Re-keys ~/.ssh/authorized_keys: drops any stale *-notify-phone key and
#      installs the VM's CURRENT pubkey behind restrict,command=.
#
# Why this exists: a full teardown destroys the data disk, so the VM generates a
# NEW notify keypair on rebuild and the phone's pinned line goes stale. That
# failure looks like `Permission denied (publickey)` from notify-phone.
#
# Safety properties (learned the hard way):
#   - The VM pubkey is validated by ssh-keygen before use, so an empty or
#     truncated value can never be written as a malformed authorized_keys line.
#   - Only keys whose comment ends in `-notify-phone` are removed. Your laptop
#     key is never touched.
#   - authorized_keys is backed up, then re-validated; if any pre-existing key
#     would be lost or the file no longer parses, it is rolled back.
#
# Usage:
#   ./provision-phone.sh
#
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_config
load_phone_config

[[ -n "$PHONE_HOST" ]] || die "termux_host unknown: set TF_VAR_termux_host in config.env (or run terraform apply first so 'terraform output' works)"
[[ -n "$PHONE_USER" ]] || die "termux_ssh_user unknown: set TF_VAR_termux_ssh_user in config.env"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

phone() { ssh_phone "$@"; }

# --- 0. Preflight -------------------------------------------------------
note "phone=$PHONE_USER@$PHONE_HOST:$PHONE_PORT instance=$INSTANCE"

if ! phone true 2>/dev/null; then
  cat >&2 <<EOF
ERROR: cannot SSH to the phone at $PHONE_USER@$PHONE_HOST:$PHONE_PORT

  Connection refused  -> sshd is not running. In Termux: sshd
  Timed out           -> phone not on the tailnet, or Termux was killed.
  Permission denied   -> your laptop key is not in the phone's authorized_keys.
EOF
  exit 1
fi

# --- 1. Fetch the VM's current notify pubkey ----------------------------
# Serial console first: it needs no SSH to the VM, so it works even when
# Tailscale SSH is in check mode (which requires an interactive browser click).
# The startup script echoes the pubkey when it generates the keypair.
note "Fetching the VM's notify pubkey"
VMKEY="$(
  gcloud_instance get-serial-port-output 2>/dev/null |
    grep -oE "ssh-ed25519 [A-Za-z0-9+/=]+ [^ ]*-notify-phone" | tail -1 || true
)"

if [[ -z "$VMKEY" ]]; then
  # No key in the serial log: normal when the data disk (and its keypair)
  # survived the rebuild, since the script only echoes on generation.
  note "not in the serial log (disk likely persisted); reading it from the VM"
  VMKEY="$(
    ssh_vm 'cat /mnt/data/ssh-termux/id_ed25519.pub' 2>/dev/null |
      grep -E '^ssh-ed25519 ' || true
  )"
fi

[[ -n "$VMKEY" ]] || die "could not determine the VM's notify pubkey.
  Is the VM up and past step 8 of the startup script? Check:
    gcloud compute instances get-serial-port-output $INSTANCE --zone $ZONE | tail
  If Tailscale SSH is in check mode, complete the browser check once, then retry."

# Validate with the real parser, not a regex guess: this is what stops an empty
# or truncated value from being appended as a malformed line.
printf '%s\n' "$VMKEY" >"$TMP/vm.pub"
ssh-keygen -lf "$TMP/vm.pub" >/dev/null 2>&1 ||
  die "refusing to install an unparsable pubkey: '$VMKEY'"
VM_FPR="$(ssh-keygen -lf "$TMP/vm.pub" | awk '{print $2}')"
note "VM notify key: $VM_FPR"

# --- 2. Install the forced-command parser -------------------------------
note "Installing ~/bin/notify-only"
phone 'mkdir -p ~/bin && cat > ~/bin/notify-only && chmod 700 ~/bin/notify-only' <<'PARSER'
#!/data/data/com.termux/files/usr/bin/python3
# Forced-command target for the VM's notify key: may run ONLY
# termux-notification, but with ANY flags.
#
# sshd hands us the client's command as one string in SSH_ORIGINAL_COMMAND.
# shlex.split parses it WITHOUT a shell, so shell metacharacters in the message
# are inert data: `;` cannot chain, `$(...)` cannot substitute. execv then runs
# the binary directly, never through a shell.
import os
import shlex
import sys

BIN = "/data/data/com.termux/files/usr/bin/termux-notification"

raw = os.environ.get("SSH_ORIGINAL_COMMAND", "")
try:
    argv = shlex.split(raw)
except ValueError as e:
    sys.exit(f"refused: unbalanced quoting ({e})")
if not argv or argv[0] != "termux-notification":
    sys.exit("refused: this key may only run termux-notification")
os.execv(BIN, argv)
PARSER

# --- 3. Make sshd survive a reboot --------------------------------------
# Without this, notify-phone breaks silently the next time the phone reboots.
note "Ensuring sshd starts on boot"
phone 'rm -f "${PREFIX:-/data/data/com.termux/files/usr}/var/service/sshd/down"' 2>/dev/null || true
phone 'mkdir -p ~/.termux/boot && cat > ~/.termux/boot/start-sshd.sh && chmod 700 ~/.termux/boot/start-sshd.sh' <<'BOOT'
#!/data/data/com.termux/files/usr/bin/sh
# Run by Termux:Boot at device startup. Keeps sshd up so the VM can notify us.
termux-wake-lock
sshd
BOOT

if ! phone 'pm list packages 2>/dev/null | grep -q com.termux.boot'; then
  note "WARNING: the Termux:Boot app is not installed — sshd will NOT come back"
  note "         after a reboot. Install it from F-Droid, then open it once."
fi

# --- 4. Re-key authorized_keys (atomic, validated, self-rolling-back) ---
note "Installing the hardened notify line"

# The value must NOT be passed as an ssh argument: ssh joins argv with spaces
# and the remote shell re-parses the result, which both splits this line at its
# spaces and strips the quotes that `command="..."` requires. Instead, %q-escape
# it into a leading assignment so the remote bash sees one literal string (and
# `$HOME` stays unexpanded, for sshd to expand at auth time).
printf -v NEWLINE_Q '%q' "restrict,command=\"\$HOME/bin/notify-only\" $VMKEY"

{
  printf 'NEWLINE=%s\n' "$NEWLINE_Q"
  cat <<'REKEY'
set -eu
AK="$HOME/.ssh/authorized_keys"

mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
touch "$AK"
cp "$AK" "$AK.bak"

# Every key that is NOT a VM notify key must still be present afterwards.
ssh-keygen -lf "$AK" 2>/dev/null | grep -v -- '-notify-phone' |
  awk '{print $2}' | sort -u >"$HOME/.ssh/.keep.fpr" || true

# Drop stale notify keys (comment always ends in -notify-phone), add the new one.
grep -v -- '-notify-phone' "$AK" >"$AK.new" || true
printf '%s\n' "$NEWLINE" >>"$AK.new"
mv "$AK.new" "$AK"
chmod 600 "$AK"

rollback() {
  echo "FATAL: $1 — rolling back authorized_keys" >&2
  cp "$AK.bak" "$AK"
  chmod 600 "$AK"
  exit 1
}

ssh-keygen -lf "$AK" >/dev/null 2>&1 || rollback "authorized_keys no longer parses"
ssh-keygen -lf "$AK" | awk '{print $2}' | sort -u >"$HOME/.ssh/.now.fpr"
MISSING="$(comm -23 "$HOME/.ssh/.keep.fpr" "$HOME/.ssh/.now.fpr")"
[ -z "$MISSING" ] || rollback "would drop pre-existing key(s): $MISSING"
grep -q -- '-notify-phone' "$AK" || rollback "notify key was not installed"

rm -f "$HOME/.ssh/.keep.fpr" "$HOME/.ssh/.now.fpr"
echo "OK"
REKEY
} | phone 'bash -s'

# --- 5. Confirm the phone now trusts exactly this key -------------------
PHONE_FPR="$(phone 'ssh-keygen -lf ~/.ssh/authorized_keys' | grep -- '-notify-phone' | awk '{print $2}')"
[[ "$PHONE_FPR" == "$VM_FPR" ]] ||
  die "mismatch: phone trusts '$PHONE_FPR' but the VM holds '$VM_FPR'"

note "Phone provisioned. Trusted notify key matches the VM: $VM_FPR"
note "Verify end-to-end with: ./verify.sh"
