# Measurements

Evidence. Every number here was measured on the box, not estimated, and each one
exists because a decision in [`decisions/`](decisions/) rests on it.

Rules this file follows, because breaking them has cost real debugging time:

- A number without a date and a machine type is not evidence.
- A negative result from an ad-hoc probe is not evidence until the probe has the
  same `PATH` discipline as the committed checks (see "traps" below).
- Measure the *effect*, not the reported configuration.

Unless stated otherwise: **Hetzner CX33** (4 vCPU / 8 GB), `nbg1` Nuremberg, Debian 12,
`MemTotal` 7750 MB, August 2026. Earlier measurements are GCP `e2-standard-2`
(2 vCPU / 8 GB), `me-west1-a`, Debian 12, `MemTotal` 7950 MB.

Agent-layer measurements — what an opencode session or a language server costs,
how the box degrades under concurrency — moved with the agent layer to
`~/stuff/phone-approval/docs/measurements.md`.

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
— that the box had no swap at all. `verify-browser.sh` already documented
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

## Hetzner CX33 — the migration box

Measured 2026-08-05 on the live box (Hetzner Cloud, `nbg1`, Debian 12, CX33
4 vCPU / 8 GB, 80 GB NVMe + 20 GB Volume). Built with this repo's shared
startup template.

| What | Value |
|---|---|
| Cost, all-in | **≈ $11.55/mo** — CX33 $10.59 + 20 GB Volume ≈ $0.96. vs GCP `e2-standard-2` $60.25 |
| Tailscale RTT from workstation | **61–62 ms** (matches the 61.7 ms TCP pre-measure) |
| CPU | AMD EPYC-Rome, **4 physical threads** (GCP e2 "2 vCPU" = 2 hyperthreads on 1 core) |
| sysbench CPU 1-thread | 3488 events/s |
| sysbench CPU 4-thread | 14015 events/s — near-linear, i.e. real cores |
| sysbench memory (1K × 1 GB, 4 thr) | 4.47 GiB/s |
| boot → on tailnet | ~1 min from create (server created 18:10:28 UTC, `tailscale up` in the first cloud-init run) |
| Browser | identical stack to the GCP measurement: headed Chromium 151, Xvfb `:99`, llvmpipe WebGL |

`./run verify` passes 16/16 and survives a full reboot (fstab `LABEL=` mount,
`/var/lib/tailscale` bind-mount, and the tailnet node identity all persist — the
node keeps its IP across reboots).

### Traps the migration surfaced (each cost real debugging time)

- **`blkid -L` returns the DEVICE path, not the UUID.** `blkid -s UUID -o value -L <label>`
  is unreliable across util-linux versions; it yielded `/dev/sdb` and
  `mount UUID=/dev/sdb` failed — aborting phase A before the box reached the
  tailnet. Mount by `LABEL=<label>` (mount and fstab), which is also the stable
  handle across provider rebuilds.
- **`>` redirect preserves an existing file's mode.** A file once created 0711
  stays 0711 across rewrites. `chmod +x` can't fix a 0711 script (it needs
  read+exec for a non-owner). Fix in the template: `chmod 755` explicitly.
- **sshd keeps the FIRST value it sees.** cloud-init writes
  `50-cloud-init.conf` with `PasswordAuthentication yes`; a `99-` drop-in loses.
  The hardening drop-in must sort before cloud-init's: `10-agent-hardening.conf`.
- **`umask 077` in an `if` branch leaks into the main shell.** The one-off
  authkey write set umask 077 and every later file in phase A was created
  0600/0711. Scope it in a subshell; set `umask 022` at the top of the script.
- **A `grep -q /mnt/data` matches the `/mnt/data/tailscale` bind line**, so the
  data-disk fstab entry was silently skipped on re-runs. Anchor the match:
  `grep -qE "[[:space:]]/mnt/data[[:space:]]"`.
- **`agent-packages` double-triggers at boot** (enabled unit + `agent-startup`
  restarting it) → a transient `failed` that verify can catch. Only kick phase B
  when it is not already active.

## Latency from the workstation

| Target | RTT |
|---|---|
| GCP `me-west1` (current VM, direct) | **7 ms** |
| Hetzner Nuremberg | 61 ms |
| Hetzner Falkenstein | 71 ms |
| Hetzner Helsinki | 94 ms |

`tailscale ping` reports `via DERP(…)` on the first packet and then upgrades to
direct — read the **last** line, not the first.

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

The gap is a function of size:

- **at 2 GB** — `e2-small` vs CX23 → **$154/yr**. Not worth a migration.
- **at 16 GB** — `e2-standard-4` vs CX43 → **$1,353/yr**, and Hetzner gives 2× the
  vCPU plus NVMe instead of pd-standard. Worth it *if* a workload ever needs 16 GB.

Hosted CDP, for reference (Bright Data Scraping Browser): $8/GB pay-as-you-go,
$7/GB at $499/mo, $6/GB at $999/mo. An hourly feed poll with media blocked is
≈0.35 GB ≈ **$2.81/mo**; every 30 min ≈ $5.62/mo. Bandwidth is not the expensive
part — the host is.
