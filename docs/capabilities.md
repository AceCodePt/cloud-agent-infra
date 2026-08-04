# Capabilities

One place that answers **what can this repo do, and how do I reach it.** It is a
map, not a manual: `README.md` is the entry point, `docs/operating.md` is the
how-to detail, `docs/decisions/` is the why, and `docs/measurements.md` is the
evidence. This file ties them together across the three dimensions that drift
apart fastest: the **commands** (`./run …`), the **scripts** they dispatch, and
the **flows** they compose.

The box is a GCE VM reached over Tailscale (`ssh <user>@cloud-agent`). Two places
do work: **the workstation** (this repo) and **the box** (scripts installed by
phase B, or pushed over ssh for measurement). Every table below says which.

---

## 1. The command surface

`./run` is the single entry point (a dispatcher over `scripts/`). `./run` with no
arguments prints this. Commands marked **box** actually execute on the VM over
ssh; everything else runs here, from this repo.

### Lifecycle — build, repair, tear down

| Command | What it does | Dispatches |
|---|---|---|
| `./run up` | **The one command.** Converge everything to the verified good state, non-destructively; ends with `verify` | `scripts/up.sh` |
| `./run plan` | Show the Terraform plan | `lib.sh` `tf plan` |
| `./run apply` | Create/update infrastructure; validates the auth key first | `tailscale-api.sh check` + `tf apply` |
| `./run wait [--packages]` | Block until the VM is on the tailnet / phase B finished | `scripts/wait-ready.sh` |
| `./run verify [--quick]` | Assert the entire end state; non-zero on drift | `scripts/verify.sh` |
| `./run verify-browser [--quick]` | Just the browser stack (sidecar; `verify` runs it) | `scripts/verify-browser.sh` |
| `./run rebuild` | `cleanup → bootstrap → apply → wait → phone → verify`. **Destroys the data disk** | multiple |
| `./run cleanup [--yes --keep-*]` | Tear down + delete tailnet node. Full wipe by default | `scripts/cleanup.sh` |
| `./run bootstrap` | State bucket + `backend.tf` + `terraform init` + mint auth key | `scripts/bootstrap.sh` |
| `./run phone` | Re-key the phone to the VM's current notify pubkey | `scripts/provision-phone.sh` |

### Agents — measure the box, not opinions

| Command | What it does | Dispatches |
|---|---|---|
| `./run measure [--seconds --interval --label --json]` | Sample the box's real resource use (PSS by user/kind, peaks, MemAvailable, swap, load). **Runs on the box** | `scripts/measure-resources.py` over ssh |
| `./run lsp-probe --cmd … --root … [--ext --files --settle --quiet --json]` | What one language server costs on a real repo, no provider needed. **Runs on the box** | `scripts/lsp-probe.mjs` over ssh |

Real agent sessions (a connected model, tool calls, LSP spawn) are driven **by
hand over ssh** — see the "measurement toolchain" section below; they are
deliberately not wired into `./run`.

### Social — one-time login and session proof

| Command | What it does | Dispatches |
|---|---|---|
| `./run login [platform]` | Log a social account in BY HAND, over VNC through an SSH tunnel (once) | `scripts/login-social.sh` |
| `./run login [pf] --verify [--deep]` | Still logged in? Default: cookie jar only, no traffic. `--deep`: +1 authenticated request. Exit 0/1/2 | `scripts/login-social.sh` + `social-session.py` |
| `./run login [pf] --stop` | SIGTERM that platform's browser (cookies flush) | `scripts/login-social.sh` |

### Tailscale

| Command | What it does | Dispatches |
|---|---|---|
| `./run mint-key` | Mint a fresh one-off auth key into `tailscale.auto.tfvars` | `scripts/tailscale-api.sh mint` |
| `./run check-key` | Assert that key is still usable | `scripts/tailscale-api.sh check` |
| `./run rekey [--reboot]` | Get a fresh key into an EXISTING VM (apply can't) | `scripts/rekey.sh` |
| `./run list-nodes` | List tailnet devices | `scripts/tailscale-api.sh list` |
| `./run delete-node [n]` | Delete this instance's node (+ any -N duplicate) | `scripts/tailscale-api.sh delete-node` |

### Misc

| Command | What it does |
|---|---|
| `./run ssh [args]` | Interactive SSH to the box over Tailscale |
| `./run tf <args>` | Raw terraform in `terraform/` (`./run tf state list`) |
| `./run fmt` / `validate` / `check` | Format / validate + bash -n / validate + verify |

---

## 2. The scripts

### Lifecycle (workstation)

| Script | Capability |
|---|---|
| `scripts/lib.sh` | Shared plumbing: repo-root resolution, `load_config`, `ssh_vm`/`ssh_phone`, `vm_online`, `instance_status`, `rerun_startup_script`, the `tf` wrapper. Sourced, never executed. |
| `scripts/up.sh` | The convergence loop behind `./run up`. |
| `scripts/bootstrap.sh` | GCS state bucket + `backend.tf` + init + mint one-off auth key. |
| `scripts/cleanup.sh` | Full teardown (compute + bucket + local files + tailnet node), with `--keep-*` and `--force`. |
| `scripts/tailscale-api.sh` | Mint/validate/revoke check one-off auth keys; list/delete tailnet nodes. |
| `scripts/rekey.sh` | Re-deliver an auth key to a running VM (IAP re-run of startup, or reboot). |
| `scripts/wait-ready.sh` | Poll until the VM is on the tailnet and phase A/B finished. |
| `scripts/provision-phone.sh` | Phone-side parser + boot survival + re-key to the current VM pubkey. Idempotent, rolls back. |
| `scripts/verify.sh` | Assert the whole end state; runs `verify-browser.sh` as a sidecar. |
| `scripts/verify-browser.sh` | Browser-stack checks (chromium, Xvfb, CDP, zram). |

### Social (workstation → box)

| Script | Capability |
|---|---|
| `scripts/login-social.sh` | Hand-login over VNC (starts x11vnc + browser + tunnel), `--verify [--deep]`, `--stop`. Platform table: `P_URL`/`P_PROFILE`/`P_NAME`. |
| `scripts/social-session.py` | Two-level session verifier: cookie-set analysis (default) or `--deep` (decrypt + 1 authenticated request). Exit 0/1/2. |

### Measurement (mostly box-side)

| Script | Capability | Where |
|---|---|---|
| `scripts/measure-resources.py` | PSS-by-user/kind sampler; peaks; MemAvailable cross-check; swap; load. Prints on SIGTERM. | box (over ssh) |
| `scripts/lsp-probe.mjs` | Drive one LSP over stdio on a real repo; PSS/RSS of the whole process tree. | box (over ssh) |
| `scripts/agent-stress.mjs` | K concurrent canary sessions × R rounds against a running server; per-round ok/err; completion %. | box |
| `scripts/box-agent-stress.sh` | Orchestrate a single-server ramp: fresh server + sampler + stress + halt signals (OOM dmesg, process liveness, health). | box |
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
result. Non-destructive by contract. Repair = `up`; throw it away and keep data =
`tf destroy -target=google_compute_instance.agent && up`; throw everything away =
`rebuild`.

### The measurement toolchain — how the numbers in `docs/measurements.md` were made

This is the part easiest to lose track of, so it gets a map of its own. It
measures **cost per client**, in increasing fidelity:

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

---

## 4. Where does what run?

| Concern | Workstation | Box |
|---|---|---|
| Terraform, `./run` lifecycle | yes | — |
| `notify-phone` (dials OUT to Termux) | — | yes (phase B installs it) |
| Browsers (Xvfb, headed/social-chromium, x11vnc) | — | yes (phase B) |
| Measurement samplers/probes | pushes the script | yes (executes) |
| opencode server | — | yes (pinned, `/usr/local/bin`) |
| Measurement repos (`/mnt/data/repos/{ts,pyd}`) | — | yes |

---

## 5. Test/verify surface

| Command | Proves |
|---|---|
| `./run verify` | The whole machine state (31 checks) |
| `./run verify-browser` | Browser stack alone (chromium/Xvfb/zram/CDP) |
| `./run validate` | `terraform fmt -check` + `validate` + `bash -n` every script |
| `./run check` | `validate` + `verify` |
