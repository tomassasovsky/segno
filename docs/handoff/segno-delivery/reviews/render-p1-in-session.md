Model: Claude Opus (subagent), in-session

# Review of PR #1238: feat(engine): shared render recipe and one streaming WAV writer

## Scope

- PR #1238, `origin/claude/render-1202-p1` at `88390a548`, on trunk `097e1ef68` (`origin/claude/segno-integration`). Issue #1202, Part 1 of the plan on PR #1225 at `c73995889`.
- Two commits:
  - `eb8fe6055` `refactor(engine)`: `engine_wav.c/.h` and the cache's `le_fx_frozen_chain` / `le_fx_print` factoring, with `perf_render.c` moved onto the writer;
  - `88390a548` `feat(engine)`: `engine_render.c/.h`, command 112, the freeze, chunked staging, the sliced worker, Pre printed, Post per Wrap/Cut, Mix FX, the file target (`.part`, fsync, rename, `le_fs_sync_dir`), the API and bindings.
- Read in full: `engine_render.c`, `engine_render.h`, `engine_wav.c/.h`, the `engine_cache.c/.h` diff of both commits, the `engine_process.c`, `engine_private.h`, `engine.c`, `lockfree_ring.h`, `perf_log_ring.h`, `perf_render.c` and `segno_engine_api.h` diffs, `test_engine_render.h`.
- Cross-checked against: the plan (4.1-4.7 and Part 1), AB §3.5/§3.11, the live mixer (`engine_process.c` lane and track print engagement), pitch/time 3a (`origin/claude/pitch-time-1179-p3a` `fd3b8970d`, PR #1214) and #1198's part format (`origin/claude/recording-1198-p5`, PR #1227, `packages/wav_codec/lib/src/recorded_part.dart`).
- No UI in this part, so the pen is not involved.

## Runs

All in my own worktrees under the scratchpad, each native run with its own `TMPDIR`, `CC=clang`.

- **Native plain** (`run_native_tests.sh`) x3 at `88390a548`: ALL PASSED x3.
- **TSAN races** (`NATIVE_TESTS_ONLY=races`, `-fsanitize=thread`): pass, no reports.
- **TSAN on the render tests themselves** (not covered by CI's TSAN job): the core test binary built with `-fsanitize=thread`, `run_render_tests()` x3 in one process: no reports.
- **ASAN+UBSAN** full native suite: ALL PASSED, no reports.
- **Telemetry-off** full native suite: 1 failure, `test_fade_restore_staging_and_manifest_capacity` (`test_engine_fade.h:898`). Investigated under Notes: a pre-existing flake that also fails on the base trunk.
- **segno_engine Dart suite** with `SEGNO_ENGINE_LIB` from `build_test_lib.sh`: 376 passed.
- **App suite** (`flutter test` at the root): 3,323 passed, 202 skipped, 0 failed.
- **`dart analyze --fatal-infos lib test packages/segno_engine`**: clean. The only Dart change is the regenerated bindings. A whole-`packages` analyze in my worktree reports `storage_repository` URI errors because that package was not resolved there; they are unrelated to this PR.
- **Byte-identity of existing renders (asked for).** I instrumented copies of the base (`097e1ef68`) and head trees:
  - every `le_pr_write_wav` call hashes the file it wrote;
  - every successful `le_cache_render` hashes its wet buffer.

  Then I ran the full native core suite on both.
  - 226 performance-render WAV files (82 `master.wav`, 144 track stems): identical bytes and identical order.
  - 55 cache prints: identical as a multiset.
- **Probes** (my own test code against the production entry points; the results back the findings below):
  - reversed source with a Pre delay, live against render;
  - Once across a chosen-length window;
  - eviction of a live print by a render reservation;
  - configure latency during a recipe lane print.
- **Mutations of `engine_render.c`, run against the render tests:**
  - **Survived:**
    - `track_printed` forced to 0;
    - track-chain gain forced to 1;
    - Once clipped instead of wrapped;
    - the freeze length check removed;
    - the staging completion revision check removed;
    - lane pans dropped from the whole-track print.
  - **Killed:** right lane pan replaced by the left (144 failures).

## Verified correct (traced)

- **Freeze in the callback.** `le_render_freeze_apply` (`engine_process.c:165-191`) is real-time safe:
  - it only reads track and clock fields;
  - the loop is bounded by `track_count`;
  - it writes an engine-owned record and publishes `a_done` with release.

  The id gate (`a_id` stored before the push, matched in the callback) means a stale command for a cancelled job cannot touch a newer job's record. The control side reads the record only after `a_done == id` (acquire), and a ring is FIFO, so no write can overlap that read. 112 is refused on the raw post path (`engine.c:1528`) and excluded from `le_log_extract`.
- **The read law.**
  - `base0 = position − top` uses the same `e->clock.length > 0` branch as `le_track_base_position`, so shared-clock, Sync division and Free/Song sources each get the live law.
  - The Once start arithmetic matches `le_direction_index`/`le_direction_lap_start` in both directions.
  - Proven by the existing mid-loop Reverse test and by my probe: a Once source relaunched with a non-zero origin on a common cycle reads `3..16, 1, 2`, one full pass rotated, which is correct.
- **Worker ownership.** `a_render_runnable` and `a_render_worker_busy` are seq_cst on both sides (a Dekker pair), so `le_render_sweep_retired`/`le_render_retire` can never free a job the worker holds. Cancel sets `a_cancel`, which `le_fx_print` polls every 4096 frames, so the retire spin (`engine_render.c:311-313`) is short after a cancel.
- **Priority.** `le_render_worker_choice` is right as written:
  - prints for audible lanes go first;
  - a waiting recipe goes before stopped-lane prints;
  - after 8 audible prints the recipe gets one turn.

  The pick reads the track state on every turn, so a stopped track whose Transpose job is waiting is promoted as soon as it plays.
- **Against 3a's Transpose renders.**
  - 3a's kind-1 job is picked by the same `le_cache_pick`, so it ranks as an audible print for a playing track.
  - 3a's unsliced whole-track stretch can hold a recipe back by at most 8 such jobs before aging. That is latency, not starvation.
  - 3a's worker `nice +10` will cover the recipe too.
  - The two branches conflict textually in `le_cache_pick` and `le_ca_worker_main`. Whoever lands second must keep both the 3a pick and the `out_fallback` signature.
- **Cache refactor.**
  - `le_fx_frozen_fill` reproduces the old per-job copy: count, effective bits, params, channel handling.
  - `le_fx_print` reproduces the old two-pass render, the seeding and the abort cadence.
  - The new skip of `le_fx_prepare` for `LE_FX_PLUGIN` is behaviour-neutral, because that row's `prepare` is NULL (`engine_fx.c:1043`).
  - The byte-identity run above confirms all of this.
- **WAV writer.**
  - The header is little-endian by construction: format tag 3, block align `4 × channels`, byte rate, 32 bits.
  - RIFF size is `data + header − 8`, which with no extra chunk equals the old `36 + data`.
  - The data size is patched at `header_bytes − 4`.
  - Seal refuses a size beyond 32 bits instead of wrapping (the old `perf_render` code wrapped silently).
  - **#1198 fit.** With a 32-byte `sgno` chunk the writer's header is 84 bytes, laid out exactly as `RecordedPartHeader` on PR #1227 (RIFF 12, `fmt ` 24, `sgno` 40, `data` 8). Its 32-bit ceiling equals `maxDataBytes = 0xFFFFFFFF − 76`, so 2,000,000,000-byte parts fit.
  - `perf_render` keeps `sync = 0`, as before.
- **File target.**
  - It writes `<path>.part`, seals with fsync, renames, then calls `le_fs_sync_dir`.
  - Failure unlinks the part, and cancel removes it (tested).
  - Wrap's first pass writes nothing.
- **Staging.**
  - It copies from exactly the frozen slot.
  - On every chunk it checks revision, slot and state before the readable gate.
  - It checks `pool_cap` and re-checks the revisions at completion.
  - A stopped engine's `le_cache_shutdown` fails a running job with `DEVICE` (tested).
- **Live order.**
  - Lane: Pre print or dry × level, then lane Post, then pan.
  - Track: the whole-track print or a live track chain with `gain × fade` at the Pre/Post boundary (`fx_apply_chain_with_gain`).
  - Mix FX: one state over the sum.

  This matches `mix_tracks_frame`, and the Post-chain live parity test passes sample-exactly.

## Findings

### High

**H1. A reversed source with Pre effects renders differently from what is heard.**
- **Where.** `engine_render.c:795-796` (lane) and `:785-786` (whole-track print). The render reads the Pre print at `idx` from the reversed law, so it plays the forward print backwards. The live rig never does this:
  - a print engages only on a forward track (`engine_process.c:5980`, `:6137`, both `!tr->reversed`);
  - a toggle disengages every print (`:3330-3337`);
  - the mixer's own comment says "reversing a loop reverses the recording, not its effects, so the live chains run forward over the backward read" (`:5976-5979`).
- **Failure.** Track 2 has a Pre delay (or reverb) and is reversed. Save audio or Bounce produces a reverse-echo: the echo arrives before the note instead of after it.
- **Probe.** One lane, a Pre delay of 2,400 frames, a 6,000-frame loop with one impulse, reversed and played to steady state, then rendered with Cut. In loop-phase frames:
  - live: impulse at 1983, its echo 2,400 frames later at 4383;
  - render: impulse at 1983, its echo at 5583, which is 2,400 frames *before* the next impulse.

  This is AB §3.11's "as heard" contract broken for the normal use of Reverse.
- **Plan.** Plan 4.3 ("byte-identical to the published print whether or not the print is engaged") and the 4.6 Reverse row do not cover this case. See the plan delta.
- **Fix.**
  - For a reversed source, print its Pre (lane and whole-track) over the lap in read order: the dry reversed, then wrapped at `len`. Read that print forward at lap phase `(lap_start − idx)`. The steady-state live Pre on a reversed loop is exactly that wrapped print.
  - Add a live-parity test for a reversed source with a Pre delay. The probe above is a ready-made test.

### Medium

**M1. A recipe reservation can unpublish the Pre prints of playing tracks, and a finished job keeps them unpublished until cancel.**
- **Where.**
  - `le_cache_reserve` (`engine_cache.c:1314-1322`) calls `le_cache_ensure_budget`, which evicts LRU entries of every kind, including the entry a playing lane has engaged (`le_cache_drop_entry` stores NULL into `a_wet`).
  - The job's charge is released only on FAILED, cancel or the next begin (`engine_render.c:579-590`; cancel `:625`). A DONE job, including a file job that needs nothing after publish, holds all its staged and printed bytes.
- **Failure.** During a performance the player starts Save audio. Its reservation evicts the engaged Pre print of a playing track, and that lane falls back to its live Pre through the clean re-enable path (reset, ring clear, warmup, ramp). The reverb wash audibly restarts. The scheduler cannot re-print while the job holds the bytes, so the lane stays on the live path until the job is cancelled.
- **Probe.** A playing lane with an engaged Pre print, and a cap just under used plus the job:
  - after begin: `a_wet = NULL`;
  - 600 ms after DONE without cancel: still NULL, bytes still charged;
  - after cancel: the print returns.
- **Rule.** This is an audible change the player did not ask for (rule 3), and the plan's 4.7 does not state it.
- **Fix.**
  - On DONE, free a file job's staged dry, prints, states and slice buffer, and release its charge. A memory job keeps only `out`.
  - Make the recipe's reservation skip entries currently published for PLAYING lanes. Refuse with `CAPACITY` rather than evict them, or give the recipe its own budget sized against the cap.
  - Test: a playing lane's engaged print survives a recipe begin.

**M2. A configure or stop waits for a whole recipe lane print: the recipe ignores the cache's shutdown flag.**
- **Where.** `le_render_cancelled` (`engine_render.c:659-662`) polls only `j->a_cancel`. `le_cache_shutdown` sets `c->a_shutdown` (`engine_cache.c:1462`) and joins before `le_render_on_cache_shutdown` (`:1466`) touches the job.
- **Why it matters.** A setup unit is a whole lane print or whole-track print, two passes over `len` frames, so the join is no longer bounded by the cache's 4096-frame abort check. The cache's own print checks `a_shutdown`.
- **Probe.** One 30 s lane with a Pre reverb. `le_engine_configure` during the recipe's lane print took 1,138 ms on this Mac, against about 70 ms without a render. On the Pi it will be several times longer.
- **Failure.** A device reopen (#1140/#1158), a configure or a Stop blocks the control thread for seconds.
- **Fix.** Have the abort function also read `e->cache->a_shutdown`, or set `a_cancel` on the current job before the join. Test configure latency mid-print.

**M3. A Once pass that crosses the end of a chosen-length window plays the wrong material.**
- **Where.** `engine_render.c:776-779`. `sounding` wraps the pass by window phase (`mod(f − once_start, frames) < len`), but the index is still the live law's, `le_direction_index(…, base0 + f, len)`.
- **When it is correct.** Only when the window is a multiple of the span, which a common cycle always is. With a chosen length that is not a multiple, the wrapped part reads the law's index instead of continuing the pass.
- **Probe.** Span 30,000, chosen 1 bar = 38,400 frames, Once start d = 20,000.
  - The 11,600 wrapped frames read indices 10,000..21,599 instead of 18,400..29,999.
  - Frame 0 reads sample 10,001 where the continuation is 18,401.
  - The pass repeats some material and drops the rest (sum 352,575,000 against 450,015,000).
- **Window shorter than the span.** The rule degenerates: the source sounds on every frame and nothing is silent. The plan does not say what should happen.
- **Untested.** The mutation that clips instead of wrapping survives, and the build record says the relaunch case is untested.
- **Fix.**
  - For a Once source, compute the index from the pass phase: `p = mod(f − d, W)`, index = the lap index `p` steps from the lap start in the source's direction when `p < len`.
  - Define `W < len`, for example as one pass from `d` truncated at the window.
  - Add literal tests: a common cycle with a relaunch, a chosen length not a multiple, and `W < len`.

**M4. Two production audio paths and two safety checks have no test.**
- **Mutations that survived the render suite:**
  - `track_printed` forced to 0, so the whole-track print path is never used;
  - lane pans dropped from the whole-track print source;
  - the track-chain gain forced to 1 (`fx_apply_chain_with_gain` with `g`, `engine_render.c:818-820`);
  - the freeze length check removed (`:471-472`);
  - the staging completion revision check removed (`:543-548`).
- **Coverage.** No test puts a chain on the track bus, so neither the whole-track print nor the live track chain runs.
- **Plan tests built weaker than listed:**
  - `test_render_excludes_buses` only adds one output FX entry and one input block (plan: monitors, click, master 0.5, limiter);
  - `test_render_wrap_vs_cut_tail` checks energy, not equality with pass 2 of a two-window run;
  - Fade "moving during staging", Free sources' own lap start and "an overdub admitted while staging" are missing.
- **Build record.** It lists only two omitted tests.
- **Fix.**
  - Literal tests: a track Pre (whole-track print, with pans), a track Post with gain ≠ 1, a source whose length changes between begin and freeze, and a revision bumped after the last chunk.
  - Correct the build record.

### Low

- **L1. The slice bound is not true for setup units.** `engine_render.c:670-713` renders each lane or track print in one worker turn, and that is two passes over the source length. Plan 4.1 and 4.7 say a recipe "never holds back a Pre print or Transpose render for a playing lane by more than one slice". In fact a lane print of the source's length goes first. That equals one cache print of the same lane, so it is acceptable, but the plan text should say so. Slicing the prints is an alternative.
- **L2. The measure doc promises a refusal that is not implemented.** The API comment (`segno_engine_api.h`, `le_engine_render_measure`) promises `LE_ERR_NOT_READY` for "an unacknowledged state command". `le_render_measure_impl` uses `le_effective_state`, which reads the pending target, and only staging waits on `le_engine_commands_settled`. Either implement the refusal or reword the comment.
- **L3. A failed directory sync reports a published file as failed.** When `le_wav_publish` renames successfully but `le_fs_sync_dir` then fails, the job reports `DEVICE` while the final file exists and has replaced any previous file at that path. `remove(j->part_path)` (`engine_render.c:883`) is then a no-op. Report the publish as done with a durability warning, or document that `DEVICE` can leave the file in place.
- **L4. The writer cannot yet serve #1198's checkpoints.** #1198's drain `fflush`es every cycle and its checkpoint thread fsyncs parts in place. Recovery re-patches the sizes of a truncated part (`recording-recovery-plan` D4). `engine_wav.h` has no flush call and no "patch sizes of an existing file" call, so the drain would reach into `w->file` or write its own patcher. Add `le_wav_flush` and a size-patch helper when #1198 Part 2 adopts the writer. Separately, an odd `chunk_bytes` is written without the RIFF pad byte, so the header comment's "an even size keeps RIFF word alignment" should become a check.
- **L5. Uncharged memory.** `le_render_job_bytes` (`engine_render.c:327-342`) does not count the heap `le_fx_state`s: one per lane with Post, per track chain, per Mix FX, plus one per print. Delay and reverb rings are sized by `fx_delay_frames`. `le_fx_print` also prepares every entry of a lane's chain, Post included, for a Pre-only print (`engine_cache.c` `le_fx_print` → `le_fx_frozen_state_init(fx, c, 0, count, cap)` prepares `[0, c->count)`). Prepare only `[0, count)` and charge the states.
- **L6. The default cap refuses an ordinary set.** On this trunk the cap is 64 MiB (`LE_CACHE_DEFAULT_CAP_BYTES`). An eight-track set of stereo 30 s loops stages 16 × 5.76 MB = 92 MB of dry alone, so Save audio of the whole rig returns `CAPACITY` until pitch/time 3a raises the cap to 384 MiB. The build record says so. Part 3 must not ship before the larger cap or a dedicated budget (see M1).

## Size

About 1,300 production lines against the plan's 700. I would not split the recipe further. `engine_render.c` is one cohesive unit (measure, begin, freeze, staging, worker, targets), and any cut leaves an API that cannot complete a job.

Commit 1 (`eb8fe6055`) is the natural boundary:
- it is behaviour-neutral (I proved byte identity above);
- it already passes on its own;
- #1198 Part 2 needs `engine_wav` too.

Review it commit by commit in this PR. Cherry-pick it into its own PR only if #1198 Part 2 needs the writer before this lands. Avoid a stacked pair, because of the squash-merge hazards on stacked PRs.

## Notes

- **The telemetry-off failure is a pre-existing flake.** It is `test_fade_restore_staging_and_manifest_capacity` waiting for the parked staging ring to drain (`test_engine_fade.h:896-898`). That file is unchanged by this PR. I looped the test 40 times per run on both trees:
  - **base, telemetry on:** failed in 1 of 5 loops;
  - **head, telemetry off:** failed in 3 of 9 loops (one loop had 19 failures);
  - **base, telemetry off:** 0 failures in 8 loops;
  - **head, telemetry on:** 0 failures in 5 loops;
  - **full telemetry-off suite:** head failed 2 of 3 runs, base 0 of 2.

  So it fails on base too, and I found no code path from this PR into the perf drain. Head's rate in my sampling is higher, so watch CI's telemetry-off job on this PR before trusting it.
- **TSAN coverage.** CI's TSAN job builds only the race binaries, so the recipe's worker/control handoff is not under TSAN in CI. My local TSAN run of the render tests is clean. Consider adding `test_engine_render.h` to a TSAN target.
- **Unfinished pieces.** `pending_mask` is always 0 until pitch/time Transpose lands, as the plan says. The plan's `CANCELLED` state does not exist; cancel retires the id. Both are fine; the plan text should match.
- **Device loss.** A job whose freeze is posted while the device is present but not calling back stays FREEZING until the reopen's configure fails it with `DEVICE`. Part 2's poller should time out on FREEZING.

Verdict: Request changes

## Delta review (1ac22cb9b)

### Scope

- `origin/claude/render-1202-p1` at `1ac22cb9b`.
  - The fix is `26b98ace6`: engine_render, engine_cache, engine_wav, the API comments, the bindings and the tests.
  - The rest is a merge of the trunk, which also brings `67a02d571`, the fix for the fade staging flake I reported under Notes.
- Re-read every changed hunk.
- Compared `engine_wav.c/.h` with #1245 (`origin/claude/recording-1198-p2` at `51696d5f3`), which will rebase onto them.

### Runs

All in my own worktree at `1ac22cb9b`, each with its own `TMPDIR`.

- **Native plain x3:** ALL PASSED x3.
- **TSAN races:** pass, no reports.
- **ASAN+UBSAN:** pass, no reports.
- **Telemetry-off:** pass. The fade flake is gone with `67a02d571`.
- **My first-round probes, re-run on this code:**
  - **Reversed Pre:** the echo now follows the note, at the same loop phase as live (783/1983/3183/4383/5583 in both).
  - **Once, span 30,000 in a 38,400-frame window, start 20,000:** frame 0 reads 18,401, which continues the pass; the pass sum is exact.
  - **Eviction:** a playing lane's engaged print stays published through begin, DONE and cancel, and the cache's used bytes do not move.
  - **Configure during a 30 s Pre reverb print:** 15.9 ms, down from 1,138 ms.
- **Mutations of `engine_render.c`, two rounds of the render tests each.**
  - **All six survivors from the first round are now killed:**
    - `track_printed` forced to 0;
    - track-chain gain forced to 1;
    - Once clipped;
    - freeze length check removed;
    - completion revision check removed;
    - whole-track print without pans.
  - **New fixes, killed:**
    - reversed layout skipped;
    - shutdown check removed;
    - DONE release removed;
    - a short window wrapping.
  - **Survived:** a reversed Once read in forward order (L-D2 below).

### The asked-for checks

- **Reversed Pre parity: fixed.**
  - A first setup unit lays each reversed source's staged dry in read order. Lane and whole-track prints are made over that layout, and the window reads them at the lap phase (`idx = len − 1 − idx`).
  - Traced: material index `len − 1 − idx_live` walks forward one per frame and wraps with the lap, so the wrapped print is the live forward chain's steady state over the backward read.
  - The probe and the new `test_render_reversed_pre_live_parity` agree.
  - With a feedback delay, live and render differ by about 0.5% in level (0.654 against 0.650). That is the documented [R5] one-lap accumulation of every cached print, not this bug.
- **Own 256 MiB budget, no eviction, release on finish: fixed.**
  - `le_cache_reserve`/`le_cache_release` are gone; the job is checked against `LE_RENDER_BUDGET_BYTES` and never touches the cache's entries.
  - The tick frees a finished job once the worker is provably out: a FAILED job and a DONE file job keep nothing, and a DONE memory job keeps `out` (`2 × frames × 4` bytes).
  - Effect states are now charged (L5), and `le_fx_frozen_state_init` prepares only `[from, to)`.
  - The worst case the process holds is the cache cap plus 256 MiB. The plan says so.
- **Shutdown honoured: fixed.** `le_render_cancelled` reads `le_cache_shutting_down(j->engine)`. The worker reads `engine->cache` while the cache is alive, because the join precedes the free. A slice (48,000 frames) is the remaining unchecked span, which is acceptable.
- **Once on a chosen length: fixed per the plan's three cases.** On a common cycle, and on a chosen length with W ≥ len, the pass phase is `p = (f − d) mod W`. With W < len it is `p = f − d`. The index is the lap index `p` from the lap start. `test_render_once_chosen_length` checks the wrap and the short window literally.
- **The lows:**
  - **L1:** the plan now states the slice bound as one source-length print.
  - **L2:** the measure comment now says what is refused.
  - **L3:** `le_wav_publish` returns 2 when only the directory sync failed, and the job reads DONE.
  - **L4:** the flush and size-patch calls exist, and an odd chunk is refused.
  - **L5:** fixed, as above.
  - **L6:** answered by the own budget.

### `le_wav_flush` and `le_wav_patch_sizes` against #1245's needs

- **Layout.** The writer still produces #1227/#1245's 84-byte part header. #1245's open, cloexec descriptor and `le_wav_note_frames` are in this branch verbatim.
- **`le_wav_flush`** is `fflush` with failure latched into `w->failed`. #1245 flushes through its own `le_pd_flush(pf->w.file)` (`perf_drain.c:837`, `:1702-1707`) and should switch to this call on rebase. Its checkpoint thread syncs by its own descriptor, which this design supports.
- **`le_wav_patch_sizes` is correct for recovery:**
  - it walks chunks to `data`, tolerating a zero `data` size and the `sgno` chunk;
  - it accepts only float32 with a matching block align;
  - it keeps `min(whole frames, max_frames)` frames and truncates a torn tail;
  - it patches both sizes, checking the 32-bit ceiling, and fsyncs;
  - the reads, seeks and writes on the `r+b` stream are separated by seeks, and the stream is flushed before `ftruncate`.
  - `test_wav_flush_and_patch_sizes` covers the repair, the cut-back and a non-WAV refusal.

### Findings

**M-D1 (Medium). #1245 needs a seal truncation that this branch does not have.**
- **Divergence.** #1245's `engine_wav.c` truncates the file at seal to `header + data` (`51696d5f3`, "Cut anything past the declared data: a short write leaves a torn partial frame there"). This branch's `le_wav_seal` (`engine_wav.c:115-139`) does not.
- **Why #1245 needs it.** Its drain rewinds over a torn frame with `fseek(pf->w.file, −torn, SEEK_CUR)` (`perf_drain.c:1041`) and relies on seal to remove the residue.
- **Failure.** The two files conflict when #1245 rebases. If the conflict resolves to this branch's seal, a part sealed after a short write keeps trailing bytes past its `data` chunk: the file size disagrees with the header, and the tail is not part of the digest.
- **Fix.** Take #1245's truncation into this branch's `le_wav_seal` (`ftruncate`/`_chsize_s` to `header_bytes + data_bytes` after the size patch). It is a no-op for the recipe and the performance renderer. Add a test: append a partial frame through `w->file`, call `le_wav_note_frames` for the whole frames, seal, and check the exact size.

**L-D1 (Low). A Once whose start lies past a short window is silent with no warning.**
- **When.** With W < len, a Once whose start `d` falls at or after W contributes nothing to the render.
- **Probe.** A span of 60,000 frames in a 38,400-frame window, with a relaunch origin, gave 0 sounding frames.
- **Plan.** This follows the plan's "one pass from d, cut at the window end".
- **Fix.** A source that sounds nowhere should be reported in the plan, for example in a new `silent_mask`, so the surfaces can say "Track N is a Once track outside the chosen length". Alternatively, define the case and test it.

**L-D2 (Low). No test reads a reversed Once.** The mutation that drops the reversed branch of the Once index (`idx = p` instead of `len − 1 − p`) survives both rounds of the render tests. A reversed Once source would then play forward. Add a literal test with a reversed Once on a common cycle.

**L-D3 (Low). The salvage is about to be written twice.** `le_wav_patch_sizes` is not `LE_EXPORT`ed. #1245's salvage seals open parts in Dart instead (`performance_repository.dart:939-944`, `_sealOpenParts`, "Part 8 replaces this"), so there are two size-patching implementations. Either export a repair entry so the Dart salvage calls the native one, or have Part 8 move salvage native as planned and drop `_sealOpenParts` then. Record which in #1245 (rule 4).

### Notes

- **Budget headroom.** The 256 MiB budget refuses a set whose lane prints double its staged size: sixteen lanes, all with Pre, at 48 kHz × 30 s comes to about 264 MiB. Freeing a lane's dry once its Pre print exists would roughly halve the peak for Pre-heavy sets. Not blocking.
- **Configure timing test.** `test_render_configure_mid_print` asserts on wall time (`configure * 2 < whole`), against a reference print measured in the same run, so it is resilient to load. It passed in all six of my runs, including ASAN.

Verdict: Request changes (M-D1 only; the first-round findings are all resolved)

## Delta review (07d65b615)

### Scope

- `07d65b615` on top of `1ac22cb9b`. It touches:
  - `engine_render.c/.h` (staging budget and progress, `once_cut_mask`);
  - `engine_wav.c/.h` (seal truncation; `le_wav_patch_sizes` moved to the API);
  - `segno_engine_api.h`, the bindings and the tests.

### Runs

- Native plain at `07d65b615`: ALL PASSED.
- The same code is also inside the 4a head, where it ran:
  - plain x3, TSAN races and telemetry-off: all pass;
  - ASAN: one failure under load, see Notes.
- Mutations on the render and WAV code, all killed:

  | Mutation | Failures |
  |---|---|
  | seal without truncation | 2 |
  | reversed Once read forward (the survivor from last round) | 17 |
  | `once_cut_mask` never set | 2 |
  | staging progress not published | 2 |

### The asked-for checks

- **Seal truncation: done** (M-D1 resolved).
  - `le_wav_seal` truncates to header plus data after the size patch and the flush, then fsyncs. This matches #1245's `51696d5f3`.
  - It is a no-op for the recipe and `perf_render`, so byte identity is unaffected.
  - `test_wav_seal_cuts_torn_frame` writes two frames plus 3 torn bytes through `w.file`, credits two frames, and checks the exact 60-byte file.
- **`le_wav_patch_sizes` exported: done** (L-D3 resolved on the engine side).
  - It is declared `LE_EXPORT` in `segno_engine_api.h`. `engine_wav.c` includes that header before the definition, so the export attribute applies.
  - The bindings are regenerated.
  - #1245's Dart `_sealOpenParts` can now call it. That switch belongs to #1245.
- **`once_cut_mask`: done** (L-D1 resolved).
  - Measure names every Once source whose span exceeds the window. That only happens with a chosen length, because a common cycle is a multiple of every span.
  - It is a conservative flag: it names a source whose pass is partly or wholly outside the window.
  - Part 2 surfaces it as `onceCutTracks`.
- **The reversed-Once test: done** (L-D2 resolved). `test_render_once_reversed` checks A[15]..A[0] once, then silence, literally. The mutation that survived last round now fails it.
- **Staging progress with a 2 ms budget: done.**
  - Staging copies chunks until 2 ms have passed, always at least one per heartbeat.
  - It publishes a permille on the same scale as the render (staged chunks plus setup units plus slices), so progress is monotonic across the phase change.
  - `test_render_staging_progress` steps it one chunk at a time.
  - The per-chunk revision, slot and state checks still run on every chunk inside the budget.

### Findings

**L-E1 (Low). A timing assertion fails under load with ASAN.**
- **Where.** `test_render_configure_mid_print` measures an undisturbed 30 s Pre-reverb render, then interrupts one. Its first step, `rr_wait` (`test_engine_render.h:946`), allows 10 s.
- **Observed.** The ASAN run at the 4a head failed there: `rr_wait == DONE` at `:946`. Dart suites were running at the same time. The same test passed under ASAN with no other load (two runs).
- **Risk.** CI's ASAN job runs on a slower Linux runner, so this can go red at random.
- **Fix.** Use a shorter lane (for example 5 s), or give the reference render a longer bound. Keep the ratio assertion.

**L-E2 (Low). The staging budget is a mutable global.** `le_render_stage_budget_ns` is a writable global in production code, exported for tests. It is only touched on the control thread, so this is harmless today. Consider gating it under `LE_NATIVE_TESTS`, as the other test hooks are.

### Notes

- Behaviour is unchanged for existing users of the writer: `perf_render` still writes sealed files without fsync.

Verdict: Approve
