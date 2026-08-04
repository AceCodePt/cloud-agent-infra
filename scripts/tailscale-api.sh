#!/usr/bin/env bash
#
# tailscale-api.sh — talk to the Tailscale API so the rebuild needs no manual
# admin-console steps.
#
# Subcommands:
#   mint          Create a ONE-OFF (single-use), pre-approved auth key, write it
#                 to tailscale.auto.tfvars (auto-loaded by Terraform).
#   check         Assert the auth key Terraform is about to bake in is usable.
#   delete-node   Remove the instance's node (+ any <name>-N duplicate), so the
#                 next build gets the clean MagicDNS name.
#   list          Show the tailnet's devices (read-only).
#
# Auth: TAILSCALE_API_KEY in config.env — a tailnet-ADMIN credential that can
# mint keys and delete devices, so it never reaches the VM; only the minted
# single-use key does. A scoped OAuth client is the better long-term choice.
#
# WARNING: deleting the node of a RUNNING VM orphans it: tailscaled keeps its
# node identity on the data disk, and once the node is gone server-side every
# netmap poll fails `404: node not found` — it can't rejoin without a fresh key.
# cleanup.sh only deletes the node once the instance is verifiably gone.
#
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_config

API="https://api.tailscale.com/api/v2"
KEYFILE="$TF_DIR/tailscale.auto.tfvars"

# How long the minted key stays valid. It is consumed within minutes of the
# apply, so this only bounds the window in which an unused key is useful.
KEY_TTL_SECONDS="${TAILSCALE_KEY_TTL_SECONDS:-86400}"

require_api_key() {
  [[ -n "$API_KEY" ]] || die "TAILSCALE_API_KEY is not set in config.env.
  Create one at https://login.tailscale.com/admin/settings/keys
  (or set TF_VAR_tailscale_auth_key manually and skip this script)."
}

command -v python3 >/dev/null || die "python3 is required."

# api <METHOD> <PATH> [json-body]  -> body on stdout, non-zero on HTTP >= 400
api() {
  local method="$1" path="$2" body="${3:-}"
  local args=(-s -w '\n%{http_code}' -u "$API_KEY:" -X "$method" "$API$path")
  [[ -n "$body" ]] && args+=(-H 'Content-Type: application/json' -d "$body")

  local out code
  out="$(curl "${args[@]}")" || die "curl failed talking to the Tailscale API"
  code="$(printf '%s' "$out" | tail -1)"
  body="$(printf '%s' "$out" | sed '$d')"

  if [[ "$code" -ge 400 ]]; then
    # Map the failures you actually hit to something actionable — a bare
    # "HTTP 401" during bootstrap looks like infrastructure failing.
    case "$code" in
    401)
      die "your Tailscale API key is no good (HTTP 401 Unauthorized).

  TAILSCALE_API_KEY in config.env is expired, revoked, or malformed. Tailscale
  API keys last at most 90 days, and the admin console shows the expiry.

  Fix: mint a new one at https://login.tailscale.com/admin/settings/keys
       then update TAILSCALE_API_KEY in config.env.

  Key currently in use: ${API_KEY:0:14}... (${#API_KEY} chars)"
      ;;
    403)
      die "your Tailscale API key was accepted but is not allowed to do this
  (HTTP 403 Forbidden) on $method $path.

  Most likely it is an OAuth client or scoped key missing the required scope:
  minting keys needs 'auth_keys', deleting nodes needs 'devices' (write).
  Response: $body"
      ;;
    404)
      die "Tailscale API returned 404 for $method $path.
  If this was a device deletion, the node was probably already removed.
  Response: $body"
      ;;
    429)
      die "Tailscale API rate-limited us (HTTP 429). Wait a moment and retry."
      ;;
    *)
      echo "$body" >&2
      die "Tailscale API $method $path returned HTTP $code"
      ;;
    esac
  fi
  printf '%s' "$body"
}

cmd_mint() {
  require_api_key
  echo ">> Minting a one-off auth key (single-use, pre-approved, ${KEY_TTL_SECONDS}s TTL)"

  # reusable=false  -> one-off, as requested
  # ephemeral=false -> the node must survive going offline; ephemeral nodes are
  #                    deleted on disconnect, which would orphan the VM on every
  #                    reboot (see the 404 warning above).
  # preauthorized   -> joins without waiting for manual device approval.
  local req
  req="$(
    python3 - "$KEY_TTL_SECONDS" "$INSTANCE" <<'PY'
import json, sys, datetime
ttl, instance = int(sys.argv[1]), sys.argv[2]
print(json.dumps({
    "capabilities": {"devices": {"create": {
        "reusable": False,
        "ephemeral": False,
        "preauthorized": True,
    }}},
    "expirySeconds": ttl,
    # The API rejects a description containing characters like ':', so keep the
    # timestamp punctuation-free.
    "description": f"{instance} one-off {datetime.datetime.now(datetime.timezone.utc):%Y-%m-%d %H%M} UTC",
}))
PY
  )"

  local resp key id expires
  resp="$(api POST "/tailnet/-/keys" "$req")"
  key="$(printf '%s' "$resp" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("key",""))')"
  id="$(printf '%s' "$resp" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))')"
  expires="$(printf '%s' "$resp" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("expires",""))')"

  [[ "$key" == tskey-auth-* ]] || die "API did not return an auth key (got '${key:0:12}...')"

  # Written as a .auto.tfvars file so a plain `terraform apply` picks it up with
  # no extra flags. *.tfvars is already git-ignored.
  umask 077
  printf 'tailscale_auth_key = "%s"\n' "$key" >"$KEYFILE"
  chmod 600 "$KEYFILE"

  echo ">> Wrote $KEYFILE (mode 600, git-ignored). key id=$id expires=$expires"
}

# The key Terraform will actually use. This MUST mirror Terraform's variable
# precedence, or the check validates a different key than the one that gets baked
# into the VM: *.auto.tfvars outranks TF_VAR_* from the environment.
effective_auth_key() {
  local key=""
  if [[ -f "$KEYFILE" ]]; then
    key="$(sed -nE 's/^[[:space:]]*tailscale_auth_key[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$KEYFILE" | head -1)"
  fi
  printf '%s' "${key:-${TF_VAR_tailscale_auth_key:-}}"
}

# Is $INSTANCE already a member of the tailnet? Prints present|absent|unknown.
#
# Asked over the API rather than the local `tailscale status`, so the answer does
# not depend on this laptop being on the tailnet at the time. Deliberately NOT via
# api(): that dies (exiting the whole script) on any HTTP >= 400, and here an
# unreachable API is a third answer to be reported, not a fatal error.
node_state() {
  local out code body devfile
  out="$(curl -s -w '\n%{http_code}' -u "$API_KEY:" "$API/tailnet/-/devices" 2>/dev/null)" || {
    printf 'unknown'
    return 0
  }
  code="$(printf '%s' "$out" | tail -1)"
  body="$(printf '%s' "$out" | sed '$d')"
  [[ "$code" == 200 ]] || {
    printf 'unknown'
    return 0
  }

  # A temp file, not a pipe: `python3 -` reads the *program* from stdin, so a
  # heredoc program and piped data cannot coexist.
  devfile="$(mktemp)"
  # shellcheck disable=SC2064
  trap "rm -f '$devfile'" RETURN
  printf '%s' "$body" >"$devfile"

  if python3 - "$INSTANCE" "$devfile" <<'PY'
import json, sys
target, path = sys.argv[1], sys.argv[2]
try:
    with open(path) as fh:
        devices = json.load(fh).get("devices", [])
except (ValueError, OSError):
    sys.exit(2)
for d in devices:
    if d.get("name", "").split(".")[0] == target or d.get("hostname") == target:
        sys.exit(0)
sys.exit(1)
PY
  then
    printf 'present'
  elif [[ $? == 2 ]]; then
    printf 'unknown'
  else
    printf 'absent'
  fi
}

# Assert the auth key is usable BEFORE terraform bakes it in: a key revoked or
# spent between mint and apply produces a VM that boots, fails `tailscale up`,
# and is unreachable by design — a five-minute timeout that looks like
# infrastructure rather than a dead credential.
#
# One-off keys are marked invalid the moment they're CONSUMED, so an invalid key
# is only an error when the node still needs it. If $INSTANCE is already on the
# tailnet the spent key is expected — warn, don't die.
cmd_check() {
  local key id
  key="$(effective_auth_key)"

  [[ -n "$key" ]] || die "no Tailscale auth key to check.
  Neither $KEYFILE nor TF_VAR_tailscale_auth_key holds one.
  Fix: ./run mint-key"

  [[ "$key" == tskey-auth-* ]] || die "the auth key does not look like one
  (expected it to start with 'tskey-auth-', got '${key:0:12}...')."

  if [[ -z "$API_KEY" ]]; then
    warn "TAILSCALE_API_KEY is not set, so the auth key cannot be validated.
  Proceeding blind: if it is spent or expired the VM will boot and never join."
    return 0
  fi

  # tskey-auth-<id>-<secret>
  id="$(printf '%s' "$key" | cut -d- -f3)"

  # Deliberately NOT via api(): that dies on 404, and here a 404 is a finding to
  # be interpreted (key unknown to control), not a transport failure.
  local out code body
  out="$(curl -s -w '\n%{http_code}' -u "$API_KEY:" "$API/tailnet/-/keys/$id")" ||
    die "curl failed talking to the Tailscale API"
  code="$(printf '%s' "$out" | tail -1)"
  body="$(printf '%s' "$out" | sed '$d')"

  local status
  case "$code" in
  200)
    status="$(printf '%s' "$body" | python3 -c '
import json, sys
k = json.load(sys.stdin)
if k.get("invalid") or k.get("revoked"):
    print("revoked " + str(k.get("revoked", "")))
else:
    print("valid " + str(k.get("expires", "")))
')"
    ;;
  404) status="missing" ;;
  401 | 403)
    warn "cannot validate the auth key: the Tailscale API returned HTTP $code.
  Proceeding, but fix TAILSCALE_API_KEY — mint-key and delete-node need it too."
    return 0
    ;;
  *)
    warn "cannot validate the auth key: Tailscale API returned HTTP $code.
  Proceeding blind."
    return 0
    ;;
  esac

  if [[ "$status" == valid* ]]; then
    note "auth key $id is valid (expires ${status#valid })"
    return 0
  fi

  # Unusable. Whether that is fatal depends on whether the VM still needs it.
  local node
  node="$(node_state)"
  if [[ "$node" == present ]]; then
    warn "auth key $id is spent/revoked, but '$INSTANCE' is already on the
  tailnet and does not need it (the startup script only spends a key when the
  node is not a member). Continuing."
    return 0
  fi

  local reason source needs
  if [[ "$status" == missing ]]; then
    reason="unknown to Tailscale control (never existed, or purged)"
  else
    reason="revoked or spent at ${status#revoked }"
  fi
  if [[ -f "$KEYFILE" ]]; then source="$KEYFILE"; else source="TF_VAR_tailscale_auth_key in config.env"; fi
  if [[ "$node" == absent ]]; then
    needs="'$INSTANCE' is NOT on the tailnet, so it needs a working key to join."
  else
    needs="Could not reach the Tailscale API to find out whether '$INSTANCE' is
  already on the tailnet, so this refuses to guess."
  fi

  die "the Tailscale auth key Terraform is about to use is NOT usable.

  key id : $id
  state  : $reason
  source : $source

  $needs
  Applying now would build a VM that boots, fails 'tailscale up', and is then
  unreachable (there is no public inbound).

  Fix: ./run mint-key && ./run apply
  Note: revoking a key in the admin console after minting it does exactly this."
}

# Delete the instance's node, plus any <name>-N MagicDNS duplicate a previous
# build left behind.
cmd_delete_node() {
  require_api_key
  local target="${1:-$INSTANCE}"
  echo ">> Looking for tailnet nodes matching '$target'"

  # The device list goes to a temp file rather than a pipe: `python3 -` reads the
  # *program* from stdin, so a heredoc program and piped data cannot coexist.
  local devfile
  devfile="$(mktemp)"
  # shellcheck disable=SC2064
  trap "rm -f '$devfile'" RETURN
  api GET "/tailnet/-/devices" >"$devfile"

  local matches
  matches="$(
    python3 - "$target" "$devfile" <<'PY'
import json, re, sys
target, path = sys.argv[1], sys.argv[2]
with open(path) as fh:
    data = json.load(fh)
# MagicDNS may suffix duplicates: cloud-agent-1, cloud-agent-2, ...
pat = re.compile(rf"^{re.escape(target)}(-\d+)?$")
for d in data.get("devices", []):
    label = d.get("name", "").split(".")[0]
    if pat.match(label) or d.get("hostname") == target:
        print(d["id"], label)
PY
  )"

  if [[ -z "$matches" ]]; then
    echo ">> No node named '$target' in the tailnet. Nothing to delete."
    return 0
  fi

  while read -r id label; do
    [[ -n "$id" ]] || continue
    echo ">> Deleting node $label (id=$id)"
    api DELETE "/device/$id" >/dev/null
  done <<<"$matches"
  echo ">> Node deletion complete."
}

cmd_list() {
  require_api_key
  api GET "/tailnet/-/devices" | python3 -c '
import json,sys
for d in json.load(sys.stdin).get("devices", []):
    print(f'"'"'{d["id"]:>18}  {d.get("name","")}  last_seen={d.get("lastSeen","")}'"'"')
'
}

case "${1:-}" in
mint) cmd_mint ;;
check) cmd_check ;;
delete-node) cmd_delete_node "${2:-}" ;;
list) cmd_list ;;
*)
  echo "Usage: $0 {mint|check|delete-node [name]|list}" >&2
  exit 1
  ;;
esac
