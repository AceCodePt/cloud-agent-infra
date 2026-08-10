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

printf '\033[1mConverging %s (provider %s)\033[0m\n' "$INSTANCE" "$PROVIDER"

if [[ "$PROVIDER" == gcp ]]; then
  gcloud auth application-default print-access-token >/dev/null 2>&1 ||
    die "no application-default credentials.
  Run: gcloud auth application-default login"
fi

if [[ -f "$TF_DIR/backend.tf" && -d "$TF_DIR/.terraform" ]]; then
  converged "state backend initialised"
elif [[ -d "$TF_DIR/.terraform" && -f "$TF_DIR/terraform.tfstate" ]]; then
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
  KEY_RC=$?
  if [[ "$KEY_RC" -eq 2 ]]; then
    step "no Tailscale auth key present (the default state) — minting one"
  else
    step "mint a fresh Tailscale auth key"
    echo "  reason: the current key is not usable —"
    printf '%s\n' "$KEY_STATE" | sed 's/^/  | /'
  fi
  "$SCRIPT_DIR"/tailscale-api.sh mint
  "$SCRIPT_DIR"/tailscale-api.sh check   # a key revoked mid-mint must not be baked in
fi

BEFORE="$(instance_status)"

if [[ "$BEFORE" == unknown ]]; then
  if [[ "$PROVIDER" == hetzner ]]; then
    die "cannot determine whether server '$INSTANCE' exists — the Hetzner API
  could not be read. Check HETZNER_API_KEY in config.env."
  fi
  if [[ "$PROVIDER" == oci ]]; then
    die "cannot determine whether instance '$INSTANCE' exists — the OCI CLI
  could not read it. Check OCI_* credentials in config.env and that 'oci' is on PATH."
  fi
  die "cannot determine whether $INSTANCE exists — gcloud could not read it.

$(gcloud_identity_hint)"
fi

step "terraform apply"
echo "  instance status before: $BEFORE"
# OCI free-tier A1 launches are capacity-flaky ("Out of host capacity").
# Retry the apply a bounded number of times instead of failing the whole
# converge on a transient region shortage. Safe to retry: Terraform records
# each resource as it is created, so a later attempt only relaunches the
# instance. Any other failure exits immediately.
APPLY_LOG="$(mktemp)"
apply_ok=false
for attempt in $(seq 1 "${OCI_LAUNCH_RETRIES:-8}"); do
  if [[ "$attempt" -gt 1 ]]; then
    echo "  terraform apply (attempt $attempt/${OCI_LAUNCH_RETRIES:-8})"
  fi
  if tf apply -auto-approve >"$APPLY_LOG" 2>&1; then
    apply_ok=true
    break
  fi
  if [[ "$PROVIDER" == oci ]] && grep -q "Out of host capacity" "$APPLY_LOG" && [[ "$attempt" -lt "${OCI_LAUNCH_RETRIES:-8}" ]]; then
    echo "  A1 free-tier out of host capacity; retrying in 30s"
    sleep 30
    continue
  fi
  break
done
cat "$APPLY_LOG"
rm -f "$APPLY_LOG"
$apply_ok || die "terraform apply failed (see the plan/errors above)"

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
  instance_start
  "$SCRIPT_DIR"/wait-ready.sh
  ;;
RUNNING)
  if vm_online; then
    converged "$INSTANCE is online in the tailnet"
  else
    step "deliver the auth key to the running VM"
    echo "  $INSTANCE is RUNNING but not online in the tailnet, so it never"
    echo "  consumed a key. 'apply' cannot fix this: the startup script only"
    echo "  runs at boot, so re-trigger it explicitly."
    if [[ "$PROVIDER" == hetzner ]]; then
      warn "$INSTANCE is not on the tailnet, so SSH is unreachable and the key
  cannot be delivered remotely. Open the Hetzner Cloud web console (VNC) for
  $INSTANCE, or use a rescue system — then fix /etc/agent/authkey or reboot."
    elif [[ "$PROVIDER" == oci ]]; then
      warn "$INSTANCE is not on the tailnet, so SSH is unreachable and the key
  cannot be delivered remotely. Use the OCI Cloud Shell serial console for
  $INSTANCE, then fix /etc/agent/authkey or reboot."
    elif ! rerun_startup_script "$METHOD"; then
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
    CHECK_URL="$(grep -oE 'https://login\.tailscale\.com/a/[A-Za-z0-9]+' <<<"$SSH_ERR" | head -1)"
    # The check-mode connection can stall (banner never answers) instead of
    # failing fast; backfill the URL from a fresh probe so it is always current.
    [[ -n "$CHECK_URL" ]] || \
      CHECK_URL="$(ssh_vm true 2>&1 || true | grep -oE 'https://login\.tailscale\.com/a/[A-Za-z0-9]+' | head -1)"
    warn "Tailscale SSH needs a one-time browser approval before SSH to $INSTANCE works."
    echo "  Open this URL in a browser and approve it:"
    echo "    ${CHECK_URL:-<no URL found — run interactively:  ./run ssh>}"
    echo "  Waiting for your approval — this run continues automatically once"
    echo "  you click it. (Ctrl-C to abort.)"

    WAIT_BUDGET="${WAIT_APPROVAL_TIMEOUT:-1800}"
    START_WAIT="$(date +%s)"
    while :; do
      if PROBE_OUT="$(ssh_vm true 2>&1)"; then
        echo "  SSH approved — continuing."
        break
      fi
      # A definite non-approval failure (host key, auth, refused) is not going
      # to pass by itself — surface it instead of burning the wait budget.
      if ! grep -qiE "additional check|login.tailscale.com" <<<"$PROBE_OUT" &&
         grep -qiE "REMOTE HOST IDENTIFICATION HAS CHANGED|Host key verification failed|Permission denied|Connection refused|authentication failed" <<<"$PROBE_OUT"; then
        warn "SSH is failing for a reason other than the approval prompt:"
        printf '%s\n' "$PROBE_OUT" | sed 's/^/  | /'
        exit 1
      fi
      ELAPSED_WAIT=$(($(date +%s) - START_WAIT))
      if [[ "$ELAPSED_WAIT" -ge "$WAIT_BUDGET" ]]; then
        warn "timed out waiting for the Tailscale SSH approval (${WAIT_BUDGET}s)."
        echo "  Approve the URL above, then re-run:  ./run up"
        exit 1
      fi
      if (( ELAPSED_WAIT % 60 < 15 )); then
        echo "  still waiting for your approval… (${ELAPSED_WAIT}s elapsed)"
      fi
      sleep 15
    done
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
