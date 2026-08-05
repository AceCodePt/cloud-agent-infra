# Decisions: the browser on the box

Everything about running a browser on the box. There is exactly **one** wrapper,
`headed-chromium`, and this repo knows nothing about logged-in accounts: anything
account-shaped (a real session, an extension, fingerprint coherence for a
specific identity) is deployed by the app that owns it — e.g.
[`AceCodePt/linkedin-reader`](https://github.com/AceCodePt/linkedin-reader).

Measurements behind these are in [`../measurements.md`](../measurements.md).

---

## One wrapper, and the app brings its own — **Made**

`headed-chromium` is a real headed Chromium on the virtual display with CDP and a
persistent profile, for driving apps in a browser that must not be headless:

| | `headed-chromium` |
|---|---|
| For | driving apps in a real, unheadlessable browser |
| CDP | yes, `CDP_PORT` (default 9222) |
| Profile | `BROWSER_PROFILE_DIR`, default `/mnt/data/browser/default` |

This replaced a two-wrapper split (`headed-chromium` + a `social-chromium` that
refused CDP). The split was real and the reasoning still holds — **a browser with
a real account logged into it is a different problem from a browser testing our
own apps**, and conflating them is how a session gets burned — but it belongs to
whichever app owns the account, not to the infrastructure. `linkedin-reader`
deploys its own no-CDP wrapper and its own profile.

What stays here: the display, the browser binary, the software-GL configuration,
and `x11vnc` for hand access. Profiles live under `/mnt/data/browser/`, one
directory each, so nothing learned about one identity applies to another.

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

## Software WebGL, routed at Mesa rather than SwiftShader — **Made**

Measured: `getContext('webgl')` returned `null`, because Chrome 136+ refuses
software WebGL unless told otherwise and this box has no GPU. An absent WebGL
context is far louder than a datacenter IP. Fixed by routing ANGLE at
Mesa/llvmpipe rather than SwiftShader, because "SwiftShader" is headless Chrome's
historical calling card. `libgl1-mesa-dri` is an explicit package for that
reason, even though chromium pulls it in — a fingerprint-relevant dependency
should not be left implicit.

Residual, accepted: `hardwareConcurrency: 2` and a software renderer (any
GPU-less VM has one).

## No fingerprint-spoofing flags — **Made**

The goal is a normal browser being normal, not an invisible one. There is
deliberately **no** `--user-agent`, no `--disable-blink-features` beyond
`AutomationControlled`, and no spoofing flag: a browser answering client hints
with blanks is rarer than one admitting it is automated. An app that needs
coherence for a *specific identity* (a timezone matching the account's history,
say) sets that in its own wrapper, where the identity is known.

## Thorium instead of Debian's Chromium — **Rejected**

Measurement killed the case: Debian's Chromium already reports H.264/AAC
`probably` and a normal Chrome UA. An unofficial GitHub `.deb` means no apt
security updates on the most attack-exposed program on the box, and rarity
*increases* fingerprint entropy.

## Block media to save bandwidth — **Superseded**

Made when the plan was to drive a browser over CDP for scraping. Bandwidth was
never the constraint. `--blink-settings=imagesEnabled=false` is not a substitute
either: it is measurably not a memory saving (523 vs 527 MB) and it changes the
fingerprint.
