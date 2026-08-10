# Decisions

Every settled question lives here, with its reasoning and its status. Nothing
else in the repo should re-argue one: `README.md` documents how to operate the
machine, `SPEC.md` states the goals and the current state, `TASK.md` lists work
that is still open, `docs/capabilities.md` maps command ↔ script ↔ flow,
`docs/operating.md` is the operator's manual, and `docs/measurements.md` holds
the evidence these decisions were made from.

If a decision changes, edit it here and change its status. Do not leave two
answers to the same question in two files — that is how this repo previously
ended up asserting both "static IP, for session stability" and "no static IP,
the premise is unevidenced".

## Status vocabulary

| Status | Meaning |
|---|---|
| **Made** | In force. The code reflects it. |
| **Rejected** | Considered, deliberately not done. |
| **Reversed** | Implemented, then undone. Recorded so it is not re-implemented from memory. |
| **Superseded** | Was in force; a later decision replaced it. |
| **Parked** | Deliberately not decided yet, with the condition that would unblock it. |

## Index

### [infrastructure.md](infrastructure.md) — the box and how it is built

| Decision | Status |
|---|---|
| Native VM, not a container on COS | Made |
| Debian 12 from Google's image family, not Arch | Made |
| Oracle Linux 9 from OCI platform images, not a custom Arch image | Made |
| Tailscale-only access, dedicated VPC, IAP as break-glass | Made (GCP path; Hetzner uses empty-rule firewall + console/rescue) |
| Separate persistent data disk at `/mnt/data` | Made |
| Two-phase boot | Made |
| One-off auth keys minted per build, validated before apply | Made |
| Node.js from the vendor apt repo, not a curl-to-shell install | Superseded |
| `config.env` as the single source of truth; no direnv | Made |
| zram compressed swap — kept | Made |
| Stay on GCP for now | Superseded |
| Static external IP | Reversed |
| Right-sizing the box | Parked |
| Provider migration | Made (Hetzner CX33, 2026-08-05) |

### [browser.md](browser.md) — the browser on the box

| Decision | Status |
|---|---|
| One wrapper (`headed-chromium`); the app brings its own if it has an account | Made |
| Headful Chromium on Xvfb, no window manager | Made |
| Software WebGL routed at Mesa, not SwiftShader | Made |
| No fingerprint-spoofing flags | Made |
| Openbox | Rejected |
| Thorium instead of Debian's Chromium | Rejected |
| Block media to save bandwidth | Superseded |

Anything tied to a **logged-in account** — a real session, the extension and
controller that drive it, fingerprint coherence for one identity, the ToS
exposure — belongs to the app that owns the account, not here. See
[`AceCodePt/linkedin-reader`](https://github.com/AceCodePt/linkedin-reader).
This repo only builds the box the browser runs on.

### [history.md](history.md) — superseded architecture

Where the project started and why it moved: container-on-COS → native VM, Arch
→ Debian. Kept only so the same ground is not re-walked.

---

Agent-layer decisions (the runner, per-client isolation, sizing, the phone
approval loop) moved with the agent layer to
[`~/stuff/phone-approval`](../../../phone-approval/docs/decisions/README.md).
