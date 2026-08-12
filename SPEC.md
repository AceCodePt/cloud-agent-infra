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

Asserted by `./run verify` — **31 checks** (the Oracle idle-check verdict SKIPs
until it has ~17h of CPU history to judge, then is 31/31) — and it has survived
a full `cleanup --yes` + rebuild cycle.

**The box** (active provider: `PROVIDER=oci`)

- OCI **Always Free A1.Flex** (2 OCPU / 12 GB), `il-jerusalem-1`, booting OCI's
  **stock Oracle Linux 9** platform image — no custom image, no build/upload/
  import pipeline (the Arch golden-image path was removed; see
  [`docs/decisions/infrastructure.md`](docs/decisions/infrastructure.md))
- One public ingress: a **reserved public IPv4** (stable direct endpoint) + a
  security list whose only ingress is IPv4+IPv6 UDP 41641 (Tailscale's WireGuard
  port, for the direct non-DERP path); everything else closed at the edge,
  Tailscale-only access, with the OCI serial console (Cloud Shell) as break-glass
- Tailscale one-off auth keys minted via API and validated before every apply
- Tailscale state bind-mounted onto the block volume (by `LABEL=cloud-agent-data`)
  — survives instance replacement, but not volume destruction
- Two-phase boot (`scripts/templates/startup.rhel.sh`): phase A reaches the
  tailnet in ~3-4 min, phase B (dnf + EPEL + Flatpak Chromium + zram +
  dnf-automatic) installs the rest out of band
- `./run up` — idempotent convergence, never destructive
- One RHEL-family startup template for every provider: OCI boots its stock
  Oracle Linux 9, the Hetzner and GCP Terraform paths boot Rocky Linux 9 — the
  setup process after picking the image is identical. `PROVIDER` shim in
  `scripts/lib.sh`; the Hetzner and GCP paths remain for reference (GCP still
  on Debian; see `TASK.md`)

**On the box** (all from phase B, so all reproducible)

- CLI: `git`, `gh`, `stow`, `tmux`, `python3-pip`, the `Development Tools`
  group, `fzf`, `unzip` via dnf+EPEL; `neovim` (GitHub release), `direnv`
  (GitHub static binary), and `mise` (GitHub release; go, rust, node, and
  tree-sitter-cli installed through mise/cargo per the account's global config)
- Xvfb `:99` + Chromium with one wrapper, `headed-chromium` (Flatpak build, CDP,
  persistent profile). An app that needs a browser tied to a logged-in account
  deploys its own wrapper — this repo knows nothing about accounts.
- `x11vnc`, installed but not enabled — started by hand via `./run browser`
- zram compressed swap
- `oci-idle-burn` (phase A): the Oracle Always Free idle guard — keeps the
  95th-percentile CPU above Oracle's 20% reclaim floor with an idle-priority
  spin loop (`nice 19` + `CPUWeight=1`, so real work preempts it). Installed
  only where the image carries the Oracle Cloud Agent
  (`/usr/libexec/oracle-cloud-agent`), so Hetzner/Rocky and GCP boots never
  see it and the shared template stays provider-neutral.
- `oci-cpu-sampler` + `oci-idle-check` (phase A): a once-a-minute CPU sampler
  (rolling window on the data volume) and a **daily** timer that recomputes the
  7-day p95 CPU against the 20% reclaim floor and logs the verdict to
  `/mnt/data/idle-check/daily.log`. Same Oracle-only guard: a dead burn unit is
  caught within a day instead of at reclaim. Verify trips on a non-SAFE result.

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

**2. Provider history.** The box moved GCP → Hetzner on 2026-08-05
(`docs/decisions/infrastructure.md`), then to OCI's free-tier A1 on 2026-08-10 —
free, first-party Oracle Linux, and a verified 28/28 `./run verify`. The Hetzner
path remains the paid fallback if OCI's free-tier A1 capacity ever gets flaky or
the box needs to leave the Jerusalem home region.

---

## Risks

**Capacity.** The box is an A1.Flex with 2 OCPU / 12 GB. The numbers behind
whether that holds for any particular workload — idle floor, browser memory, how
the box degrades under load — are in `docs/measurements.md`. Slow is acceptable;
unreachable is not, and there is no public inbound to fall back on. `verify.sh`
is the tripwire.

**Process.** This project has drifted before: a session that began with a revoked
Tailscale key ended up planning a provider migration, via zram, Thorium, Openbox
and hosted CDP, while the original goal stayed at zero lines. Three
recommendations were reversed inside twenty minutes because each was made against
a locally-scoped question rather than a stated goal. Hence the goal above,
`TASK.md`'s ordering rule, and `docs/decisions/` holding a single answer per
question.
