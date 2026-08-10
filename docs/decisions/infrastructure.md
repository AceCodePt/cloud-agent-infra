# Decisions: infrastructure

The box, how it is reached, and how it is built. Evidence for anything numeric
here is in [`../measurements.md`](../measurements.md).

---

## Native VM, not a container — **Made**

A container on Container-Optimized OS layered on problems it did not solve:
read-only `/mnt`, a Tailscale sidecar fighting the app container, host/container
port-22 collisions, and Tailscale SSH hanging on a bare container. One machine,
one sshd path, one `tailscaled`. See [history.md](history.md).

## Debian 12 from Google's image family, not Arch — **Made**

`debian-cloud/debian-12` is rebuilt constantly, so first boot has nothing to
catch up on, and `unattended-upgrades` ships enabled. The workload (Chromium,
Tailscale) is distro-agnostic, so laptop parity bought nothing and a rolling
release cost babysitting. See [history.md](history.md).

## Oracle Linux 9 from OCI platform images, not a custom Arch image — **Made**

On OCI's free-tier A1 (arm64), the box boots **OCI's stock Oracle Linux 9
platform image** and provisions itself at first boot via `startup.ol.sh`. There
is no custom image, no build/upload/import pipeline, no local QEMU boot test.

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
  distro-neutral and `startup.ol.sh` implements it.
- **Chromium, not snap** — OCI A1 offers no platform image with real chromium
  in base repos (Ubuntu's is a snap). `startup.ol.sh` installs **Flatpak
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

## Provider migration — **Made (Hetzner)**

The box moved from GCP `e2-standard-2` ($60.25/mo, me-west1) to Hetzner CX33
4 vCPU / 8 GB + 20 GB Volume ($10.59 + $0.96 ≈ **$11.55/mo**, nbg1, 61–62 ms
from the workstation). Evidence in `../measurements.md`.

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
