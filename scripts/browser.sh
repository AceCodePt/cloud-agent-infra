#!/usr/bin/env bash
#
# browser.sh — reach the box's virtual display and drive a browser in it, BY
# HAND, over VNC through an SSH tunnel.
#
#   ./run browser [url]      open the shared browser on the box, tunnel VNC
#                            into it, and hand you a window on the :99 screen
#   ./run browser --stop     stop the browser (SIGTERM) and x11vnc
#
# This is the box's shared browser: `headed-chromium` on the virtual display,
# one persistent profile. The browser is infra; WHAT runs in it (a login, an
# app under test, an agent's UI) is up to whoever called this.
#
# Why over VNC on the box, not locally: the box's browser is the one with the
# profile, the egress, and the display — copying a session out of it is exactly
# the mistake this command exists to avoid.
#
# CHAIN (no window manager; the browser IS the whole 1920x1080 screen):
#
#   VNC client -> localhost:5900 -> ssh tunnel -> box 127.0.0.1:5900
#             -> x11vnc -> Xvfb :99 (1920x1080x24) -> headed-chromium
#
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Arguments.
MODE=open
URL="about:blank"
for a in "$@"; do
  case "$a" in
  --stop) MODE=stop ;;
  -*) die "unknown flag: $a" ;;
  *) URL="$a" ;;
  esac
done

BROWSER_CMD="${BROWSER_CMD:-headed-chromium}"
PROFILE="${BROWSER_PROFILE_DIR:-/mnt/data/browser/default}"
PORT="${VNC_LOCAL_PORT:-5900}"

load_config

# Remote helper. The PATH fix-up: ss/systemctl live in /usr/sbin, which is NOT
# on the PATH of a non-interactive ssh command — the same trap that once made
# this repo conclude the box had no swap.
rsh() { ssh_vm "export PATH=/usr/local/sbin:/usr/sbin:/sbin:\$PATH; $1"; }

# The [u] is not a typo: `pgrep -f` matches every process's full command line,
# including the shell ssh spawned to run THIS command — a plain pattern would
# report the browser running when it isn't. (Measured: 2 false positives.)
browser_pid() { rsh "pgrep -f '[u]ser-data-dir=$PROFILE' | head -1" 2>/dev/null | tr -d '[:space:]'; }

stop_vnc() {
  note "stopping x11vnc on the box"
  # reset-failed too: x11vnc traps SIGTERM and exits 2, so an ordinary stop is
  # recorded as a failure and the unit stays failed forever (SuccessExitStatus=2
  # fixes new boxes; a bogus --failed entry is how real failures get ignored).
  rsh "sudo -n systemctl stop x11vnc; sudo -n systemctl reset-failed x11vnc" 2>/dev/null || true
}

case "$MODE" in
# stop
stop)
  stop_vnc
  pid="$(browser_pid)"
  if [[ -n "$pid" ]]; then
    note "stopping browser (pid $pid)"
    # SIGTERM, never -9: Chromium must flush Cookies and Local State to disk.
    rsh "kill $pid" || true
    sleep 3
  else
    note "no browser running on $PROFILE"
  fi
  echo "stopped."
  exit 0
  ;;

# open
open)
  viewer=""
  for c in vncviewer wlvncc gvncviewer remmina vinagre; do
    if command -v "$c" >/dev/null 2>&1; then
      viewer="$c"
      break
    fi
  done
  [[ -n "$viewer" ]] && note "using VNC client: $viewer" || die "no VNC client on this machine. Install one:
    sudo pacman -S tigervnc      # provides vncviewer; runs fine under XWayland
  then re-run: ./run browser $URL"

  vm_online || die "$INSTANCE is not on the tailnet. Try: ./run up"

  [[ "$(rsh 'systemctl is-active xvfb' || true)" == active ]] ||
    die "Xvfb is not running on the box, so there is no display to export.
  Check with: ./run verify-browser"

  if ss -ltn 2>/dev/null | grep -q ":$PORT "; then
    die "local port $PORT is already in use (an older tunnel still open?).
  Re-run with a different port:  VNC_LOCAL_PORT=5901 ./run browser $URL"
  fi

  trap stop_vnc EXIT INT TERM
  note "starting x11vnc on the box (loopback only, no password -- see comments)"
  rsh "sudo -n systemctl start x11vnc"

  pid="$(browser_pid)"
  if [[ -n "$pid" ]]; then
    note "browser already running (pid $pid) -- reusing it"
  else
    note "launching $BROWSER_CMD on :99 at $URL"
    # setsid + nohup + closed stdin: without all three the browser is a child of
    # this ssh session and dies with it. BROWSER_WINDOW_SIZE (optional) sizes
    # the browser to the user's own screen.
    WINSIZE="${BROWSER_WINDOW_SIZE:-}"
    rsh "BROWSER_PROFILE_DIR='$PROFILE' ${WINSIZE:+BROWSER_WINDOW_SIZE='$WINSIZE' }setsid nohup $BROWSER_CMD '$URL' \
      >/tmp/browser-$BROWSER_CMD.log 2>&1 </dev/null & disown" || true
    sleep 4
    [[ -n "$(browser_pid)" ]] || die "$BROWSER_CMD did not start. Look at:
  ./run ssh cat /tmp/browser-$BROWSER_CMD.log"
  fi

  note "opening ssh tunnel localhost:$PORT -> $INSTANCE:5900"
  ssh -o StrictHostKeyChecking=accept-new -o ExitOnForwardFailure=yes \
    -N -L "$PORT:127.0.0.1:5900" "$SSH_USER@$INSTANCE" &
  tunnel=$!
  # shellcheck disable=SC2317
  trap 'kill '"$tunnel"' 2>/dev/null || true; stop_vnc' EXIT INT TERM

  for _ in $(seq 1 20); do
    ss -ltn 2>/dev/null | grep -q ":$PORT " && break
    kill -0 "$tunnel" 2>/dev/null || die "ssh tunnel died. If Tailscale is asking to
  re-authenticate, run './run ssh true' once interactively and follow the URL."
    sleep 1
  done

  cat <<EOF

$(printf '\033[1m')The box's screen is now in the VNC window.$(printf '\033[0m')

  The browser ($BROWSER_CMD) is the whole 1920x1080 screen. There is no window
  manager, so no title bar and nothing to alt-tab -- that is intentional.

  Ctrl-C here when done. The browser stays up; x11vnc and the tunnel are shut
  down for you.

EOF
  printf '%s\n' "  (url: $URL, profile: $PROFILE)"
  echo

  note "starting $viewer"
  case "$viewer" in
  vncviewer) "$viewer" -Shared "localhost:$PORT" || true ;;
  wlvncc) "$viewer" localhost "$PORT" || true ;;
  *) "$viewer" "vnc://localhost:$PORT" || true ;;
  esac
  ;;
esac
