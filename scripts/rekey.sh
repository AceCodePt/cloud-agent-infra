#!/usr/bin/env bash
#
# rekey.sh — get a working Tailscale auth key into a VM that already exists.
#
# Why this is its own command: `terraform apply` cannot do it. The auth key is
# delivered through the `startup-script` metadata value, and GCE only runs
# startup-script at BOOT. Applying a fresh key against a running instance is a
# metadata-only update ("0 to add, 1 to change, 0 to destroy") that the guest
# never reads, so nothing consumes the key and nothing joins the tailnet. The
# apply looks completely successful.
#
# So the key has to be pushed AND the startup script re-triggered:
#
#   1. mint a fresh one-off key      (tailscale-api.sh mint)
#   2. terraform apply               (bakes it into instance metadata)
#   3. re-run the startup script     (the guest finally reads it)
#   4. wait until the node is up     (wait-ready.sh)
#
# Step 3 goes over `gcloud compute ssh --tunnel-through-iap`, deliberately: the
# whole point of running this is that Tailscale is broken, so the tailnet is not
# available as a transport. IAP is the break-glass path the firewall keeps open
# for exactly this (network.tf), and re-running the startup script means the key
# is read from metadata rather than passed on a command line.
#
# --reboot uses a stop/start instead. Slower (~3 min of downtime) but it depends
# on nothing but the Compute API, so it is the fallback when IAP is unavailable
# (missing roles/iap.tunnelResourceAccessor, org policy, no OS Login).
#
# Idempotent, and safe on a HEALTHY box: the startup script only spends a key
# when the node is not already a tailnet member, so a rekey against a working VM
# just re-asserts --ssh and leaves the fresh key unspent.
#
# Usage:
#   ./run rekey             push a fresh key and re-run startup over IAP
#   ./run rekey --reboot    push a fresh key and stop/start the VM instead
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

# --- 1. Fresh key ---------------------------------------------------------
"$SCRIPT_DIR"/tailscale-api.sh mint

# Confirm the key we just minted is actually live before spending any effort on
# it — a key revoked between mint and apply is exactly the failure this command
# exists to recover from, so don't reproduce it here.
"$SCRIPT_DIR"/tailscale-api.sh check

# --- 2. Push it into instance metadata ------------------------------------
note "terraform apply (updates startup-script metadata; the guest does NOT re-read it yet)"
tf apply -auto-approve

# --- 3. Make the guest actually run it ------------------------------------
rerun_startup_script "$METHOD" ||
  die "could not re-run the startup script over IAP.
  If this is a permissions or OS Login problem rather than a broken VM, retry
  with the transport that needs nothing but the Compute API:
    ./run rekey --reboot"

# --- 4. Confirm ------------------------------------------------------------
"$SCRIPT_DIR"/wait-ready.sh

note "Rekey complete. Next: ./run verify"
