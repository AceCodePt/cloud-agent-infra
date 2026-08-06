#!/usr/bin/env bash
set -euo pipefail
umask 022
exec > >(tee /var/log/startup-agent.log) 2>&1
echo "=== agent startup $(date -u) ==="

export DEBIAN_FRONTEND=noninteractive
APT="apt-get -o DPkg::Lock::Timeout=300 -o Dpkg::Options::=--force-confold"

DATA_LABEL="__DATA_LABEL__"
DATA_DEV="__DATA_DEV__"
DATA_MNT="/mnt/data"
USER_NAME="__USER__"
INSTANCE_NAME="__INSTANCE__"

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
After=network-online.target
Wants=network-online.target

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
mkdir -p "$DATA_MNT"
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

$APT update
$APT install -y curl ca-certificates sudo
if ! command -v tailscale >/dev/null 2>&1; then
  echo ">> installing tailscale (install.sh fetched, sanity-checked, executed)"
  TS_INSTALL="$(mktemp)"
  if curl -fsSL https://tailscale.com/install.sh -o "$TS_INSTALL"; then
    # Never run a remote script unvetted; the repo key still GPG-verifies what it installs.
    if head -n1 "$TS_INSTALL" | grep -qE '^#!.*(ba)?sh' \
        && grep -qiE 'pkgs\.tailscale\.com' "$TS_INSTALL"; then
      bash "$TS_INSTALL"
    else
      echo "!! tailscale install.sh failed sanity checks; refusing to execute"
    fi
  else
    echo "!! could not fetch tailscale install.sh"
  fi
  rm -f "$TS_INSTALL"
fi

mkdir -p "$DATA_MNT/tailscale"
if [ -L /var/lib/tailscale ]; then
  rm /var/lib/tailscale
fi
mkdir -p /var/lib/tailscale
# If /var/lib/tailscale is bound to a directory that is NOT the data volume's
# (e.g. a degraded early boot before the volume mounted), re-point it.
CUR_SRC="$(findmnt -no SOURCE /var/lib/tailscale 2>/dev/null || true)"
if [ -n "$CUR_SRC" ] && [ "$CUR_SRC" != "$DATA_MNT/tailscale" ]; then
  echo ">> /var/lib/tailscale was bound to $CUR_SRC; re-pointing to the data volume"
  umount /var/lib/tailscale 2>/dev/null || true
  CUR_SRC=""
fi
if ! findmnt /var/lib/tailscale >/dev/null 2>&1; then
  mount --bind "$DATA_MNT/tailscale" /var/lib/tailscale
fi
if ! grep -qE "[[:space:]]/var/lib/tailscale[[:space:]]" /etc/fstab; then
  echo "$DATA_MNT/tailscale /var/lib/tailscale none bind,nofail 0 0" >> /etc/fstab
fi

if [ -n "$USER_NAME" ]; then
  if ! id "$USER_NAME" >/dev/null 2>&1; then
    useradd -m -G sudo -s /bin/bash "$USER_NAME"
  fi
  echo "$USER_NAME ALL=(ALL:ALL) NOPASSWD: ALL" > /etc/sudoers.d/agent-sudo
  chmod 440 /etc/sudoers.d/agent-sudo
fi

# sshd hardening: this is what keeps the only "other way in" to a physical
# console (Hetzner web console, GCP serial console). Key-only over Tailscale.
# Filename sorts BEFORE cloud-init's 50-cloud-init.conf because sshd keeps the
# FIRST value it sees — a 99- drop-in would lose to cloud-init's
# "PasswordAuthentication yes".
mkdir -p /etc/ssh/sshd_config.d
rm -f /etc/ssh/sshd_config.d/99-agent-hardening.conf
cat > /etc/ssh/sshd_config.d/10-agent-hardening.conf <<'HARD'
PasswordAuthentication no
PermitRootLogin no
KbdInteractiveAuthentication no
HARD
chmod 644 /etc/ssh/sshd_config.d/10-agent-hardening.conf

systemctl enable --now ssh
systemctl restart ssh
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

TS_STATE=""
for _ in $(seq 1 15); do
  TS_STATE="$(tailscale status --json 2>/dev/null |
    sed -n 's/.*"BackendState": *"\([^"]*\)".*/\1/p' | head -1)"
  [ -n "$TS_STATE" ] && break
  sleep 1
done
echo ">> tailscale BackendState=${TS_STATE:-unknown}"

TS_JOINED=0
if [ "$TS_STATE" = "Running" ]; then
  TS_JOINED=1
  tailscale up --ssh --hostname="$INSTANCE_NAME" \
    || echo ">> tailscale up (no key) returned non-zero; already up?"
elif [ -n "$AUTHKEY" ]; then
  if tailscale up --ssh --hostname="$INSTANCE_NAME" --authkey="$AUTHKEY"; then
    TS_JOINED=1
  else
    echo ">> tailscale up FAILED: the one-off key is likely spent, revoked or expired.
    >> Recover with:  ./run rekey     (writes a key over SSH and restarts agent-startup)"
  fi
else
  echo ">> no tailscale auth key available; this box cannot join the tailnet."
fi

# The key is spent once joined; don't leave it on disk.
if [ "$TS_JOINED" = 1 ]; then
  rm -f /etc/agent/authkey
  sed -ri 's/tskey-auth-[A-Za-z0-9_-]+/tskey-auth-SPENT/g' /usr/local/sbin/agent-startup 2>/dev/null || true
fi

# Let the agent user run `tailscale` without sudo (status/up/set, etc.).
# Same as the manual `sudo tailscale set --operator=$USER`, run from a login
# shell — but this script runs as root, so name the user explicitly.
if [ -n "$USER_NAME" ]; then
  sudo tailscale set --operator="$USER_NAME" \
    || echo ">> tailscale set --operator failed (tailscale may not be up yet)"
fi
tailscale set --exit-node=auto:any \
  || echo ">> tailscale set --exit-node=auto:any failed (tailscale may not be up yet)"

# --- exit-node watchdog: probe egress, reset the exit node on failure, heal to auto ---
cat > /usr/local/sbin/exit-node-watch <<'DAEMON'
#!/usr/bin/env bash
set -uo pipefail

PROBE_URL="https://ifconfig.me"
INTERVAL=5

note() {
  echo "exit-node-watch: $*"
  logger -t exit-node-watch "$*"
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

while true; do
  CURRENT="$(tailscale get exit-node 2>/dev/null || true)"

  if [ -n "$CURRENT" ]; then
    if ! curl -4s --max-time 5 -o /dev/null "$PROBE_URL" 2>/dev/null; then
      note "egress probe failed (exit-node=$CURRENT); resetting exit node"
      tailscale set --exit-node= || note "reset failed (rc=$?)"
    fi
  else
    ONLINE="$(online_exit_node)"
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

# --- virtual-display browser stack (phase B is deferred; this is the config) ---
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
systemctl start xvfb.service

echo 'export DISPLAY=:99' > /etc/profile.d/display.sh
chmod 644 /etc/profile.d/display.sh

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
exec chromium --no-first-run --no-default-browser-check \
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

cat > /usr/local/sbin/agent-install-packages <<'PKGS'
#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
APT="apt-get -o DPkg::Lock::Timeout=600 -o Dpkg::Options::=--force-confold"

echo "=== agent packages $(date -u) ==="
$APT update

echo ">> wave 1: CLI tools"
$APT install -y git stow tmux neovim python3-pip zsh gh fzf direnv gpg

# The account phase A created. Pinned by name (not a uid heuristic) so a
# cloud-init default user on a non-GCP image cannot hijack the usermod.
# usermod -s writes /etc/passwd directly; chsh goes through PAM, which rejects
# the change because the root account is password-locked ("Authentication token
# is no longer valid") — so never use chsh here.
AGENT_USER="__USER__"
if [ -n "$AGENT_USER" ] && command -v zsh >/dev/null 2>&1; then
  usermod -s /usr/bin/zsh "$AGENT_USER"
  echo ">> default shell for $AGENT_USER -> zsh"
fi

echo ">> mise (version manager, via Debian extrepo)"
if ! command -v mise >/dev/null 2>&1; then
  $APT install -y extrepo
  extrepo enable mise
  $APT update
fi
$APT install -y mise

if [ -n "$AGENT_USER" ] && command -v mise >/dev/null 2>&1; then
  echo ">> go@latest for $AGENT_USER via mise"
  sudo -u "$AGENT_USER" env HOME="/home/$AGENT_USER" mise use -g go@latest
fi

echo ">> wave 2: upgrade + headed-browser stack"
$APT upgrade -y
$APT install -y build-essential xvfb xauth chromium \
  fonts-liberation fonts-noto-core zram-tools \
  x11vnc python3-venv libgl1-mesa-dri unattended-upgrades

echo ">> unattended-upgrades: auto-install security/updates, never reboot"
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'UPR'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
UPR
cat > /etc/apt/apt.conf.d/90-agent-unattended <<'UPU'
Unattended-Upgrade::Origins-Pattern {
    "origin=Debian,codename=${distro_codename},label=Debian-Security";
    "origin=Debian,codename=${distro_codename},label=Debian";
};
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Automatic-Reboot-Time "03:00";
UPU
systemctl enable apt-daily-upgrade.timer
systemctl start apt-daily-upgrade.timer

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

touch /run/agent-startup-complete
logger -t agent-startup "agent startup complete"
echo "=== agent startup complete $(date -u) ==="
