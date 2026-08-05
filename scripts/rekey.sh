#!/usr/bin/env bash
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

"$SCRIPT_DIR"/tailscale-api.sh mint

"$SCRIPT_DIR"/tailscale-api.sh check

note "terraform apply (updates startup-script metadata; the guest does NOT re-read it yet)"
tf apply -auto-approve

rerun_startup_script "$METHOD" ||
  die "could not re-run the startup script over IAP.
  If this is a permissions or OS Login problem rather than a broken VM, retry
  with the transport that needs nothing but the Compute API:
    ./run rekey --reboot"

"$SCRIPT_DIR"/wait-ready.sh

note "Rekey complete. Next: ./run verify"
