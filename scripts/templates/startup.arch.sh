#!/usr/bin/env bash
set -euo pipefail
umask 022
exec > >(umask 027; tee /var/log/startup-agent.log) 2>&1
echo "=== agent startup (Oracle staging -> Arch) $(date -u) ==="

export DEBIAN_FRONTEND=noninteractive

DATA_LABEL="__DATA_LABEL__"
DATA_DEV="__DATA_DEV__"
DATA_MNT="/mnt/data"
USER_NAME="__USER__"
INSTANCE_NAME="__INSTANCE__"
AUTHKEY="__AUTHKEY__"
SSHPUB="__SSHPUB__"

if [ -z "$USER_NAME" ] || [ "$USER_NAME" != "${USER_NAME#-}" ] || \
   [ -n "${USER_NAME//[A-Za-z0-9._-]/}" ]; then
  echo "!! invalid USER_NAME '$USER_NAME' (want ^[A-Za-z0-9._-]+$); skipping per-user setup"
  USER_NAME=""
fi

# --- persistent data disk, discovered by filesystem LABEL (provider-neutral) ---
# OCI paravirtualized volumes appear as /dev/sdb (the /dev/oracleoci/ name is an
# Oracle Linux udev alias that may or may not have landed). Probe both.
mkdir -p "$DATA_MNT"
for cand in "$DATA_DEV" /dev/sdb /dev/sdc /dev/vdb; do
  if [ -b "$cand" ]; then
    DATA_DEV="$cand"
    break
  fi
done
for _ in $(seq 1 30); do
  [ -b "$DATA_DEV" ] && break
  sleep 2
done
echo ">> data device probe: ${DATA_DEV:-none}"
if ! blkid -L "$DATA_LABEL" >/dev/null 2>&1; then
  if [ -b "$DATA_DEV" ]; then
    if [ -n "$(blkid -o value -s TYPE "$DATA_DEV" 2>/dev/null || true)" ]; then
      echo "!! $DATA_DEV already has a filesystem but no label $DATA_LABEL; NOT reformatting"
    else
      echo ">> formatting fresh data disk $DATA_DEV (label $DATA_LABEL)"
      mkfs.ext4 -F -L "$DATA_LABEL" "$DATA_DEV"
    fi
  else
    echo "!! data device not found at first boot"
  fi
fi
if [ -n "$(blkid -L "$DATA_LABEL" 2>/dev/null)" ]; then
  mount -o discard,defaults LABEL="$DATA_LABEL" "$DATA_MNT"
else
  echo "!! data disk not mountable; cannot build Arch. Aborting."
  exit 1
fi

# --- tools needed for the build on the staging host ---
dnf -y install curl tar gzip wget >/dev/null 2>&1 || true

# --- download + extract the Arch Linux ARM rootfs ---
ROOTFS_TARBALL=/tmp/arch-rootfs.tar.gz
if [ ! -s "$ROOTFS_TARBALL" ]; then
  echo ">> downloading Arch Linux ARM rootfs (aarch64)"
  curl -fSL --retry 5 --retry-delay 5 -o "$ROOTFS_TARBALL" \
    "https://archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz"
fi
echo ">> extracting Arch rootfs to $DATA_MNT"
tar -xzf "$ROOTFS_TARBALL" -C "$DATA_MNT"
rm -f "$ROOTFS_TARBALL"

# --- chroot prep: bind the virtual filesystems ---
mount --bind /dev "$DATA_MNT/dev" || true
mount --bind /proc "$DATA_MNT/proc" || true
mount --bind /sys "$DATA_MNT/sys" || true
mount --bind /run "$DATA_MNT/run" || true

# pacman.conf: the sandbox must be off inside a chroot; CheckSpace must be off
sed -i 's/^#\?DisableSandboxFilesystem/DisableSandboxFilesystem/' "$DATA_MNT/etc/pacman.conf"
sed -i 's/^#\?DisableSandboxSyscalls/DisableSandboxSyscalls/' "$DATA_MNT/etc/pacman.conf"
sed -i 's/^#\?CheckSpace/CheckSpace/' "$DATA_MNT/etc/pacman.conf"

# mirrorlist: reliable mirrors for the staging build
cat > "$DATA_MNT/etc/pacman.d/mirrorlist" <<'MIRROR'
Server = https://mirror.math.princeton.edu/pub/archlinuxarm/$arch/$repo
Server = https://mirror.umd.edu/archlinuxarm/$arch/$repo
MIRROR

# DNS for the chroot (the Arch image ships a resolved-stub symlink; pacman
# needs a live resolv.conf before systemd-resolved is up). Remove the dangling
# symlink first — `cp` would follow it and fail ("not writing through dangling
# symlink"), killing the build under set -e.
rm -f "$DATA_MNT/etc/resolv.conf"
cp /etc/resolv.conf "$DATA_MNT/etc/resolv.conf"

echo ">> pacman full system upgrade + base packages"
chroot "$DATA_MNT" pacman -Syu --noconfirm
chroot "$DATA_MNT" pacman -S --noconfirm grub efibootmgr tailscale sudo

# virtio drivers must be present in the initramfs (or the OCI disk/NIC is lost)
if ! grep -q '^MODULES=' "$DATA_MNT/etc/mkinitcpio.conf"; then
  echo 'MODULES=(virtio virtio_blk virtio_net virtio_pci)' >> "$DATA_MNT/etc/mkinitcpio.conf"
else
  sed -i 's/^MODULES=(.*)/MODULES=(virtio virtio_blk virtio_net virtio_pci)/' \
    "$DATA_MNT/etc/mkinitcpio.conf"
fi
chroot "$DATA_MNT" mkinitcpio -P

# --- root filesystem identity ---
ROOT_UUID="$(blkid -s UUID -o value "$DATA_DEV")"
EFI_UUID="$(blkid -s UUID -o value /dev/sda1)"
echo ">> root=$ROOT_UUID efi=$EFI_UUID"
cat > "$DATA_MNT/etc/fstab" <<EOF
# Arch root on the OCI data volume
UUID=$ROOT_UUID  /          ext4  discard,defaults  0  1
UUID=$EFI_UUID  /boot/efi  vfat  defaults,umask=0077  0  2
EOF

echo "$INSTANCE_NAME" > "$DATA_MNT/etc/hostname"

# --- networking: systemd-networkd DHCP on the primary VNIC ---
mkdir -p "$DATA_MNT/etc/systemd/network"
cat > "$DATA_MNT/etc/systemd/network/20-oci.network" <<'NET'
[Match]
Name=en* eth*

[Network]
DHCP=yes

[DHCP]
UseDomains=yes
NET

# DNS through systemd-resolved
ln -sf /run/systemd/resolve/stub-resolv.conf "$DATA_MNT/etc/resolv.conf"

# --- tailscaled: operator is a CLI pref (tailscale set), NOT a daemon flag ---
sed -i 's/^FLAGS=".*"/FLAGS=""/' "$DATA_MNT/etc/default/tailscaled" 2>/dev/null || true
mkdir -p "$DATA_MNT/etc/systemd/system/tailscaled.service.d"
cat > "$DATA_MNT/etc/systemd/system/tailscaled.service.d/override.conf" <<'TSDROP'
[Unit]
After=systemd-networkd-wait-online.service
Wants=systemd-networkd-wait-online.service

[Service]
Restart=always
RestartSec=5
TSDROP

chroot "$DATA_MNT" systemctl enable \
  systemd-networkd systemd-resolved systemd-networkd-wait-online \
  tailscaled sshd

# --- per-user account (phase A creates it; phase B tunes it) ---
if [ -n "$USER_NAME" ]; then
  chroot "$DATA_MNT" useradd -m -G wheel -s /bin/bash "$USER_NAME"
  echo "$USER_NAME ALL=(ALL:ALL) NOPASSWD: ALL" > "$DATA_MNT/etc/sudoers.d/agent-sudo"
  chmod 440 "$DATA_MNT/etc/sudoers.d/agent-sudo"
  mkdir -p "$DATA_MNT/home/$USER_NAME/.ssh"
  printf '%s\n' "$SSHPUB" > "$DATA_MNT/home/$USER_NAME/.ssh/authorized_keys"
  chown -R "$USER_NAME:$USER_NAME" "$DATA_MNT/home/$USER_NAME/.ssh"
  chmod 700 "$DATA_MNT/home/$USER_NAME/.ssh"
  chmod 600 "$DATA_MNT/home/$USER_NAME/.ssh/authorized_keys"
fi

# --- sshd hardening: key-only over Tailscale ---
mkdir -p "$DATA_MNT/etc/ssh/sshd_config.d"
cat > "$DATA_MNT/etc/ssh/sshd_config.d/10-agent-hardening.conf" <<'HARD'
PasswordAuthentication no
PermitRootLogin no
KbdInteractiveAuthentication no
HARD

# --- auth key for Arch's first boot (single-use; the staging host never joins) ---
mkdir -p "$DATA_MNT/etc/agent"
printf '%s\n' "$AUTHKEY" > "$DATA_MNT/etc/agent/authkey"
chmod 600 "$DATA_MNT/etc/agent/authkey"

# ============================================================================
# Arch phase A: re-runnable tailnet join + sentinel (mirrors startup.ol.sh)
# ============================================================================
cat > "$DATA_MNT/usr/local/sbin/agent-startup" <<'ASTART'
#!/usr/bin/env bash
set -uo pipefail
echo "=== agent startup (Arch) $(date -u) ==="
USER_NAME="__USER__"
INSTANCE_NAME="__INSTANCE__"

if [ -z "$USER_NAME" ] || [ "$USER_NAME" != "${USER_NAME#-}" ] || \
   [ -n "${USER_NAME//[A-Za-z0-9._-]/}" ]; then
  USER_NAME=""
fi

# Tailscale client talks to the daemon via a socket that takes a moment to
# appear; wait for it before trying to join.
for _ in $(seq 1 30); do
  [ -S /run/tailscale/tailscaled.sock ] && break
  sleep 1
done

AUTHKEY=""
[ -s /etc/agent/authkey ] && AUTHKEY="$(cat /etc/agent/authkey)"

if [ -n "$AUTHKEY" ]; then
  if tailscale up --ssh --hostname="$INSTANCE_NAME" --authkey="$AUTHKEY"; then
    rm -f /etc/agent/authkey
  else
    echo ">> tailscale up FAILED: the one-off key is likely spent, revoked or expired."
    echo ">> Recover with:  ./run rekey"
  fi
elif tailscale status >/dev/null 2>&1; then
  tailscale up --ssh --hostname="$INSTANCE_NAME" || echo ">> tailscale up returned non-zero; already up?"
else
  echo ">> no tailscale auth key available; this box cannot join the tailnet."
fi

[ -n "$USER_NAME" ] && tailscale set --operator="$USER_NAME" 2>/dev/null || true

# exit-node watchdog: probe egress, reset a stale exit node, heal to auto
cat > /usr/local/sbin/exit-node-watch <<'DAEMON'
#!/usr/bin/env bash
set -uo pipefail
PROBE_URL="https://ifconfig.me"
INTERVAL=5
note() { echo "exit-node-watch: $*"; logger -t exit-node-watch "$*"; }
while true; do
  CURRENT="$(tailscale get exit-node 2>/dev/null || true)"
  if [ -n "$CURRENT" ]; then
    if ! curl -4sf --max-time 5 -o /dev/null "$PROBE_URL" 2>/dev/null; then
      note "egress probe failed (exit-node=$CURRENT); resetting exit node"
      tailscale set --exit-node= || note "reset failed (rc=$?)"
    fi
  else
    ONLINE="$(tailscale status --json 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
for p in d.get("Peer", {}).values():
    if p.get("ExitNodeOption") and p.get("Online"):
        print(p["DNSName"].split(".")[0]); sys.exit(0)
sys.exit(1)
' 2>/dev/null || true)"
    if [ -n "$ONLINE" ]; then
      note "exit node '$ONLINE' is online again; restoring auto exit node"
      tailscale set --exit-node=auto:any || note "re-heal failed (rc=$?)"
    fi
  fi
  sleep "$INTERVAL"
done
DAEMON
chmod 755 /usr/local/sbin/exit-node-watch
cat > /etc/systemd/system/exit-node-watch.service <<'UNIT'
[Unit]
Description=cloud-agent exit-node watchdog: probe egress, reset/re-heal exit node
After=network-online.target tailscaled.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/sbin/exit-node-watch
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable exit-node-watch.service
systemctl start exit-node-watch.service

touch /run/agent-startup-complete
echo "=== agent startup complete (Arch) $(date -u) ==="
ASTART
chmod 700 "$DATA_MNT/usr/local/sbin/agent-startup"
sed -i "s/__USER__/$USER_NAME/g; s/__INSTANCE__/$INSTANCE_NAME/g" \
  "$DATA_MNT/usr/local/sbin/agent-startup"

cat > "$DATA_MNT/etc/systemd/system/agent-startup.service" <<'ASTARTU'
[Unit]
Description=cloud-agent phase A: reach the box (tailscale, watchdog)
After=network-online.target tailscaled.service systemd-networkd-wait-online.service
Wants=network-online.target systemd-networkd-wait-online.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/agent-startup
TimeoutStartSec=600

[Install]
WantedBy=multi-user.target
ASTARTU

# ============================================================================
# Arch phase B: deferred tooling + headed browser stack (pacman equivalents)
# ============================================================================
cat > "$DATA_MNT/usr/local/sbin/agent-install-packages" <<'APKGS'
#!/usr/bin/env bash
set -euo pipefail
echo "=== agent packages (Arch) $(date -u) ==="

pacman -Syu --noconfirm --needed \
  git stow tmux python python-pip zsh github-cli fzf gpg unzip \
  fzf direnv neovim \
  go rust nodejs npm \
  chromium xorg-server-xvfb x11vnc zram-generator

# mise (version manager) is AUR-only on Arch; install the static binary like
# the Oracle Linux build did.
if ! command -v mise >/dev/null 2>&1; then
  MISE_VERSION="v2026.8.2"
  MISE_ARCH="arm64"
  [ "$(uname -m)" = "x86_64" ] && MISE_ARCH="amd64"
  MISE_TARBALL="$(mktemp)"
  if curl -fsSL "https://github.com/jdx/mise/releases/download/${MISE_VERSION}/mise-${MISE_VERSION}-linux-${MISE_ARCH}.tar.gz" \
      -o "$MISE_TARBALL"; then
    mkdir -p /opt/mise
    tar -xzf "$MISE_TARBALL" -C /opt/mise
    ln -sf /opt/mise/bin/mise /usr/local/bin/mise
  else
    echo "!! could not download mise from GitHub releases"
  fi
  rm -f "$MISE_TARBALL"
fi

AGENT_USER="__USER__"
if [ -n "$AGENT_USER" ]; then
  echo ">> go@latest for $AGENT_USER via mise"
  sudo -u "$AGENT_USER" env HOME="/home/$AGENT_USER" PATH="/usr/local/bin:$PATH" mise use -g go@latest || true
  echo ">> rust@latest for $AGENT_USER via mise"
  sudo -u "$AGENT_USER" env HOME="/home/$AGENT_USER" PATH="/usr/local/bin:$PATH" mise use -g rust@latest || true
  echo ">> node@latest for $AGENT_USER via mise"
  sudo -u "$AGENT_USER" env HOME="/home/$AGENT_USER" PATH="/usr/local/bin:$PATH" mise use -g node@latest || true
  usermod -s /usr/bin/zsh "$AGENT_USER" || true
fi

# virtual-display browser stack
cat > /etc/systemd/system/xvfb.service <<'XVFB'
[Unit]
Description=Virtual framebuffer X server (DISPLAY :99)
After=systemd-user-sessions.service

[Service]
ExecStart=/usr/bin/Xvfb :99 -screen 0 1920x1080x24 -nolisten tcp
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
XVFB
systemctl enable xvfb.service
systemctl start xvfb.service

echo 'export DISPLAY=:99' > /etc/profile.d/display.sh
chmod 644 /etc/profile.d/display.sh

cat > /etc/systemd/system/x11vnc.service <<'VNC'
[Unit]
Description=x11vnc on DISPLAY :99, loopback only (manual start, for hand-login)
After=xvfb.service
Requires=xvfb.service

[Service]
Environment=DISPLAY=:99
ExecStart=/usr/bin/x11vnc -display :99 -localhost -nopw -forever -shared -noxdamage
SuccessExitStatus=2
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
VNC

cat > /usr/local/bin/headed-chromium <<'CHROME'
#!/usr/bin/env bash
export DISPLAY="${DISPLAY:-:99}"
exec /usr/bin/chromium --no-sandbox --no-first-run \
  --no-default-browser-check \
  --disable-blink-features=AutomationControlled \
  --ignore-gpu-blocklist --use-gl=angle --use-angle=gl \
  --window-size="${BROWSER_WINDOW_SIZE:-1920,1080}" \
  --remote-debugging-port="${CDP_PORT:-9222}" \
  --remote-debugging-address=127.0.0.1 \
  --user-data-dir="${BROWSER_PROFILE_DIR:-/mnt/data/browser/default}" \
  "$@"
CHROME
chmod 755 /usr/local/bin/headed-chromium

mkdir -p /mnt/data/browser /mnt/data/app
if [ -n "$AGENT_USER" ]; then
  chown -R "$AGENT_USER:$AGENT_USER" /mnt/data/browser /mnt/data/app
fi

# zram: compressed swap via systemd zram-generator
cat > /etc/systemd/zram-generator.conf <<'ZRAM'
[zram0]
zram-size = min(ram / 2, 4096)
compression-algorithm = zstd
ZRAM
systemctl daemon-reload
systemctl start systemd-zram-setup@zram0.service 2>/dev/null || true

echo "=== agent packages complete (Arch) $(date -u) ==="
APKGS
chmod 755 "$DATA_MNT/usr/local/sbin/agent-install-packages"
sed -i "s/__USER__/$USER_NAME/g" "$DATA_MNT/usr/local/sbin/agent-install-packages"

cat > "$DATA_MNT/etc/systemd/system/agent-packages.service" <<'APKGSU'
[Unit]
Description=cloud-agent deferred package install (CLI tools + headed browser stack)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/agent-install-packages
TimeoutStartSec=3600

[Install]
WantedBy=multi-user.target
APKGSU

chroot "$DATA_MNT" systemctl enable agent-startup.service agent-packages.service

# ============================================================================
# ESP staging: boot the Arch kernel from the ESP (GRUB cannot read the OCI
# data volume: it presents 262144-byte sectors). grub-mkstandalone embeds the
# config + modules so nothing needs to be read from disk at boot.
# ============================================================================
echo ">> staging the ESP boot chain"
ESP_MNT="$DATA_MNT/boot/efi"
mkdir -p "$ESP_MNT"
mount /dev/sda1 "$ESP_MNT"

cp "$DATA_MNT/boot/Image" "$ESP_MNT/Image"
cp "$DATA_MNT/boot/initramfs-linux.img" "$ESP_MNT/initramfs-linux.img"

cat > "$DATA_MNT/boot/embedded-grub.cfg" <<EOF
set root=(hd0,1)
linux /Image root=UUID=$ROOT_UUID rw loglevel=3 quiet
initrd /initramfs-linux.img
boot
EOF

chroot "$DATA_MNT" grub-mkstandalone -O arm64-efi \
  --modules="part_gpt fat linux normal search search_fs_uuid" \
  --themes="" --locales="" \
  boot/grub/grub.cfg=/boot/embedded-grub.cfg \
  -o /boot/efi/EFI/BOOT/BOOTAA64.EFI

rm -f "$DATA_MNT/boot/embedded-grub.cfg"
sync

# --- boot order: fallback 0002 (reads EFI/BOOT/BOOTAA64.EFI) first, drop the
# Oracle Linux entry so the firmware cannot fall back to the boot volume ---
efibootmgr -o 0002,0000,0001,0004 2>/dev/null || true
efibootmgr -b 0005 -B 2>/dev/null || true

echo ">> boot chain staged. Rebooting into Arch."
sync
umount -l "$DATA_MNT/run" 2>/dev/null || true
umount "$ESP_MNT" 2>/dev/null || true
umount -l "$DATA_MNT/sys" 2>/dev/null || true
umount -l "$DATA_MNT/proc" 2>/dev/null || true
umount -l "$DATA_MNT/dev" 2>/dev/null || true
umount -l "$DATA_MNT" 2>/dev/null || true

systemctl reboot
