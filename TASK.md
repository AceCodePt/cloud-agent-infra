# TASK

Open, actionable work only. Nothing here explains *why* — reasoning lives in
[`docs/decisions/`](docs/decisions/), evidence in
[`docs/measurements.md`](docs/measurements.md), state of the world in `SPEC.md`.

**Ordering rule:** the priority column in `SPEC.md` decides what gets worked on,
not whichever question is most tractable. Goal 4 is primary and has the least
built.

---

## Goal 4 (primary) — specify it before building anything

Everything about sizing, isolation and the provider is blocked on this. The
output of the first two items is a decision document, not code.

- [ ] Write down the concurrency target: how many clients, how many
      *simultaneously active* agents. Measured: the CPU saturates around ~2–4
      active agents on 2 vCPU, but the box **degrades gracefully and never
      halts** — 100% completion up to 24 concurrent sessions (see
      `docs/measurements.md`). So the target should be set on acceptable
      latency, not on a hard ceiling.
- [ ] Decide the isolation model — Unix user per client, container per client, or
      box per client — and record it in `docs/decisions/agents-and-sizing.md`.
- [ ] Decide whether agent browser testing means one shared browser or one per
      agent (each headed Chromium is ~530 MB and a browser on a busy page is
      ~1 core).
- [ ] Only then: resize, or migrate provider, or neither.
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

- [ ] `python3-websocket`, `x11-utils` and `xdotool` were installed by hand during
      measurement and are in no committed script and no phase B wave. Either drop
      them or add them to `startup.tf`, so a rebuilt box matches this one.
- [x] The measurement toolchain (`agent-stress.mjs`, `box-*-stress.sh`,
      `box-agent-supervisor.sh`, `drive-agent*.mjs`, `box-setup-agent.sh`,
      `box-run-agent.sh`) is committed and documented in
      `docs/capabilities.md` (section 3) — no longer hand-rolled in `/tmp`.
      Note: they stay **hand-driven over ssh**, not wired into `./run`, because
      each needs a running `opencode serve` with a provider connected.
