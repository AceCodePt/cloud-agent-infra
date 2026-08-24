#!/usr/bin/env bash
set -euo pipefail
umask 022
# umask 027 inside the process substitution: the log is created by tee, so it
# would be 644 under the script's umask; keep root-only-ish (640) instead.
exec > >(umask 027; tee /var/log/startup-agent.log) 2>&1
echo "=== agent startup $(date -u) ==="

export DEBIAN_FRONTEND=noninteractive
DNF="dnf -y"

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
# OCI block volumes attach over iSCSI; the device may take a moment to appear.
# The udev alias __DATA_DEV__ is not deterministic (this instance got
# oraclevda, others oraclevdb), so scan the /dev/oracleoci/ symlinks for a
# non-partition device and fall back to the well-known plain names too.
for cand in "$DATA_DEV" \
            "$(for s in /dev/oracleoci/oraclevd*; do [[ "$s" =~ [0-9]$ ]] || echo "$s"; done | head -1)" \
            /dev/sdb /dev/vdb; do
  [ -n "$cand" ] && [ -b "$cand" ] && DATA_DEV="$cand" && break
done
# Wait a bounded time for the data device before declaring the disk missing.
for _ in $(seq 1 30); do
  [ -b "$DATA_DEV" ] && break
  sleep 2
done
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

# Oracle Linux splits the boot LVM into a fixed root (29.5G) + oled; grow root
# into any unallocated VG space from a larger boot volume. Oracle-only (other
# providers' images grow root via cloud-init). Idempotent when nothing is free.
if [ -d /usr/libexec/oracle-cloud-agent ]; then
  ROOT_LV="$(findmnt -no SOURCE / 2>/dev/null || true)"
  case "$ROOT_LV" in
    /dev/mapper/* | /dev/*vg*)
      FREE_EXTENTS="$(vgs --noheadings -o vg_free_count 2>/dev/null | tr -d ' ')"
      if [ -n "$FREE_EXTENTS" ] && [ "$FREE_EXTENTS" -gt 0 ] 2>/dev/null; then
        if lvextend -l +100%FREE "$ROOT_LV" >/dev/null 2>&1; then
          if ! xfs_growfs / >/dev/null 2>&1; then
            resize2fs "$ROOT_LV" >/dev/null 2>&1 || true
          fi
          echo ">> grew $ROOT_LV to $(df -h / 2>/dev/null | awk 'NR==2{print $2}')"
        else
          echo "!! lvextend $ROOT_LV failed (continuing with the image's root size)"
        fi
      fi
      ;;
  esac
fi

# Tailscale SSH (the box's only inbound path) can stall — banner never answers —
# when SELinux is enforcing (https://tailscale.com/s/ssh-selinux). Drop to
# permissive now so tailscaled starts under a mode its SSH server works in.
if command -v setenforce >/dev/null 2>&1; then
  setenforce 0 >/dev/null 2>&1 || true
  if [ -f /etc/selinux/config ]; then
    sed -i 's/^SELINUX=.*/SELINUX=permissive/' /etc/selinux/config
  fi
fi

$DNF install -y curl ca-certificates sudo tar gzip
if ! command -v tailscale >/dev/null 2>&1; then
  echo ">> installing tailscale (install.sh fetched, checksum-pinned, executed)"
  # Never execute an unvetted remote script: a compromised or rewritten upstream
  # install.sh must be refused.
  TS_INSTALL_SHA256="805e85ed6f6f81a7ea2e70d52d47e7d5290863299e5c922b2787d71aa312f22e"
  TS_INSTALL="$(mktemp)"
  if curl -fsSL https://tailscale.com/install.sh -o "$TS_INSTALL"; then
    if [ "$(sha256sum "$TS_INSTALL" | awk '{print $1}')" = "$TS_INSTALL_SHA256" ]; then
      bash "$TS_INSTALL"
    else
      echo "!! tailscale install.sh checksum mismatch (got $(sha256sum "$TS_INSTALL" | awk '{print $1}'))"
      echo "!! refusing to execute; update TS_INSTALL_SHA256 if the upstream script legitimately changed"
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
    useradd -m -G wheel -s /bin/bash "$USER_NAME"
  fi
  echo "$USER_NAME ALL=(ALL:ALL) NOPASSWD: ALL" > /etc/sudoers.d/agent-sudo
  chmod 440 /etc/sudoers.d/agent-sudo
fi

# sshd hardening: this is what keeps the only "other way in" to a physical
# console. Key-only over Tailscale. Oracle Linux's sshd ships with
# PasswordAuthentication in the default config, so a drop-in that sorts early
# wins (first value seen wins).
mkdir -p /etc/ssh/sshd_config.d
rm -f /etc/ssh/sshd_config.d/99-agent-hardening.conf
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
  echo "!! sshd -t failed; NOT restarting sshd (check sshd_config.d)"
fi
if command -v firewall-cmd >/dev/null 2>&1; then
  systemctl enable --now firewalld >/dev/null 2>&1 || true
  if ! firewall-cmd --list-ports --permanent 2>/dev/null | grep -q '^41641/udp$'; then
    firewall-cmd --permanent --add-port=41641/udp >/dev/null 2>&1 || true
  fi
  firewall-cmd --reload >/dev/null 2>&1 || true
fi

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
    if ! curl -4sf --max-time 5 -o /dev/null "$PROBE_URL" 2>/dev/null; then
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

# --- Oracle Cloud Always Free idle guard ---
# Why it exists, and why it self-detects the provider instead of using a token:
# docs/decisions/infrastructure.md ("Oracle Always Free idle guard").
if [ -d /usr/libexec/oracle-cloud-agent ]; then
  cat > /usr/local/sbin/oci-idle-burn <<'BURN'
#!/usr/bin/env bash
# Oracle Always Free idle guard. Keeps the 95th-percentile CPU above Oracle's
# 20% reclaim floor. Runs at nice 19 (lowest priority), so it only fills
# otherwise-idle capacity and yields to real work.
#
# Levels:
#   full  spin one core continuously      ~50% CPU
#   low   spin 6 min / rest 54 min        ~5% CPU, p95 still ~50%
#   off   no spin; rely on real usage
# Modes:
#   auto (default)  the daemon probes REAL cpu (no burn) every 2h; if its
#                   7-day p95 >= 20% it sets off, else low
#   manual          an operator set the level; the daemon leaves it alone
#
# Run with no args (or --help) it prints usage; `--daemon` is what systemd
# runs. State lives in /mnt/data/idle-check/ (root-owned, survives rebuilds).
set -uo pipefail

STATE="/mnt/data/idle-check"
MODE_FILE="$STATE/burn.mode"
LEVEL_FILE="$STATE/burn.level"
PROBE_FILE="$STATE/burn.last_probe"
CYCLE_FILE="$STATE/burn.cycle_start"
PROBE_LOG="$STATE/probe.log"
THRESHOLD=20
PROBE_EVERY_MIN=120
PROBE_MIN=5
LOW_BURN_MIN=6
LOW_REST_MIN=54
CYCLE_MIN=$(( LOW_BURN_MIN + LOW_REST_MIN ))

usage() {
  cat <<EOF
oci-idle-burn: Oracle Always Free idle guard

  --daemon          run the guard (used by systemd; no arguments otherwise)
  off|low|full      set the level (switches to manual mode)
  auto              return to automatic level selection
  status            show mode, level, and the last idle-check verdict
EOF
}

read_val() { # read_val <file> <default>
  local f="$1" d="${2:-}"
  if [ -f "$f" ]; then cat "$f" 2>/dev/null || printf '%s\n' "$d"; else printf '%s\n' "$d"; fi
}

write_val() { # write_val <file> <value>
  mkdir -p "$STATE" 2>/dev/null || true
  printf '%s\n' "$2" > "$1" 2>/dev/null || true
}

need_root() {
  if ! [ -w "$STATE" ]; then
    echo "oci-idle-burn: $STATE is not writable by $(id -un) — use sudo" >&2
    exit 1
  fi
}

cmd="${1:-}"
case "$cmd" in
  "" | --help | -h | help)
    usage
    exit 0
    ;;
  --daemon)
    ;;
  off | low | full)
    need_root
    write_val "$MODE_FILE" manual
    write_val "$LEVEL_FILE" "$cmd"
    echo "oci-idle-burn: level=$cmd (manual). Takes effect within a minute."
    exit 0
    ;;
  auto)
    need_root
    write_val "$MODE_FILE" auto
    write_val "$PROBE_FILE" 0
    echo "oci-idle-burn: auto mode. Probes real CPU every ${PROBE_EVERY_MIN} min and picks full/low/off itself."
    exit 0
    ;;
  status)
    printf 'mode=%s level=%s last_check=%s\n' \
      "$(read_val "$MODE_FILE" auto)" \
      "$(read_val "$LEVEL_FILE" full)" \
      "$(tail -1 "$STATE/daily.log" 2>/dev/null || echo none)"
    exit 0
    ;;
  *)
    echo "oci-idle-burn: unknown command '$cmd'" >&2
    usage >&2
    exit 2
    ;;
esac

# ---- daemon ----
mkdir -p "$STATE"
[ -f "$MODE_FILE" ]  || write_val "$MODE_FILE" auto
[ -f "$LEVEL_FILE" ] || write_val "$LEVEL_FILE" full
[ -f "$PROBE_FILE" ] || write_val "$PROBE_FILE" "$(date +%s)"
[ -f "$CYCLE_FILE" ] || write_val "$CYCLE_FILE" "$(date +%s)"

spin_sec() { # spin_sec <seconds>
  timeout "$1" nice -n 19 bash -c 'while :; do :; done'
}

cpu_pct() { # cpu_pct — one 60s sample of TOTAL cpu, no burning
  local u1 n1 s1 i1 w1 ir1 si1 st1 u2 n2 s2 i2 w2 ir2 si2 st2
  local t1 t2 idle1 idle2 denom busy
  read -r _ u1 n1 s1 i1 w1 ir1 si1 st1 _ _ < <(grep '^cpu ' /proc/stat)
  sleep 60
  read -r _ u2 n2 s2 i2 w2 ir2 si2 st2 _ _ < <(grep '^cpu ' /proc/stat)
  t1=$(( u1 + n1 + s1 + i1 + w1 + ir1 + si1 + st1 ))
  t2=$(( u2 + n2 + s2 + i2 + w2 + ir2 + si2 + st2 ))
  idle1=$(( i1 + w1 )); idle2=$(( i2 + w2 ))
  denom=$(( t2 - t1 )); busy=$(( (t2 - t1) - (idle2 - idle1) ))
  if [ "$denom" -gt 0 ]; then echo $(( busy * 100 / denom )); else echo 0; fi
}

probe_and_decide() {
  # The daemon is the only burner, so "pause the burn" is just: don't spin.
  # Sample REAL cpu once a minute for PROBE_MIN minutes, then set the level:
  # off if real usage p95 >= threshold, else low. (Never full — if real usage
  # is low, the box needs SOME burn, and low clears the floor with margin.)
  local i pct readout p95 level
  for i in $(seq 1 "$PROBE_MIN"); do
    pct="$(cpu_pct)"
    printf '%s %s\n' "$(date +%s)" "$pct" >> "$PROBE_LOG" || true
  done
  readout="$(python3 - "$PROBE_LOG" "$(( $(date +%s) - 8 * 86400 ))" "$THRESHOLD" <<'PY'
import sys
log, cutoff, thr = sys.argv[1], int(sys.argv[2]), float(sys.argv[3])
vals = []
for line in open(log):
    parts = line.split()
    if len(parts) != 2:
        continue
    try:
        ts, v = float(parts[0]), float(parts[1])
    except ValueError:
        continue
    if ts >= cutoff:
        vals.append(v)
if not vals:
    print("0.0 low")
    sys.exit(0)
vals.sort()
p95 = vals[int(0.95 * (len(vals) - 1))]
print("%.1f %s" % (p95, "off" if p95 >= thr else "low"))
PY
)"
  p95="${readout%% *}"
  level="${readout##* }"
  write_val "$LEVEL_FILE" "$level"
  logger -t oci-idle-burn "auto probe: real-usage p95=$p95 threshold=$THRESHOLD -> level=$level"
  write_val "$PROBE_FILE" "$(date +%s)"
}

while true; do
  mode="$(read_val "$MODE_FILE" auto)"
  level="$(read_val "$LEVEL_FILE" full)"
  now=$(date +%s)

  if [ "$mode" = auto ]; then
    lp="$(read_val "$PROBE_FILE" 0)"
    if [ $(( now - lp )) -ge $(( PROBE_EVERY_MIN * 60 )) ]; then
      probe_and_decide
      level="$(read_val "$LEVEL_FILE" low)"
      now=$(date +%s)
    fi
  fi

  case "$level" in
    full) spin_sec 60 ;;
    low)
      cs="$(read_val "$CYCLE_FILE" "$now")"
      elapsed=$(( now - cs ))
      if [ "$elapsed" -ge "$CYCLE_MIN" ]; then
        write_val "$CYCLE_FILE" "$now"
        elapsed=0
      fi
      if [ "$elapsed" -lt "$LOW_BURN_MIN" ]; then
        spin_sec 60
      else
        sleep 60
      fi
      ;;
    *) sleep 60 ;;
  esac
done
BURN
  chmod 755 /usr/local/sbin/oci-idle-burn

  cat > /etc/systemd/system/oci-idle-burn.service <<'UNIT'
[Unit]
Description=Oracle Always Free idle guard: keep p95 CPU above 20%%
After=multi-user.target

[Service]
ExecStart=/usr/local/sbin/oci-idle-burn --daemon
Nice=19
CPUWeight=1
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable oci-idle-burn.service
  systemctl start oci-idle-burn.service

  # Daily self-verification: a dead burn unit would silently fall back under
  # the reclaim line, so sample once a minute and recompute the 7-day p95 daily.
  cat > /usr/local/sbin/oci-cpu-sampler <<'SAMPLER'
#!/usr/bin/env bash
set -uo pipefail
LOG="/mnt/data/idle-check/cpu.log"
# oci-cpu-sampler is a daemon, not a query command. The read-only status check
# lives in oci-idle-check; point anyone who tries flags here at the right tool.
if [ $# -gt 0 ]; then
  echo "oci-cpu-sampler: this is a background daemon and takes no arguments." >&2
  echo "oci-cpu-sampler: to check the idle status read-only, run:  sudo /usr/local/sbin/oci-idle-check --check-only" >&2
  exit 2
fi
[ -d /mnt/data ] || exit 1                 # history lives on the data volume
mkdir -p /mnt/data/idle-check
# Fail fast when run by hand as a non-root user: the log is root-owned (the
# systemd service runs as root), so a hand-run would silently loop on
# "Permission denied" every minute. Only the service is meant to write it.
if ! [ -w "$LOG" ] && ! [ -w "$(dirname "$LOG")" ]; then
  echo "oci-cpu-sampler: $LOG is not writable by $(id -un)" >&2
  echo "oci-cpu-sampler: run via systemd (sudo systemctl restart oci-cpu-sampler)" >&2
  exit 1
fi
while true; do
  read -r _ u1 n1 s1 i1 w1 ir1 si1 st1 _ _ < <(grep '^cpu ' /proc/stat)
  sleep 60
  read -r _ u2 n2 s2 i2 w2 ir2 si2 st2 _ _ < <(grep '^cpu ' /proc/stat)
  t1=$(( u1 + n1 + s1 + i1 + w1 + ir1 + si1 + st1 ))
  t2=$(( u2 + n2 + s2 + i2 + w2 + ir2 + si2 + st2 ))
  idle1=$(( i1 + w1 )); idle2=$(( i2 + w2 ))
  denom=$(( t2 - t1 )); busy=$(( (t2 - t1) - (idle2 - idle1) ))
  pct=0
  [ "$denom" -gt 0 ] && pct=$(( busy * 100 / denom ))
  printf '%s %s\n' "$(date +%s)" "$pct" >> "$LOG" || true
  lines=$(wc -l < "$LOG" 2>/dev/null || echo 0)
  if [ "$lines" -gt 20000 ]; then
    tail -n 20000 "$LOG" > "$LOG".tmp 2>/dev/null && mv "$LOG".tmp "$LOG"
  fi
done
SAMPLER
  chmod 755 /usr/local/sbin/oci-cpu-sampler

  cat > /usr/local/sbin/oci-idle-check <<'CHECK'
#!/usr/bin/env bash
set -uo pipefail
LOG="/mnt/data/idle-check/cpu.log"
OUT="/mnt/data/idle-check/daily.log"
THRESHOLD=20
WINDOW_DAYS=7
MIN_SAMPLES=1000          # one per minute: ~16.7h of history before a verdict
CHECK_ONLY=0
[ "${1:-}" = "--check-only" ] && CHECK_ONLY=1
mkdir -p /mnt/data/idle-check
now=$(date +%s)
cutoff=$(( now - WINDOW_DAYS * 86400 ))
# The timer (Persistent=true) can fire before the sampler's first sample lands;
# a missing or tiny log is NO_DATA, not a verdict.
[ -s "$LOG" ] || { echo "NO_DATA 0"; exit 0; }
read -r verdict p95 <<< "$(python3 - "$LOG" "$cutoff" "$THRESHOLD" "$MIN_SAMPLES" <<'PY'
import sys
log, cutoff, thr, min_samples = sys.argv[1], int(sys.argv[2]), float(sys.argv[3]), int(sys.argv[4])
vals = []
for line in open(log):
    parts = line.split()
    if len(parts) != 2:
        continue
    try:
        ts, v = float(parts[0]), float(parts[1])
    except ValueError:
        continue
    if ts >= cutoff:
        vals.append(v)
if len(vals) < min_samples:
    print("NO_DATA 0")
    sys.exit(0)
vals.sort()
p95 = vals[int(0.95 * (len(vals) - 1))]
print("SAFE" if p95 >= thr else "AT_RISK", p95)
PY
)"
guard="$(systemctl is-active oci-idle-burn 2>/dev/null || echo unknown)"
if [ "$CHECK_ONLY" -ne 1 ]; then
  # Only the daily timer (root) writes OUT; a hand-run as a non-root user
  # would fail on the root-owned log, so fail fast instead of appending a
  # blank line.
  if ! [ -w "$OUT" ] && ! [ -w "$(dirname "$OUT")" ]; then
    echo "oci-idle-check: $OUT is not writable by $(id -un)" >&2
    echo "oci-idle-check: run via systemd (sudo systemctl start oci-idle-check)" >&2
    exit 1
  fi
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $verdict p95=$p95 guard=$guard" >> "$OUT"
  logger -t oci-idle-check "verdict=$verdict p95=$p95 (floor $THRESHOLD% over $WINDOW_DAYS days) guard=$guard"
fi
echo "$verdict $p95"
case "$verdict" in
  NO_DATA) exit 0 ;;
  SAFE) exit 0 ;;
  *) exit 1 ;;
esac
CHECK
  chmod 755 /usr/local/sbin/oci-idle-check

  cat > /etc/systemd/system/oci-cpu-sampler.service <<'UNIT'
[Unit]
Description=cloud-agent CPU sampler: 1-minute samples for the Oracle idle check
After=multi-user.target

[Service]
ExecStart=/usr/local/sbin/oci-cpu-sampler
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable oci-cpu-sampler.service
  systemctl start oci-cpu-sampler.service

  cat > /etc/systemd/system/oci-idle-check.service <<'UNIT'
[Unit]
Description=Oracle idle check: 7-day p95 CPU against the 20% reclaim floor

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/oci-idle-check
UNIT

  cat > /etc/systemd/system/oci-idle-check.timer <<'UNIT'
[Unit]
Description=daily Oracle idle 20% verification

[Timer]
OnCalendar=daily
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
UNIT
  systemctl daemon-reload
  systemctl enable oci-idle-check.timer
  systemctl start oci-idle-check.timer
fi

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

# Chromium comes from Flathub as a Flatpak: it is STANDARD Chromium (built from
# the official source tarball, no Playwright/automation patches), available for
# aarch64, and --socket=x11 lets it reach Xvfb. Flatpak is the same binary as
# any distro's chromium — the sandbox is packaging, not a fork.
cat > /usr/local/bin/headed-chromium <<'CHROME'
#!/usr/bin/env bash
export DISPLAY="${DISPLAY:-:99}"
exec flatpak run org.chromium.Chromium --no-sandbox --no-first-run \
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

cat > /usr/local/sbin/agent-install-packages <<'PKGS'
#!/usr/bin/env bash
set -euo pipefail
DNF="dnf -y"

echo "=== agent packages $(date -u) ==="

echo ">> enabling EPEL (extra packages for enterprise linux, needed for fzf/direnv/gh/x11vnc/neovim)"
$DNF install -y epel-release
# The EPEL repo is enabled=0 in the images we boot: on Oracle Linux the
# package installs but the repo stays disabled, on Rocky the enable line
# targets `epel` directly — so the EPEL-only packages (stow/gh/fzf) would be
# invisible and wave 1 fails with "No match for argument". Enable it before
# the makecache, accepting either repo id.
dnf config-manager --set-enabled epel 2>/dev/null ||
  dnf config-manager --set-enabled ol9_developer_EPEL 2>/dev/null || true
# Oracle-only mirror/repo cleanup: on Oracle Linux the OCI regional yum mirror
# (yum.<region>.<domain>) is flaky on the free tier — repomd.xml and package
# downloads time out. Point every Oracle repo at the public mirror instead,
# and drop the OCI-only / ksplice repos we don't need. On Rocky these are
# harmless no-ops (no such repo exists).
sed -i 's|yum\$ociregion\.\$ocidomain|yum.oracle.com|g' /etc/yum.repos.d/*.repo 2>/dev/null || true
dnf config-manager --set-disabled ol9_oci_included 2>/dev/null || true
dnf config-manager --set-disabled ol9_ksplice 2>/dev/null || true
$DNF makecache || echo "!! makecache failed (continuing; dnf will retry per-install)"

echo ">> wave 1: CLI tools"
$DNF install -y git stow tmux python3-pip zsh gh fzf fd-find ripgrep gpg unzip
$DNF group install -y "Development Tools"

echo ">> lazygit: not packaged for EL9, install from the atim/lazygit copr"
$DNF install -y dnf-plugins-core
$DNF copr enable atim/lazygit -y
$DNF install -y lazygit

echo ">> direnv: not packaged for EL9, install the static binary from GitHub"
if ! command -v direnv >/dev/null 2>&1; then
  DIRENV_VERSION="v2.37.1"
  case "$(uname -m)" in
    aarch64) DIRENV_ARCH="arm64" ;;
    x86_64)  DIRENV_ARCH="amd64" ;;
    *)       DIRENV_ARCH="amd64" ;;
  esac
  if curl -fsSL "https://github.com/direnv/direnv/releases/download/${DIRENV_VERSION}/direnv.linux-${DIRENV_ARCH}" \
      -o /usr/local/bin/direnv; then
    chmod 755 /usr/local/bin/direnv
  else
    echo "!! could not download direnv from GitHub releases"
  fi
fi

echo ">> tmux: EL9 ships 3.2a (too old for the dotfiles config); build latest release from GitHub"
$DNF install -y gcc make pkg-config libevent-devel ncurses-devel
TMUX_VERSION="$(curl -fsSL https://api.github.com/repos/tmux/tmux/releases/latest 2>/dev/null |
  sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)"
TMUX_VERSION="${TMUX_VERSION#v}"
if [ -z "$TMUX_VERSION" ] || [ "$(tmux -V 2>/dev/null | cut -d' ' -f2)" = "$TMUX_VERSION" ]; then
  echo ">> tmux ${TMUX_VERSION:-current} already installed or latest unknown; skipping build"
else
  TMUX_TARBALL="$(mktemp)"
  if curl -fsSL "https://github.com/tmux/tmux/releases/download/v${TMUX_VERSION}/tmux-${TMUX_VERSION}.tar.gz" \
      -o "$TMUX_TARBALL"; then
    rm -rf "/tmp/tmux-${TMUX_VERSION}"
    tar -xzf "$TMUX_TARBALL" -C /tmp
    if (cd "/tmp/tmux-${TMUX_VERSION}" && ./configure --prefix=/usr/local >/dev/null 2>&1 && \
        make -j"$(nproc)" >/dev/null 2>&1 && make install >/dev/null 2>&1); then
      hash -r
      echo ">> tmux $(tmux -V 2>/dev/null) built and installed"
    else
      echo "!! tmux build failed; keeping the distro package"
    fi
    rm -rf "/tmp/tmux-${TMUX_VERSION}"
  else
    echo "!! could not download tmux ${TMUX_VERSION} from GitHub releases"
  fi
  rm -f "$TMUX_TARBALL"
fi

echo ">> neovim: latest stable from GitHub releases (arm64 build)"
ARCH="$(uname -m)"
case "$ARCH" in
  aarch64) NVIM_ARCH="arm64" ;;
  x86_64)  NVIM_ARCH="x86_64" ;;
  *)       NVIM_ARCH="arm64" ;;
esac
NVIM_DIR="/opt/nvim-linux-${NVIM_ARCH}"
if ! [ -x "$NVIM_DIR/bin/nvim" ]; then
  NVIM_TARBALL="$(mktemp)"
  if curl -fsSL "https://github.com/neovim/neovim/releases/download/stable/nvim-linux-${NVIM_ARCH}.tar.gz" \
      -o "$NVIM_TARBALL"; then
    rm -rf "$NVIM_DIR"
    mkdir -p /opt
    tar -xzf "$NVIM_TARBALL" -C /opt
  else
    echo "!! could not download neovim from GitHub releases"
  fi
  rm -f "$NVIM_TARBALL"
fi
if [ -x "$NVIM_DIR/bin/nvim" ]; then
  ln -sf "$NVIM_DIR/bin/nvim" /usr/local/bin/nvim
else
  echo "!! nvim binary missing; falling back to the EPEL package"
  $DNF install -y neovim || true
fi

# The account phase A created. Pinned by name (not a uid heuristic) so a
# cloud-init default user on a non-GCP image cannot hijack the usermod.
# usermod -s writes /etc/passwd directly; chsh goes through PAM, which rejects
# the change because the root account is password-locked ("Authentication token
# is no longer valid") — so never use chsh here.
AGENT_USER="__USER__"
# Rendered with the raw config value, so a malformed account name must not reach
# usermod/sudo -u.
if [ -z "$AGENT_USER" ] || [ "$AGENT_USER" != "${AGENT_USER#-}" ] || \
   [ -n "${AGENT_USER//[A-Za-z0-9._-]/}" ]; then
  echo "!! invalid AGENT_USER '$AGENT_USER' (want ^[A-Za-z0-9._-]+$); skipping per-user setup"
  AGENT_USER=""
fi
if [ -n "$AGENT_USER" ] && command -v zsh >/dev/null 2>&1; then
  usermod -s /usr/bin/zsh "$AGENT_USER"
  echo ">> default shell for $AGENT_USER -> zsh"
fi

echo ">> mise (version manager, from GitHub releases; pinned version)"
MISE_VERSION="v2026.8.2"
if ! command -v mise >/dev/null 2>&1; then
  MISE_TARBALL="$(mktemp)"
  if curl -fsSL "https://github.com/jdx/mise/releases/download/${MISE_VERSION}/mise-${MISE_VERSION}-linux-${NVIM_ARCH}.tar.gz" \
      -o "$MISE_TARBALL"; then
    # The tarball carries a top-level `mise/` dir, so extract to /opt (like
    # neovim) or /opt/mise/bin/mise never exists and the symlink dangles.
    tar -xzf "$MISE_TARBALL" -C /opt
    ln -sf /opt/mise/bin/mise /usr/local/bin/mise
  else
    echo "!! could not download mise from GitHub releases"
  fi
  rm -f "$MISE_TARBALL"
fi
if [ -n "$AGENT_USER" ] && command -v mise >/dev/null 2>&1; then
  echo ">> go@latest for $AGENT_USER via mise"
  sudo -u "$AGENT_USER" env HOME="/home/$AGENT_USER" PATH="/usr/local/bin:$PATH" mise use -g go@latest
  echo ">> rust@latest for $AGENT_USER via mise"
  sudo -u "$AGENT_USER" env HOME="/home/$AGENT_USER" PATH="/usr/local/bin:$PATH" mise use -g rust@latest
  echo ">> tree-sitter-cli for nvim-treesitter parser compilation"
  sudo -u "$AGENT_USER" env HOME="/home/$AGENT_USER" \
    PATH="/home/$AGENT_USER/.local/share/mise/shims:/home/$AGENT_USER/.cargo/bin:/usr/local/bin:$PATH" \
    cargo install tree-sitter-cli 2>&1 || echo "!! tree-sitter-cli install failed (non-fatal)"
  echo ">> node@latest for $AGENT_USER via mise"
  sudo -u "$AGENT_USER" env HOME="/home/$AGENT_USER" PATH="/usr/local/bin:$PATH" mise use -g node@latest
fi

echo ">> wave 2: upgrade + headed-browser stack"
# --allowerasing: OCI's tuned-profiles-oci pins an older tuned; upgrading hits a
# version conflict that is safe to resolve (it only replaces the conflicting
# tuned packages).
dnf -y --allowerasing upgrade
$DNF install -y flatpak xorg-x11-server-Xvfb xauth \
  liberation-fonts google-noto-sans-fonts \
  x11vnc mesa-libGL
$DNF install -y neovim 2>/dev/null || true

echo ">> flatpak: add Flathub and install standard Chromium (aarch64)"
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
flatpak install -y flathub org.chromium.Chromium
# The Flatpak sandbox needs to read/write the data volume for browser profiles.
flatpak override --user --filesystem=/mnt/data org.chromium.Chromium

echo ">> zram: compressed swap via systemd zram-generator"
# Package name is `zram-generator` on EL9 (Fedora's `systemd-zram-generator`
# does not exist here).
$DNF install -y zram-generator
cat > /etc/systemd/zram-generator.conf <<'ZRAM'
[zram0]
zram-size = min(ram / 2, 4096)
compression-algorithm = zstd
ZRAM
systemctl daemon-reload
systemctl enable systemd-zram-setup@zram0.service 2>/dev/null || true
systemctl start systemd-zram-setup@zram0.service 2>/dev/null || true

echo ">> dnf-automatic: auto-install security/updates, never reboot"
$DNF install -y dnf-automatic
cat > /etc/dnf/automatic.conf <<'AUTO'
[commands]
upgrade_type = security
download_updates = yes
apply_updates = yes
random_sleep = 360
[emitters]
emit_via = stdio
AUTO
systemctl enable dnf-automatic-install.timer
systemctl start dnf-automatic-install.timer

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
