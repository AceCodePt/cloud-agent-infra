# TASK

Open, actionable work only. Nothing here explains *why* — reasoning lives in
[`docs/decisions/`](docs/decisions/), evidence in
[`docs/measurements.md`](docs/measurements.md), state of the world in `SPEC.md`.

The core box is built and verified (`./run verify` passes). Remaining work on the
infrastructure layer is small; work on the agent layer (per-client opencode
accounts, the phone approval loop) lives in
[`~/stuff/phone-approval`](../phone-approval)'s `docs/TASK.md`, not here.

The OCI box boots stock Oracle Linux 9 (`startup.ol.sh`); the custom-Arch-image
pipeline was removed — see
[`docs/decisions/infrastructure.md`](docs/decisions/infrastructure.md).
`startup.ol.sh` was validated by a single cloud cycle; any later tweak is a
re-`./run up`, not a rebuild.
