# TASK

Open, actionable work only. Nothing here explains *why* — reasoning lives in
[`docs/decisions/`](docs/decisions/), evidence in
[`docs/measurements.md`](docs/measurements.md), state of the world in `SPEC.md`.

**Ordering rule:** the priority column in `SPEC.md` decides what gets worked on,
not whichever question is most tractable. Goal 4 is primary and has the least
built.

The LinkedIn reader — a real account, the extension/controller, feed harvesting —
is the first app this infra will host and lives in its own repo,
[`AceCodePt/linkedin-reader`](https://github.com/AceCodePt/linkedin-reader). It is
not tracked here.

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
