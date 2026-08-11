# Operating manual

How to drive the machine day to day. This is the detail behind the map in
[`capabilities.md`](capabilities.md); **why** things are the way they are lives
in [`decisions/`](decisions/README.md), and the numbers in
[`measurements.md`](measurements.md). `README.md` is just the front door.

---

## Configuration: single source of truth

All shared config lives in **`config.env`** at the repo root. Terraform reads
`TF_VAR_*` environment variables natively; the shell scripts source the same
file. One place to edit.

```sh
cp example.config.env config.env
```

```sh
# config.env  (git-ignored — contains secrets)
PROVIDER="oci"                     # oci (active) | hetzner | gcp
TF_VAR_instance_name="cloud-agent"   # also the tailnet hostname
TF_VAR_ssh_user="youruser"           # your Unix user on the box
TF_VAR_machine_type="VM.Standard.A1.Flex"  # OCI Ampere A1 (Always Free eligible)
TF_VAR_ocpus="2"                     # free tier: up to 4
TF_VAR_memory_in_gbs="12"            # free tier: up to 24

# OCI (Oracle Cloud Infrastructure). Home region il-jerusalem-1 holds the
# Always Free capacity. Credentials for the `oci` CLI + Terraform.
OCI_TENANCY_OCID="ocid1.tenancy.oc1..."
OCI_USER_OCID="ocid1.user.oc1..."
OCI_FINGERPRINT="xx:xx:..."
OCI_PRIVATE_KEY_PATH="~/.oci/oci_api_key.pem"
TF_VAR_region="il-jerusalem-1"

# Hetzner (reference path — set PROVIDER=hetzner and these take effect)
HETZNER_API_KEY="your-hetzner-api-token"
TF_VAR_location="nbg1"
TF_VAR_data_disk_size_gb="20"

# GCP (unused while PROVIDER=oci; kept for switching back)
TF_VAR_project_id="your-project-id"
TF_VAR_region="me-west1"
TF_VAR_zone="me-west1-a"

# Tailnet admin key. bootstrap.sh mints a single-use auth key per build from it.
TAILSCALE_API_KEY="tskey-api-..."
```

`TF_VAR_data_disk_size_gb` is optional — omit it to use the default (50 GB on
OCI, 20 GB on Hetzner).

> **Do not** also set `TF_VAR_tailscale_auth_key`. Terraform ranks
> `terraform/tailscale.auto.tfvars` (written by `mint`) above `TF_VAR_*` env vars,
> so a key here is ignored on every normal build and then silently takes effect —
> as a long-spent key — if that file ever goes missing. Set one or the other.

> **`TF_VAR_ssh_public_key` is optional and GCP-path-only** — it authorizes
> your own key for sshd so you can connect through a raw IAP tunnel. On OCI
> your key is injected via instance metadata (`ssh_authorized_keys`); on
> Hetzner there is no IAP and no key is needed. Leave it unset.

No `export` prefixes, nothing to source or activate. Every entry point calls
`load_config` (`scripts/lib.sh`), which wraps the source in `set -a` so `TF_VAR_*`
reach Terraform. `./run` works in a completely bare shell:

```sh
env -i HOME="$HOME" PATH="$PATH" ./run plan   # No changes.
```

For testing, point `load_config` at a different file without touching the real one:
`CONFIG_ENV=/path/to/config.env ./run plan`.

**Why no direnv:** an `.envrc` with `dotenv config.env` used to live here and
actively caused a bug, and it leaked the tailnet-admin `TAILSCALE_API_KEY` into
every process started from this directory — agents included. Config loading has
exactly one definition. Full reasoning:
[`decisions/infrastructure.md`](decisions/infrastructure.md).

---

## Prerequisites

- An OCI tenancy (Always Free eligible) with the API key pair uploaded — set
  `OCI_TENANCY_OCID`, `OCI_USER_OCID`, `OCI_FINGERPRINT`,
  `OCI_PRIVATE_KEY_PATH` in `config.env`, plus a Tailscale **API key** (admin
  console → Settings → Keys) to mint the one-off auth key per build.
- `terraform` and the `oci` CLI installed locally. (The `PROVIDER=hetzner` path
  needs a Hetzner API token instead; `PROVIDER=gcp` needs `gcloud` and
  application-default credentials — see `example.config.env`.)
- The Terraform provider (`oracle/oci` etc.) is downloaded once into
  `~/.terraform.d/plugin-cache` (`TF_PLUGIN_CACHE_DIR`, set in `lib.sh`) and
  reused from there, so `cleanup`/`rebuild` never re-download it.

---

## The one command

```sh
./run up
```

`up` is a **convergence** command, not a build script: every step first asks what
is already true and does nothing if the answer is "already correct". It ends by
running `verify.sh`, so it can't lie about the result. **Non-destructive by
contract** — it never destroys the server, data volume, or a tailnet node. It
cannot cost you your browser logins or the work on `/mnt/data`.

The steps `up` encodes, in order, doing only what is missing:

| # | Converges | Acts only if |
|---|-----------|--------------|
| 1 | Terraform state backend | `terraform/<provider>/` is not `terraform init`-ed |
| 2 | Tailscale auth key | the current key is unusable (spent, revoked, missing) |
| 3 | Infrastructure | `terraform apply` — always; it is itself a converge |
| 4 | Guest has consumed the key | the box is not online in the tailnet |
| 5 | Local `known_hosts` | a stale entry from a previous box is blocking SSH |
| 6 | Proof | `verify.sh`, non-zero exit on any drift |

Step 4 is why `up` exists — `apply` alone cannot re-key a running box (below).

### Rebuilding from scratch

`./run rebuild` is the destructive sibling: `cleanup → bootstrap → apply → wait →
verify`. It **destroys the server, the data volume and the tailnet node** — a new
node identity and loss of everything on `/mnt/data`. Reach for it only when you
mean exactly that; `up` is what you want the other 99% of the time.

```sh
./scripts/cleanup.sh          # tear down + delete the tailnet node
./scripts/bootstrap.sh        # terraform init + mint a one-off auth key
./run apply                   # server created; reachable ~1 min later
./scripts/wait-ready.sh       # block until on the tailnet AND startup script done
./scripts/verify.sh           # assert the entire end state, non-zero on any drift
```

### The boot is two phases, and the split is the point

**Phase A (foreground, ~1 min)** does only what is needed to *reach* the box:
mount the data volume (by `LABEL=cloud-agent-data`), install Tailscale, create
your user, `tailscale up`. The single-use auth key is spent at the end of
phase A.

**Phase B (background, ~5–10 min on A1)** is everything else, in waves: EPEL,
CLI tools (git, gh, stow, tmux, fzf, …), the GitHub-release builds of
neovim/direnv/mise (go, rust, node via mise), a `dnf --allowerasing upgrade`,
and the headed-browser stack (Flatpak Chromium, Xvfb, xauth, x11vnc, zram,
dnf-automatic). It runs as `agent-packages.service`, launched with
`systemctl restart --no-block` by `agent-startup.service` (the systemd unit
phase A installs), so phase A returns immediately. The default shell for the
interactive account phase A created is `zsh`.

Measured on OCI, not guessed: ~3–4 min from instance created → on the tailnet
(the GCP box measured `274s → 84s` for the same milestone).

```sh
./run ssh journalctl -u agent-packages -f   # watch phase B
./run ssh systemctl is-active agent-packages # activating | active | failed
./run wait --packages                        # block until phase B finishes
./run verify-browser                         # assert the browser stack alone
```

Phase B is an enabled oneshot unit, so it re-runs on every boot and is a no-op
when the packages are current — self-healing a failed install. Because the box is
deliberately declared ready before phase B finishes, `verify.sh` reports the
browser checks as **SKIP** while `agent-packages` is `activating`. That is not
drift.

### `apply` cannot re-key a running box

The auth key is baked into the boot provisioning (cloud-init `user_data`) and is
not re-read after boot. Minting a key and re-applying does nothing for a running
box. Use:

```sh
./run rekey            # mint + deliver the key over the tailnet + re-run phase A
./run rekey --reboot   # same, but stop/start the box instead
```

`rekey` writes the fresh key to `/etc/agent/authkey` over SSH and runs
`systemctl restart agent-startup` — phase A is a re-runnable systemd unit, not a
one-shot metadata script. This only works while the box is reachable over the
tailnet. If the box is **off** the tailnet, there is no network way in (zero
public ingress): use the OCI serial console (Cloud Shell) to fix
`/etc/agent/authkey`, then reboot. The startup script only spends a key when the
node is not already a member.

### A dead key fails the apply, not the boot

A spent, expired, or **revoked** key is otherwise invisible until the VM has
booted and silently failed to join — unreachable by design, looking like a hung
build. `./run apply` validates the key against the Tailscale API first
(`./run check-key` runs it standalone). One-off keys are marked revoked the
moment they are *consumed*, so an invalid key is only fatal when the node still
needs it; a spent key on an already-joined node is expected and only warns.

> Revoking a key in the admin console *after* minting it produces exactly this,
> and the Tailscale audit log shows it. Let the tooling manage its own keys.

---

## The browser: one wrapper, on a virtual display

The box runs a **real browser** — many sites block `HeadlessChrome`, so Chromium
runs *headed* on a virtual display: **Xvfb** provides a 1920×1080 screen
(`DISPLAY :99`, pre-set in every login shell and tmux) and Chromium renders into
it like a normal browser. No desktop or window manager.

There is exactly one wrapper, `headed-chromium`:

| | `headed-chromium` |
|---|---|
| For | driving apps in a real, unheadlessable browser |
| CDP | yes, `CDP_PORT` (default 9222) |
| Profile | `BROWSER_PROFILE_DIR`, default `/mnt/data/browser/default` |

```sh
headed-chromium https://example.com                     # test browser
BROWSER_PROFILE_DIR=/mnt/data/browser/agent2 CDP_PORT=9223 headed-chromium
./run browser                                           # hand-drive it over VNC
./run browser --stop                                    # stop it (SIGTERM, flushes cookies)
```

- Playwright: `chromium.launch(headless=False, executable_path="/usr/bin/chromium")`,
  or attach: `chromium.connect_over_cdp("http://localhost:9222")`.
- Profiles live on the data disk, so anything logged in survives a rebuild.
- Each headed Chromium costs ~530 MB (measured); a browser sitting on a busy page
  also costs about a full core, so park it on `about:blank` or stop it.
- Give each app or identity its own `BROWSER_PROFILE_DIR` and `CDP_PORT` — one
  profile shared between identities means one cookie jar and one fingerprint for
  both.

**An app with a logged-in account brings its own wrapper.** This repo knows
nothing about accounts: no timezone pinned to someone's history, no extension
loading, no CDP refusal. That belongs to whichever app owns the session — e.g.
[`linkedin-reader`](https://github.com/AceCodePt/linkedin-reader) deploys its own
`social-chromium`. Reasoning: [`decisions/browser.md`](decisions/browser.md).

### Reaching the display by hand: `./run browser`

`./run browser [url]` does the whole thing: starts `x11vnc` on the box (loopback
only), launches `headed-chromium` on `:99`, opens an SSH tunnel
`localhost:5900 → box:5900`, and opens your local VNC client. You drive whatever
is in the browser by hand, including a one-time login; on exit the tunnel closes
and `x11vnc` stops. x11vnc runs with `-nopw` (no password) — safe only because it
is bound to loopback and the SSH tunnel is the only path to it.

```sh
./run browser                       # needs a VNC client locally, e.g. tigervnc
./run browser https://example.com   # open a specific page
VNC_LOCAL_PORT=5901 ./run browser   # if 5900 is taken
BROWSER_PROFILE_DIR=/mnt/data/browser/agent2 ./run browser   # a different profile
BROWSER_WINDOW_SIZE=1440,900 ./run browser   # size it to your screen
```

`BROWSER_CMD` swaps the wrapper, so an app that deployed its own can be driven
through the same tunnel (`BROWSER_CMD=social-chromium ./run browser`).

---

## Teardown

**Full wipe by default** — destroys the server + data volume, deletes local
Terraform state, and removes local artifacts:

```sh
./run cleanup                # FULL wipe (compute + local state + files + tailnet node)
./run cleanup --yes          # same, skip confirmation prompts
./scripts/cleanup.sh --keep-files    # keep local .terraform / tfstate
```
(The GCP path additionally manages a GCS state bucket; `--keep-bucket` applies
there.)

> **`cleanup` is not "reset".** Answering `y` to all three prompts deletes the
> data volume — everything under `/mnt/data` and the tailnet node identity — plus
> the local state, which is the only record of what exists.
> There is no undo. If your goal is "make it work again", that is `./run up`; if
> it is "throw the server away but keep my data", that is:
>
> ```sh
> ./run tf destroy -target=oci_core_instance.agent && ./run up
> ```

---

## Security: no public inbound (IPv4); one IPv6 Tailscale port

The instance has **no public IPv4** (the VNIC is created with
`assign_public_ip = false`); IPv4 stays behind a NAT gateway with an empty
ingress rule set. The **only** public ingress in the security list is
**IPv6 UDP 41641** — Tailscale's WireGuard listener — which lets the box take a
direct (non-DERP) Tailscale path from any IPv6-capable network. WireGuard does
not respond to unauthenticated handshakes, so nothing else is exposed; the
firewalld on the box opens the same single port. `verify.sh` asserts all of
this: no public IPv4, and the security list's only ingress rule is IPv6
UDP 41641 from `::/0`.

There is **no other public inbound** — you reach the box over the Tailscale
tailnet, established outbound. Your user has **passwordless sudo**, acceptable
because the only way in is your tailnet identity, enforced off-box
(`useradd` creates the account password-locked, and sshd has
`PasswordAuthentication no` + `PermitRootLogin no`, so no password would ever
match). SSH is never opened publicly — the security list keeps TCP 22 closed.

Break-glass when Tailscale is the thing that is broken: the OCI **serial console**
via Cloud Shell. The tty login is unusable by design — the account password
is locked and root login is off — so a live fix goes through the serial console
or a reboot of a repaired boot volume.

(Reference paths: Hetzner uses an empty-rule-set firewall + web VNC console +
rescue system; GCP uses IAP as a second way in.)

---

## Persistence model

- **Disposable:** the VM and its root disk. Rebuild freely.
- **Persistent:** the separate data disk at `/mnt/data` — repos, work output,
  anything you can't lose. Tailscale state is bind-mounted here
  (`/var/lib/tailscale` → `/mnt/data/tailscale`), so a rebuild keeps the node
  identity (no re-auth) as long as the data disk survives. Browser profiles
  (`/mnt/data/browser/`) live here too — logins survive.
- A full `cleanup.sh` deletes the data disk too. Use `--keep-*` flags or snapshot
  the disk first.

---

## Measuring the box

The numbers behind the sizing and browser decisions — boot time, browser memory,
zram, fingerprint, latency, cost — are measured, not guessed, and live in
[`measurements.md`](measurements.md).

To see how fast the link between this machine and the box actually is, right now:

```sh
./run speedtest
```

runs iperf3 both ways over the tailnet (`iperf3 -s` on the box via
`systemd-run`, client locally), against the box's Tailscale IPv4, and prints
upload (local → box) and download (box → local) in Mbit/s. `IPERF3_DURATION`,
`IPERF3_PARALLEL`, and `IPERF3_PORT` override the defaults (5 s, 4 streams,
5201). iperf3 must be installed on both ends.

---

## Gotchas (learned the hard way)

- **GCP's `default` network is wide open** (tcp:22, 3389, icmp from `0.0.0.0/0`).
  On the GCP path, use the dedicated VPC in `terraform/gcp/network.tf`, or delete
  those rules. OCI blocks inbound via a security list with no ingress rules.
- **Deleting `default-allow-ssh` makes plain `gcloud compute ssh` hang** — it has
  no route in. Use `--tunnel-through-iap`, or rely on Tailscale. (GCP path only.)
- **Tailscale SSH ACL rules are first-match-wins.** A broad `action: check` rule
  listed before your `action: accept` rule shadows it — the accept never runs and
  you get a browser prompt every time. Order specific `accept` rules first.
- **`tailscale up` won't silently drop a flag.** To change settings toward
  defaults, use `--reset`.
- **`terraform apply` cannot deliver a new auth key to a running VM.** Use
  `./run rekey`.
- **Don't revoke an auth key in the admin console mid-build.** A revoked key gets
  baked into the VM, `tailscale up` fails, and the box is unreachable by design.
  The symptom is a 5-minute `wait-ready` timeout that reads like an
  infrastructure fault. `./run apply` validates the key first.
- **Terraform's variable precedence puts `*.auto.tfvars` above `TF_VAR_*` env
  vars.** Set `TF_VAR_tailscale_auth_key` OR the auto-tfvars key, never both.
- **Use `findmnt`, not `ls`,** to verify a mount — an empty dir and a mounted dir
  look identical.
- **`blkid` before `mkfs`.** Don't reformat a disk that already has a filesystem
  (the startup script guards this).
- **Don't symlink `/var/lib/tailscale`.** The distro `tailscaled.service` sets
  `StateDirectory=tailscale`, and systemd refuses a symlinked state dir
  (status 238). Bind-mount instead.
- **Billing must be enabled** or `gcloud services enable` fails before Terraform
  runs.
- **Key injection on first boot can lag** on a fresh VM; give it a minute.
- **In an HCL heredoc, `$$` is an escape only before `{`.** `$${VAR}` yields
  `${VAR}`, but `$$VAR` renders as two literal dollars, which bash expands to the
  **PID**. The startup now lives in plain files
  (`scripts/templates/startup.rhel.sh`, read via `file()`),
  so this whole class is gone from new providers; the GCP path's
  `terraform/gcp/compute.tf` `lifecycle precondition` still fails the apply if
  any `$$` survives the render.
- **`ssh host cmd arg1 arg2` joins argv with spaces and the remote shell
  re-parses it.** Quoting is not preserved. Escape each argument with
  `printf %q` when the remote command carries user text.
- **`ssh` eats stdin.** Piping a script to `bash -s` over ssh and then calling
  `ssh` inside it makes the inner ssh consume the rest of the script. Use `ssh -n`
  or `</dev/null`.
- **Non-interactive ssh has a minimal `PATH`.** `swapon`/`zramctl` live in
  `/usr/sbin`; `ssh host swapon --show` fails with "command not found". Export the
  full PATH when probing.
- **`DEBIAN_FRONTEND=noninteractive` does NOT stop dpkg conffile prompts.** It
  governs debconf. Pass `-o Dpkg::Options::=--force-confold`.
- **A conffile conflict poisons the box permanently.** The failed package is left
  half-configured (`iU`), so every later `apt-get install` fails identically —
  before `tailscale up` — making the box unreachable *and* unable to re-key itself.
  Repair with `dpkg --configure --force-confold -a`.
- **Never pre-create a file a package owns as a conffile.** Writing
  `/etc/default/zramswap` before installing `zram-tools` caused both bugs above.
- **The last line of a startup script may never reach a serial console.**
  Milestones go through `logger` (synchronous, journal) and a sentinel file at
  `/run/agent-startup-complete` checked over SSH.
- **gcloud `--filter` can be pushed SERVER-side and rejected.** `verify.sh` lists
  plainly and matches client-side. (GCP path.)
- **gcloud and Terraform authenticate SEPARATELY.** Terraform uses
  application-default credentials; the `gcloud` CLI uses its own active account.
  `gcloud auth list` / `gcloud config list` are the diagnosis. (GCP path.)
- **Don't let a failed API call read as a passing check.** A security check that
  cannot run must FAIL, never pass.
- **Anything slow in the foreground of phase A is time the box is
  unreachable.** Keep phase A minimal; defer the rest to `agent-packages.service`.
- **`cleanup` is a wipe, not a reset.** To fix a broken box use `./run up`; to
  replace just the box, `tf destroy -target=oci_core_instance.agent`.
- **Never delete the local Terraform state while resources exist.** It is the
  only pointer to live infrastructure; `cleanup.sh` verifies the server and
  volume are really gone before wiping it. (On the GCP path, the same applies to
  the state bucket.)
- **Measurement harness traps**: `pkill -f` patterns must be anchored or they
  match the killer's own command line and kill the shell running it; every `curl`
  health check needs `--connect-timeout --max-time` or a half-open server hangs
  the whole run; the sampler prints peaks on SIGTERM so a short workload doesn't
  lose its numbers; detached processes must redirect all three fds or ssh waits
  on the channel.
- **`./run browser` failing with `Can't open display` is a LOCAL problem, not the
  box.** A tmp cleaner can delete XWayland's socket from `/tmp/.X11-unix` while
  the Xwayland process keeps running: the socket stays bound in the kernel (still
  visible in `ss -xl`) but nothing can reach it, so every X11 client dies —
  `xset q` fails too, which is how to tell it apart in one command. Retrying
  never helps; either log out and back in to restart XWayland, or use a
  Wayland-native VNC client (`remmina`) so XWayland is not in the path at all.
  `browser.sh` now preflights this instead of starting a tunnel it has to tear
  down.
- **SSH is `accept-new`, not "ask".** A rebuilt VM always presents a new host key;
  under BatchMode the default just refuses unknown hosts. `accept-new` takes an
  unknown host silently but refuses a *changed* key — so a leftover `known_hosts`
  entry from a previous build reads as a VM fault. `up` and `verify` clear it for
  you (`ssh-keygen -R cloud-agent`).
- **Tailscale SSH check mode demands a one-time browser approval.** The first
  SSH from a device can hit an "additional check" prompt, and the connection can
  stall (banner never answers) instead of failing fast — so every repo SSH call
  is bounded with a timeout. `./run up` prints the approval URL and **waits up to
  `WAIT_APPROVAL_TIMEOUT` (default 30 min)** for you to click it, then continues
  in the same run. `./run ssh` skips BatchMode so the prompt works interactively.
- **x11vnc exits 2 on SIGTERM**, so a plain `systemctl stop` leaves the unit
  "Failed (exit-code)" forever — a real-looking fault on a box whose correct state
  is "stopped, login finished". `SuccessExitStatus=2` fixes new boxes and
  `reset-failed` clears the bogus entry; `browser.sh` does both.
- **A backgrounded process over ssh dies with the session** unless it gets
  `setsid` + `nohup` + closed stdin + `disown` — all four, or the process is a
  child of the ssh session. `browser.sh` uses all four.
- **`instance_status` distinguishes "absent" from "unknown".** "unknown" means
  gcloud could not read the VM at all — almost always a credential mismatch, not a
  deleted VM. `up` refuses to guess there, so it cannot build a second VM while
  the real one runs invisibly.
