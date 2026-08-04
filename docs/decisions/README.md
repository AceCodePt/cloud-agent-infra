# Decisions

Every settled question lives here, with its reasoning and its status. Nothing
else in the repo should re-argue one: `README.md` documents how to operate the
machine, `SPEC.md` states the goals and the current state, `TASK.md` lists work
that is still open, `docs/capabilities.md` maps command ↔ script ↔ flow,
`docs/operating.md` is the operator's manual, and `docs/measurements.md` holds
the evidence these decisions were made from.

If a decision changes, edit it here and change its status. Do not leave two
answers to the same question in two files — that is how this repo previously
ended up asserting both "static IP, for session stability" and "no static IP,
the premise is unevidenced".

## Status vocabulary

| Status | Meaning |
|---|---|
| **Made** | In force. The code reflects it. |
| **Rejected** | Considered, deliberately not done. |
| **Reversed** | Implemented, then undone. Recorded so it is not re-implemented from memory. |
| **Superseded** | Was in force; a later decision replaced it. |
| **Parked** | Deliberately not decided yet, with the condition that would unblock it. |

## Index

### [infrastructure.md](infrastructure.md) — the box and how it is built

| Decision | Status |
|---|---|
| Native VM, not a container on COS | Made |
| Debian 12 from Google's image family, not Arch | Made |
| Tailscale-only access, dedicated VPC, IAP as break-glass | Made |
| Separate persistent data disk at `/mnt/data` | Made |
| Two-phase boot | Made |
| One-off auth keys minted per build, validated before apply | Made |
| Node.js from the vendor apt repo, not a curl-to-shell install | Made |
| `config.env` as the single source of truth; no direnv | Made |
| zram compressed swap — kept | Made |
| Stay on GCP for now | Made |
| Static external IP | Reversed |
| Right-sizing the box | Parked |
| Provider migration | Parked |

### [browser-and-social.md](browser-and-social.md) — browsers, fingerprints, social accounts

| Decision | Status |
|---|---|
| Two browsers split by purpose; the social one never speaks CDP | Made |
| Extension + local WebSocket controller instead of CDP | Made |
| Private, unlisted extension; no `web_accessible_resources`; no DOM writes | Made |
| Headful Chromium on Xvfb, no window manager | Made |
| Coherence over invisibility (real TZ, real-looking WebGL, no spoof flags) | Made |
| Run the browser locally, not on a hosted CDP service | Made |
| Log in by hand on the box; never copy a cookie from the laptop | Made |
| No proxy, no exit-node egress, no residential IP | Made |
| No scheduled poller; read-only; randomised spacing | Made |
| Constraints on how the reader reads (notifications first, harvest mid-scroll, status codes) | Made |
| ToS exposure, stated plainly | Accepted risk |
| Openbox | Rejected |
| Thorium instead of Debian's Chromium | Rejected |
| Block media via CDP to save bandwidth | Superseded |
| Meta (Facebook/Instagram) | Parked |

### [agents-and-sizing.md](agents-and-sizing.md) — the agent runner and how the box is sized

| Decision | Status |
|---|---|
| opencode is the runner, pinned, one root-owned binary | Made |
| Server + attach, not a TUI per human; phone drives it over HTTP/SSE | Made |
| Size from measurement, and measure PSS rather than RSS | Made |
| CPU is the binding constraint, so a resize buys cores | Made |
| Language server chosen per client repo; tsgo for large TypeScript | Made |
| Node rather than Python for anything the extension talks to | Made |
| Measure token spend before optimising the VM further | Made |
| Concurrency target: 5–10 clients, ~2 simultaneously active | Made |
| Isolation model: Unix user per client | Made |
| Browser testing: one shared browser, or served over the tailnet from outside | Made |
| Phone approval loop | Open |
| Build goal 2 before touching infrastructure | Superseded |

### [history.md](history.md) — superseded architecture

Where the project started and why it moved: container-on-COS → native VM, Arch
→ Debian. Kept only so the same ground is not re-walked.
