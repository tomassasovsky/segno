Model: Claude Fable 5.1 (subagent, extra-high effort), in-session; no earlier Claude verdict exists for this packet
Base: 6646086a5be2e7c9135b4f01fd0464e316154082  Head: 659792cafed98f341b208f42353a12b0f2b29e4c  (PR #1120, shared Count-in cohort)

## Verdict

Not mergeable as-is. Two introduced defects need a fix; both have small corrections. The native scheduler itself (bounded table, insertion order, per-member images, commit-before-start, one-drain grace) holds up under the paths I traced; the defects are at the control boundary.

## Introduced defects

### 1. Medium: Rec Stop can finalize a just-launched defining take into a near-zero master
- `packages/segno_engine/src/core/engine_commands.c:2276-2301` and `engine_process.c:2551-2563`.
- Control side encodes two intents as the same `action = 0`: "cancel the cohort" (when `cohort` = `a_counting_in` or any `a_launch_grace` reads 1) and "finish an unquantized capture now". On apply, `le_cancel_count_in` returning 0 falls through to a synthesized `LE_CMD_RECORD`.
- Trigger: control thread reads `a_counting_in`/`a_launch_grace` as set (2284-2286), is preempted, and `le_push` (2296) lands after the drain that follows the commit (`le_engine_process` clears `launch_grace` right after that drain, engine_process.c:5826-5829). The grace is one block (~2.7 ms at 128/48k); the read-to-push span on the Dart FFI thread only has to straddle that boundary.
- Impact: `handle_record` on the RECORDING defining take → `request_master_finalize` → `finalize_master` with `len = record_pos` (one or two blocks; `engine_process.c:837` clamps to >= 1). A tiny master is defined and tempo is derived from it. This is exactly the outcome the plan forbids ("must not manufacture a tiny master"). Pre-PR, `_recStop` never attempted a cancel during count-in and the old `FINALIZE_TAKE` route refused the defining take, so this is new.
- Smallest correction: in `le_engine_stop_record_control`, when `cohort` is nonzero push `LE_CMD_CANCEL_COUNT_IN` (already exists) instead of `STOP_RECORD_CONTROL(0)`; a late landing then degrades to a no-op (capture survives, next Stop finishes it with Record timing). Equivalently give the cancel intent its own `arg_f` code and `break` on apply when nothing was canceled.
- Not covered by tests: `test_shared_count_in_stop_intents_do_not_acquire` only exercises a control read taken after the grace closed. Reproducing needs a seam between the atomic read and the push (the existing `le_test_record_timing_hook` pattern would do).

### 2. Medium: Mute-mode Rec/Play consumes `parkedResume` for launches that have not happened
- `lib/control/cubit/control_cubit.dart:1820-1852` (`_muteRecPlay` parked branch) with `1919-1922` (`_parkAllAccepted`).
- The branch mutes deselected members, calls `play()` per resume member, then emits `parkedResume: {}` with the comment "the resumed tracks are now sounding". Under this PR a parked `play()` is a deferred launch (engine_process.c `handle_play` → `le_launch_defer`), so nothing is sounding and `isParked` stays true.
- Trigger A: second Rec/Play press during the countdown with at least one deselected member. `parkedResume` is empty, so `resume` becomes every playable track; `setMute(false)` unmutes the deselected track and `play()` on it joins the cohort, while `play()` on the selected members routes to `cancelArm` (looper_repository.dart:3216-3224) and cancels them. Net result at the downbeat: the deselected track plays, the selected ones stay stopped. Inverse of the gesture.
- Trigger B: Stop during the countdown. `_parkAllAccepted` cancels the cohort and returns with "keep the parked resume set", but the set was already emptied, so the next Rec/Play resumes and unmutes everything; the deselection is lost. Pre-PR the set was re-latched from `_running()` because the plays were immediate.
- Smallest correction: do not clear `parkedResume` at press time; clear it when the projection first observes a resume member running (or, in the parked branch, treat `tracks[c].pendingLaunch != null` for any resume member as "cancel the cohort" and return without re-deriving `resume`).

## Low / notes (introduced)

- FX entry (`control_cubit.dart:1702`) now returns early on the first refused `cancelArm` after `_invalidateGestures()` (1656) already ran, leaving a half-applied transition with no feedback. The refusal path (`le_push` → ring full or `!a_configured`) is rare and "refused cancellation keeps transport controls" is the stated design, so this is a note, not a blocker. Consider moving `_invalidateGestures()` after the sweep.
- `_parkAllAccepted` now reports Stop as accepted on an idle rig (`_acceptedContacts`), a small LED/feedback change not mentioned in the plan.
- `LE_PLOG_RECORD_ABORT` is logged only on the DISARM cancel path (engine_process.c:2677-2679). Cancellation through `STOP_RECORD_CONTROL`, `CANCEL_COUNT_IN`, repeat press, `handle_stop`, `CANCEL_TAKE` and clear log nothing for a retired Record member. Observability asymmetry only.
- `segno_engine_api.h:1872` still documents `le_engine_cancel_arm` as "No-op (LE_OK) when the track is not armed"; it now always pushes a DISARM (and so costs a ring slot per call; FX entry spends eight).
- Test naming: `test_shared_count_in_metric_capacity_and_grace_stop` checks `le_engine_record(e, 8) == LE_ERR_INVALID`, which is the channel bounds check, not table capacity (the table is sized by `LE_MAX_TRACKS` so capacity cannot actually be exceeded). Harmless but overclaims.

## Unverified hypotheses

- perf_render.c:1231 clears `cut_silenced` on `LE_CMD_PLAY`, which is logged at press time while the actual start is deferred (or never happens if canceled). After a Cut Sound, an export render may un-silence a track `count_in_total` frames early. I did not trace what `cut_silenced` gates, so impact is unconfirmed.
- The Song/Band "section" policy in `le_count_in_commit` (engine_process.c:3936-3966: last non-primary member wins, others masked from unpark and forced STOPPED) is new engine-side policy. I could not confirm from the packet where immediate-path Song/Band exclusivity lives (the immediate `handle_play` unparks every stopped track), so I cannot say whether count-in and immediate launches agree in those modes.

## Pre-existing / out of scope

- `LE_CMD_SET_RECORD_START` (engine_process.c:3094) resets the whole cohort on any accepted count-in edit, same value included.
- The one-block grace window is inherently narrow for a polled controller; the old design had the same limit. Finding 1 is about the fall-through, not the window.
- `handle_record`'s `initial == LE_TRACK_PLAYING` deferral branch is dead (`le_transport_held` excludes PLAYING).
- Punch-in dub shadows posted by control for an overdub member are not reclaimed on cancel; identical to the existing DISARM behaviour for quantized arms.

## What holds up (traced)

- Deferral only when `le_transport_held`; sound-start fires (`a_record_start < 0`) and grid fires (transport active) never defer; Band section arms firing at a loop top do not defer. Count-in on an empty rig is retained.
- Commit zeroes `launch_action` before `le_count_in_reset` so member images survive to `le_apply_capture_image`; `close_active_capture` retires an earlier fresh member via `apply_undo_to_empty` only under `launch_committing && launch_grace == 1`, so no zero-length layer or master.
- Cancel paths (`le_record_impl` cancel-only RECORD, `le_engine_play` → DISARM, `le_engine_undo` → DISARM) are safe when they land late: no-op or cancellation-only.
- Repository settlement reads `commandsSettled` before `snapshot()`; FIFO ordering makes the "earlier unpolled launch" cancellation sound.
- FFI parity: `le_track_snapshot` gains two trailing int32 fields; bindings match; both new exports are wired in `NativeAudioEngine`, `MockAudioEngine` and the fakes.

## Scope and limits

Read the whole diff and head/before copies of every changed file, plus `handle_record`/`handle_play`/`handle_stop`/`close_active_capture`/`le_count_in_commit`/drain ordering, `le_classify_record`/`le_record_impl`/`le_post_record_image`, `le_engine_toggle_section`, snapshot fill, `perf_render` PLAY handling, and the cubit paths `setMode`, `_recStop`, `_parkAllAccepted`, `_muteRecPlay`, `_recAdvance`. Did not read vendor code, did not build or run anything, and make no hardware or CI claim. Native real-engine Dart tests depend on `SEGNO_ENGINE_LIB`, which `main.yaml:341` does export.
