# TASK

Actionable work only. Rationale, measurements and evidence live in `SPEC.md`.

---

## Architecture (current)

A **private, unlisted Chrome extension** reads LinkedIn; a local controller
drives it over a **WebSocket**. No CDP anywhere.

```
  controller (python, on the VM)
    └─ WebSocket server on 127.0.0.1:8765
         ▲                          │
         │ harvested JSON           │ commands: scroll / harvest / stop
         │                          ▼
  ┌──────┴───────────────────────────────────┐
  │ extension service worker  (holds the WS)  │
  │        ▲ chrome.runtime messaging ▼       │
  │ content script (isolated world, reads DOM)│
  └───────────────────────────────────────────┘
        real headful Chrome on Xvfb :99
        LinkedIn tab — sees none of the above
```

Why this shape, in one line each (evidence in `SPEC.md`):

- **No CDP** — `Runtime.enable` is the single clearest automation marker, and an
  extension needs no debugging port at all.
- **Private extension ID** — never published, so it is not in LinkedIn's
  extension-ID scan list (38 IDs in 2017 → 6,167 by Feb 2026).
- **No `web_accessible_resources`** — Chrome then *blocks* `chrome-extension://`
  probes outright, so the ID cannot be confirmed even if guessed. Content
  scripts do not need the declaration.
- **No DOM modification** — nothing for LinkedIn's DOM-walking scan to find;
  content scripts run in an isolated world invisible to page JS.
- **Headful on Xvfb** — measures identically to real headed Chrome (CreepJS
  0%/44%); headless scores 67%/50%.
- **Extension can only be a WS client**, never a server — so the controller
  listens and the browser dials out. Nothing can reach into the extension.

---

## Now — make the machine ready

- [x] **Phase B packages** — added `x11vnc`, `xauth`, `python3-venv`; kept
      `zram-tools` (it was active all along; the removal rested on a bad probe)
- [x] **Node.js 24 LTS** from the NodeSource apt repo — Debian ships 18, which is
      EOL. Same vendor-apt-repo pattern phase A uses for Tailscale, so it still
      gets security updates (unlike a curl-pipe-to-shell install).
      Verified `v24.18.1` / npm `11.16.0`.
- [x] **`x11vnc` systemd unit**, bound to `127.0.0.1`, **not enabled** — started
      by hand for the one-time login, reached over an SSH tunnel
- [x] **`social-chromium` wrapper**: no `--remote-debugging-port`, loads the
      extension, persistent profile at `/mnt/data/browser/social`
- [x] Keep `headed-chromium` (with CDP) for **agent browser testing** — our own
      apps, nothing to hide from. Test and social browsers stay separate.
- [x] **No `openbox`** — no evidence any detector checks for a window manager.
      The measured Xvfb config needs `xauth`, not a WM.
- [x] **No static IP.** Tried and reverted; see `SPEC.md` → Decisions.
- [x] Fixed a real bug found on the way: phase A used `systemctl start` on a
      `RemainAfterExit=yes` oneshot, which is a **no-op** once the unit is
      `active (exited)`. So re-running the startup script never reinstalled
      anything. Now `systemctl restart`.
- [x] `./run validate` + `./run verify` → 31/31
- [ ] `chmod 600 config.env` (currently `644`, holds a live Tailscale API key)
- [ ] Fold in or drop the packages installed ad-hoc during measurement so they
      are reproducible: `python3-websocket`, `x11-utils`, `xdotool`

---

## Phase 1 — extension + controller skeleton

Goal: a round trip. Controller sends `ping`, extension answers, JSON lands on disk.
No LinkedIn yet.

- [ ] `extension/manifest.json` — MV3, `"minimum_chrome_version": "116"`,
      host permission for `linkedin.com` + the localhost WS, **no**
      `web_accessible_resources`, no other permissions
- [ ] Pack with a fixed `key` so the extension ID is stable across reloads
      (unpacked IDs derive from the install path)
- [ ] `extension/sw.js` — service worker: opens `ws://127.0.0.1:8765`,
      **keepalive ping every 20s** (30s idle timeout, WS activity resets it),
      reconnect with backoff on `onclose`
- [ ] `extension/content.js` — isolated world, reads only, no injection;
      relays to the service worker via `chrome.runtime` messaging
- [ ] `controller/server.js` — Node WS server on `127.0.0.1:8765`; treats
      "no client connected" as normal, not an error. Node rather than Python so
      one language covers the service worker, the content script and the server,
      with no build step or bundler keeping three dialects in sync.
- [ ] `scripts/deploy-app.sh` + `./run deploy` — rsync `extension/` and
      `controller/` to the VM over Tailscale (app code is not Terraform's job)
- [ ] Confirm whether `host_permissions` is needed for `ws://127.0.0.1`
      (WS URLs match against the `http`/`https` equivalent). Fails loudly.

---

## Phase 2 — the login

The real risk. Do it before building anything on top.

- [ ] Start `x11vnc` by hand; tunnel it over SSH; confirm a usable session
- [ ] Log into LinkedIn **by hand**, into the persistent social profile
- [ ] Zero extensions loaded other than ours; never use incognito (cookies
      extracted from incognito die in ~1h vs weeks from a normal profile)
- [ ] Note the browser's user agent and keep it stable afterwards
- [ ] Stop `x11vnc` again
- [ ] **Pause and unpause the VM. Confirm the session survives.** This is the
      decision point — if it does not, the design changes.

---

## Phase 3 — read something

Start with notifications, not the feed: `voyagerIdentityDashNotificationCards`
is verified working browserless, whereas the home feed operation
(`voyagerFeedDashMainFeed`) has a captured query ID that **nobody has
demonstrated executing**.

- [ ] Harvest notifications first — the surface with evidence behind it
- [ ] Then the feed via DOM read, **harvesting during the scroll**: the feed is
      virtualised and recycles nodes, so nothing is there afterwards
- [ ] Persist seen post IDs on `/mnt/data`
- [ ] Treat **zero items parsed as an error**, never as an empty feed
- [ ] Read status codes correctly: `302 → /uas/login` is the only session-death
      signal; **`403` means a missing `csrf-token` header, not a ban**; `429`
      means slow down
- [ ] Echo `JSESSIONID` as the `csrf-token` header (quotes stripped) if calling
      Voyager directly

### Rules for the scrolling/harvest loop

- [ ] **Never a fixed interval and never a round clock time** — mechanical
      timing is a stronger signal than anything about the IP
- [ ] Randomise spacing; run on demand rather than on a schedule
- [ ] Read-only. No likes, comments, connects, or profile views.

---

## Explicitly not doing

- **No scheduled poller.** Fixed-interval polling is itself a detection signal.
- **No notification stream to the phone.** Not spamming the phone.
- **No openbox** — folklore; see `SPEC.md`.
- **No residential/commercial proxy** — vendor-driven advice with no measurement
  behind it. Revisit only if a challenge actually appears.
- **No provider migration.** Money is no longer the optimisation target; pausing
  the VM covers cost, and GCP bills a stopped instance for disks only.
- **No static IP and no proxy/exit-node egress.** The whole IP-stability premise
  is weakly evidenced (see `SPEC.md`). Revisit only if a challenge actually
  appears — and note the phone is the *worst* candidate for an exit node, because
  it roams (WiFi → LTE → CGNAT), Doze throttles sustained forwarding, and
  Tailscale exit nodes **fail closed**, so traffic stops when the phone wanders
  off rather than falling back. The router is the sane option if one is ever
  needed: always on, never moves, same residential address.
- **Do not log in on the laptop and copy the `li_at` cookie to the box.** That
  creates the session on one address and uses it from another, which is the one
  transition with real reports behind it. Logging in through VNC into the
  browser *on the box* makes login and use share an IP automatically.
- **Meta (Facebook/Instagram) is out of scope** until LinkedIn has run cleanly
  for weeks. Accounts Center links them, so enforcement can cascade.

---

## Known risks to keep in view

- **DOM scraping is fragile.** Generated class names churn; the feed is
  virtualised. Reading response bodies would be sturdier but is not practical in
  MV3 (`declarativeNetRequest` and `webRequest` cannot read bodies; patching
  `window.fetch` means touching the page; `chrome.debugger` *is* CDP).
- **Scrolling emits no `wheel` or `pointer` events.** Extensions cannot forge
  trusted input — only CDP can, which is what we are avoiding. Residual
  difference from a real user; accepted.
- **Software WebGL renderer** (`SwiftShader`/`llvmpipe`) marks the box as a
  GPU-less VM, and LinkedIn does collect the renderer string. Unfixable here.
- **Service workers die unpredictably.** Keepalive prevents *idle* death only;
  reconnect logic is mandatory.
- **ToS.** LinkedIn's `robots.txt` is `Disallow: /` and the User Agreement
  prohibits automation. Read-only access to one's own feed has no reported
  enforcement precedent, but that is absence of evidence, not safety.
