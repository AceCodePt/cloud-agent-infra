#!/usr/bin/env bash
# Boot the built image under aarch64 QEMU + AAVMF to reproduce the OCI boot
# path locally (virtio-scsi disk, no KVM, TCG). Asserts the boot actually
# reaches multi-user (or a login prompt) so a mount/root failure fails the
# script instead of silently passing. Serial console goes to
# images/output/boot-test.log for diagnosis.
set -euo pipefail

IMG="${1:-images/output/archlinux-aarch64.img}"
LOG="images/output/boot-test.log"
[[ -f "$IMG" ]] || { echo "image not found: $IMG"; exit 1; }
mkdir -p images/output

docker run --rm --privileged \
  -v "$(pwd):/work" \
  cloud-agent-img-tools bash -euc '
    pacman -S --noconfirm --needed qemu-system-aarch64 edk2-aarch64 >/dev/null 2>&1
    IMG="$1"
    LOG="$2"
    # writable vars copy (AAVMF_CODE is shared/RO; VARS must be RW)
    cp /usr/share/AAVMF/AAVMF_CODE.fd /tmp/code.fd
    cp /usr/share/AAVMF/AAVMF_VARS.fd /tmp/vars.fd
    timeout 300 qemu-system-aarch64 \
      -M virt \
      -cpu max \
      -smp 2 \
      -m 4096 \
      -nographic \
      -monitor none \
      -serial mon:stdio \
      -pflash /tmp/code.fd \
      -pflash /tmp/vars.fd \
      -device virtio-scsi-pci,id=scsi0 \
      -device scsi-hd,drive=hd0 \
      -drive file=/work/"$IMG",if=none,id=hd0,format=raw,cache=unsafe \
      -netdev user,id=net0 \
      -device virtio-net-pci,netdev=net0 \
      2>&1 | tee /work/"$LOG" | tail -n 60
  ' _ "$IMG" "$LOG" || true

if [[ -f "$LOG" ]] && grep -qiE "Reached target Multi-User System|cloud-agent login:|login:" "$LOG"; then
  echo ">> local boot test: PASS (reached multi-user/login)"
  exit 0
else
  echo ">> local boot test: FAIL — the image did not finish booting locally." >&2
  echo "   Full console in $LOG; the tail follows:" >&2
  tail -n 40 "$LOG" 2>/dev/null | sed 's/^/   | /' >&2 || true
  exit 1
fi
