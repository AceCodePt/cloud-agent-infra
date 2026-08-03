#!/usr/bin/env bash
#
# cleanup.sh — tear down the cloud-agent infrastructure (full wipe by default).
#
# By default this:
#   1. terraform destroy       -> removes the VM + attached data disk
#   2. deletes the GCS state bucket (and all its contents/versions)
#   3. removes local Terraform artifacts (.terraform, lockfile, backend.tf, state)
#
# The state bucket is NOT created by Terraform (chicken-and-egg), so
# Terraform can't destroy it — we remove it explicitly.
#
# SAFETY: the state bucket and backend.tf are the only pointers to live
# resources. Deleting them while the VM/disk still exist orphans that
# infrastructure: Terraform forgets it, this script can no longer destroy it
# (see the backend.tf guard below), and it keeps billing. So both wipes are
# gated on the resources actually being gone, verified with gcloud rather than
# assumed from the destroy's exit code. Override with --force if you really mean
# it.
#
# Usage:
#   ./cleanup.sh              # FULL wipe: compute + bucket + local files
#   ./cleanup.sh --keep-bucket # keep the GCS state bucket
#   ./cleanup.sh --keep-files  # keep local Terraform artifacts
#   ./cleanup.sh --yes         # skip confirmation prompts
#   ./cleanup.sh --force       # wipe bucket/files even if resources still exist
#
set -euo pipefail

DELETE_BUCKET=true
DELETE_FILES=true
ASSUME_YES=false
FORCE=false
for arg in "$@"; do
  case "$arg" in
    --keep-bucket) DELETE_BUCKET=false ;;
    --keep-files)  DELETE_FILES=false ;;
    --yes|-y)      ASSUME_YES=true ;;
    --force)       FORCE=true ;;
    *) echo "Unknown flag: $arg"; exit 1 ;;
  esac
done

# --- Load the single source of truth -----------------------------------
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_config

echo ">> project=$PROJECT_ID region=$REGION bucket=$STATE_BUCKET"
echo ">> FULL WIPE: compute$( $DELETE_BUCKET && echo ' + state bucket')$( $DELETE_FILES && echo ' + local files')"

confirm() {
  $ASSUME_YES && return 0
  read -r -p "$1 [y/N] " ans
  [[ "$ans" == "y" || "$ans" == "Y" ]]
}

# --- 1. Destroy compute via Terraform ----------------------------------
if [[ -f "$TF_DIR/backend.tf" && -d "$TF_DIR/.terraform" ]]; then
  echo ">> Destroying Terraform-managed resources (VM, disk, etc.)"
  if confirm "Run 'terraform destroy'? This deletes the VM and data disk."; then
    # Deliberately not fatal: the guard below inspects reality with gcloud, and a
    # failed destroy must not abort before that guard can protect the state.
    if tf destroy -auto-approve; then
      echo ">> Destroy complete."
    else
      echo ">> WARNING: 'terraform destroy' FAILED — resources may remain."
    fi
  else
    echo ">> Skipped terraform destroy."
  fi
else
  echo ">> No initialized Terraform state (terraform/backend.tf or terraform/.terraform missing)."
  echo "   Skipping terraform destroy. If a VM still exists, delete it with:"
  echo "     gcloud compute instances delete ${TF_VAR_instance_name:-cloud-agent} --zone ${TF_VAR_zone:-me-west1-a}"
fi

# --- 1b. Refuse to throw away the pointers to live resources -----------
LIVE="$(live_resources)"
if [[ -n "$LIVE" ]]; then
  echo ">> WARNING: these resources still exist: $LIVE"
  if $FORCE; then
    echo ">> --force given: continuing anyway."
  elif $DELETE_BUCKET || $DELETE_FILES; then
    echo ">> Refusing to delete the state bucket or local Terraform files while"
    echo "   they exist: that orphans them (Terraform forgets them, they keep"
    echo "   billing, and this script skips the destroy without backend.tf)."
    echo "   Re-run the destroy, or use --force to override."
    DELETE_BUCKET=false
    DELETE_FILES=false
  fi
else
  echo ">> Verified with gcloud: no instance or data disk remains."
fi

# --- 1c. Remove the tailnet node ---------------------------------------
# Only once the instance is verifiably gone: deleting the node of a LIVE VM
# orphans it (tailscaled's persisted identity 404s and it cannot rejoin without
# a fresh auth key). Leaving it behind is also harmful — the stale node keeps the
# MagicDNS name and the next build becomes ${INSTANCE}-1.
if [[ -n "${TAILSCALE_API_KEY:-}" ]]; then
  if [[ -z "$LIVE" ]] || $FORCE; then
    "$SCRIPT_DIR"/tailscale-api.sh delete-node || echo ">> WARNING: node deletion failed; remove it manually."
  else
    echo ">> Skipping tailnet node deletion: the instance still exists"
    echo "   (deleting its node would orphan it from the tailnet)."
  fi
else
  echo ">> TAILSCALE_API_KEY not set: leaving the tailnet node in place."
  echo "   Delete it manually or the next build joins as ${INSTANCE}-1."
fi

# --- 2. Delete the state bucket (default) ------------------------------
if $DELETE_BUCKET; then
  if gcloud storage buckets describe "gs://${STATE_BUCKET}" >/dev/null 2>&1; then
    echo ">> WARNING: deleting the state bucket destroys all Terraform state history."
    if confirm "Delete gs://${STATE_BUCKET} and ALL its contents?"; then
      # --recursive removes objects (incl. versioned) then the bucket
      gcloud storage rm --recursive "gs://${STATE_BUCKET}"
      echo ">> Bucket deleted."
    else
      echo ">> Skipped bucket deletion."
    fi
  else
    echo ">> State bucket gs://${STATE_BUCKET} does not exist. Nothing to delete."
  fi
else
  echo ">> Keeping state bucket gs://${STATE_BUCKET} (--keep-bucket)."
fi

# --- 3. Remove local Terraform artifacts (default) ---------------------
if $DELETE_FILES; then
  echo ">> Removing local Terraform artifacts for a clean slate."
  if confirm "Delete terraform/{.terraform,backend.tf,*.tfstate,tailscale.auto.tfvars}?"; then
    # .terraform.lock.hcl is deliberately NOT deleted: it is committed, and
    # keeping it pins the provider version across rebuilds instead of silently
    # picking up a newer one on the next init.
    rm -rf "$TF_DIR/.terraform" "$TF_DIR/backend.tf" \
      "$TF_DIR/terraform.tfstate" "$TF_DIR/terraform.tfstate.backup" \
      "$TF_DIR/tailscale.auto.tfvars"
    echo ">> Local Terraform artifacts removed."
  else
    echo ">> Skipped local file removal."
  fi
else
  echo ">> Keeping local Terraform artifacts (--keep-files)."
fi

echo ">> Cleanup complete."
