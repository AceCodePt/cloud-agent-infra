#!/usr/bin/env bash
#
# bootstrap.sh — one-time setup of the Terraform GCS state backend.
#
# Solves the chicken-and-egg problem: Terraform's state bucket can't be
# managed by Terraform itself, so we create it here first, then hand off.
#
# What it does:
#   1. Reads config from config.env (the single source of truth).
#   2. Sets the active project and enables required APIs.
#   3. Creates the GCS state bucket (idempotent) with versioning.
#   4. Writes backend.tf and runs `terraform init`.
#
# Safe to re-run: the bucket create is guarded, versioning is idempotent.
#
# Usage:
#   source ./config.env     # or let direnv do it
#   ./bootstrap.sh
#   ./bootstrap.sh --no-mint   # skip key minting; the caller owns that decision
#
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_config

# --no-mint exists for up.sh, which decides for itself whether a new key is
# needed (it mints only when the current one is unusable). Minting here as well
# would burn a key on every converge and leave a permanent metadata diff, so
# "nothing changed" could never be observed.
MINT=true
for arg in "$@"; do
  case "$arg" in
  --no-mint) MINT=false ;;
  *) die "unknown flag: $arg" ;;
  esac
done

echo ">> project=$PROJECT_ID region=$REGION bucket=$STATE_BUCKET"

# --- Fail fast on the things that only surface 4 minutes into a boot ----
: "${TF_VAR_zone:?zone not set in config.env}"
: "${TF_VAR_ssh_user:?ssh_user not set in config.env}"

# A missing or malformed auth key is invisible until the VM has booted and
# silently failed to join the tailnet — at which point the box is unreachable by
# design and looks like a hang. So resolve it here, before anything is built.
if ! $MINT; then
  echo ">> Skipping auth-key minting (--no-mint)."
elif [[ -n "${TAILSCALE_API_KEY:-}" ]]; then
  # Preferred path: mint a fresh one-off key per build. Nothing long-lived sits
  # in config.env, and a spent key can never silently fail a later rebuild.
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

# A leftover node holds the MagicDNS name, so the new VM becomes ${INSTANCE}-1
# and `ssh $INSTANCE` quietly targets the dead machine.
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

# --- Sanity: are we authenticated? -------------------------------------
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

# --- Create the state bucket (idempotent) ------------------------------
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

# --- Write backend config + init ---------------------------------------
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
# -input=false: bootstrap runs unattended inside `./run up`, and an init that
# decides to ask something (backend migration, missing variable) must fail with
# the question printed rather than block forever on a stdin nobody is watching.
tf init -input=false

echo ">> Bootstrap complete. Next: make plan && make apply"
