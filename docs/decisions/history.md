# Superseded architecture

Where this project started, and why it is not there any more. Kept so the same
ground is not re-walked; nothing here describes the current box.

---

## Container on Container-Optimized OS → native VM

**Superseded 2026-08-03.**

The first shape was an app container on COS. The layering caused a cascade of
problems, none of them the actual work:

- read-only `/mnt`
- a Tailscale sidecar fighting the app container
- host/container port-22 collisions
- Tailscale SSH hanging on a bare container

Dropping the container entirely — one machine, one sshd path, one `tailscaled` —
removed all four. Everything in the repo now assumes a native VM.

## Arch Linux → Debian 12

**Superseded 2026-08-03.**

The box originally ran Arch for parity with the laptop. Two problems:

- the public `arch-linux-gce` image had gone stale (newest: Sept 2022), so every
  first boot needed a ~200-package upgrade through retired repos and expired
  keyrings
- a rolling release wants babysitting that an unattended box should not need

The workload is distro-agnostic, so parity bought nothing real. Debian 12 from
Google's own image family is always fresh and ships `unattended-upgrades`.
Boring, on purpose.
