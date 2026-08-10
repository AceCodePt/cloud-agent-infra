#!/usr/bin/env bash
set -euo pipefail
umask 022
# umask 027 inside the process substitution: the log is created by tee, so it
# would be 644 under the script's umask; keep root-only-ish (640) instead.
exec > >(umask 027; tee /var/log/startup-agent.log) 2>&1
echo "=== agent startup (custom Arch image) $(date -u) ==="

# First-boot provisioning for an instance booted from our pre-built custom
# Arch Linux ARM64 golden image. The root is on the BOOT volume (the image);
# this script must not touch /boot/efi, GRUB, or try to build Arch.
DATA_LABEL="__DATA_LABEL__"
DATA_DEV="__DATA_DEV__"
DATA_MNT="/mnt/data"
USER_NAME="__USER__"
INSTANCE_NAME="__INSTANCE__"
SSHPUB="__SSHPUB__"

# Guard the sudoers drop-in: an unvalidated username could inject rules.
if [ -z "$USER_NAME" ] || [ "$USER_NAME" != "${USER_NAME#-}" ] || \
   [ -n "${USER_NAME//[A-Za-z0-9._-]/}" ]; then
  echo "!! invalid USER_NAME '$USER_NAME' (want ^[A-Za-z0-9._-]+$); skipping per-user setup"
  USER_NAME=""
fi

# Install this script as a re-runnable systemd unit so "re-run phase A" is
# `systemctl restart agent-startup` — no cloud vendor's metadata runner needed.
# cloud-init/user_data only delivers this file once; the unit owns every later run.
if [ "$(readlink -f "$0" 2>/dev/null || echo "$0")" != "/usr/local/sbin/agent-startup" ]; then
  cp "$0" /usr/local/sbin/agent-startup
  # 700: the rendered script embeds the single-use tailscale auth key until join
  chmod 700 /usr/local/sbin/agent-startup
fi

if [ ! -f /etc/systemd/system/agent-startup.service ]; then
  cat > /etc/systemd/system/agent-startup.service <<'UNIT'
[Unit]
Description=cloud-agent phase A: reach the box (disk, tailscale, user)
After=network-online.target tailscaled.service systemd-networkd-wait-online.service
Wants=network-online.target tailscaled.service systemd-networkd-wait-online.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/agent-startup
TimeoutStartSec=600

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable agent-startup.service
fi

# --- persistent data disk, discovered by filesystem LABEL (provider-neutral) ---
# OCI paravirtualized volumes appear as /dev/sdb (the /dev/oracleoci/ name is an
# Oracle Linux udev alias that may or may not have landed). Probe all candidates.
mkdir -p "$DATA_MNT"
for cand in "$DATA_DEV" /dev/sdb /dev/vdb; do
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
    # Only a blank provider-attached disk is safe to format.
    if [ -n "$(blkid -o value -s TYPE "$DATA_DEV" 2>/dev/null || true)" ]; then
      echo "!! $DATA_DEV already has a filesystem but no label $DATA_LABEL; NOT reformatting"
    else
      echo ">> formatting fresh data disk $DATA_DEV (label $DATA_LABEL)"
      mkfs.ext4 -F -L "$DATA_LABEL" "$DATA_DEV"
    fi
  else
    echo "!! data device $DATA_DEV not found at first boot"
  fi
fi
if [ -n "$(blkid -L "$DATA_LABEL" 2>/dev/null)" ]; then
  if ! findmnt "$DATA_MNT" >/dev/null 2>&1; then
    # Mount by LABEL, not UUID: blkid -L returns the DEVICE path, and the path
    # can change between boots/provider rebuilds. LABEL= is the stable handle.
    if ! mount -o discard,defaults LABEL="$DATA_LABEL" "$DATA_MNT"; then
      echo "!! could not mount $DATA_MNT (continuing: reachability first)"
    fi
  fi
  if ! grep -qE "[[:space:]]$DATA_MNT[[:space:]]" /etc/fstab; then
    echo "LABEL=$DATA_LABEL $DATA_MNT ext4 discard,defaults,nofail 0 2" >> /etc/fstab
  fi
else
  echo "!! data disk not mountable yet (label $DATA_LABEL absent)"
fi

# --- package-manager-agnostic install helper (sourceable) ---
cat > /usr/local/sbin/pkg-install <<'PKGI'
#!/usr/bin/env bash
# Sourceable helper: install packages with whatever package manager is present.
# Usage: source /usr/local/sbin/pkg-install; pkg_install pkg1 pkg2 ...
pkg_install() {
  if command -v pacman >/dev/null 2>&1; then
    pacman -Syu --noconfirm --needed "$@"
  elif command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq
    apt-get install -y "$@"
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y "$@"
  else
    echo "pkg-install: no supported package manager found (pacman/apt-get/dnf)" >&2
    return 1
  fi
}
PKGI
chmod 755 /usr/local/sbin/pkg-install
source /usr/local/sbin/pkg-install

# --- base tools (tailscale/openssh are already baked into the golden image) ---
pkg_install curl ca-certificates sudo
command -v tailscale >/dev/null 2>&1 || { echo ">> installing tailscale"; pkg_install tailscale; }
command -v sshd >/dev/null 2>&1 || { echo ">> installing openssh"; pkg_install openssh; }

# --- sshd hardening: key-only over Tailscale. The image already hardens this;
# idempotent re-assert is fine. Filename sorts before any provider drop-in
# because sshd keeps the FIRST value it sees for each key.
mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/10-agent-hardening.conf <<'HARD'
PasswordAuthentication no
PermitRootLogin no
KbdInteractiveAuthentication no
HARD
chmod 644 /etc/ssh/sshd_config.d/10-agent-hardening.conf

systemctl enable --now sshd
# `set -e` would abort startup here — before the tailscale join — on a bad drop-in
# (self-DoS), so a failed config test must not be fatal.
if sshd -t 2>/dev/null; then
  systemctl restart sshd
else
  echo "!! sshd -t failed; NOT restarting ssh (check sshd_config.d)"
fi

# --- per-user account (phase B tunes it further) ---
if [ -n "$USER_NAME" ]; then
  if ! id "$USER_NAME" >/dev/null 2>&1; then
    useradd -m -s /usr/bin/zsh "$USER_NAME"
  fi
  echo "$USER_NAME ALL=(ALL:ALL) NOPASSWD: ALL" > /etc/sudoers.d/agent-sudo
  chmod 440 /etc/sudoers.d/agent-sudo
  mkdir -p "/home/$USER_NAME/.ssh"
  printf '%s\n' "$SSHPUB" > "/home/$USER_NAME/.ssh/authorized_keys"
  chown -R "$USER_NAME:$USER_NAME" "/home/$USER_NAME/.ssh"
  chmod 700 "/home/$USER_NAME/.ssh"
  chmod 600 "/home/$USER_NAME/.ssh/authorized_keys"
fi

# --- tailscaled: enable + start. FLAGS="" in /etc/default/tailscaled and the
# override drop-in are baked into the golden image — do not touch those.
systemctl enable --now tailscaled

# --- join the tailnet ---
AUTHKEY=""
if [ -s /etc/agent/authkey ]; then
  AUTHKEY="$(cat /etc/agent/authkey)"
elif [ -n "__AUTHKEY__" ]; then
  mkdir -p /etc/agent
  ( umask 077; echo "__AUTHKEY__" > /etc/agent/authkey )  # subshell: don't leak umask 077
  AUTHKEY="__AUTHKEY__"
fi

# The tailscale client talks to the daemon via a socket that takes a moment to
# appear; wait for it before trying to join.
for _ in $(seq 1 30); do
  [ -S /run/tailscale/tailscaled.sock ] && break
  sleep 1
done

if [ -n "$AUTHKEY" ]; then
  if tailscale up --ssh --hostname="$INSTANCE_NAME" --authkey="$AUTHKEY"; then
    rm -f /etc/agent/authkey
    # The key is spent once joined; don't leave it on disk.
    sed -ri 's/tskey-auth-[A-Za-z0-9_-]+/tskey-auth-SPENT/g' /usr/local/sbin/agent-startup 2>/dev/null || true
  else
    echo ">> tailscale up FAILED: the one-off key is likely spent, revoked or expired."
  fi
elif tailscale status >/dev/null 2>&1; then
  tailscale up --ssh --hostname="$INSTANCE_NAME" \
    || echo ">> tailscale up (no key) returned non-zero; already up?"
else
  echo ">> no tailscale auth key available; this box cannot join the tailnet."
fi

# Let the agent user run `tailscale` without sudo (status/up/set, etc.).
if [ -n "$USER_NAME" ]; then
  tailscale set --operator="$USER_NAME" || true
fi

# --- exit-node watchdog: only use an exit node when DIRECT egress is broken.
# Never force --exit-node=auto:any here: pointing the default route at a phone
# exit node that is offline/relaying silently breaks ALL egress (the box's own
# NAT gateway is normally the right path), which made phase B package installs
# fail with mirror timeouts. tailscaled runs --port=${PORT} from
# /etc/default/tailscaled; keep that file's PORT line intact.
cat > /usr/local/sbin/exit-node-watch <<'DAEMON'
#!/usr/bin/env bash
set -uo pipefail

PROBE_URL="https://ifconfig.me"
INTERVAL=10

note() {
  echo "exit-node-watch: $*"
  logger -t exit-node-watch "$*"
}

egress_ok() {
  curl -4sf --max-time 5 -o /dev/null "$PROBE_URL" 2>/dev/null
}

online_exit_node() {
  tailscale status --json 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
for p in d.get("Peer", {}).values():
    if p.get("ExitNodeOption") and p.get("Online"):
        print(p["DNSName"].split(".")[0])
        sys.exit(0)
sys.exit(1)
' 2>/dev/null
}

exit_node_set() {
  tailscale status --json 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
print("yes" if d.get("ExitNodeStatus") and d["ExitNodeStatus"].get("ID") else "no")
' 2>/dev/null
}

while true; do
  CURRENT="$(exit_node_set)"

  if [ "$CURRENT" = "yes" ]; then
    if ! egress_ok; then
      note "egress probe failed with exit node set; clearing exit node"
      tailscale set --exit-node= || note "clear failed (rc=$?)"
    fi
  elif ! egress_ok; then
    ONLINE="$(online_exit_node)"
    if [ -n "$ONLINE" ]; then
      note "direct egress broken; trying exit node '$ONLINE'"
      tailscale set --exit-node="$ONLINE" || note "set failed (rc=$?)"
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

# --- deferred package install (phase B) ---
cat > /usr/local/sbin/agent-install-packages <<'PKGS'
#!/usr/bin/env bash
set -euo pipefail
# Package-manager-agnostic: works on Arch (pacman) as well as apt-get/dnf hosts.
# On the Arch golden image this resolves to pacman.
source /usr/local/sbin/pkg-install

echo "=== agent packages $(date -u) ==="

# All package operations go through pkg_install — never call pacman/apt/dnf
# directly here. gnupg (not "gpg") is the Arch package providing gpg.
pkg_install git stow tmux python python-pip zsh github-cli fzf gnupg unzip direnv neovim go rust nodejs npm chromium xorg-server-xvfb x11vnc zram-generator

# Trim the package cache: the browser stack is ~3.5G unpacked, and keeping every
# downloaded .pkg.tar.* in /var/cache can swallow gigabytes on a small boot disk.
if command -v pacman >/dev/null 2>&1; then
  pacman -Sc --noconfirm
fi

echo "=== agent packages complete $(date -u) ==="
PKGS
chmod 755 /usr/local/sbin/agent-install-packages

cat > /etc/systemd/system/agent-packages.service <<'UNIT'
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
UNIT

systemctl daemon-reload
systemctl enable agent-packages.service
# Only kick phase B if it is not already running: the unit is enabled, so on
# every boot it starts on its own — restarting it here again would race it.
if ! systemctl is-active --quiet agent-packages; then
  systemctl restart --no-block agent-packages.service
fi

echo ">> phase B (packages + browser stack) is installing in the background."
echo ">>   progress:  journalctl -u agent-packages -f"
echo ">>   state:     systemctl is-active agent-packages"

# --- virtual-display browser stack (packages installed by phase B; config here) ---
cat > /etc/systemd/system/xvfb.service <<'UNIT'
[Unit]
Description=Virtual framebuffer X server (DISPLAY :99)
After=systemd-user-sessions.service

[Service]
ExecStart=/usr/bin/Xvfb :99 -screen 0 1920x1080x24 -nolisten tcp
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT

systemctl enable xvfb.service
# xorg-server-xvfb lands in phase B; if the binary is not here yet the unit
# stays enabled and starts on the next boot once the package has landed.
systemctl start xvfb.service 2>/dev/null \
  || echo ">> Xvfb not installed yet (phase B); will start on next boot"

echo 'export DISPLAY=:99' > /etc/profile.d/display.sh
chmod 644 /etc/profile.d/display.sh

# -nopw on purpose: the unit is never enabled and only runs under `./run
# browser`, which tunnels VNC over SSH — the SSH boundary is the auth. A
# password here would just be an extra secret to lose.
cat > /etc/systemd/system/x11vnc.service <<'UNIT'
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
UNIT

cat > /usr/local/bin/headed-chromium <<'CHROME'
#!/usr/bin/env bash
export DISPLAY="${DISPLAY:-:99}"
export LIBGL_ALWAYS_SOFTWARE=1
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

mkdir -p "$DATA_MNT/browser" "$DATA_MNT/app"
if [ -n "$USER_NAME" ]; then
  chown -R "$USER_NAME:$USER_NAME" "$DATA_MNT/browser" "$DATA_MNT/app"
fi

# --- zram: compressed swap via systemd zram-generator (package lands in phase B) ---
cat > /etc/systemd/zram-generator.conf <<'ZRAM'
[zram0]
zram-size = min(ram / 2, 4096)
compression-algorithm = zstd
ZRAM

systemctl daemon-reload
systemctl start systemd-zram-setup@zram0.service 2>/dev/null || true

touch /run/agent-startup-complete
logger -t agent-startup "agent startup complete"
echo "=== agent startup complete (custom Arch image) $(date -u) ==="
exit 0
