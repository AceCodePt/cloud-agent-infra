# TASK

Open, actionable work only. Nothing here explains *why* — reasoning lives in
[`docs/decisions/`](docs/decisions/), evidence in
[`docs/measurements.md`](docs/measurements.md), state of the world in `SPEC.md`.

The core box is built and verified (`./run verify` passes). Remaining work on the
infrastructure layer is small; work on the agent layer (per-client opencode
accounts, the phone approval loop) lives in
[`~/stuff/phone-approval`](../phone-approval)'s `docs/TASK.md`, not here.

The OCI box boots stock Oracle Linux 9 from the single RHEL-family template
(`startup.rhel.sh`); the custom-Arch-image pipeline was removed — see
[`docs/decisions/infrastructure.md`](docs/decisions/infrastructure.md).
`startup.rhel.sh` was validated by a single cloud cycle; any later tweak is a
re-`./run up`, not a rebuild.

Open items:

- **GCP reference path still boots Debian.** `terraform/gcp/` uses the
  `debian-cloud/debian-12` image family, while the repo's rule is one RHEL-family
  startup template (`startup.rhel.sh`) on every provider. Migrate it to Rocky
  Linux 9 (GCP `rocky-linux-9` family, project `rocky-linux-cloud`) and render
  `startup.rhel.sh` — then `startup.debian.sh`'s last reference is gone and every
  provider shares the one template.
