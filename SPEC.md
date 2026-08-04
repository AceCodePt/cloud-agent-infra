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

The LinkedIn reader (a real account, the extension/controller, feed harvesting)
is NOT a goal of this repo. It is the first app this infrastructure will host,
and it lives in its own repo:
[`AceCodePt/linkedin-reader`](https://github.com/AceCodePt/linkedin-reader).

---

## Goals

Numbered in the order they were first stated, which is NOT their priority.
**Goals 2 and 3 are absent on purpose** — they were the LinkedIn reader and its
Meta extension, and they now live in
[`AceCodePt/linkedin-reader`](https://github.com/AceCodePt/linkedin-reader). The
numbering is kept because `docs/decisions/` refers to it.

| # | Goal | Priority | State |
|---|---|---|---|
| 4 | Agentic workflows for client companies: multiple agents, isolated per client, with agent-driven browser testing | **PRIMARY — the reason the machine exists** | Runner installed and measured; **isolation + concurrency decided (Unix user per client, 5–10 clients), no per-client accounts built yet** |
| 1 | A reliable, reproducible cloud box reachable only over Tailscale, able to notify the phone | Substrate for the above | **Built and verified** |

The box exists to run many agents, one Unix user per client. Everything else —
browser testing, notifications, the apps that use them — is a consumer of that.

---

## What exists

Asserted by `./run verify` — 31 checks, passing — and it has survived a full
`cleanup --yes` + rebuild cycle.

**The box**

- GCP `e2-standard-2` (2 vCPU / 8 GB), `me-west1-a`, Debian 12
- Dedicated VPC, zero public ingress; Tailscale-only access, with
  `gcloud compute ssh --tunnel-through-iap` as break-glass
- Tailscale one-off auth keys minted via API and validated before every apply
- Tailscale state bind-mounted onto the data disk — survives instance
  replacement, but not data-disk destruction
- Phone notifications end to end: `notify-phone` → Termux, restricted
  forced-command key, atomic re-key with rollback
- Two-phase boot (`terraform/startup.tf`): phase A reaches the tailnet in ~84s,
  phase B installs the rest out of band
- `./run up` — idempotent convergence, never destructive
- Terraform state in GCS, bucket lifecycle in `scripts/bootstrap.sh`

**On the box** (all from phase B, so all reproducible)

- CLI: `git`, `stow`, `tmux`, `neovim`, `python3-pip`, `build-essential`
- Node.js 24 from the NodeSource apt repo
- **opencode, pinned to `1.18.11`**, one root-owned binary in `/usr/local/bin`
- Xvfb `:99` + Chromium with one wrapper, `headed-chromium` (CDP, persistent
  profile). An app that needs a browser tied to a logged-in account deploys its
  own wrapper — this repo knows nothing about accounts.
- `x11vnc`, installed but not enabled — started by hand via `./run browser`
- zram compressed swap

## What does not exist

- **Goal 4 has no design.** No per-client Unix accounts, no container runtime, no
  `gh`, no client checkouts. Isolation and concurrency are *decided* (Unix user
  per client, 5–10 clients — see `docs/decisions/agents-and-sizing.md`) but
  nothing is built. The runner binary being installed is not the same as goal 4
  being started.
- `/mnt/data` holds the browser profiles, Tailscale state, and the phone notify
  key. Nothing else.

---

## Open questions

**1. What is goal 4, concretely?** Settled, in `docs/decisions/agents-and-sizing.md`:
5–10 clients with ~2 simultaneously active agents; isolation is a **Unix user per
client**; browser testing is **one shared browser, or a browser served over the
tailnet from outside** (not one per agent); no resize, no migration — the box
stays `e2-standard-2` on GCP. Still open: wiring the phone into an approval loop
and re-measuring over a long real session. The `$154/yr` vs `$1,353/yr` question
is answered: neither, at the current scale.

**2. Client data residency.** Confirmed unrestricted today, so a German VPS is
allowed. Re-check if a client contract says otherwise — and note that at ~$19/mo
per box, one-server-per-client becomes affordable isolation that GCP pricing
forecloses.

Break-glass on a non-GCP provider is also unresolved, but it is recorded with the
parked migration decision in
[`docs/decisions/infrastructure.md`](docs/decisions/infrastructure.md).

---

## Risks

**Goal 4 — capacity**

The box saturates CPU at roughly two actively-working agents on 2 vCPU, but a
concurrency ramp showed it **degrades gracefully, never halts**: 100% completion
up to 24 concurrent sessions on one server, and 3 separate per-client servers
(6/6 rounds) at 2952 MB peak PSS with ~4.6 GB free — see
`docs/measurements.md`. Memory is not the binding constraint; CPU is, and slow
is not halt.

**Process**

This project has drifted before: a session that began with a revoked Tailscale
key ended up planning a provider migration, via zram, Thorium, Openbox and hosted
CDP, while the primary goal stayed at zero lines. Three recommendations were
reversed inside twenty minutes because each was made against a locally-scoped
question rather than a stated goal. Hence the priority column above, `TASK.md`'s
ordering rule, and `docs/decisions/` holding a single answer per question.
