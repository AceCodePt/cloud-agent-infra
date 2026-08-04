#!/usr/bin/env bash
#
# up.sh — the single command. Converge everything to the verified good state.
# A convergence loop, not a build script: every step first asks what is already
# true and does nothing if so. Safe to run on a broken, half-built, fine, or
# unknown-state box.
#
# NON-DESTRUCTIVE BY CONTRACT: never destroys the VM, data disk, state bucket or
# tailnet node. May reboot the VM when that is the only way to deliver an auth
# key. What it converges, in order:
#   1. Terraform state backend     bootstrap only if backend.tf/.terraform absent
#   2. Tailscale auth key          mint only if the current one is unusable
#   3. Infrastructure              terraform apply (itself a converge)
#   4. Guest consumed the key      only if the VM is not online in the tailnet
#   5. Local SSH known_hosts       clear a stale entry from a previous VM
#   6. Phone notify key            re-key to the VM's CURRENT pubkey (idempotent)
#   7. Proof                       verify.sh, non-zero on any drift
#
# Step 4 is why this script exists: GCE runs startup-script at BOOT only, so
# applying a fresh key to a running instance is a metadata-only change the guest
# never reads, and the apply still reports success.
#
# Usage: ./run up [--quick] [--reboot]
#
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

# Actions taken, so the run ends with an honest summary instead of a wall of
# output you read backwards to find whether anything changed.
ACTIONS=()
step() {
  ACTIONS+=("$1")
  printf '\n\033[1m=== %s\033[0m\n' "$1"
}
converged() { printf '  \033[32mok\033[0m    %s\n' "$1"; }

printf '\033[1mConverging %s (project %s, zone %s)\033[0m\n' "$INSTANCE" "$PROJECT_ID" "$ZONE"

# 0. Preflight — Terraform uses application-default credentials; without them
# the failure is a provider error several steps deep.
gcloud auth application-default print-access-token >/dev/null 2>&1 ||
  die "no application-default credentials.
  Run: gcloud auth application-default login"

# 1. State backend. The marker is .terraform/terraform.tfstate, not the
# directory: the file is the record of an initialised backend, whereas the dir
# also exists after a providers-only `init -backend=false` (./run validate).
if [[ -f "$TF_DIR/backend.tf" && -f "$TF_DIR/.terraform/terraform.tfstate" ]]; then
  converged "state backend initialised"
else
  step "bootstrap the Terraform state backend"
  # --no-mint: the key decision belongs to step 2, which only mints when needed.
  "$SCRIPT_DIR"/bootstrap.sh --no-mint
fi

# 2. Tailscale auth key. `check` is the same guard ./run apply uses; its output
# is captured because an unusable key is a condition to fix, not an error.
if KEY_STATE="$("$SCRIPT_DIR"/tailscale-api.sh check 2>&1)"; then
  # check also succeeds-with-a-warning (no API key, or a spent key the running
  # node no longer needs) — pass those through verbatim.
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

# 3. Infrastructure. BEFORE is recorded pre-apply: whether the guest needs the
# key delivered depends on whether this apply created the instance (first boot
# consumes it itself) or only updated a running one's metadata (it does not).
BEFORE="$(instance_status)"

# "unknown" means gcloud could not tell us — almost always a credential
# mismatch. Refuse to guess: treating it as "absent" would build a second VM
# while the real one runs invisibly.
if [[ "$BEFORE" == unknown ]]; then
  die "cannot determine whether $INSTANCE exists — gcloud could not read it.

$(gcloud_identity_hint)"
fi

step "terraform apply"
echo "  instance status before: $BEFORE"
tf apply -auto-approve

# A VM that did not exist a moment ago cannot legitimately present the host key
# this machine remembers. Clear it BEFORE anything tries to SSH — wait-ready
# now uses SSH for its authoritative readiness check.
if [[ "$BEFORE" == absent ]]; then
  ssh-keygen -R "$INSTANCE" >/dev/null 2>&1 || true
fi

# 4. Make sure the guest has consumed the key.
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
      # Retry the other transport only: IAP can be unavailable (permissions, org
      # policy) while the Compute API works; rebooting after a failed reboot would
      # just fail twice. Full if/else, not `[[ ]] && die`: under `set -e` a false
      # test exits the script instead of falling through to the fallback.
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
  # STAGING, STOPPING, SUSPENDED, REPAIRING — mid-transition; wait on the end state.
  step "wait for $INSTANCE to settle (status was $BEFORE)"
  "$SCRIPT_DIR"/wait-ready.sh
  ;;
esac

# 5. Local SSH known_hosts. accept-new takes an UNKNOWN host silently but refuses
# a CHANGED one, so a leftover entry from a previous build breaks every ssh_vm
# with what looks like a VM fault. Only this host's entry is touched. The EXIT
# CODE is the signal, not stderr: a first connection succeeds while printing
# "Permanently added ..." so treating any stderr as failure would warn on every
# fresh build.
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
  # Tailscale SSH check mode needs an interactive browser confirmation, which
  # can't be automated away — say so instead of failing six steps later.
  *"additional check"* | *"login.tailscale.com"*)
    warn "Tailscale SSH wants a browser confirmation for this session.
  Run once, interactively:  ./run ssh"
    ;;
  *) warn "SSH to $SSH_USER@$INSTANCE is failing: $SSH_ERR" ;;
  esac
fi

# 5b. Deferred install state — one cheap query, remembered for the summary.
PKG_STATE="$(ssh_vm 'systemctl is-active agent-packages' 2>/dev/null || true)"
case "$PKG_STATE" in
active) converged "deferred package install finished" ;;
activating) converged "deferred package install still running (expected on a fresh build)" ;;
failed) warn "the deferred package install FAILED — the box is reachable but the
  browser stack is missing. Diagnose:  ./run ssh journalctl -u agent-packages -n 50" ;;
esac

# 6. Phone notify key. Always run: idempotent, and the VM's notify keypair is the
# most drift-prone fact in the system (a new data disk = new keypair, phone still
# trusts the old one). Only removes keys whose comment ends in -notify-phone.
#
# Resolved HERE, not at the top: config.env only overrides, so the defaults
# (termux_host especially) are only knowable from Terraform outputs — which don't
# exist until the apply above ran. Reading them earlier yields empty values on a
# from-zero run, and this step would silently skip while verify.sh failed on the
# stale phone key.
load_phone_config
if [[ -n "$PHONE_HOST" && -n "$PHONE_USER" ]]; then
  step "re-key the phone to the VM's current notify pubkey"
  "$SCRIPT_DIR"/provision-phone.sh
else
  converged "phone notifications not configured (skipping)"
fi

# 7. Proof. The summary must print even when verify fails, and its exit code is
# this script's — so drop `set -e` for exactly this call.
step "verify"
set +e
"$SCRIPT_DIR"/verify.sh "${VERIFY_ARGS[@]}"
RESULT=$?
set -e

# --- Summary --------------------------------------------------------------
printf '\n\033[1m=== summary\033[0m\n'
if [[ "${#ACTIONS[@]}" -eq 0 ]]; then
  echo "  nothing to do — already converged"
else
  for a in "${ACTIONS[@]}"; do echo "  - $a"; done
fi

if [[ "$RESULT" -eq 0 ]]; then
  printf '\n\033[1;32m%s is up and verified.\033[0m\n' "$INSTANCE"
  # verify SKIPs the browser stack while phase B is still installing, so a green
  # run doesn't mean chromium is ready.
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
