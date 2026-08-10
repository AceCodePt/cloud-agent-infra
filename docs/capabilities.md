# Capabilities

What this repo can do, and how to reach it. The map between **commands**
(`./run …`), the **scripts** they dispatch, and the **flows** they compose.
`README.md` is the entry point; `docs/operating.md` is the how-to; `docs/decisions/`
is the why.

The box is an OCI free-tier instance (Oracle Linux 9, Ampere A1) reached over
Tailscale (`ssh <user>@cloud-agent`). Two places do work: **the workstation**
(this repo) and **the box** (provisioned by phase B, or pushed over ssh). Every
table below says which. (`PROVIDER` in `config.env` selects the cloud: `oci` —
active — or the reference paths `hetzner` and `gcp`.)

---

## 1. The command surface

`./run` is the single entry point (a dispatcher over `scripts/`). Commands marked
**box** execute on the VM over ssh; everything else runs here.

### Lifecycle — build, repair, tear down

| Command | What it does | Dispatches |
|---|---|---|
| `./run up` | **The one command.** Converge to the verified good state, non-destructively; ends with `verify` | `scripts/up.sh` |
| `./run plan` | Show the Terraform plan | `lib.sh` `tf plan` |
| `./run apply` | Create/update infrastructure; validates the auth key first | `tailscale-api.sh check` + `tf apply` |
| `./run wait [--packages]` | Block until the VM is on the tailnet / phase B finished | `scripts/wait-ready.sh` |
| `./run verify [--quick]` | Assert the entire end state; non-zero on drift | `scripts/verify.sh` |
| `./run verify-browser [--quick]` | Browser stack only (sidecar; `verify` runs it) | `scripts/verify-browser.sh` |
| `./run rebuild` | `cleanup → bootstrap → apply → wait → verify`. **Destroys the data disk** | multiple |
| `./run cleanup [--yes --keep-*]` | Tear down + delete tailnet node. Full wipe by default | `scripts/cleanup.sh` |
| `./run bootstrap` | `terraform init` + mint auth key (GCP path: also GCS state bucket + `backend.tf`) | `scripts/bootstrap.sh` |
| `./run setup [oci\|hetzner\|gcp]` | Check what you need per provider (API keys, CLI, credentials) | `scripts/setup.sh` |

### Browser — reach the box's display, by hand

| Command | What it does | Dispatches |
|---|---|---|
| `./run browser [url]` | Open the **shared** browser on the box and tunnel VNC into it — drive whatever runs in it by hand | `scripts/browser.sh` |
| `./run browser --stop` | Stop the browser (SIGTERM, flushes cookies) and `x11vnc` | `scripts/browser.sh` |

The browser is infra; what runs in it (a login, an app under test) belongs to
the caller. `BROWSER_CMD`, `BROWSER_PROFILE_DIR`, and `VNC_LOCAL_PORT` override
the defaults.

### Tailscale

| Command | What it does | Dispatches |
|---|---|---|
| `./run mint-key` | Mint a fresh one-off auth key into `tailscale.auto.tfvars` | `scripts/tailscale-api.sh mint` |
| `./run check-key` | Assert that key is still usable | `scripts/tailscale-api.sh check` |
| `./run rekey [--reboot]` | Get a fresh key into an EXISTING VM (apply can't) | `scripts/rekey.sh` |
| `./run list-nodes` | List tailnet devices | `scripts/tailscale-api.sh list` |
| `./run delete-node [n]` | Delete this instance's node (+ any `-N` duplicate) | `scripts/tailscale-api.sh delete-node` |

### Misc

| Command | What it does |
|---|---|
| `./run ssh [args]` | Interactive SSH to the box over Tailscale |
| `./run tf <args>` | Raw terraform in `terraform/<provider>/` (`./run tf state list`) |
| `./run fmt` / `validate` / `check` | Format / validate + `bash -n` / validate + verify |

`./run validate` runs `terraform validate` with `-backend=false` on a clean
checkout (no `.terraform/` yet), so it works before any infrastructure exists.

---

## 2. The scripts not reachable from `./run`

Everything else under `scripts/` is dispatched by the tables above, or is a
sourced library (`scripts/lib.sh`).

---

## 3. The flows

### `up` — the convergence loop

```
bootstrap → mint key → apply → wait (on tailnet) → verify
```
Each step asks "is it already true?" and does nothing if so; `verify` proves the
result. Repair = `up`; throw away but keep data = `tf destroy -target=... && up`;
throw everything away = `rebuild`.

### Browser — one VNC session, then you're in

```
./run browser about:blank      # open the shared browser, tunnel VNC, hand you the screen
./run browser https://example.com
BROWSER_PROFILE_DIR=/mnt/data/browser/app2 ./run browser   # pick a profile
./run browser --stop           # SIGTERM the browser (flushes cookies)
```
