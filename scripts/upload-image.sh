#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_config

[[ "$PROVIDER" == oci ]] ||
  die "upload-image only supports PROVIDER=oci (config.env has PROVIDER=$PROVIDER)."

require_oci_key

IMAGE_RAW="images/output/archlinux-aarch64.img"
IMAGE_QCOW2="images/output/archlinux-aarch64.qcow2"
BUCKET="cloud-agent-images"
OBJECT="archlinux-aarch64.qcow2"
TOOLS_IMAGE="cloud-agent-img-tools"

[[ -f "$IMAGE_RAW" ]] ||
  die "$IMAGE_RAW not found. Run ./run build-image first."

# qemu-img convert runs inside the tools container (no host qemu-img needed).
command -v docker >/dev/null 2>&1 ||
  die "docker is required (qemu-img convert runs via the $TOOLS_IMAGE container)."
docker build -q -t "$TOOLS_IMAGE" -f images/Dockerfile.build images/ >/dev/null

note "converting $IMAGE_RAW -> $IMAGE_QCOW2"
docker run --rm -u "$(id -u):$(id -g)" \
  -v "$REPO_ROOT/images/output:/out" \
  "$TOOLS_IMAGE" \
  qemu-img convert -f raw -O qcow2 /out/archlinux-aarch64.img /out/archlinux-aarch64.qcow2

# NOTE: the os bucket/object commands take no --compartment-id, so they are
# called directly rather than through oci_json (which injects one).
if oci os bucket get --bucket-name "$BUCKET" >/dev/null 2>&1; then
  note "bucket $BUCKET already exists"
else
  note "creating bucket $BUCKET"
  oci os bucket create --name "$BUCKET" --compartment-id "$OCI_TENANCY_OCID" >/dev/null
fi

# --- convergence: skip the upload if the object already holds this qcow2 ---
# The qcow2's md5 is stored as object metadata at put time; if the object exists
# and that metadata matches the local file, nothing changed and the upload (and
# any re-import it would trigger) is skipped.
MD5="$(md5sum "$IMAGE_QCOW2" | awk '{print $1}')"
if oci os object head --bucket-name "$BUCKET" --name "$OBJECT" >/dev/null 2>&1; then
  REMOTE_MD5="$(oci os object head --bucket-name "$BUCKET" --name "$OBJECT" 2>/dev/null |
    python3 -c 'import json,sys
try:
    d=json.load(sys.stdin)
    print(d.get("metadata",{}).get("qcow2-md5",""))
except Exception:
    print("")' 2>/dev/null)"
  if [[ "$REMOTE_MD5" == "$MD5" ]]; then
    note "$OBJECT already holds this exact qcow2 (md5 match); skipping upload."
    exit 0
  fi
  note "object $OBJECT exists but is stale (md5 differs); re-uploading."
fi

note "uploading $IMAGE_QCOW2 -> $BUCKET/$OBJECT (overwrite allowed, parallel)"
oci os object put --bucket-name "$BUCKET" --name "$OBJECT" --file "$IMAGE_QCOW2" \
  --metadata '{"qcow2-md5":"'"$MD5"'"}' --force --parallel-upload-count 8

note "upload complete. Next: ./run import-image"
