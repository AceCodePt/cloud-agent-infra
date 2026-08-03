# lib.sh — shared plumbing for the scripts in this directory.
#
# Sourced, never executed. Every script starts with:
#
#   source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
#
# which cd's to the repo root, so the scripts work from any directory and
# Terraform always runs where the .tf files live.

# --- Repo root -----------------------------------------------------------
# All Terraform state, config.env and tailscale.auto.tfvars are resolved
# relative to the repo root, never to the caller's cwd.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$REPO_ROOT/scripts"
TF_DIR="$REPO_ROOT/terraform"
cd "$REPO_ROOT" || exit 1

# --- Output --------------------------------------------------------------
die() {
  echo "ERROR: $*" >&2
  exit 1
}
note() { echo ">> $*"; }
warn() { echo ">> WARNING: $*" >&2; }

# --- Config --------------------------------------------------------------
# config.env is the single source of truth. CONFIG_ENV can point at a different
# file (handy for testing an alternate/broken config without touching the real
# one) — note that values in the file win over the surrounding environment.
load_config() {
  local file="${CONFIG_ENV:-config.env}"
  [[ -f "$file" ]] || die "$file not found. Copy example.config.env and fill it in."
  # `set -a` is load-bearing: terraform reads TF_VAR_* from the ENVIRONMENT, and
  # config.env assigns without `export`. Without this, terraform only works in a
  # shell where direnv (or the caller) happened to export them — so a plain
  # `./scripts/cleanup.sh` would fail on "No value for required variable".
  set -a
  # shellcheck disable=SC1090
  source "$file"
  set +a

  PROJECT_ID="${TF_VAR_project_id:?project_id not set in $file}"
  REGION="${TF_VAR_region:-me-west1}"
  ZONE="${TF_VAR_zone:-me-west1-a}"
  INSTANCE="${TF_VAR_instance_name:-cloud-agent}"
  SSH_USER="${TF_VAR_ssh_user:-$USER}"
  STATE_BUCKET="${PROJECT_ID}-tf-state"
  API_KEY="${TAILSCALE_API_KEY:-}"
}

# --- Terraform -----------------------------------------------------------
# Every terraform invocation goes through this wrapper. The .tf files live in
# terraform/ while config.env stays at the repo root; -chdir makes terraform
# treat that directory as its working dir, so backend.tf, the state, .terraform/
# and *.auto.tfvars are all found there without anyone having to cd around.
tf() { terraform -chdir="$TF_DIR" "$@"; }

# Effective value of a Terraform output. config.env only sets what it overrides,
# so the variable *defaults* (e.g. termux_host) are only knowable via Terraform.
# Silent when the state isn't initialised yet.
tf_out() { tf output -raw "$1" 2>/dev/null || true; }

# Resolve phone connection details: config.env first, then Terraform defaults.
load_phone_config() {
  PHONE_HOST="${TF_VAR_termux_host:-$(tf_out termux_host)}"
  PHONE_USER="${TF_VAR_termux_ssh_user:-$(tf_out termux_ssh_user)}"
  PHONE_PORT="${TF_VAR_termux_ssh_port:-$(tf_out termux_ssh_port)}"
  PHONE_PORT="${PHONE_PORT:-8022}"
}

# --- SSH -----------------------------------------------------------------
# accept-new, not the default "ask": a rebuilt VM presents a NEW host key, and
# under BatchMode "ask" simply refuses an unknown host. accept-new still refuses
# a *changed* key, which is the case worth surfacing loudly.
SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)

ssh_vm() { ssh "${SSH_OPTS[@]}" "$SSH_USER@$INSTANCE" "$@"; }
ssh_phone() { ssh "${SSH_OPTS[@]}" -p "$PHONE_PORT" "$PHONE_USER@$PHONE_HOST" "$@"; }

# --- Tailnet -------------------------------------------------------------
# Is $INSTANCE ONLINE in the tailnet right now, as seen from this machine?
#
# Deliberately reads the Online flag out of --json rather than grepping plain
# `tailscale status`, which lists offline peers too. The distinction is the whole
# point here: a node record that exists but is offline means the VM holds a
# tailnet identity yet has no connectivity, which needs a different fix than a
# VM that was never registered at all.
vm_online() {
  command -v tailscale >/dev/null 2>&1 || return 1
  tailscale status --json 2>/dev/null | python3 -c '
import json, sys
target = sys.argv[1]
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
for p in d.get("Peer", {}).values():
    if p.get("DNSName", "").split(".")[0] == target:
        sys.exit(0 if p.get("Online") else 1)
sys.exit(1)
' "$INSTANCE"
}

# --- Guest -------------------------------------------------------------
# Re-run the guest's startup script.
#
# This is the only way to get a new auth key into a VM that already exists: the
# key travels in `startup-script` metadata and GCE runs that at boot only, so a
# `terraform apply` reports success while the guest never re-reads it.
#
#   rerun_startup_script iap     over `gcloud compute ssh --tunnel-through-iap`
#   rerun_startup_script reboot  stop/start the instance instead
#
# IAP is the default precisely because the reason for calling this is usually
# that Tailscale is broken, so the tailnet is not available as a transport. The
# script is read from metadata, so no key is ever passed on a command line.
# `reboot` needs nothing but the Compute API, so it is the fallback when IAP is
# unavailable (missing roles/iap.tunnelResourceAccessor, org policy, no OS Login).
rerun_startup_script() {
  local method="${1:-iap}"
  if [[ "$method" == reboot ]]; then
    note "stop/start $INSTANCE so the startup script re-runs"
    gcloud_instance stop
    gcloud_instance start
    return 0
  fi

  note "re-running the startup script over IAP (no reboot)"
  # NOT ssh_vm: that goes over the tailnet, which is the thing being repaired.
  gcloud compute ssh "$INSTANCE" \
    --zone "$ZONE" --project "$PROJECT_ID" --tunnel-through-iap \
    --command 'sudo google_metadata_script_runner startup'
}

# --- GCP -----------------------------------------------------------------
gcloud_instance() {
  gcloud compute instances "$1" "$INSTANCE" --zone "$ZONE" --project "$PROJECT_ID" "${@:2}"
}

# RUNNING | TERMINATED | STOPPING | ... | absent | unknown.
# Never fails, so callers can branch on the answer instead of on an exit code.
#
# "absent" and "unknown" are deliberately different answers. Collapsing an error
# into "absent" is how a broken gcloud credential comes to look like a deleted
# VM: terraform keeps working (it authenticates separately, via ADC) while every
# gcloud call 403s, and a caller that trusts "absent" will happily decide the
# instance needs creating.
instance_status() {
  local out err rc=0
  err="$(mktemp)"
  out="$(gcloud_instance describe --format='value(status)' 2>"$err")" || rc=$?

  if [[ "$rc" -eq 0 && -n "$out" ]]; then
    rm -f "$err"
    printf '%s' "$out"
    return 0
  fi
  if grep -qiE 'was not found|notFound|does not exist' "$err"; then
    rm -f "$err"
    printf 'absent'
    return 0
  fi
  rm -f "$err"
  printf 'unknown'
}

# Why a gcloud call just failed, in the terms that actually explain it.
#
# The gcloud CLI and Terraform authenticate SEPARATELY: terraform uses
# application-default credentials, gcloud uses its own active account. They drift
# apart the moment you `gcloud config set account` or log in a second identity,
# and the result is genuinely confusing — terraform builds the VM while every
# gcloud-based check insists it does not exist.
gcloud_identity_hint() {
  cat <<EOF
  gcloud account : $(gcloud config get-value account 2>/dev/null || echo '(none)')
  gcloud project : $(gcloud config get-value project 2>/dev/null || echo '(none)')
  wanted project : $PROJECT_ID

  Terraform authenticates separately (application-default credentials), so it can
  keep working while gcloud cannot see the project at all.

  Fix by pointing gcloud at the right identity and project:
    gcloud config set account <the account that owns $PROJECT_ID>
    gcloud config set project $PROJECT_ID
  Check who is available with:  gcloud auth list
EOF
}

# Ground truth, independent of Terraform state: what still exists in GCP?
live_resources() {
  local live=""
  gcloud compute instances describe "$INSTANCE" --zone "$ZONE" \
    --project "$PROJECT_ID" >/dev/null 2>&1 && live="$live instance/$INSTANCE"
  gcloud compute disks describe "${INSTANCE}-data" --zone "$ZONE" \
    --project "$PROJECT_ID" >/dev/null 2>&1 && live="$live disk/${INSTANCE}-data"
  printf '%s' "${live# }"
}
