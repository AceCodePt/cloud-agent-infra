# Measurements

Evidence. Every number here was measured on the box, not estimated, and each one
exists because a decision in [`decisions/`](decisions/) rests on it.

Rules this file follows, because breaking them has cost real debugging time:

- A number without a date and a machine type is not evidence.
- A negative result from an ad-hoc probe is not evidence until the probe has the
  same `PATH` discipline as the committed checks (see "traps" below).
- Measure the *effect*, not the reported configuration.

Unless stated otherwise: GCP `e2-standard-2` (2 vCPU / 8 GB), `me-west1-a`,
Debian 12, `MemTotal` 7950 MB, August 2026.

How to reproduce:

```sh
./run measure --seconds 120 --label "idle"   # PSS by user and kind, peaks
./run lsp-probe --cmd "tsgo --lsp --stdio" --root /mnt/data/repos/ts
./run verify                                 # 31 assertions about the end state
```

`scripts/drive-agent-loop.mjs` and `scripts/agent-stress.mjs` drive real opencode
sessions while `./run measure` samples. They are hand-driven over SSH, not wired
into `./run`.

---

## Boot time — why the boot is two phases

| | single phase | two phases |
|---|---|---|
| instance created → auth key consumed | **4m34s** (274s) | **1m24s** (84s) |
| of which GCE guest boot before the script runs | ~41s | ~41s |
| of which the startup script itself | ~233s | **43s** |

Chromium's codec dependencies are ~200 MB and have nothing to do with
reachability. The remaining 41s is GCE booting the guest, which this repo does not
control.

## Memory — headful Chromium, one tab

| Case | Peak PSS | `MemAvailable` drop |
|---|---|---|
| `about:blank` (stack floor) | 394 MB | 167 MB |
| Heavy news SPA, images ON | 527 MB | 243 MB |
| Heavy news SPA, images OFF | 523 MB | 249 MB |

9 processes. **Blocking images saves bandwidth, not RAM** (523 vs 527 MB) —
decoded bitmaps are transient, JS heap and DOM dominate. Two independent levers;
do not conflate them.

## zram

`/dev/zram0`, 3.9 GB, `zstd`, priority 100, `zram-tools 0.3.3.1-1.1`, `zramswap`
unit active — and **0 B in use**, because a 530 MB browser on an 8 GB box never
reaches for swap.

## Sizing: idle floor

| Scenario | Peak PSS | Peak 1-min load |
|---|---|---|
| True idle: no browser, no agents | 492 MB | 1.75 |
| One `opencode serve`, idle, no session | 800 MB | 0.96 |
| Two `opencode serve`, idle | 1020 MB | 0.38 |
| Headed browser parked on a busy feed | +1168 MB | **2.50** |

**First opencode server costs 308 MB; the second costs 221 MB** — the difference
is shared pages, which is why per-client isolation is much cheaper in memory than
it looks. `MemAvailable` agreed with the PSS accounting to within 11 MB of
1629 MB on the first run, which is why these numbers are trusted at all.

Note the last row: a browser sitting on a busy page, doing nothing anyone asked
for, costs 1168 MB and more than a full core continuously.

## Sizing: the language server dominates

`./run lsp-probe` drives a server over stdio (initialize, `didOpen` a batch of
real files, wait for quiet) and samples its whole process tree, since tsserver and
pyright both fork children. Corpus: `microsoft/TypeScript` (~600k LOC, `npm ci`
complete) at `/mnt/data/repos/ts` and `pydantic/pydantic` at `/mnt/data/repos/pyd`;
40 real source files, files under 2 KB skipped so barrel files cannot understate
the type-checking work.

| Language server | Peak PSS | Peak RSS | Procs | Diagnostics |
|---|---|---|---|---|
| `typescript-language-server` (**opencode's default**) | **1263 MB** | 1410 MB | 4 | 64 |
| `vtsls` | 1255 MB | 1402 MB | 4 | 22 |
| `tsgo` (`@typescript/native-preview`) | **200 MB** | 200 MB | 1 | 1 |
| `pyright-langserver` | 429 MB | 450 MB | 1 | 98 |

`vtsls` and `typescript-language-server` land within 1% of each other because both
are tsserver wearing different hats; choosing between them is a features decision,
not a memory one.

**The quiet window is load-bearing.** With `--quiet 8`, vtsls reported 869 MB;
with `--quiet 30` it reached 1255 MB. The early number was a 30% undercount
because the server had paused, not finished. 30s is the floor for a repo this
size.

Derived, against ~6.3 GB usable (MemTotal less the 492 MB idle floor and ~15%
headroom):

| Client profile | Per client | Fits in RAM |
|---|---|---|
| TypeScript on tsserver (default) | ~1480 MB | **~4** |
| TypeScript on tsgo, idle | ~420 MB | ~14 |
| TypeScript on tsgo, **active** | **~1000 MB** | ~6 |
| Python on pyright | ~650 MB | ~9 |

## A real agent, measured end to end

With a provider connected (opencode's free `big-pickle` model, so the measurement
cost nothing) and tsgo as the session LSP, an agent ran four rounds against
`microsoft/TypeScript`, reading `src/compiler/checker.ts` (54k lines) and
`src/compiler/binder.ts` and enumerating their AST type-check functions. Real work
happened: 53k input tokens, 9.2k output, 7.8k reasoning, 1.39M cache reads;
`GET /lsp` showed `{"id":"tsgo","status":"connected"}`; the `fs.read` snapshot hash
moved every round.

| Kind | Peak PSS |
|---|---|
| opencode | 687 MB |
| lsp (tsgo) | 242–333 MB |
| node (driver) | 56 MB |
| **one working client, total** | **~1000 MB** |

Peak 1-minute load hit **3.60 on 2 vCPU** while the agent was mid-run and stayed
above 1.0 for a sustained stretch. `MemAvailable` cross-check agreed within
~140 MB.

So: a *working* client costs ~1000 MB, not 420 MB, and it is **CPU-bound**. RAM
fits ~6 clients; the CPU saturates at roughly two actively-working agents. Model
choice barely moves memory — the cost is tool subprocesses and LSP indexing, not
the token stream.

**Caveat:** these are short bursts of a few minutes. A session running for an hour
accumulates context and touches more of the repo, so the LSP peak may grow.
Re-measure with a real client workload and a longer run before committing to a
concurrency number.

## Does the box halt, or just slow down?

The question that actually decides sizing. `agent-stress.mjs` drives K concurrent
canaries — each a bounded "read `checker.ts`, list functions" task on its own
session — while a sampler watches MemAvailable / swap / load; then dmesg is
grepped for OOM and every process checked alive. A canary that completes proves
the whole stack worked; a box that is merely slow completes, late.

**One shared server, K concurrent sessions** (what one server absorbs):

| K | completion | peak PSS | min MemAvailable | peak swap | max load |
|---|---|---|---|---|---|
| 2 | 4/4 (100%) | 1972 MB | 5546 MB | 35 MB | 3.28 |
| 4 | 8/8 (100%) | 1980 MB | 5515 MB | 35 MB | 4.82 |
| 6 | 12/12 (100%) | 2212 MB | 5283 MB | 35 MB | 7.02 |
| 8 | 16/16 (100%) | 2020 MB | 2528 MB | 118 MB | 9.27 |
| 12 | 24/24 (100%) | 2421 MB | 5101 MB | 99 MB | 7.16 |
| 16 | 32/32 (100%) | 2371 MB | 5128 MB | 98 MB | 9.33 |
| 24 | 48/48 (100%) | 2274 MB | 5265 MB | 121 MB | 10.95 |

Not one OOM kill, not one dead process, not one failed round, all the way to 24
concurrent agents on 2 vCPU. Memory stays nearly flat because every session on
the same repo shares the same tsgo LSP client — the box just gets slower. The
single K=8 dip (2528 MB) was a transient (several LSPs spawning at once), not a
trend; K=12 and above returned to ~5100 MB free.

**The realistic per-client case — one server each** (`box-multi-stress.sh`,
matching the isolation design where every client is its own opencode + LSP):

| K servers | completion | peak PSS | min MemAvailable | peak swap | max load |
|---|---|---|---|---|---|
| 3 | 6/6 (100%) | 2952 MB | 4594 MB | 120 MB | 8.14 |

**Answer: the box does not halt, it degrades gracefully.** It ran out of CPU
around K=4 (load above 2 vCPU) but kept completing at 100% up to K=24, with
MemAvailable never below ~2.5 GB and swap never above ~120 MB (zram absorbs it).
The failure mode is "work gets slower", never "work stops". The only real halt
threat is OOM, and it was not approached at these sizes: ~1000 MB per working
client against 8 GB leaves a wide margin, with zram as a further compressed
buffer.

What would change the answer: a much larger repo (LSP peak grows with indexing),
multiple distinct repos (no shared LSP — the multi-server run showed the real
per-client memory), or agents running long builds. The rule stands: re-run the
ramp when a new client type arrives.

## Fingerprint

CreepJS, measured: headful Chromium under Xvfb with `xauth` scores **0%/44%** —
identical to real headed Chrome on a desktop. Headless scores 67%/50%. That is
the reason the box runs a headed browser on a virtual display at all.

One defect found here was a property of the **box**, always sent and verifiable
by any site, and therefore outranking the IP question earlier sessions spent so
long on:

**WebGL did not exist.** `getContext('webgl')` → `null`, log line
`ContextResult::kFatalFailure: WebGL1 blocklisted`. Chrome 136+ refuses software
WebGL unless told otherwise and this box has no GPU. Three options, measured:

| Config | `UNMASKED_RENDERER_WEBGL` | Verdict |
|---|---|---|
| as shipped | *(no context at all)* | rare, obviously broken |
| `--enable-unsafe-swiftshader` | `ANGLE (Google, Vulkan 1.3.0 (SwiftShader Device (Subzero)…), SwiftShader driver)` | works, but "SwiftShader" is headless Chrome's calling card |
| `--ignore-gpu-blocklist --use-gl=angle --use-angle=gl` + `LIBGL_ALWAYS_SOFTWARE=1` | `ANGLE (Mesa/X.org, llvmpipe (LLVM 15.0.6 256 bits), OpenGL 4.5)` | **chosen** — what a real Linux desktop with no GPU driver reports |

`--ignore-gpu-blocklist` is the flag that actually lifts the ban; the backend
flags alone still measured `null`. llvmpipe also reports `MAX_TEXTURE_SIZE` 16384
against SwiftShader's 8192, and WebGL2 works. Both the flags and
`libgl1-mesa-dri` are in `headed-chromium` and phase B for this reason.

Other environment facts, readable by any page's client-side telemetry:

- `document.hasFocus()` → `false` while `visibilityState` → `visible`
- no `_NET_SUPPORTING_WM_CHECK` (no window manager, deliberately)
- window size: Chromium with no WM opened at `945x917 +10,+10` on a 1920×1080
  framebuffer; `headed-chromium` now pins `--window-size` to the display
  (`BROWSER_WINDOW_SIZE`)
- H.264 `probably`, AAC `probably`; UA `Chrome/151.0.0.0`
- Chromium `151.0.7922.71` (Debian bookworm)
- `hardwareConcurrency` 2, where a real desktop is usually 4–16 — only fixable by
  paying for a bigger machine type

**Anything tied to a specific account is not measured here.** A second defect —
the box's UTC clock being wrong for a browser claiming a particular identity, and
what a persistent profile's session cookie is worth — is a property of the app
that owns the account, and lives with it in
[`AceCodePt/linkedin-reader`](https://github.com/AceCodePt/linkedin-reader).

## Measurement traps worth remembering

**Non-interactive SSH has a minimal `PATH`.** `swapon` and `zramctl` live in
`/usr/sbin`, so `ssh host swapon --show` returns "command not found". An ad-hoc
probe swallowed that into `|| echo "(none)"` and this repo concluded — in writing
— that the box had no swap at all. `verify-browser.sh:42` already documented
the trap and exported the right `PATH`; the one-off probe did not.

**`/proc/<pid>/environ` lies about Chromium.** It showed `TZ` unset on a browser
demonstrably running with `TZ` set, because Chromium rewrites that memory region
for process naming. Measure the effect (`Intl.DateTimeFormat()` over CDP on a
throwaway profile), never the reported environment.

**`pgrep -f` / `pkill -f` match the shell that runs them,** because the pattern is
in that shell's own command line. As `pgrep` this produced two false positives; as
`pkill` it killed the shell mid-command, so a browser launch silently never
happened and left no log to explain it. Always bracket the first character:
`[u]ser-data-dir=…`.

**The last line of a startup script may never reach the serial console.** With
`exec > >(tee …)`, bash does not wait for `tee` to flush into the metadata
runner's pipe before exiting, so the final line lands on disk but can be dropped
from the journal. `wait-ready.sh` polled for exactly that marker, so a healthy
84-second boot presented as a 10-minute timeout.

## Latency from the workstation

| Target | RTT |
|---|---|
| GCP `me-west1` (current VM, direct) | **7 ms** |
| Hetzner Nuremberg | 61 ms |
| Hetzner Falkenstein | 71 ms |
| Hetzner Helsinki | 94 ms |

`tailscale ping` reports `via DERP(…)` on the first packet and then upgrades to
direct — read the **last** line, not the first.

+54 ms is perceptible for keystroke-level editing over SSH (`mosh` hides it) and
irrelevant for an agent-driven workflow of prompts and output.

## Cost

Current box, all-in: **$60.25/mo** — compute $53.80, external IP $3.65, disks
$2.80.

Comparison in $/mo all-in. GCP includes the external IP and disks; Hetzner
includes the $0.60 IPv4 and 20 TB traffic at post-15-June-2026 prices (CX/CAX rose
30–40%, CPX/CCX more than doubled, so older comparisons are void).

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

Hosted CDP, for reference (Bright Data Scraping Browser): $8/GB pay-as-you-go,
$7/GB at $499/mo, $6/GB at $999/mo. An hourly feed poll with media blocked is
≈0.35 GB ≈ **$2.81/mo**; every 30 min ≈ $5.62/mo. Bandwidth is not the expensive
part — the host is.
