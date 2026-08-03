# Log: Container-on-COS → native VM

**Date:** 2026-08-03 (as noted in README history)
**Status:** superseded by current architecture (native Debian VM)

## Decision

Started as a container-on-Container-Optimized-OS setup. That layering caused
a cascade of problems:

- Read-only `/mnt`
- A Tailscale sidecar fighting the app container
- Host/container port-22 collisions
- Tailscale SSH hanging on a bare container

The fix was to drop the container entirely and run a **native Linux VM** — one
machine, one sshd path, one tailscaled. Everything in the current repo reflects
that simpler architecture.
