#!/usr/bin/env bash
set -euo pipefail

# 04-boot: stage the OCI EFI boot chain on the ESP.
# Runs INSIDE the image chroot (via qemu-aarch64-static).
#
# Verified boot chain on OCI (do not deviate):
#   * EFI boot (ARM64 has no BIOS): kernel Image + initramfs-linux.img are
#     copied onto the ESP at /boot/efi/.
#   * A standalone GRUB EFI binary at /boot/efi/EFI/BOOT/BOOTAA64.EFI built with
#     grub-mkstandalone; the config below is embedded in the memdisk, so no
#     grub-install is needed and nothing is read from disk at boot time.

echo "=== 04-boot: stage ESP boot chain ==="

# The plugin already mounts the ESP at /boot/efi; make sure it is.
if ! findmnt /boot/efi >/dev/null 2>&1; then
  mount /boot/efi
fi

mkdir -p /boot/efi/EFI/BOOT

# Kernel and initramfs onto the ESP.
cp /boot/Image /boot/efi/Image
cp /boot/initramfs-linux.img /boot/efi/initramfs-linux.img

# Embedded GRUB config. Root is referenced by LABEL so UUIDs are irrelevant.
# console=ttyAMA0 (PL011) is the OCI ARM serial console; without it the console
# history stays empty even on a successful boot. systemd.firstboot=off: the
# golden image pre-satisfies firstboot inputs (localtime etc.), and the serial
# console must never block on an interactive prompt before cloud-init/user_data.
cat > /boot/embedded-grub.cfg <<'GRUBCFG'
set root=(hd0,1)
linux /Image root=LABEL=arch-agent-root rw console=ttyAMA0,115200 systemd.firstboot=off loglevel=4
initrd /initramfs-linux.img
boot
GRUBCFG

# Standalone GRUB EFI binary with the config embedded.
grub-mkstandalone -O arm64-efi \
  --modules="part_gpt fat linux normal search search_fs_uuid" \
  --themes="" --locales="" \
  boot/grub/grub.cfg=/boot/embedded-grub.cfg \
  -o /boot/efi/EFI/BOOT/BOOTAA64.EFI

sync

echo "=== 04-boot: done ==="
