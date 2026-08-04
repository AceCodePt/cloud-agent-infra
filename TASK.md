# TASK

Open, actionable work only. Nothing here explains *why* — reasoning lives in
[`docs/decisions/`](docs/decisions/), evidence in
[`docs/measurements.md`](docs/measurements.md), state of the world in `SPEC.md`.

**Ordering rule:** the priority column in `SPEC.md` decides what gets worked on,
not whichever question is most tractable. Goal 4 is primary and has the least
built.

---

## Goal 4 (primary) — isolation and concurrency decided; build next

Settled and recorded in `docs/decisions/agents-and-sizing.md`:
5–10 clients with ~2 simultaneously active agents; **Unix user per client**;
browser testing is one shared browser, or a browser served over the tailnet
from outside; **neither resize nor migration** — the box stays as it is.

- [x] Concurrency target — 5–10 clients, ~2 simultaneously active agents. The
      box **degrades gracefully and never halts** (100% completion up to 24
      concurrent sessions, see `docs/measurements.md`), so the target is set on
      acceptable latency, not a hard ceiling.
- [x] Isolation model — **Unix user per client**, no container runtime. Recorded
      in `docs/decisions/agents-and-sizing.md`; the PSS measurements carry over.
- [x] Browser model — one shared browser, or a browser served over the tailnet
      from outside; **not** one browser per agent (each headed Chromium is
      ~530 MB + ~1 core on a busy page).
- [x] Resize or migrate — **neither**. The box stays `e2-standard-2` on GCP.
- [ ] Build the first per-client account: `useradd`, per-client `opencode.json`,
      first client checkout, `opencode serve` as that user, verify isolation.
- [ ] Wire the phone into an approval loop: `GET /event` (SSE) → `notify-phone`
      with action buttons → `POST /session/:id/permissions/:permissionID`.
- [ ] Re-measure with a real client workload over a long session; the current
      numbers are minutes-long bursts.

---

## Goal 2 — the LinkedIn reader

### Blocking check

- [ ] **Pause and unpause the VM, then confirm the session survives.** This is a
      decision point, not a detail (`SPEC.md` open question 2).

### Phase 1 — extension + controller skeleton

Goal: a round trip. Controller sends `ping`, extension answers, JSON lands on
disk. No LinkedIn yet.

- [ ] `extension/manifest.json` — MV3, `"minimum_chrome_version": "116"`, host
      permission for `linkedin.com` + the localhost WS, **no**
      `web_accessible_resources`, no other permissions
- [ ] Pack with a fixed `key` so the extension ID is stable across reloads
      (unpacked IDs derive from the install path)
- [ ] `extension/sw.js` — service worker: opens `ws://127.0.0.1:8765`, keepalive
      ping every 20s (30s idle timeout, WS activity resets it), reconnect with
      backoff on `onclose`
- [ ] `extension/content.js` — isolated world, reads only, no injection; relays to
      the service worker via `chrome.runtime` messaging
- [ ] `controller/server.js` — Node WS server on `127.0.0.1:8765`; treats "no
      client connected" as normal, not an error
- [ ] `scripts/deploy-app.sh` + `./run deploy` — rsync `extension/` and
      `controller/` to `/mnt/data/app/` over Tailscale (`social-chromium` already
      expects the extension at `/mnt/data/app/extension`)
- [ ] Confirm whether `host_permissions` is needed for `ws://127.0.0.1` (WS URLs
      match against the `http`/`https` equivalent). Fail loudly either way.

### Phase 2 — read something

- [ ] Harvest notifications first (`voyagerIdentityDashNotificationCards` is the
      surface with evidence behind it), then the feed via DOM read
- [ ] Harvest **during** the scroll — the feed is virtualised
- [ ] Persist seen post IDs on `/mnt/data`
- [ ] Alert on zero items parsed; never treat it as an empty feed
- [ ] Handle `302 → /uas/login` (session dead), `403` (missing `csrf-token`
      header), `429` (slow down) distinctly
- [ ] Park the browser on `about:blank` or stop it between reads — a browser
      sitting on `/feed/` costs ~1 core and 1168 MB continuously

---

## Housekeeping

- [x] `python3-websocket`, `x11-utils` and `xdotool` were installed by hand during
      measurement and in no committed script. Resolved: **removed the two true
      cruft packages** (`python3-websocket`, `xdotool` + their now-orphaned
      deps) from the box — nothing in the repo or the planned architecture
      (Node controller, bash+ssh `notify-phone`) uses them. `x11-utils` is a
      hard `Depends` of `chromium-common`, so a rebuilt box gets it
      automatically and nothing needs adding to `startup.tf`. Verified with
      `./run verify` (31/31) after the removal.
- [x] The measurement toolchain (`agent-stress.mjs`, `box-*-stress.sh`,
      `box-agent-supervisor.sh`, `drive-agent*.mjs`, `box-setup-agent.sh`,
      `box-run-agent.sh`) is committed and documented in
      `docs/capabilities.md` (section 3) — no longer hand-rolled in `/tmp`.
      Note: they stay **hand-driven over ssh**, not wired into `./run`, because
      each needs a running `opencode serve` with a provider connected.
