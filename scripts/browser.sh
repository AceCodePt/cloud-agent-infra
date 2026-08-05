#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

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

rsh() { ssh_vm "export PATH=/usr/local/sbin:/usr/sbin:/sbin:\$PATH; $1"; }

browser_pid() { rsh "pgrep -f '[u]ser-data-dir=$PROFILE' | head -1" 2>/dev/null | tr -d '[:space:]'; }

stop_vnc() {
  note "stopping x11vnc on the box"
  rsh "sudo -n systemctl stop x11vnc; sudo -n systemctl reset-failed x11vnc" 2>/dev/null || true
}

case "$MODE" in
stop)
  stop_vnc
  pid="$(browser_pid)"
  if [[ -n "$pid" ]]; then
    note "stopping browser (pid $pid)"
    rsh "kill $pid" || true
    sleep 3
  else
    note "no browser running on $PROFILE"
  fi
  echo "stopped."
  exit 0
  ;;

open)
  if [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
    CANDIDATES=(wlvncc gvncviewer remmina vinagre vncviewer)
  else
    CANDIDATES=(vncviewer wlvncc gvncviewer remmina vinagre)
  fi
  viewer=""
  for c in "${CANDIDATES[@]}"; do
    if command -v "$c" >/dev/null 2>&1; then
      viewer="$c"
      break
    fi
  done
  [[ -n "$viewer" ]] || die "no VNC client on this machine. Install one:
    sudo pacman -S tigervnc      # vncviewer; X11-only, needs a working XWayland
    sudo pacman -S remmina       # GTK, speaks Wayland natively
  then re-run: ./run browser $URL"
  note "using VNC client: $viewer"

  if [[ "$viewer" == vncviewer || "$viewer" == vinagre ]]; then
    [[ -n "${DISPLAY:-}" ]] || die "$viewer is an X11 client but DISPLAY is unset.
  On Wayland, install a native client:  sudo pacman -S remmina"
    if command -v xset >/dev/null 2>&1 && ! timeout 5 xset q >/dev/null 2>&1; then
      die "$viewer is an X11 client and DISPLAY=$DISPLAY cannot be opened.
  Every X11 app on this machine is broken right now, not just this one
  (check: xset q).
  Usually XWayland's socket was deleted from /tmp/.X11-unix while Xwayland
  kept running, which no amount of retrying fixes. Either:
    - log out and back in, to restart XWayland, or
    - use a Wayland-native client:  sudo pacman -S remmina"
    fi
  fi

  vm_online || die "$INSTANCE is not on the tailnet. Try: ./run up"

  [[ "$(rsh 'systemctl is-active xvfb' || true)" == active ]] ||
    die "Xvfb is not running on the box, so there is no display to export.
  Check with: ./run verify-browser"

  if ss -ltn 2>/dev/null | grep -q ":$PORT "; then
    die "local port $PORT is already in use (an older tunnel still open?).
  Re-run with a different port:  VNC_LOCAL_PORT=5901 ./run browser $URL"
  fi

  trap stop_vnc EXIT INT TERM
  note "starting x11vnc on the box (loopback only, no password -- see operating.md)"
  rsh "sudo -n systemctl start x11vnc"

  pid="$(browser_pid)"
  if [[ -n "$pid" ]]; then
    note "browser already running (pid $pid) -- reusing it"
  else
    note "launching $BROWSER_CMD on :99 at $URL"
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

  case "$viewer" in
  vncviewer) ESCAPE="press F8 for the TigerVNC menu (Exit viewer)" ;;
  *) ESCAPE="close the $viewer window" ;;
  esac

  cat <<EOF

$(printf '\033[1m')The box's screen is now in the VNC window.$(printf '\033[0m')

  The browser ($BROWSER_CMD) is the whole 1920x1080 screen. There is no window
  manager, so no title bar and nothing to alt-tab -- that is intentional.

$(printf '\033[1m')  Getting back out:$(printf '\033[0m') $ESCAPE, or use your window manager's
  close-window key. The viewer fills the screen and on a tiling WM can open on
  a different workspace than this terminal.
  Then Ctrl-C here. The browser stays up on :99; x11vnc and the tunnel are shut
  down for you. To stop the browser too: ./run browser --stop

EOF
  printf '%s\n' "  (url: $URL, profile: $PROFILE)"
  echo

  note "starting $viewer"
  rc=0
  case "$viewer" in
  vncviewer) "$viewer" -Shared "localhost:$PORT" || rc=$? ;;
  wlvncc) "$viewer" localhost "$PORT" || rc=$? ;;
  *) "$viewer" "vnc://localhost:$PORT" || rc=$? ;;
  esac
  if [[ "$rc" -ne 0 ]]; then
    warn "$viewer exited non-zero ($rc)."
    warn "If it never drew a window, this is a LOCAL display problem, not the box:"
    warn "  the browser is still running on :99 — re-attach once the viewer works."
  fi
  ;;
esac
