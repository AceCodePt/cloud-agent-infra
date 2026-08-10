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

if [[ "$PROVIDER" == hetzner || "$PROVIDER" == oci ]]; then
  STATUS="$(instance_status)"
  if [[ "$STATUS" == absent ]]; then
    die "instance '$INSTANCE' does not exist, so there is nothing to rekey.
  For a fresh build use: ./run rebuild"
  fi
  if [[ "$STATUS" == unknown ]]; then
    die "cannot reach the $([[ "$PROVIDER" == oci ]] && echo OCI || echo Hetzner) API. Check the credentials in config.env."
  fi

  "$SCRIPT_DIR"/tailscale-api.sh mint
  "$SCRIPT_DIR"/tailscale-api.sh check

  KEY="$(sed -nE 's/^[[:space:]]*tailscale_auth_key[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$TF_DIR/tailscale.auto.tfvars" | head -1)"
  [[ -n "$KEY" ]] || die "minted key not found in $TF_DIR/tailscale.auto.tfvars"

  note "delivering the fresh key to $INSTANCE and re-running phase A"
  if ! ssh_vm bash -s <<EOF
sudo mkdir -p /etc/agent
printf '%s' '$KEY' | sudo tee /etc/agent/authkey >/dev/null
sudo chmod 600 /etc/agent/authkey
sudo systemctl restart agent-startup
EOF
  then
    die "could not reach $SSH_USER@$INSTANCE over the tailnet to deliver the key.
  If the box is not online, use the OCI serial console to write /etc/agent/authkey,
  or rebuild with: ./run rebuild"
  fi

  "$SCRIPT_DIR"/wait-ready.sh
  note "Rekey complete. Next: ./run verify"
  exit 0
fi

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
