#!/usr/bin/env bash
#
# rekey.sh — get a working Tailscale auth key into a VM that already exists.
#
# Why its own command: `terraform apply` cannot do it. The key travels in
# startup-script metadata, which GCE reads at boot only — against a running
# instance, apply is a metadata-only change the guest never reads. So: mint →
# apply → re-run the startup script → wait. Step 3 goes over IAP deliberately
# (the reason to rekey is usually that Tailscale is broken); --reboot uses a
# stop/start instead, needing only the Compute API.
#
# Idempotent, safe on a HEALTHY box: the startup script only spends a key when
# the node is not already a tailnet member.
#
# Usage: ./run rekey [--reboot]
#
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_config

METHOD="iap"
while [[ $# -gt 0 ]]; do
  case "$1" in
  --reboot) METHOD="reboot" ;;
  -h | --help)
    echo "Usage: ./run rekey [--reboot]"
    exit 0
    ;;
  *) die "unknown flag: $1 (try --reboot)" ;;
  esac
  shift
done

gcloud compute instances describe "$INSTANCE" --zone "$ZONE" --project "$PROJECT_ID" \
  >/dev/null 2>&1 ||
  die "instance '$INSTANCE' does not exist, so there is nothing to rekey.
  For a fresh build use: ./run rebuild"

# 1. Fresh key
"$SCRIPT_DIR"/tailscale-api.sh mint

# Confirm the key is live before spending effort — a key revoked between mint
# and apply is exactly the failure this command exists to recover from.
"$SCRIPT_DIR"/tailscale-api.sh check

# 2. Push it into instance metadata (guest does NOT re-read it yet)
note "terraform apply (updates startup-script metadata; the guest does NOT re-read it yet)"
tf apply -auto-approve

# 3. Make the guest actually run it
rerun_startup_script "$METHOD" ||
  die "could not re-run the startup script over IAP.
  If this is a permissions or OS Login problem rather than a broken VM, retry
  with the transport that needs nothing but the Compute API:
    ./run rekey --reboot"

# 4. Confirm
"$SCRIPT_DIR"/wait-ready.sh

note "Rekey complete. Next: ./run verify"
