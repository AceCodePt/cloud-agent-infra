# Capabilities

What this repo can do, and how to reach it. The map between **commands**
(`./run …`), the **scripts** they dispatch, and the **flows** they compose.
`README.md` is the entry point; `docs/operating.md` is the how-to; `docs/decisions/`
is the why.

The box is a GCE VM reached over Tailscale (`ssh <user>@cloud-agent`). Two places
do work: **the workstation** (this repo) and **the box** (provisioned by phase B,
or pushed over ssh for measurement). Every table below says which.

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
| `./run rebuild` | `cleanup → bootstrap → apply → wait → phone → verify`. **Destroys the data disk** | multiple |
| `./run cleanup [--yes --keep-*]` | Tear down + delete tailnet node. Full wipe by default | `scripts/cleanup.sh` |
| `./run bootstrap` | State bucket + `backend.tf` + `terraform init` + mint auth key | `scripts/bootstrap.sh` |
| `./run phone` | Re-key the phone to the VM's current notify pubkey | `scripts/provision-phone.sh` |

### Agents — measure the box, not opinions

| Command | What it does | Dispatches |
|---|---|---|
| `./run measure [--seconds --interval --label --json]` | Sample the box's real resource use (PSS by user/kind, peaks, MemAvailable, swap, load). **box** | `scripts/measure-resources.py` over ssh |
| `./run lsp-probe --cmd … --root … [--ext --files --settle --quiet --json]` | What one language server costs on a real repo, no provider needed. **box** | `scripts/lsp-probe.mjs` over ssh |

Real agent sessions (a connected model, tool calls, LSP spawn) are hand-driven
over ssh — see §3; deliberately not wired into `./run`.

### Social — one-time login and session proof

| Command | What it does | Dispatches |
|---|---|---|
| `./run login [platform]` | Log a social account in BY HAND, over VNC through an SSH tunnel (once) | `scripts/login-social.sh` |
| `./run login [pf] --verify [--deep]` | Still logged in? Default: cookie jar only. `--deep`: +1 authenticated request. Exit 0/1/2 | `scripts/login-social.sh` + `social-session.py` |
| `./run login [pf] --stop` | SIGTERM that platform's browser (cookies flush) | `scripts/login-social.sh` |

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
| `./run tf <args>` | Raw terraform in `terraform/` (`./run tf state list`) |
| `./run fmt` / `validate` / `check` | Format / validate + `bash -n` / validate + verify |

---

## 2. The scripts not reachable from `./run`

Everything else under `scripts/` is dispatched by the tables above, or is a
sourced library (`scripts/lib.sh`). The exception is the measurement toolchain —
hand-driven over ssh, each needing a running `opencode serve` with a provider
connected:

| Script | Capability | Where |
|---|---|---|
| `scripts/measure-resources.py` | PSS-by-user/kind sampler; peaks; MemAvailable; swap; load. Prints on SIGTERM. | box (over ssh) |
| `scripts/lsp-probe.mjs` | Drive one LSP over stdio on a real repo; PSS/RSS of the whole process tree. | box (over ssh) |
| `scripts/agent-stress.mjs` | K concurrent canary sessions × R rounds against a running server; per-round ok/err; completion %. | box |
| `scripts/box-agent-stress.sh` | Single-server ramp: fresh server + sampler + stress + halt signals (OOM dmesg, process liveness, health). | box |
| `scripts/box-multi-stress.sh` | The realistic per-client case: one server each, own LSP, shared repo. | box |
| `scripts/box-agent-supervisor.sh` | SIGTERM the sampler when a detached stress finishes. | box |
| `scripts/drive-agent.mjs` | Send one message to an opencode session (measures tool subprocesses + LSP). | box |
| `scripts/drive-agent-loop.mjs` | Drive a session through multiple rounds sequentially. | box |
| `scripts/box-setup-agent.sh` | Fresh opencode server on the TS repo + create a session, print its ID. | box |
| `scripts/box-run-agent.sh` | Run the agent loop in the background, logging to `/tmp/agent-run.log`. | box |

---

## 3. The flows

### `up` — the convergence loop

```
bootstrap → mint key → apply → wait (on tailnet) → phone → verify
```
Each step asks "is it already true?" and does nothing if so; `verify` proves the
result. Repair = `up`; throw away but keep data = `tf destroy -target=... && up`;
throw everything away = `rebuild`.

### The measurement toolchain — how the numbers in `docs/measurements.md` were made

Measures **cost per client**, in increasing fidelity:

```
lsp-probe        what ONE language server costs (no model needed)
  └── drives the server directly over stdio on /mnt/data/repos/{ts,pyd}

drive-agent      what a REAL agent session costs (needs a provider)
  └── one message to a session; then ./run measure alongside it

agent-stress     does the box HALT or just slow down?
  └── K canaries × R rounds on one server, sampler + dmesg OOM + liveness
      (box-agent-stress.sh orchestrates, box-agent-supervisor.sh ends it)

box-multi-stress the REAL per-client number (one server per client)
  └── K servers on ports 4101+, each with own LSP, shared repo
```

Typical invocation (single-server ramp):

```sh
# push the pieces, then drive from the box
ssh_vm "cat > /tmp/agent-stress.mjs" < scripts/agent-stress.mjs
ssh_vm "cat > /tmp/box-agent-stress.sh" < scripts/box-agent-stress.sh
ssh_vm "bash /tmp/box-agent-stress.sh 4 2 \"stress K=4\""   # K=4, 2 rounds each
```

Result (from the ramp): completion stays 100% from K=2 to K=24; the box degrades
gracefully (load to ~11, MemAvailable never below ~2.5 GB, swap ≤121 MB), it does
not halt. Details and caveats in `docs/measurements.md`.

### Social — one login, then proof

```
./run login linkedin        # by hand, over VNC, on the box (once; li_at ≈364 days)
./run login linkedin --verify      # cookie jar only — no traffic
./run login linkedin --verify --deep   # +1 authenticated request (proves live egress)
./run login linkedin --stop         # SIGTERM the browser (flushes cookies)
```
