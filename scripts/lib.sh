REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$REPO_ROOT/scripts"
PROVIDER_DIR="$REPO_ROOT/terraform"
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

  PROVIDER="${PROVIDER:-gcp}"
  PROJECT_ID="${TF_VAR_project_id:-}"
  REGION="${TF_VAR_region:-me-west1}"
  ZONE="${TF_VAR_zone:-me-west1-a}"
  INSTANCE="${TF_VAR_instance_name:-cloud-agent}"
  SSH_USER="${TF_VAR_ssh_user:-$USER}"
  STATE_BUCKET="${PROJECT_ID}-tf-state"
  API_KEY="${TAILSCALE_API_KEY:-}"
  HZ_API_KEY="${HETZNER_API_KEY:-}"
  HZ_OBJECT_ACCESS_KEY="${HETZNER_OBJECT_ACCESS_KEY:-}"
  HZ_OBJECT_SECRET_KEY="${HETZNER_OBJECT_SECRET_KEY:-}"
  HZ_OBJECT_BUCKET="${TF_STATE_BUCKET:-}"
  HZ_OBJECT_REGION="${HZ_OBJECT_REGION:-nbg1}"

  # OCI (Oracle Cloud Infrastructure) credentials for Terraform.
  OCI_TENANCY_OCID="${OCI_TENANCY_OCID:-}"
  OCI_USER_OCID="${OCI_USER_OCID:-}"
  OCI_FINGERPRINT="${OCI_FINGERPRINT:-}"
  OCI_PRIVATE_KEY_PATH="${OCI_PRIVATE_KEY_PATH:-}"

  # Terraform's s3 backend authenticates through the standard AWS credential
  # chain, so expose the Hetzner Object Storage keys under those env vars.
  if [[ -n "$HZ_OBJECT_ACCESS_KEY" ]]; then
    export AWS_ACCESS_KEY_ID="$HZ_OBJECT_ACCESS_KEY"
    export AWS_SECRET_ACCESS_KEY="$HZ_OBJECT_SECRET_KEY"
  fi

  case "$PROVIDER" in
  gcp | hetzner | oci) ;;
  *) die "unknown PROVIDER '$PROVIDER' in $file (want gcp, hetzner or oci)" ;;
  esac

  # OCI Terraform reads credentials from TF_VAR_* env vars (config.env holds the
  # OCI_* spellings; lib.sh maps them).
  if [[ "$PROVIDER" == oci ]]; then
    export TF_VAR_tenancy_ocid="$OCI_TENANCY_OCID"
    export TF_VAR_user_ocid="$OCI_USER_OCID"
    export TF_VAR_fingerprint="$OCI_FINGERPRINT"
    export TF_VAR_private_key_path="$OCI_PRIVATE_KEY_PATH"
  fi

  # One Terraform root module per provider: terraform/<provider>/.
  TF_DIR="$PROVIDER_DIR/$PROVIDER"
}

tf() { terraform -chdir="$TF_DIR" "$@"; }

SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)

ssh_vm() { ssh "${SSH_OPTS[@]}" "$SSH_USER@$INSTANCE" "$@"; }

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

# --- Hetzner helpers (used only when PROVIDER=hetzner) ---

HZ_BASE="https://api.hetzner.cloud/v1"

require_hz_key() {
  [[ -n "$HZ_API_KEY" ]] || die "HETZNER_API_KEY is not set in config.env.
  Create one in the Hetzner Cloud console: Project -> Security -> API Tokens."
}

hz_api() { # method path [body]
  local method="$1" path="$2" body="${3:-}"
  require_hz_key
  local args=(-s -H "Authorization: Bearer $HZ_API_KEY")
  [[ -n "$body" ]] && args+=(-H 'Content-Type: application/json' -d "$body")
  curl "${args[@]}" -X "$method" "$HZ_BASE$path"
}

hz_server_json() {
  hz_api GET "/servers?name=$INSTANCE"
}

hz_server_id() {
  hz_server_json | jq -r '.servers[0].id // empty' 2>/dev/null
}

hz_server_status() {
  local resp
  resp="$(hz_server_json)" || { printf 'unknown'; return 0; }
  if [[ "$(printf '%s' "$resp" | jq -r '.servers | length')" == 0 ]]; then
    printf 'absent'
    return 0
  fi
  case "$(printf '%s' "$resp" | jq -r '.servers[0].status')" in
  running) printf 'RUNNING' ;;
  off) printf 'TERMINATED' ;;
  starting | stopping | rebuilding | initializing) printf 'STARTING' ;;
  *) printf 'unknown' ;;
  esac
}

hz_server_start() {
  local id
  id="$(hz_server_id)"
  [[ -n "$id" ]] || die "no server named '$INSTANCE' in the Hetzner project"
  hz_api POST "/servers/$id/actions/poweron" >/dev/null
}

hz_server_stop() {
  local id
  id="$(hz_server_id)"
  [[ -n "$id" ]] || die "no server named '$INSTANCE' in the Hetzner project"
  hz_api POST "/servers/$id/actions/poweroff" >/dev/null
}

hz_live_resources() {
  local live=""
  hz_server_json | jq -e '.servers | length > 0' >/dev/null 2>&1 && live="$live server/$INSTANCE"
  hz_api GET "/volumes?name=${INSTANCE}-data" | jq -e '.volumes | length > 0' >/dev/null 2>&1 && live="$live volume/${INSTANCE}-data"
  printf '%s' "${live# }"
}

# Asserts the repo's "no public inbound" posture on Hetzner: the firewall must
# have NO inbound rule at all (the applied posture is an empty rule set, so any
# "in" rule is drift). Prints exactly 'none' when the posture holds; anything
# else fails the assertion. A server with NO firewall applied is a violation
# (Hetzner default is all-inbound-open), not a pass.
hz_public_ingress() {
  local resp ids fw name
  resp="$(hz_server_json)"
  ids="$(printf '%s' "$resp" | jq -r '.servers[0].public_net.firewalls[].id // empty' 2>/dev/null)"
  if [[ -z "$ids" ]]; then
    printf 'no firewall applied to server'
    return 0
  fi
  while read -r fwid; do
    [[ -n "$fwid" ]] || continue
    fw="$(hz_api GET "/firewalls/$fwid")"
    if printf '%s' "$fw" | jq -e '.firewall.rules[]? | select(.direction == "in")' >/dev/null 2>&1; then
      name="$(printf '%s' "$fw" | jq -r '.firewall.name // "unknown"')"
      printf 'open rule on firewall %s' "$name"
      return 0
    fi
  done <<<"$ids"
  printf 'none'
}

# --- OCI helpers (used only when PROVIDER=oci) ---

require_oci_key() {
  [[ -n "$OCI_TENANCY_OCID" && -n "$OCI_USER_OCID" && -n "$OCI_FINGERPRINT" ]] ||
    die "OCI credentials are not set in config.env.
  Set OCI_TENANCY_OCID, OCI_USER_OCID, OCI_FINGERPRINT and OCI_PRIVATE_KEY_PATH."
  [[ -n "$OCI_PRIVATE_KEY_PATH" && -f "$OCI_PRIVATE_KEY_PATH" ]] ||
    die "OCI_PRIVATE_KEY_PATH=$OCI_PRIVATE_KEY_PATH is not a file.
  Generate the key pair with: openssl genrsa -out ~/.oci/oci_api_key.pem 2048
  then upload the public key in the OCI console (User -> API Keys)."
  command -v oci >/dev/null 2>&1 ||
    die "oci CLI is not installed. Install it with: pip3 install oci-cli"
}

# oci_json <args...> — runs `oci` and emits stdout on success, nothing on
# failure (so `$(...)` yields empty and the caller can decide what that means).
oci_json() {
  require_oci_key
  oci "$@" --compartment-id "$OCI_TENANCY_OCID" 2>/dev/null || true
}

oci_instances_json() {
  oci_json compute instance list --all
}

oci_find_instance() {
  oci_instances_json | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
target = sys.argv[1]
# Prefer a live instance over stale TERMINATED records (multiple rebuilds
# leave many cloud-agent entries with the same display name behind).
best = ""
for i in d.get("data", []):
    if i.get("display-name") != target:
        continue
    state = i.get("lifecycle-state", "")
    if state == "RUNNING":
        print(i.get("id", ""))
        sys.exit(0)
    if not best and state != "TERMINATED":
        best = i.get("id", "")
if best:
    print(best)
    sys.exit(0)
sys.exit(1)
' "$INSTANCE"
}

# OCI lifecycle states: PROVISIONING, STARTING, RUNNING, STOPPING, STOPPED,
# TERMINATING, TERMINATED. Map to the repo's RUNNING/TERMINATED/absent strings.
oci_instance_status() {
  local resp id state
  id="$(oci_find_instance)"
  if [[ -z "$id" ]]; then
    printf 'absent'
    return 0
  fi
  resp="$(oci compute instance get --instance-id "$id" 2>/dev/null)" || {
    printf 'unknown'
    return 0
  }
  state="$(printf '%s' "$resp" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("data",{}).get("lifecycle-state",""))' 2>/dev/null)"
  case "$state" in
  RUNNING) printf 'RUNNING' ;;
  STOPPED | TERMINATED) printf 'TERMINATED' ;;
  PROVISIONING | STARTING | STOPPING | TERMINATING) printf 'STARTING' ;;
  *) printf 'unknown' ;;
  esac
}

oci_instance_start() {
  local id
  id="$(oci_find_instance)"
  [[ -n "$id" ]] || die "no instance named '$INSTANCE' in the tenancy"
  oci compute instance action --instance-id "$id" --action START >/dev/null
}

oci_instance_stop() {
  local id
  id="$(oci_find_instance)"
  [[ -n "$id" ]] || die "no instance named '$INSTANCE' in the tenancy"
  oci compute instance action --instance-id "$id" --action SOFTSTOP >/dev/null
}

oci_live_resources() {
  local live=""
  local id
  id="$(oci_find_instance)"
  [[ -n "$id" ]] && live="$live instance/$INSTANCE"
  oci_json bv volume list --all 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
target = sys.argv[1]
for v in d.get("data", []):
    if v.get("display-name") == target:
        print("volume/" + target)
' "${INSTANCE}-data" | while read -r v; do live="$live $v"; done
  printf '%s' "${live# }"
}

# Asserts the repo's "no public inbound" posture on OCI: the instance must have
# NO public IP and the subnet security list must have NO ingress rules. Prints
# exactly 'none' when the posture holds; anything else fails the assertion.
oci_public_ingress() {
  local id subnet sl
  id="$(oci_find_instance)"
  [[ -n "$id" ]] || { printf 'no instance found'; return 0; }

  local pub
  pub="$(oci compute instance list-vnics --instance-id "$id" 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for v in d.get("data", []):
    if v.get("public-ip"):
        print(v.get("public-ip"))
        sys.exit(0)
sys.exit(0)
' 2>/dev/null)"
  if [[ -n "$pub" ]]; then
    printf 'instance has a public IP (%s)' "$pub"
    return 0
  fi

  subnet="$(oci compute instance list-vnics --instance-id "$id" 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for v in d.get("data", []):
    if v.get("subnet-id"):
        print(v.get("subnet-id"))
        sys.exit(0)
sys.exit(0)
' 2>/dev/null)"
  [[ -n "$subnet" ]] || { printf 'could not read instance subnet'; return 0; }

  sl="$(oci network subnet get --subnet-id "$subnet" 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
sls = d.get("data", {}).get("security-list-ids", [])
for s in sls:
    print(s)
' 2>/dev/null | head -1)"
  [[ -n "$sl" ]] || { printf 'could not read security list'; return 0; }

  oci network security-list get --security-list-id "$sl" 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
rules = d.get("data", {}).get("ingress-security-rules", [])
print("open ingress rule" if rules else "none")
'
}

# --- provider dispatch ---

instance_status() {
  if [[ "$PROVIDER" == hetzner ]]; then
    hz_server_status
  elif [[ "$PROVIDER" == oci ]]; then
    oci_instance_status
  else
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
  fi
}

instance_start() {
  if [[ "$PROVIDER" == hetzner ]]; then
    hz_server_start
  elif [[ "$PROVIDER" == oci ]]; then
    oci_instance_start
  else
    gcloud_instance start
  fi
}

instance_stop() {
  if [[ "$PROVIDER" == hetzner ]]; then
    hz_server_stop
  elif [[ "$PROVIDER" == oci ]]; then
    oci_instance_stop
  else
    gcloud_instance stop
  fi
}

# Re-run phase A. On gcp this is the metadata runner (IAP) or a stop/start; on
# hetzner the guest re-runs itself via systemd — no cloud vendor mechanism.
rerun_startup_script() {
  local method="${1:-ssh}"
  if [[ "$PROVIDER" == hetzner ]]; then
    if [[ "$method" == reboot ]]; then
      note "stop/start $INSTANCE so agent-startup re-runs"
      instance_stop
      sleep 3
      instance_start
      return 0
    fi
    note "re-running phase A via systemd (no reboot)"
    ssh_vm 'sudo systemctl restart agent-startup'
    return 0
  fi

  if [[ "$PROVIDER" == oci ]]; then
    if [[ "$method" == reboot ]]; then
      note "stop/start $INSTANCE so agent-startup re-runs"
      instance_stop
      sleep 3
      instance_start
      return 0
    fi
    note "re-running phase A via systemd (no reboot)"
    ssh_vm 'sudo systemctl restart agent-startup'
    return 0
  fi

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
  if [[ "$PROVIDER" == hetzner ]]; then
    hz_live_resources
    return 0
  fi

  if [[ "$PROVIDER" == oci ]]; then
    oci_live_resources
    return 0
  fi

  local live=""
  gcloud compute instances describe "$INSTANCE" --zone "$ZONE" \
    --project "$PROJECT_ID" >/dev/null 2>&1 && live="$live instance/$INSTANCE"
  gcloud compute disks describe "${INSTANCE}-data" --zone "$ZONE" \
    --project "$PROJECT_ID" >/dev/null 2>&1 && live="$live disk/${INSTANCE}-data"
  printf '%s' "${live# }"
}
