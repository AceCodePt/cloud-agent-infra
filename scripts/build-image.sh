#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_config

IMAGE_RAW="images/output/archlinux-aarch64.img"
TARBALL="images/output/ArchLinuxARM-aarch64-latest.tar.gz"
TARBALL_URL="https://archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz"
MD5_URL="https://archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz.md5"
QEMU_STATIC="${QEMU_STATIC:-/tmp/opencode/qemu-aarch64-static}"
TOOLS_IMAGE="cloud-agent-img-tools"
IMAGE_SIZE="${IMAGE_SIZE:-6G}"
STAMP="images/output/.build-stamp"

command -v docker >/dev/null 2>&1 ||
  die "docker is required for the QEMU/chroot image build."
[[ -f "$QEMU_STATIC" ]] ||
  die "qemu-aarch64-static not found at $QEMU_STATIC. Set QEMU_STATIC to its path."

mkdir -p images/output

# --- convergence: only rebuild when the inputs changed ---
# Signature = hash of every build input (scripts, tarball checksum, size).
# If the image exists and the signature is unchanged, there is nothing to do.
build_sig() {
  {
    cat images/build-inner.sh images/Dockerfile.build
    for f in images/scripts/*.sh; do cat "$f"; done
    echo "size=$IMAGE_SIZE"
    echo "qemu=$(md5sum "$QEMU_STATIC" 2>/dev/null | awk '{print $1}')"
    echo "tarball=$(md5sum "$TARBALL" 2>/dev/null | awk '{print $1}')"
  } | md5sum | awk '{print $1}'
}

SIG="$(build_sig)"
if [[ -f "$IMAGE_RAW" && -f "$STAMP" && "$(cat "$STAMP" 2>/dev/null)" == "$SIG" ]]; then
  note "image is current (nothing changed); skipping the build."
  exit 0
fi

# Download the rootfs tarball once (checksum-verified); keep it cached so
# rebuilds don't re-download.
if [[ ! -f "$TARBALL" ]]; then
  note "downloading $TARBALL_URL"
  curl -fsSL -o "$TARBALL" "$TARBALL_URL"
fi
expected="$(curl -fsSL "$MD5_URL" | awk '{print $1}')"
actual="$(md5sum "$TARBALL" | awk '{print $1}')"
[[ "$expected" == "$actual" ]] ||
  die "checksum mismatch for $TARBALL (got $actual, want $expected)"

# Sparse image owned by the user (the container writes through it).
truncate -s "$IMAGE_SIZE" "$IMAGE_RAW"

note "building tools image $TOOLS_IMAGE"
docker build -q -t "$TOOLS_IMAGE" -f images/Dockerfile.build images/ >/dev/null

note "building $IMAGE_RAW via QEMU/chroot in $TOOLS_IMAGE"
docker run --rm --privileged \
  -v "$REPO_ROOT/images:/work:rw" \
  -v "$QEMU_STATIC:/usr/bin/qemu-aarch64-static:ro" \
  "$TOOLS_IMAGE" /work/build-inner.sh

[[ -f "$IMAGE_RAW" ]] ||
  die "build finished but $IMAGE_RAW is missing — did build-inner.sh change the output path?"

note "raw image built at $IMAGE_RAW"
printf '%s' "$SIG" > "$STAMP"
note "next: ./run upload-image"
