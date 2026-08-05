#!/usr/bin/env bash
set -uo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_config
load_phone_config

QUICK=false
[[ "${1:-}" == "--quick" ]] && QUICK=true

PASS=0
FAIL=0
ok() {
  printf '  \033[32mPASS\033[0m  %s\n' "$1"
  PASS=$((PASS + 1))
}
bad() {
  printf '  \033[31mFAIL\033[0m  %s\n' "$1"
  FAIL=$((FAIL + 1))
}
skip() { printf '  \033[33mSKIP\033[0m  %s\n' "$1"; }
assert() {
  if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi
}
section() { printf '\n\033[1m%s\033[0m\n' "$1"; }

fact() { # fact <blob> <key>
  printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -1
}

section "Cloud resources"
STATUS="$(instance_status)"
if [[ "$STATUS" == unknown ]]; then
  bad "cannot read instance $INSTANCE from gcloud (credential problem, not the VM)"
  printf '%s\n' "$(gcloud_identity_hint)"
else
  assert "instance $INSTANCE is RUNNING" "$STATUS" "RUNNING"
fi

RENDERED="$(gcloud_instance describe --format='value(metadata.items)' 2>/dev/null)"
if [[ -z "$RENDERED" ]]; then
  bad "could not read startup-script metadata"
elif printf '%s' "$RENDERED" | grep -q '\$\$'; then
  bad "deployed startup-script still contains '\$\$'"
else
  ok "deployed startup-script is free of '\$\$'"
fi

FW_ERR="$(mktemp)"
if FW_ALL="$(gcloud compute firewall-rules list --project "$PROJECT_ID" \
  --format='csv[no-heading](name,direction,disabled,sourceRanges.list())' 2>"$FW_ERR")"; then
  OPEN="$(printf '%s\n' "$FW_ALL" |
    awk -F, '$2=="INGRESS" && tolower($3)=="false" && /0\.0\.0\.0\/0/ {print $1}')"
  assert "no INGRESS rule allows 0.0.0.0/0" "${OPEN:-none}" "none"
else
  bad "could NOT check for public ingress rules — this assertion did not run.
  $(head -3 "$FW_ERR")"
fi
rm -f "$FW_ERR"

section "Tailnet"
TS_JSON="$(tailscale status --json 2>/dev/null)"
TS_NAMES="$(printf '%s' "$TS_JSON" | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
for p in d.get("Peer",{}).values():
    print(p.get("DNSName","").split(".")[0], "online" if p.get("Online") else "offline")
' 2>/dev/null)"

if printf '%s\n' "$TS_NAMES" | grep -q "^$INSTANCE online"; then
  ok "$INSTANCE is online in the tailnet"
else
  bad "$INSTANCE is not online in the tailnet (found: $(printf '%s' "$TS_NAMES" | tr '\n' ' '))"
fi

DUPES="$(printf '%s\n' "$TS_NAMES" | grep -cE "^$INSTANCE-[0-9]+ ")"
assert "no duplicate ${INSTANCE}-N node (stale node not cleaned up)" "$DUPES" "0"

section "VM state"
BROWSER_OUT="$(mktemp)"
trap 'rm -f "$BROWSER_OUT"' EXIT
BROWSER_ARGS=(--raw)
$QUICK && BROWSER_ARGS+=(--quick)
"$SCRIPT_DIR"/verify-browser.sh "${BROWSER_ARGS[@]}" >"$BROWSER_OUT" 2>&1 &
BROWSER_PID=$!
VM_FACTS="$(ssh_vm QUICK="$QUICK" 'bash -s' 2>/dev/null <<'VMEOF'
set -u
export PATH="/usr/local/sbin:/usr/sbin:/sbin:$PATH"
echo "reachable=yes"
mountpoint -q /mnt/data && echo "data_mounted=yes" || echo "data_mounted=no"
echo "browser_owner=$(stat -c %U /mnt/data/browser 2>/dev/null || echo missing)"
[ "$(tail -1 /usr/local/bin/headed-chromium | tr -d ' ')" = '"$@"' ] \
  && echo "chromium_args=ok" || echo "chromium_args=broken"
[ "$(tail -1 /usr/local/bin/notify-phone)" = 'exec ssh -n termux-phone "$CMD$ARGS"' ] \
  && echo "notify_args=ok" || echo "notify_args=broken"
grep -q '\$\$' /usr/local/bin/notify-phone /usr/local/bin/headed-chromium \
  && echo "dollar_bug=present" || echo "dollar_bug=absent"

echo "notify_key_fpr=$(ssh-keygen -lf /mnt/data/ssh-termux/id_ed25519.pub 2>/dev/null | awk '{print $2}')"
echo "passwd_state=$(sudo passwd -S "$(id -un)" 2>/dev/null | awk '{print $2}')"
sudo sshd -T 2>/dev/null | grep -qx 'passwordauthentication no' \
  && echo "sshd_passauth=off" || echo "sshd_passauth=ON"
sudo sshd -T 2>/dev/null | grep -qx 'permitrootlogin no' \
  && echo "sshd_rootlogin=off" || echo "sshd_rootlogin=ON"

if notify-phone "verify.sh" "state verified $(date -u +%H:%M:%SZ)" --id verify-sh >/dev/null 2>&1 </dev/null; then
  echo "notify_e2e=ok"
else
  echo "notify_e2e=fail"
fi

if ssh -n -o BatchMode=yes -o ConnectTimeout=10 termux-phone id >/dev/null 2>&1; then
  echo "notify_key_shell=ALLOWED"
else
  echo "notify_key_shell=refused"
fi
VMEOF
)"

if [[ "$(fact "$VM_FACTS" reachable)" != "yes" ]]; then
  SSH_ERR="$(ssh_vm true 2>&1 || true)"
  case "$SSH_ERR" in
  *"REMOTE HOST IDENTIFICATION HAS CHANGED"*)
    bad "stale host key for $INSTANCE (the VM was rebuilt). Fix: ssh-keygen -R $INSTANCE" ;;
  *"additional check"* | *"login.tailscale.com"*)
    bad "Tailscale SSH check mode wants a browser confirmation. Run: ssh $SSH_USER@$INSTANCE" ;;
  *)
    bad "cannot SSH to $SSH_USER@$INSTANCE: ${SSH_ERR:-unknown error}" ;;
  esac
else
  ok "SSH to $SSH_USER@$INSTANCE works"
  assert "/mnt/data is mounted" "$(fact "$VM_FACTS" data_mounted)" "yes"
  assert "/mnt/data/browser owned by $SSH_USER" "$(fact "$VM_FACTS" browser_owner)" "$SSH_USER"
  assert "headed-chromium passes arguments through" "$(fact "$VM_FACTS" chromium_args)" "ok"
  assert "notify-phone builds its command correctly" "$(fact "$VM_FACTS" notify_args)" "ok"
  assert "no '\$\$' in the generated wrappers" "$(fact "$VM_FACTS" dollar_bug)" "absent"
  assert "$SSH_USER password is locked" "$(fact "$VM_FACTS" passwd_state)" "L"
  assert "sshd PasswordAuthentication off" "$(fact "$VM_FACTS" sshd_passauth)" "off"
  assert "sshd PermitRootLogin off" "$(fact "$VM_FACTS" sshd_rootlogin)" "off"
  assert "notify-phone reaches the phone end-to-end" "$(fact "$VM_FACTS" notify_e2e)" "ok"
  assert "notify key is refused a shell on the phone" "$(fact "$VM_FACTS" notify_key_shell)" "refused"
fi

section "Phone state"
if [[ -z "$PHONE_HOST" || -z "$PHONE_USER" ]]; then
  skip "phone checks (termux_host/termux_ssh_user not configured)"
else
  PHONE_FACTS="$(ssh_phone 'bash -s' 2>/dev/null <<'PHEOF'
set -u
echo "reachable=yes"
[ -x "$HOME/bin/notify-only" ] && echo "parser=yes" || echo "parser=no"
[ -x "$HOME/.termux/boot/start-sshd.sh" ] && echo "bootscript=yes" || echo "bootscript=no"
TPREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
[ -e "$TPREFIX/var/service/sshd/down" ] && echo "downfile=present" || echo "downfile=absent"
pm list packages 2>/dev/null | grep -q com.termux.boot && echo "bootapp=yes" || echo "bootapp=no"
pm list packages 2>/dev/null | grep -q com.termux.api && echo "apiapp=yes" || echo "apiapp=no"
command -v termux-notification >/dev/null && echo "notifybin=yes" || echo "notifybin=no"
AK="$HOME/.ssh/authorized_keys"
echo "notify_keys=$(ssh-keygen -lf "$AK" 2>/dev/null | grep -c -- '-notify-phone')"
echo "notify_fpr=$(ssh-keygen -lf "$AK" 2>/dev/null | grep -- '-notify-phone' | awk '{print $2}' | head -1)"
echo "other_keys=$(ssh-keygen -lf "$AK" 2>/dev/null | grep -vc -- '-notify-phone')"
echo "restrict_lines=$(grep -c 'restrict,command=' "$AK" 2>/dev/null)"
PHEOF
  )"

  if [[ "$(fact "$PHONE_FACTS" reachable)" != "yes" ]]; then
    bad "cannot SSH to the phone ($PHONE_USER@$PHONE_HOST:$PHONE_PORT)"
  else
    ok "SSH to the phone works"
    assert "forced-command parser installed" "$(fact "$PHONE_FACTS" parser)" "yes"
    assert "termux-notification available" "$(fact "$PHONE_FACTS" notifybin)" "yes"
    assert "Termux:API app installed" "$(fact "$PHONE_FACTS" apiapp)" "yes"
    assert "Termux:Boot app installed" "$(fact "$PHONE_FACTS" bootapp)" "yes"
    assert "boot script installed" "$(fact "$PHONE_FACTS" bootscript)" "yes"
    assert "runit 'down' file cleared" "$(fact "$PHONE_FACTS" downfile)" "absent"
    assert "exactly one notify key authorised" "$(fact "$PHONE_FACTS" notify_keys)" "1"
    assert "notify key is hardened with restrict,command=" "$(fact "$PHONE_FACTS" restrict_lines)" "1"

    if [[ "$(fact "$PHONE_FACTS" other_keys)" -ge 1 ]]; then
      ok "your own key(s) still present ($(fact "$PHONE_FACTS" other_keys))"
    else
      bad "no non-notify key left on the phone — you would lose shell access"
    fi

    VM_FPR="$(fact "$VM_FACTS" notify_key_fpr)"
    PH_FPR="$(fact "$PHONE_FACTS" notify_fpr)"
    if [[ -z "$VM_FPR" ]]; then
      skip "key match (could not read the VM's pubkey)"
    else
      assert "phone trusts the VM's CURRENT key" "$PH_FPR" "$VM_FPR"
    fi
  fi
fi

section "Browser stack (sidecar)"
wait "$BROWSER_PID" 2>/dev/null || true
if [[ ! -s "$BROWSER_OUT" ]]; then
  bad "browser sidecar produced no output (verify-browser.sh failed to run)"
else
  while read -r verdict desc; do
    [[ -n "$verdict" ]] || continue
    case "$verdict" in
    PASS) ok "$desc" ;;
    FAIL) bad "$desc" ;;
    SKIP) skip "$desc" ;;
    *) bad "browser sidecar: $verdict $desc" ;;
    esac
  done <"$BROWSER_OUT"
fi

printf '\n\033[1mResult: %d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
  echo "State is NOT verified. See failures above." >&2
  exit 1
fi
echo "State verified."
