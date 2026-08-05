locals {
  startup_script = <<-EOT
    #!/usr/bin/env bash
    set -euo pipefail
    exec > >(tee /var/log/startup-agent.log) 2>&1
    echo "=== agent startup $(date -u) ==="

    export DEBIAN_FRONTEND=noninteractive
    APT="apt-get -o DPkg::Lock::Timeout=300 -o Dpkg::Options::=--force-confold"

    DATA_DEV="/dev/disk/by-id/google-data"
    DATA_MNT="/mnt/data"
    USER_NAME="${var.ssh_user}"

    mkdir -p "$DATA_MNT"
    if ! blkid "$DATA_DEV" >/dev/null 2>&1; then
      echo ">> formatting fresh data disk"
      mkfs.ext4 -F "$DATA_DEV"
    fi
    if ! findmnt "$DATA_MNT" >/dev/null 2>&1; then
      mount -o discard,defaults "$DATA_DEV" "$DATA_MNT"
    fi
    if ! grep -q "$DATA_MNT" /etc/fstab; then
      DISK_UUID=$(blkid -s UUID -o value "$DATA_DEV")
      echo "UUID=$DISK_UUID $DATA_MNT ext4 discard,defaults,nofail 0 2" >> /etc/fstab
    fi

    $APT update
    $APT install -y curl ca-certificates sudo
    if ! command -v tailscale >/dev/null 2>&1; then
      curl -fsSL https://tailscale.com/install.sh | sh
    fi

    mkdir -p "$DATA_MNT/tailscale"
    if [ -L /var/lib/tailscale ]; then
      rm /var/lib/tailscale
    fi
    mkdir -p /var/lib/tailscale
    if ! findmnt /var/lib/tailscale >/dev/null 2>&1; then
      mount --bind "$DATA_MNT/tailscale" /var/lib/tailscale
    fi
    if ! grep -qE "[[:space:]]/var/lib/tailscale[[:space:]]" /etc/fstab; then
      echo "$DATA_MNT/tailscale /var/lib/tailscale none bind,nofail 0 0" >> /etc/fstab
    fi

    if ! id "$USER_NAME" >/dev/null 2>&1; then
      useradd -m -G sudo -s /bin/bash "$USER_NAME"
    fi
    echo '%sudo ALL=(ALL:ALL) NOPASSWD: ALL' > /etc/sudoers.d/agent-sudo
    chmod 440 /etc/sudoers.d/agent-sudo

    systemctl enable --now ssh

    systemctl enable --now tailscaled

    TS_STATE=""
    for _ in $(seq 1 15); do
      TS_STATE="$(tailscale status --json 2>/dev/null |
        sed -n 's/.*"BackendState": *"\([^"]*\)".*/\1/p' | head -1)"
      [ -n "$TS_STATE" ] && break
      sleep 1
    done
    echo ">> tailscale BackendState=$${TS_STATE:-unknown}"

    if [ "$TS_STATE" = "Running" ]; then
      tailscale up --ssh --hostname=${var.instance_name} \
        || echo ">> tailscale up (no key) returned non-zero; already up?"
    else
      tailscale up --ssh --hostname=${var.instance_name} --authkey='${var.tailscale_auth_key}' ||
        echo ">> tailscale up FAILED: the one-off key is likely spent, revoked or expired.
        >> Recover with:  ./run rekey     (mints a key and re-runs this script over IAP)"
    fi

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
export DISPLAY="$${DISPLAY:-:99}"
export LIBGL_ALWAYS_SOFTWARE=1
exec chromium --no-first-run --no-default-browser-check \
  --disable-blink-features=AutomationControlled \
  --ignore-gpu-blocklist --use-gl=angle --use-angle=gl \
  --window-size="$${BROWSER_WINDOW_SIZE:-1920,1080}" \
  --remote-debugging-port="$${CDP_PORT:-9222}" \
  --user-data-dir="$${BROWSER_PROFILE_DIR:-/mnt/data/browser/default}" \
  "$@"
CHROME
    chmod +x /usr/local/bin/headed-chromium

    mkdir -p "$DATA_MNT/browser" "$DATA_MNT/app"
    chown -R "$USER_NAME:$USER_NAME" "$DATA_MNT/browser" "$DATA_MNT/app"

    cat > /usr/local/sbin/agent-install-packages <<'PKGS'
#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
APT="apt-get -o DPkg::Lock::Timeout=600 -o Dpkg::Options::=--force-confold"

echo "=== agent packages $(date -u) ==="
$APT update

echo ">> wave 1: CLI tools"
$APT install -y git stow tmux neovim python3-pip zsh

AGENT_USER="$(getent passwd | awk -F: '$3 >= 1000 && $3 < 60000 { print $1; exit }')"
if [ -n "$AGENT_USER" ] && command -v zsh >/dev/null 2>&1; then
  chsh -s /usr/bin/zsh "$AGENT_USER"
  echo ">> default shell for $AGENT_USER -> zsh"
fi

echo ">> wave 2: upgrade + headed-browser stack"
$APT upgrade -y
$APT install -y build-essential xvfb xauth chromium \
  fonts-liberation fonts-noto-core zram-tools \
  x11vnc python3-venv libgl1-mesa-dri

echo "=== agent packages complete $(date -u) ==="
PKGS
    chmod +x /usr/local/sbin/agent-install-packages

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
    systemctl restart --no-block agent-packages.service

    echo ">> phase B (packages + browser stack) is installing in the background."
    echo ">>   progress:  journalctl -u agent-packages -f"
    echo ">>   state:     systemctl is-active agent-packages"

    touch /run/agent-startup-complete
    logger -t agent-startup "agent startup complete"
    echo "=== agent startup complete $(date -u) ==="
  EOT
}
