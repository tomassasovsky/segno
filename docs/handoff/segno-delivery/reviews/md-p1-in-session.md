Model: Claude Opus (subagent), in-session

# Review of PR #1212: feat(engine): double or halve a track as one recoverable length edit

## Scope

- Branch `origin/claude/multiply-divide-1168-p1` at `4b26f6189`, issue #1168.
- The M/D work is the single commit `4b26f6189` on top of the merge `9af5746b0`.
  The merge-base with `origin/claude/peel-1164-p2` is `15ec99e6d`, so everything between that base and `9af5746b0` is Peel P2 plus trunk, which is reviewed separately.
  This review covers `git diff 9af5746b0 4b26f6189`: 35 files, +2663/-47.
- Reviewed against:
  - plan `docs/plan/2026-10-05-feat-foot-multiply-divide-plan.md`, identical to `origin/claude/multiply-divide-plan-1168` apart from the Part 1 build notes and one cspell word;
  - `accepted-behavior.md`: section 2.7-2.11 and the section 4 Multiply / Divide row at line 304;
  - AGENTS.md;
  - the owner rules.
- Pen section 16: Part 1 ships no surface (no mode, no assignment, no caller of `editLength` in `lib/`), so no screen is affected. I tried twice to read the 8 screens through the pencil MCP, and the whole-document visitor was interrupted both times. Checking them against the surface belongs to the Part 3 review.
- Speed interaction was checked against PR #1201 (`origin/claude/pitch-time-1179-p2a` at `aa99ecc3f`).

## Runs

All runs were made in a detached worktree at `4b26f6189`.

| Run | Result |
|---|---|
| `run_native_tests.sh`, 3 runs, separate TMPDIR each | ALL PASSED x3, exit 0. All 13 `test_length_*` cases ran. |
| TSAN races (`NATIVE_TESTS_ONLY=races CC=clang EXTRA_CFLAGS="-fsanitize=thread -g"`) | exit 0, 0 failures. This binary only races telemetry and the plugin runtime, so it does not exercise length edits. |
| Extra threaded probe of my own, TSAN build of the full engine (`-fsanitize=thread`) | 0 reports over 6 trials. A paced audio thread runs `le_engine_process` while the control thread records two tracks, admits a Double, waits for the receipt, Undoes and compares the images. |
| `SEGNO_ENGINE_LIB` from `build_test_lib.sh` | built |
| segno_engine | +373, all passed |
| looper_repository | +808, all passed. `length_native_test.dart` ran against the real library: 2/2 passed. |
| session_repository | +129, all passed |
| `dart analyze` on segno_engine, looper_repository, session_repository, performance_repository and `test/helpers` | No issues found |

Probes:
- `grid.c` uses the public API through the test dylib.
- `seaminterleave.c` uses `engine_private.h` and replays one interleaving deterministically.

## Verified correct (traced)

- **Verdict shared by admission and callback.** `le_length_fit_check` (engine_core.h) is called by control through `le_length_fit_ctl`, using effective states and `le_rig_effective_master_len`. It is called by the callback (engine_process.c:3377-3418) with raw `a_state` and `e->clock.length`. The callback refuses unless multiple, divisor and reclock all match the payload.
  - Ring order makes the two views agree in both directions: a sibling Clear or Restore posted before the edit has already applied when the edit drains.
  - The division read uses `clock.length / n` (engine_process.c `sync_division_positions_frame`). That is the same base the verdict uses, and `le_mode_span_fits` guarantees `base % len == 0` for n = 2 or 4, so a division the edit creates tiles exactly.
- **Real-time safety of the callback half.** `le_length_apply` allocates nothing and takes no lock. It does O(lanes) atomic stores, one O(tracks) loop and wait-free plog pushes. `sync_grid_to_loop` already runs on the audio thread at every finalize.
  - The one audio-side `a_live` store is fenced by `length_pending`. Every control-side motion on the track refuses while it is set: undo, redo, record, Clear, Peel, the history gate and `le_restore_commit_layer` (tested).
  - Image, length, multiple or divisor and master change in one drain before any frame is mixed.
- **Image building on the control thread.** The new slot is outside live, both stacks and `outstanding`, so the callback cannot name it while it is built. Slot growth happens off the audio thread.
  - Exception: see M1. The source read is not gated against the trailing seam fold.
- **Playhead map.**
  - `(i - start) mod len` with the inverse `-start` stored for Undo is exact for both halves and for Double.
  - The segment re-derivation of `start_iter` keeps a k-track on its segment grid, with origin 0 in the zero-offset case.
  - The origin is re-derived through `le_direction_origin` after the clock moves, so a reversed track or a Once relaunch keeps reading on.
  - A division needs nothing because `pos % len` already equals the mapped index.
  - Tests cover a k=4 track in segments 1 and 3, reversed Double and First half, STOPPED, and Free odd halves.
- **Seam folds.** `le_seam_fold_head` is one body shared by finalize, the dub-shadow twin and both halves.
  - First half folds from `old[half, half+F)`. Last half folds from the already folded head `old[0, F)`, which is the true continuation of `old[L-1]`.
  - The bounds hold: `half >= 2F` implies `half + F <= L`.
  - `test_length_fold_48k` checks the result bit-exact at blocks of 1, 127 and 512.
- **History.**
  - The LENGTH entry is filed only after the ack, read through `a_length_result` with release on `a_state_acks` and acquire on the read.
  - A fresh edit runs `le_clear_redo`.
  - Undo and Redo ride the same command and move the replaced image to the other stack.
  - Peel stops at LENGTH: `le_peel_depth` breaks on any kind other than LAYER or PEEL.
  - A queued Undo never posts from the drain.
  - `le_hist_len_at` gives each exported image its own length. `export_layer` now refuses a slot shorter than the entry.
  - `finalize_history` and the Dart decoder refuse kind 4.
- **Outstanding-shadow deviation.** This is sound:
  - shadows are replenished only while a layer is in flight or recording, and admission excludes both;
  - so `outstanding` holds only idle armed shadows plus the pin;
  - the callback drops the armed shadows before the ack, so `outstanding_count = 0` on acceptance is exact;
  - a refusal releases only the pin, and only for op 0.
- **Deviation with no `LE_EVT_LENGTH_RESULT`.** This is sound and better than an event: the ack cannot be lost to a full event ring, and only one length command per track can be in flight.
- **Deviation where the entry carries `len`/`start` instead of `master_len`.** This is sound. A track that is the sole content always re-clocks with k = 1, so Undo and Redo re-derive the master from the entry through the same verdict. With siblings, the base is never moved. `test_length_history_gate` covers refusal after a sibling is recorded and success after it is cleared.
- **Undo across mode changes.** Each Undo or Redo re-runs the verdict in the current mode:
  - Free/Song re-times `free_clock`;
  - shared modes fit against the live base.
  The mode switch itself re-derives every multiple and divisor from lengths (`le_apply_mode_switch`), so a LENGTH entry made in Free and undone in Multi, or the reverse, lands on a consistent clock.
- **Reopen.** `le_engine_reopen_file_retired` collects an applied but unfiled edit before `reset_runtime` zeroes `length_pending`. An unapplied edit is a pending state command, so its track falls under the reopen drop rule.
- **Fade and Reverse.** The Fade envelope is untouched by the edit (tested). The direction is preserved, and the Reverse turn window is snapped (`turn_left = 0`).

## Findings

### Medium

**M1. A Double or half admitted during a sibling take's trailing seam capture can publish an image with the unfolded head, and it reads the live slot while the callback writes it.**

Where:
- engine_commands.c:2960-3007: `le_engine_edit_length` builds the image at :2999 through `le_length_build`.
- engine_commands.c:2856: `le_length_busy`.
- engine_process.c:3388-3392: the callback recheck.

How it happens:
- The seam fold of a non-defining take runs on the audio thread at the frame where `seam_capture` reaches 0 (engine_process.c:6383-6393). That is up to F = 10 ms after the track already reads PLAYING.
- Admission does not exclude this window. `le_length_busy` cannot see `seam_capture`, which is local to the audio thread. The engine already has the right gate for control-side reads of live PCM, `le_cache_source_readable` (engine_cache.c:606), which excludes `seam_capture`, `xfade_capture`, `od_gain` and in-flight layers. M/D does not use it.
- The callback only checks `seam_capture == 0` when it drains the command. If the control-side memcpy overlaps the block in which the fold runs, and the push lands after that block's drain, the next drain sees `seam_capture == 0` and accepts a stale image.

Reproduced deterministically by replaying that interleaving (`seaminterleave.c`). The setup is the `test_length_callback_refusals` fixture: a 1000-frame master and a 1000-frame sibling finalized at the top.
1. Step to `seam_capture == 1`.
2. Admit a Double (`rc 0`).
3. Hold the SET_LENGTH command off the ring for the one-frame block that folds.
4. Push it back.

Results:
- `verdict=0 len=2000`;
- the fold changed 470 head frames;
- the doubled image differs from the folded take in 470 frames, in both copies.

Effect:
- The #728 seam click is baked into the edited image at every wrap until it is undone.
- In the threaded build it is also a C data race: control `memcpy` against callback `le_seam_fold` on the same floats.

Reachability: an edit within about 10 ms of a take that finishes exactly on its cycle boundary, which is the normal Sync/Band capture end. That is unlikely by foot, but plausible from an assigned MIDI or CTRL action, or a scripted sequence.

Suggested fix:
- At admission, read `a_audio_rev` (acquire) before the build and carry it in the payload. In the callback, refuse with NOT_READY when `t->a_audio_rev` differs. The fold bumps `a_audio_rev` (engine_process.c:6393); this is the `[B5]` rule `le_restore_commit_layer` uses.
- Or also gate admission on `le_cache_source_readable`.
- Pin it with the hold-the-command interleave above as a native test.

**M2. When a sole track's halving re-clocks the rig, the beat grid stops matching the tempo whenever the result is not a whole number of bars.**

Where: engine_process.c:2732 (`sync_grid_to_loop(e, len)` inside `le_length_apply`) and `sync_grid_to_loop` at :638-666. `le_grid_bars_for_loop` rounds with a floor of 1 bar, and the grid then spreads `bars * num` beats over the loop.

Measured through the public API (`grid.c`: 48 kHz, sync tempo on, tempo 120, one track):

| Recorded | Half (master) | loop_bars | tempo | Beat changes over the original loop's wall time |
|---|---|---|---|---|
| 1 bar | 48000 | 1 | 120 | 9, was 5: the click and grid run at 2x |
| 3 bars | 144000 | 2 | 120 | 17, was 13: about 160 BPM equivalent |
| 2 bars | 96000 | 1 | 120 | correct |

Effect:
- The displayed tempo stays 120 while the click, `current_beat` and every later quantized capture run at another rate.
- MIDI clock send keeps 120 against a half-bar loop.
- Undo restores the grid.

Why it matters:
- This contradicts "Pitch/speed unchanged" and the plan's own premise ("bars halve or double at the unchanged tempo", 1.4).
- It is silent, against owner rule 3.
- "Record one bar, keep half" is the most likely first use.

Suggested fix: when a grid exists (`a_loop_bars > 0` and the tempo source is not NONE) and `len` is not a whole number of bars at the current tempo, refuse the re-clock with `LE_ERR_MODE_MISMATCH` at both admission and the recheck, so it is visible as "incompatible length". Or carry the grid forward as fractional beats, which is a larger change. This also feeds the owner question the plan already flags, about whether a sole track's halving should re-clock at all. Add a native test for a 1-bar and a 3-bar halving with sync on.

### Low

**L1. During a pending re-clock, other tracks' history decisions measure the stale master.**

Where: engine_commands.c:591-604 (`le_rig_effective_master_len` returns the wire whenever it is above 0) and the history gate at :2286.

Before this PR, nothing changed a nonzero master through a pending command. Now a pending sole-content re-clock does.

Scenario in Multi:
1. A and B are both M long. B is cleared with Undo available.
2. Double A: B is EMPTY, so A re-clocks to 2M.
3. Within the same block, Undo B. The gate passes because base M fits len M.
4. The callback applies A's re-clock, then `RESTORE_CLEAR(B)`. `le_restore_multiple_or_divisor(B, 2M, M)` publishes divisor 2 in MULTI.

Result: a half-span track plays in Multi, which section 2.9 forbids. Reads stay in bounds because the division path is not gated by mode.

The window is one audio block.

Fix: either have `le_rig_effective_master_len` prefer any track's pending `length_pending` with `pending_master_len > 0`, or make `le_engine_history_mode_gate` return NOT_READY while any track has a pending re-clock.

**L2. A callback refusal of an Undo or Redo of a LENGTH entry is silent.**

Where: engine_commands.c:3014-3030 (`le_length_history` posts with no receipt), and 3040-3046 (`le_length_collect` refusal just returns).

`le_engine_undo` and `le_engine_redo` return LE_OK at the post. If the recheck then refuses, the stacks are unchanged and no notice is given. For example, an immediate Record on an EMPTY sibling posted just before turns a re-clocking Undo into "others", and the payload mismatches.

This goes against the plan's decision 7 ("every refusal is a notice") and owner rule 3.

Fix: give history motions a receipt or a published refusal counter that the repository turns into a `RecoveryRefusal`. Or document it as the accepted race, as for undo-to-empty, and test it.

**L3. Queued Undo taps that reach a LENGTH entry are dropped.**

Where: engine_commands.c:642, then `queued_undo = 0` at the end of `le_apply_queued_undo`.

A double tap during an overdub drain removes the pass and swallows the second tap without a notice, although LE_OK was already returned. This matches the existing "empty now, further queued taps are no-ops" precedent and the plan. It is listed so Part 3 surfaces it, for example by flashing Undo, rather than leaving it silent by foot.

**L4. A refusal can still mutate history.**

Where: engine_commands.c:2997-2999. `track_acquire_slot` may evict the bottom history entry before `le_length_build` can fail on OOM and return LE_ERR_INVALID. That breaks the success criterion "every refusal ... mutates nothing" on that path.

Fix: select the slot without evicting (`track_select_slot`) until the build succeeds. Or document that this path is OOM-only.

## Notes

- **Collision with Speed, PR #1201.** #1201 removes `playback_offset`/`reversed` and `engine_direction.h` in favour of `le_read_head` (a double origin and rate) and `le_track_song_position` (an unbounded position over `start_iter` and `free_iteration`).
  - `le_length_apply` will not compile on top of it.
  - Whichever lands second must port the map onto it, in this order:
    1. index through `le_head_index`;
    2. clock and `start_iter`;
    3. `le_head_origin` at the new song position.
  - That port must add an edit and its Undo at rate 2 and 1/2, since the current tests only cover rate 1.
  - Free/Song leaves `free_iteration` alone. That is fine because the origin is re-derived after the clock moves, so keep that order in the port.
- **events.log version.** The writer stamps 9 (perf_drain.c:826). If M/D lands before Speed, a v9 file claims knowledge of the v8 facts. No reader gates on the version, so this is cosmetic. Renumber at landing, as the builder notes.
- **Session save path.** While Part 2 is absent, a save of a track holding a LENGTH entry would write a bundle the strict decoder rejects. That track can only exist through `LooperRepository.editLength`, which has no caller in `lib/`. Part 3 must not land before Part 2.
- **Base used by the verdict.** The verdict measures shared spans against `clock.length`, which matches the read model. The mode-switch gate (`le_ctl_mode_base`) uses the shortest take in Multi, and the two can differ after a first take is cleared. That divergence predates this PR. The edit can create Multi rigs the mode-switch gate would call non-fitting, for example by halving one of two doubled tracks, but nothing reads that predicate while the mode is unchanged.
- **Undo exactness after a re-clock.** Undo after a sibling is recorded is not exact: the master stays and the track becomes k = 2. This is the correct reading of "reject incompatible mode lengths rather than alter other tracks", and it is tested.
- **Judgement on the recorded deviations.**
  - All five are acceptable: version 9 (with the renumber note), no result event, `len`/`start` in the entry, dub shadows not refused, and the decoder refusing kind 4.
  - Missing from the deviation list: the callback recheck omits the plan's `dub_slot < 0`. This is covered by `od_gain == 0`, `a_layer_in_flight` and the armed-shadow drop.
- **Test quality.** The tests are strong: positional PCM, three block sizes, exact images, stacks read directly and refusals checked unmutated. Gaps:
  - M1 has no test;
  - re-clock with sync tempo on and odd bar counts has no test (M2);
  - no Band-mode case;
  - no test of an edit with a pending sibling restore (L1).

Verdict: Request changes (M1, M2).

## Delta review (1baf012b1)

### Scope

- Head `1baf012b1`. It sits on `78c5c717f`, which merges the trunk with Peel P2.
- This delta covers the fix commit, `git diff 78c5c717f 1baf012b1` (9 files, +350/-69).

### Runs

All runs were made in a fresh worktree at `1baf012b1`.

| Run | Result |
|---|---|
| `run_native_tests.sh`, 3 runs, separate TMPDIR each | ALL PASSED x3. The 4 new length tests ran. |
| TSAN races binary | exit 0 |
| segno_engine | +378, all passed |
| looper_repository | +809, all passed, including `length_native_test` against the real library |
| session_repository | +189, all passed |
| App suite, after `flutter gen-l10n` | +3323, ~202 skipped, all passed. The first attempt failed only because a fresh worktree has no `lib/l10n/gen`. |

### Each finding

- **M1: fixed.**
  - Admission now returns NOT_READY unless the callback's end-of-block `a_cache_source_readable` holds. That flag excludes seam capture, xfade capture, `od_gain`, a layer in flight, a pending record and a launch.
  - The payload carries the `a_audio_rev` read before the build. The callback refuses on a mismatch, and the seam fold bumps that revision (engine_process.c:6393).
  - `test_length_seam_race` replays my interleaving: hold the command across the fold block, then push it.
    - The edit is now refused with NOT_READY.
    - The pin is released and the history is unchanged.
    - A later Double carries the folded head in both copies.
  - Undo and Redo carry the revision too, harmlessly, since they copy no PCM.
- **M2: fixed as specified. The product judgement is below.**
  - `le_length_fit_check` now takes `a_loop_bars`. A re-clock is accepted only when `bars * len / base` lands within one frame of a whole bar count. The grid is then restored exactly through `le_restore_musical_grid(fit.bars)`; tempo is never re-derived.
  - My `grid.c` probe cases now give:
    - half of 1 or 3 bars: refused with MODE_MISMATCH;
    - half of 2 bars: 1 bar at 120 BPM;
    - Double of 1 or 2 bars: accepted.
  - `test_length_reclock_keeps_tempo` covers 1, 2 and 3 bars, Undo, and Double.
  - Undo of an accepted halving always passes the bar check, because the restored length is a whole multiple of the new base.
- **L1: fixed.** `le_rig_effective_master_len` now returns a posted, unacknowledged re-clock's master first. `test_length_pending_reclock_master` proves that B's Clear-undo in the window is refused with MODE_MISMATCH and that A's re-clock lands.
- **L4: fixed.**
  - `track_select_slot` (pure) runs first, then every lane's buffer is `calloc`ed, and only then does `track_acquire_slot` evict.
  - Selection and acquisition are the same pure function of unchanged state, so the "selection differs" branch cannot fire.
  - No test covers this, since the engine has no allocation-failure seam. Acceptable.
- **L2 and L3: deferred to Part 3, recorded in the plan.** I accept the deferral because Part 1 has no surface. `test_length_refused_history_motion` pins L2's behaviour: the history stays exact, and the next tap meets the verdict at admission. Part 3 must flash Undo for both cases, as the plan note says.
- **Speed port note: correct.**
  - Order: old index through `le_head_index`, then clock and `start_iter`, then `le_head_origin` at the new song position.
  - The port must add tests at rates 2 and 1/2.

### New observation (Low)

**DL1. An Undo of a re-clocking edit can be refused after a tempo re-grid.**
- `regrid_surviving_master` (on SET_TEMPO while the tempo is unlocked) can change `a_loop_bars` without changing the length.
- Example: a 1-bar loop is doubled to 2 bars, then a tempo change re-grids it to 1 bar. Undo of the Double now needs half a bar and is refused with MODE_MISMATCH.
- The image is still on the stack, so setting the tempo back makes it reachable again. This only matters if the tempo is unlocked while content exists.
- Worth one line in the Part 3 notice copy. No change is needed now.

### Key product check: refusing Divide on a 1-bar (or 3-bar) sole loop

What the sources say:
- **Accepted behaviour, section 4 row (line 304).** "Double repeats its material; direct First half or Last half retains that region ... Pitch/speed unchanged ... Reject incompatible mode lengths rather than alter other tracks."
  - The rejection clause is about mode compatibility with other tracks.
  - A sole loop has no other track, and halving it at the same tempo changes neither pitch nor speed.
  - So nothing in the row asks for this refusal.
- **Pen section 16 ("Current study · proposal", 8 screens).**
  - Screens 04 and 05 show Track 1 at "1 bar" with First half labelled "Beats 1–2" and Last half labelled "Beats 3–4" as live, available pedal captions.
  - Screen 06 shows Track 5 at "3 bars" with halves labelled "Beats 1–6" and "Beats 7–12".
  - The only blocked states drawn are an empty loop (07) and recording in progress (08). No incompatible-length state is drawn.
  - The design therefore expects a 1-bar or 3-bar Divide to work, and it already names the result in beats.
- **Defaults.** Sync tempo is on by default (engine.c:1163, and `_syncTempo = true` in the repository). With the current fix, "record one bar, Divide" on a fresh rig is refused, and the length tests had to turn sync tempo off. That is the most common first use, and the screens draw it as working.

Recommendation:
- Carry the grid in whole beats instead of refusing.
  - A sole-loop re-clock keeps the tempo and sets the beat count over the new length:
    - 4 beats → 2 beats;
    - 12 beats → 6 beats.
  - Refuse only a fractional beat count, as an incompatible length. Examples: half of 1 bar of 3/4 (1.5 beats), or half of a 1-beat loop.
  - The engine already counts beats over the loop (`grid_total_beats`, `le_grid_beat_at`). Integer `a_loop_bars` stays as the display and Session field, and sub-bar loops would need `a_loop_beats` or a fractional-bar presentation:
    - display ("2 beats", as the pen labels it);
    - Session `loopBars`;
    - count-in;
    - MIDI clock.
  - This is real work, so it belongs before Part 3 exposes the mode, not in Part 1.
- The current refusal is fail-safe and visible (MODE_MISMATCH, which becomes the incompatible-length notice). It is therefore acceptable for an unadvertised Part 1, and far better than the original silent beat-rate change.

Owner question with a default:
> When Divide leaves the rig's only loop at less than a bar, or a fractional bar count (1 bar → 2 beats, 3 bars → 1½ bars), should it keep the tempo and count the loop in whole beats, or be refused as incompatible?
> **Default: keep the tempo and count in beats, refusing only half-beats**, as pen 16 screens 04–06 draw it. Until it is built, Part 1's refusal stands.

### Verdict (delta)

Approve. M1, M2, L1 and L4 are fixed and tested, and L2 and L3 are deferred to Part 3 with a written plan. The M2 owner question above must be settled, and the beat-grid follow-up built if the default holds, before Part 3 exposes the mode.

## Delta review (be963fd81)

### Scope

- Head `be963fd81`. The new work is `d807fb210` (the beat grid), plus two trunk merges and a test fix for the merged Session rig's track direction.
- It implements the owner decision of 2026-10-06: a sole loop is counted in beats, and Divide keeps the tempo, refusing only half-beats.

### Runs

All runs were made in a fresh worktree at `be963fd81`.

| Run | Result |
|---|---|
| `run_native_tests.sh`, 3 runs, separate TMPDIR each | ALL PASSED x3 |
| TSAN races binary | exit 0 |
| segno_engine | +379, all passed |
| looper_repository | +819, all passed |
| session_repository | +245, all passed |
| App suite, after `flutter gen-l10n` | +3464, ~56 skipped, all passed |

### The beat grid (traced)

- **`le_reclock_whole_beats` (engine_core.h).** This is the only place the rule lives.
  - It rounds `beats * len / base` and accepts the result within 1 frame of a whole beat count.
  - Admission and the callback recheck both call it with `a_loop_beats`.
  - `test_length_reclock_keeps_tempo` checks:
    - 1, 2 and 3 bars of 4/4 at 120 halve to 2, 4 and 6 beats at 120 BPM;
    - `loop_bars` is 0 for sub-bar results;
    - Undo restores bars and beats;
    - 1 bar goes to 2 beats, then to 1 beat, and a further half is refused (MODE_MISMATCH);
    - 3/4 refuses its 1.5-beat half.
- **`le_set_loop_grid`.** It is now the single writer of `a_loop_beats`, `a_loop_bars` (only when the beats make whole bars, else 0) and `grid_total_beats`. I grepped the core and every former direct writer goes through it:
  - `sync_grid_to_loop`, `le_apply_length_preset_tempo`, `le_restore_musical_grid`;
  - the switch into Free/Song, `handle_clear`, `reopen_settle`, `reset_material`, `regrid_surviving_master`;
  - the session commit.
- **Tempo lock.** It now reads `a_loop_beats > 0`, which equals the old `loop_bars > 0` for every whole-bar grid and also locks a sub-bar one.
- **`regrid_surviving_master`.** It keeps D7 for whole-bar grids, and gives a sub-bar grid the nearest whole beats.
  - It only runs when the tempo is unlocked over a surviving master (the undo-to-empty edge).
  - A time-signature change re-derives bars from the beats through the setter.

### Every consumer of the bar count, checked for a sub-bar grid

- **Beat indicator and click** (`grid_beat_frame`).
  - The beat is `le_grid_beat_at(pos, len, grid_total_beats)`, so a 2-beat loop publishes beats 0 and 1 (the test checks `current_beat == 1` halfway).
  - `current_beat` is `beat % ts_num`. In a 6-beat 4/4 loop the click therefore accents beat 1 and beat 5, then restarts at the loop top: a 4+2 pattern. This is musically honest, but a visible behaviour; it belongs in the pen write-back.
- **Quantize** (`le_live_subdiv_ratio` → `le_grid_loop_subdiv_ratio`).
  - It takes `grid_total_beats` as a rational, documented "never assumes" whole bars.
  - BAR quantization on a 2-beat loop is ratio 1/2: no boundary falls inside the loop, so the arm fires at the loop top (`le_grid_loop_next_subdiv` returns `len`).
  - On a 6-beat loop, boundaries fall at beat 4 and at the top.
  - No division by zero, nothing out of bounds.
- **Count-in.** It is computed from the tempo and the count-in bar setting, on an empty rig, so a loop's bar count is never read.
- **MIDI clock.** It is driven by the tempo, which is unchanged.
- **Renderer, stems and events.log.**
  - `perf_render.c` reads `LE_PLOG_LOOP_LENGTH_LOCKED` only.
  - `COMMIT_SESSION` is not logged raw (events.log format, code 23: logged only as 302). The renamed `session.loop_beats` field in `le_log_command` is therefore never written, and no version bump is needed.
  - DAW export (`event_log_reader`, `manifest_reader`) never reads bars.
- **Dart.**
  - `TransportState.loopBeats` and `Track.wholeBeats` are added.
  - `_framesPerBeat` prefers the master's beats, then the bars, then the nominal tempo.
  - `wholeBars` is derived from the same per-beat unit.
  - At this head the stage still shows only `wholeBars`; the "2 beats" reading arrives in P3.

### Notes

- **N1.** At this head the Session still saves `loopBars` only (`session_mapping.dart:125`). A sub-bar grid would therefore recall grid-free: the tempo is kept, but there is no beat lock.
  - This is unreachable here, since Divide has no caller in P1.
  - P2 closes it with schema 14 `loopBeats`.
  - P1 and P2 must therefore land before P3, which they do by construction of the stack.
- **N2.** `le_engine_commit_session` now takes beats, and the only caller (`commitSession(base, loopBeats: rig.gridBeats)`) passes bars × numerator for older rigs. The C API changed in place; this is acceptable under AGENTS.md, and the bindings are regenerated.

### Verdict (delta be963fd81)

Approve.
