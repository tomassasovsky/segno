Model: Claude Fable (subagent), in-session

# Review of PR #1158 — feat(engine): reopen the audio device without losing recorded loops

Branch `claude/engine-reopen-1140` @ e1cae3988, base `codex/fade-clear-history` @ 270209fbc.
Reviewed by reading the full engine sources at the head commit (not the diff alone), running both native suites, and adding six throwaway native probes (`probes_test_engine_reopen_extra.h` in this directory; not committed). All file:line references are to the PR head.

## Verification runs

- `bash packages/segno_engine/src/test/run_native_tests.sh` — ALL PASSED (every binary), exit 0 (`native_tests_plain.log`).
- `EXTRA_CFLAGS="-fsanitize=address -g" bash packages/segno_engine/src/test/run_native_tests.sh` — ALL PASSED, no ASAN reports, exit 0 (`native_tests_asan.log`).
- Probes, built with ASAN: `probes_asan_output.log`. Five pass; one (probe A) reproduces finding 1; probe D reproduces the behaviour in finding 2.

## Verified correct (traced)

Threads during the reopen
- The audio callback is gone before any retained-path field moves: `le_engine_reopen_configured` refuses while `a_running` (engine.c:921) and `le_engine_stop` cleared it (engine.c:1427). Every state command the audio thread pops is acked inside its apply handler (engine_process.c:2358, 2901, 2932, 2971, 2999, 3036), so at reopen time an unacked state command is still unpopped in the command ring, never half-applied (this matters for finding 2).
- Workers: `le_engine_quiesce_workers` (engine.c:358-410) joins the cache worker, the restore worker and the perf drain thread, cancels a render, frees the staged layers and stores `a_perf_armed = 0` (engine.c:402) BEFORE `le_engine_reopen_file_retired` runs, so `le_stage_retired_layer` (engine_commands.c:539-541) is a no-op there and never pushes into the zeroed `layer_staging_ring`. `le_plog_push` is gated on `perf.armed` (engine_process.c:90), so the `le_fade_reset` → `le_fade_log` calls in the settle (engine_process.c:1745) do not touch the zeroed log ring.
- In `le_engine_reopen` the device is opened before quiesce; `le_miniaudio_open` writes only `context_initialised`, `device_initialised`, `capture_id_set` (engine_miniaudio.c:149-339), none of which the retention decision or the still-alive drain thread reads. The sample-rate comparison in `le_engine_reopen_outcome` (engine.c:898) therefore compares the negotiated rate against the previous session's `engine->sample_rate`, which open did not overwrite.
- Rings: both SPSC rings are re-initialised in `le_engine_reset_runtime` (engine.c:654-655) only after the event ring was drained by `le_engine_reopen_file_retired` (engine_commands.c:847); `commands_posted`/`commands_applied`/`a_commands_published` reset together (engine.c:634-637).

Material vs runtime split
- `le_engine_reset_material` (engine.c:422-487) is the only place that frees pools, zeros `a_live/a_len/a_recoverable`, history, take ids, Fade envelopes, `clock.length`, `a_master_len`, crown and grid. `le_engine_reset_runtime` (engine.c:497-879) touches none of them; it resets `clock.position` only (engine.c:682) and `le_lane_reset_settings` keeps `pool`, `a_live`, `a_len`, `a_recoverable`, `image_gain/pan` (engine.c:147-218) while recomposing `a_vol_bits`/pan gains from the retained image.
- Generation counters: `dub_generation` and `dub_gen_audio` both reset to 0 in the runtime reset (engine.c:589, 612); `clear_cmd_ack`, `state_cmds_posted`, `a_state_acks`, `pending_target` reset together (engine.c:607-611). `fade_lifetime` is bumped and every track's `fade_cache.lifetime` rewritten (engine.c:515-519); `fade_next_request` is never reset (monotonic), so old request ids cannot collide with new ones — `le_engine_read_fade_result(e, stale)` returns INVALID (test_engine_reopen.h:434) and `le_engine_install_fade` with a stale lifetime is refused (engine_commands.c:2337).
- `lane_count` is retained (set only in reset_material, engine.c:427); a lane-count change still in the ring at the loss just stays unapplied, with its pre-allocated buffers sitting in the pool.

Exact revert walk
- `le_dub_run_copy` (engine_process.c:1568-1593) is the single definition used by both the drain (1658) and the revert (1712); index = `vseg*base + comp_pos(vpos, off, base)` matches the write head `wdub = seg_base + comp_pos(trk_pos, dub_offset, trk_len)` (engine_process.c:5612) and the start latch (5615-5618). The run splits at the segment end and at `vpos == off`; traced both cases and confirmed with probe B (record offset 1, passes starting before and after the wrap) and probe E (mid-drain revert on a multiple-2 track whose pass straddled the segment boundary, 0 differing frames).
- Mid-drain: the drain extends coverage contiguously from `start + count` (1639-1641), so the revert of `count` frames from the start re-copies drained positions as no-ops. The re-punch gap case resets `dub_count = -1` (1467-1473), so a stale partial shadow is never reverted.
- The division-track base mismatch is pre-existing and the author filed #1157; the revert mirrors the drain, so no new divergence.

Settle and filing
- RECORDING / `seam_capture > 0` drop (engine_process.c:1725-1750): a fresh take always starts on an empty undo/redo history (`le_begin_empty_capture`, `le_clear_redo`, `le_drop_clear_history`), so `undo_count = redo_count = 0` is correct there; the deferred master crossfade keeps `clock.length == 0` until `finalize_master_xfade` (engine_process.c:1092-1101), so dropping an `xfade_capture > 0` take leaves no master (test_engine_reopen.h:376).
- Content tracks → STOPPED, `fade.frames = 0` re-origins the ramp (1759), `le_dub_drop_armed` + `a_layer_in_flight = 0` (1773-1774), `le_primary_reconcile` (1787).
- Filing (engine_commands.c:841-891): parked retire filed with `dub_gen_audio`, which equals `dub_generation` because no state command is pending (ruled out by the outcome predicate); `le_collect_clear` runs while the mailbox and `clear_cmd_ack` are intact. Probe C (undo-to-empty retained, redo works after reopen) and probe F (retained Clear restore point: undo restores, redo re-clears, layer beneath peels) pass.
- `start_iter`/`loop_iteration` zeroed on every track: this loses the relative segment phase of two multi-loop tracks, but the engine already does exactly this whenever the transport is held (engine_process.c:4606-4611), and the reopen parks everything STOPPED, so it is consistent with existing Stop-all → Play behaviour, not a reopen defect.

Failure paths
- Open failure returns before anything moves (engine.c:1334). Configure failure closes the device (1340-1343). Start failure closes in `le_engine_publish_and_start` (1392-1395) with material already settled; the retry re-quiesces (joins the workers `le_cache_init`/`le_restore_init` had restarted). `lat_buf` is freed before realloc (engine.c:675). No double free: `le_lane_reset_settings` nulls each freed delay line and plugin slot.

Fewer channels
- Input read is bounded by `ic < ch_in` (engine_process.c:5698); output routing writes only bits below `ch_out`; `test_reopen_fewer_channels_keeps_material` sizes `out` exactly to the device and passes under ASAN.

Tests
- The 14 native tests use literal PCM oracles through production entry points; the parked-retire test genuinely fills the event ring (test_engine_reopen.h:336-342) and the mid-drain test genuinely observes `dub_draining` (303-309). My probes B, C, E, F extend coverage to the offset-split walk, redo-from-empty, cross-segment mid-drain and Clear redo; all pass.

Dart
- `NativeAudioEngine.reopen`, `PumpedNativeEngine.reopen` (same `maxLoopFrames` as its `start`, so the pumped path retains), `MockAudioEngine.reopen` and the four fakes are straightforward. `ReopenOutcome.fromCode` maps unknown codes to `clearedPending`. Nothing calls `reopen` yet (part 2, stated in the PR body).

## Findings

1. **Low** — Two complete passes at the loss: only one is filed, the other layer is lost.
   - Where: `le_engine_reopen_file_retired`, engine_commands.c:859-871 (`if (dub_retire_slot >= 0) … else if (dub_slot complete)`).
   - Trigger: event ring full across two consecutive pass boundaries while OVERDUBBING. `le_dub_boundary` parks pass N in `dub_retire_slot` and arms the spare; at the next boundary it returns early (engine_process.c:1545) and leaves pass N+1 frozen complete in `dub_slot`. On reopen only `dub_retire_slot` is filed; the settle skips `dub_slot` (count >= len, engine_process.c:1705) and `le_dub_drop_armed` discards it.
   - Impact: the newer complete layer disappears from history. Content stays coherent (live holds the merged result; undo peels straight to the pre-N image) but one undo step the user had is gone. Reproduced by probe A: `undo_depth` 1 instead of 2; after undo the loop reads 1.0 instead of 1.5.
   - Fix: file both, oldest first — after filing `dub_retire_slot`, also synthesise a retire for `dub_slot` when `dub_len > 0 && dub_count >= dub_len` (same `dub_gen_audio`), then clear both.
   - Realism: needs LE_RING_CAPACITY (256) undrained events, so a control thread that stopped polling; low.

2. **Medium (design / blast radius)** — `CLEARED_PENDING` wipes every track for a command the audio thread never saw.
   - Where: `le_engine_reopen_outcome`, engine.c:900-906, and its caller returning `le_engine_configure` for the whole engine (engine.c:931-934).
   - Trigger: device lost → `le_engine_stop`. The user presses Undo on a track with no layers (or Clear, or Redo-from-empty) while the device is away: `le_push_cmd` is configured-gated (engine.c:1528-1532), so the press is accepted and `le_mark_state_cmd` bumps `state_cmds_posted`. The reopen then reports `CLEARED_PENDING` and `le_engine_configure` resets all eight tracks. Reproduced by probe D: a single Undo press on track 1 empties track 0's retained loop.
   - Why this is not the "half-applied" case the predicate describes: acks are bumped inside the apply handlers (engine_process.c:2901-3036) and the stop is synchronous, so an unacked state command at reopen time is still unpopped in the ring — the audio side applied nothing. What is inconsistent is only the control-side pre-mutation on that one track (`le_track_set_len(t, 0)`, the redo push, `a_multiple = 1` for UNDO_TO_EMPTY, engine_commands.c:2183-2195). The PR's own lifecycle test shows a RECORD press made while stopped is simply discarded (test_engine_reopen.h:719-721); the state-flip presses instead cost the whole rig.
   - Impact: the retained promise fails for unrelated tracks after an ordinary press during the outage; part 2's supervisor will reopen on its own tick, so the user cannot avoid it by waiting.
   - Smallest fix: scope the pending rule per track — drop that track the way the settle drops a RECORDING take (EMPTY, len 0, history and shadows dropped, `le_fade_reset`) and retain the rest; or, if the owner prefers the engine-wide clear, have part 2 refuse history presses while `devicePresent == false`. Either way this is an owner call; the plan recorded CLEARED_PENDING without the whole-rig consequence being spelled out.

## Verdict

Retained path, revert walk, filing, generation/lifetime handling and all failure paths trace correct under both suites and six extra probes; one low defect (second complete layer lost when the event ring was full for two passes) should be fixed before merge, and the engine-wide CLEARED_PENDING blast radius needs an owner decision or a part-2 gate — approve with those two addressed.

---

# Delta review (6618fd9a5)

`fix(engine): keep the other tracks when one reopen command is pending` — reviewed as `git diff e1cae3988..6618fd9a5` plus a re-read of the touched functions at the new head. Delta probes: `probes_delta_6618fd9a5.h`, output `probes_delta_asan_output.log` (ASAN build, all six pass).

## Verification runs (clean tree at 6618fd9a5)

- `bash packages/segno_engine/src/test/run_native_tests.sh` — ALL PASSED x5 (race, FX recipe, engine incl. the 3 new reopen tests, MIDI, plugin scan, plugin slot), exit 0 (`native_tests_plain_6618fd9a5.log`).
- `EXTRA_CFLAGS="-fsanitize=address -g" bash packages/segno_engine/src/test/run_native_tests.sh` — ALL PASSED x5, no AddressSanitizer reports, exit 0 (`native_tests_asan_6618fd9a5.log`).
- Delta probes A, D, G, H, I, J (ASAN build) — all pass (`probes_delta_asan_output.log`).

## Both original findings: fixed (reproduced)

1. Two complete passes. `le_engine_reopen_file_retired` now files `dub_retire_slot` first, then an armed `dub_slot` with `dub_count >= dub_len`, through one helper `le_reopen_file_slot` (engine_commands.c:845-849, 870-877), both tagged `dub_gen_audio`. Probe A re-run: `undo_depth` 2, undo peels 2.0 → 1.5 → 1.0 in the order the passes were played. The PR's `test_reopen_files_two_complete_passes` asserts the same.
2. Blast radius. `le_engine_reopen_outcome` now accumulates a per-track `drop_mask` (engine.c:904-918) and returns `LE_REOPEN_RETAINED_PARTIAL`; only a rate or cap mismatch still goes through `le_engine_configure` (engine.c:933-936). Probe D re-run: one Undo press on track 1 while stopped → outcome 3, mask 0x2, track 0 STOPPED with its 4 frames byte-exact, master kept. The PR's `test_reopen_pending_press_drops_only_that_track` is the same scenario.

## Verified correct (traced)

Dropped track sharing state with retained tracks
- Crown: `le_reopen_drop_track` leaves `a_primary_track` alone and the settle's `le_primary_reconcile` (engine_process.c:1815) keeps a crowned-but-EMPTY primary when a sibling has content — the same D18 rule `handle_clear` follows ("deliberately untouched", engine_process.c:2300-2305) and `le_primary_reconcile` encodes (846-861). Probe G compares an unapplied Clear on the primary (dropped at reopen) with the same Clear applied before the reopen: master 4, primary 0, track states, sibling multiple 2, sibling playback from the head and the primary's next take (len 8, k=2) are identical in both variants.
- Master clock when the dropped track defined it: kept while any track still has content, reset only when the rig is all EMPTY (engine_process.c:1805-1814) — the same condition `handle_clear` uses (2344-2351). The fields the delta resets (`clock`, `a_master_len`, `a_loop_bars`, `grid_total_beats`) are `handle_clear`'s set minus those `le_engine_reset_runtime` already resets afterwards (`loop_iteration`, `a_master_pos`, `a_current_beat`, `grid_prev_beat`, `has_tap`, `last_tap_frame`: engine.c:684, 690, 712-716, 720).
- Multiples and Sync divisions: a sibling's `a_multiple` / `a_sync_divisor` are relative to `e->clock.length`, not to the dropped track's buffer, and the clock survives exactly when it would after an applied clear of that track, so `trk_len = clock.length / n` (engine_process.c:5278-5286) stays well-defined. Traced by equivalence with the applied-clear path; not driven empirically (Sync-mode fixture).
- All-EMPTY reset with an EMPTY-with-redo sibling: probe H — track 1 undone to empty (redo kept, master 4), unapplied Clear on track 0 → mask 0x1, master reset to 0, track 1 `redo_depth` still 1; redo re-establishes master 4, PLAYING, content byte-exact, crown moves to 1. This matches `handle_clear`'s existing behaviour for the same sequence with an applied clear (the redo re-derives the grid via `le_restore_master_len`, engine_commands.c:1873-1879).
- Control-side pre-mutations of the dropped commands are per-track only: `le_prepare_clear`/`le_finish_clear` touch `t->*` and `engine->armed[channel]` (engine_commands.c:1288-1342), `le_restore_clear` and redo-from-empty touch `t->*` and the track's `pending_master_len` (2026-2085, 2272-2289), the record fresh-take grid-redefine CLEAR goes through the same two helpers (1560-1575) on the recording track. No path pre-stores `a_master_len` or `clock` control-side, so a dropped track never leaves engine-wide state half-moved.

file_retired mask skip
- A masked track's parked `dub_retire_slot` and armed `dub_slot` are not filed; the settle's `le_dub_drop_armed` (engine_process.c:1787) clears both and `le_reopen_drop_track` zeroes the stacks, so no stack, `outstanding_slots` or dub field references them — `track_acquire_slot` (engine_commands.c:101-116) sees them free. Not a leak: pool buffers are owned by the lane until configure/destroy regardless. Probe I: masked track with a parked retire and an armed shadow → after reopen `dub_retire_slot`/`dub_slot` -1, `outstanding_count` 0; six new overdub passes file six layers and the old slot indices are reused.
- The event-ring pop still runs for masked tracks (engine_commands.c:856, before the skip): a late LAYER_RETIRED or TAKE_CANCELLED for a masked track is handled and then wiped by the drop; `le_stage_retired_layer` is a no-op (a_perf_armed 0). `le_collect_clear` skipped for masked tracks is fine — the mailbox and `clear_cmd_ack` are zeroed in the runtime reset (engine.c:596-603).
- Masked track that was EMPTY with a restore point and got an unapplied restore (`le_restore_clear` moved the point to redo and swapped a_live): probe J — dropped with `clear_restore` 0, `undo_depth` 0, sibling retained, master kept; a later Undo on it returns INVALID harmlessly.

Settle ordering
- `drop` is computed before the revert (engine_process.c:1731-1733) and the revert is skipped for dropped tracks, so no shadow→live copy runs on a track about to read EMPTY; the common tail (park, `le_dub_drop_armed`, `a_layer_in_flight = 0`, `le_fade_publish`) still runs for every track (1776-1790).
- `dropped_any` now also covers RECORDING / seam drops, so the all-EMPTY reset can fire where v1 left the clock: only reachable when the dropped capture was non-defining and every sibling is EMPTY — but a fresh take on an all-EMPTY rig with a kept clock posts the internal grid-redefine CLEAR ahead of RECORD (engine_commands.c:1563-1575), which the FIFO applies first, so the clock is already 0 by the time that track is RECORDING. No behavioural change in practice.

Dart
- `ReopenOutcome.fromCode`: 0 retained, 1 clearedRate, 3 retainedPartial, anything else (including 2) clearedCap; `keepsMaterial` true only for the two retained values. `ReopenResult` gained `droppedTracks`; every constructor in the tree updated (native, pumped, mock, four fakes — grep finds no stale `clearedPending`). Native and pumped engines pass a zero-initialised mask pointer and read it back; the failed-open path leaves it 0 as documented. The pumped test `an undo pressed while the device was away drops only its track` mirrors the native repro through the FFI.

Tests
- The three new native tests fail on e1cae3988 by construction: the old predicate returned `CLEARED_PENDING` (so `reopen_same_mask` would see outcome 3 but all tracks EMPTY and `s.tracks[0].length_frames == LOOP_N` fails), and the old filing left `undo_depth` 1. `reopen_same` now also asserts `mask == 0`, so every pre-existing retained test guards against a spurious drop.

## Findings

None traced or reproduced in the delta.

Observations (not defects, inherited semantics): a redo on an EMPTY-with-redo sibling after an all-EMPTY reset re-derives the master from that take's own length (so a multiple-2 sibling would re-establish a 2x grid), exactly as it does today after an applied clear empties the rig; and the crowned-but-EMPTY primary left by a dropped primary follows the existing D18 rule. Sync-division equivalence was traced, not driven.

## Verdict

Both findings are fixed and reproduced fixed; the per-track drop reproduces the applied-clear end state for crown, master and siblings, the mask skip leaks nothing, the all-EMPTY reset matches `handle_clear`, and the Dart mapping is complete — approve.
