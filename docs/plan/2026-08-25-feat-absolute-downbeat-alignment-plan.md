# feat: absolute-downbeat option for k-loop tracks (#201)

**Status:** Definition for plan-gate sign-off · **Date:** 2026-08-25 · **Type:** feature (engine + Dart settings/UI)

> Tracking: #201 (`stage:brainstorm`, P3, one line: "Absolute-downbeat option
> for k-loop tracks"). Verified against `master` @ `61609b35`.

## Current state (verified): multiples are relative, and only multiples

A track of multiple k plays segment
`(loop_iteration - start_iter) % k` of its k·base buffer
(`engine_process.c:3878`), with `start_iter` latched to the iteration its
recording began (`engine_process.c:1416`). That is **relative anchoring**:
playback reproduces the take exactly where it was played against the master
grid — record a 2-bar answer phrase one bar after a 2-bar call phrase and
they interlock forever, offset as performed. This is correct and must stay
the default.

Two facts complicate the one-liner, and both must shape the design:

**1. Sync/Band divisions are already absolute — deliberately.** A division's
read is `pos % trk_len` , "deliberately anchored to `pos`, not a running
iteration count … so a division track's own loop-top ALWAYS coincides with
the primary's" (`sync_division_positions_frame`, `engine_process.c:3755`).
The codebase already decided that a *shorter*-than-base loop snaps to the
shared grid unconditionally. #201 is the mirror question for
*longer*-than-base loops — so the option is not an alien concept, it is
symmetry.

**2. The relative anchor already does not survive anything.** Every path that
rebuilds a track zeroes `start_iter`: session load (`engine_session.c:94,255`),
stop-all/park restart ("Resetting each track's start_iter keeps multi-loop
tracks aligned", `engine_process.c:3211-3215`), redo-from-empty and
restore-clear (`engine_process.c:1934,1959`), engine reset. Today's product
behaviour is therefore **relative while you play, absolute after any
restart/reload/undo-restore** — the offsets a performer layered in are
silently collapsed by the first stop-all. Whatever the owner picks, the plan
must name this inconsistency as the thing being resolved, not preserved.

### A premise to kill: "absolute alignment is just a read-side tweak"

Reading `seg = loop_iteration % k` while keeping today's write path does not
"align" a take — it **rotates** it: the buffer's first-recorded lap would
land on the global cycle top instead of where it was played. That is a
defensible *musical* semantic (the phrase snaps so its bar 1 is the rig's
bar 1 — RC-505-style measure sync), but it is a different feature from
"preserve as-played placement across restarts", and conflating them is how
this issue would get built wrong. The design below keeps them distinct.

## The decisions for the owner

**D1 — which semantic is the option?** Two coherent candidates:

- **(a) Phrase-snap (recommended).** Absolute mode means: a k-loop take's
  phrase start is aligned to the global k-cycle top (`loop_iteration % k == 0`),
  rotating it from where it was recorded if needed. Predictable — every
  k-track shares bar 1, matching what the reset paths already produce — and
  it is the semantic the name "absolute downbeat" describes. Restart, reload
  and undo-restore become consistent with live play *for free*, because
  anchor-zero is exactly what those paths already do.
- **(b) Placement-preservation.** Keep relative live behaviour but persist
  `start_iter % k` through session save, stop-all and restore, so as-played
  offsets survive resets. More faithful to a performance, but it hardens the
  *current* live semantic rather than adding the requested option, touches
  the session format, and still leaves two k-tracks unable to share a
  downbeat on purpose. Not recommended as this issue; if the owner wants it,
  it is a separate issue against the reset paths.

**D2 — scope of the toggle.** Recommended: one per-rig setting
(`downbeat anchor: as played / bar 1`), default **as played** (ships
today's behaviour), living with the looper-mode settings
(`lib/looper/view/looper_mode_section.dart` territory), persisted like the
other loop settings and pushed to the engine as an atomic. Per-track flags
are more machinery than a P3 niche option earns, and mixing anchors within
one rig re-creates the confusion the option exists to remove. Applies to
Multi/Sync/Band multiples (`a_multiple > 1`) only — Free/Song tracks run
their own clocks (`free_track_positions_frame`) and have no shared grid to
be absolute against; divisions are already absolute.

**D3 — when the snap lands.** `seg_base` is recomputed every frame from
`loop_iteration`; changing the anchor mid-lap splices mid-position.
Recommended: latch the anchor change at a base-loop boundary — at finalize,
a take in absolute mode stores an anchor `start_iter - (start_iter % k)`
(≡ 0 mod k) that takes effect from the next wrap, so the first audible
difference is a lap-boundary content swap, the one place segment changes
already happen (`loop_iteration` only advances on wrap). Toggling the
setting with content playing re-anchors the same way. The alternative —
quantize *record start* to the k-cycle top so no rotation ever occurs — is
rejected: recording must start when pressed (the whole point of
`record_start = e->clock.position` seeding, `engine_process.c:1415`).

## Implementation outline

- **PR 1 — engine** (`autonomy:merge-gate`): `a_downbeat_anchor` mode atomic
  + FFI setter; finalize (`finalize_new_track`, the multiple leg at
  `engine_process.c:1009`) computes the anchored `start_iter` in absolute
  mode; the wrap-latched re-anchor for live toggles; native tests
  (see verification). No behaviour change with the setting off — the
  existing `seg` expression is untouched in relative mode.
- **PR 2 — engine, export parity** (`autonomy:auto`): `perf_render.c:635`
  documents that the offline render indexes
  `((loop_iteration - start_iter) % k)` to mirror live playback; teach it the
  anchored `start_iter` so a DAW export of an absolute-mode performance lays
  laps out as heard. A render/live divergence here is the highest-risk silent
  bug in this feature.
- **PR 3 — Dart** (`autonomy:merge-gate`): FFI surface, settings persistence,
  the toggle in the loop settings tray, and the pen: the control is a design
  change, so it goes into `segno-ui.pen` (geometry + `c/` note) per the
  design-source rule, not just the Flutter tree.

## Verification plan

- Native (`packages/segno_engine/src/test`): record a k=2 take starting at
  iteration 1 (odd) → absolute mode plays its first-recorded lap at even
  iterations only, from the first wrap after finalize; relative mode
  byte-identical to today (regression pin on the existing multi-loop tests);
  toggle-mid-play re-anchors only at a wrap (no mid-lap splice: assert the
  read position is continuous across the toggle frame); session save/load and
  restore-clear land on the same segment the absolute rule names.
- Render parity: capture a two-k-track performance in absolute mode; offline
  render equals the live mix capture lap-for-lap.
- Dart: settings round-trip; cubit/widget tests for the toggle; goldens
  regenerated + eyeballed (author-machine-only screenshot suite).

## Acceptance criteria

- With the option ON: every k-loop track's phrase start coincides with
  `loop_iteration % k == 0`; two k=2 takes recorded a bar apart share their
  downbeat; stop-all → play, session reload, and undo-of-clear all resume
  identically to live play (the current collapse-on-reset inconsistency is
  gone *because* live now matches the reset paths).
- With the option OFF (default): bit-identical playback to master today,
  proven by the existing engine suites plus the new regression pins.
- DAW export matches live playback in both modes.

## Non-goals

- No change to division anchoring (already absolute, already right).
- No per-track anchor choice; no Free/Song-mode behaviour change.
- No persistence of relative phase across resets (option (b) above — a
  separate issue if ever wanted).
- No record-start quantization.
