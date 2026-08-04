# Decisions: the agent runner and sizing

Goal 4 — isolated agentic workflows per client company — is the reason the
machine exists. It is researched but not built. What follows is what has been
settled about it, so it is not researched twice. Numbers come from
[`../measurements.md`](../measurements.md).

---

## opencode is the runner, pinned, one root-owned binary — **Made**

Its architecture already fits: opencode is a server with clients attached, not a
monolithic TUI.

- `opencode serve --port N --hostname H` — headless HTTP server, OpenAPI 3.1 spec
  at `/doc`, default `127.0.0.1:4096`.
- `opencode attach http://host:port` — a terminal TUI against the *same* server,
  sharing sessions and state, so phone and laptop can drive one session.
- `opencode web` — a browser UI already exists (session list, active sessions,
  server status), so the phone "app" does not have to be written to get status
  and replies.
- Auth is `OPENCODE_SERVER_PASSWORD` (plus optional
  `OPENCODE_SERVER_USERNAME`, default `opencode`) as HTTP basic auth. Unset means
  unsecured.

**Pinned, not floating** (`OPENCODE_VERSION` in `terraform/startup.tf`, currently
`1.18.11`): this box runs other people's work, and a runner that changes version
underneath a client engagement is not something to discover mid-task.

**Installed from the release tarball into `/usr/local/bin`, not by the vendor
script.** The script installs into `$HOME/.opencode` and rewrites shell rc files
— both wrong for provisioning, and neither answers "which user is this for" once
there is one account per client. A single root-owned binary is shared by every
client account, and no client's agent can modify the runner itself.

Provider credentials are connected by hand through the TUI. Not a blocker to
design around.

## Server + attach, not a TUI per human; the phone drives it over HTTP/SSE — **Made**

The endpoints that cover what the phone needs, so no bespoke protocol is invented:

| Need | Endpoint |
|---|---|
| status | `GET /session/status`, `GET /session/:id/todo`, `GET /project` |
| answer an agent | `POST /session/:id/message`, `/prompt_async` |
| **approve/deny a permission request** | `POST /session/:id/permissions/:permissionID` |
| push instead of polling | `GET /event`, `/global/event` (SSE) |
| stop a runaway agent | `POST /session/:id/abort` |

`/event` plus the existing `notify-phone` path is the whole notification story.
The phone is measured, not assumed: `SM-S928B`, Android 16, `aarch64`, already a
tailnet node, with Termux `node`, `python`, `termux-notification` and
`termux-tts-speak`. `termux-notification` supports action buttons, so approve/deny
can be answered from the notification shade; TTS matters for the
assistant-replacement goal.

## Size from measurement, and measure PSS rather than RSS — **Made**

An earlier draft asserted that 2 vCPU / 8 GB "will not hold several agents". That
was an opinion wearing the clothes of a fact. `./run measure`
(`scripts/measure-resources.py`) replaced it.

**PSS, not RSS, and that is the entire point.** Per-client isolation means several
copies of the same ~180 MB opencode binary, the same libc and the same chromium.
RSS charges every shared page in full to every process that maps it, so sizing
from RSS overestimates in exactly the direction that costs money. PSS divides
shared pages among their sharers, so the numbers can be added up. `MemAvailable`
is sampled alongside as an accounting-independent cross-check.

Corollary: **measure to settle, not to a timer.** A first LSP run with an
8-second quiet window undercounted vtsls by 30%, because the server had merely
paused rather than finished.

## CPU is the binding constraint, so a resize buys cores — **Made**

Measured, and it inverts the earlier assumption:

- marginal cost of another idle opencode server: **221 MB** (the first costs 308)
- a *working* client with an LSP: **~1000 MB**
- one active agent drove 1-minute load to **3.60 on 2 vCPU**; a social browser
  merely parked on the LinkedIn feed drove it to 2.50

So RAM fits roughly six working clients while the CPU saturates at about **two
actively-working agents**. Any resize buys cores, not gigabytes.

Second-order consequence for goal 2: do not leave the social browser sitting on
`/feed/` between reads. Park it on `about:blank`, or stop it and let
`./run login --verify` read the cookie jar with no browser running at all.

## Overload is graceful, not a halt — **Made**

The natural question after the last section: if two active agents saturate the
CPU, what happens with ten? A concurrency ramp (`agent-stress.mjs` +
`box-agent-stress.sh`) answered it empirically: K canaries × R rounds against a
running server, with a sampler watching MemAvailable/swap/load and dmesg grepped
for OOM. **Completion stayed 100% all the way to K=24** — no OOM kill, no dead
process, no failed round — while load climbed to ~11 and MemAvailable never fell
below ~2.5 GB (swap ≤121 MB, absorbed by zram).

The failure mode is "work gets slower", never "work stops". Slow is acceptable
by the operator's own rule, so this removes the only hard capacity objection to
running several clients on one box. The honest per-client number for the real
isolation design (one server each, no shared LSP) is higher — 3 servers measured
at ~2952 MB peak with ~4.6 GB free — still comfortably inside 8 GB. What would
change the answer: a much larger repo, several distinct repos (no shared LSP),
or agents running long builds. Re-run the ramp when a new client type arrives.
Full tables: [`../measurements.md`](../measurements.md).

## Language server chosen per client repo; tsgo for large TypeScript — **Made**

The LSP, not opencode, is the dominant per-client cost, and opencode's default
TypeScript server is the most expensive option measured (1263 MB against tsgo's
200 MB on the same corpus). Switching a large TypeScript client from tsserver to
tsgo is worth more than tripling the box's RAM, and costs a config block.

Both `vtsls` and `tsgo` work as custom servers; opencode ships neither. Per-client
isolation makes this a per-client decision, and each client's `opencode.json`
picks its own:

```json
{
  "lsp": {
    "typescript": { "disabled": true },
    "tsgo": {
      "command": ["tsgo", "--lsp", "--stdio"],
      "extensions": [".ts", ".tsx", ".mts", ".cts", ".js", ".jsx"]
    }
  }
}
```

**The caveat that keeps this honest:** tsgo emitted 1 diagnostic where tsserver
emitted 64. Some of that gap is efficiency (it is a native Go port) and some is
work it did not do — it is a preview with incomplete coverage. Treat 200 MB as a
lower bound and re-measure per client repo with `./run lsp-probe`.

Related facts worth not rediscovering: opencode's built-in `typescript` server
only spawns if `typescript/lib/tsserver.js` resolves from the project, so a client
repo without typescript installed silently gets no TS LSP at all; `pyright` is
auto-downloaded unless `disableLspDownload` is set; and `ty` is gated behind
`experimentalLspTy`, which deletes pyright when enabled.

## Node rather than Python for anything the extension talks to — **Made**

One language across the service worker, the content script and the WebSocket
server, with no build step or bundler keeping three dialects in sync. This is why
Node 24 is provisioned on the box at all.

## Concurrency target: 5–10 clients, ~2 simultaneously active — **Made**

Set by the operator, stated as a pair because the two numbers answer different
questions: "how many clients does the box hold" and "how much agent work is
really happening at once". Measured facts that bound the choice: the box
degrades gracefully and never halts (100% completion to K=24), so the ceiling is
not a hard one; CPU saturates at roughly two actively-working agents on 2 vCPU.

At 5–10 clients with ~2 active agents, **neither resize nor migration is
wanted** — the box stays `e2-standard-2` on GCP as it is. Any future change is
re-decided against the latency rule, not against a capacity ceiling.

## Isolation model: Unix user per client — **Made**

Each client gets a Unix account, its own `opencode` data dir and its own
`opencode.json` (per-client LSP choice is the point of the tsgo decision). No
container runtime. This was the assumption the PSS measurements were built on;
it is now the decision, so sizing numbers carry straight across.

What the operator accepts with this choice:

- **A user can only damage themselves.** Files, sessions and servers are owned
  per account; there is no cross-client shell access and no shared writable
  state between clients.
- **The runner stays root-owned and shared** (`/usr/local/bin/opencode`), so no
  client can modify the binary itself.
- **It is not memory-safe or network-proof.** A malicious session inside a
  client account could reach the machine's local network and other processes.
  The threat model is "client work is confidential from other clients", not
  "client work is hostile". If a client ever becomes hostile, move that account
  to its own ~$19/mo box.

## Browser testing: one shared browser, or a browser served over the tailnet from outside — **Made**

Not one browser per agent. Either the agents share the box's `headed-chromium`,
or browser testing happens through a browser service reachable over the
tailnet and hosted outside this box. Both keep per-client memory flat; one
browser per agent would not (each headed Chromium is ~530 MB + ~1 core on a busy
page).

## Phone approval loop — **Open**

Not started. Stays in `TASK.md`; the endpoints it needs are already enumerated
above (`/event` SSE + `/session/:id/permissions/:permissionID`), so it is an
integration task, not a design one.

## Build goal 2 before touching infrastructure — **Superseded**

Was justified as "narrowest goal, substrate already verified, produces the
measurements the other goals need". It has been overtaken: goal 4 is the primary
goal, and effort has repeatedly followed whatever was most concrete and
measurable rather than what mattered most. Ordering now comes from the priority
column in `SPEC.md`, not from tractability.

## Token spend probably dwarfs the VM — **Made** (as a rule for future decisions)

One measured session read 53k input / 9.2k output tokens with 1.39M cache reads in
four rounds. Once several agents run, inference cost likely exceeds any hosting
decision in this repo. Measure it before optimising a $19–130/mo VM any further.
