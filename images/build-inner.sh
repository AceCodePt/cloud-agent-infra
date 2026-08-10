#!/usr/bin/env bash
set -euo pipefail

# build-inner.sh — runs INSIDE the cloud-agent-img-tools container (as root).
# Orchestrated by scripts/build-image.sh. Performs the raw-image build that the
# Packer template used to do, without Packer:
#   parted GPT (ESP 100MB + root) -> losetup (offset-based) -> mkfs by LABEL ->
#   mount -> bsdtar extract -> bind /proc /dev /sys -> chroot the 01/02/04/05
#   scripts -> cleanup. All work happens inside the (ephemeral) container; only
#   the image file and tarball persist on the host (both owned by the user,
#   created before this script runs).
#
# Loop devices are created with --offset/--sizelimit because container kernels
# do not reliably create partition nodes (/dev/loopXpN) for `losetup -P`; the
# partition geometry is duplicated here and in parted below. Keep them in sync.

set -x

IMG=/work/output/archlinux-aarch64.img
TARBALL=/work/output/ArchLinuxARM-aarch64-latest.tar.gz
SCRIPTS=/work/scripts
MNT=/mnt/imgroot

# 512 MB ESP starting at 1 MiB (matches parted layout below). 100 MB was too
# small: Image is ~44 MB and the virtio initramfs can exceed that.
ESP_START=$((1 * 1024 * 1024))
ESP_SIZE=$((512 * 1024 * 1024))

[[ -f "$IMG" ]] || { echo "missing $IMG"; exit 1; }
[[ -f "$TARBALL" ]] || { echo "missing $TARBALL"; exit 1; }
command -v qemu-aarch64-static >/dev/null ||
  { echo "qemu-aarch64-static missing in container"; exit 1; }
command -v parted >/dev/null ||
  { echo "parted missing in container"; exit 1; }
command -v losetup >/dev/null ||
  { echo "losetup missing in container"; exit 1; }

# The container may lack /dev/loop* nodes; create them (privileged container).
command -v mknod >/dev/null || { echo "mknod missing in container"; exit 1; }
mknod /dev/loop-control c 10 237 2>/dev/null || true
for i in $(seq 0 15); do
  [[ -e "/dev/loop$i" ]] || mknod "/dev/loop$i" b 7 "$i" 2>/dev/null || true
done

# 1. GPT partition table: ESP (100 MB, type ef00) + root (rest, type 8300).
#    The root partition gets the default "Linux filesystem" type; the ESP flag
#    sets type ef00. Alignment to 1 MiB matches the boot chain.
parted -s "$IMG" mklabel gpt
parted -s "$IMG" mkpart primary fat32 1MiB 513MiB
parted -s "$IMG" set 1 esp on
parted -s "$IMG" mkpart primary ext4 513MiB 100%

# 2. One loop device per partition, bound by offset/sizelimit.
#    IMPORTANT: the root loop device MUST be limited to the partition size, not
#    left to run to the end of the image. parted reserves the last ~2 MiB of the
#    disk for the backup GPT header, so the partition is smaller than the image
#    remainder; mkfs.ext4 on an unlimited loop device creates a superblock whose
#    block count overruns the partition and the kernel refuses to mount it:
#      EXT4-fs (sda2): bad geometry: block count 1441536 exceeds size of device
#    The partition byte size is read from the GPT (sector count * 512), keeping
#    this in sync with parted automatically.
ESP="$(losetup -f --show -o "$ESP_START" --sizelimit "$ESP_SIZE" "$IMG")"
ROOT_SIZE_SECTORS="$(parted -s "$IMG" unit s print | awk '$1==2 {gsub("s","",$4); print $4}')"
ROOT_SIZE_BYTES=$((ROOT_SIZE_SECTORS * 512))
ROOT="$(losetup -f --show -o $((ESP_START + ESP_SIZE)) --sizelimit "$ROOT_SIZE_BYTES" "$IMG")"
trap 'losetup -d "$ROOT" "$ESP" 2>/dev/null || true' EXIT

# 3. Filesystems created BY LABEL at mkfs time — this is what makes the
#    LABEL=arch-agent-{esp,root} boot chain and /etc/fstab work. The vfat label
#    is limited to 11 chars (arch-agent-esp would be truncated, breaking the
#    LABEL= fstab/boot match), so the ESP label is ARCH-ESP.
mkfs.vfat -F 32 -n ARCH-ESP "$ESP"
mkfs.ext4 -L arch-agent-root "$ROOT"

# 4. Mount root, then ESP at /boot/efi.
mkdir -p "$MNT"
mount "$ROOT" "$MNT"
mkdir -p "$MNT/boot/efi"
mount "$ESP" "$MNT/boot/efi"

# 5. Extract the Arch Linux ARM rootfs onto the root filesystem.
bsdtar -xpf "$TARBALL" -C "$MNT"

# 6. qemu-aarch64-static + bind mounts so the chroot can execute aarch64.
cp /usr/bin/qemu-aarch64-static "$MNT/usr/bin/qemu-aarch64-static"
for d in /proc /dev /sys; do
  mount --bind "$d" "$MNT$d"
done

# 7. Provisioners run in order inside the chroot (01, 02, 04, 05).
for s in 01-base.sh 02-config.sh 04-boot.sh 05-cleanup.sh; do
  cp "$SCRIPTS/$s" "$MNT/tmp/$s"
  chroot "$MNT" /usr/bin/bash "/tmp/$s"
done

sync

echo "build-inner done"
