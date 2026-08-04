# Decisions: browsers on the box

Everything about running a browser on the box. The logged-in social account —
the extension/controller architecture, how logins happen, the reader's read
constraints, the ToS exposure — lives with the app that owns it:
[`AceCodePt/linkedin-reader`](https://github.com/AceCodePt/linkedin-reader)
(`docs/decisions/browser-and-social.md` there).

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
  browser claiming to be an Israeli account — the site read the clock and stored
  `timezone=UTC`. Fixed with `TZ` in the wrapper only, so system logs stay UTC.
- **WebGL was absent entirely** (`getContext('webgl')` → `null`), which is far
  louder than a datacenter IP. Fixed by routing ANGLE at Mesa/llvmpipe rather
  than SwiftShader, because "SwiftShader" is headless Chrome's historical calling
  card. `libgl1-mesa-dri` is now an explicit package for that reason.

Residual, accepted: `hardwareConcurrency: 2`, a software renderer (any GPU-less
VM has one), and no window manager.

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
