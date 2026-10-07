Model: Claude Fable (subagent), in-session

# Adversarial review: PR #1173 `feat(engine): replay layer Undo and Redo exactly in performance stems`

Head `d5c9daec7` (`claude/stem-history-replay-1143`), base `cee9685ac`
(`claude/manifest-failure-1144`). Reviewed from a private worktree at the PR
head; nothing committed, pushed or posted.

## What was run

| Check | Result |
|---|---|
| `bash packages/segno_engine/src/test/run_native_tests.sh` | ALL PASSED (x5 binaries), exit 0 |
| same with `EXTRA_CFLAGS="-fsanitize=address -fno-omit-frame-pointer -g"` | ALL PASSED, exit 0, no ASAN report |
| same with `EXTRA_CFLAGS="-DLE_CALLBACK_TELEMETRY=0"` | ALL PASSED, exit 0 |
| Head test files built against **base** engine sources (`git archive` of `cee9685ac`, head's `test_engine_core.c` / `test_engine_fade.h` / `test_engine_history_replay.h` overlaid, `-DLE_PLOG_SOURCE_APPLIED=LE_PLOG_CLEAR_RESTORE -DLE_PLOG_SOURCE_TRANSPORT=LE_PLOG_RESTORE_TRANSPORT`, `SEGNO_HISTORY_TESTS_ONLY=1`) | **all 13 claimed tests fail on base**: 10 new history tests + `test_fade_restore_history_replacement` (11 CHECKs), `test_fade_restore_source_end_edges` (8), `test_fade_restore_capture_lifetime` (534). Claim verified. |
| Probe test `probe_history_arm_window` (below) at head | **fails**: 0 facts, `succeeded=1`, stem[0] = A+B+C while live[0] = A+B (finding 1) |
| Same probe with the 10-line fix in finding 1 | passes; fade + history subset passes (0 FAILs) |

## Verified correct (traced)

- **Call graph (E2 premise).** `le_engine_process` runs `for (uint32_t f = 0; f < frames; ++f)` at `engine_process.c:6301` and calls `mix_tracks_frame(e, in_c, out, f, ...)` at `:6351`. `buf[t][l]`, `cap`, `vol`, `mut` are locals of `mix_tracks_frame`, rebuilt every frame. The `a_live` load at `:5310` is therefore per frame; the review's "loaded once per block" premise does not hold on this base either (checked `cee9685ac:5283-5291`, same structure).
- **`a_live` publishers, complete list.** The only stores are `engine_core.h:122` (`le_track_publish_live`, called solely from `le_publish_live_image`) and `engine.c:165` (`le_lane_reset`: configure, and lane activation inside `le_engine_import_track_lane` at `engine_session.c:111`, whose row zero at `:126` follows). `le_publish_live_image` call sites: undo swap `:280`, `le_restore_commit_layer` `:413` (id 0), `le_restore_clear` `:2049`, redo-from-empty `:2271`, redo swap `:2288`, `le_engine_finalize_layers` `engine_session.c:295` (id 0). No audio-thread store of `a_live` exists.
- **Control-side pool PCM writers, complete list, and coverage.** `le_restore_commit_layer` `:392/:394` (fresh slot, published with id 0); `le_prepare_new_capture` `:895` (always preceded by `le_begin_empty_capture`'s row zero: `:1606/:1654/:1684` call order checked); `le_prepare_routing` lane growth `:1261` (new lanes only, lane 0 untouched; renderer is lane-0); `le_engine_import_track_lane` `engine_session.c:127-129` (row zero at `:126`); `le_engine_import_layer` `:228-230` (row zero at `:227`); `le_prepare_image_capture` `:1052` (replaces an EMPTY track's live slot and a free shadow; runs at `:1522`, before the same press's `le_begin_empty_capture`). Punch-out drain (`le_dub_block_update`), backup-on-write and `track_acquire_slot` eviction write **shadow** slots only; a shadow reaches `a_live` only through an admission, and every admission re-stages (fresh copy, table overwrite). The #728 seam capture writes the live slot under PLAYING, but it is armed only at a fresh-take finalize (`engine_process.c:1411-1415`, `record_pos - offset == new_len`), i.e. on snapshot-provenance content, never on an image-sourced slot.
- **Memory ordering.** Table store (relaxed) → `a_live` release store; callback acquire load of lane 0 → relaxed table load. For redo-from-empty and Clear restore the command push (release) follows the table store and the callback pop (acquire) precedes the handler, so the handler-first interleaving also sees the entry. The "stage before push" ordering is safe because in both paths the target equals the current `a_live` (redo top is the slot pushed at undo-to-empty, `:2178`; `e.slot` is `a_live` at clear, `:1775`/`:1282`), so a handler that flips PLAYING before the publish still mixes the staged slot.
- **Real-time safety.** Per track per frame: one acquire load (replaces the relaxed lane-0 load for non-idle tracks; new for idle ones), integer compares, one relaxed table load only on a slot change; `le_plog_push` is the existing wait-free ring push; no allocation, no blocking. PERF_ARM handler adds `tc` loads once.
- **Rule 1 under STOPPED/idle.** `live_idx[t]` is loaded before the `idle` skip, so a swap on an idle STOPPED track logs 322 STOPPED (silent segment) and Play logs 323 PLAYING with the resumed phase; `trk_play_pos` is updated above the tracker in the same loop, so the phase is this frame's.
- **Rule 3 extension (deviation 2), fresh takes.** All three `le_engine_record` entry points call `le_begin_empty_capture` (row zero) before `le_prepare_new_capture` and before the RECORD push; the RECORD command rides the ring after the zero, so the first RECORDING frame finds entry 0 and logs nothing. Count-in, sound-activated and grid-quantized starts all go through the same press. Overdub on an unchanged snapshot-provenance slot: `perf_source_id == 0` and slot unchanged → no fact. Queued Undo applied under OVERDUBBING (`le_apply_queued_undo` → `le_undo_swap`) → 323/0, truthful (the staged copy is about to be overwritten). No false-failure path found for ordinary takes.
- **`le_stage_retired_layer` return / overruns.** Every refusal path returns 0 and counts, except the unreachable `frame_count <= 0` (callers pass `a_len`, `empty_len`, `e.len`, all checked > 0 upstream). `le_stage_source_image` counts id exhaustion; a refused id is consumed (gap in the sequence), ids never repeat. `le_handle_retired` ignores the return, as before.
- **Capacity.** `LE_POOL_SLOTS` 256, staging ring and manifest both `8 x 256 = 2048` per capture, `LE_PR_MAX_SEGMENTS` 4096 per track; overflow fails the stem, never truncates. Table is 8 KB as the plan says; `le_forget_slot_images` is 256 relaxed stores (2048 at arm) — negligible.
- **Renderer.** Repeated 322: each `initial` loads its own image via `le_pr_restore_image` (exact `kind/channel/restore_id`, duplicate rejected), the segment owns it, and the failure path frees only the just-loaded image (`if (initial) free(restore_image)`); 323 shares the pointer with `owns_image = 0`; 39 and CLEAR append a silence segment and zero `restore_id`, so a stray later 323 fails on `!id || id != restore_id`. `phase0` comes from the fact and `phase >= restore_len` is rejected. A channel with only 323/0 is collected (`le_pr_collect_channels` takes both codes) and fails.
- **events.log version 6.** `perf_drain.c` writes 6; `LE_TEST_EVENTS_VERSION` 6; format doc header and table row; `perf_drain.c` and `perf_log_ring.h` comments; the Dart `EventLogReader` and `le_pr_load_log` check only the magic. Note the reverse plan (`origin/claude/reverse-plan-1162`, plan `:263`) also takes 5→6; whichever lands second must take 7 (the plan says so).
- **Tests.** The 13 fail-on-base claim holds (table above). Oracles are literal (A ramp, B constant, C 7-periodic) and `fade_render_status` reads the per-stem `succeeded` flag for channel 0; `test_read_wet_stem` reads the actual stem file. `test_history_capture_namespace` checks the two `restore-0-1.pcm` files hold different layers. `test_history_staging_refusal_fails_stem_keeps_undo` pins `layer_overruns == 1` and master.pcm parity.

## Findings

### 1. Admission between `le_perf_arm` and the `LE_CMD_PERF_ARM` apply renders the stale arm image as success — Medium

- **Where:** `engine_process.c:3654-3660` (PERF_ARM handler): `perf_source_slot = a_live; perf_source_id = 0` for every non-EMPTY track, unconditionally.
- **Trigger:** `le_perf_arm` returns (drain owned, table zeroed, ARM command queued); before the next callback drains ARM, a layer Undo/Redo is admitted. `le_stage_source_image` stages the target (drain != NULL → image 1, listed in this capture) and publishes it. The handler then adopts the already-swapped `a_live` as snapshot provenance; no 322 is ever logged; the renderer plays the arm image, which the repository exported **before** `perfArm` (`performance_repository.dart:316` `_captureSettledLanes` precedes `:360` `_engine.perfArm`). In production the window is the gap after `perfArm` returns until the next audio callback (one buffer, 2.7-10 ms); in `_armGated` it is reachable because the awaits after `perfArm` let a pedal/UI Undo run.
- **Impact:** wrong-content success — the exact class this PR exists to eliminate — plus an orphan staged image. Reproduced at head with a probe (`history_fixture`, `history_arm_image`, `le_perf_arm`, `le_engine_undo`, 8 frames, disarm, finalize, render): 0 facts, `succeeded=1`, stem[0] = 0.269531 (A+B+C) vs live[0] = 0.253906 (A+B). The existing `test_fade_restore_capture_lifetime` pending-arm leg does not catch it because its track is EMPTY at arm (-1 path).
- **Smallest fix (verified: probe passes, fade + history subset passes):** in the PERF_ARM handler treat a nonzero table entry for the live slot as "unresolved", so the first mixed frame logs 322 through rule 1; load `a_live` with acquire so a seen swap implies a seen entry:
  ```c
  tr->perf_source_slot = -1; tr->perf_source_id = 0;
  if (load_i32(&tr->a_state) != LE_TRACK_EMPTY) {
    const int32_t live = atomic_load_explicit(&tr->lanes[0].a_live, memory_order_acquire);
    if (atomic_load_explicit(&e->perf.slot_image[t][live], memory_order_relaxed) == 0)
      tr->perf_source_slot = live;
  }
  ```
  Any nonzero entry at this point was staged after `le_perf_arm`'s row zero, so it is this capture's. Add the probe as a test leg (`arm, Undo before any process, expect one 322 at frame 0 with id 1 and parity`). The sub-window **before** `le_perf_arm` (plan section 10, pre-existing: table 0, drain NULL) stays open and is a repository ordering question (export after the ARM acknowledgement), not this PR's.

### 2. Lane-0-only application boundary: lanes 1..n can switch one frame before or after the fact — Low

- **Where:** `engine_core.h:121-123` stores lane 0 first then lanes 1..n; `engine_process.c:5315` loads lanes 1..n relaxed, after the lane-0 acquire load.
- **Trigger:** multi-lane track, swap published while the callback is between the lane-0 and lane-k loads of one frame, or between two frames' loads.
- **Impact:** the 322 frame is exact for lane 0 by construction (shared `live_idx`) but lane k may have mixed the new slot one frame early or the old slot one frame late. Today's renderer is lane-0 only, so no stem is wrong; the staged image file is interleaved across lanes, so a future multi-lane renderer would inherit a one-frame tear. Pre-existing tear in the mixer itself, but the fact now claims exactness.
- **Smallest fix:** document it beside the "does not implement multi-lane offline rendering" sentence in the format doc. Optionally store lanes n..1 first and lane 0 last in `le_track_publish_live` (release on lane 0 then covers the others), which removes the "lane k lags the fact" direction; the "lane k leads" direction needs a single per-track live word and is out of scope.

### 3. The 128-frame-block test leg does not discriminate E2 — Low (test honesty)

- **Where:** `test_history_undo_redo_literal_parity`, `blocks[] = {1, 128}`; build record "E2" paragraph.
- **Trigger:** every swap is admitted between `le_engine_process` calls, so a per-block load and a per-frame load both place the fact on the block's first frame.
- **Impact:** the build record presents the leg as proof that the per-frame choice is right; it is a block-boundary placement regression check only. The real per-frame evidence in this PR is the hook-5 racing-swap leg of `test_fade_restore_source_end_edges` (publish after this frame's loads → applied and logged next frame), which is a 1-frame-block test.
- **Smallest fix:** add a leg that admits the swap from `le_test_fade_hook` stage 5 at frame `f` inside a 128-frame block (the hook fires after the loads) and asserts the 322 at `block_start + f + 1`; a per-block design would log it at the next block start. Reword the build record accordingly.

### 4. Batch test cannot content-verify which image the renderer used — Low (test strength)

- **Where:** `test_history_batch_before_callback`: images 1, 3 and 5 are all A+B (byte-identical).
- **Impact:** parity passes whichever of the three ids the renderer resolved; only the fact's `image_id == 3` is checked, not the renderer's resolution of it.
- **Smallest fix:** make the batch end on a slot whose content differs from the other staged images in the batch (e.g. Undo, Undo, Undo→ no; use Undo, Redo, Undo so the mixed slot is A while images for A+B exist), or compare the stem against image 3's file bytes.

### 5. Format doc: "`frames` ... reads 0 until it lands" is not guaranteed by this writer — Info

- **Where:** version-6 row, `performance-event-log-format.md`.
- **Impact:** the fourth `int32` of a 303 payload is whatever the `le_command` union held; compound literals zero it in practice (gcc/clang), but the writer does not promise it. Reword to "unspecified until Part 2 lands under version 6" or zero the union explicitly where `LE_EVT_LAYER_RETIRED` is built.

### 6. Disk and control-thread cost under rapid toggling — Info (accepted by D3/E6, recorded for the merger)

- Each press copies `len x lanes x 4` bytes on the control thread and the drain writes the same to disk; A→B→A re-stages byte-identical images (the batch test lists 5 files for 5 presses). At 10 presses/s on a 30 s stereo loop that is ~115 MB/s of writes; a slow disk backs the staging ring up (each entry holds its malloc'd copy until drained), bounded only by the 2048-entry ring. Failure mode is truthful (refusal → 323/0, `layer_overruns`), master unaffected. A later optimization that stays within the model: skip re-staging when the slot's entry is nonzero, provided `track_acquire_slot`/shadow posting zero the entry of any slot they hand to the callback.

### 7. Version clash — Info

- The reverse plan (#1162) also bumps events.log to 6 and allocates code 324. Whichever lands second must take 7; the plan says so, the PR description does not.

## E2 adjudication (deviation 1)

**The builder is right and the reviewer's premise is wrong.** `mix_tracks_frame` is called from `le_engine_process`'s per-frame loop (`engine_process.c:6301`, `:6351`); `buf[t][l] = ln->pool[live]` at `:5315-5316` is a per-frame local, on this base and on the PR head. A once-per-block load would have deferred every mid-block publish by up to a block in the production mixer, a product change. The built rule — one acquire load of lane 0's `a_live` per track per frame into `live_idx[t]`, consumed by both the mixer and the tracker — makes the lane-0 fact frame equal to the lane-0 mixed frame by construction; there is no second load left to race. The 322 frame can still differ from the frame lanes 1..n first mix the new slot (finding 2, ±1 frame, lane-0 renderer unaffected). The 128-frame-block test leg is not a discriminating check for E2 (finding 3); the deviation itself is correct and should stand, and section 2.2 of the plan already records it.

## Rule 3 extension adjudication (deviation 2)

**Correct, and it closes a real hole.** Without it, a Clear restore (or Redo-from-empty, or layer swap) followed by Record in the same block leaves a staged, never-mixed image in the table with no fact, and the renderer continues the previous source as success. With it, a slot change under RECORDING/OVERDUBBING to a slot with a nonzero entry logs 323/0. Ordinary fresh takes are unaffected: `le_begin_empty_capture` zeroes the row at all three `le_engine_record` entry points before the RECORD push, `le_prepare_image_capture` precedes it, and the deferred starts (count-in, sound, grid) reuse the same press, so the first RECORDING frame sees entry 0 and logs nothing. Overdub on an unchanged snapshot-provenance slot logs nothing. The one behavioral consequence — any history swap followed by Record/overdub within one block fails the stem — is the D4 policy for image-sourced tracks already.

## Verdict

**Approve after finding 1 is fixed** (one handler change plus a test leg; verified locally that the fix passes the probe and the fade/history subset). Everything else traced clean: the publisher and PCM-writer enumeration is complete and covered, the callback addition is RT-safe, the renderer handles repeated 322, 323 sharing, 39 silence and phase exactly, the version bump is consistent, and the 13 fail-on-base claim holds. Findings 2-5 are documentation and test-strength items that can land in the same PR or in Part 2; 6-7 are notes for the merger.
