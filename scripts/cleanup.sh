#!/usr/bin/env bash
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

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_config

echo ">> provider=$PROVIDER instance=$INSTANCE"
echo ">> FULL WIPE: compute$( [[ "$PROVIDER" == gcp ]] && $DELETE_BUCKET && echo ' + state bucket')$( $DELETE_FILES && echo ' + local files')"

confirm() {
  $ASSUME_YES && return 0
  read -r -p "$1 [y/N] " ans
  [[ "$ans" == "y" || "$ans" == "Y" ]]
}

if [[ -d "$TF_DIR/.terraform" && ( -f "$TF_DIR/backend.tf" || -f "$TF_DIR/terraform.tfstate" ) ]]; then
  echo ">> Destroying Terraform-managed resources (VM, disk, etc.)"
  if confirm "Run 'terraform destroy'? This deletes the VM and data disk."; then
    if tf destroy -auto-approve; then
      echo ">> Destroy complete."
    else
      echo ">> WARNING: 'terraform destroy' FAILED — resources may remain."
    fi
  else
    echo ">> Skipped terraform destroy."
  fi
else
  if [[ "$PROVIDER" == hetzner ]]; then
    echo ">> No initialized Terraform state (terraform/backend.tf or terraform/.terraform missing)."
    echo "   Skipping terraform destroy. If a server still exists, delete it in the"
    echo "   Hetzner Cloud console or with:  hcloud server delete $INSTANCE"
  elif [[ "$PROVIDER" == oci ]]; then
    echo ">> No initialized Terraform state (terraform/backend.tf or terraform/.terraform missing)."
    echo "   Skipping terraform destroy. If an instance still exists, delete it in the"
    echo "   OCI console or with:  oci compute instance terminate"
  else
    echo ">> No initialized Terraform state (terraform/backend.tf or terraform/.terraform missing)."
    echo "   Skipping terraform destroy."
  fi
fi

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
  if [[ "$PROVIDER" == hetzner ]]; then
    echo ">> Verified with the Hetzner API: no server or volume remains."
  elif [[ "$PROVIDER" == oci ]]; then
    echo ">> Verified with OCI: no instance or block volume remains."
  else
    echo ">> Verified with gcloud: no instance or data disk remains."
  fi
fi

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

if [[ "$PROVIDER" == gcp ]] && $DELETE_BUCKET; then
  if gcloud storage buckets describe "gs://${STATE_BUCKET}" >/dev/null 2>&1; then
    echo ">> WARNING: deleting the state bucket destroys all Terraform state history."
    if confirm "Delete gs://${STATE_BUCKET} and ALL its contents?"; then
      gcloud storage rm --recursive "gs://${STATE_BUCKET}"   # removes objects incl. versioned, then the bucket
      echo ">> Bucket deleted."
    else
      echo ">> Skipped bucket deletion."
    fi
  else
    echo ">> State bucket gs://${STATE_BUCKET} does not exist. Nothing to delete."
  fi
elif [[ "$PROVIDER" == gcp ]]; then
  echo ">> Keeping state bucket gs://${STATE_BUCKET} (--keep-bucket)."
else
  echo ">> No state bucket (Hetzner uses local state)."
fi

if $DELETE_FILES; then
  echo ">> Removing local Terraform artifacts for a clean slate."
  if confirm "Delete terraform/{.terraform,backend.tf,*.tfstate,tailscale.auto.tfvars}?"; then
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
