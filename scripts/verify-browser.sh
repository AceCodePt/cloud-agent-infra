#!/usr/bin/env bash
set -uo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_config

RAW=false
QUICK=false
for arg in "$@"; do
  case "$arg" in
  --raw) RAW=true ;;
  --quick) QUICK=true ;;
  -h | --help)
    echo "Usage: ./run verify-browser [--quick]"
    exit 0
    ;;
  *) die "unknown flag: $arg (try --quick, --raw)" ;;
  esac
done

FAILED=0
emit() { # emit PASS|FAIL|SKIP <description>
  local verdict="$1" desc="$2"
  [[ "$verdict" == FAIL ]] && FAILED=$((FAILED + 1))
  if $RAW; then
    printf '%s %s\n' "$verdict" "$desc"
  else
    case "$verdict" in
    PASS) printf '  \033[32mPASS\033[0m  %s\n' "$desc" ;;
    FAIL) printf '  \033[31mFAIL\033[0m  %s\n' "$desc" ;;
    SKIP) printf '  \033[33mSKIP\033[0m  %s\n' "$desc" ;;
    esac
  fi
}

fact() { printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -1; }

$RAW || printf '\n\033[1mBrowser stack\033[0m\n'

FACTS="$(ssh_vm QUICK="$QUICK" 'bash -s' 2>/dev/null <<'VMEOF'
set -u
export PATH="/usr/local/sbin:/usr/sbin:/sbin:$PATH"
echo "reachable=yes"

echo "packages=$(systemctl is-active agent-packages 2>/dev/null || true)"

command -v chromium >/dev/null && echo "chromium=yes" || echo "chromium=no"
pgrep -x Xvfb >/dev/null && echo "xvfb=yes" || echo "xvfb=no"
swapon --noheadings --show=NAME 2>/dev/null | grep -q zram && echo "zram=yes" || echo "zram=no"

if [ "$QUICK" = "false" ] && command -v chromium >/dev/null; then
  export DISPLAY=:99 CDP_PORT=9333 BROWSER_PROFILE_DIR=/mnt/data/browser/verify
  headed-chromium about:blank >/tmp/verify-chromium.log 2>&1 </dev/null &
  CH=$!
  BROWSER=""
  for _ in $(seq 1 25); do
    sleep 1
    BROWSER="$(curl -s --max-time 2 http://127.0.0.1:9333/json/version 2>/dev/null |
      sed -n 's/.*"Browser": *"\([^"]*\)".*/\1/p')"
    [ -n "$BROWSER" ] && break
  done
  echo "cdp=${BROWSER:-unreachable}"
  kill "$CH" 2>/dev/null
  sleep 1
  kill -9 "$CH" 2>/dev/null
else
  echo "cdp=skipped"
fi
VMEOF
)"

if [[ "$(fact "$FACTS" reachable)" != "yes" ]]; then
  emit FAIL "cannot SSH to $SSH_USER@$INSTANCE for the browser checks"
  exit 1
fi

PKGS="$(fact "$FACTS" packages)"
case "$PKGS" in
activating)
  emit SKIP "browser stack still installing (agent-packages: activating)"
  emit SKIP "  watch it:  ./run ssh journalctl -u agent-packages -f"
  $RAW || printf '\n  Nothing is wrong — phase B defers ~200MB of packages so the\n  VM can join the tailnet in under a minute. Re-run when it finishes.\n'
  exit 0
  ;;
active) ;;
failed)
  emit FAIL "deferred package install FAILED (agent-packages: failed)"
  emit FAIL "  diagnose:  ./run ssh journalctl -u agent-packages -n 50"
  ;;
"" | inactive)
  emit FAIL "deferred package install never ran (agent-packages: ${PKGS:-missing})"
  ;;
*)
  emit FAIL "deferred package install in an unexpected state: $PKGS"
  ;;
esac

if [[ "$PKGS" == active ]]; then
  [[ "$(fact "$FACTS" chromium)" == yes ]] &&
    emit PASS "chromium installed" ||
    emit FAIL "chromium not installed"

  [[ "$(fact "$FACTS" xvfb)" == yes ]] &&
    emit PASS "Xvfb :99 running" ||
    emit FAIL "Xvfb :99 not running"

  [[ "$(fact "$FACTS" zram)" == yes ]] &&
    emit PASS "zram swap active" ||
    emit FAIL "zram swap not active"

  CDP="$(fact "$FACTS" cdp)"
  case "$CDP" in
  skipped) emit SKIP "headed Chromium over CDP (--quick)" ;;
  Chrome/*) emit PASS "headed Chromium reachable over CDP ($CDP)" ;;
  *) emit FAIL "headed Chromium not reachable over CDP (got '$CDP')" ;;
  esac
fi

if ! $RAW; then
  if [[ "$FAILED" -eq 0 ]]; then
    printf '\n\033[1;32mBrowser stack verified.\033[0m\n'
  else
    printf '\n\033[1;31mBrowser stack: %d check(s) failed.\033[0m\n' "$FAILED" >&2
  fi
fi
[[ "$FAILED" -eq 0 ]]
