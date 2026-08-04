# SPEC

Intent, measurements and decisions. Actionable work lives in `TASK.md`;
`README.md` documents the machine as it currently exists.

Read this before picking the project back up — most of it exists to stop
settled questions being re-argued from memory.

---

## Goals

In the order they were stated. Only goal 1 exists.

| # | Goal | State |
|---|---|---|
| 1 | A reliable, reproducible cloud box reachable only over Tailscale, able to notify the phone | **Built. 31/31 verified.** |
| 2 | Track posts in the LinkedIn feed and notify the phone | Not started |
| 3 | Extend to Facebook + Instagram: notify about relevant comments and suggest replies | Not started |
| 4 | A coding box running multiple agents for multiple client companies, with agent-driven browser testing | **Not started, not specified** |

Goal 4 drives all infrastructure sizing and is the one with no concrete
definition. That is the project's central open question.

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
