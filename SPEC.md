# SPEC

What this project is for, what actually exists today, and what is still
undecided. Read it before picking the project back up.

Three other places, so nothing is duplicated here:

- **`README.md`** — how to operate the machine that exists.
- **`TASK.md`** — work that is still open.
- **[`docs/decisions/`](docs/decisions/)** — every settled question, with its
  reasoning and status. **Do not re-argue one of those from memory**; if a
  decision changes, change it there.
- **[`docs/measurements.md`](docs/measurements.md)** — the evidence the decisions
  rest on.

---

## Goals

Numbered in the order they were first stated, which is NOT their priority. The
priority column is what matters.

| # | Goal | Priority | State |
|---|---|---|---|
| 4 | Agentic workflows for client companies: multiple agents, isolated per client, with agent-driven browser testing | **PRIMARY — the reason the machine exists** | Runner installed and measured; **no design, no per-client anything** |
| 1 | A reliable, reproducible cloud box reachable only over Tailscale, able to notify the phone | Substrate for the above | **Built and verified** |
| 2 | Track posts in the LinkedIn feed and notify the phone | Secondary | Logged in, session verified; nothing reads the feed |
| 3 | Extend to Facebook + Instagram: relevant comments, suggest replies | Secondary | Not started |

Goals 2 and 3 are further along than the primary goal, which is an inversion
worth naming: effort followed whatever was concrete and measurable (fingerprints
have crisp right answers) rather than what mattered most. That is why this table
has a priority column at all.

Sizing is downstream of goal 4 and cannot be settled until goal 4 is defined.

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

- CLI: `git`, `stow`, `tmux`, `vim`, `python3-pip`, `build-essential`
- Node.js 24 from the NodeSource apt repo
- **opencode, pinned to `1.18.11`**, one root-owned binary in `/usr/local/bin`
- Xvfb `:99` + Chromium, two wrappers: `headed-chromium` (CDP, for testing our
  own apps) and `social-chromium` (never CDP, for logged-in accounts)
- `x11vnc`, installed but not enabled — started by hand for a one-time login
- zram compressed swap

**Goal 2, so far**

- A LinkedIn account is logged in by hand on the box, into
  `/mnt/data/browser/social-linkedin`
- `./run login --verify` proves the session from the cookie jar with no traffic;
  `--deep` proves it is live with one authenticated request
- Two fingerprint defects found and fixed (timezone, WebGL) — see
  `docs/measurements.md`

## What does not exist

- **Goal 4 has no design.** No per-client Unix accounts, no container runtime, no
  `gh`, no client checkouts, no isolation model, no concurrency target. The runner
  binary being installed is not the same as goal 4 being started.
- **Nothing reads the feed.** No `extension/`, no `controller/`, no
  `./run deploy`.
- `/mnt/data` holds the browser profiles, Tailscale state, the phone notify key,
  and the measurement corpora at `/mnt/data/repos/{ts,pyd}`. Nothing else.

---

## Planned architecture for goal 2

Not built. The reasoning is in
[`docs/decisions/browser-and-social.md`](docs/decisions/browser-and-social.md);
this is only the shape:

```
  controller (node, on the VM)
    └─ WebSocket server on 127.0.0.1:8765
         ▲                          │
         │ harvested JSON           │ commands: scroll / harvest / stop
         │                          ▼
  ┌──────┴───────────────────────────────────┐
  │ extension service worker  (holds the WS)  │
  │        ▲ chrome.runtime messaging ▼       │
  │ content script (isolated world, reads DOM)│
  └───────────────────────────────────────────┘
        real headful Chrome on Xvfb :99
        LinkedIn tab — sees none of the above
```

No CDP anywhere in that chain, which is the entire point.

---

## Open questions

**1. What is goal 4, concretely?** Concurrent agent count; whether isolation is a
Unix user, a container or a whole box per client; whether browser testing means
one browser or one per agent. Determines sizing, which determines whether the
provider gap is $154/yr or $1,353/yr. All infrastructure work waits on this.

**2. Does the social session survive a VM pause/unpause?** Untested, and it is a
decision point rather than a detail: if it does not, goal 2's whole "log in once
by hand" premise changes.

**3. Client data residency.** Confirmed unrestricted today, so a German VPS is
allowed. Re-check if a client contract says otherwise — and note that at ~$19/mo
per box, one-server-per-client becomes affordable isolation that GCP pricing
forecloses.

Break-glass on a non-GCP provider is also unresolved, but it is recorded with the
parked migration decision in
[`docs/decisions/infrastructure.md`](docs/decisions/infrastructure.md).

---

## Risks

**Goal 2 — LinkedIn**

- **The feed requires authentication.** No official API exposes the member home
  feed, and the User Agreement prohibits automated access. The realistic downside
  is account restriction — losing the network and history — not litigation.
- **Silent breakage is the likely failure mode**, not a dramatic ban: a layout
  change that parses zero posts looks identical to a quiet feed. Zero parsed items
  must alert.
- **DOM scraping is fragile.** Generated class names churn and the feed is
  virtualised. Reading response bodies would be sturdier but is not available in
  MV3 without touching the page or using CDP.
- **Service workers die unpredictably.** Keepalive prevents *idle* death only;
  reconnect logic is mandatory.
- Residual fingerprint differences are accepted knowingly: software renderer,
  `hardwareConcurrency: 2`, no trusted input events from an extension.

**Goal 3 — Meta**

Facebook and Instagram are linked through Accounts Center, so enforcement can
cascade across both, and Meta is more aggressive about automation than LinkedIn.

**Goal 4 — capacity**

The box saturates at roughly two actively-working agents on 2 vCPU. Any promise
made to a client about concurrency is currently unbacked.

**Process**

This project has drifted before: a session that began with a revoked Tailscale
key ended up planning a provider migration, via zram, Thorium, Openbox and hosted
CDP, while goals 2–4 stayed at zero lines. Three recommendations were reversed
inside twenty minutes because each was made against a locally-scoped question
rather than a stated goal. Hence the priority column above, `TASK.md`'s ordering
rule, and `docs/decisions/` holding a single answer per question.
