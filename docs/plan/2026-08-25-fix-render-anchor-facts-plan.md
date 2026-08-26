---
title: "fix(render): explicit anchors — the PERF_ARM transport fact (#262) and the disarm-image take identity (#819)"
type: fix
date: 2026-08-25
issue: 262
---

# Render anchoring: replace two inferences with two facts (#262 + #819)

One design, two issues. The performance render places audio on the capture
timeline using **two inferred anchors**, and both inferences are wrong in the
same way: the data that would make them exact exists in the engine at a
precise audio-thread instant, and the capture simply never records it.

- **#262** — the arm-image anchor. `perf_render.c` anchors a track that was
  already playing at arm time at `armSnapshot.clockFrame`, indexing
  `(clockFrame + f) % image_len` (`le_pr_render_track`, the arm-image
  segment). But `clockFrame` is sampled **control-side** —
  `PerformanceRepository.arm()` reads `snapshot.masterPositionFrames`
  (`packages/performance_repository/lib/src/performance_repository.dart:304`)
  — *before* lane WAV export and manifest I/O, while capture frame 0 begins
  only when `LE_CMD_PERF_ARM` reaches the audio thread
  (`engine_process.c:2514`), an unbounded I/O gap later. The renderer's own
  comment marks this "KNOWN RESIDUAL (#262) … render-side, this is as good
  as the data gets."
- **#819** — the disarm-image anchor. The same function places
  `disarmSnapshot`'s lane-0 image at "the **first** `LE_PLOG_RECORD_END` on
  this channel while `build.has_content` is still false" — ordinal position
  plus a content flag, not an identity. #816 made the rule *currently* true
  by routing void takes to `LE_PLOG_RECORD_ABORT`, but any future finalize
  path that logs an END before content exists re-breaks #264 silently.

Fixing them together is right because they are the same shape: an
engine-side fact logged at the exact audio-thread frame, versioned into
`events.log` / `performance.json`, preferred by the renderer over the
inference.

## Killing one premise first

Issue #819 says "`perf_drain.c` writes it at disarm." **It does not.**
`disarmSnapshot` is written Dart-side: `PerformanceRepository._finalizeArmed`
builds it from `_captureSettledLanes` (`performance_repository.dart:404-411`,
`:900-966`), which reads the engine snapshot and exports each settled lane's
PCM via `_engine.exportTrackLane`. `perf_drain.c` writes `events.log`, the
master/monitor rings, and layer segments — never the manifest. The
consequence is real, not pedantic: **the take identity must cross the FFI
boundary** (engine → `le_snapshot` → Dart → `performance.json`), it cannot be
written by the drain thread as the issue implies. That determines the seams
below.

## Current state, verified

- `LE_CMD_PERF_ARM`'s audio-thread application (`engine_process.c:2514`) is
  zero-payload: reset callback telemetry, set `e->perf.armed = 1`, store the
  atomic. Nothing is logged; the loop clock's position at that instant —
  `e->clock.position`, sitting right there — is discarded.
- The event-log vocabulary is versioned (`docs/design/performance-event-log-format.md`,
  header `version`, currently `2`; the doc's own table shows version 1→2 was
  exactly this kind of vocabulary change, for #264).
- `le_pr_record_end_phase` (`perf_render.c:600-680`) already reconstructs a
  fresh take's phase from `RECORD_START` + `LOOP_LENGTH_LOCKED` facts, and
  falls back to `arm_clock_frame` when no lock happened inside the capture —
  so #262's staleness contaminates the RECORD_END phase math too, not just
  the arm image. One fact fixes both consumers.
- The perf-log entry payload is `le_command` (`perf_log_ring.h`), whose `fx`
  arm carries four `int32`s — room for a fact carrying more than
  `arg_i`/`arg_f`.
- The mid-capture transport hold (`engine_process.c:3213`: playback with
  nothing active pins `clock.position = 0`) is unlogged — the sibling
  unlogged-phase-reset #262's issue text flags.

## Decisions for the owner

### Decision A — what the PERF_ARM fact carries (#262)

A new transport fact, `LE_PLOG_PERF_ARMED` (315), pushed inside the
`LE_CMD_PERF_ARM` case at the capture's frame 0.

- **Option a — position only** (`arg_i = clock.position`). Fixes the arm
  image's rotation. Leaves the multi-loop sub-cycle ambiguity (#260) and a
  master-length change in the arm gap unrepresented.
- **Option b — position + master length + loop iteration (recommended),**
  via the `fx` arm's four ints (or two adjacent generic entries if that
  reads better in the format doc). Same cost, and it retires the #260
  sub-cycle ambiguity and the stale `masterLenFrames` in one move — the
  renderer then needs *nothing* from `armSnapshot` for phase math.

**Recommendation: option b.**

### Decision B — whether to log the transport hold

- **Option a — log it (recommended):** a `LE_PLOG_TRANSPORT_HELD` fact when
  the hold pins the clock, so the renderer's phase math can't silently run a
  clock the engine had frozen. Cheap, and it closes the last unlogged
  phase-reset.
- **Option b — defer.** Defensible only if renders never span a
  hold-then-resume; nothing guarantees that.

### Decision C — the take identity (#819)

- **Option a — monotonic per-channel take id (recommended).** Engine keeps a
  per-track counter bumped at each `RECORD_START`; `RECORD_END` logs it
  (move 301's payload to a two-int arm: channel + take id); `le_snapshot`
  exposes each track's *settled take id*; `_captureSettledLanes` writes it
  on the lane-0 entry as `takeId`; `le_pr_render_track` anchors the disarm
  image at the `RECORD_END` whose id matches. Identity survives any future
  finalize path by construction.
- **Option b — finalize frame as the identity.** No counter, but it is still
  a *rendezvous by value*: Dart must read "the frame lane 0 last finalized
  at" from the snapshot, and two ends at the same frame (channel-adjacent
  edge cases) collapse. Weaker for no real saving.

**Recommendation: option a.**

### Decision D — compatibility posture

`AGENTS.md` is explicit: no compatibility layers, fallbacks, or migrations.
But #262's issue text asks that "old captures without it must keep rendering
(fallback to clockFrame)."

- **Option a — follow AGENTS.md (recommended):** bump `events.log` header to
  version 3; the renderer *requires* the PERF_ARMED fact and the take id and
  the `!has_content` proxy is deleted, not kept as a fallback. Pre-upgrade
  unfinalized captures (the only old data the renderer ever revisits, via
  D-SALVAGE) render as well as they ever did only if re-captured; that is
  the documented one-time cost.
- **Option b — versioned fallback:** keep the clockFrame anchor and the
  first-END scan for version-2 files. Preserves salvage of old captures at
  the price of keeping the exact heuristic #819 exists to kill, forever
  testable in two forms.

**Recommendation: option a** — the format doc's version table records the
semantics change, same as version 1→2 did.

## Implementation outline

Two PRs, both `autonomy:auto` (engine + renderer, mutation-provable, narrow):

1. **PR 1 — the PERF_ARMED fact (#262):**
   - `perf_log_ring.h`: `LE_PLOG_PERF_ARMED = 315` (+ `TRANSPORT_HELD = 316`
     under decision B-a); `engine_process.c`: push at the `LE_CMD_PERF_ARM`
     case and at the hold site (`:3213`); bump the events.log header version;
     update `docs/design/performance-event-log-format.md`'s audited table.
   - `perf_render.c`: prefer the fact over `arm_clock_frame`/`arm_master_len`
     in both consumers (`le_pr_render_track`'s arm segment,
     `le_pr_record_end_phase`'s no-lock branch); delete the KNOWN RESIDUAL
     comment.
2. **PR 2 — the take identity (#819):**
   - Engine: per-track take counter; `RECORD_END` payload gains the id;
     `le_snapshot` exposes the settled take id per track (**ffigen regen
     in-PR** — the B3 heap-overflow lesson).
   - Dart: `_captureSettledLanes` writes `takeId`;
     `performance_manifest.dart` round-trips it;
     `docs/design/performance-manifest-format.md` documents it
     (presence-keyed, like the FX stages).
   - Renderer: anchor on the matching id; delete the first-END scan and the
     `!build.has_content` gate; retire the carve-out prose on 301's
     declaration.

PR 1 lands first — PR 2's fixture wants the format-version bump already in.

## Verification plan

- Native suite (`run_native_tests.sh`) + ASAN. New fixtures:
  - **#262:** arm mid-loop against a playing track with a deliberate delay
    between snapshot read and `LE_CMD_PERF_ARM` application; assert the stem
    is *not* rotated by the delay (fails against `clockFrame`, passes
    against the fact). Force the gap the way
    `test(engine): force the alloc-watch zero-fill gap` (#828) forces its
    race — deterministically, not by sleeping.
  - **#819:** the issue's own acceptance fixture — a capture where the first
    `RECORD_END` on a content-free channel is **not** the take the disarm
    image belongs to (e.g. finalize, clear, re-record within one capture)
    must render the image at the second END's frame.
- Dart: manifest round-trip tests in `performance_repository`; `dart analyze`;
  `bloc lint`.
- Mutation checks: revert the renderer to `arg_i`-from-armSnapshot / to the
  first-END scan one at a time; the new fixtures must be the tests that fail.

## Acceptance criteria

- `events.log` header version 3; `LE_PLOG_PERF_ARMED` in the audited table;
  renderer phase math consumes it in both branches.
- `performance.json` lane-0 entries carry `takeId`; the disarm image anchors
  by identity; `!build.has_content` no longer exists in `perf_render.c`.
- The #264-class regression (an END before content) is impossible by
  construction, and the fixture proving it is in the suite.
- Both issues closed by their PRs (`Closes #262` / `Closes #819`).

## Non-goals

- Re-rendering or migrating existing capture bundles.
- The #279 musical-grid export (it *consumes* the PERF_ARMED fact; planned in
  `2026-08-25-feat-bar-aligned-als-export-plan.md`).
- Any change to arm/disarm UX, D-GUARD windows, or the drain thread's
  ring/budget design.
