# TASK

Open, actionable work only. Nothing here explains *why* — reasoning lives in
[`docs/decisions/`](docs/decisions/), evidence in
[`docs/measurements.md`](docs/measurements.md), state of the world in `SPEC.md`.

The core box is built and verified (`./run verify` passes). Remaining work on the
infrastructure layer is small; work on the agent layer (per-client opencode
accounts, the phone approval loop) lives in
[`~/stuff/phone-approval`](../phone-approval)'s `docs/TASK.md`, not here.

## Known nits

- [ ] Naming: the instance/resource/unit names still say "agent"
      (`cloud-agent`, `google_compute_instance.agent`, `agent-packages.service`)
      as a leftover from when the box was built for an agent workload. Harmless,
      but if a rename is ever wanted it must be done as a migration (`tf state mv`
      + `./run rekey`), not a fresh apply.
- [ ] `TF_VAR_machine_type` default (`e2-standard-2`) is larger than a browser
      alone needs; right-sizing is parked in `docs/decisions/infrastructure.md`.
