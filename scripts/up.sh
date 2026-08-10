#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_config

VERIFY_ARGS=()
METHOD="iap"
NO_IMAGE=false
while [[ $# -gt 0 ]]; do
  case "$1" in
  --quick) VERIFY_ARGS+=(--quick) ;;
  --no-image) NO_IMAGE=true ;;
  --reboot) METHOD="reboot" ;;
  -h | --help)
    echo "Usage: ./run up [--quick] [--no-image] [--reboot]"
    echo "  --no-image   skip build/upload/import of the golden image (infra only)"
    exit 0
    ;;
  *) die "unknown flag: $1 (try --quick, --no-image, --reboot)" ;;
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
  step "mint a fresh Tailscale auth key"
  echo "  reason: the current key is not usable —"
  printf '%s\n' "$KEY_STATE" | sed 's/^/  | /'
  "$SCRIPT_DIR"/tailscale-api.sh mint
  "$SCRIPT_DIR"/tailscale-api.sh check   # a key revoked mid-mint must not be baked in
fi

# --- golden image: build -> upload -> import (each step converges) ---
if $NO_IMAGE; then
  converged "image steps skipped (--no-image)"
elif [[ "$PROVIDER" != oci ]]; then
  converged "golden image steps are OCI-only (provider $PROVIDER)"
else
  # Snapshot the build stamp's mtime: if it changes, build-image.sh really
  # rebuilt the image, and a local QEMU boot test gates the cloud cycle.
  STAMP="images/output/.build-stamp"
  [[ -f "$STAMP" ]] && STAMP_MTIME_BEFORE="$(stat -c %Y "$STAMP")" || STAMP_MTIME_BEFORE=""

  step "golden image: build (skips if nothing changed)"
  "$SCRIPT_DIR"/build-image.sh

  STAMP_MTIME_AFTER=""
  [[ -f "$STAMP" ]] && STAMP_MTIME_AFTER="$(stat -c %Y "$STAMP")"
  if [[ -n "$STAMP_MTIME_BEFORE" && "$STAMP_MTIME_AFTER" == "$STAMP_MTIME_BEFORE" ]]; then
    converged "image unchanged; skipping local boot test"
  else
    step "golden image: local QEMU boot test (fresh build)"
    "$SCRIPT_DIR"/boot-test-local.sh
  fi

  step "golden image: upload to Object Storage (skips if object is current)"
  "$SCRIPT_DIR"/upload-image.sh

  step "golden image: import as custom image (reuses the image for this qcow2)"
  "$SCRIPT_DIR"/import-image.sh
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
tf apply -auto-approve

if [[ "$BEFORE" == absent ]]; then
  ssh-keygen -R "$INSTANCE" >/dev/null 2>&1 || true
fi

case "$BEFORE" in
absent)
  if [[ "$PROVIDER" == oci ]]; then
    # OCI first boot stages the whole Arch system before the box joins the
    # tailnet (download + extract rootfs, pacman -Syu, ESP staging, reboot).
    # Give it up to 45 minutes; every later boot is a plain Arch boot.
    step "wait for first boot (OCI: Arch staging build, can take ~10-30 min)"
    "$SCRIPT_DIR"/wait-ready.sh 2700
  else
    step "wait for first boot (the fresh VM consumes the key itself)"
    "$SCRIPT_DIR"/wait-ready.sh
  fi
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
    if [[ "$PROVIDER" == oci ]]; then
      # OCI first build is a staging host that constructs the whole Arch system
      # on the data volume and only then reboots into it. While that runs, the
      # box is Oracle Linux and never joins the tailnet — that is normal, not a
      # missing key. Just wait (long): the boot-order + ESP are staged by the
      # script itself, so there is nothing to deliver remotely.
      step "wait for the OCI Arch staging build (download+pacman+reboot, can take ~10-30 min)"
      "$SCRIPT_DIR"/wait-ready.sh 2700
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
