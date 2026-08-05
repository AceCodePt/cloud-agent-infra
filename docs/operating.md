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
# config.env  (git-ignored — contains a secret)
TF_VAR_project_id="your-project-id"
TF_VAR_region="me-west1"           # Tel Aviv: lowest latency from Israel
TF_VAR_zone="me-west1-a"
TF_VAR_machine_type="e2-standard-2"  # 2 full vCPU/8GB for agents+browsers; e2-medium is leaner
TF_VAR_instance_name="cloud-agent"   # also the tailnet hostname
TF_VAR_ssh_user="youruser"           # your Unix user on the box
TF_VAR_data_disk_size_gb="20"        # persistent disk for repos + tailscale state (defaults to 20)
TF_VAR_termux_host="galaxy-s24-ultra" # phone's Tailscale MagicDNS name, for notify-phone (optional)
TF_VAR_termux_ssh_user="u0_a221"      # `whoami` inside Termux, required for notify-phone to work

# Tailnet admin key. bootstrap.sh mints a single-use auth key per build from it.
TAILSCALE_API_KEY="tskey-api-..."
```

`TF_VAR_data_disk_size_gb` is optional — omit it to use the default (20 GB).

> **Do not** also set `TF_VAR_tailscale_auth_key`. Terraform ranks
> `terraform/tailscale.auto.tfvars` (written by `mint`) above `TF_VAR_*` env vars,
> so a key here is ignored on every normal build and then silently takes effect —
> as a long-spent key — if that file ever goes missing. Set one or the other.

> **`TF_VAR_ssh_public_key` is optional and usually unnecessary** — it authorizes
> your own key for sshd, but `gcloud compute ssh --tunnel-through-iap` injects an
> ephemeral key of its own, and Tailscale SSH needs no key at all. Set it only if
> you connect to sshd through a raw IAP tunnel with your own key (e.g. editor
> Remote-SSH without Tailscale).

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

- A Google Cloud project with **billing enabled**.
- `gcloud` and `terraform` installed locally. (No `direnv`.)
- A [Tailscale](https://tailscale.com) account and a tailnet **API key** (admin
  console → Settings → Keys). The tooling mints its own single-use auth key per
  build from that; you do not manage auth keys by hand.
- Application-default credentials for Terraform:
  ```sh
  gcloud auth application-default login
  ```

---

## The one command

```sh
./run up
```

`up` is a **convergence** command, not a build script: every step first asks what
is already true and does nothing if the answer is "already correct". It ends by
running `verify.sh`, so it can't lie about the result. **Non-destructive by
contract** — it never destroys the VM, data disk, state bucket, or a tailnet
node. It cannot cost you the notify keypair, your browser logins, or the work on
`/mnt/data`.

The steps `up` encodes, in order, doing only what is missing:

| # | Converges | Acts only if |
|---|-----------|--------------|
| 1 | Terraform state backend | `backend.tf` or the backend record is absent |
| 2 | Tailscale auth key | the current key is unusable (spent, revoked, missing) |
| 3 | Infrastructure | `terraform apply` — always; it is itself a converge |
| 4 | Guest has consumed the key | the VM is not online in the tailnet |
| 5 | Local `known_hosts` | a stale entry from a previous VM is blocking SSH |
| 6 | Phone notify key | always (idempotent; the most drift-prone fact there is) |
| 7 | Proof | `verify.sh`, non-zero exit on any drift |

Step 4 is why `up` exists — `apply` alone cannot re-key a running VM (below).

### Rebuilding from scratch

`./run rebuild` is the destructive sibling: `cleanup → bootstrap → apply → wait →
phone → verify`. It **destroys the data disk, the state bucket and the tailnet
node** — a new notify keypair, a stale pinned key on the phone, and loss of
everything on `/mnt/data`. Reach for it only when you mean exactly that; `up` is
what you want the other 99% of the time.

```sh
./scripts/cleanup.sh          # tear down + delete the tailnet node
./scripts/bootstrap.sh        # state bucket + backend.tf + init + mint a one-off auth key
./run apply                   # instance created; reachable ~40-60s later
./scripts/wait-ready.sh       # block until on the tailnet AND startup script done
./scripts/provision-phone.sh  # re-key the phone to the VM's CURRENT pubkey
./scripts/verify.sh           # assert the entire end state, non-zero on any drift
```

### The boot is two phases, and the split is the point

**Phase A (foreground, ~40-60s)** does only what is needed to *reach* the box:
mount the data disk, install Tailscale, create your user, `tailscale up`. The
single-use auth key is spent at the end of phase A.

**Phase B (background, ~4 min)** is everything else, in waves: CLI tools, `apt
upgrade`, the headed-browser stack (chromium, fonts, Xvfb, xauth, x11vnc,
`libgl1-mesa-dri`, zram), Node.js 24, and opencode at a pinned version as a single
root-owned binary in `/usr/local/bin`. It runs as `agent-packages.service`,
launched with `systemctl restart --no-block`, so the metadata script runner
returns immediately. The agent user's default shell is `zsh` because the dotfiles
are zsh-centric; the install picks the single interactive account phase A created
(uid ≥ 1000) rather than hardcoding a name.

Measured, not guessed: `274s → 84s` for instance-created → key-consumed. The
remaining 41s of the 84 is GCE booting the guest before it hands over.

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

### `apply` cannot re-key a running VM

The auth key reaches the VM through the `startup-script` **metadata** value, and
GCE only runs `startup-script` at **boot**. Minting a key and applying against an
existing instance is a metadata-only update — the guest never reads it, nothing
joins the tailnet, and the apply reports success. Use:

```sh
./run rekey            # mint + apply + re-run startup over IAP (no downtime)
./run rekey --reboot    # same, but stop/start instead — needs only the Compute API
```

`rekey` re-triggers the startup script rather than running `tailscale up` by
hand, so the key is read from metadata. The default path goes over
`gcloud compute ssh --tunnel-through-iap` deliberately: if you are running this,
Tailscale is broken, so the tailnet is not usable as a transport. Safe on a
healthy box — the startup script only spends a key when the node is not already a
member.

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

Agents get a **real browser** — many sites block `HeadlessChrome`, so the box
runs Chromium *headed* on a virtual display: **Xvfb** provides a 1920×1080 screen
(`DISPLAY :99`, pre-set in every login shell and tmux) and Chromium renders into
it like a normal browser. No desktop or window manager.

There is exactly one wrapper, `headed-chromium`:

| | `headed-chromium` |
|---|---|
| For | agent browser testing against **our own** apps |
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
- Give each agent its own `BROWSER_PROFILE_DIR` and `CDP_PORT` — one profile
  shared between identities means one cookie jar and one fingerprint for both.

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

## Phone notifications (Termux)

Agents can ping your phone ("build finished", "needs your input") via
`notify-phone "<title>" "<message>" [extra flags]`. The VM is the SSH *client* —
it dials **out** to Termux's own `sshd` on your phone over the tailnet and runs
`termux-notification` remotely. No inbound changes on the VM, no forwarding, no
Tailscale SSH.

```sh
notify-phone "Build" "finished on cloud-agent"
notify-phone "Tests" "3 failed — tap to open" \
  --action "android.intent.action.VIEW" \
  --icon-path /sdcard/Download/ic_fail.png
```

Any `termux-notification` flag passes straight through. The wrapper `%q`-escapes
every argument so multi-word and special-character text survives ssh's
space-joining intact. If the phone is down, `notify-phone` **fails fast** (~5s,
non-zero exit) — append `|| true` if notifications are best-effort.

The dedicated ed25519 keypair and `known_hosts` live on the persistent data disk
(`/mnt/data/ssh-termux/`), so a VM rebuild doesn't require re-adding the key.

**One-time setup on the phone (Termux), by hand:**

```sh
pkg install openssh termux-api termux-services python
sshd             # starts sshd right now, on port 8022
whoami           # note this — it's TF_VAR_termux_ssh_user
```

Termux is an unprivileged Android app, so it **cannot bind port 22** — `sshd`
listens on **8022** (hence the `TF_VAR_termux_ssh_port` default). No password —
auth is by key only.

```sh
# Fully restart Termux first (swipe from recents) — termux-services' runsvdir
# starts from ~/.profile.
sv-enable sshd
sv up sshd
```

Also on the phone: install **Termux:Boot** and open it once (sshd won't survive a
phone reboot otherwise), **exempt Termux from battery optimization**
(Settings → Apps → Termux → Battery → Unrestricted), and on Android 13+ grant
**Termux:API the notification permission**. `python` is only needed for the
hardening parser below.

Then, after `./run apply`, grab the generated public key from the VM
(`cat /mnt/data/ssh-termux/id_ed25519.pub`) and append it to
`~/.ssh/authorized_keys` in Termux.

Configure via `TF_VAR_termux_host` (default `galaxy-s24-ultra`),
`TF_VAR_termux_ssh_port` (default `8022`), and `TF_VAR_termux_ssh_user` (from
`whoami`). The feature is only provisioned when **both** host and user are set.

### Hardening the phone key (optional, recommended)

By default the key can open a full shell on your phone. To lock it to
notifications only, use a **forced command** on the phone side. The parser is
python's `shlex` — pure parsing, **no shell eval** — so injection is impossible
by construction.

`~/bin/notify-only` in Termux (`chmod +x`):

```python
#!/data/data/com.termux/files/usr/bin/python3
# Forced-command target for the notify-phone key: run ONLY termux-notification,
# with any flags. sshd puts the original command in SSH_ORIGINAL_COMMAND as one
# string; shlex splits it (no eval), so metacharacters in the message are data.
import os, shlex, sys

BIN = "/data/data/com.termux/files/usr/bin/termux-notification"

raw = os.environ.get("SSH_ORIGINAL_COMMAND", "")
try:
    argv = shlex.split(raw)
except ValueError as e:
    sys.exit(f"refused: unbalanced quoting ({e})")
if not argv or argv[0] != "termux-notification":
    sys.exit("refused: this key may only run termux-notification")
os.execv(BIN, argv)
```

and in `~/.ssh/authorized_keys` use this *instead of* the plain pubkey:

```
restrict,command="$HOME/bin/notify-only" ssh-ed25519 AAAA... sagi@cloud-agent-notify-phone
```

`restrict` additionally disables PTY, port/agent forwarding, X11 and user-rc for
this key. Nothing on the VM side changes.

---

## Teardown

**Full wipe by default** — destroys the VM + data disk, deletes the GCS state
bucket, and removes local Terraform artifacts:

```sh
./run cleanup                # FULL wipe (compute + bucket + files + tailnet node)
./run cleanup --yes          # same, skip confirmation prompts
./scripts/cleanup.sh --keep-bucket   # keep the state bucket
./scripts/cleanup.sh --keep-files    # keep local .terraform / backend.tf / state
```

> **`cleanup` is not "reset".** Answering `y` to all three prompts deletes the
> data disk — everything under `/mnt/data`, the tailnet node identity, and the
> notify keypair — plus the state bucket, which is the only record of what exists.
> There is no undo. If your goal is "make it work again", that is `./run up`; if
> it is "throw the VM away but keep my data", that is:
>
> ```sh
> ./run tf destroy -target=google_compute_instance.agent && ./run up
> ```

---

## Security: no public inbound

The VM runs on its **own dedicated VPC** (`network.tf`), not GCP's `default`
network (whose auto rules open tcp:22, tcp:3389, icmp to `0.0.0.0/0`).

The firewall allows only:

- **Ingress tcp:22 from `35.235.240.0/20`** — Google's IAP range, so
  `gcloud compute ssh --tunnel-through-iap` works as a break-glass path.
- **Ingress within the subnet** (`10.10.0.0/24`).
- **All egress** — Tailscale dials out; apt/git need the internet.

There is **no public inbound** — you reach the box over the Tailscale tailnet,
established outbound. Your user has **passwordless sudo**, acceptable because the
only ways in are your tailnet identity and your Google identity, both enforced
off-box (`useradd` creates the account password-locked, so no password would ever
match).

If you still have GCP's default rules:

```sh
gcloud compute firewall-rules list \
  --format="table(name,network,sourceRanges.list())"
# delete the internet-facing ones (keep default-allow-internal):
gcloud compute firewall-rules delete default-allow-ssh default-allow-rdp default-allow-icmp --quiet
```

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

Sizing decisions in this repo come from measurement, not opinion, and the tools
are checked in so a claim can be re-checked. The full numbers and their caveats:
[`measurements.md`](measurements.md). The toolchain that produced them
is mapped in [`capabilities.md`](capabilities.md).

```sh
./run measure --seconds 120 --label "two agents"   # PSS by user and kind, peaks
./run lsp-probe --cmd "tsgo --lsp --stdio" --root /mnt/data/repos/ts --quiet 30
```

`measure` reports **PSS**, not RSS, because per-client isolation means several
copies of the same binaries sharing pages, and RSS overestimates in the direction
that costs money.

---

## Gotchas (learned the hard way)

- **GCP's `default` network is wide open** (tcp:22, 3389, icmp from `0.0.0.0/0`).
  Use the dedicated VPC in `network.tf`, or delete those rules.
- **Deleting `default-allow-ssh` makes plain `gcloud compute ssh` hang** — it has
  no route in. Use `--tunnel-through-iap`, or rely on Tailscale.
- **Tailscale SSH needs an ACL** granting it. In the tailnet admin console add an
  `ssh` rule (e.g. `action: accept`, `src: autogroup:member`,
  `dst: autogroup:self`, `users: [youruser, autogroup:nonroot]`).
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
  **PID**. Write bare `$VAR`. A `lifecycle precondition` in `compute.tf` now
  fails the apply if any `$$` survives — and always verify against the *rendered*
  script (`gcloud compute instances describe`).
- **`ssh host cmd arg1 arg2` joins argv with spaces and the remote shell
  re-parses it.** Quoting is not preserved. `notify-phone` uses `printf %q` +
  `shlex.split`; `provision-phone.sh` embeds `%q`-escaped assignments.
- **`ssh` eats stdin.** Piping a script to `bash -s` over ssh and then calling
  `ssh` inside it makes the inner ssh consume the rest of the script. Use `ssh -n`
  or `</dev/null`; `notify-phone` passes `-n`.
- **Non-interactive ssh has a minimal `PATH`.** `swapon`/`zramctl` live in
  `/usr/sbin`; `ssh host swapon --show` fails with "command not found". Export the
  full PATH when probing.
- **`DEBIAN_FRONTEND=noninteractive` does NOT stop dpkg conffile prompts.** It
  governs debconf. Pass `-o Dpkg::Options::=--force-confold`.
- **A conffile conflict poisons the box permanently.** The failed package is left
  half-configured (`iU`), so every later `apt-get install` fails identically —
  before `tailscale up` — making the VM unreachable *and* unable to re-key itself.
  Repair with `dpkg --configure --force-confold -a`.
- **Never pre-create a file a package owns as a conffile.** Writing
  `/etc/default/zramswap` before installing `zram-tools` caused both bugs above.
- **The last line of a startup script may never reach the serial console.**
  Milestones go through `logger` (synchronous, journal) and a sentinel file at
  `/run/agent-startup-complete` checked over SSH.
- **gcloud `--filter` can be pushed SERVER-side and rejected.** `verify.sh` lists
  plainly and matches client-side.
- **gcloud and Terraform authenticate SEPARATELY.** Terraform uses
  application-default credentials; the `gcloud` CLI uses its own active account.
  `gcloud auth list` / `gcloud config list` are the diagnosis.
- **Don't let a failed API call read as a passing check.** A security check that
  cannot run must FAIL, never pass.
- **Anything slow in the foreground of `startup-script` is time the box is
  unreachable.** Keep phase A minimal; defer the rest to `agent-packages.service`.
- **Do not write a literal doubled dollar inside the `startup.tf` heredoc** — not
  even in a comment. The `compute.tf` precondition rejects the apply.
- **`cleanup` is a wipe, not a reset.** To fix a broken box use `./run up`; to
  replace just the VM, `tf destroy -target=...instance.agent`.
- **Never delete the state bucket or `backend.tf` while resources exist.** They
  are the only pointers to live infrastructure. `cleanup.sh` verifies with
  `gcloud` that the instance and disk are really gone before either wipe.
- **Measurement harness traps** (from the sizing work): `pkill -f` patterns must
  be anchored (`^/usr/local/bin/opencode serve`) or they match the killer's own
  command line and kill the shell running it; every `curl` health check needs
  `--connect-timeout --max-time` or a half-open server hangs the whole run; the
  sampler prints peaks on SIGTERM so a short workload doesn't lose its numbers;
  detached processes must redirect all three fds or ssh waits on the channel.
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
- **Tailscale SSH check mode demands a browser confirmation.** A non-interactive
  session (verify, rekey, measure) can trigger an "additional check" prompt —
  once per session, not per host. Run `./run ssh` once and follow the URL; the
  scripts warn instead of failing. `./run ssh` deliberately skips BatchMode so
  those prompts work.
- **x11vnc exits 2 on SIGTERM**, so a plain `systemctl stop` leaves the unit
  "Failed (exit-code)" forever — a real-looking fault on a box whose correct state
  is "stopped, login finished". `SuccessExitStatus=2` fixes new boxes and
  `reset-failed` clears the bogus entry; `browser.sh` does both.
- **A backgrounded process over ssh dies with the session** unless it gets
  `setsid` + `nohup` + closed stdin + `disown` — all four, or the process is a
  child of the ssh session. `browser.sh` and the measurement harness use all
  four.
- **`instance_status` distinguishes "absent" from "unknown".** "unknown" means
  gcloud could not read the VM at all — almost always a credential mismatch, not a
  deleted VM. `up` refuses to guess there, so it cannot build a second VM while
  the real one runs invisibly.
