#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_config

VERIFY_ARGS=()
METHOD="iap"
while [[ $# -gt 0 ]]; do
  case "$1" in
  --quick) VERIFY_ARGS+=(--quick) ;;
  --reboot) METHOD="reboot" ;;
  -h | --help)
    echo "Usage: ./run up [--quick] [--reboot]"
    exit 0
    ;;
  *) die "unknown flag: $1 (try --quick, --reboot)" ;;
  esac
  shift
done

ACTIONS=()
step() {
  ACTIONS+=("$1")
  printf '\n\033[1m=== %s\033[0m\n' "$1"
}
converged() { printf '  \033[32mok\033[0m    %s\n' "$1"; }

printf '\033[1mConverging %s (project %s, zone %s)\033[0m\n' "$INSTANCE" "$PROJECT_ID" "$ZONE"

gcloud auth application-default print-access-token >/dev/null 2>&1 ||
  die "no application-default credentials.
  Run: gcloud auth application-default login"

if [[ -f "$TF_DIR/backend.tf" && -f "$TF_DIR/.terraform/terraform.tfstate" ]]; then
  converged "state backend initialised"
else
  step "bootstrap the Terraform state backend"
  "$SCRIPT_DIR"/bootstrap.sh --no-mint
fi

if KEY_STATE="$("$SCRIPT_DIR"/tailscale-api.sh check 2>&1)"; then
  if [[ "$KEY_STATE" == *WARNING* ]]; then
    printf '%s\n' "$KEY_STATE"
  else
    converged "${KEY_STATE#>> }"
  fi
else
  step "mint a fresh Tailscale auth key"
  echo "  reason: the current key is not usable —"
  printf '%s\n' "$KEY_STATE" | sed 's/^/  | /'
  "$SCRIPT_DIR"/tailscale-api.sh mint
  "$SCRIPT_DIR"/tailscale-api.sh check   # a key revoked mid-mint must not be baked in
fi

BEFORE="$(instance_status)"

if [[ "$BEFORE" == unknown ]]; then
  die "cannot determine whether $INSTANCE exists — gcloud could not read it.

$(gcloud_identity_hint)"
fi

step "terraform apply"
echo "  instance status before: $BEFORE"
tf apply -auto-approve

if [[ "$BEFORE" == absent ]]; then
  ssh-keygen -R "$INSTANCE" >/dev/null 2>&1 || true
fi

case "$BEFORE" in
absent)
  step "wait for first boot (the fresh VM consumes the key itself)"
  "$SCRIPT_DIR"/wait-ready.sh
  ;;
TERMINATED)
  step "start $INSTANCE (a stopped VM re-runs its startup script on boot)"
  gcloud_instance start
  "$SCRIPT_DIR"/wait-ready.sh
  ;;
RUNNING)
  if vm_online; then
    converged "$INSTANCE is online in the tailnet"
  else
    step "deliver the auth key to the running VM"
    echo "  $INSTANCE is RUNNING but not online in the tailnet, so it never"
    echo "  consumed a key. 'apply' cannot fix this: GCE only runs"
    echo "  startup-script at boot, so re-trigger it explicitly."
    if ! rerun_startup_script "$METHOD"; then
      if [[ "$METHOD" == reboot ]]; then
        die "could not stop/start $INSTANCE — see the gcloud error above."
      fi
      warn "re-running the startup script over IAP failed; falling back to a reboot"
      rerun_startup_script reboot
    fi
    "$SCRIPT_DIR"/wait-ready.sh
  fi
  ;;
*)
  step "wait for $INSTANCE to settle (status was $BEFORE)"
  "$SCRIPT_DIR"/wait-ready.sh
  ;;
esac

if ssh_vm true 2>/dev/null; then
  converged "SSH to $SSH_USER@$INSTANCE works"
else
  SSH_ERR="$(ssh_vm true 2>&1 || true)"
  case "$SSH_ERR" in
  *"REMOTE HOST IDENTIFICATION HAS CHANGED"*)
    step "clear the stale SSH host key for $INSTANCE"
    echo "  the VM was rebuilt since this machine last connected"
    ssh-keygen -R "$INSTANCE" >/dev/null 2>&1 || true
    if ssh_vm true 2>/dev/null; then
      echo "  SSH works again"
    else
      warn "SSH still failing after clearing the host key:
  $(ssh_vm true 2>&1 || true)"
    fi
    ;;
  *"additional check"* | *"login.tailscale.com"*)
    warn "Tailscale SSH wants a browser confirmation for this session.
  Run once, interactively:  ./run ssh"
    ;;
  *) warn "SSH to $SSH_USER@$INSTANCE is failing: $SSH_ERR" ;;
  esac
fi

PKG_STATE="$(ssh_vm 'systemctl is-active agent-packages' 2>/dev/null || true)"
case "$PKG_STATE" in
active) converged "deferred package install finished" ;;
activating) converged "deferred package install still running (expected on a fresh build)" ;;
failed) warn "the deferred package install FAILED — the box is reachable but the
  browser stack is missing. Diagnose:  ./run ssh journalctl -u agent-packages -n 50" ;;
esac

load_phone_config
if [[ -n "$PHONE_HOST" && -n "$PHONE_USER" ]]; then
  step "re-key the phone to the VM's current notify pubkey"
  "$SCRIPT_DIR"/provision-phone.sh
else
  converged "phone notifications not configured (skipping)"
fi

step "verify"
set +e
"$SCRIPT_DIR"/verify.sh "${VERIFY_ARGS[@]}"
RESULT=$?
set -e

printf '\n\033[1m=== summary\033[0m\n'
if [[ "${#ACTIONS[@]}" -eq 0 ]]; then
  echo "  nothing to do — already converged"
else
  for a in "${ACTIONS[@]}"; do echo "  - $a"; done
fi

if [[ "$RESULT" -eq 0 ]]; then
  printf '\n\033[1;32m%s is up and verified.\033[0m\n' "$INSTANCE"
  if [[ "$PKG_STATE" == activating ]]; then
    echo
    echo "The browser stack (chromium/Xvfb/zram) is still installing in the"
    echo "background, so those checks were SKIPped, not asserted. To finish:"
    echo "  ./run wait --packages && ./run verify-browser"
  fi
else
  printf '\n\033[1;31mConverged as far as possible, but verify FAILED.\033[0m\n' >&2
  echo "See the failures above. Re-running ./run up is safe and may fix" >&2
  echo "transient drift; anything persistent needs the fix it names." >&2
fi
exit "$RESULT"
