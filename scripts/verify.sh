#!/usr/bin/env bash
set -uo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_config

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
  if [[ "$PROVIDER" == hetzner ]]; then
    bad "cannot read server $INSTANCE from the Hetzner API (token problem, not the VM)"
  elif [[ "$PROVIDER" == oci ]]; then
    bad "cannot read instance $INSTANCE from OCI (credential problem, not the VM)"
  else
    bad "cannot read instance $INSTANCE from gcloud (credential problem, not the VM)"
    printf '%s\n' "$(gcloud_identity_hint)"
  fi
else
  assert "instance $INSTANCE is RUNNING" "$STATUS" "RUNNING"
fi

if [[ "$PROVIDER" == hetzner ]]; then
  OPEN="$(hz_public_ingress)"
  assert "no inbound firewall rule opens the server" "$OPEN" "none"
elif [[ "$PROVIDER" == oci ]]; then
  OPEN="$(oci_public_ingress)"
  assert "no public IP and no inbound rule opens the instance" "$OPEN" "none"
else
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
fi

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
VM_FACTS="$(ssh_vm QUICK="$QUICK" PROVIDER="$PROVIDER" 'bash -s' 2>/dev/null <<'VMEOF'
set -u
export PATH="$HOME/.local/bin:/usr/local/sbin:/usr/sbin:/sbin:$PATH"
echo "reachable=yes"
if mountpoint -q /mnt/data; then
  echo "data_mounted=yes"
else
  echo "data_mounted=no"
fi
echo "browser_owner=$(stat -c %U /mnt/data/browser 2>/dev/null || echo missing)"
[ "$(tail -1 /usr/local/bin/headed-chromium | tr -d ' ')" = '"$@"' ] \
  && echo "chromium_args=ok" || echo "chromium_args=broken"
grep -q '\$\$' /usr/local/bin/headed-chromium \
  && echo "dollar_bug=present" || echo "dollar_bug=absent"

tailscale status >/dev/null 2>&1 && echo "ts_operator=yes" || echo "ts_operator=no"
echo "passwd_state=$(sudo passwd -S "$(id -un)" 2>/dev/null | awk '{print $2}')"
sudo sshd -T 2>/dev/null | grep -qix 'passwordauthentication no' \
  && echo "sshd_passauth=off" || echo "sshd_passauth=ON"
sudo sshd -T 2>/dev/null | grep -qix 'permitrootlogin no' \
  && echo "sshd_rootlogin=off" || echo "sshd_rootlogin=ON"
sudo sshd -T 2>/dev/null | grep -qix 'kbdinteractiveauthentication no' \
  && echo "sshd_kbdinteractive=off" || echo "sshd_kbdinteractive=ON"
echo "startup_script_mode=$(stat -c %a /usr/local/sbin/agent-startup 2>/dev/null || echo missing)"

systemctl is-active exit-node-watch 2>/dev/null | grep -qx active \
  && echo "watchdog=active" || echo "watchdog=inactive"
[ -x /usr/local/sbin/exit-node-watch ] \
  && echo "watchdog_script=present" || echo "watchdog_script=missing"

for t in fzf direnv mise nvim unzip; do
  command -v "$t" >/dev/null 2>&1 \
    && echo "${t}=present" || echo "${t}=missing"
done
[ -x "$HOME/.local/share/mise/shims/go" ] \
  && echo "go_shim=present" || echo "go_shim=missing"
[ -x "$HOME/.local/share/mise/shims/cargo" ] \
  && echo "cargo_shim=present" || echo "cargo_shim=missing"
[ -x "$HOME/.local/share/mise/shims/node" ] \
  && echo "node_shim=present" || echo "node_shim=missing"
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
  assert "no '\$\$' in the generated wrapper" "$(fact "$VM_FACTS" dollar_bug)" "absent"
  assert "$SSH_USER password is locked" "$(fact "$VM_FACTS" passwd_state)" "L"
  assert "sshd PasswordAuthentication off" "$(fact "$VM_FACTS" sshd_passauth)" "off"
  assert "sshd PermitRootLogin off" "$(fact "$VM_FACTS" sshd_rootlogin)" "off"
  assert "sshd KbdInteractiveAuthentication off" "$(fact "$VM_FACTS" sshd_kbdinteractive)" "off"
  assert "startup script mode 700" "$(fact "$VM_FACTS" startup_script_mode)" "700"
  assert "exit-node watchdog running" "$(fact "$VM_FACTS" watchdog)" "active"
  assert "exit-node watchdog script present" "$(fact "$VM_FACTS" watchdog_script)" "present"
  assert "fzf installed" "$(fact "$VM_FACTS" fzf)" "present"
  assert "direnv installed" "$(fact "$VM_FACTS" direnv)" "present"
  assert "mise installed" "$(fact "$VM_FACTS" mise)" "present"
  assert "go installed via mise" "$(fact "$VM_FACTS" go_shim)" "present"
  assert "cargo installed via mise" "$(fact "$VM_FACTS" cargo_shim)" "present"
  assert "node installed via mise" "$(fact "$VM_FACTS" node_shim)" "present"
  assert "neovim installed" "$(fact "$VM_FACTS" nvim)" "present"
  assert "unzip installed" "$(fact "$VM_FACTS" unzip)" "present"
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
