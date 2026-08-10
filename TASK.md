# TASK

Open, actionable work only. Nothing here explains *why* — reasoning lives in
[`docs/decisions/`](docs/decisions/), evidence in
[`docs/measurements.md`](docs/measurements.md), state of the world in `SPEC.md`.

The core box is built and verified (`./run verify` passes). Remaining work on the
infrastructure layer is small; work on the agent layer (per-client opencode
accounts, the phone approval loop) lives in
[`~/stuff/phone-approval`](../phone-approval)'s `docs/TASK.md`, not here.

## Image build is aarch64-only — make the target arch a parameter

The image pipeline (`build-image.sh`, `build-inner.sh`, `images/scripts/*.sh`,
`boot-test-local.sh`, `import-image.sh`) hardcodes aarch64 as the single target:
ARM tarball, `qemu-aarch64-static`, `BOOTAA64.EFI`, `/boot/Image`, `console=ttyAMA0`,
AAVMF boot test, UEFI_64 import + A1.Flex shape compat. The host/guest split is
implicit (host runs the tools natively; only the chroot runs under qemu) and
never parameterized.

**What to do:** introduce `TARGET_ARCH` (or a config.env `IMAGE_ARCH`) driving
`aarch64|x86_64`, and parameterize every hardcoded assumption: rootfs tarball URL,
qemu-static binary path, `grub-mkstandalone -O` + EFI binary name (`BOOTAA64.EFI`
vs `BOOTX64.EFI`), kernel image name (`Image` vs `bzImage`), serial console
(`ttyAMA0` vs `ttyS0`), the local QEMU/AAVMF boot test (`qemu-system-aarch64` +
`edk2-aarch64` vs x86_64 + OVMF), and the OCI import firmware/shape-compat entry.
Verify aarch64 still produces the identical booting image before shipping x86_64.

**Open question to settle first:** is x86 actually wanted? OCI Always Free is ARM-only,
so the only reason to build x86 images would be booting them on a paid x86 shape or
another provider. Decide before refactoring, or the parameterization is dead abstraction.

## Build natively when host arch == target arch, qemu otherwise

The build today always cross-compiles through qemu, even though it only needs to
when the host and target differ: building aarch64 for OCI on this x86_64 host, or
an x86_64 image on an aarch64 host, requires qemu-aarch64-static/x86_64-static;
building x86_64 on x86_64 or aarch64 on aarch64 can chroot natively.

**What to do:** in `build-image.sh` (and by extension `build-inner.sh`), detect the
host arch (`uname -m`) and compare it to the target: if they match, skip the qemu
dependency entirely and run the chroot natively; only bind in the qemu-static
binary when they differ. Parameterize the qemu-static path by target arch (currently
hardcoded `qemu-aarch64-static`) so the comparison is real, and keep the 
`QEMU_STATIC` override for cross builds.

**Payoff:** native builds eliminate the cross-arch compensation hacks in
`01-base.sh` (the dropped fsck hook and the hard-pinned virtio MODULES, both
workarounds for the emulated chroot reading the x86 host's `/sys`), drop the
external qemu prerequisite on same-arch hosts, and remove TCG emulation slowness.
Verify the native path produces an identical booting image before relying on it.
