# Decisions: infrastructure

The box, how it is reached, and how it is built. Evidence for anything numeric
here is in [`../measurements.md`](../measurements.md).

---

## Native VM, not a container — **Made**

A container on Container-Optimized OS layered on problems it did not solve:
read-only `/mnt`, a Tailscale sidecar fighting the app container, host/container
port-22 collisions, and Tailscale SSH hanging on a bare container. One machine,
one sshd path, one `tailscaled`. See [history.md](history.md).

## Debian 12 from Google's image family, not Arch — **Superseded**

`debian-cloud/debian-12` is rebuilt constantly, so first boot has nothing to
catch up on, and `unattended-upgrades` ships enabled. The workload (Chromium,
Tailscale) is distro-agnostic, so laptop parity bought nothing and a rolling
release cost babysitting. See [history.md](history.md).

**Superseded 2026-08-10** by the single-RHEL-family rule below: the Debian
template (`startup.debian.sh`) was removed and every provider now runs the one
dnf-based `startup.rhel.sh`. The load-bearing principle survived intact — the
workload is distro-agnostic — which is exactly why one family could replace two
distros. The GCP path is still on Debian as a reference; migrating it to Rocky
Linux 9 is an open task (see `TASK.md`).

## One RHEL-family startup template for every provider — **Made**

OCI boots its stock Oracle Linux 9 platform image; every other provider
(Hetzner today, GCP pending) boots **Rocky Linux 9**. Both are RHEL-derived, so
**one** dnf-based startup template — `startup.rhel.sh` — is the setup process
everywhere: after the per-provider step of picking the image, provisioning is
byte-for-byte identical. Only the base-image reference in each provider's
terraform differs.

The two template edits that made the OL9 script family-neutral:

- EPEL enable accepts either repo id (`epel` on Rocky, `ol9_developer_EPEL` on
  Oracle Linux).
- The OCI-only mirror `sed` and `ol9_oci_included`/`ol9_ksplice` repo-disables
  are guarded by `|| true` and match repos that do not exist on Rocky, so they
  are harmless no-ops there while still fixing OCI's flaky regional mirrors.

`startup.debian.sh` was removed; the GCP path's move from Debian to Rocky is an
open task. The live OCI box is untouched (unchanged image + `ignore_changes`),
so the template change applies on the next rebuild, not a migration.

## Oracle Linux 9 from OCI platform images, not a custom Arch image — **Made**

On OCI's free-tier A1 (arm64), the box boots **OCI's stock Oracle Linux 9
platform image** and provisions itself at first boot via `startup.rhel.sh`.
There is no custom image, no build/upload/import pipeline, no local QEMU boot
test.

The path before this: a locally built **Arch Linux ARM64 golden image**,
imported as an OCI custom image (UEFI_64 + A1.Flex shape compat). The bring-up
took many hours across dozens of 25–30 min cloud cycles and was still not
finished when stopped — see
[`../POSTMORTEM-oci-arm64-bringup.md`](../POSTMORTEM-oci-arm64-bringup.md).
The workload is distro-agnostic (same conclusion as "Debian 12, not Arch"
above), so the golden image bought nothing the platform image already offers.

The two real needs that pulled toward Arch are both met on stock Oracle Linux:

- **Latest nvim / cutting-edge tools** — the repo already installs neovim,
  direnv and mise from GitHub releases, not the distro. That pattern is
  distro-neutral and `startup.rhel.sh` implements it.
- **Chromium, not snap** — OCI A1 offers no platform image with real chromium
  in base repos (Ubuntu's is a snap). `startup.rhel.sh` installs **Flatpak
  Chromium** from Flathub: standard Chromium, current, aarch64, and
  `--socket=x11` reaches Xvfb. Flatpak works on any of the A1 images, so this
  is a wash across candidates.

Cost of the pivot: one stock platform image, zero image-pipeline machinery, and
a change to the startup template is applied by re-running `./run up` instead of
a 30-min build→upload→import→boot loop.

Corollary: `./run up` no longer builds/imports anything. The Arch golden-image
pipeline (build/upload/import scripts, `startup.arch.sh`, `startup.image.sh`,
`images/` build source) was removed in the same change; the built artifacts in
`images/output/` were kept on disk.

## Oracle Always Free idle guard (CPU floor) — **Made**

Oracle reclaims "idle" Always Free instances: if the **95th-percentile** CPU,
network **and** (A1 shapes only) memory utilization all stay **under 20%** over
a 7-day window, the instance is deemed idle and reclaimed. Because the verdict
is an **AND** of the three metrics, keeping any one of them above 20% protects
the box. Memory (the browser) and network already ride above the line in
practice, so a **CPU floor** is the reliable lever — measured before the guard
at a 7-day-permilled p95 of **~9%**, far under the reclaim line
(`../measurements.md`).

The floor is one **idle-priority spin loop** (`oci-idle-burn`, `nice 19` +
`CPUWeight=1`): it consumes only otherwise-idle capacity and is preempted the
moment real work wants the core. Steady-state it reads ~50% (one of two OCPUs),
p95 of the per-minute max **73%** vs the 20% floor with 3.5× margin.

Two design points:

- **Provider-neutral by self-detection, not a token.** The guard installs itself
  only where the image carries the Oracle Cloud Agent
  (`/usr/libexec/oracle-cloud-agent`). That directory exists on OCI platform
  images and nowhere else, so Hetzner/Rocky and GCP boots never see it and the
  shared `startup.rhel.sh` stays the single provider-neutral template. Same
  pattern as the data-disk `LABEL=` discovery. A non-Oracle box that somehow ran
  an Oracle-with-agent image would correctly get the guard, because the reclaim
  risk comes from being on Oracle's free tier and the agent's presence is its
  reliable signal.
- **Daily self-verification, not faith.** A dead burn unit would silently let
  the box fall back under the reclaim line. `oci-cpu-sampler` samples the box's
  own CPU once a minute (rolling window on `/mnt/data/idle-check/cpu.log`), and
  `oci-idle-check` runs daily (systemd timer, `Persistent=true`) recomputing the
  7-day p95 against the 20% floor into `/mnt/data/idle-check/daily.log`. A
  verdict is withheld until at least 1000 samples (~17h) exist, so sparse
  history is never read as SAFE. `verify.sh` asserts the guard and sampler run
  on Oracle boxes and are absent everywhere else.

## Tailscale-only access, dedicated VPC, IAP as break-glass — **Made (GCP path)**

*Describes the GCP design. The box now runs on Hetzner, whose equivalent is: an
empty-rule-set firewall (block inbound, allow outbound), with the web VNC
console + rescue system as break-glass — see "Provider migration" below.*

The VM has **no public inbound**. Access is Tailscale SSH over a tailnet
established outbound; the only firewall ingress is tcp:22 from Google's IAP
range (`35.235.240.0/20`) so `gcloud compute ssh --tunnel-through-iap` remains a
second, independent way in when Tailscale is the thing that is broken.

GCP's `default` network is not used, because its auto-created rules open tcp:22,
tcp:3389 and icmp to `0.0.0.0/0`.

Consequence worth stating: two independent escapes is a **feature of GCP**, and
the reason provider migration is not a cheap decision (see below).

## Separate persistent data disk at `/mnt/data` — **Made**

The VM and its root disk are disposable; the data disk is not. Repos, work
output and browser profiles live there, and
`/var/lib/tailscale` is **bind-mounted** (not symlinked) onto it so the node
identity survives instance replacement.

Not symlinked because the distro `tailscaled.service` sets
`StateDirectory=tailscale`, and systemd refuses to enter a symlinked state
directory (status 238).

## Two-phase boot — **Made**

Phase A does only what is needed to *reach* the box: mount the disk, install
Tailscale, create the user, `tailscale up`. Everything else — apt upgrade, CLI
tools, the browser stack — is `agent-packages.service`, started with
`systemctl restart --no-block`.

The reason is not tidiness: until `tailscale up` runs there is no inbound path
at all, so every second of foreground work is a second in which the VM cannot be
reached, cannot be debugged, and a bad auth key has not yet surfaced. Measured
274s → 84s (`../measurements.md`).

`restart`, not `start`: the unit is a oneshot with `RemainAfterExit=yes`, and
`start` on an `active (exited)` unit is a no-op — which silently broke the
self-healing this design claims.

## One-off auth keys minted per build, validated before apply — **Made**

`bootstrap.sh` mints a fresh single-use, pre-approved auth key per build from the
tailnet API into `terraform/tailscale.auto.tfvars`; `cleanup.sh` deletes the
stale node so the next build keeps the clean MagicDNS name. Nothing long-lived
lives in `config.env` except the API key itself.

`./run apply` validates the key against the API first, because a spent, expired
or revoked key is otherwise invisible until the VM has booted and silently failed
to join — at which point it is unreachable by design and the failure reads as a
hung build.

Corollary, learned the hard way: **never delete a tailnet node whose VM you
intend to keep.** `tailscaled`'s identity is on the data disk, so once the node
is gone server-side every netmap poll fails `404: node not found` and the box
cannot rejoin without a fresh key.

## Node.js from the vendor apt repo — **Superseded**

Debian bookworm ships Node 18, which is EOL. Node 24 once came from NodeSource as
an **apt source**, the same pattern phase A uses for Tailscale. Node provisioning
moved out with the agent layer to `~/stuff/phone-approval` (its
`scripts/provision-agent.sh`); this repo no longer installs Node.

## `config.env` as the single source of truth; no direnv — **Made**

All shared config is in `config.env`; every entry point calls `load_config`
(`scripts/lib.sh`), which wraps `source` in `set -a` so `TF_VAR_*` reach
Terraform.

An `.envrc` with `dotenv config.env` used to exist and actively caused a bug: it
exported `TF_VAR_*` into the interactive shell, so a `load_config` that
*silently failed* to export still appeared to work locally while breaking in any
other shell. It was also a second definition of config loading, and it exported
the tailnet-admin `TAILSCALE_API_KEY` into every process started from the
directory — agents included.

## zram compressed swap — kept — **Made**

3.9 GB zstd, active, and **0 B in use**, because a 530 MB browser on an 8 GB box
never reaches for swap. It earns nothing today and is kept for when a workload
pushes against the memory ceiling — exactly the case swap headroom exists for.

It was briefly removed on the false premise that it was not installed. That
premise came from a probe that lost `swapon` to a non-interactive `PATH` — see
"measurement traps" in `../measurements.md`.

The real historical complaint stands and is fixed: writing
`/etc/default/zramswap` *before* installing `zram-tools` triggered a dpkg
conffile prompt → exit 100 → an `iU` state that poisoned every later apt run,
including phase A before `tailscale up`. Phase B now writes that file after the
install and passes `--force-confold`.

## Stay on GCP for now — **Superseded**

Not on merit. GCP is poor value at these specs — measured all-in $60.25/mo
against roughly $10/mo for comparable Hetzner hardware — but:

- the sizing that would justify migrating is unmeasured — what runs on this box
  has not yet pushed it,
- ~20% of the repo is provider-specific and the risky 20% is concentrated in
  observability and break-glass (see `SPEC.md` → open questions),
- and the gap only becomes large at large sizes: at 2 GB it is ~$154/yr, at
  16 GB ~$1,353/yr.

Two arguments that used to appear here are void: "Hetzner IPs are blocked by bot
protection" (the box's own egress is what any app's traffic uses, on any
provider) and "Hetzner bills powered-off servers while a stopped
GCP instance bills disks only" (that only matters if something polls 24/7, and
nothing does).

**Superseded 2026-08-05** by the migration below — the repo now builds on Hetzner.

## Static external IP — **Reversed**

Reserved, then released. The premise was that the ephemeral IP changing on every
pause (measured `34.165.106.36` → `34.165.192.90`) would trip account-security
checks on a logged-in session belonging to an app on the box.

That premise does not survive contact with normal usage: devices roam between home
wifi, mobile data and café APs all day, so a changed IP cannot be weighted
heavily or the mobile apps would be unusable. The evidence was thin and came
largely from proxy vendors, who sell the remedy. Back to `access_config {}`.

Revisit only if an actual account challenge appears.

## Right-sizing the box — **Parked**

The box is `e2-standard-2` (2 vCPU / 8 GB) because of an abandoned plan, and a
headed browser peaks at ~530 MB — but measurement says the box is **CPU**-bound,
not RAM-bound. Do not resize until a workload on this box measures a real need;
when it does, buy cores.

`hardwareConcurrency: 2` is visible in the browser fingerprint and is only
fixable by paying for a bigger machine type. Accepted for now.

## Provider migration — **Made (Hetzner), then OCI (2026-08-10)**

The box moved from GCP `e2-standard-2` ($60.25/mo, me-west1) to Hetzner CX33
4 vCPU / 8 GB + 20 GB Volume ($10.59 + $0.96 ≈ **$11.55/mo**, nbg1, 61–62 ms
from the workstation). Evidence in `../measurements.md`.

On 2026-08-10 the active box moved again, to OCI's **Always Free A1** (2 OCPU /
12 GB, `il-jerusalem-1`, stock Oracle Linux 9) — see the "Oracle Linux 9 from
OCI platform images" decision above. The Hetzner path stays as the paid
fallback. The rest of this section is the record of the GCP → Hetzner move.

**IPv6 for a direct Tailscale path (2026-08-10):** the box got an
Oracle-allocated /56 GUA prefix (`is_ipv6enabled` on the VCN) and a public IPv6
on its VNIC, plus an internet gateway with a `::/0` route. This lets Tailscale
establish a **direct, non-DERP** connection from any IPv6-capable network (the
phone on 5G goes direct). Posture change: the security list's only ingress is
now **IPv4+IPv6 UDP 41641** (Tailscale/WireGuard) from `0.0.0.0/0` and `::/0`.
Verified by `verify.sh` (28 checks) and by
`tailscale ping` showing `direct [2a02:…]` to the phone vs DERP before.

**Direct IPv4 path — reserved public IPv4 (2026-08-12, final):** the box got a
**reserved public IPv4** (`oci_core_public_ip`, stable across rebuilds) as a
direct Tailscale endpoint, replacing the NAT gateway (IPv4 egress now flows
through the internet gateway sourcing the public IP). Measured on an office
network behind a **symmetric NAT**: without the public IP the tunnel was stuck
on DERP(par) at ~110 ms / ~1 Mbit/s; with it, `tailscale ping` goes **direct**
(RTT 5–9 ms) and `./run speedtest` measured **~460–500 Mbit/s up / 168 Mbit/s
down**. A public endpoint is what makes direct IPv4 possible at all from
symmetric-NAT networks — the NAT-return trick (no public IP, ride the NAT
gateway's outbound mapping) only worked from friendly cone-NAT networks like
home, not the office.

**Reserved vs ephemeral:** reserved is kept. The box is disposable and rebuilt
often, and an ephemeral IP would change every rebuild, forcing a DERP window
while peers re-learn the endpoint. Reserved is $0 on OCI, survives `tf destroy
-target=oci_core_instance.agent && ./run up`, and keeps the address's
reputation history entirely the box's own. Scanner exposure is identical for
both (both are Oracle-pool IPv4 reachable via the IGW); the difference is
stability and reputation ownership.

**Security posture (final):** no NAT gateway; a **reserved public IPv4 + a
public IPv6**; the security list's ONLY ingress is IPv4 UDP 41641 from
0.0.0.0/0 and IPv6 UDP 41641 from ::/0 (Tailscale/WireGuard). WireGuard does
not respond to unauthenticated handshakes, so the exposed port is
cryptographically silent; TCP 22 and everything else stay closed at the edge.
This is a modest, accepted tradeoff — a directly reachable UDP port that only
WireGuard keys can use — in exchange for full-speed direct connectivity from
any network. Oracle does not charge for public IPv4s, so cost was not a factor.


What unblocked it:

- **The break-glass premise was self-imposed, not a Hetzner limitation.** The
  old analysis said a Hetzner box that boots but fails `tailscale up` would be
  "unreachable and unobservable simultaneously… Hetzner would have zero"
  escapes. Partly true, partly not: the web VNC console login is unusable —
  `verify.sh` asserts the account password is locked and root login is off,
  which *does* shut the console tty. But Hetzner's **rescue system** boots a
  separate image with a key injected via the API, and that works regardless of
  the guest's sshd state. The box also re-runs phase A by itself: startup is a
  re-runnable systemd unit (`systemctl restart agent-startup`), so a reboot
  (from the console) re-applies the whole provisioning with the key on disk.
- **The startup script became provider-neutral.** One shared template
  (`scripts/templates/startup.sh`) serves every provider: the data disk is
  discovered by filesystem **label** (`LABEL=cloud-agent-data`), phase A is a
  systemd unit instead of a vendor metadata runner, and phase B stays deferred.
- **A `PROVIDER` shim in `scripts/lib.sh`** dispatches status/stop/start/firewall
  checks; `verify.sh`, `wait-ready.sh`, `rekey.sh`, `up.sh` and `cleanup.sh`
  branch on it. The GCP path remains for reference.
- **State backend is local** (terraform/hetzner/terraform.tfstate, git-ignored),
  not GCS: the GCP project was retired. Tradeoff accepted: a single always-on
  box that `./run up` can rebuild; revisit Hetzner Object Storage if the box
  ever needs shared state.

`./run verify` passes 16/16 and survives a reboot (fstab `LABEL=` mount,
`/var/lib/tailscale` bind-mount, tailnet identity all persist).
