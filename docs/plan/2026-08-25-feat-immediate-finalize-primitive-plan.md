---
title: "feat(engine): immediate finalize primitive — FX-mode entry can end a live take (A5)"
type: feat
date: 2026-08-25
issue: 405
---

# The immediate-finalize primitive (#405) — and what "off-grid" actually means

Issue #405 records, correctly, why A5's "entering FX finalizes a live
capture" was withdrawn three times: the only tool the app has is a record
press, and `le_engine_record` gives a press three different meanings
(quantize-arm, cancel-someone's-arm, or *start* a capture when parked —
pinned by `test_record_press_on_pending_arm_starts_when_parked`). The missing
piece is an engine primitive that finalizes **now**, unconditionally, in the
shape of `le_engine_cancel_arm` (`engine_commands.c:1228`). This plan defines
that primitive and makes the musical call the issue defers.

## Current state, verified

- `ControlCubit.setMode`'s FX case (`lib/control/cubit/control_cubit.dart:505-528`)
  cancels every pending arm via `LooperRepository.cancelArm` and documents
  the withdrawal inline (`:467-475`): "A finalize that ignores quantize
  needs an engine primitive that does not exist yet." The pinned contract is
  `test/control/control_cubit_test.dart`'s "entering FX mode leaves a LIVE
  capture running…".
- `le_engine_record`'s control-side branches (`engine_commands.c:675` on)
  are exactly the three wrong meanings: the auto-record arm-toggle, the
  quantize deferral, and the parked-transport immediate path that *starts*
  captures. None of them is "end this take, now, regardless".
- The audio-thread finalize machinery is already unconditional once reached:
  `finalize_master` / `finalize_new_track` (`engine_process.c:562`, `:783`)
  run when the RECORD command applies against a RECORDING track.

## The musical premise to kill

The issue frames option 1 as "immediate **off-grid** finalize", worse than
letting the take run to the boundary. For a **non-defining** take that
framing is wrong: `finalize_new_track` never produces an off-grid length.
With no forced multiple it rounds **up** to whole base loops —
`k = (record_pos + base - 1) / base`, `le_track_set_len(t, k * base)` — and
the unfilled remainder `[record_pos, len)` is the digital silence
`le_prepare_new_capture` wrote, with the stopped-early seam treatment (#730)
already applied to that exact case. An immediate finalize is precisely what
a quantize-off record press does today: the take stays a whole number of
bars; what is "lost" is only the tail of the bar the player chose not to
finish. The grid is never desynced.

The framing is *right* for one case: the **defining** take (no master yet).
There, finalize-at-the-press *sets* the grid to whatever length the player
happened to reach mid-gesture — a mode switch silently deciding the session's
bar length. That case, not quantize, is where the danger lives.

## Decisions for the owner

### Decision 1 — what FX entry does to a live take

- **Option a (recommended): finalize non-defining takes immediately; leave a
  defining take running.** Non-defining: the primitive fires, the take ends
  on-grid (rounded up, silence-padded, #730-smoothed) and plays — the A5
  intent, with none of the feared grid damage. Defining: the primitive
  refuses (`LE_ERR_INVALID`-class), the cubit falls back to today's
  documented "capture survives into FX" behaviour — a mode switch must not
  be the gesture that defines the session's grid.
- **Option b: keep today's behaviour wholesale** (A5 satisfied by the arm
  cancel alone). Honest, already shipped — but it leaves the real problem:
  a forgotten take grows toward `max_loop_frames` in a mode whose transport
  is entirely inert, and ending it requires cycling modes while it still
  records.
- **Option c: refuse the mode change while capturing, with plate feedback.**
  Punishes the *performer's* most time-critical gesture (reaching for FX
  mid-take) to protect an edge case; also breaks the "mode toggle is a view
  change" rule that Mute entry established.

**Recommendation: option a.** It is Mute-parity where parity is safe (the
defining take) and A5 where A5 is safe (everything else).

### Decision 2 — primitive scope: RECORDING only, or OVERDUBBING too

- **Option a (recommended): RECORDING only.** The A5 problem is unbounded
  growth; an overdub is bounded and cycling, and already survives Mute
  identically. Punch-out-on-FX-entry would end a layer the player may be
  deliberately letting ride under FX manipulation.
- **Option b: also punch out a live overdub.** More "everything settles on
  FX entry", but it changes an intentional performance texture, and pending
  punch-out *arms* are already cancelled by the existing sweep.

**Recommendation: option a**, with the API shaped so OVERDUBBING support is
an added case, not a redesign.

### Decision 3 — the count-in edge

A take mid count-in has captured nothing (`record_pos == 0`). The primitive
should end it via the existing void path — which now correctly logs
`LE_PLOG_RECORD_ABORT` (#816) and returns the track to EMPTY. Confirm at
build time that count-in state is cleanly cancellable there; if it needs its
own teardown, that belongs inside the primitive, not in the cubit.

## Implementation outline

Two PRs:

1. **PR 1 — engine primitive** (`autonomy:auto`):
   - `le_engine_finalize_take(le_engine*, int32_t channel)` in
     `engine_commands.c`, exported in `segno_engine_api.h` next to
     `le_engine_cancel_arm` and documented against it (cancel_arm kills the
     *pending*; this kills the *live*).
   - Control-side: the standard configured/channel guards +
     `le_engine_drain_events`; refuse unless effective state is RECORDING
     (decision 2a) and the take is non-defining (decision 1a — the same
     "does anything else hold the grid" question `le_grid_still_needed`
     already answers for `le_engine_record`); then post the finalize the
     immediate path posts — skipping the quantize deferral, the auto-record
     arm toggle, and the shared `armed[]`/`armed_trigger[]` machinery
     entirely, so it can neither arm nor cancel anyone else's arm.
   - No new audio-thread code: the applied command reaches
     `finalize_new_track` exactly as a quantize-off press does.
   - ffigen regen in-PR for the new export.
2. **PR 2 — app wiring** (`autonomy:auto`; the behaviour change is
   test-pinned, not taste):
   - `AudioEngine`/`NativeAudioEngine` → `LooperRepository.finalizeTake` →
     `ControlCubit.setMode`'s FX case: after the arm sweep, call it for each
     track whose live state is recording; refusals are silently accepted
     (that *is* the defining-take fallback).
   - Rewrite the withdrawal comment (`control_cubit.dart:467-475`) into the
     new contract; flip the pinned test.

## Verification plan

- Native (`run_native_tests.sh` + ASAN):
  - quantize ON, master present, transport active → finalize happens **at
    the call frame**, not the loop top; length = rounded-up whole multiple;
    no arm left pending.
  - a *different* pending arm on the channel → untouched (the B3b
    cross-command interference class).
  - parked transport / EMPTY / PLAYING → refused, nothing starts (the exact
    counter-case to `test_record_press_on_pending_arm_starts_when_parked`).
  - defining take → refused, capture still live.
  - mid count-in → track back to EMPTY, `RECORD_ABORT` logged, never a
    `RECORD_END` (the #264/#819 invariant).
- Dart: `control_cubit_test.dart` — FX entry finalizes a live non-defining
  take, leaves a defining take running, still cancels arms; `flutter test`,
  `dart analyze`, `bloc lint`.
- Mutation check: route the primitive through `le_engine_record` instead —
  the quantize-ON test must fail (it would arm, not finalize).

## Acceptance criteria

- The primitive exists with cancel_arm's shape and refusal semantics; FX
  entry ends every live non-defining take on-grid at the entry gesture.
- Today's three wrong meanings are provably not reachable through it (the
  three native counter-tests above).
- The `control_cubit.dart` withdrawal prose is replaced by the shipped
  contract; issue closed by PR 2 (`Closes #405`).

## Non-goals

- FX-mode transport controls (Rec/Play/Stop/Undo stay inert in FX — that is
  the console-UI epic's territory, #442).
- Overdub punch-out on FX entry (decision 2; add later if wanted).
- Any change to Mute-entry semantics, the D-GUARD windows, or quantize
  behaviour outside this primitive.
