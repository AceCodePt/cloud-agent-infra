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
ssh_check_notified=false
hostkey_cleared=false
approval_last_hint=0
last_probe_issue=""
$WAIT_PACKAGES && note "will also wait for the deferred package install (phase B)"

while :; do
  elapsed=$(($(date +%s) - START))
  # A pending Tailscale SSH approval means the wait is on the human, not the
  # box: extend the budget so a slow click doesn't kill the run mid-provision.
  effective_timeout="$TIMEOUT"
  if $ssh_check_notified; then
    effective_timeout=$((TIMEOUT + ${WAIT_APPROVAL_TIMEOUT:-1800}))
  fi
  if [[ "$elapsed" -gt "$effective_timeout" ]]; then
    echo >&2
    if $ssh_check_notified; then
      die "timed out waiting for the Tailscale SSH approval (${WAIT_APPROVAL_TIMEOUT:-1800}s).
  Approve the URL printed above, then re-run: ./run up"
    fi
    if [[ "$PROVIDER" == hetzner ]]; then
      die "timed out after ${elapsed}s. tailnet=$joined startup_complete=$complete packages=$packages_done
  last probe issue: ${last_probe_issue:-none}
  Inspect the boot with the Hetzner Cloud web console (VNC) for $INSTANCE, or
  connect its rescue system. A server that boots but never joins the tailnet
  usually means the auth key was spent, revoked, expired, or missing (there is
  no public inbound, so it just looks dead). Recover with: ./run rekey"
    elif [[ "$PROVIDER" == oci ]]; then
      die "timed out after ${elapsed}s. tailnet=$joined startup_complete=$complete packages=$packages_done
  last probe issue: ${last_probe_issue:-none}
  Inspect the boot with the OCI console serial connection for $INSTANCE. A VM
  that boots but never joins the tailnet usually means the auth key was spent,
  revoked, expired, or missing (there is no public inbound, so it just looks
  dead). Recover with: ./run rekey"
    else
      die "timed out after ${elapsed}s. tailnet=$joined startup_complete=$complete packages=$packages_done
  last probe issue: ${last_probe_issue:-none}
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

  if [[ "$PROVIDER" == hetzner || "$PROVIDER" == oci ]]; then
    SERIAL=""
  else
    SERIAL="$(gcloud_instance get-serial-port-output 2>/dev/null || true)"
  fi

  if ! $complete; then
    if $joined; then
      PROBE_OUT="$(ssh_vm test -f /run/agent-startup-complete 2>&1)"
      PROBE_RC=$?
      if [[ "$PROBE_RC" -eq 0 ]]; then
        complete=true
        note "startup script completed (${elapsed}s, sentinel file)"
      else
        if [[ "$PROBE_RC" -eq 124 ]]; then
          last_probe_issue="SSH probe is stalling (no answer in ${SSH_TIMEOUT:-20}s) — check-mode approval pending, or SELinux is blocking Tailscale SSH"
        elif grep -q "REMOTE HOST IDENTIFICATION HAS CHANGED" <<<"$PROBE_OUT"; then
          last_probe_issue="host key changed (the VM was recreated)"
          if ! $hostkey_cleared; then
            hostkey_cleared=true
            warn "host key for $INSTANCE changed (VM was recreated) — clearing known_hosts and retrying"
            ssh-keygen -R "$INSTANCE" >/dev/null 2>&1 || true
          fi
        elif grep -qiE "could not resolve hostname|Name or service not known" <<<"$PROBE_OUT"; then
          last_probe_issue="'$INSTANCE' does not resolve on the tailnet (MagicDNS) — is this machine's tailnet session logged in?"
        else
          last_probe_issue="SSH probe failed: $(head -1 <<<"$PROBE_OUT")"
        fi
        if (( elapsed % 60 < 10 )); then
          warn "not complete yet (${elapsed}s) — $last_probe_issue"
        fi
      fi
    fi
    if ! $complete && grep -q 'agent startup complete' <<<"$SERIAL"; then
      complete=true
      note "startup script completed (${elapsed}s, serial console)"
    fi
  fi

  # Tailscale SSH "check mode": the first connection from this machine needs a
  # one-time browser approval. Surface the URL when it appears, then keep a
  # compact reminder visible every ~60s so a not-watching human cannot miss it.
  if ! $complete && $joined; then
    PROBE="$(ssh_vm true 2>&1 || true)"
    if grep -qE "additional check|login.tailscale.com" <<<"$PROBE"; then
      CHECK_URL="$(grep -oE 'https://login\.tailscale\.com/a/[A-Za-z0-9]+' <<<"$PROBE" | head -1)"
      if ! $ssh_check_notified; then
        ssh_check_notified=true
        approval_last_hint="$elapsed"
        echo
        warn "Tailscale SSH needs a one-time browser approval before SSH to $INSTANCE works."
        echo "  Open this URL in a browser and approve it — this run continues automatically:"
        echo "    ${CHECK_URL:-<no URL found — run interactively:  ./run ssh>}"
        echo
      elif [[ -n "$CHECK_URL" ]] && (( elapsed - approval_last_hint >= 60 )); then
        approval_last_hint="$elapsed"
        warn "still waiting for the SSH approval — open this URL to continue:"
        echo "    $CHECK_URL"
      fi
    fi
  fi

  if ! $packages_done; then
    if [[ "$PROVIDER" == hetzner || "$PROVIDER" == oci ]]; then
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
