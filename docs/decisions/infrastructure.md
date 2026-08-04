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
catch up on, and `unattended-upgrades` ships enabled. The workload (agents,
Chromium, Tailscale) is distro-agnostic, so laptop parity bought nothing and a
rolling release cost babysitting. See [history.md](history.md).

## Tailscale-only access, dedicated VPC, IAP as break-glass — **Made**

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
output, browser profiles and the notify keypair live there, and
`/var/lib/tailscale` is **bind-mounted** (not symlinked) onto it so the node
identity survives instance replacement.

Not symlinked because the distro `tailscaled.service` sets
`StateDirectory=tailscale`, and systemd refuses to enter a symlinked state
directory (status 238).

## Two-phase boot — **Made**

Phase A does only what is needed to *reach* the box: mount the disk, install
Tailscale, create the user, `tailscale up`. Everything else — apt upgrade, CLI
tools, the browser stack, Node, opencode — is `agent-packages.service`, started
with `systemctl restart --no-block`.

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

## Node.js from the vendor apt repo — **Made**

Debian bookworm ships Node 18, which is EOL. Node 24 comes from NodeSource as an
**apt source**, the same pattern phase A uses for Tailscale, so it keeps getting
security updates — unlike a curl-pipe-to-shell binary drop that apt knows
nothing about.

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
never reaches for swap. It earns nothing today and is kept for the multi-agent
workload, which is exactly the case swap headroom exists for.

It was briefly removed on the false premise that it was not installed. That
premise came from a probe that lost `swapon` to a non-interactive `PATH` — see
"measurement traps" in `../measurements.md`.

The real historical complaint stands and is fixed: writing
`/etc/default/zramswap` *before* installing `zram-tools` triggered a dpkg
conffile prompt → exit 100 → an `iU` state that poisoned every later apt run,
including phase A before `tailscale up`. Phase B now writes that file after the
install and passes `--force-confold`.

## Stay on GCP for now — **Made**

Not on merit. GCP is poor value at these specs — measured all-in $60.25/mo
against roughly $10/mo for comparable Hetzner hardware — but:

- the sizing that would justify migrating is downstream of goal 4 and unmeasured,
- ~20% of the repo is provider-specific and the risky 20% is concentrated in
  observability and break-glass (see `SPEC.md` → open questions),
- and the gap only becomes large at large sizes: at 2 GB it is ~$154/yr, at
  16 GB ~$1,353/yr.

Two arguments that used to appear here are void: "Hetzner IPs are blocked by bot
protection" (the box's own egress is what any app's traffic uses, on any
provider) and "Hetzner bills powered-off servers while a stopped
GCP instance bills disks only" (that only matters if something polls 24/7, and
nothing does).

## Static external IP — **Reversed**

Reserved, then released. The premise was that the ephemeral IP changing on every
pause (measured `34.165.106.36` → `34.165.192.90`) would trip account-security
checks on a logged-in session belonging to an app on the box.

That premise does not survive contact with normal usage: phones roam between home
wifi, mobile data and café APs all day, so a changed IP cannot be weighted
heavily or the mobile apps would be unusable. The evidence was thin and came
largely from proxy vendors, who sell the remedy. Back to `access_config {}`.

Revisit only if an actual account challenge appears.

## Right-sizing the box — **Parked**

The box is `e2-standard-2` (2 vCPU / 8 GB) because of an abandoned plan, and a
headed browser peaks at ~530 MB — but measurement says the box is **CPU**-bound,
not RAM-bound, and goal 4 may need more of both. Do not resize until goal 4 is
specified; when it is, buy cores.

`hardwareConcurrency: 2` is visible in the browser fingerprint and is only
fixable by paying for a bigger machine type. Accepted for now.

## Provider migration — **Parked**

Blocked on two things: goal 4's real sizing (see
[agents-and-sizing.md](agents-and-sizing.md)), and break-glass.

**Break-glass is the honest counterweight to the $1,353/yr.** GCP's IAP tunnel is
the only non-Tailscale way into a box with zero public ingress. Hetzner has no
equivalent, and our own hardening closes the alternatives — `verify.sh:209-211`
asserts the account password is locked and root login is off, which shuts the VNC
console. Combined with the loss of a programmatic serial console, a Hetzner box
that boots but fails `tailscale up` would be **unreachable and unobservable
simultaneously**. GCP has two independent escapes; Hetzner would have zero. Decide
this before writing any Terraform.

A full survey found **~80% of the repo is provider-agnostic** — all of
`tailscale-api.sh` and `verify-browser.sh`, 24 of 27 `verify.sh` checks, and most
of `startup.tf`'s guest logic including the two-phase design. The danger is
concentrated in the other 20%, recorded here so the survey is not redone:

- **No `google_metadata_script_runner` equivalent.** `./run rekey` loses its
  mechanism and every re-key becomes a full reboot. Better fix: phase A installs
  itself as `/usr/local/sbin/agent-startup` plus a systemd unit, so "re-run
  startup" is `systemctl restart` over SSH. That is an improvement on the status
  quo.
- **No programmatic serial console.** `wait-ready.sh` and `provision-phone.sh`
  lose their no-SSH observability channel, and the fallback requires SSH, which
  requires the tailnet, which is the thing being waited on. Replace with an
  outbound status beacon from phase A, which also eliminates the console-flush bug
  class that already cost one debugging session.
- **Data-disk device path.** `startup.tf` hardcodes
  `/dev/disk/by-id/google-data`. Hetzner's path embeds a volume ID unknowable
  until the volume exists, and templating it creates a Terraform dependency
  cycle. Discover in-guest by label — if the path is wrong, `mkfs.ext4 -F` runs
  against it.
- **Status vocabulary.** `instance_status()` returns `RUNNING`/`TERMINATED`;
  Hetzner's is lowercase and differently named (`running`/`off`). A missed rename
  falls through to a catch-all that waits 10 minutes on a box that is off.
- **cloud-init `user_data` runs once by default**, unlike GCE's every-boot
  metadata script, which the current self-healing design relies on.
- **State backend.** Hetzner has no first-class object store, and two thirds of
  `bootstrap.sh` exists solely to solve the GCS chicken-and-egg.
