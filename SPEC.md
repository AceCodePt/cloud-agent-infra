# SPEC

What this project is for, what actually exists today, and what is still
undecided. Read it before picking the project back up.

The other places, so nothing is duplicated here:

- **`README.md`** — the front door; where to read depending on the question.
- **[`docs/capabilities.md`](docs/capabilities.md)** — command ↔ script ↔ flow map.
- **[`docs/operating.md`](docs/operating.md)** — how to operate the machine that exists.
- **`TASK.md`** — work that is still open.
- **[`docs/decisions/`](docs/decisions/)** — every settled question, with its
  reasoning and status. **Do not re-argue one of those from memory**; if a
  decision changes, change it there.
- **[`docs/measurements.md`](docs/measurements.md)** — the evidence the decisions
  rest on.

The agent layer — opencode sessions on this box, per-client accounts, and phone
approval — is **not** a goal of this repo. It is a consumer of the infrastructure
here and lives in its own repo: [`~/stuff/phone-approval`](../phone-approval).

---

## Goal

A reliable, reproducible cloud box, reachable **only over Tailscale** from any
other device on the tailnet (laptop or any other tailnet node), that can be
managed and repaired remotely without public exposure.

| Goal | Priority | State |
|---|---|---|
| A reliable, reproducible cloud box reachable only over Tailscale, with a virtual-display browser you can drive by hand from another device | **The reason the machine exists** | **Built and verified** |

The box is substrate. Apps that need always-on hosting, a browser with a logged-in
account, or an agent runner provision themselves onto this box — this repo knows
nothing about any of them.

---

## What exists

Asserted by `./run verify` — 18 checks, passing — and it has survived a full
`cleanup --yes` + rebuild cycle.

**The box**

- Hetzner CX33 (4 vCPU / 8 GB), `nbg1` Nuremberg, Debian 12 — ≈ $11.55/mo all-in
- Zero public ingress; Tailscale-only access (Hetzner firewall, empty rule set =
  block inbound / allow outbound), with Hetzner's web console + rescue system as
  break-glass
- Tailscale one-off auth keys minted via API and validated before every apply
- Tailscale state bind-mounted onto the data volume (by `LABEL=cloud-agent-data`)
  — survives server replacement, but not volume destruction
- Two-phase boot (`scripts/templates/startup.debian.sh`): phase A reaches the
  tailnet in ~1 min, phase B installs the rest out of band
- `./run up` — idempotent convergence, never destructive
- Shared startup template + `PROVIDER` shim in `scripts/lib.sh`; the GCP Terraform
  path remains for reference

**OCI path (free tier)**

The same box on OCI's Always Free A1 boots **stock Oracle Linux 9** with
`scripts/templates/startup.ol.sh` — no custom image, no build/upload/import
pipeline. First boot joins the tailnet in ~1-3 min; phase B (dnf + EPEL + Flatpak
Chromium + Xvfb + zram) finishes in the background. The Arch golden-image path was
removed; see [`docs/decisions/infrastructure.md`](docs/decisions/infrastructure.md).

**On the box** (all from phase B, so all reproducible)

- CLI: `git`, `gh`, `stow`, `tmux`, `neovim` (from GitHub releases, not the Debian 0.7 apt package), `python3-pip`, `build-essential`,
  `fzf`, `direnv`, `unzip`, `libclang-dev`, `mise` (go, rust, node, and tree-sitter-cli installed through mise/cargo per the account's global config)
- Xvfb `:99` + Chromium with one wrapper, `headed-chromium` (CDP, persistent
  profile). An app that needs a browser tied to a logged-in account deploys its
  own wrapper — this repo knows nothing about accounts.
- `x11vnc`, installed but not enabled — started by hand via `./run browser`
- zram compressed swap

## What does not exist

- The agent runner (opencode), per-client accounts, and the phone approval loop.
  These are the sibling [`~/stuff/phone-approval`](../phone-approval) repo's job;
  it provisions itself onto this box over ssh.
- `/mnt/data` holds the browser profiles and the Tailscale state. Nothing else.

---

## Open questions

**1. Client data residency.** Confirmed unrestricted today, so a German VPS is
allowed. Re-check if a client contract says otherwise — and note that at ~$19/mo
per box, one-server-per-client becomes affordable isolation that GCP pricing
forecloses.

**2. Provider migration.** **Made 2026-08-05** — the box is now Hetzner CX33
(≈ $11.55/mo vs GCP's $60.25). The break-glass premise that blocked it (GCP's
IAP being the only second escape) was partly self-imposed; see
[`docs/decisions/infrastructure.md`](docs/decisions/infrastructure.md).

---

## Risks

**Capacity.** The box is `e2-standard-2`. The numbers behind whether that holds
for any particular workload — idle floor, browser memory, how the box degrades
under load — are in `docs/measurements.md`. Slow is acceptable; unreachable is
not, and there is no public inbound to fall back on. `verify.sh` is the tripwire.

**Process.** This project has drifted before: a session that began with a revoked
Tailscale key ended up planning a provider migration, via zram, Thorium, Openbox
and hosted CDP, while the original goal stayed at zero lines. Three
recommendations were reversed inside twenty minutes because each was made against
a locally-scoped question rather than a stated goal. Hence the goal above,
`TASK.md`'s ordering rule, and `docs/decisions/` holding a single answer per
question.
