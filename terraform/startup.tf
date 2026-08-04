# startup.tf — first-boot + every-boot provisioning, Debian 12.
#
# TWO PHASES, and the split is the point:
#   A (foreground, ~30-60s): only what is needed to REACH this box — mount the
#     data disk, install tailscale, create the user, join the tailnet. The auth
#     key is single-use and spent at the end of A, so every second here is a
#     second the VM is unreachable, undebuggable, and wait-ready looks hung.
#   B (background, ~4 min): everything else — apt upgrade, CLI tools, the
#     headed-browser stack. Runs as agent-packages.service, started
#     --no-block, so the metadata runner returns immediately.
# Idempotent: safe on every boot.
#
# STATE: tailscaled keeps identity at /var/lib/tailscale. It is bind-mounted
# from the data disk (NOT a symlink — systemd refuses a symlinked
# StateDirectory=), so identity survives rebuilds.
#
# ESCAPING (footgun): in an HCL heredoc `$$` is an escape only before `{`.
# Write bare `$VAR`, `$@`, `$?`; `$${VAR}` renders `${VAR}` but `$$VAR` renders
# as two literal dollars = bash PID. compute.tf preconditions reject any `$$`.

locals {
  startup_script = <<-EOT
    #!/usr/bin/env bash
    set -euo pipefail
    exec > >(tee /var/log/startup-agent.log) 2>&1
    echo "=== agent startup $(date -u) ==="

    export DEBIAN_FRONTEND=noninteractive
    # --force-confold: dpkg conffile prompts read stdin, which doesn't exist
    # here; a left half-configured package (`iU`) breaks every later apt run,
    # and DEBIAN_FRONTEND does not govern conffile prompts (see operating.md).
    APT="apt-get -o DPkg::Lock::Timeout=300 -o Dpkg::Options::=--force-confold"

    DATA_DEV="/dev/disk/by-id/google-data"
    DATA_MNT="/mnt/data"
    USER_NAME="${var.ssh_user}"

    # ==================================================================
    # PHASE A — the critical path to a reachable box. Keep this SMALL.
    # ==================================================================

    # A1. Mount the persistent data disk
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

    # A2. Tailscale (vendor repo — Debian's lags years). Only the installer's
    # own prerequisites are ensured here; they ship on the image anyway.
    $APT update
    $APT install -y curl ca-certificates sudo
    if ! command -v tailscale >/dev/null 2>&1; then
      curl -fsSL https://tailscale.com/install.sh | sh
    fi

    # A3. Persist tailscale state on the data disk (bind-mount, not symlink —
    # systemd refuses a symlinked StateDirectory=).
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

    # A4. Create the user (passwordless sudo; access is already gated by
    # tailnet ACLs). Must exist before `tailscale up` — Tailscale SSH maps
    # tailnet identity onto this local account.
    if ! id "$USER_NAME" >/dev/null 2>&1; then
      useradd -m -G sudo -s /bin/bash "$USER_NAME"
    fi
    echo '%sudo ALL=(ALL:ALL) NOPASSWD: ALL' > /etc/sudoers.d/agent-sudo
    chmod 440 /etc/sudoers.d/agent-sudo

    # A5. sshd for the IAP break-glass path only (no public :22).
    systemctl enable --now ssh

    # A6. Join the tailnet. The single-use key is spent HERE; on a reboot the
    # node identity lives on the data disk, so `up` with a consumed key would
    # fail — the no-key branch is a harmless reassert of --ssh.
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
      # First boot, or a deleted node (netmap 404s) — a fresh key re-registers.
      tailscale up --ssh --hostname=${var.instance_name} --authkey='${var.tailscale_auth_key}' ||
        echo ">> tailscale up FAILED: the one-off key is likely spent, revoked or expired.
        >> Recover with:  ./run rekey     (mints a key and re-runs this script over IAP)"
    fi

    # A7. Browser-stack files (no packages, so effectively free — the
    # PACKAGES install in phase B, letting verify.sh assert the wrapper
    # contents without waiting for chromium to exist). Files are written
    # before phase B; do not write a literal doubled dollar in this heredoc.

    # A7a. Virtual display. Local only; enabled in phase B once Xvfb exists.
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

    # A7b. Every login shell (and tmux) gets the display by default.
    echo 'export DISPLAY=:99' > /etc/profile.d/display.sh

    # A7c. x11vnc: the ONLY way to interact with the browser on :99 by hand —
    # a one-time login (password/2FA) can't be automated without handing
    # credentials to a script. Loopback-bound (reach via `ssh -L 5900:...`),
    # -nopw safe only because of that bind; NOT enabled, started by hand and
    # stopped after the login (`./run browser` drives the whole flow).
    # Deliberately no window manager: the measured fingerprint-matching config
    # needs xauth, not a WM.
    cat > /etc/systemd/system/x11vnc.service <<'UNIT'
[Unit]
Description=x11vnc on DISPLAY :99, loopback only (manual start, for hand-login)
After=xvfb.service
Requires=xvfb.service

[Service]
Environment=DISPLAY=:99
ExecStart=/usr/bin/x11vnc -display :99 -localhost -nopw -forever -shared -noxdamage
# x11vnc traps SIGTERM and exits 2, so a plain `systemctl stop` leaves the unit
# "Failed (exit-code)" forever — looking like a real fault on a box whose
# correct state is "stopped, login finished". Measured status=2/INVALIDARGUMENT.
SuccessExitStatus=2
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT

    # A7d. headed-chromium: a real browser on :99 with CDP + persistent profile,
    # for agents and scrapers. The only wrapper — an app that needs a browser
    # tied to a logged-in account deploys its own (see decisions/browser.md).
    cat > /usr/local/bin/headed-chromium <<'CHROME'
#!/usr/bin/env bash
# Headed Chromium on the virtual display, for agents + scrapers.
#   DISPLAY              default :99 (the Xvfb screen)
#   BROWSER_PROFILE_DIR  default /mnt/data/browser/default (survives rebuilds)
#   CDP_PORT             default 9222 (use a different port per agent/browser)
#   BROWSER_WINDOW_SIZE  default 1920,1080 (the whole framebuffer)
# AutomationControlled is disabled so navigator.webdriver stays false.
export DISPLAY="$${DISPLAY:-:99}"
# Software WebGL: without it getContext('webgl') returns null on this GPU-less
# box, silently breaking any app under test that touches WebGL. ANGLE is routed
# at Mesa/llvmpipe, not SwiftShader — see decisions/browser.md.
export LIBGL_ALWAYS_SOFTWARE=1
# WINDOW SIZE: Xvfb is 1920x1080 but Chromium without a WM opens at its default
# size, leaving most of the framebuffer black — which is what you actually see
# over VNC. Pin the window to the display.
exec chromium --no-first-run --no-default-browser-check \
  --disable-blink-features=AutomationControlled \
  --ignore-gpu-blocklist --use-gl=angle --use-angle=gl \
  --window-size="$${BROWSER_WINDOW_SIZE:-1920,1080}" \
  --remote-debugging-port="$${CDP_PORT:-9222}" \
  --user-data-dir="$${BROWSER_PROFILE_DIR:-/mnt/data/browser/default}" \
  "$@"
CHROME
    chmod +x /usr/local/bin/headed-chromium

    # A7e. Agent-writable profile root + deployed app dir on the data disk
    # (/mnt/data is root-owned; agents run as your user and create their own
    # subdirs). Only browser/ parent is created — Chromium creates its own
    # --user-data-dir.
    mkdir -p "$DATA_MNT/browser" "$DATA_MNT/app"
    chown -R "$USER_NAME:$USER_NAME" "$DATA_MNT/browser" "$DATA_MNT/app"

    # A8. Phone notifications: the VM is the SSH *client*, dialing out to
    # Termux's sshd over the tailnet. No forwarding, no sshd change here.
    # Keypair + known_hosts on the data disk, so a rebuild doesn't re-add the
    # pubkey to the phone.
    TERMUX_HOST="${var.termux_host}"
    TERMUX_USER="${var.termux_ssh_user}"
    if [ -n "$TERMUX_HOST" ] && [ -n "$TERMUX_USER" ]; then
      TERMUX_DIR="$DATA_MNT/ssh-termux"
      mkdir -p "$TERMUX_DIR"
      if [ ! -f "$TERMUX_DIR/id_ed25519" ]; then
        ssh-keygen -t ed25519 -N "" -f "$TERMUX_DIR/id_ed25519" \
          -C "$USER_NAME@${var.instance_name}-notify-phone"
        echo ">> generated notify-phone keypair; public key follows (add to phone's ~/.ssh/authorized_keys):"
        cat "$TERMUX_DIR/id_ed25519.pub"
      fi
      touch "$TERMUX_DIR/known_hosts"
      chown -R "$USER_NAME:$USER_NAME" "$TERMUX_DIR"
      chmod 700 "$TERMUX_DIR"
      chmod 600 "$TERMUX_DIR/id_ed25519" "$TERMUX_DIR/known_hosts"
      chmod 644 "$TERMUX_DIR/id_ed25519.pub"

      mkdir -p /etc/ssh/ssh_config.d
      cat > /etc/ssh/ssh_config.d/99-termux.conf <<SSHCFG
Host termux-phone
  HostName $TERMUX_HOST
  Port ${var.termux_ssh_port}
  User $TERMUX_USER
  IdentityFile $TERMUX_DIR/id_ed25519
  UserKnownHostsFile $TERMUX_DIR/known_hosts
  StrictHostKeyChecking accept-new
  ConnectTimeout 5
  BatchMode yes
SSHCFG

      cat > /usr/local/bin/notify-phone <<'NOTIFY'
#!/usr/bin/env bash
# notify-phone "<title>" "<message>" [extra termux-notification flags...]
# Dials out to Termux sshd over the tailnet (see 99-termux.conf). Extra flags
# pass straight through to termux-notification. Args are %q-escaped so ssh
# re-joins argv with spaces without eating your quoting.
CMD="termux-notification"
printf -v ARGS ' %q' -t "$${1:-Agent}" -c "$${2:-}" "$${@:3}"
# -n is load-bearing: without it ssh reads our stdin, so calling notify-phone
# from inside a loop or a piped script silently swallows the caller's input.
exec ssh -n termux-phone "$CMD$ARGS"
NOTIFY
      chmod +x /usr/local/bin/notify-phone
    else
      echo ">> notify-phone skipped: TF_VAR_termux_host or TF_VAR_termux_ssh_user is empty"
    fi

    # A9. PHASE B — hand off the slow work and get out of the way. A real
    # systemd unit, not a backgrounded subshell: the metadata runner waits for
    # its children, and this script's stdout is a tee pipe an inherited fd
    # would hold open. Enabled oneshot = re-runs on every boot to self-heal.
    cat > /usr/local/sbin/agent-install-packages <<'PKGS'
#!/usr/bin/env bash
# Deferred package install: everything not needed to reach this box.
# Idempotent — apt is a no-op when the packages are current.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
# --force-confold is load-bearing: dpkg conffile prompts read stdin, which
# doesn't exist here, and a half-configured package fails every later apt run
# (see operating.md). DEBIAN_FRONTEND governs debconf, not dpkg.
APT="apt-get -o DPkg::Lock::Timeout=600 -o Dpkg::Options::=--force-confold"

echo "=== agent packages $(date -u) ==="
$APT update

# Wave 1: the CLI tools you want the moment you log in.
echo ">> wave 1: CLI tools"
$APT install -y git stow tmux neovim python3-pip zsh

# The dotfiles are zsh-centric, so the agent user's default shell is zsh.
# phase A created exactly one interactive account (uid >= 1000); pick it
# rather than hardcoding a username. Idempotent.
AGENT_USER="$(getent passwd | awk -F: '$3 >= 1000 && $3 < 60000 { print $1; exit }')"
if [ -n "$AGENT_USER" ] && command -v zsh >/dev/null 2>&1; then
  chsh -s /usr/bin/zsh "$AGENT_USER"
  echo ">> default shell for $AGENT_USER -> zsh"
fi

# Wave 2: the heavy stuff. chromium alone pulls ~200MB of codec libraries.
echo ">> wave 2: upgrade + headed-browser stack"
$APT upgrade -y
# libgl1-mesa-dri is explicit even though chromium pulls it in: it provides
# swrast_dri.so (llvmpipe), which is what makes WebGL work at all on this
# GPU-less box. A fingerprint-relevant dependency should not be left implicit.
$APT install -y build-essential xvfb xauth chromium \
  fonts-liberation fonts-noto-core zram-tools \
  x11vnc python3-venv libgl1-mesa-dri

# Wave 2b: Node.js LTS from the vendor apt repo. bookworm ships nodejs 18
# (EOL April 2025); the vendor repo is an apt source, so it gets updates
# (same pattern as Tailscale in phase A). Node, not Python, because the
# extension/controller are already JavaScript.
echo ">> wave 2b: node.js LTS"
if ! command -v node >/dev/null 2>&1; then
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key |
    gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
  chmod 0644 /etc/apt/keyrings/nodesource.gpg
  echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_24.x nodistro main" \
    > /etc/apt/sources.list.d/nodesource.list
  $APT update
fi
$APT install -y nodejs
echo ">> node $(node --version), npm $(npm --version)"

# Wave 2c: opencode — the agent runner, and the whole point of the machine.
# PINNED, not floating (this box runs other people's work); bump deliberately.
# Installed from the release tarball, not the vendor script: that installs into
# $HOME/.opencode and rewrites shell rc files — both wrong once there is one
# Unix user per client. A root-owned binary in /usr/local/bin is shared by every
# client account and none can modify it. linux-x64 vs -baseline picked by avx2;
# a silent SIGILL on a missing instruction set would be miserable to find.
OPENCODE_VERSION="1.18.11"
if [ "$(opencode --version 2>/dev/null)" != "$OPENCODE_VERSION" ]; then
  echo ">> wave 2c: opencode $OPENCODE_VERSION"
  oc_target="linux-x64"
  grep -qwi avx2 /proc/cpuinfo || oc_target="linux-x64-baseline"
  oc_tmp="$(mktemp -d)"
  if curl -fsSL -o "$oc_tmp/oc.tar.gz" \
    "https://github.com/anomalyco/opencode/releases/download/v$${OPENCODE_VERSION}/opencode-$${oc_target}.tar.gz"; then
    tar -xzf "$oc_tmp/oc.tar.gz" -C "$oc_tmp"
    install -m 0755 -o root -g root "$oc_tmp/opencode" /usr/local/bin/opencode
    echo ">> opencode $(/usr/local/bin/opencode --version 2>&1) ($oc_target)"
  else
    # Not fatal: phase B must not leave the box unusable because GitHub is down.
    echo "!! opencode download failed; box still usable, re-run the startup script" >&2
  fi
  rm -rf "$oc_tmp"
else
  echo ">> opencode $OPENCODE_VERSION already installed"
fi

# zram compressed swap. Written AFTER the install, for the conffile reason
# above. apt auto-starts zramswap with a fallback size at install time, so a
# restart (not enable --now) is what deterministically applies our sizing.
# Measured: 0B in use on 8 GB today; kept for the multi-agent workload where
# several browsers + toolchains at once is exactly what swap headroom is for.
echo ">> configuring zram swap"
printf 'ALGO=zstd\nPERCENT=50\n' > /etc/default/zramswap

# Now that the packages exist, start the units whose files phase A wrote.
# x11vnc is deliberately NOT enabled: started by hand for a login, then stopped.
echo ">> enabling xvfb + zram"
systemctl daemon-reload
systemctl enable --now xvfb
systemctl enable zramswap
systemctl restart zramswap

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
# RemainAfterExit is what makes `systemctl is-active` a usable state machine
# (activating=installing / active=finished / failed=broken); verify-browser.sh
# reads it to tell "not ready yet" (SKIP) apart from "broken" (FAIL).
RemainAfterExit=yes
ExecStart=/usr/local/sbin/agent-install-packages
TimeoutStartSec=3600

[Install]
WantedBy=multi-user.target
UNIT

    systemctl daemon-reload
    systemctl enable agent-packages.service
    # `restart`, NOT `start`: a oneshot with RemainAfterExit=yes stays "active
    # (exited)" after success, so `start` would be a silent no-op on a rerun —
    # breaking the self-healing this file claims. `--no-block`: do not wait.
    systemctl restart --no-block agent-packages.service

    echo ">> phase B (packages + browser stack) is installing in the background."
    echo ">>   progress:  journalctl -u agent-packages -f"
    echo ">>   state:     systemctl is-active agent-packages"

    # --- Completion marker, delivered THREE ways on purpose ---------------
    # `echo` alone is not reliable for the FINAL line: stdout is a tee process
    # substitution bash doesn't wait to flush into the metadata pipe, so the
    # line can be lost from the journal/serial console. wait-ready.sh polls the
    # serial console, so losing it turns a healthy 84s boot into a ten-minute
    # timeout that looks like a hung VM (measured). 1. sentinel file — checked
    # over SSH; /run is tmpfs so it's correctly per-boot. 2. logger — writes to
    # the journal synchronously, independent of the tee pipe. 3. echo — the
    # human-readable on-disk log.
    touch /run/agent-startup-complete
    logger -t agent-startup "agent startup complete"
    echo "=== agent startup complete $(date -u) ==="
  EOT
}
