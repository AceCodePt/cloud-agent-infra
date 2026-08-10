#!/usr/bin/env bash
set -euo pipefail

# 01-base: DNS, mirrors, keyring, full system upgrade, base packages, initramfs.
# Runs INSIDE the image chroot (via qemu-aarch64-static), so all paths are
# chroot-relative.

echo "=== 01-base: pacman setup + base packages ==="

# Working DNS for the chroot. The Arch image ships a dangling resolved-stub
# symlink that pacman cannot use before systemd-resolved is up.
rm -f /etc/resolv.conf
echo 'nameserver 1.1.1.1' > /etc/resolv.conf

# Mirrorlist: official primary + mirror pool.
cat > /etc/pacman.d/mirrorlist <<'MIRROR'
Server = http://archlinuxarm.org/$arch/$repo
Server = http://mirror.archlinuxarm.org/$arch/$repo
MIRROR

# pacman inside a chroot: sandbox off, CheckSpace off (matches the repo's
# staging flow in scripts/templates/startup.arch.sh).
sed -i 's/^#\?DisableSandboxFilesystem/DisableSandboxFilesystem/' /etc/pacman.conf
sed -i 's/^#\?DisableSandboxSyscalls/DisableSandboxSyscalls/' /etc/pacman.conf
sed -i 's/^#\?CheckSpace/CheckSpace/' /etc/pacman.conf

pacman-key --init
pacman-key --populate archlinuxarm

pacman -Syu --noconfirm
# gnupg (not "gpg") is the Arch package that provides /usr/bin/gpg; pacman has
# no "gpg" target, so `pacman -S gpg` would fail.
# zsh is baked in because the sagi account (02-config.sh) uses /usr/bin/zsh.
# Everything else user-facing (fzf, neovim, tmux, python, github-cli, browser
# stack, ...) is deferred: delivered at first boot on the cloud via user_data
# (cloud-init), so this stays a lean golden base. cloud-init is required here
# so OCI user_data can run at first boot.
# cloud-guest-utils provides growpart, which cloud-init's built-in growpart +
# resizefs modules (already enabled in /etc/cloud/cloud.cfg) use at first boot
# to expand the root partition to fill the provider's boot volume. That keeps
# the image portable: the 6G partition fits any disk >= ~6G and self-sizes up.
pacman -S --noconfirm --needed grub efibootmgr tailscale sudo openssh git curl rsync cloud-init zsh gnupg cloud-guest-utils

# virtio drivers must be in the initramfs (or the OCI disk/NIC is lost).
# The OCI paravirtualized boot volume is a virtio-SCSI disk (firmware logs show
# "UEFI ORACLE BlockVolume ... Scsi(0,1)" behind VirtioScsiDxe), so the SCSI
# stack (virtio_scsi + sd_mod) is required in addition to virtio_blk. They are
# listed explicitly because the mkinitcpio autodetect hook runs against the
# build host's /sys (an x86 machine) and would otherwise strip them.
if grep -q '^MODULES=' /etc/mkinitcpio.conf; then
  sed -i 's/^MODULES=(.*)/MODULES=(virtio virtio_blk virtio_net virtio_pci virtio_scsi sd_mod)/' /etc/mkinitcpio.conf
else
  echo 'MODULES=(virtio virtio_blk virtio_net virtio_pci virtio_scsi sd_mod)' >> /etc/mkinitcpio.conf
fi

# Drop the fsck hook: in the cross-arch chroot the mkinitcpio fsck hook fails to
# bundle fsck.ext4, so systemd-fsck-root fails at boot and dumps the box into
# emergency mode (disk is found, fsck just isn't there). Cloud boot volumes are
# freshly provisioned ext4; boot-time fsck is unnecessary.
if grep -q '^HOOKS=' /etc/mkinitcpio.conf; then
  sed -i 's/\(HOOKS=([^)]*\) fsck)/\1)/' /etc/mkinitcpio.conf
fi

mkinitcpio -P

echo "=== 01-base: done ==="
