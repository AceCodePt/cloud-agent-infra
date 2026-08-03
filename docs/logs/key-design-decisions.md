# Log: Key design decisions

**Date:** 2026-08-03
**Status:** current

The current architecture's key decisions, for the record:

- **Debian 12 on Google's own image family** (`debian-cloud/debian-12`),
  rebuilt constantly — first boot has nothing to catch up on, and
  `unattended-upgrades` ships enabled. Chosen for zero-drama unattended
  operation.
- **Tailscale SSH** for access (works on a real systemd host; no key
  management, no OpenSSH port to manage).
- **Dedicated, locked-down VPC** — no public inbound on any port.
- **Separate persistent disk** at `/mnt/data` for repos + tailscale state,
  so the VM stays disposable while work + node identity survive rebuilds.
- **Headed browser for agents** — no desktop/WM: Chromium runs on an Xvfb
  virtual display (`:99`) as a *real* browser (defeats headless detection),
  with CDP for automation and profiles persisted on `/mnt/data`.
