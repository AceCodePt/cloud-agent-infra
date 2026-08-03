# Log: Arch Linux → Debian 12

**Date:** 2026-08-03 (as noted in README history)
**Status:** superseded by current architecture (Debian 12)

## Decision

The box originally ran **Arch Linux** for laptop parity. Problems:

- The public `arch-linux-gce` image went stale (newest: Sept 2022), so every
  first boot needed a ~200-package upgrade through a minefield of retired repos
  and expired keyrings.
- A rolling release wants babysitting an unattended box shouldn't need.

The workload (opencode agents, Chromium, Tailscale) is entirely
distro-agnostic, so the box now runs **Debian 12**: a Google-maintained image
that is always fresh, with `unattended-upgrades` for security patches. Boring,
on purpose.
