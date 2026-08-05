#!/usr/bin/env bash
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

note "Fetching the VM's notify pubkey"
VMKEY="$(
  gcloud_instance get-serial-port-output 2>/dev/null |
    grep -oE "ssh-ed25519 [A-Za-z0-9+/=]+ [^ ]*-notify-phone" | tail -1 || true
)"

if [[ -z "$VMKEY" ]]; then
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

printf '%s\n' "$VMKEY" >"$TMP/vm.pub"
ssh-keygen -lf "$TMP/vm.pub" >/dev/null 2>&1 ||
  die "refusing to install an unparsable pubkey: '$VMKEY'"
VM_FPR="$(ssh-keygen -lf "$TMP/vm.pub" | awk '{print $2}')"
note "VM notify key: $VM_FPR"

note "Installing ~/bin/notify-only"
phone 'mkdir -p ~/bin && cat > ~/bin/notify-only && chmod 700 ~/bin/notify-only' <<'PARSER'
#!/data/data/com.termux/files/usr/bin/python3
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

note "Ensuring sshd starts on boot"
phone 'rm -f "${PREFIX:-/data/data/com.termux/files/usr}/var/service/sshd/down"' 2>/dev/null || true
phone 'mkdir -p ~/.termux/boot && cat > ~/.termux/boot/start-sshd.sh && chmod 700 ~/.termux/boot/start-sshd.sh' <<'BOOT'
#!/data/data/com.termux/files/usr/bin/sh
termux-wake-lock
sshd
BOOT

if ! phone 'pm list packages 2>/dev/null | grep -q com.termux.boot'; then
  note "WARNING: the Termux:Boot app is not installed — sshd will NOT come back"
  note "         after a reboot. Install it from F-Droid, then open it once."
fi

note "Installing the hardened notify line"

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

ssh-keygen -lf "$AK" 2>/dev/null | grep -v -- '-notify-phone' |
  awk '{print $2}' | sort -u >"$HOME/.ssh/.keep.fpr" || true

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

PHONE_FPR="$(phone 'ssh-keygen -lf ~/.ssh/authorized_keys' | grep -- '-notify-phone' | awk '{print $2}')"
[[ "$PHONE_FPR" == "$VM_FPR" ]] ||
  die "mismatch: phone trusts '$PHONE_FPR' but the VM holds '$VM_FPR'"

note "Phone provisioned. Trusted notify key matches the VM: $VM_FPR"
note "Verify end-to-end with: ./verify.sh"
