#!/usr/bin/env bash
#
# login-social.sh — log a real social account into the browser ON THE BOX, by hand.
#
# This is the one step that cannot be automated, and should not be: it involves a
# password, probably an emailed code, and possibly a device confirmation. So it is
# done exactly once, interactively, and then the profile on the data disk keeps
# the session alive for weeks.
#
# WHY THE LOGIN HAPPENS ON THE BOX, and not on your laptop:
#
#   The tempting shortcut is to log in locally and copy the li_at cookie over.
#   Don't. That creates the session from your home address and then uses it from
#   a datacenter in me-west1 — a mismatch that is one of the few IP-related
#   signals with real reports behind it. Logging in through this script means the
#   session is created and used from the same egress, which is what a normal
#   user's session looks like. The cookie also lasts weeks when it comes from a
#   persistent profile like this one, versus about an hour when lifted out of a
#   fresh or incognito context.
#
# HOW IT WORKS
#
#   The browser runs on the box's Xvfb display :99 (1920x1080x24 — a real headed
#   Chromium, measured indistinguishable from a desktop one). x11vnc exports that
#   display, bound to 127.0.0.1 so it adds no listening surface anywhere. An SSH
#   tunnel forwards it to your workstation, and a local VNC client draws it.
#
#     your VNC client -> localhost:5900 -> ssh tunnel -> box 127.0.0.1:5900
#                     -> x11vnc -> Xvfb :99 -> social-chromium
#
#   Nothing here touches CDP. social-chromium has no --remote-debugging-port at
#   all, which is the entire reason this indirect route exists.
#
# ON EXIT it always stops x11vnc and closes the tunnel. The BROWSER IS LEFT
# RUNNING on purpose, so the session it just established stays warm; stop it with
#   ./run login --stop
#
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PORT="${VNC_LOCAL_PORT:-5900}"
URL="${SOCIAL_URL:-https://www.linkedin.com/login}"
PROFILE="/mnt/data/browser/social"

# Remote helper. PATH is fixed up because ss/systemctl live in /usr/sbin, which is
# NOT on the PATH of a non-interactive ssh command — the same trap that once made
# this repo conclude the box had no swap.
rsh() { ssh_vm "export PATH=/usr/local/sbin:/usr/sbin:/sbin:\$PATH; $1"; }

# The [u] is not a typo. `pgrep -f` matches every process's full command line,
# and the shell that ssh spawns to run this very command HAS the pattern in its
# own command line — so a plain pattern reports the browser as running when it is
# not. Bracketing the first character means the regex no longer matches the
# literal text carrying it. pgrep only excludes itself, never its parent.
browser_pid() { rsh "pgrep -f '[u]ser-data-dir=$PROFILE' | head -1" 2>/dev/null | tr -d '[:space:]'; }

stop_all() {
  note "stopping x11vnc on the box"
  # reset-failed as well: x11vnc traps SIGTERM and exits 2, so an ordinary stop
  # is recorded as a failure. The unit now declares SuccessExitStatus=2, but a
  # box provisioned before that change still has the old unit, and leaving a
  # bogus entry in `systemctl --failed` is how real failures get ignored.
  rsh "sudo -n systemctl stop x11vnc; sudo -n systemctl reset-failed x11vnc" 2>/dev/null || true
}

# --- ./run login --stop : shut the browser down too -----------------------
if [[ "${1:-}" == "--stop" ]]; then
  load_config
  stop_all
  local_pid="$(browser_pid)"
  if [[ -n "$local_pid" ]]; then
    note "stopping social-chromium (pid $local_pid)"
    # SIGTERM, never -9: Chromium must flush Cookies/Local State to disk, and
    # killing it hard is a good way to lose the session you just created.
    rsh "kill $local_pid" || true
    sleep 3
  fi
  echo "stopped."
  exit 0
fi

load_config

# --- Preflight ------------------------------------------------------------
# Each check exists because its absence produces a confusing failure later: a
# black VNC window, a refused tunnel, or a client that is simply not installed.

viewer=""
for c in vncviewer wlvncc gvncviewer remmina vinagre; do
  if command -v "$c" >/dev/null 2>&1; then viewer="$c"; break; fi
done
if [[ -z "$viewer" ]]; then
  die "no VNC client on this machine. Install one:
    sudo pacman -S tigervnc      # provides vncviewer; runs fine under XWayland
  then re-run: ./run login"
fi

vm_online || die "$INSTANCE is not on the tailnet. Try: ./run up"

[[ "$(rsh 'systemctl is-active xvfb' || true)" == active ]] ||
  die "Xvfb is not running on the box, so there is no display to export.
  Check with: ./run verify-browser"

if ss -ltn 2>/dev/null | grep -q ":$PORT "; then
  die "local port $PORT is already in use (an older tunnel still open?).
  Re-run with a different port:  VNC_LOCAL_PORT=5901 ./run login"
fi

# --- Bring up the remote side --------------------------------------------
trap stop_all EXIT INT TERM

note "starting x11vnc on the box (loopback only, no password — see comments)"
rsh "sudo -n systemctl start x11vnc"

pid="$(browser_pid)"
if [[ -n "$pid" ]]; then
  note "social-chromium already running (pid $pid) — reusing it"
else
  note "launching social-chromium on :99 at $URL"
  # setsid + nohup + closed stdin: without all three the browser is a child of
  # this ssh session and dies with it, taking the half-finished login with it.
  rsh "setsid nohup social-chromium '$URL' >/tmp/social-chromium.log 2>&1 </dev/null & disown" || true
  sleep 4
  [[ -n "$(browser_pid)" ]] || die "social-chromium did not start. Look at:
  ./run ssh cat /tmp/social-chromium.log"
fi

# --- Tunnel + viewer ------------------------------------------------------
note "opening ssh tunnel localhost:$PORT -> $INSTANCE:5900"
ssh -o StrictHostKeyChecking=accept-new -o ExitOnForwardFailure=yes \
  -N -L "$PORT:127.0.0.1:5900" "$SSH_USER@$INSTANCE" &
tunnel=$!
# shellcheck disable=SC2317
trap 'kill '"$tunnel"' 2>/dev/null || true; stop_all' EXIT INT TERM

for _ in $(seq 1 20); do
  ss -ltn 2>/dev/null | grep -q ":$PORT " && break
  kill -0 "$tunnel" 2>/dev/null || die "ssh tunnel died. If Tailscale is asking to
  re-authenticate, run './run ssh true' once interactively and follow the URL."
  sleep 1
done

cat <<EOF

$(printf '\033[1m')Log in now, in the VNC window.$(printf '\033[0m')

  1. Type your email + password. Expect an emailed 6-digit code — have that
     inbox open. Tick "remember this device" if offered.
  2. Land on the real feed, then stop. Don't browse, don't scroll far.
  3. Close this script with Ctrl-C when you're done. The browser stays up;
     x11vnc and the tunnel are shut down for you.

  Keyboard note: it is a bare X display with no window manager, so there is no
  title bar and nothing to alt-tab. The browser is the whole screen. That is
  intentional (a WM buys nothing detectable).

EOF

note "starting $viewer"
case "$viewer" in
vncviewer) "$viewer" -Shared "localhost:$PORT" || true ;;
wlvncc) "$viewer" localhost "$PORT" || true ;;
*) "$viewer" "vnc://localhost:$PORT" || true ;;
esac

# --- Confirm the session actually persisted -------------------------------
# The point of the whole exercise is a cookie on disk, so check for one rather
# than assuming success. li_at is the session cookie; it lives in the profile's
# Cookies SQLite database, encrypted, so we only look for its presence.
echo
if rsh "test -f '$PROFILE/Default/Cookies' && strings '$PROFILE/Default/Cookies' 2>/dev/null | grep -q li_at"; then
  printf '\033[1;32mli_at cookie is present in %s\033[0m\n' "$PROFILE/Default/Cookies"
  echo "Next: pause and unpause the VM, then re-run './run login' and confirm you"
  echo "are still logged in. If the session survives that, it will survive anything."
else
  printf '\033[1;33mNo li_at cookie found yet.\033[0m\n'
  echo "If you did not finish the login, just run ./run login again."
  echo "Chromium writes cookies lazily — if you are sure you logged in, run"
  echo "'./run login --stop' (a clean SIGTERM flushes them) and check again."
fi
