#!/usr/bin/env bash
#
# wait-ready.sh — block until a freshly applied VM is actually usable.
#
# "apply finished" is not "ready": the notify keypair is generated near the end
# of the startup script, so running provision-phone.sh or verify.sh before that
# produces confusing failures. Ready means: node online in the tailnet AND the
# startup script logged its completion line (~40-60s on a cold boot, since
# startup.tf defers the ~200MB browser stack to agent-packages.service).
#
# Phase B is NOT waited for by default — deferring it is the point; --packages
# blocks on it for when you want the fully-provisioned machine.
#
# Usage: ./scripts/wait-ready.sh [timeout-seconds] [--packages]  (default 600)
#
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
    die "timed out after ${elapsed}s. tailnet=$joined startup_complete=$complete packages=$packages_done
  Inspect the boot with:
    gcloud compute instances get-serial-port-output $INSTANCE --zone $ZONE | tail -40
  A VM that boots but never joins the tailnet usually means the auth key was
  spent, revoked, expired, or missing (there is no public inbound, so it just
  looks dead). Recover with: ./run rekey"
  fi

  if ! $joined; then
    if command -v tailscale >/dev/null 2>&1 &&
      tailscale status 2>/dev/null | grep -qE "[[:space:]]$INSTANCE[[:space:]]"; then
      joined=true
      note "tailnet: $INSTANCE is online (${elapsed}s)"
    fi
  fi

  # One serial-port read per iteration, reused below. Phase B runs as a systemd
  # unit, so its output reaches the journal and therefore the serial console —
  # which is why this can watch it without needing SSH.
  SERIAL="$(gcloud_instance get-serial-port-output 2>/dev/null || true)"

  if ! $complete; then
    # Two independent signals, because neither alone is trustworthy: the SENTINEL
    # FILE is authoritative but needs SSH (needs the tailnet); the SERIAL CONSOLE
    # needs no SSH but can silently DROP the final line (stdout is an unflushed
    # tee) — relying on it alone turned an 84s boot into a 10-minute timeout.
    if $joined && ssh_vm test -f /run/agent-startup-complete 2>/dev/null; then
      complete=true
      note "startup script completed (${elapsed}s, sentinel file)"
    elif grep -q 'agent startup complete' <<<"$SERIAL"; then
      complete=true
      note "startup script completed (${elapsed}s, serial console)"
    fi
  fi

  if ! $packages_done; then
    if grep -q 'agent packages complete' <<<"$SERIAL"; then
      packages_done=true
      note "deferred package install finished (${elapsed}s)"
    elif grep -q 'agent-packages.service: Failed' <<<"$SERIAL"; then
      warn "the deferred package install FAILED. The box is reachable, but the
  browser stack is not installed. Diagnose with:
    ./run ssh journalctl -u agent-packages -n 50"
      # Not fatal: reachability is what "ready" means; --packages callers get the
      # timeout below if they insist on waiting for an install that won't come.
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
