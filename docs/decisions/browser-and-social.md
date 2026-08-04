# Decisions: browsers, fingerprints and social accounts

Everything about running a browser on the box, and about the logged-in social
account in particular. Measurements behind these are in
[`../measurements.md`](../measurements.md).

The one sentence that generates most of what follows: **a browser with a real
account logged into it is a different problem from a browser testing our own
apps**, and conflating them is how a session gets burned.

---

## Two browsers, split by purpose — **Made**

| Wrapper | Purpose | CDP |
|---|---|---|
| `headed-chromium` | agent browser testing against **our own** apps | yes, `CDP_PORT` (default 9222) |
| `social-chromium` | a **real account** is logged in | **never** |

`social-chromium` refuses `--remote-debugging-port` with exit 64 unless
`ALLOW_CDP=1` is set explicitly. That guard exists because `"$@"` used to pass
straight through, so `social-chromium --remote-debugging-port=…` quietly turned
it into the one thing it must never be — found by doing it accidentally while
measuring.

Profiles are separate directories on `/mnt/data`, so nothing learned about one
identity applies to another.

## Extension + local WebSocket controller instead of CDP — **Made**

`Runtime.enable` is the single clearest automation marker there is, and an
extension needs no debugging port at all. So the social reader is a private Chrome
extension driven by a local controller over a WebSocket:

```
  controller (on the VM)
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
        the social tab — sees none of the above
```

The controller listens and the browser dials out, because an extension can only
ever be a WS client. Nothing can reach into the extension from outside.

Accepted cost: scrolling from an extension emits no trusted `wheel`/`pointer`
events. Only CDP can forge those, which is the thing being avoided.

## Private, unlisted extension; no `web_accessible_resources`; no DOM writes — **Made**

- **Never published**, so the extension ID is not in the extension-ID scan lists
  sites maintain (38 IDs in 2017 → 6,167 by Feb 2026).
- **No `web_accessible_resources`** — Chrome then blocks `chrome-extension://`
  probes outright, so the ID cannot be confirmed even if guessed. Content scripts
  do not need the declaration.
- **No DOM modification**, and the content script runs in an isolated world, so a
  page's DOM-walking scan has nothing to find.

## Headful Chromium on Xvfb, no window manager — **Made**

Headful under Xvfb measures identically to real headed Chrome (CreepJS 0%/44%);
headless scores 67%/50%. `xauth` is part of the measured configuration; a window
manager is not.

## Openbox — **Rejected**

Folklore. No evidence any detector checks for a window manager, and the measured
good configuration does not include one. It was previously parked as "yes, with
phase 1" on the strength of `document.hasFocus()` returning false and Chromium
opening a small window on a 1920×1080 framebuffer — both real observations, but
the window-size half is fixed by pinning `--window-size` in the wrapper, and
`hasFocus()` alone does not justify a desktop environment on the box.

## Coherence over invisibility — **Made**

The goal is a normal browser being normal, not an invisible one. There is
deliberately **no** `--user-agent`, no `--disable-blink-features` and no
fingerprint-spoofing flag on `social-chromium`: a browser answering client hints
with blanks is rarer than one admitting it is automated.

Two incoherences were measured and fixed:

- **Timezone.** The box is UTC, which is right for a server and wrong for a
  browser claiming to be an Israeli account — LinkedIn read the clock and stored
  `timezone=UTC`. Fixed with `TZ` in the wrapper only, so system logs stay UTC.
- **WebGL was absent entirely** (`getContext('webgl')` → `null`), which is far
  louder than a datacenter IP. Fixed by routing ANGLE at Mesa/llvmpipe rather
  than SwiftShader, because "SwiftShader" is headless Chrome's historical calling
  card. `libgl1-mesa-dri` is now an explicit package for that reason.

Residual, accepted: `hardwareConcurrency: 2`, a software renderer (any GPU-less
VM has one), and no window manager.

## Run the browser locally, not on a hosted CDP service — **Made**

A hosted CDP service (e.g. Bright Data Scraping Browser) runs the browser in
vendor infrastructure, so the session cookie would live there. That cookie is
full account access and bypasses 2FA. Keeping it on hardware we control costs
roughly $7/mo more. Bandwidth was never the expensive part; the host is.

## Log in by hand on the box; never copy a cookie from the laptop — **Made**

Copying `li_at` from a laptop creates the session at one address and uses it from
another, which is one of the few IP-related transitions with real reports behind
it. `./run login` tunnels VNC to `x11vnc` on the box instead, so session creation
and use share an egress automatically.

Also measured: a cookie from a persistent profile is issued with a 364-day
expiry, against roughly an hour for one lifted from a fresh or incognito context.
So: never incognito, and never a fresh throwaway profile.

## No proxy, no exit-node egress, no residential IP — **Made**

This reverses an earlier plan to route social traffic over the home connection
via a Tailscale exit node on the router. It is not implemented and is not wanted
unless a challenge actually appears:

- The IP-stability premise is weakly evidenced and mostly vendor-driven (see the
  static-IP reversal in [infrastructure.md](infrastructure.md)).
- **Rotating** residential pools are actively harmful for an authenticated
  session — they are built for anonymous public scraping.
- The phone is the worst possible exit node: it roams (WiFi → LTE → CGNAT), Doze
  throttles sustained forwarding, and Tailscale exit nodes **fail closed**, so
  traffic stops when the phone wanders off rather than degrading.

If one is ever needed, the router is the sane choice: always on, never moves,
same residential address.

## No scheduled poller; read-only; randomised spacing — **Made**

Fixed-interval polling is itself a detection signal, and a round clock time is a
stronger signal than anything about the IP. Runs happen on demand, with
randomised spacing, and are **read-only**: no likes, comments, connects or
profile views.

Two consequences: nothing needs 24/7 uptime (so the VM can be paused, which is
also what covers cost), and notifications are not streamed to the phone for their
own sake.

## Block media via CDP to save bandwidth — **Superseded**

Made when the plan was to drive the social browser over CDP. The social browser
now has no CDP at all, and bandwidth was never the constraint. `--blink-settings=
imagesEnabled=false` is not a substitute: it is measurably not a memory saving
(523 vs 527 MB) and it changes the fingerprint.

## Thorium instead of Debian's Chromium — **Rejected**

Measurement killed the case: Debian's Chromium already reports H.264/AAC
`probably` and a normal Chrome UA. An unofficial GitHub `.deb` means no apt
security updates on the most attack-exposed program on the box, and rarity
*increases* fingerprint entropy.

## Meta (Facebook/Instagram) — **Parked**

Out of scope until LinkedIn has run cleanly for weeks. Accounts Center links the
two, so enforcement can cascade across both, and Meta is more aggressive about
automation. Adding a platform is a table row in `scripts/login-social.sh` plus
one in `scripts/social-session.py` — deliberately not done yet.

## Reading the wire, when it comes to that — **Made**

Notes that constrain the reader's implementation, recorded here so they are not
rediscovered:

- Start with notifications, not the feed:
  `voyagerIdentityDashNotificationCards` is verified working browserless, whereas
  the captured home-feed query ID (`voyagerFeedDashMainFeed`) has never been
  demonstrated executing.
- The feed is virtualised and recycles nodes, so harvest **during** the scroll —
  nothing is there afterwards.
- **Zero items parsed is an error**, never an empty feed. Silent breakage is the
  likely failure mode, not a dramatic ban.
- Status codes: `302 → /uas/login` is the only session-death signal; **`403`
  means a missing `csrf-token` header, not a ban**; `429` means slow down.
- If calling Voyager directly, echo `JSESSIONID` as the `csrf-token` header with
  quotes stripped.
- Response bodies cannot be read in MV3 (`declarativeNetRequest` and
  `webRequest` cannot see them, patching `window.fetch` means touching the page,
  and `chrome.debugger` *is* CDP), so DOM reading is accepted despite being
  fragile.

## ToS, stated plainly — **Made** (accepted risk)

LinkedIn's `robots.txt` is `Disallow: /` and the User Agreement prohibits
automation. *hiQ v. LinkedIn* concerned **public** data accessed **without**
logging in and does not cover this. Read-only access to one's own feed has no
reported enforcement precedent, but that is absence of evidence, not safety. The
realistic downside is account restriction — losing the network and history — not
litigation.
