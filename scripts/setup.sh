#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_config

want="${1:-all}"

ok() { printf '  [x] %-42s %s\n' "$1" "${2:-}"; }
miss() { printf '  [ ] %-42s %s\n' "$1" "${2:-}"; }

tool() { command -v "$1" >/dev/null 2>&1; }
toolver() { command -v "$1" >/dev/null 2>&1 && "$1" version 2>/dev/null | head -1 | cut -c1-40 || echo "(missing)"; }

section() { printf '\n\033[1m%s\033[0m\n' "$1"; }
line() { printf '  %s\n' "$1"; }

tools_section() {
  section "Tooling (host)"
  if tool terraform; then ok "terraform" "$(toolver terraform)"; else miss "terraform" "install from https://developer.hashicorp.com/terraform/install"; fi
  if tool jq; then ok "jq"; else miss "jq" "apt install jq"; fi
  if tool curl; then ok "curl"; else miss "curl" "apt install curl"; fi
  if tool tailscale; then ok "tailscale" "(used for vm_online checks)"; else miss "tailscale" "optional on this host"; fi
  if tool gcloud; then ok "gcloud"; else miss "gcloud" "needed only if PROVIDER=gcp"; fi
  if tool oci; then ok "oci"; else miss "oci" "needed only if PROVIDER=oci (pip3 install oci-cli)"; fi
  section "Next"
  line "  ./run bootstrap   # state backend + init + mint tailscale auth key"
  line "  ./run up          # converge + verify"
}

shared_requirements() {
  section "Shared (both providers)"
  if [[ -n "${TF_VAR_instance_name:-}" ]]; then ok "TF_VAR_instance_name" "$TF_VAR_instance_name"; else miss "TF_VAR_instance_name" "instance name"; fi
  if [[ -n "${TF_VAR_ssh_user:-}" ]]; then ok "TF_VAR_ssh_user" "$TF_VAR_ssh_user"; else miss "TF_VAR_ssh_user" "account on the VM"; fi
  if [[ -n "${TF_VAR_machine_type:-}" ]]; then ok "TF_VAR_machine_type" "$TF_VAR_machine_type"; else miss "TF_VAR_machine_type" "e.g. cx33 (hetzner) / e2-standard-2 (gcp) / VM.Standard.A1.Flex (oci)"; fi
  if [[ -n "${TAILSCALE_API_KEY:-}" ]]; then
    ok "TAILSCALE_API_KEY" "mints single-use auth keys: login.tailscale.com/admin/settings/keys"
  else
    miss "TAILSCALE_API_KEY" "required: no key -> VM never joins tailnet -> unreachable"
  fi
}

oci_section() {
  section "Provider: oci  (terraform/oci/)"
  if [[ -n "${OCI_TENANCY_OCID:-}" ]]; then ok "OCI_TENANCY_OCID" "tenancy OCID"; else miss "OCI_TENANCY_OCID" "tenancy OCID"; fi
  if [[ -n "${OCI_USER_OCID:-}" ]]; then ok "OCI_USER_OCID" "user OCID"; else miss "OCI_USER_OCID" "user OCID"; fi
  if [[ -n "${OCI_FINGERPRINT:-}" ]]; then ok "OCI_FINGERPRINT" "API key fingerprint"; else miss "OCI_FINGERPRINT" "API key fingerprint"; fi
  if [[ -n "${OCI_PRIVATE_KEY_PATH:-}" && -f "${OCI_PRIVATE_KEY_PATH:-}" ]]; then
    ok "OCI_PRIVATE_KEY_PATH" "$OCI_PRIVATE_KEY_PATH"
  else
    miss "OCI_PRIVATE_KEY_PATH" "path to the API private key PEM (~/.oci/oci_api_key.pem)"
  fi
  if [[ -n "${TF_VAR_region:-}" ]]; then ok "TF_VAR_region" "$TF_VAR_region (home region hosts Always Free capacity)"; else miss "TF_VAR_region" "region"; fi
  line "  Security posture: private subnet (NO public IPv4) + NAT for outbound only;"
  line "  public ingress is exactly IPv6 UDP 41641 (Tailscale direct path)."
  line "  SSH only via Tailscale; data on a labeled block volume at /mnt/data."
  line "  Free tier: VM.Standard.A1.Flex, up to 4 OCPU / 24 GB / 200 GB block."
}

hetzner_section() {
  section "Provider: hetzner  (terraform/hetzner/)"
  if [[ -n "$HZ_API_KEY" ]]; then
    ok "HETZNER_API_KEY" "Cloud API token (rw): console.hetzner.com -> Security -> API Tokens"
  else
    miss "HETZNER_API_KEY" "Cloud API token (rw): console.hetzner.com -> Security -> API Tokens"
  fi
  if [[ -n "${TF_VAR_location:-}" ]]; then ok "TF_VAR_location" "$TF_VAR_location (nbg1, fsn1, hel1, ash1, ...)"; else miss "TF_VAR_location" "datacenter"; fi
  if [[ -n "$HZ_OBJECT_ACCESS_KEY" && -n "$HZ_OBJECT_SECRET_KEY" && -n "$HZ_OBJECT_BUCKET" ]]; then
    ok "Object Storage keys + TF_STATE_BUCKET" "durable state -> bucket=$HZ_OBJECT_BUCKET"
  else
    miss "Object Storage (optional)" "durable state: create bucket + access key, console -> Object Storage. Empty = local tfstate"
  fi
  line "  Security posture: empty firewall rule set (block all inbound, allow outbound);"
  line "  SSH only via Tailscale; data on a labeled volume mounted at /mnt/data."
}

gcp_section() {
  section "Provider: gcp  (terraform/gcp/)"
  if [[ -n "${TF_VAR_project_id:-}" ]]; then ok "TF_VAR_project_id" "$TF_VAR_project_id"; else miss "TF_VAR_project_id" "project id"; fi
  if [[ -n "${TF_VAR_region:-}" ]]; then ok "TF_VAR_region" "$TF_VAR_region"; else miss "TF_VAR_region" "region"; fi
  if [[ -n "${TF_VAR_zone:-}" ]]; then ok "TF_VAR_zone" "$TF_VAR_zone"; else miss "TF_VAR_zone" "zone"; fi
  if gcloud auth application-default print-access-token >/dev/null 2>&1; then
    ok "ADC" "gcloud auth application-default login"
  else
    miss "ADC" "run: gcloud auth application-default login"
  fi
  if gcloud auth list --format='value(account)' 2>/dev/null | grep -q .; then
    ok "gcloud identity" "$(gcloud config get-value account 2>/dev/null)"
  else
    miss "gcloud identity" "run: gcloud auth login"
  fi
  line "  bootstrap enables compute/storage/iap APIs, creates gs://<project>-tf-state,"
  line "  and SSH runs over IAP (no public ingress). Costs ~\$${GCP_MONTHLY:-60}/mo."
}

case "$want" in
all)
  echo "PROVIDER=${PROVIDER}  (config.env)"
  shared_requirements
  hetzner_section
  oci_section
  gcp_section
  ;;
hetzner)
  echo "PROVIDER=${PROVIDER}  (config.env)"
  shared_requirements
  hetzner_section
  ;;
oci)
  echo "PROVIDER=${PROVIDER}  (config.env)"
  shared_requirements
  oci_section
  ;;
gcp)
  echo "PROVIDER=${PROVIDER}  (config.env)"
  shared_requirements
  gcp_section
  ;;
*)
  echo "usage: ./run setup [gcp|hetzner|oci]" >&2
  exit 1
  ;;
esac

tools_section
