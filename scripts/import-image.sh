#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_config

[[ "$PROVIDER" == oci ]] ||
  die "import-image only supports PROVIDER=oci (config.env has PROVIDER=$PROVIDER)."

require_oci_key

BUCKET="cloud-agent-images"
OBJECT="archlinux-aarch64.qcow2"
TIMEOUT="${TIMEOUT:-600}" # ~10 min for the image to become AVAILABLE
STAMP="images/output/.import-stamp"

# The import reads from Object Storage, so the qcow2 must already be uploaded.
if ! oci os object head --bucket-name "$BUCKET" --name "$OBJECT" >/dev/null 2>&1; then
  die "$BUCKET/$OBJECT not found in Object Storage. Run ./run upload-image first."
fi

# The Object Storage namespace is a per-tenancy string, distinct from the
# tenancy OCID. bucket get/put resolve it automatically, but the import command
# requires it explicitly.
NS="$(oci os ns get 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("data",""))' 2>/dev/null || true)"
[[ -n "$NS" ]] || die "could not determine the Object Storage namespace (oci os ns get failed)."

# The identity of the source object: the md5 upload-image stores as metadata.
# A custom image imported from the SAME object bytes must not be re-imported.
OBJ_MD5="$(oci os object head --bucket-name "$BUCKET" --name "$OBJECT" 2>/dev/null |
  python3 -c 'import json,sys
try:
    d=json.load(sys.stdin)
    print(d.get("metadata",{}).get("qcow2-md5",""))
except Exception:
    print("")' 2>/dev/null)"

# --- convergence: reuse the custom image that already imported THIS object ---
# .import-stamp holds "<obj-md5> <image-ocid>". Reuse it if the stored md5
# matches the current object and the image still exists.
STAMP_MD5="$(awk '{print $1}' "$STAMP" 2>/dev/null || true)"
STAMP_OCID="$(awk '{print $2}' "$STAMP" 2>/dev/null || true)"
REUSE=""
if [[ -n "$OBJ_MD5" && "$STAMP_MD5" == "$OBJ_MD5" && -n "$STAMP_OCID" ]]; then
  REUSE_STATE="$(oci compute image get --image-id "$STAMP_OCID" 2>/dev/null |
    python3 -c 'import json,sys
try:
    print(json.load(sys.stdin).get("data",{}).get("lifecycle-state",""))
except Exception:
    print("")' 2>/dev/null || true)"
  if [[ "$REUSE_STATE" == "AVAILABLE" ]]; then
    note "custom image $STAMP_OCID already imports this exact qcow2; reusing it."
    REUSE="$STAMP_OCID"
  else
    warn "stamped image $STAMP_OCID is not AVAILABLE (${REUSE_STATE:-gone}); importing fresh."
  fi
fi

if [[ -n "$REUSE" ]]; then
  IMAGE_OCID="$REUSE"
else
  TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
  DISPLAY_NAME="archlinux-aarch64-$TIMESTAMP"

  # Import via the raw API (not `oci compute image import from-object`), because
  # the CLI's --launch-mode PARAVIRTUALIZED hardcodes firmware=BIOS on the image.
  # BIOS cannot boot on Ampere A1 (UEFI-only), so the image would launch but never
  # boot. launchMode=CUSTOM + explicit launchOptions lets us set firmware=UEFI_64,
  # which is the required boot firmware for arm64 on A1.
  note "importing $BUCKET/$OBJECT as custom image '$DISPLAY_NAME' (firmware UEFI_64)"
  IMPORT_BODY="$(python3 - "$NS" "$DISPLAY_NAME" "$OCI_TENANCY_OCID" "$BUCKET" "$OBJECT" <<'PY'
import json, sys
ns, name, tenancy, bucket, obj = sys.argv[1:6]
print(json.dumps({
    "compartmentId": tenancy,
    "displayName": name,
    "launchMode": "CUSTOM",
    "launchOptions": {
        "firmware": "UEFI_64",
        "bootVolumeType": "PARAVIRTUALIZED",
        "networkType": "PARAVIRTUALIZED",
        "remoteDataVolumeType": "PARAVIRTUALIZED",
        "isConsistentVolumeNamingEnabled": False,
        "isPvEncryptionInTransitEnabled": False,
    },
    "imageSourceDetails": {
        "sourceType": "objectStorageTuple",
        "namespaceName": ns,
        "bucketName": bucket,
        "objectName": obj,
        "sourceImageType": "QCOW2",
        "operatingSystem": "Arch Linux",
    },
}))
PY
  )"
  IMPORT_JSON="$(oci raw-request --http-method POST \
    --target-uri "https://iaas.${TF_VAR_region}.oraclecloud.com/20160918/images" \
    --request-body "$IMPORT_BODY" 2>/dev/null || true)"

  IMAGE_OCID="$(printf '%s' "$IMPORT_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["id"])' 2>/dev/null || true)"
  [[ -n "$IMAGE_OCID" ]] || die "import did not return an image OCID — inspect the response above."

  # ARM64 images are not auto-added to the A1 shape-compat list on import; without
  # this, A1.Flex refuses to launch the image at all.
  note "adding VM.Standard.A1.Flex to the image's compatible shapes"
  oci compute image-shape-compatibility-entry add \
    --image-id "$IMAGE_OCID" --shape-name VM.Standard.A1.Flex >/dev/null 2>&1 || \
    warn "could not add A1.Flex shape compatibility (you may need to add it manually)"

  note "waiting for image $IMAGE_OCID to become AVAILABLE (timeout ${TIMEOUT}s)"
  START="$(date +%s)"
  state=""
  while :; do
    elapsed=$(($(date +%s) - START))
    [[ "$elapsed" -le "$TIMEOUT" ]] || break
    state="$(oci compute image get --image-id "$IMAGE_OCID" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("data",{}).get("lifecycle-state",""))' 2>/dev/null || true)"
    [[ "$state" == "AVAILABLE" ]] && break
    sleep 15
  done

  if [[ "$state" == "AVAILABLE" ]]; then
    note "image $IMAGE_OCID is AVAILABLE"
  else
    die "timed out waiting for image $IMAGE_OCID to become AVAILABLE (last state: ${state:-unknown}).
  Check progress with: oci compute image get --image-id $IMAGE_OCID"
  fi

  # Record which object this image was imported from so the next run can reuse it.
  printf '%s %s\n' "$OBJ_MD5" "$IMAGE_OCID" > "$STAMP"
fi

# --- wire the image into Terraform (Option A: no config.env edits) ---
# terraform/oci/image.auto.tfvars feeds var.custom_image_id; *.tfvars is
# git-ignored. compute.tf boots the custom image whenever it is non-empty.
AUTO_TFVARS="terraform/$PROVIDER/image.auto.tfvars"
printf 'custom_image_id = "%s"\n' "$IMAGE_OCID" > "$AUTO_TFVARS"

cat <<EOF

=====================================================================
Custom image ready: $IMAGE_OCID
Wrote $AUTO_TFVARS (custom_image_id), so Terraform boots this image.
Next: ./run up
EOF
