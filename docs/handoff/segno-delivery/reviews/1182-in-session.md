Model: Claude Fable (subagent), in-session

# Review: PR #1182 — feat(engine): reverse a track's playback at its current position

Branch `claude/reverse-1162-p1` @ 3dd3380f6, base `claude/segno-integration` @ 31c4aafad (merge-base confirmed).
Reviewed: full diff (35 files), `gh pr view 1182`, `docs/plan/2026-10-05-feat-foot-reverse-plan.md`, and the surrounding engine code the diff depends on (mix_tracks_frame pair setup, advance_transport_frame, handle_record/handle_play, launch cohort commit, le_apply_mode_switch, perf_render segment table, commit-session handler, import paths).

## Runs

| What | Result |
|---|---|
| `run_native_tests.sh` plain (own TMPDIR) | ALL PASSED (5 suites), 14 reverse tests ran |
| `run_native_tests.sh` with `EXTRA_CFLAGS="-fsanitize=address -g"` (own TMPDIR) | ALL PASSED (5 suites) |
| `leaks --atExit` on the core binary with `SEGNO_REVERSE_TESTS_ONLY=1` | `0 leaks for 0 total leaked bytes` |
| `build_test_lib.sh` + `SEGNO_ENGINE_LIB=... flutter test` in `packages/looper_repository` | 796 passed; `reverse_native_test.dart` ran and passed (re-run alone to confirm it was not skipped) |
| `dart analyze packages/segno_engine packages/looper_repository lib test` (after `pub get`) | No issues found |
| Mutations re-run (reverse-only binary) | M1 drop the `-1` in the reversed index: caught. M2 remove `!tr->reversed` from both print-engage conditions: caught (`!info.engaged`, line 539). M3 remove the handle_record punch-in drop: caught (PCM changed, line 387). M4 `perf_source_next_pos` always `+1`: caught (`transport == 0` line 638 and render parity line 651). M5 renderer `turn_frames = 0`: caught (parity lines 583 and 651). |
| Probes (worktree only, ASAN build) | 8 probes, see findings; the segment-overflow probe reproduces a double free. |

## Verified correct (traced)

- **Read coordinate.** `(origin - pos - 1) mod len`: lap start is `len-1` at origin 0, the wrap is `0 -> len-1`, and the turn re-origin (`le_direction_origin`) makes the index continuous at `cur` in both directions (ramp tests at 44.1/48 kHz, blocks 1/127/512). Multiples: `le_track_base_position` adds the segment `((iter - start_iter) % k) * clock.length` and `len = k*base`, so the mirror runs across both segments (test + my k=2/k=1 probe). Sync divisions: base position is the unfolded primary phase and the fold is the modulo by `len = base/n`, so a reversed division still completes exactly `n` laps per primary cycle with lap start `len-1` on the primary's loop top (test). Free/Song: `le_apply_mode_switch` resets `e->clock` on entering Free/Song (dormant), so the `clock.length > 0` branch of `le_track_base_position` can never shadow `free_clock` there; the private clock keeps ticking and the read runs back. Once: `advance_track_clock_frame` and `le_shared_clock_one_shots` stop when the next index is the direction's lap start — identical to the old wrap test for a forward track with a parked origin — and `le_restart_once` re-origins to the lap start in either mode (tests). STOPPED toggle while the transport is running re-origins at the continuous index and Play resumes there (probe, exact).
- **Pair rewrite bounds.** `seg_base + trk_pos == index < lanes[0].a_len`, and every lane slot an import fills is allocated to `max_loop_frames` (`le_lane_ensure_slot(..., engine->max_loop_frames)`), so a shorter lane 1 or a second lane cannot be read out of bounds; the exposure equals the pre-existing forward read. ASAN probe: k=2 track + k=1 track with a 500-frame lane 1, 6000 reversed frames, clean.
- **Turn crossfade memory safety.** The old head is an *index* into the current live slot (`lbuf[turn_old[t]]`, `turn_old < len`), never a pointer to a slot, so undo slot reuse, Clear and a fresh capture cannot leave it dangling; `le_direction_reset` and `le_reset_track_playback` zero `turn_left` on every material transition. Countdown: `x = (F - turn_left)/F` is 0 on the toggle frame (both heads read `cur`) and `1 - 1/F` on the last window frame; the decrement sits after the lane loop with no track-level `continue`, so it runs for idle, muted and stopped tracks (probe: 380 -> 372 after 8 held frames). Layer undo while reversed mid-turn: direction kept, no fault (probe).
- **#1173 provenance.** `perf_source_next_pos` steps `-1 mod len` while reversed; the restored-image test shows exactly one 322 and zero 323 and sample-exact parity; M4 proves the test depends on it.
- **Record guard and callback drop.** Toggle admission refuses while `a_pending`, `armed[channel]` or `a_pending_launch` is set; `le_record_impl` refuses punch-ins on an effective-reversed PLAYING/STOPPED track before any shadow preparation; every firing path (grid arm, section arm, sound arm, count-in commit, mute-punch) funnels through `handle_record`, where the drop precedes `le_launch_defer`. So no arm or launch can start writing into a reversed pair. `le_effective_reversed` cannot drift permanently: `reverse_posted` and `a_reverse_applied` advance once per admitted command (accepted or refused) and the view falls back to `a_reversed` once they are equal; a late `reverse_posted++` after the callback already applied is harmless (`posted > applied` is simply false).
- **Material reset coverage.** `le_transform_reset` at void-take finalize, EMPTY->RECORDING (both branches), undo-to-empty, Clear, `le_reopen_drop_track`, and `LE_CMD_RESET_TRANSFORMS` (import lane 0, `finalize_layers`). Full configure (`le_engine_reset_material`) zeroes `reversed`/`a_reversed`; a retained reopen runs only `le_engine_reset_runtime` + the head park (`le_reset_track_playback`), so direction survives and the origin/turn are parked. Restore-clear needs no reset (a cleared track is already forward). Layer undo/redo keep direction, as the plan says.
- **Rename sweep.** No stale `le_engine_read_fade_result`, `FadeAdmission`, `_pendingFades`, `LE_CMD_RESET_FADE`, `fade_receipts`, `fade_next_request`, `le_fade_reset` or `le_shared_track_position` anywhere in C, Dart or docs; `le_log_extract` excludes 82/83; Fade admission is semantically unchanged (lifetime check, then the shared slot/receipt bookkeeping).
- **Free/Song `playback_offset`.** It was always 0 there (Once rewound `free_clock` instead). Now the relaunch re-origins; nothing else reads `free_clock.position` or `free_iteration` except the rewritten pair and the one-shot check, so existing behaviour is unchanged and the Once relaunch produces the same index sequence.
- **events.log v7.** `perf_drain.c` writes 7, `LE_TEST_EVENTS_VERSION` is 7, `rev_log_facts` checks 7, the format doc has the version-7 row and the 324 row; the Dart `daw_export` reader has no version gate. 324 is listed before 325 (reserved for Peel), consistent with #1180's note.
- **Dart seam.** Generated bindings carry the trailing `reversed` snapshot field and the three new symbols; `EngineResult.reversed` maps -9; mock, four fakes and the repository's shared `_pendingReceipts` are consistent; Session replacement retires Reverse receipts with the Fade ones.

## Findings

### 1. Medium — double free in the offline renderer when the segment table overflows
- **Where:** `packages/segno_engine/src/core/perf_render.c`, `le_pr_apply_direction` (~line 777-790) calling `le_pr_append_segment` with `image = last->image`.
- **Trigger:** 4096 (`LE_PR_MAX_SEGMENTS`) or more segments on one channel in one capture. Every accepted toggle/install appends one, and so do 322/323 facts and layer retires. Reproduced in my worktree under ASAN: 4104 accepted toggles during a capture, then `le_perf_render_begin` -> `AddressSanitizer: double-free perf_render.c:1151 in le_pr_render_track` (the arm image from `le_pr_read_wav_mono`).
- **Impact:** `le_pr_append_segment`'s overflow branch `free(image)`s the pointer it is handed, but the direction segment shares the previous segment's image (it sets `owns_image = 0` only *after* the append returns). The owning segment's cleanup then frees it again: heap corruption in the render worker inside the app process. Before this PR an overflow was a clean per-stem `load_failed`.
- **Smallest fix:** pass `NULL, 0` to `le_pr_append_segment` and assign `seg->image = image; seg->image_len = image_len;` afterwards, exactly as the non-initial 323 path does (~line 1000). Or test `b->segment_count >= LE_PR_MAX_SEGMENTS` first and set `load_failed`. Add a test that overflows the table and expects a failed stem, not a crash.

### 2. Low — a re-toggle inside the turn window mixes a head that never (or only partly) sounded
- **Where:** `engine_process.c`, `case LE_CMD_REVERSE` — `turn_reversed/turn_offset/turn_frames/turn_left` are overwritten unconditionally.
- **Trigger:** two toggles within one turn window (~10 ms), including the "rapid double toggles" case the suite exercises (both in one drain). Probe on the 0..999 ramp: after a same-drain double toggle at index 37 the output over the next 480 frames deviates from the pure forward ramp by up to 850.85 (frame 38 reads 925.85 where 75 is expected), because the "old" head is the reversed head of the first toggle, which never sounded and wraps to the far end of the loop at ~92 % gain.
- **Impact:** a net-zero gesture produces a ~10 ms burst of material from elsewhere in the loop. A foot double-tap is slower than 10 ms, but duplicate MIDI/assignment messages and an "all tracks" fan-out can land two toggles in one drain. The existing test passes for the wrong reason: it asserts direction and index, not the audio.
- **Smallest fix:** in the apply, if `t->turn_left > 0 && target == t->turn_reversed && t->turn_left == t->turn_frames` (nothing of the previous turn has sounded yet) restore `playback_offset = t->turn_offset`, set `turn_left = 0` and start no new turn. Extend the rapid-double-toggle test to check `out[k] == 37 + k` over `F` frames. The mid-window re-toggle (some frames sounded) is a smaller artefact and can stay.

### 3. Low — the transport hold parks the origin but not the turn
- **Where:** `engine_process.c` idle branch of `advance_transport_frame` (~line 4822): `playback_offset = 0` without `turn_left = 0`; `le_reset_track_playback` parks both and its comment says "a parked origin has no old head to mix".
- **Trigger:** toggle on a PLAYING track, Stop it (transport held) within 10 ms, Play before the window has elapsed. Probe: first samples after Play are 224.775, 227.40, 230.02 ... instead of 999, 998, 997 — a blend of the parked forward head (index 0, 1, 2 ...) with the reversed lap start.
- **Impact:** a <= 10 ms ramp on the relaunch instead of a clean start at `len-1`. Benign, but it contradicts the stated rule and the hold-park comment.
- **Smallest fix:** `e->tracks[t].turn_left = 0;` beside the park in the idle branch.

### 4. Low — Session-recall install re-origins to offset 1 until a held block parks it
- **Where:** `case LE_CMD_REVERSE` on an EMPTY imported track before the commit: `base = 0`, `cur = 0`, so `playback_offset = le_direction_origin(1, 0, 0, len) = 1`. `LE_CMD_COMMIT_SESSION` (~line 4036-4052) parks state STOPPED but not the origin; the idle branch parks it only once `clock.length > 0`, i.e. one processed block after the commit.
- **Trigger:** Play landing in the same drain as the commit. Probe: variant A (one block between commit and Play) reads 999, 998, ...; variant B (no block) reads 0, 999, 998, ... — the lap starts at index 0.
- **Impact:** one-sample deviation from the plan's "recall starts at len-1" rule in a timing window the app does not hit today. Part 2 territory, but the EMPTY-accepting admission lands here.
- **Smallest fix:** call `le_reset_track_playback(tr)` in the commit handler's per-track loop (it is the "park at the loop head" fact for recall anyway).

### 5. Info — stale launch grace if the callback drop ever fires for a count-in member
- **Where:** `le_launch_commit` (~line 4352-4362) sets `launch_grace[ch] = action` after `handle_record` regardless of whether the reversed drop returned early.
- **Trigger:** a cohort member with action 3 on a reversed track. Not reachable through admission today (toggle refuses while `a_pending_launch`; record refuses on a reversed track), only through raw posts.
- **Impact:** if reached, the next press on that track is consumed as a launch cancel and stops it. Latent trap for whoever next relies on the drop.
- **Smallest fix:** skip the member (`continue`) when `action == 3 && e->tracks[ch].reversed` before calling `handle_record`.

### 6. Info — one-drain prediction transient after a doomed toggle
- **Where:** `le_effective_reversed` / `le_record_impl`.
- **Trigger:** toggle admitted during the punch tail (`od_gain > 0`), then Record before the callback refuses it. Probe: Record returns -9 while the toggle is in flight, 0 right after the refusal is published.
- **Impact:** a spurious "overdub unavailable" for one drain; self-correcting, and the header comment documents it. No change needed.

### 7. Nit — test comments
- `packages/looper_repository/test/reverse_native_test.dart`: the comment says "the frame after the toggle at index 37 reads 36" but the assertion checks the toggle frame itself (`37/128`), which is the right check.
- `test_reverse_material_resets`: `facts >= 4` does not pin the count; `== 5` (toggle, clear, capture reset, toggle, undo-to-empty) would.

## Verdict

**Request changes** for finding 1 (a real memory-safety regression, small fix, needs a test), and take findings 2 and 3 while in the file (two-line fixes). Everything else traced correct: the index arithmetic holds at every edge I could construct, the turn is memory-safe and counts down correctly, provenance stays quiet, the record guard closes every firing path, resets cover every material transition, the rename is complete, the Free/Song change is behaviour-neutral, and the v7 log is consistent. All five re-run mutations are caught by the suite. With 1-3 fixed this is mergeable.
