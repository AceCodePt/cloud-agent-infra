# startup.tf
#
# Runs on first boot (and every boot) via the GCE Linux Guest Environment.
# Debian 12 (bookworm) — the "boring" choice: Google-maintained image that is
# always fresh, deterministic apt, unattended security updates out of the box.
#
# TWO PHASES, and the split is the point.
#
# PHASE A (foreground, ~30-60s) does only what is required to REACH this box:
# mount the data disk, install tailscale, create the user, join the tailnet. The
# auth key is single-use and is spent at the end of phase A, so every second
# spent here is a second in which the VM is unreachable, undebuggable (there is
# no public inbound), and `wait-ready` looks like a hang.
#
# PHASE B (background, ~4 min) is everything else: apt upgrade, the CLI tools,
# and the headed-browser stack (chromium + fonts + xvfb + zram). It runs as
# agent-packages.service, started with `systemctl start --no-block`, so the
# metadata script runner returns immediately.
#
# This ordering was earned: with the browser stack in the foreground the key was
# not consumed until ~4m52s into the boot (measured: instance created 10:28:16Z,
# `tailscale up` at 10:33:08Z), and a wrong key meant a five-minute wait before
# the failure even surfaced. Chromium's codec dependencies are ~200MB and have
# nothing to do with reachability.
#
# Phase A, in order:
#   1. Mount the persistent data disk at /mnt/data (idempotent, fstab-persisted).
#   2. Install Tailscale from the vendor repo.
#   3. Bind-mount tailscale state onto the data disk (identity survives rebuilds).
#   4. Create your user (sudo group, passwordless sudo).
#   5. Ensure sshd is enabled (IAP break-glass path only; no public :22).
#   6. Join the tailnet with Tailscale SSH.  <-- the auth key is spent HERE
#   7. Write the browser-stack files (units, wrappers, config: all instant).
#   8. Phone notifications: the notify-phone keypair and wrapper.
#   9. Hand the slow work to phase B and exit.
#
# Idempotent: safe on every boot. apt installs are no-ops when current; guards
# prevent double-format and double-user-create; tailscaled keeps its own state;
# phase B is a normal enabled unit, so it re-runs (and self-heals) each boot.
#
# STATE: tailscaled stores state at /var/lib/tailscale. To keep it across VM
# *rebuilds*, we bind-mount the persistent disk's tailscale dir over it before
# starting the daemon (a symlink breaks systemd's StateDirectory=).
#
# ESCAPING (footgun): inside this heredoc, HCL only treats `$$` as an escape
# when it precedes `{`. So `$${VAR}` correctly yields `${VAR}`, but `$$VAR`,
# `$$@` and `$$?` are NOT escapes — they render as two literal dollars, which
# bash then expands as `$$` (the PID). Write bare `$VAR`, `$@`, `$?`: a `$` not
# followed by `{` passes through untouched. Verify against what was really
# rendered (`gcloud compute instances describe ... startup-script`), never
# against a hand-rolled unescape — searching the rendered script for any
# remaining `$$` catches this class of bug immediately.

locals {
  startup_script = <<-EOT
    #!/usr/bin/env bash
    set -euo pipefail
    exec > >(tee /var/log/startup-agent.log) 2>&1
    echo "=== agent startup $(date -u) ==="

    export DEBIAN_FRONTEND=noninteractive
    # DPkg::Lock::Timeout — unattended-upgrades may hold the dpkg lock early in boot.
    #
    # --force-confold — every apt call in this script needs it, not just phase B's.
    # Any package whose conffile already exists on disk makes dpkg stop and ask on
    # stdin, and there is no stdin here: it dies with "end of file on stdin at
    # conffile prompt" and exits 100. Worse, that leaves the package half-configured
    # (dpkg state `iU`), and every SUBSEQUENT `apt-get install` — including this
    # one, on every future boot — tries to configure it again and fails the same
    # way. With `set -e` that aborts phase A before `tailscale up`, so the box stops
    # being reachable AND stops being able to re-key itself. Measured exactly that.
    # DEBIAN_FRONTEND=noninteractive does not help: it governs debconf, not dpkg
    # conffile prompts.
    APT="apt-get -o DPkg::Lock::Timeout=300 -o Dpkg::Options::=--force-confold"

    DATA_DEV="/dev/disk/by-id/google-data"
    DATA_MNT="/mnt/data"
    USER_NAME="${var.ssh_user}"

    # ==================================================================
    # PHASE A — the critical path to a reachable box. Keep this SMALL.
    # ==================================================================

    # --- A1. Mount the persistent data disk -------------------------------
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

    # --- A2. Tailscale ----------------------------------------------------
    # Only the three packages tailscale's installer itself needs are ensured
    # here; they ship on the debian-cloud image, so this is normally a no-op
    # that just primes the apt cache. Everything else waits for phase B.
    # Tailscale comes from the vendor repo — Debian's own package lags years.
    $APT update
    $APT install -y curl ca-certificates sudo
    if ! command -v tailscale >/dev/null 2>&1; then
      curl -fsSL https://tailscale.com/install.sh | sh
    fi

    # --- A3. Persist tailscale state on the data disk ---------------------
    # Bind-mount, NOT a symlink: the distro tailscaled.service sets
    # StateDirectory=tailscale, and systemd refuses to enter /var/lib/tailscale
    # when it's a symlink (status=238/STATE_DIRECTORY "Too many levels of
    # symbolic links"). A bind mount looks like a real directory to systemd.
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

    # --- A4. Create the user (passwordless sudo) --------------------------
    # Before `tailscale up`: Tailscale SSH maps your tailnet identity onto this
    # local account, so it has to exist for the very first login to work.
    if ! id "$USER_NAME" >/dev/null 2>&1; then
      useradd -m -G sudo -s /bin/bash "$USER_NAME"
    fi
    # NOPASSWD: useradd leaves the account password-locked, so a passworded
    # sudo could never authenticate. Access is already gated by tailnet ACLs.
    echo '%sudo ALL=(ALL:ALL) NOPASSWD: ALL' > /etc/sudoers.d/agent-sudo
    chmod 440 /etc/sudoers.d/agent-sudo

    # --- A5. sshd for the IAP break-glass path ----------------------------
    # Preinstalled on debian-cloud images; make sure it's up. Tailscale SSH
    # is the primary access and doesn't use sshd — this exists only for
    # `gcloud compute ssh --tunnel-through-iap` (firewall: IAP range only),
    # which is also how ./run rekey repairs a box that never joined.
    systemctl enable --now ssh

    # --- A6. Join the tailnet  <-- THE AUTH KEY IS SPENT HERE -------------
    # The auth key is single-use (minted per build), so only spend it when this
    # node is not already a tailnet member. On a reboot the node identity lives
    # on the data disk, so re-running `tailscale up --authkey` with a consumed
    # key would fail; without the key it is a harmless no-op that just
    # reasserts --ssh.
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
      # Covers first boot AND recovery from a deleted node (netmap 404s), where
      # a fresh key re-registers this machine.
      tailscale up --ssh --hostname=${var.instance_name} --authkey='${var.tailscale_auth_key}' ||
        echo ">> tailscale up FAILED: the one-off key is likely spent, revoked or expired.
        >> Recover with:  ./run rekey     (mints a key and re-runs this script over IAP)"
    fi

    # --- A7. Browser-stack files (no packages, so effectively free) -------
    # Multiple agents drive a REAL (non-headless) Chromium on a virtual
    # display — no window manager or desktop needed. Xvfb provides DISPLAY
    # :99; Chromium renders into it like a normal desktop browser, which
    # defeats headless-mode detection. Agents attach via CDP on :9222
    # (Playwright connectOverCDP / launch). Profiles live on /mnt/data so
    # logins survive rebuilds.
    #
    # The files are written now and the PACKAGES are installed in phase B.
    # Writing them costs milliseconds, keeps phase B to "install and start",
    # and lets verify.sh assert the wrapper contents (the doubled-dollar
    # regression guards) immediately, without waiting for chromium to exist.
    # NB: do not write a literal doubled dollar anywhere in this heredoc — it
    # renders through as-is and the compute.tf precondition rejects the apply.

    # A7a. Virtual display. No TCP listener — local only. Enabled in phase B,
    # once /usr/bin/Xvfb actually exists.
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

    # A7c. NOTE: /etc/default/zramswap is deliberately NOT written here.
    # It is a dpkg CONFFILE shipped by zram-tools, and zram-tools is installed in
    # phase B. Creating it first makes dpkg detect a conflict ("File on system
    # created by you or by a script / File also in package") and prompt on stdin;
    # phase B has no stdin, so dpkg dies with "end of file on stdin at conffile
    # prompt", the whole apt run exits 100, and the browser stack never installs.
    # DEBIAN_FRONTEND=noninteractive does NOT prevent this — it governs debconf,
    # not dpkg conffile prompts. Phase B writes the file after the install and
    # also passes --force-confold as a general guard.

    # A7d. headed-chromium: a real browser on :99 with CDP + persistent profile.
    cat > /usr/local/bin/headed-chromium <<'CHROME'
#!/usr/bin/env bash
# Headed Chromium on the virtual display, for agents + scrapers.
#   DISPLAY             default :99 (the Xvfb screen)
#   BROWSER_PROFILE_DIR default /mnt/data/browser/default (survives rebuilds)
#   CDP_PORT            default 9222 (use a different port per agent/browser)
# AutomationControlled is disabled so navigator.webdriver stays false.
export DISPLAY="$${DISPLAY:-:99}"
exec chromium --no-first-run --no-default-browser-check \
  --disable-blink-features=AutomationControlled \
  --remote-debugging-port="$${CDP_PORT:-9222}" \
  --user-data-dir="$${BROWSER_PROFILE_DIR:-/mnt/data/browser/default}" \
  "$@"
CHROME
    chmod +x /usr/local/bin/headed-chromium

    # A7e. Agent-writable profile root on the data disk (/mnt/data is
    # root-owned; agents run as your user and create their own subdirs).
    mkdir -p "$DATA_MNT/browser"
    chown "$USER_NAME:$USER_NAME" "$DATA_MNT/browser"

    # --- A8. Phone notifications (Termux) ---------------------------------
    # The VM is the SSH *client* here — it dials out to Termux's own sshd on
    # the phone over the tailnet and runs `termux-notification` remotely.
    # No forwarding, no sshd changes on this box: just an outbound key-based
    # SSH connection. Keypair + known_hosts live on the persistent data disk
    # so a VM rebuild doesn't require re-adding the pubkey to the phone.
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
# Pings your phone via Termux:API over an outbound SSH connection to Termux's
# sshd (see 99-termux.conf). Extra flags (--action, --icon-path, ...) pass
# straight through to termux-notification.
# Every word is %q-escaped before ssh re-joins argv with spaces, so multi-word
# and special-character arguments arrive on the phone intact (ssh itself does
# NOT preserve your quoting).
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

    # ==================================================================
    # A9. PHASE B — hand off the slow work and get out of the way.
    # ==================================================================
    # A real systemd unit rather than a backgrounded subshell: the metadata
    # script runner waits for its children, and this script's stdout is a `tee`
    # pipe that an inherited fd would hold open. `systemctl start --no-block`
    # detaches cleanly, the output lands in the journal (and so on the serial
    # console, which is how wait-ready.sh can watch it without SSH), and being
    # an enabled oneshot it re-runs on every boot to self-heal a failed install.
    cat > /usr/local/sbin/agent-install-packages <<'PKGS'
#!/usr/bin/env bash
# Deferred package install: everything not needed to reach this box.
# Idempotent — apt is a no-op when the packages are current, so re-running this
# (on reboot, or by hand after a failure) is cheap and safe.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
# --force-confold is load-bearing, not boilerplate. DEBIAN_FRONTEND governs
# debconf, NOT dpkg's conffile prompts: if any package ships a config file that
# already exists on disk, dpkg stops and asks on stdin. There is no stdin here, so
# it fails with "end of file on stdin at conffile prompt" and takes the entire apt
# run (exit 100) and this service down with it. Keeping our version is also the
# behaviour we want for anything we deliberately pre-write.
APT="apt-get -o DPkg::Lock::Timeout=600 -o Dpkg::Options::=--force-confold"

echo "=== agent packages $(date -u) ==="
$APT update

# Wave 1: the CLI tools you want the moment you log in. Small and quick, so
# they land well before the browser stack finishes.
echo ">> wave 1: CLI tools"
$APT install -y git stow tmux vim python3-pip

# Wave 2: the heavy stuff. chromium alone pulls ~200MB of codec libraries.
echo ">> wave 2: upgrade + headed-browser stack"
$APT upgrade -y
$APT install -y build-essential xvfb chromium \
  fonts-liberation fonts-noto-core zram-tools

# zram compressed swap (~+50% effective RAM headroom for browsers). Written
# AFTER the install, for the conffile reason documented in phase A7c. apt
# auto-starts zramswap with a fallback size at install time, so a restart (not
# enable --now) is what deterministically applies our sizing.
echo ">> configuring zram swap"
printf 'ALGO=zstd\nPERCENT=50\n' > /etc/default/zramswap

# Now that the packages exist, start the units whose files phase A wrote.
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
# RemainAfterExit is what makes `systemctl is-active` a usable state machine:
#   activating -> still installing      active -> finished
#   failed     -> install failed        inactive -> never started
# verify-browser.sh reads exactly that to tell "not ready yet" (SKIP) apart
# from "broken" (FAIL).
RemainAfterExit=yes
ExecStart=/usr/local/sbin/agent-install-packages
TimeoutStartSec=3600

[Install]
WantedBy=multi-user.target
UNIT

    systemctl daemon-reload
    systemctl enable agent-packages.service
    # --no-block: do not wait. This is the whole point of the split.
    systemctl start --no-block agent-packages.service

    echo ">> phase B (packages + browser stack) is installing in the background."
    echo ">>   progress:  journalctl -u agent-packages -f"
    echo ">>   state:     systemctl is-active agent-packages"

    # --- Completion marker, delivered THREE ways on purpose ---------------
    # `echo` alone is not reliable for the FINAL line. stdout here is a process
    # substitution running tee; when this script exits, bash does not wait for
    # tee to flush its stdout buffer into the metadata runner's pipe. The line
    # always reaches /var/log/startup-agent.log (tee's file output) but can be
    # LOST from the journal and therefore the serial console.
    #
    # That is not cosmetic: wait-ready.sh polls the serial console for this
    # marker, so losing it turns a perfectly healthy 84-second boot into a
    # ten-minute timeout that looks exactly like a hung VM. Measured: the boot
    # of 11:54:12 completed fine on disk, and the console never showed it.
    #
    #   1. sentinel file — authoritative, checked over SSH once the node is up.
    #      /run is tmpfs, so it is correctly per-boot.
    #   2. logger      — writes to the journal synchronously, independent of the
    #                    tee pipe, so it reaches the serial console reliably.
    #   3. echo        — the human-readable on-disk log.
    touch /run/agent-startup-complete
    logger -t agent-startup "agent startup complete"
    echo "=== agent startup complete $(date -u) ==="
  EOT
}
