# SPEC

Intent, measurements and decisions. Actionable work lives in `TASK.md`;
`README.md` documents the machine as it currently exists.

Read this before picking the project back up — most of it exists to stop
settled questions being re-argued from memory.

---

## Goals

Numbered in the order they were first stated, which is NOT their priority. The
priority column is what matters.

| # | Goal | Priority | State |
|---|---|---|---|
| 4 | Agentic workflows for client companies: multiple agents, isolated per client, with agent-driven browser testing | **PRIMARY — the reason the machine exists** | **Not started, not specified** |
| 1 | A reliable, reproducible cloud box reachable only over Tailscale, able to notify the phone | Substrate for the above | **Built. 31/31 verified.** |
| 2 | Track posts in the LinkedIn feed and notify the phone | Secondary | Logged in + session verified; feed reading not built |
| 3 | Extend to Facebook + Instagram: relevant comments, suggest replies | Secondary | Not started |

**The primary goal has nothing built and no design.** The box has no `opencode`,
no `claude`, no container runtime, no `gh`, and no client checkouts; `/mnt/data`
holds only the browser profiles, the Tailscale state and the phone key.

Goals 2 and 3 are, by comparison, well advanced — which is an inversion worth
naming. Effort followed whatever was concrete and measurable (fingerprints have
crisp right answers) rather than what mattered most, and this table previously
listed goals in stated-order with no priority column, which made that easy to do.
Sizing is downstream of goal 4 and cannot be settled until goal 4 is defined:
2 vCPU / 8 GB is already visible in the fingerprint as `hardwareConcurrency: 2`,
and several concurrent agents plus browsers will not fit it.

---

## Goal 4 (primary): what the pieces actually are

Researched, not yet built. Recorded so it is not re-researched.

**The runner is opencode**, and its architecture already fits: `opencode` is a
server with clients attached, not a monolithic TUI.

- `opencode serve --port N --hostname H` — headless HTTP server, OpenAPI 3.1
  spec at `/doc`. Default `127.0.0.1:4096`.
- `opencode web` — **a full browser UI already exists**: session list, active
  sessions, server status. So the phone "app" does not have to be written from
  scratch to get status and replies; Chrome on Android plus Add to Home Screen
  covers a lot of it.
- `opencode attach http://host:port` — attach a terminal TUI to the *same*
  server, sharing sessions and state. So phone and laptop can drive one session.
- Auth: `OPENCODE_SERVER_PASSWORD` (+ optional `OPENCODE_SERVER_USERNAME`,
  default `opencode`) gives HTTP basic auth. Unset means unsecured.

The endpoints that map directly onto what the phone needs:

| Need | Endpoint |
|---|---|
| "give me their status" | `GET /session/status`, `GET /session/:id/todo`, `GET /project` |
| "let me answer them" | `POST /session/:id/message`, `/prompt_async` (fire-and-forget) |
| **approve/deny an agent's request** | `POST /session/:id/permissions/:permissionID` |
| push, rather than polling | `GET /event` and `/global/event` (SSE) |
| stop a runaway agent | `POST /session/:id/abort` |

`/event` as an SSE stream plus the existing `notify-phone` path is the whole
notification story: nothing new has to be invented to get an alert on the phone
when an agent needs a decision.

**Phone (measured, not assumed):** `SM-S928B`, Android 16, `aarch64`, already a
tailnet node. Termux has `node`, `python`, `termux-notification` and
`termux-tts-speak`. TTS on the phone matters for the assistant-replacement goal.
`termux-notification` supports action buttons, so an approve/deny prompt can be
answered from the notification shade without opening anything.

**Install shape:** opencode is a single ~180 MB binary, installed by the vendor
script to `~/.opencode/bin/opencode`, not from a package manager. Workstation is
on `1.18.11`; the box should be pinned to the same version, not floating.

**Provider credentials:** owner will connect providers by hand through the TUI.
Not a blocker to design around.

---

## Sizing: how it is measured

An earlier draft of this file asserted that 2 vCPU / 8 GB "will not hold several
agents". That was an opinion wearing the clothes of a fact. `./run measure`
(`scripts/measure-resources.py`) replaces it: it samples `/proc`, attributes
memory by user and by kind, and reports peaks.

**It reports PSS, not RSS, and that is the entire point.** One Unix user per
client means several copies of the same 180 MB opencode binary, the same libc
and the same chromium. RSS charges every shared page in full to every process
that maps it, so sizing from RSS overestimates in exactly the direction that
costs money. PSS divides shared pages among their sharers, so the numbers may be
added up. `MemAvailable` is sampled alongside as an accounting-independent
cross-check — and it agreed to within 11 MB of 1629 MB on the first run, which is
why the numbers below are trusted at all.

### Measured, 2 vCPU / 8 GB

| Scenario | Peak PSS | Peak 1-min load |
|---|---|---|
| True idle: no browser, no agents | 492 MB | 1.75 |
| One `opencode serve`, idle, no session | 800 MB | 0.96 |
| Two `opencode serve`, idle | 1020 MB | 0.38 |
| Social browser parked on the LinkedIn feed | +1168 MB | **2.50** |

**First opencode server costs 308 MB; the second costs 221 MB.** The difference
is shared pages, and it is why per-client isolation is much cheaper in memory
than it looks. Extrapolating idle servers only, ~26 would fit in RAM.

### What this changes

**RAM is not the constraint. CPU is.** The earlier claim was wrong, and wrong in
its reasoning, not just its number. At 221 MB marginal per client, memory runs
out long after 2 vCPU does — a single browser sitting on the LinkedIn feed, doing
nothing anyone asked for, drove the 1-minute load average to 2.50 on a 2-core
box. Any resize should therefore buy cores, not gigabytes.

**Second finding, for the secondary goal:** the social browser parked on the feed
costs 1168 MB and more than a full core, continuously. It should not be left
sitting on `/feed/` between reads — park it on `about:blank`, or stop it and let
`./run login --verify` confirm the session from the cookie jar without a browser
running at all.

### The language server is the per-client cost

The figures above are an idle floor. The dominant real cost is the **LSP**, and
it does not need a connected provider to measure: indexing costs the same
whether a human or an agent caused the file to be opened. `./run lsp-probe`
(`scripts/lsp-probe.mjs`) drives a server directly over stdio — initialize,
`didOpen` a batch of real files, wait for it to go quiet — and samples the
server's whole process tree, since tsserver and pyright both fork children.

Corpus: `microsoft/TypeScript` (~600k LOC, `npm ci` complete) at
`/mnt/data/repos/ts`, and `pydantic/pydantic` at `/mnt/data/repos/pyd`. 40 real
source files opened, files under 2 KB skipped so barrel files cannot understate
the type-checking work.

| Language server | Peak PSS | Peak RSS | Procs | Diagnostics |
|---|---|---|---|---|
| `typescript-language-server` (**opencode's default**) | **1263 MB** | 1410 MB | 4 | 64 |
| `vtsls` | 1255 MB | 1402 MB | 4 | 22 |
| `tsgo` (`@typescript/native-preview`) | **200 MB** | 200 MB | 1 | 1 |
| `pyright-langserver` | 429 MB | 450 MB | 1 | 98 |

`vtsls` and `typescript-language-server` land within 1% of each other because
both are tsserver wearing different hats. Choosing between them is a features
decision, not a memory one.

**Measure to settle, not to a timer.** A first run with an 8-second quiet window
reported vtsls at 869 MB. Given 30 seconds of quiet it reached 1255 MB — the
early number was a 30% undercount, because the server had merely paused, not
finished. `--quiet 30` is the floor for a repo of this size.

### What this means for sizing

Per client = 221 MB marginal opencode + its LSP. Against ~6.3 GB usable
(MemTotal less the 492 MB idle box and ~15% headroom):

| Client profile | Per client | Fits in RAM |
|---|---|---|
| TypeScript on tsserver (default) | ~1480 MB | **~4** |
| TypeScript on tsgo | ~420 MB | ~14 |
| Python on pyright | ~650 MB | ~9 |

**Switching TypeScript clients from tsserver to tsgo is worth more than tripling
the box's RAM**, and costs nothing but a config block. With tsserver, four
TypeScript clients exhaust an 8 GB box; with tsgo, RAM stops being the binding
constraint at all and 2 vCPU binds first — consistent with the load figures
above.

**The caveat that keeps this honest:** tsgo emitted 1 diagnostic where tsserver
emitted 64. Some of that 6× gap is efficiency (it is a native Go port of the
compiler) and some is work it did not do — it is a preview with incomplete
feature coverage. Treat 200 MB as a lower bound, and re-measure per client repo
with `./run lsp-probe` rather than assuming it holds.

### opencode does not ship vtsls or tsgo

Confirmed by reading the binary's LSP registry: the built-in servers are
`typescript`, `pyright`, `ty`, `eslint`, `gopls`, `rust`, `vue`, `svelte`,
`zig`, `ruby`, `elixir`, `csharp`, `java`, `clangd`. TypeScript means
`typescript-language-server`, which is the most expensive option measured, and
it only spawns if `typescript/lib/tsserver.js` resolves from the project — so a
client repo without typescript installed silently gets no TS LSP at all.
`pyright` is auto-downloaded when absent unless `disableLspDownload` is set.
`ty` (Astral's) exists but is gated behind `experimentalLspTy`, and enabling it
deletes pyright.

Both `vtsls` and `tsgo` work as custom servers. Verified accepted by the running
server via `GET /config`:

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

Per-client isolation makes this a per-client decision: each client's own
`opencode.json` picks its LSP, so a client on a small repo can afford tsserver
while a large one is moved to tsgo.

### Driving real agent work needs a provider

Tool execution cannot be triggered over the API without a model:
`/experimental/tool` only *lists* tools and requires `provider` and `model`
query parameters. LSPs spawn lazily when a session's read/edit tool touches a
file, so `GET /lsp` returns `[]` on a server nobody has prompted. Once a
provider is connected, `POST /session/:id/message` drives an agent that runs
tools for real, and `./run measure` alongside it captures the full picture —
model streaming, tool subprocesses, builds and LSP together. That is the one
remaining measurement, and it is the only one that needs credentials.

---

## What is built

Verified by `./run verify` (31 checks); has survived a full `cleanup --yes` +
rebuild cycle.

- GCP `e2-standard-2` (2 vCPU / 8 GB), `me-west1-a`, Debian 12
- Dedicated VPC, **zero public ingress**; Tailscale-only access, with
  `gcloud compute ssh --tunnel-through-iap` as break-glass
- Tailscale one-off auth keys minted via API and validated before every apply
  (`scripts/tailscale-api.sh`)
- Tailscale state bind-mounted onto the data disk — survives instance
  replacement, but not data-disk destruction
- Phone notifications end to end: `notify-phone` → Termux, restricted
  forced-command key, atomic re-key with rollback
- Two-phase boot (`terraform/startup.tf`): phase A reaches the tailnet, phase B
  installs the browser stack out of band. **Measured 274s → 84s.**
- Headful Chromium + Xvfb, CDP on `127.0.0.1:9333`
- `./run up` — idempotent convergence, never destructive
- Terraform state in GCS, bucket lifecycle in `scripts/bootstrap.sh`

Cost: **$60.25/mo** — compute $53.80, external IP $3.65, disks $2.80.

---

## Measured facts

### Memory — headful Chromium, one tab, on the VM

| Case | Peak PSS | MemAvailable drop |
|---|---|---|
| `about:blank` (stack floor) | 394 MB | 167 MB |
| Heavy news SPA, images ON | 527 MB | 243 MB |
| Heavy news SPA, images OFF | 523 MB | 249 MB |

9 processes. `MemTotal` 7950 MB.

**Blocking images saves bandwidth, not RAM** (523 vs 527 MB) — decoded bitmaps
are transient; JS heap and DOM dominate. Two independent levers; do not conflate.

Openbox not installed, and not wanted (see Decisions).

**zram IS active**: `/dev/zram0`, 3.9 GB, `zstd`, priority 100, `zram-tools
0.3.3.1-1.1` installed, `zramswap` unit active — and **0 B in use**, because a
530 MB browser on an 8 GB box never reaches for swap.

An earlier revision of this file claimed the box had no swap at all. That was a
measurement error, and the mechanism is worth remembering: `swapon` and `zramctl`
live in `/usr/sbin`, which is **not** on the `PATH` of a non-interactive SSH
command. The probe got "command not found", swallowed it into `|| echo "(none)"`,
and reported absence. `verify-browser.sh:79-81` already documents this exact trap
and exports the right `PATH`; the ad-hoc probe did not. Lesson: a negative result
from a one-off SSH probe needs the same `PATH` discipline as the committed checks,
or it is not evidence.

### Fingerprint defects found after the first real login, and fixed

Both of these were found by measuring the browser the account is actually logged
into, and both outrank the IP question that earlier sessions spent so long on:
they are properties of the browser, always sent, and verifiable by the site.

**1. Timezone said UTC.** Not inferred — LinkedIn read the clock and stored
`timezone=UTC` in a cookie, against an account whose entire history is Israeli.
A server should be UTC; a browser claiming to be this person should not.

Fixed with `TZ` in the `social-chromium` wrapper only, so system logs stay UTC.
Confirmed end to end: `Intl.DateTimeFormat().resolvedOptions().timeZone` →
`Asia/Jerusalem`, `getTimezoneOffset()` → `-180`, and LinkedIn rewrote its own
cookie to `timezone=Asia/Jerusalem` on the next page load.

**2. WebGL did not exist.** `getContext('webgl')` returned `null`; the log said
`ContextResult::kFatalFailure: WebGL1 blocklisted`. Chrome 136+ refuses software
WebGL unless told otherwise, and this box has no GPU. Essentially every real
Chrome has WebGL, so its absence is a far louder signal than a datacenter IP.

Three options, measured rather than assumed:

| Config | `UNMASKED_RENDERER_WEBGL` | Verdict |
|---|---|---|
| as shipped | *(no context at all)* | rare, obviously broken |
| `--enable-unsafe-swiftshader` | `ANGLE (Google, Vulkan 1.3.0 (SwiftShader Device (Subzero)...), SwiftShader driver)` | works, but "SwiftShader" is headless Chrome's historical calling card |
| `--ignore-gpu-blocklist --use-gl=angle --use-angle=gl` + `LIBGL_ALWAYS_SOFTWARE=1` | `ANGLE (Mesa/X.org, llvmpipe (LLVM 15.0.6 256 bits), OpenGL 4.5)` | **chosen** — what a real Linux desktop with no GPU driver reports |

`--ignore-gpu-blocklist` is the flag that actually lifts the ban; the backend
flags alone still measured `null`. llvmpipe also reports `MAX_TEXTURE_SIZE`
16384 against SwiftShader's 8192, and WebGL2 works too. `libgl1-mesa-dri`
(which provides `swrast_dri.so`) is now an explicit package rather than a
transitive dependency of chromium, because a fingerprint now depends on it.

**Still imperfect, accepted for now:** `hardwareConcurrency` is 2, where a real
desktop is usually 4–16. Fixable only by paying for a bigger machine type.

### Two measurement traps worth remembering

**`/proc/<pid>/environ` lies about Chromium.** It showed `TZ` unset on a browser
that was demonstrably running with `TZ` set. Chromium rewrites that memory region
for process naming. Measure the *effect* (`Intl.DateTimeFormat()` over CDP on a
throwaway profile), never the reported environment.

**`pgrep -f` / `pkill -f` match the shell that runs them,** because the pattern is
in that shell's own command line. As `pgrep` this produced two false positives; as
`pkill` it killed the shell mid-command, so a browser launch silently never
happened and left no log to explain it. Always bracket the first character:
`[u]ser-data-dir=...`.

### Browser environment defects

- `document.hasFocus()` → `False` while `visibilityState` → `visible`
- Window `945x917` at `+10,+10` on a `1920x1080` display
- No `_NET_SUPPORTING_WM_CHECK` (no window manager running)
- H.264 `probably`, AAC `probably`; UA `Chrome/151.0.0.0`
- Chromium `151.0.7922.71` (Debian bookworm)

Readable by client-side telemetry on any page. Only matters once a persistent
authenticated session exists — hence Openbox is scheduled with phase 1, not now.

### Latency from the workstation

| Target | RTT |
|---|---|
| GCP `me-west1` (current VM, direct) | **7 ms** |
| Hetzner Nuremberg | 61 ms |
| Hetzner Falkenstein | 71 ms |
| Hetzner Helsinki | 94 ms |

Gotcha: `tailscale ping` reports `via DERP(...)` on the first packet and then
upgrades to direct. Read the **last** line, not the first.

+54 ms is perceptible for keystroke-level editing over SSH; `mosh` hides it, and
it is irrelevant for an agent-driven workflow where you issue prompts and read
output.

### Cost comparison

All-in $/mo. GCP includes the $3.65 external IP and disks. Hetzner includes the
$0.60 IPv4 and 20 TB traffic, at post-15-June-2026 prices (CX/CAX rose 30–40%,
CPX/CCX more than doubled — older comparisons are void).

| Option | $/mo | $/yr |
|---|---|---|
| GCP `e2-standard-2` 2/8 — **current** | 60.25 | 723 |
| GCP `e2-small` 2/2 | 19.88 | 239 |
| GCP `e2-medium` 2/4 | 33.35 | 400 |
| GCP `e2-standard-4` 4/16 + 200 GB | 131.84 | 1582 |
| Hetzner CX23 2/4/40 NVMe | 7.09 | 85 |
| Hetzner CX33 4/8/80 NVMe | 10.59 | 127 |
| Hetzner CX43 8/16/160 NVMe | 19.09 | 229 |

The gap is a function of size, and size is a function of goal 4:

- **at 2 GB** — `e2-small` vs CX23 → **$154/yr**. Not worth a migration.
- **at 16 GB** — `e2-standard-4` vs CX43 → **$1,353/yr**, and Hetzner gives 2× the
  vCPU plus NVMe instead of pd-standard. Worth it, *if* 16 GB turns out real.

Two facts that flipped earlier reasoning and no longer apply:

- "Hetzner IPs are blocked by bot protection" — **moot**: social egress goes via
  the home router, so the provider's IP is never seen.
- "Hetzner bills powered-off servers; GCP stopped = disks only" — **moot**:
  continuous polling means 24/7 uptime either way.

### Hosted CDP (Bright Data Scraping Browser)

$8/GB pay-as-you-go; $7/GB at $499/mo; $6/GB at $999/mo. Hourly feed poll with
media blocked ≈ 0.35 GB ≈ **$2.81/mo**; every 30 min ≈ $5.62/mo.

Bandwidth is not the expensive part. The host is.

---

## Decisions

### Made

- **Stay on GCP for now.** Not on merit — GCP is poor value at these specs — but
  on switching cost, and because the sizing that would justify migrating is
  unmeasured.
- **Run the browser locally, not hosted.** A hosted CDP service runs the browser
  in vendor infrastructure, so the LinkedIn session cookie would live there.
  That cookie is full account access and bypasses 2FA. Renting only the egress
  IP keeps it on hardware we control, for roughly $7/mo more. Bright Data's
  durable advantage is maintained anti-detection patches; its residential pool
  is actively unhelpful here (see Risks).
- **Social egress over the home connection**, via Tailscale exit node on the
  router — genuinely the IP the account logs in from. Implement as `tailscaled`
  in userspace-networking mode (which exposes SOCKS5) plus `--proxy-server=` on
  the social browser only, *not* a device-wide exit node.
- **Block media via CDP**, not `--blink-settings=imagesEnabled=false` — same
  bandwidth saving, keeps the fingerprint normal.
- **Separate test browsers from social browsers.** Test: ephemeral, headless, no
  proxy, hitting our own apps. Social: headful, persistent profile, home IP.
- **Build goal 2 before touching infrastructure.** Narrowest goal, substrate
  already verified, and it produces the measurements goals 3 and 4 need.

### Closed

- **zram — kept.** It works (3.9 GB zstd, active) and currently earns nothing,
  because nothing on an 8 GB box swaps. Kept anyway for the multi-agent workload,
  where several browsers and toolchains at once is precisely the case swap
  headroom exists for. It was briefly removed on the false premise that it was
  not even installed; see the `PATH` error under Measured facts.
  The real historical complaint stands and is fixed: writing
  `/etc/default/zramswap` in phase A triggered a dpkg conffile prompt → exit 100
  → an `iU` state that poisoned every later apt, including phase A before
  `tailscale up`. Phase B now writes that file *after* the install and passes
  `--force-confold`.
- **Static external IP — tried, reverted.** Reserved, then released. The premise
  was that the ephemeral IP changing on every pause (measured
  `34.165.106.36` → `34.165.192.90`) would trip account-security checks on a
  logged-in session. That premise does not survive contact with normal usage:
  phones roam between home wifi, mobile data and café APs all day, so a changed
  IP cannot be weighted heavily or the mobile apps would be unusable. The
  evidence behind the claim was thin and largely came from proxy vendors, who
  sell the remedy. Back to `access_config {}`.
- **Thorium — no.** Measurement killed the case: Debian's Chromium already
  reports H.264/AAC `probably` and a normal Chrome UA. An unofficial GitHub
  `.deb` means no apt security updates on the most attack-exposed program on the
  box, and rarity *increases* fingerprint entropy.

### Parked

- **Openbox — yes, with phase 1.** ~10 MB, and it fixes a *measured* defect
  rather than a theoretical one. Pointless until a persistent session exists.
- **Right-sizing.** The box is 8 GB because of an abandoned plan and peaks at
  530 MB — but goal 4 may need *more*, not less. Do not resize until specified.
- **Provider migration.** Blocked on goal 4 and on break-glass.
- **Goal 3 (Meta).** Larger blast radius than LinkedIn; separate decision.

---

## Open questions

**1. What is goal 4, concretely?** Concurrent agent count; whether each client
needs an isolated workspace; whether browser testing means one browser or one per
agent. Determines RAM, which determines whether the provider gap is $154/yr or
$1,353/yr. All infrastructure work waits on this.

**2. Break-glass on Hetzner, if we migrate.** GCP's IAP tunnel is the only
non-Tailscale way into a box with zero public ingress. Hetzner has no equivalent,
and our own hardening closes the alternatives — `verify.sh:209-211` asserts the
account password is locked and root login is off, which shuts the VNC console.
Combined with the loss of the serial console, a Hetzner box that boots but fails
`tailscale up` would be **unreachable and unobservable simultaneously**. GCP has
two independent escapes; Hetzner would have zero. This is the honest counterweight
to the $1,353/yr. Decide before writing any Terraform.

**3. Client data residency.** Confirmed unrestricted, so a German VPS is allowed.
Re-check if a client contract says otherwise. Note that at ~$19/mo per box,
one-server-per-client becomes affordable isolation that GCP pricing forecloses.

**4. Token spend will likely dwarf the VM.** Once several coding agents run,
inference cost probably exceeds any hosting decision here. Measure it before
optimising a $19–130/mo VM any further.

---

## Risks

### LinkedIn (goal 2)

- **The feed requires authentication.** No official API exposes the member home
  feed, and the User Agreement prohibits automated access. *hiQ v. LinkedIn*
  concerned **public** data accessed **without** logging in and does not cover
  this. Realistic downside is account restriction — losing the network and
  history — not litigation.
- **Rotating IPs are actively harmful.** Residential proxy pools are built for
  anonymous public scraping; varying the IP of an authenticated session triggers
  account-security checks. One sticky IP consistent with Israel is wanted, which
  is what the home-router decision provides.
- **Silent breakage is the likely failure mode**, not a dramatic ban: a layout
  change that parses zero posts looks identical to a quiet feed. Zero parsed
  posts must alert.

### Meta (goal 3)

Facebook and Instagram are linked through Accounts Center, so enforcement can
cascade across both. Meta is also more aggressive about automation than LinkedIn.

### Migration (goal 4, conditional)

A full survey found **~80% of the repo is provider-agnostic** — all of
`tailscale-api.sh` and `verify-browser.sh`, 24 of 27 `verify.sh` checks, and most
of `startup.tf`'s guest logic including the two-phase design. The danger is
concentrated in the other 20%:

- **No `google_metadata_script_runner` equivalent.** `./run rekey` loses its
  mechanism and every re-key becomes a full reboot. Better fix: phase A installs
  itself as `/usr/local/sbin/agent-startup` + a systemd unit, so "re-run startup"
  is `systemctl restart` over SSH. This is an improvement on the status quo.
- **No programmatic serial console.** `wait-ready.sh` and `provision-phone.sh`
  lose their no-SSH observability channel — the fallback requires SSH, which
  requires the tailnet, which is the thing being waited on. Replace with an
  outbound status beacon from phase A, which also eliminates the console-flush
  bug class that already cost one debugging session.
- **Data-disk device path.** `startup.tf:76` hardcodes
  `/dev/disk/by-id/google-data`. Hetzner's path embeds a volume ID unknowable
  until the volume exists, and templating it creates a Terraform dependency
  cycle. Discover in-guest by label: if the path is wrong, `mkfs.ext4 -F` runs
  against it.
- **Status vocabulary.** `instance_status()` returns `RUNNING`/`TERMINATED`;
  Hetzner's is lowercase and differently named (`running`/`off`). A missed rename
  falls through to a catch-all that waits 10 minutes on a box that is off.
- **cloud-init `user_data` runs once by default**, unlike GCE's every-boot
  metadata script — which the current design relies on for self-healing.
- **State backend.** Hetzner has no first-class object store, and two thirds of
  `bootstrap.sh` exists solely to solve the GCS chicken-and-egg.

### Process

This project has drifted before: a session that began with a revoked Tailscale
key ended up planning a provider migration, via zram, Thorium, Openbox and hosted
CDP, while goals 2–4 stayed at zero lines. Three recommendations were reversed
inside twenty minutes because each was made against a locally-scoped question
rather than a stated goal. Hence `TASK.md`'s ordering rule.
