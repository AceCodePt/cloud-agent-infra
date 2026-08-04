#!/usr/bin/env bash
#
# login-social.sh — log a social account into the browser ON THE BOX, by hand,
# and prove afterwards that the session is real.
#
#   ./run login [platform]            log in interactively over VNC
#   ./run login [platform] --verify   is it logged in? (cookie evidence, no traffic)
#   ./run login [platform] --verify --deep
#                                     ...and prove the session is live with ONE
#                                     authenticated request
#   ./run login [platform] --stop     close the browser (SIGTERM, flushes cookies)
#
# platform defaults to linkedin, the only one wired up. Adding another means
# adding a row to the table below plus one to PLATFORMS in social-session.py --
# no new code. Deliberately not doing that yet: Meta enforcement cascades across
# an Accounts Center, so LinkedIn should run cleanly for weeks before an account
# there is exposed to the same setup.
#
# WHY THE LOGIN HAPPENS ON THE BOX, and not by copying a cookie from the laptop:
#
#   Copying a cookie creates the session from a home address and then uses it
#   from me-west1 -- one of the few IP-related signals with real reports behind
#   it. Logging in here means session creation and use share an egress, which is
#   what a normal session looks like. A cookie from a persistent profile also
#   lasts weeks-to-a-year (measured: li_at issued with a 364-day expiry) against
#   roughly an hour for one lifted from a fresh or incognito context.
#
# HOW IT WORKS
#
#   your VNC client -> localhost:5900 -> ssh tunnel -> box 127.0.0.1:5900
#                   -> x11vnc -> Xvfb :99 (1920x1080x24) -> social-chromium
#
#   No CDP anywhere in that chain. social-chromium has no --remote-debugging-port
#   at all, which is the entire reason for the indirection: calling Runtime.enable
#   is the clearest automation marker there is.
#
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Platform table -------------------------------------------------------
# One row per platform: where to start the login, and which profile holds it.
#
# Separate profiles per platform on purpose. A shared profile means one cookie
# jar, one cache and one fingerprint for several identities, so anything learned
# about one account applies to the others. Separate directories keep them
# independent and individually re-loginable. The cost is about 530 MB of RAM per
# running browser (measured), which an 8 GB box can afford a few of.
declare -A P_URL=([linkedin]="https://www.linkedin.com/login")
declare -A P_PROFILE=([linkedin]="/mnt/data/browser/social-linkedin")
declare -A P_NAME=([linkedin]="LinkedIn")

# --- Arguments ------------------------------------------------------------
PLATFORM=linkedin
MODE=login
DEEP=""
for a in "$@"; do
  case "$a" in
  --verify) MODE=verify ;;
  --stop) MODE=stop ;;
  --deep) DEEP=--deep ;;
  -*) die "unknown flag: $a" ;;
  *) PLATFORM="$a" ;;
  esac
done
[[ -n "${P_URL[$PLATFORM]:-}" ]] ||
  die "unknown platform: $PLATFORM (have: ${!P_URL[*]})"

PROFILE="${P_PROFILE[$PLATFORM]}"
NAME="${P_NAME[$PLATFORM]}"
URL="${SOCIAL_URL:-${P_URL[$PLATFORM]}}"
PORT="${VNC_LOCAL_PORT:-5900}"

load_config

# Remote helper. The PATH fix-up is required because ss/systemctl live in
# /usr/sbin, which is NOT on the PATH of a non-interactive ssh command -- the
# same trap that once made this repo conclude the box had no swap.
rsh() { ssh_vm "export PATH=/usr/local/sbin:/usr/sbin:/sbin:\$PATH; $1"; }

# The [u] is not a typo. `pgrep -f` matches every process's full command line, and
# the shell ssh spawns to run this command HAS the pattern in its own command
# line -- so a plain pattern reports the browser running when it is not. pgrep
# excludes itself, never its parent. (Measured: 2 false positives without it.)
browser_pid() { rsh "pgrep -f '[u]ser-data-dir=$PROFILE' | head -1" 2>/dev/null | tr -d '[:space:]'; }

stop_vnc() {
  note "stopping x11vnc on the box"
  # reset-failed too: x11vnc traps SIGTERM and exits 2, so an ordinary stop is
  # recorded as a failure and the unit stays failed forever. The unit now sets
  # SuccessExitStatus=2, but a box provisioned before that still has the old one,
  # and a bogus entry in `systemctl --failed` is how real failures get ignored.
  rsh "sudo -n systemctl stop x11vnc; sudo -n systemctl reset-failed x11vnc" 2>/dev/null || true
}

# Ship the verifier over each time rather than depending on a deploy step: it is
# 8 KB of stdlib Python, and a stale copy on the box would be worse than useless.
verify_session() {
  rsh "cat > /tmp/social-session.py" <scripts/social-session.py 2>/dev/null ||
    ssh_vm "cat > /tmp/social-session.py" <"$HERE/social-session.py"
  rsh "python3 /tmp/social-session.py '$PLATFORM' --profile '$PROFILE' $DEEP"
}

case "$MODE" in
# --- verify ------------------------------------------------------------
verify)
  printf '\033[1m%s session in %s\033[0m\n' "$NAME" "$PROFILE"
  if verify_session; then
    exit 0
  else
    rc=$?
    # 1 = not logged in, 2 = could not determine. Different problems: the first
    # needs a login, the second needs looking at.
    [[ $rc -eq 1 ]] && echo && note "log in with: ./run login $PLATFORM"
    exit "$rc"
  fi
  ;;

# --- stop --------------------------------------------------------------
stop)
  stop_vnc
  pid="$(browser_pid)"
  if [[ -n "$pid" ]]; then
    note "stopping $NAME browser (pid $pid)"
    # SIGTERM, never -9: Chromium must flush Cookies and Local State to disk,
    # and killing it hard is a good way to lose the session you just created.
    rsh "kill $pid" || true
    sleep 3
  else
    note "no $NAME browser running"
  fi
  echo "stopped."
  ;;

# --- login -------------------------------------------------------------
login)
  # Preflight in increasing order of cost, so the common failure (no client
  # installed) costs nothing. Each check exists because its absence otherwise
  # surfaces later as a black window, a refused tunnel, or a missing binary.
  viewer=""
  for c in vncviewer wlvncc gvncviewer remmina vinagre; do
    if command -v "$c" >/dev/null 2>&1; then
      viewer="$c"
      break
    fi
  done
  [[ -n "$viewer" ]] && note "using VNC client: $viewer" || die "no VNC client on this machine. Install one:
    sudo pacman -S tigervnc      # provides vncviewer; runs fine under XWayland
  then re-run: ./run login $PLATFORM"

  vm_online || die "$INSTANCE is not on the tailnet. Try: ./run up"

  [[ "$(rsh 'systemctl is-active xvfb' || true)" == active ]] ||
    die "Xvfb is not running on the box, so there is no display to export.
  Check with: ./run verify-browser"

  if ss -ltn 2>/dev/null | grep -q ":$PORT "; then
    die "local port $PORT is already in use (an older tunnel still open?).
  Re-run with a different port:  VNC_LOCAL_PORT=5901 ./run login $PLATFORM"
  fi

  # Already logged in? Say so instead of silently re-doing 2FA. Not fatal --
  # re-logging in is exactly how you recover an expired session.
  if verify_session >/dev/null 2>&1; then
    note "$NAME already has a valid session; opening the browser anyway"
  fi

  trap stop_vnc EXIT INT TERM
  note "starting x11vnc on the box (loopback only, no password -- see comments)"
  rsh "sudo -n systemctl start x11vnc"

  pid="$(browser_pid)"
  if [[ -n "$pid" ]]; then
    note "$NAME browser already running (pid $pid) -- reusing it"
  else
    note "launching social-chromium for $NAME on :99 at $URL"
    # setsid + nohup + closed stdin: without all three the browser is a child of
    # this ssh session and dies with it, taking a half-finished login with it.
    # Forward SOCIAL_WINDOW_SIZE if set, so the user can size the browser to
    # their own screen:  SOCIAL_WINDOW_SIZE=1440,900 ./run login linkedin
    WINSIZE="${SOCIAL_WINDOW_SIZE:-}"
    rsh "SOCIAL_PROFILE_DIR='$PROFILE' ${WINSIZE:+SOCIAL_WINDOW_SIZE='$WINSIZE' }setsid nohup social-chromium '$URL' \
      >/tmp/social-chromium-$PLATFORM.log 2>&1 </dev/null & disown" || true
    sleep 4
    [[ -n "$(browser_pid)" ]] || die "social-chromium did not start. Look at:
  ./run ssh cat /tmp/social-chromium-$PLATFORM.log"
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

$(printf '\033[1m')Log in to %s now, in the VNC window.$(printf '\033[0m')

  1. Type your credentials. Expect an emailed 6-digit code -- have that inbox
     open. Tick "remember this device" if offered.
  2. Land on the real feed, then stop. Don't browse, don't scroll far.
  3. Ctrl-C here when done. The browser stays up; x11vnc and the tunnel are
     shut down for you.

  There is no window manager, so no title bar and nothing to alt-tab: the
  browser is the whole 1920x1080 screen. That is intentional -- a WM buys
  nothing detectable.

EOF
  printf '%s\n' "  (platform: $NAME, profile: $PROFILE)"
  echo

  note "starting $viewer"
  case "$viewer" in
  vncviewer) "$viewer" -Shared "localhost:$PORT" || true ;;
  wlvncc) "$viewer" localhost "$PORT" || true ;;
  *) "$viewer" "vnc://localhost:$PORT" || true ;;
  esac

  # Don't assume it worked -- check.
  echo
  printf '\033[1mVerifying...\033[0m\n'
  if verify_session; then
    echo
    echo "Next: pause and unpause the VM, then './run login $PLATFORM --verify --deep'."
    echo "If the session survives that, it survives anything."
  else
    echo
    note "not logged in yet -- just run ./run login $PLATFORM again"
  fi
  ;;
esac
