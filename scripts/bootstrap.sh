#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_config

MINT=true
for arg in "$@"; do
  case "$arg" in
  --no-mint) MINT=false ;;
  *) die "unknown flag: $arg" ;;
  esac
done

if [[ "$PROVIDER" == hetzner ]]; then
  echo ">> provider=hetzner instance=$INSTANCE location=${TF_VAR_location:-nbg1}"
else
  echo ">> project=$PROJECT_ID region=$REGION bucket=$STATE_BUCKET"
fi

: "${TF_VAR_zone:?zone not set in config.env}"
: "${TF_VAR_ssh_user:?ssh_user not set in config.env}"

if ! $MINT; then
  echo ">> Skipping auth-key minting (--no-mint)."
elif [[ -n "${TAILSCALE_API_KEY:-}" ]]; then
  if [[ -n "${TF_VAR_tailscale_auth_key:-}" ]]; then
    warn "both TAILSCALE_API_KEY and TF_VAR_tailscale_auth_key are set.
   The minted key wins (tailscale.auto.tfvars outranks TF_VAR_* env vars), so the
   one in config.env is ignored — until that file goes missing, at which point a
   probably-spent key gets baked into the VM. Remove it from config.env."
  fi
  "$SCRIPT_DIR"/tailscale-api.sh mint
elif [[ -n "${TF_VAR_tailscale_auth_key:-}" ]]; then
  if [[ "$TF_VAR_tailscale_auth_key" != tskey-auth-* ]]; then
    echo "ERROR: TF_VAR_tailscale_auth_key does not look like an auth key"
    echo "       (expected it to start with 'tskey-auth-')."
    exit 1
  fi
  echo ">> Using the auth key from config.env. NOTE: it must be REUSABLE and"
  echo "   unexpired — a consumed single-use key fails the same silent way."
else
  echo "ERROR: no Tailscale credential. Set TAILSCALE_API_KEY in config.env to"
  echo "       mint keys automatically, or set TF_VAR_tailscale_auth_key."
  echo "       Without one the VM boots but never joins the tailnet, leaving it"
  echo "       unreachable (there is no public inbound)."
  exit 1
fi

if command -v tailscale >/dev/null 2>&1; then
  if tailscale status 2>/dev/null | grep -qE "[[:space:]]$INSTANCE[[:space:]]"; then
    echo ">> WARNING: a tailnet node named '$INSTANCE' already exists."
    echo "   If it is stale, remove it before applying:"
    echo "     make delete-node   (or ./scripts/tailscale-api.sh delete-node)"
    echo "   Otherwise the new VM joins as '${INSTANCE}-1' and 'ssh $INSTANCE'"
    echo "   will hit the dead node. (cleanup.sh does this for you.)"
    echo "   NOTE: never delete the node of a VM you intend to keep — it cannot"
    echo "   rejoin without a fresh auth key (netmap polls fail 404)."
  fi
fi

if [[ "$PROVIDER" == hetzner ]]; then
  if [[ -n "$HZ_OBJECT_ACCESS_KEY" && -n "$HZ_OBJECT_SECRET_KEY" && -n "$HZ_OBJECT_BUCKET" ]]; then
    echo ">> Hetzner Object Storage backend: bucket=$HZ_OBJECT_BUCKET region=$HZ_OBJECT_REGION"
    cat > "$TF_DIR/backend.tf" <<EOF
terraform {
  backend "s3" {
    bucket                       = "${HZ_OBJECT_BUCKET}"
    key                          = "hetzner/terraform.tfstate"
    region                       = "${HZ_OBJECT_REGION}"
    endpoints = {
      s3 = "https://${HZ_OBJECT_REGION}.your-objectstorage.com"
    }
    use_path_style              = true
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_metadata_api_check     = true
    skip_requesting_account_id  = true
  }
}
EOF
    if [[ -f "$TF_DIR/terraform.tfstate" || -f "$TF_DIR/.terraform/terraform.tfstate" ]]; then
      echo ">> migrating existing local state into the bucket"
      tf init -migrate-state -force-copy -input=false
    else
      tf init -input=false
    fi
  else
    echo ">> Hetzner: LOCAL Terraform state in $TF_DIR (git-ignored)."
    echo "   For a durable backend, create a bucket in the Hetzner console"
    echo "   (Project -> Object Storage -> Create Bucket) and set in config.env:"
    echo "     HETZNER_OBJECT_ACCESS_KEY / HETZNER_OBJECT_SECRET_KEY / TF_STATE_BUCKET"
    echo "   then re-run: ./run bootstrap"
    tf init -input=false
  fi
  echo ">> Bootstrap complete. Next: ./run plan && ./run apply"
  exit 0
fi

if ! gcloud auth application-default print-access-token >/dev/null 2>&1; then
  echo "ERROR: no application-default credentials."
  echo "       Run: gcloud auth application-default login"
  exit 1
fi

echo ">> Setting active project"
gcloud config set project "$PROJECT_ID"

echo ">> Enabling required APIs (compute, storage, iap)"
gcloud services enable \
  compute.googleapis.com \
  storage.googleapis.com \
  iap.googleapis.com

if gcloud storage buckets describe "gs://${STATE_BUCKET}" >/dev/null 2>&1; then
  echo ">> Bucket gs://${STATE_BUCKET} already exists, skipping create"
else
  echo ">> Creating state bucket"
  gcloud storage buckets create "gs://${STATE_BUCKET}" \
    --project="$PROJECT_ID" \
    --location="$REGION" \
    --uniform-bucket-level-access
fi

echo ">> Enabling versioning (state recovery)"
gcloud storage buckets update "gs://${STATE_BUCKET}" --versioning

echo ">> Writing terraform/backend.tf"
cat > "$TF_DIR/backend.tf" <<EOF
terraform {
  backend "gcs" {
    bucket = "${STATE_BUCKET}"
    prefix = "terraform/state"
  }
}
EOF

echo ">> terraform init"
tf init -input=false

echo ">> Bootstrap complete. Next: make plan && make apply"
