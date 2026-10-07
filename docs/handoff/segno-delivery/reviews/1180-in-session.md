Model: Claude Fable (subagent), in-session

# PR #1180 — feat(engine): peel the newest overdub layer as one history step

Branch `claude/peel-1164-p1` @ 53925d7f5, diffed against its base
31c4aafad (`git diff 31c4aafad...origin/claude/peel-1164-p1`). Trunk
`claude/segno-integration` has moved to c3714abc2; `git merge-tree` of the PR
head onto it produces a tree with no conflicts. Plan:
`docs/plan/2026-10-05-feat-foot-peel-plan.md` §1.1-1.7, Part 1.

## What I ran

| Check | Result |
| --- | --- |
| `run_native_tests.sh`, plain, own `TMPDIR` | ALL PASSED |
| `run_native_tests.sh`, `EXTRA_CFLAGS="-fsanitize=address -g"`, own `TMPDIR` | ALL PASSED |
| `leaks --atExit` on `segno_core_tests.exe` with `SEGNO_PEEL_TESTS_ONLY=1` | 1 leak, 640 B, in `test_history_staging_refusal_fails_stem_keeps_undo` (#1173's `le_restore_clear` -> `le_stage_source_image` path, which the gate still runs before the Peel tests). None from Peel. Matches the PR body. |
| `build_test_lib.sh` + `SEGNO_ENGINE_LIB` exported, `packages/looper_repository` `flutter test` | 799 passed; `peel_native_test.dart` loaded and ran (not skipped) |
| `dart analyze packages/segno_engine`, `dart analyze packages/looper_repository` (after `pub get`) | No issues |
| 6 mutations of my own (below) | all caught |
| 4 probe tests of my own (below) | one defect reproduced (finding 1) |

Probe code lives only in my worktree (`src/test/test_engine_peel_probe.h`, a
`LE_NATIVE_TESTS`-only hook in `le_engine_peel`); nothing committed or posted.

## Verified correct (traced)

- **Peel motion** (`le_peel_apply`): removing the LAYER at `idx`, shifting the
  `skipped` PEEL entries down one, writing `PEEL{former live, skipped}` at the
  top. Count unchanged; the former live slot moves onto the stack and the
  target slot comes off it, so every slot stays referenced exactly once.
  `fact.peel_log.slot` is read before the shift (correct).
- **Undo of a PEEL** (`le_undo_swap`): pop at `p`, insert `LAYER(live)` at
  `p - skipped`, publish the PEEL's slot live, push marker `{PEEL, -1, skipped}`.
  `idx = n-1-skipped = p - skipped`, so this is the exact inverse. Count returns
  to the pre-pop value, no overflow possible.
- **Redo of a marker**: re-derives the target with `le_peel_target`; between an
  undo and its redo no edit can touch the undo stack (every edit drops redo), so
  the re-derived `skipped` equals the original except after partial eviction,
  where the recomputed value is the correct one.
- **The `max(0, p - skipped)` clamp**: every eviction path removes the lowest
  non-CLEAR entry first (`track_select_slot` + `track_acquire_slot`,
  `le_prepare_image_punch_in`'s fallback loop, `le_restore_commit_layer` via
  `track_acquire_slot`); a PEEL's "run" (the `skipped` PEELs it names) is
  contiguous directly beneath it and stays contiguous under every stack
  mutation (peel shifts the prefix uniformly, undo-of-peel inserts below the
  whole run of the popped PEEL, which contains any sub-run, retires push on top,
  CLEAR pushes on top). So if any run entry is gone, everything below it is gone
  too and index 0 is the right place. The PR's eviction test leg 2 exercises
  exactly this; my mutation M1 (drop the clamp) is caught.
- **Original take**: `le_peel_target` stops at the deepest LAYER; that entry is
  the pre-first-overdub image and is swapped in, never consumed. Sixth peel in
  the worked example returns `LE_ERR_INVALID` with the original playing; stem
  parity test asserts the same after an armed capture. PROCESSED and CLEAR block
  the walk (`kind != LE_HIST_PEEL -> break`).
- **Slot uniqueness with markers**: redo marker slot -1 never matches
  `track_select_slot`'s `used` scan, `le_prepare_image_punch_in` reads the undo
  stack only, `le_layer_slot_for_ordinal` skips `slot < 0`,
  `le_engine_redo`'s EMPTY branch always sees a LAYER on top (undo-to-empty and
  take-cancel push LAYERs, and markers only come to the top once the track has
  content). Confirmed by probe: undo-to-empty through `[Pa, Pb(1)]`, then five
  redos climb `1.0, 1.5, 2.0, 1.5, 1.0` and rebuild `[Pa(0), Pb(1)]`.
- **Clear composition**: Clear over PEELs keeps them under the CLEAR point;
  undo-of-Clear then undo restores the last peel (PR test + my probe). Peel
  after a Clear restore drops the CLEAR redo entry (`le_clear_redo`), as every
  edit does. Redo-of-Clear (`le_clear_track`) drops markers with the branch.
  Fresh capture after undo-to-empty with markers on redo: redo dies (probe).
- **Admission**: refusals for `a_pending_launch`, `clear_restore_pending`,
  `cancel_pending`, RECORDING/OVERDUBBING, `a_layer_in_flight`, pending state
  command, all before any mutation (PR test snapshots the stacks). An armed
  quantized overdub is admitted like Undo; probe confirms the pass that fires
  afterwards retires the *peeled* image as its LAYER and history stays
  `[PEEL, LAYER, ...]` with correct undo behaviour.
- **Provenance (#1173)**: `le_peel_apply` stages via `le_stage_source_image`
  before `le_publish_live_image`, same shape as `le_undo_swap`; staging refusal
  never refuses the swap. `le_log_extract` copies 16 bytes of the union, and
  `peel_log` is exactly 16 bytes, so 325's payload survives the control-side
  push (the PR's fact test decodes it). 325 is pushed after the publish, 322 is
  the callback's; the parity test shows one 322 per swap with sequential ids.
- **Kind preservation**: `le_undo_swap` LAYER/PROCESSED keep the kind on redo;
  `le_engine_redo` re-files `top.kind`; `le_restore_clear` pushes the CLEAR
  entry whole; undo-to-empty / take-cancel file LAYER (correct: the base image).
  `le_restore_commit_layer` files PROCESSED; `le_peel_depth`/`le_peel_target`
  stop at it. Mutation (redo re-files LAYER) is caught by the PROCESSED test.
- **`a_peel_depth` publication**: every `a_undo_depth` store site now stores
  `a_peel_depth` beside it (`le_publish_undo_depth` x3, `le_engine_reset_material`,
  `le_reopen_drop_track`, `le_engine_finalize_layers`). Gates mirror
  `undo_depth` (0 while a frozen Clear point is pending or a content-giving
  command is in flight; CLEAR on top reads 0 by construction).
- **Reopen (#1158)**: `le_engine_reopen_file_retired` files late retires as
  LAYERs on top via `le_handle_retired`, correct chronology because Peel refuses
  while in flight; `a_peel_depth` reset in `le_reopen_drop_track` and
  `le_engine_reset_material`.
- **#1161 guard**: Peel acquires no slot and never empties a track; it never
  reaches `le_capture_prep_touches_pcm`/`empty_command`. The only shared code is
  `track_select_slot`, whose eviction comment now covers PEEL/PROCESSED.
- **`le_engine_history_mode_gate`**: only asks "is it CLEAR"; PEEL/PROCESSED and
  markers fall with LAYER (same-span). Undo-of-base check uses `undo_count == 0`,
  unaffected.
- **Export**: `le_layer_slot_for_ordinal` enumerates image-bearing entries; the
  removed `ordinal >= undo+1+redo` guard is replaced by `slot < 0 -> INVALID`,
  which is equivalent for undo-side entries (never negative) and the live slot.
  `le_engine_export_history` honours `max` (including 0 and `-1 -> INVALID`),
  returns the total.
- **Dart seam**: `peel` added to `AudioEngine`, native, mock (`invalid` when
  running, else `notRunning`), four fakes; `LooperRepository.peel` refuses with
  `notReady` while `_sessionAudioReserved` (native test proves it during
  `applySession`); `Track.canPeel`/`layers` as the plan specifies.
- Mutations I ran (each caught by the PR's Peel suite): M1 drop the clamp; M2
  undo-of-PEEL inserts at `p` (ignores `skipped`); M3 `le_peel_depth` counts
  PEELs; M4 `le_layer_slot_for_ordinal` stops skipping markers; M5
  `le_peel_apply` files `skipped = 0`; M6 redo-of-marker peels `undo_count-1`
  without re-deriving the target.

## Findings

### 1. `le_engine_peel` can act on a stale stack when the final retire lands between its drain and its flight check — Medium

- **Where**: `packages/segno_engine/src/core/engine_commands.c`,
  `le_engine_peel`: one `le_engine_drain_events` at the top, then the
  `a_layer_in_flight` acquire-load, then `le_peel_target`. Compare
  `le_engine_undo` (`:2496-2498`), which drains a second time after the flag
  reads 0, with the comment explaining why: the audio thread pushes the final
  retire event *before* clearing the flag, so a drain that ran before the push
  and a flag load that ran after the clear leaves the event in the ring.
  (`le_engine_redo` has the same single drain, harmlessly: a fresh pass
  empties the redo stack, so a stale stack there only yields `LE_ERR_INVALID`.)
- **Trigger**: Peel tapped right after a punch-out. The window is the few
  instructions between the drain's last pop and the acquire-load, so it is
  rare per tap but hit by exactly the gesture Peel is for (stop overdubbing,
  peel the pass). Reproduced deterministically with a test hook that runs the
  audio side between those two points (partial third pass so the retire is
  produced by the punch-out drain): result `rc=0, live=1.5`,
  stack `[LAYER, PEEL(partial 2.5), LAYER(2.0)]`; expected `live=2.0`,
  `[LAYER, LAYER, PEEL]`.
- **Impact**: the peel consumes the *previous* layer (two passes removed
  audibly instead of one), then the late retire files a LAYER on top of the
  PEEL, so the history is out of chronological order: the next Undo swaps the
  2.0 image in (not the peel back), and after undoing the PEEL the 1.5 image
  has migrated to the redo side as a plain LAYER. The 325 fact names the wrong
  `slot`/`previous` pair. Slot uniqueness is preserved (no buffer reuse while
  referenced), so no PCM corruption; this is a wrong-layer and
  history-ordering defect.
- **Smallest fix**: after the `a_layer_in_flight` check passes, add
  `le_engine_drain_events(engine);` before the pending-state-command check
  (the drain also applies queued undo taps, which is the right order). I
  applied exactly that line in my worktree: the probe passes and all 12 Peel
  tests stay green. A regression test needs a seam between the drain and the
  load (a `LE_NATIVE_TESTS` hook like `le_test_fade_hook`), or the
  single-thread emulation described above.

### 2. Session capture with a redo-side PEEL marker drops the lane; saved history flattens kinds — Medium, latent, gates Part 3

- **Where**: `packages/session_repository/lib/src/session_repository.dart:652-676`
  (`total = undoCount + 1 + redoCount`; an empty export `break`s and the lane is
  skipped: `if (layerPcm.length != total) continue;`),
  `engine_session.c` `le_layer_slot_for_ordinal` (marker skipped, so the last
  ordinal returns `LE_ERR_INVALID`), `le_engine_finalize_layers` (every rebuilt
  entry is LAYER).
- **Trigger**: Peel, then Undo, then any Session save/capture. Probe:
  `undo_depth=2 redo_depth=1`, 3 of the 4 ordinals the host asks for export.
- **Impact**: that lane is silently omitted from the saved session (a mono
  track loses all its audio). Separately, saving `[L0, PEEL(2.0)]` reloads as
  `[L0, LAYER(2.0)]` with live 1.5: a Peel after reload swaps the post-pass
  image in (adds a layer), Undo order is wrong, and a PROCESSED entry reloads
  as a peelable LAYER.
- **Mitigation present**: `LooperRepository.peel` has no caller outside tests,
  so the path is unreachable from the UI in Part 1; the PR body says so and
  Part 2 (`SessionLane.history`, `le_engine_finalize_history`) owns the fix.
- **Smallest fix / requirement**: none needed to merge Part 1 as unadvertised,
  but Part 3 must not land before Part 2. Record that ordering on #1164. If the
  owner wants no latent trap in between, the one-line guard is to have Session
  capture count image-bearing redo entries (`redoDepth` minus markers) — which
  is what Part 2's `history` list provides anyway.

### 3. The 325 fact's `generation` does not bind to the staged layer key after a Clear/restore cycle — Low

- **Where**: `le_engine_peel` sets `fact.peel_log.generation = t->dub_generation`;
  the doc row (`performance-event-log-format.md`) says a reader can bind the
  fact to the staged layer key `{channel, slot, generation}`.
- **Trigger**: `[L0, L1]` -> `clear_undoable` (`le_finish_clear` bumps
  `dub_generation`) -> Undo (restore) -> Peel. L1 was staged by
  `le_handle_retired` with the pre-Clear generation; the fact carries the new
  one.
- **Impact**: a reader following the documented binding misses. The renderer is
  unaffected because the image the callback mixes is named by its own 322
  (the image id), which the row also says.
- **Smallest fix**: say in the row that 322 is the authoritative image name and
  `generation` is informational (the engine does not track per-entry retire
  generations), or drop the binding sentence.

### 4. Code 325 enters the vocabulary under header version 6 — Low (plan deviation, owner call)

- **Where**: `perf_drain.c` `version = 6` unchanged; `perf_log_ring.h` adds
  `LE_PLOG_PEEL = 325`. The row says the bump to 7 "lands with whichever of
  the two merges second". The trunk has neither 324 nor 325 today, so this PR
  is first and ships a v6 file that can contain 325. Plan §1.6 says to bump.
- **Impact**: a v6 reader meets a code outside v6's vocabulary. Low because
  readers ignore unknown codes and the renderer does not consume 325.
- **Smallest fix**: bump to 7 here (first in) and let Reverse keep 7 at its
  rebase, or write the "v6 may carry 325" exception into the version table.

### 5. `Track.layers` now counts peelable layers only — Low, by design, worth knowing

- **Where**: `track.dart` `layers => peelDepth + (hasContent ? 1 : 0)`.
- **Trigger**: any non-overdub kind on top: `[L0, PROCESSED]` reads
  `peelDepth 0 -> layers 1` while the performer hears base + 1 pass
  (conditioned); future length-edit kinds will hide the layers beneath them
  the same way.
- **Impact**: none today (no Dart caller binds `le_engine_restore_track`;
  confirmed in `native_audio_engine.dart`). The plan §1.3 specifies this
  derivation, so it is a note for the badge's future semantics, not a defect.

### Notes (no action)

- Native `le_engine_peel` is admitted on an EMPTY, import-in-progress track
  (`finalize_layers` done, `commit_session` pending): same as `le_engine_undo`
  today; the repository's `_sessionAudioReserved` guard covers it and the PR's
  native Dart test exercises that guard.
- The test helper `peel_slots_unique` is only valid on a track with content:
  undo-to-empty keeps live == redo top by design (my probe hit this; the PR's
  tests never call it on an EMPTY track).
- `test_peel_refusals`' drain-window case proves the flag refusal, not the race
  in finding 1; it passes for the right reason but does not cover that window.
- The `leaks` 640 B is #1173's and pre-dates this branch.

## Verdict

**Request changes (one small fix), then mergeable.** The history-stack design
is sound: I traced the PEEL insert/remove and the eviction clamp under peel,
undo, redo, overdub, Clear, Clear-undo, Clear-redo, restoration commit, fresh
capture, undo-to-empty/redo-from-empty and pool eviction, and slot references
stay unique in every case; the original take is structurally unreachable; the
suite is strong (all six of my mutations were caught). The one defect is
finding 1: `le_engine_peel` needs the second `le_engine_drain_events` that
`le_engine_undo` already has after the flight flag reads 0, or a Peel tapped
right after a punch-out can remove two layers and file history out of order.
Finding 2 is a documented Part 1 limitation that must be closed by Part 2
before Part 3 exposes Peel; findings 3-5 are documentation and owner calls.
