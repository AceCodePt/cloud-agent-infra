#!/usr/bin/env bash
set -euo pipefail

# 02-config: fstab, hostname, locale, networkd, tailscaled, sshd, user "sagi",
# cloud-init (OCI user_data at first boot).
# Runs INSIDE the image chroot (via qemu-aarch64-static).

echo "=== 02-config: system config, tailscaled, sshd, user sagi ==="

# --- fstab: root + ESP by LABEL (UUID is irrelevant for the boot chain) ---
# ESP label is ARCH-ESP (11-char vfat limit — arch-agent-esp would be truncated;
# uppercase avoids vfat lowercase-label quirks).
cat > /etc/fstab <<'FSTAB'
LABEL=arch-agent-root  /          ext4  defaults,noatime  0 1
LABEL=ARCH-ESP         /boot/efi  vfat  defaults,noatime  0 0
FSTAB

# --- hostname ---
echo cloud-agent > /etc/hostname

# --- systemd-firstboot: pre-satisfy what it prompts for so it never blocks
# --- first boot (fresh OCI boots would otherwise hang at the interactive
# --- "Please enter the new timezone name" before cloud-init/user_data can run).
# --- It prompts for timezone/keymap/locale when those are unset; locale.conf and
# --- vconsole.conf are written below, so baking /etc/localtime is the missing
# --- piece. machine-id is intentionally regenerated per instance in 05-cleanup.
ln -sf /usr/share/zoneinfo/UTC /etc/localtime

# --- locale ---
sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo 'LANG=en_US.UTF-8' > /etc/locale.conf
printf 'KEYMAP=us\n' > /etc/vconsole.conf

# --- networking: DHCP on the primary VNIC via systemd-networkd ---
mkdir -p /etc/systemd/network
cat > /etc/systemd/network/20-oci.network <<'NET'
[Match]
Name=en* eth*

[Network]
DHCP=yes

[DHCP]
UseDomains=yes
NET

systemctl enable systemd-networkd systemd-resolved systemd-networkd-wait-online

# DNS through systemd-resolved
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

# --- tailscaled: operator is a CLI preference (`tailscale set --operator`),
# NOT a valid daemon flag, so FLAGS must stay empty. Keep PORT=41641 (the
# package default): the unit runs `--port=${PORT}`, and an unset/empty PORT
# makes tailscaled exit instantly ("Failed to start Tailscale node agent"),
# which in turn aborts the agent-startup user_data before it can `tailscale up`.
cat > /etc/default/tailscaled <<'TSC'
PORT="41641"
FLAGS=""
TSC

mkdir -p /etc/systemd/system/tailscaled.service.d
cat > /etc/systemd/system/tailscaled.service.d/override.conf <<'TSDROP'
[Unit]
After=systemd-networkd-wait-online.service
Wants=systemd-networkd-wait-online.service

[Service]
Restart=always
RestartSec=5
TSDROP

systemctl enable tailscaled sshd

# --- per-user account ---
useradd -m -s /usr/bin/zsh sagi
echo 'sagi ALL=(ALL:ALL) NOPASSWD: ALL' > /etc/sudoers.d/sagi
chmod 440 /etc/sudoers.d/sagi
mkdir -p /home/sagi/.ssh
cat > /home/sagi/.ssh/authorized_keys <<'KEY'
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHhyq7LcRAKsL31DKsoiIXoJG6SljB66DuKsd7p0dkS6 sagi@omarchy
KEY
chown -R sagi:sagi /home/sagi/.ssh
chmod 700 /home/sagi/.ssh
chmod 600 /home/sagi/.ssh/authorized_keys

# --- sshd hardening: key-only over Tailscale ---
cat >> /etc/ssh/sshd_config <<'HARD'

# cloud-agent hardening (key-only over Tailscale)
PasswordAuthentication no
PermitRootLogin prohibit-password
KbdInteractiveAuthentication no
HARD

# --- cloud-init: process OCI user_data at first boot ---
# Golden base: NO startup/provisioning logic is baked into the image; all
# provisioning is delivered on the cloud via user_data. cloud-init must be
# enabled so user_data runs. cloud-init.target is enabled by the bundled
# cloud-init-generator; the stage units below are WantedBy=cloud-init.target,
# so enabling them is what makes the boot chain run (Arch's cloud-init 26.1
# renames the old cloud-init.service to cloud-init-main.service).
systemctl enable cloud-init-local cloud-init-main cloud-init-network cloud-config cloud-final

# OCI datasource first (Oracle = OCI), NoCloud/ConfigDrive kept as fallbacks.
# preserve_hostname: the image bakes hostname "cloud-agent"; cloud-init must
# not rename the box to the OCI instance name.
# manage_etc_hosts: the image owns /etc/hosts (fstab/networkd); cloud-init must
# not rewrite it.
# No ssh keys / no user config here: the image bakes sagi's authorized_keys,
# and cloud-init must not create or overwrite them (no default-user keys).
cat > /etc/cloud/cloud.cfg.d/99_datasources.cfg <<'CFG'
datasource_list: [ Oracle, OCI, NoCloud, ConfigDrive ]
preserve_hostname: true
manage_etc_hosts: false
CFG

echo "=== 02-config: done ==="
