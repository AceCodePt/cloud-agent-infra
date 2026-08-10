#!/usr/bin/env bash
set -euo pipefail

# 05-cleanup: shrink the image and drop machine/instance identity.
# Runs INSIDE the image chroot (via qemu-aarch64-static).

echo "=== 05-cleanup: remove qemu, caches, machine/instance identity ==="

# qemu user-mode emulator copied in by the plugin for chroot execution.
rm -f /usr/bin/qemu-aarch64-static

# pacman package cache.
rm -rf /var/cache/pacman/pkg/*

# systemd regenerates /etc/machine-id on boot.
rm -f /etc/machine-id

# SSH host keys are regenerated per instance.
rm -f /etc/ssh/ssh_host_*

# Provisioner scripts and other build-time cruft in /tmp.
rm -rf /tmp/*

# The tailscale auth key is deployment-specific and MUST NOT be baked into
# the image; it is delivered to the instance out of band at first boot.
rm -f /etc/agent/authkey

# cloud-init per-instance state and semaphores: regenerated on first boot so
# every instance runs user_data fresh (instance dir + /var/lib/cloud/instance
# symlink + semaphore dir).
rm -rf /var/lib/cloud/instances/*
rm -rf /var/lib/cloud/sem
rm -f /var/lib/cloud/instance

echo "=== 05-cleanup: done ==="
