REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$REPO_ROOT/scripts"
TF_DIR="$REPO_ROOT/terraform"
cd "$REPO_ROOT" || exit 1

die() {
  echo "ERROR: $*" >&2
  exit 1
}
note() { echo ">> $*"; }
warn() { echo ">> WARNING: $*" >&2; }

load_config() {
  local file="${CONFIG_ENV:-config.env}"
  [[ -f "$file" ]] || die "$file not found. Copy example.config.env and fill it in."
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

tf() { terraform -chdir="$TF_DIR" "$@"; }

tf_out() { tf output -raw "$1" 2>/dev/null || true; }

load_phone_config() {
  PHONE_HOST="${TF_VAR_termux_host:-$(tf_out termux_host)}"
  PHONE_USER="${TF_VAR_termux_ssh_user:-$(tf_out termux_ssh_user)}"
  PHONE_PORT="${TF_VAR_termux_ssh_port:-$(tf_out termux_ssh_port)}"
  PHONE_PORT="${PHONE_PORT:-8022}"
}

SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)

ssh_vm() { ssh "${SSH_OPTS[@]}" "$SSH_USER@$INSTANCE" "$@"; }
ssh_phone() { ssh "${SSH_OPTS[@]}" -p "$PHONE_PORT" "$PHONE_USER@$PHONE_HOST" "$@"; }

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

rerun_startup_script() {
  local method="${1:-iap}"
  if [[ "$method" == reboot ]]; then
    note "stop/start $INSTANCE so the startup script re-runs"
    gcloud_instance stop
    gcloud_instance start
    return 0
  fi

  note "re-running the startup script over IAP (no reboot)"
  gcloud compute ssh "$INSTANCE" \
    --zone "$ZONE" --project "$PROJECT_ID" --tunnel-through-iap \
    --command 'sudo google_metadata_script_runner startup'
}

gcloud_instance() {
  gcloud compute instances "$1" "$INSTANCE" --zone "$ZONE" --project "$PROJECT_ID" "${@:2}"
}

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

live_resources() {
  local live=""
  gcloud compute instances describe "$INSTANCE" --zone "$ZONE" \
    --project "$PROJECT_ID" >/dev/null 2>&1 && live="$live instance/$INSTANCE"
  gcloud compute disks describe "${INSTANCE}-data" --zone "$ZONE" \
    --project "$PROJECT_ID" >/dev/null 2>&1 && live="$live disk/${INSTANCE}-data"
  printf '%s' "${live# }"
}
