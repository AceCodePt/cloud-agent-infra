#!/usr/bin/env bash
set -uo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_config

WAIT_PACKAGES=false
ARGS=()
for arg in "$@"; do
  case "$arg" in
  --packages) WAIT_PACKAGES=true ;;
  *) ARGS+=("$arg") ;;
  esac
done

TIMEOUT="${ARGS[0]:-600}"
START="$(date +%s)"

note "Waiting for $INSTANCE to be ready (timeout ${TIMEOUT}s)"

joined=false
complete=false
packages_done=false
$WAIT_PACKAGES && note "will also wait for the deferred package install (phase B)"

while :; do
  elapsed=$(($(date +%s) - START))
  if [[ "$elapsed" -gt "$TIMEOUT" ]]; then
    echo >&2
    if [[ "$PROVIDER" == hetzner ]]; then
      die "timed out after ${elapsed}s. tailnet=$joined startup_complete=$complete packages=$packages_done
  Inspect the boot with the Hetzner Cloud web console (VNC) for $INSTANCE, or
  connect its rescue system. A server that boots but never joins the tailnet
  usually means the auth key was spent, revoked, expired, or missing (there is
  no public inbound, so it just looks dead). Recover with: ./run rekey"
    else
      die "timed out after ${elapsed}s. tailnet=$joined startup_complete=$complete packages=$packages_done
  Inspect the boot with:
    gcloud compute instances get-serial-port-output $INSTANCE --zone $ZONE | tail -40
  A VM that boots but never joins the tailnet usually means the auth key was
  spent, revoked, expired, or missing (there is no public inbound, so it just
  looks dead). Recover with: ./run rekey"
    fi
  fi

  if ! $joined; then
    if command -v tailscale >/dev/null 2>&1 &&
      tailscale status 2>/dev/null | grep -qE "[[:space:]]$INSTANCE[[:space:]]"; then
      joined=true
      note "tailnet: $INSTANCE is online (${elapsed}s)"
    fi
  fi

  if [[ "$PROVIDER" == hetzner ]]; then
    SERIAL=""
  else
    SERIAL="$(gcloud_instance get-serial-port-output 2>/dev/null || true)"
  fi

  if ! $complete; then
    if $joined && ssh_vm test -f /run/agent-startup-complete 2>/dev/null; then
      complete=true
      note "startup script completed (${elapsed}s, sentinel file)"
    elif grep -q 'agent startup complete' <<<"$SERIAL"; then
      complete=true
      note "startup script completed (${elapsed}s, serial console)"
    fi
  fi

  if ! $packages_done; then
    if [[ "$PROVIDER" == hetzner ]]; then
      PKG="$(ssh_vm 'systemctl is-active agent-packages' 2>/dev/null || true)"
      case "$PKG" in
      active)
        packages_done=true
        note "deferred package install finished (${elapsed}s)"
        ;;
      failed)
        warn "the deferred package install FAILED. The box is reachable, but the
  browser stack is not installed. Diagnose with:
    ./run ssh journalctl -u agent-packages -n 50"
        $WAIT_PACKAGES || packages_done=true
        ;;
      esac
    elif grep -q 'agent packages complete' <<<"$SERIAL"; then
      packages_done=true
      note "deferred package install finished (${elapsed}s)"
    elif grep -q 'agent-packages.service: Failed' <<<"$SERIAL"; then
      warn "the deferred package install FAILED. The box is reachable, but the
  browser stack is not installed. Diagnose with:
    ./run ssh journalctl -u agent-packages -n 50"
      $WAIT_PACKAGES || packages_done=true
    fi
  fi

  if $joined && $complete && { ! $WAIT_PACKAGES || $packages_done; }; then
    note "Ready after ${elapsed}s."
    if ! $packages_done; then
      note "Phase B (CLI tools + browser stack) is still installing in the background."
      note "  progress:  ./run ssh journalctl -u agent-packages -f"
      note "  block:     ./run wait --packages"
      note "  check:     ./run verify-browser"
    fi
    exit 0
  fi

  printf '.'
  sleep 10
done
