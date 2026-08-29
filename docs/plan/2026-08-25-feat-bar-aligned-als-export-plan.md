---
title: "feat: bar-aligned .als clips + musical-grid performance export (D2 follow-up)"
type: feat
date: 2026-08-25
issue: 279
index: 2026-07-22-feat-tempo-aware-looper-modes-plan.md
---

# Bar-aligned `.als` export — putting the grid into clip placement (#279)

A7 (#280) made `.als` export carry the session's **real tempo**. Nothing else
about the export is musical: every position is wall-clock seconds converted to
beats by pure unit arithmetic, so Live's bar grid and the performance's actual
downbeats coincide only by luck. This plan defines what "bar-aligned" concretely
means for this exporter, the one hard prerequisite, and the decisions that
gate the build.

## Current state, verified

- `packages/daw_export/lib/src/manifest_reader.dart` reads
  `performance.json` + `events.log` directly (own-input-model rule, its file
  doc) and builds a `DawProject` whose positions are all **seconds**:
  `DawArrangementClip.startSeconds`/`lengthSeconds`,
  `DawSessionClip.lengthSeconds` (`daw_project.dart:163-213`).
- `als_builder.dart` converts seconds → Ableton beat time with
  `secondsToBeats(seconds, tempoBpm)` (`:193`, `:466`) at a **single** tempo
  threaded from `Session.tempoBpm` (fallback 120). Warp is off. The tempo
  affects only the unit conversion — no downbeat, no bar phase, no
  time-signature anywhere in the builder.
- Session clips are placeholders in two ways the code itself documents: each
  lane clip's `lengthSeconds` is **the whole capture's length**, not the
  lane's loop length ("a fixed reference to the capture length is a
  placeholder", `manifest_reader.dart:~128`), and no loop-start offset
  exists, so a loop that entered the capture mid-phase round-trips into Live
  starting at the wrong beat of itself.
- The capture records **no grid facts at all**: the audited `events.log`
  vocabulary (`docs/design/performance-event-log-format.md`) has record/
  length/layer/FX facts, but `LE_CMD_SET_TEMPO`/`TAP_TEMPO`/
  `SET_TIME_SIGNATURE` are not in it. Today that is sound — tempo is
  **locked** while any track has content and a grid exists
  (`segno_engine_api.h:186-189`) — but Phase D2 (#263 remainder plan)
  relaxes exactly that lock, so "one capture, one tempo" has a scheduled
  expiry date.
- The mapping from capture frames to *grid phase* is the render-anchor
  problem: capture frame 0's loop-clock position exists today only as the
  race-stale `armSnapshot.clockFrame` (#262). Exact bar alignment is
  impossible while that anchor is inexact — the whole timeline would be
  offset by the arm latency.

## Kill one framing early

"Bar-align the clips" must **not** mean "move audio until it lands on a bar
line." The performance happened when it happened; a stem shifted to the
nearest bar is a different performance. Alignment here means: compute where
the grid's downbeats actually fall on the capture timeline, express the
timeline in Live so that **Live's bar grid coincides with the session's
downbeats**, and give looping clips the loop-start offsets that preserve
their true phase. Audio positions never move; the *grid* moves to the truth.

## Decisions for the owner

### Decision 1 — prerequisite ordering (#262 first?)

- **Option a (recommended): land the `LE_PLOG_PERF_ARMED` fact first**
  (`2026-08-25-fix-render-anchor-facts-plan.md`, PR 1). It gives the
  exporter capture-frame-0's exact loop position + master length + loop
  iteration; downbeat math becomes
  `downbeat_offset = (bar_frames - (arm_position % bar_frames)) % bar_frames`
  with `LOOP_LENGTH_LOCKED` facts handling every in-capture redefinition.
- **Option b: build on `armSnapshot.clockFrame` now.** Alignment inherits an
  unbounded, per-capture error the user reads as "the export is off by a
  bit, sometimes" — the worst kind of defect to ship in a feature whose
  whole point is exactness.

**Recommendation: option a.** This issue stays blocked on #262's PR 1 and
should say so on the board.

### Decision 2 — single-tempo now, tempo-timeline when D2 forces it

- **Option a (recommended): single-tempo export, asserted.** The engine's
  tempo lock makes a content-bearing capture single-tempo today. Export at
  `Session.tempoBpm`, and have the reader *verify* the assumption is legal
  (grid present, `tempoSource != none`) rather than silently exporting a
  120-BPM grid over gridless content — a gridless capture keeps today's
  wall-clock export unchanged. When D2 relaxes the lock it must add tempo
  facts to `events.log` (that requirement is written into the #263
  remainder plan); this exporter then grows a tempo-automation/warp story
  in a follow-up.
- **Option b: design the tempo-timeline now.** Speculative — it builds the
  multi-tempo machinery before any engine path can produce multi-tempo data,
  against AGENTS.md's simplest-implementation rule.

**Recommendation: option a.**

### Decision 3 — how alignment is expressed in the `.als`

- **Option a (recommended): leading silence offset.** Place the whole
  arrangement so capture frame 0 sits at its true beat position *within* bar
  1..2 — i.e. start the timeline at Live's bar 1 minus the downbeat offset
  (equivalently: shift every clip by `downbeat_offset` beats and let bar 1
  land on the first downbeat). Simple, uses only `CurrentStart`/`CurrentEnd`
  the builder already writes, degrades to today's output when the offset is
  zero.
- **Option b: warp markers.** Strictly more expressive (survives decision
  2's future tempo timeline) but a much bigger `als_builder` surface, and
  warp-on changes how Live treats the audio by default. Not needed while
  captures are single-tempo.

**Recommendation: option a**, with option b named as the D2-era successor.

### Decision 4 — session-clip completion (the placeholder debt)

Bar-aligning session clips requires fixing what they lack today anyway:
real per-lane loop lengths (the manifest's lane entries already carry
`lengthFrames` — the reader just doesn't use them) and a loop-start offset
(the take's phase — `le_pr_record_end_phase`'s value, which after #262/#819
is derivable from facts). **Recommendation:** fold both into this issue; it
is the same code, and "session clip loops musically" *is* this issue's
promise. Live-side: emit clip `LoopStart`/`LoopEnd`/`StartRelative` so a
mid-phase loop plays from its true beat.

## Implementation outline

All Dart, all in `packages/daw_export` (+ its caller threading one more
argument); no engine change beyond what #262 already lands. Two PRs:

1. **PR 1 — the grid model + arrangement alignment** (`autonomy:auto`):
   - New `GridMap` in `daw_export`: built from the PERF_ARMED fact +
     `LOOP_LENGTH_LOCKED` entries + session tempo/time-signature; converts
     capture frame ↔ beat position, exposes `downbeatOffsetBeats`.
   - `manifest_reader.dart` threads it; `als_builder.dart` places
     arrangement clips at fact-derived beats (decision 3a) instead of
     `secondsToBeats(startSeconds)`; automation breakpoint times go through
     the same map (they are seconds→beats conversions today, `:336`, `:360`).
   - Gridless captures bypass the map entirely — byte-identical output to
     today (the invisibility gate, in miniature).
2. **PR 2 — session-clip truth** (`autonomy:auto`):
   - Lane clips use the manifest's real `lengthFrames`; loop-start offsets
     from the take-phase facts; `LoopStart`/`LoopEnd`/`StartRelative`
     emitted. Deletes the documented placeholder comment.

Time-signature source: `Session` carries the signature in v4; thread it
beside `tempoBpm` through `DawManifestReader.read` the same way.

## Verification plan

- `flutter test packages/daw_export` — the package's existing tests already
  do independent beat-math assertions (`secondsToBeats` is exposed for
  exactly that); new tests:
  - a capture armed mid-bar: first downbeat lands on a Live bar line
    (assert on `CurrentStart` values, hand-computed);
  - a mid-capture `LOOP_LENGTH_LOCKED` redefinition: beats after the lock
    use the new grid;
  - gridless capture: output byte-identical to the pre-change golden;
  - a lane recorded mid-phase: `StartRelative` reproduces the phase.
- Manual gate (merge-gate on the *feature*, not the PRs): open an exported
  `.als` in Ableton, confirm the metronome and the performance's downbeats
  coincide and session clips loop in phase.
- `dart analyze`, `bloc lint`, full `flutter test`.

## Acceptance criteria

- With a grid present, every arrangement clip and automation breakpoint sits
  at its true musical position and bar 1 of Live is a session downbeat.
- Session clips carry real lengths and phase-correct loop points; the
  placeholder comment is gone.
- Gridless/legacy captures export exactly as today.
- `Closes #279` on the final PR.

## Non-goals

- Multi-tempo captures, warp markers, tempo automation (post-D2 follow-up,
  per decision 2).
- Re-exporting old bundles; changing the stem renderer (that is #262/#819's
  plan); #281 (persisting capture-time tempo for reExport) — adjacent, not
  here.
- Any DAW format other than `.als`.
