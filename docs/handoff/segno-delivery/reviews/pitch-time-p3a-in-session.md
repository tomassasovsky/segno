Model: Claude Opus (subagent), in-session

# Review of PR #1214 (origin/claude/pitch-time-1179-p3a, fd3b8970d): feat(engine): transpose tracks through source renders on the cache worker

## Scope

- **The commit:** one commit, `fd3b8970d`, on top of Part 2b (`ffe645ef9`), touching 21 files.
- **Size:** 903 production lines added and 63 removed (core, stretch, API). That counts comments and excludes tests, bindings and docs. The plan estimated about 450, and the ceiling is 700.
- **Reviewed against:**
  - plan `docs/plan/2026-10-06-feat-pitch-time-core-plan.md` §3, Part 3a (`:896-966`, including its "As built" addendum), and decisions 5-7, 11, 16, 17 and 19-20;
  - the numbering ledger;
  - the instruments plan (`origin/claude/instruments-plan-1197`, D2) for the shared CPU budget;
  - AGENTS.md and the owner rules;
  - the pen's "11 Performance · Transpose" screens (k5GTy, FJ8Ys), read through the pencil MCP and not saved.

## Runs

| Run | Result |
|---|---|
| `git merge-tree` against `origin/claude/segno-integration` (`7a9fdcbd9`) | clean |
| Native suite, plain | ALL PASSED x5, exit 0 |
| Native suite, ASAN | ALL PASSED x5, exit 0 |
| Native suite, telemetry-off | ALL PASSED x5, exit 0 |
| TSAN races job (`NATIVE_TESTS_ONLY=races`, clang `-fsanitize=thread`) | ALL PASSED; plugin runtime races 0; FX recipe 0. This binary does not touch the cache, the pins or the worker. |
| The core test binary under TSAN through the Reverse, Speed and Transpose tests (a real cache worker thread against the callback and the drain) | 43 tests, 0 failures, 0 TSAN warnings |
| `flutter test` packages/segno_engine (SEGNO_ENGINE_LIB from `build_test_lib.sh`) | +372, all passed |
| `flutter test` packages/looper_repository | +808, all passed |
| `dart analyze --fatal-infos` on both packages | clean |
| Bindings | the four new functions and three snapshot fields are present |
| 15 mutations through the transpose gate (ASAN for the pin mutations) | 10 killed, 5 survived (below) |
| Reviewer probes (`test_rv_probes.h`, saved beside this review), on the real code and under the four surviving mutations; the mutation runner `mutate.py` is saved too | below |
| Loop-fold loudness probe (`foldprobe2.c`, saved beside this review: `le_stretch_render_loop` with fold 20 ms against fold 0) | below |

Mutations (each applied alone, then reverted):

| Mutation | Result |
|---|---|
| T1 a PLAYING track's render is evictable (E7) | killed (`test_transpose_eviction_and_budget`) |
| T2 no pin check in the sweep | killed (ASAN heap-use-after-free) |
| T3 no `a_src_pin` (the pin on the render a lane selects) | **survived** |
| T4 no `a_turn_src` (the pin on the window's old source) | killed (ASAN heap-use-after-free) |
| T5 equal-gain law for a source swap | killed (480 checks) |
| T6 no callback drop of a punch-in on a transposed track | killed |
| T7 no 328 at PERF_ARM for a track sounding transposed | **survived** |
| T8 no loop fold | killed (wrap step) |
| T9 the verdict checks lane 0 only | **survived** |
| T10 Pre prints engage on a transposed track | **survived** |
| T11 Clear keeps the pitch | killed |
| T12 no control-side Record guard | killed |
| T13 a render whose key moved during the job is still published | survived. Equivalent in practice: the callback's verdict re-checks the key (`le_src_entry_key_matches`), so a stale render is never selected. |
| T14 the renderer renders dry | killed (stem parity) |
| T15 `le_engine_reset_material` keeps the pitch | survived; see L3 |

## Verified correct (traced)

- **The key (E8).** `le_wet_entry` gains `kind/semitones/out_len` inside the one predicate (`engine_private.h`).
  - Prints key through `le_wet_entry_key_matches` with kind 0, shift 0 and their own length.
  - Source renders key through `le_src_entry_key_matches` with `chain_fp = vol_bits = 0`.
  - `test_transpose_rekey_and_key_independence` proves a volume move and a chain edit do not re-render.
- **One job per track; lanes publish together.**
  - `le_cache_schedule_source` (`engine_cache.c:1193`) enqueues a copy of every active lane at one key.
  - `le_cache_collect` installs every lane or none, and only if `le_ca_source_current` still holds.
  - The callback engages only when every active lane holds a matching render, so a track never plays two pitches. The code is right; the test is missing (T9, M2).
- **Dry until ready, then an equal-power swap at the same index.**
  - `le_transpose_select` (`engine_process.c:5295`) runs once per buffer after the commands.
  - On a change of source it starts a window with `prev_head = head` and pins the old sources (`le_turn_sources(tr, 1)`), then logs 328 with the exact index.
  - The mix reads `src_ent[l]->pcm` or the dry `lbuf`, and the old head reads `turn_ent[l]`.
  - The test checks the equal-power mix sample by sample against the render a lap later, and stem parity to 2e-3. T5 and T14 are killed.
- **Pins and the use-after-free guard (E4).** Two pins protect a render: `a_src_pin` (the render a lane selects) and `a_turn_src` (the render a window's old head reads). The sweep (`engine_cache.c:360-381`) defers the free of either, with or without a device, and shutdown force-frees and resets both.
  - The ordering holds in both modes:
    - **Device present:** a retraction is followed by two observed `a_frames` changes before the sweep can free. By then the callback has run `le_transpose_select` at least once after the retraction, and has moved the render from `a_src_pin` to `a_turn_src`; `le_turn_sources` stores the turn pin before it clears the selection pin.
    - **Device-free:** the drain and the callback run on one thread, so the sweep never interleaves with a verdict.
  - T2 and T4 die under ASAN.
  - My probe P-T3 (cap to 0 while a render is engaged, with no bypass first) shows the selection pin is load-bearing in a device-free host. T3 makes it a heap-use-after-free under ASAN, and no shipped test catches it (M2).
  - TSAN over the Transpose tests with the real worker is clean.
- **Cache eviction while playing (E7).**
  - `le_ca_evictable` protects a source render that is the current key of a PLAYING, unbypassed track.
  - `le_cache_ensure_budget` evicts prints before any source render.
  - A job that cannot fit is refused with `LE_CACHE_REASON_BUDGET`, and the track stays dry and reported.
  - The test drops the cap below the playing render and the render survives. T1 is killed.
  - My probe also shows that a track refused for budget picks up again once room appears (track 0 back to 0 st and stopped): it does not stay given-up.
- **Commands and guards.**
  - 86/87 go through the receipt table.
  - A step clamps on control and answers `LE_ERR_CAPACITY` at the limit.
  - Install accepts an imported, uncommitted EMPTY track. Import posts `LE_CMD_RESET_TRANSFORMS` first (`engine_session.c:138`), so ring order keeps the installed pitch.
  - Control refuses a punch-in with `LE_ERR_TRANSFORMED` using the predicted pitch and bypass (`le_effective_transposed`), and the callback drops one that fires anyway.
  - `le_engine_post_command` refuses raw 86/87.
- **Resets.** Pitch dies with the material (`le_head_reset`), and Clear followed by Undo returns 0 st. Bypass is material at configure and is predicted on control across reopen.
- **Numbering.**
  - 86/87, 328 and the reuse of -10 are inside the ledger's ranges (86-87, 328-331, -11 reserved and unused).
  - events.log version 9 collides with Multiply/Divide P1's 9 (`origin/claude/multiply-divide-1168-p1:perf_drain.c:826`). Versions are assigned at landing, so this is flagged, not counted.
- **Worker priority (E9).** `setpriority(PRIO_PROCESS, gettid, 10)` (`engine_cache.c:1601`) is per thread on Linux, does nothing elsewhere, and needs no privilege to lower priority. It also slows Pre-print renders under UI load. That is a side effect, not a defect.
- **The probes pass on the real code:**
  - P-T7: a capture armed while transposed renders a stem equal to live over 48000 frames.
  - P-T9: two lanes at +12 st both move: the 660 Hz to 330 Hz power ratio is 2.6e5.
  - P-T10: a Pre print that was engaged never re-engages while the track sounds transposed.

## Findings

### High

None.

### Medium

**M1. "Undo is not cache-hot" leaves a stated success criterion unmet, and Undo on a transposed track drops to true pitch while it re-renders.**

- **What the plan requires:**
  - Part 3a's test list asks that "Undo to a previously rendered slot re-engages its cached entry within one block".
  - The second success criterion (`plan:933`) still lists "Undo re-engagement".
  - Only the "As built" note (`plan:954`) records the departure.
- **Probe:**
  - Setup: overdub a take, transpose to +5, wait until it sounds +5, then Undo.
  - Result: `effective` reads 0 in the next block and returns to 5 after 5760 frames (120 ms: the 100 ms settle plus the render of a 0.5 s lane on this machine).
  - On the appliance the plan's own figures put a 30 s lane at about 1.6 s and eight lanes at about 12 s of true pitch.
  - It is reported (rule 3 is met), but it is an audible pitch drop on a common performance gesture: undo a layer on a transposed loop.
- **The stated obstacle is narrower than "the content revision rule all three entry kinds share".**
  - Kind 1 already has its own key predicate, and history slots are immutable once retired (that is what #1143's `slot_image` relies on).
  - A per-slot content generation, bumped only where a slot's PCM is written and used in the kind-1 key in place of `a_audio_rev`, would make Undo and Redo hits without touching prints.
  - `slot_image` itself cannot be the key: it is per capture and zeroed at arm.
- **Fix (pick one):**
  - take that change here;
  - or amend the success criterion and the test list, and file the follow-up issue with the measured gap, so the owner signs off on the deviation knowingly.

**M2. Four load-bearing paths have no test; each mutation passes the whole suite.**

| Mutation | What is untested | Probe result under the mutation |
|---|---|---|
| T3 | The selection pin `a_src_pin`, the only guard when a render is retracted while selected (cap to 0 or eviction) in a device-free host, which the Dart pump and the tests are | P-T3 fails: ASAN heap-use-after-free |
| T7 | The 328 at PERF_ARM for a track already sounding transposed | P-T7 fails: 47818 of 48000 stem frames wrong. A capture armed during a transposed performance renders a dry stem without failing, which breaks "the stem is exact or fails". |
| T9 | Multi-lane engagement, "a track never plays two pitches" | P-T9 fails: lane 1 stays at 330 Hz while lane 0 moves |
| T10 | Pre prints never engage on a transposed track (decision 7) | P-T10 fails: the print engages and plays the dry pitch |

- **Fix:** add the four probes as tests. They are written in `test_rv_probes.h`, saved beside this review (`probe_src_pin_cap_drop`, `probe_arm_while_transposed`, `probe_two_lanes`, `probe_print_while_transposed`), and pass on the head as is.

**M3. The appliance gate does not cover the CPU this part adds to the audio thread, or the combination with instruments.**

- **What the gate measures:** the hardware criterion (`plan:934`, findings "What the owner measures") checks render speed, `late_periods` during eight renders, and a listening check.
- **What it does not measure:**
  - A transposed track never engages a Pre print (decision 7), so every chain on it runs live on the audio thread. With all eight tracks transposed, the print system's saving is gone.
  - The Part 2a bench rig has no chains, and only its 8 x 1 Speed row is judged (2a delta L-D2). The 50 % budget is therefore unverified for 8 x 8 with live chains at a Speed, plus Transpose.
  - The instruments plan (#1197, D2) claims up to 15-30 % of the same period for 32-64 voices, and its own 50 % re-measure sits on "the pitch/time baseline (8 tracks x 8 lanes)", which has no chains.
  - On memory: the cap is a shared 384 MiB (up from 64 MiB), and Pre prints alone may now use all of it, a sixfold rise even with no Transpose in use. A job in flight also holds `2 x lanes x len` floats plus a stretcher (under 4 MiB, measured in Part 1). A Pi 5 with 8 GiB holds that, but no peak RSS of the app with eight transposed tracks is recorded.
- **Fix:** add to the owner's appliance list for this merge:
  - (a) 8 x 8 with a Pre chain on every lane, all transposed (prints off) at 8x, p99 against the period;
  - (b) the same with 32 instrument voices once #1197 Part 1 exists, or a note that the instruments gate must include it;
  - (c) the app's peak RSS during eight 30 s renders at 96 kHz.

### Low

**L1. The 20 ms loop fold changes loudness at the loop point by up to about 5 dB.**

- **Where:** `le_stretch_render_loop` (`le_stretch.cpp:298-313`).
- **Cause:** the two signals folded together (the head rendered after the tail, and the run-out continuing past the lap) are renders of the same input, so they are correlated. The fixed equal-power law then bumps or dips depending on their phase.
- **Probe:** RMS over the middle of the fold, compared with the same region of the unfolded render:

| Input | Change |
|---|---|
| Three-tone chord, 0.5 s lap, +3 st | -4.0 dB |
| Three-tone chord, 0.5 s lap, +8 st | -5.2 dB |
| Three-tone chord, 2 s lap, -2 st | +4.6 dB |
| White noise | -3.3 to +1.5 dB |

- **Effect:** a 10-20 ms swell or dip once per lap is plausibly audible on sustained material.
- **Fix:** use equal-gain for the fold (the seam's own law for correlated signals, E5), or blend the two laws by the measured correlation. Make the hardware listening check at the loop point use a sustained chord.

**L2. A source render a STOPPED track will need is evictable.**

- **Where:** `le_ca_evictable` (`engine_cache.c:470`) protects only PLAYING tracks.
- **Scenario:** after Stop All, a print or another track's Transpose job can evict a stopped track's render (prints go first, but a source job evicts source renders). The next Play then sounds the dry pitch for the re-render time. It is reported, as E7 allows.
- **Fix:** protect any render whose key is current for a track with material and a non-zero, unbypassed pitch, and refuse the new job instead. This follows the existing rule: a job that cannot fit is refused rather than displacing an engaged render.

**L3. Tests are missing for the material-reset path and the stopped-device pins.**

- T15 survives. Since the pitch also resets at every new capture this is low risk, but `le_engine_reset_material` resetting `transpose_st` and bypass is untested.
- With the device stopped (`a_running` 0) a retracted, pinned render waits in the graveyard until the callback runs again or the cache shuts down. That is bounded by design, but it no longer matches the graveyard comment "the push cannot fail".
- **Fix:** update the comment, or size the graveyard for `2 x LE_MAX_TRACKS x LE_MAX_LANES` pinned entries on top of the books.

**L4. A source swap inside a Speed or Reverse window restarts the window.**

- **Where:** `le_transpose_select` (`engine_process.c:5327`) sets `prev_head = head` unconditionally. The addendum says so.
- **Effect:** the rate turn's old head is dropped mid-fade.
- **Probe:** 2x, then bypass 320 frames into the 480-frame window. The largest step afterwards is 0.044, against 0.017 without the Speed step, on a 0.5 sine whose steepest legitimate step at 2x and +5 st is about 0.038. No click above the material's own slope.
- **Fix:** none needed. Keep the addendum, and add a test that pins the bound.

## Should the size overrun be split?

No. The 903 lines are about 450 on the cache side (the job, render, install, eviction and pins in `engine_cache.c` plus the stretch loop) and about 450 on the callback side (the verdict, the swap window, commands, guards, the 328 fact and renderer replay).

- Neither half can be tested alone. The cache side needs a stored pitch to render, and the callback side needs a render to swap to.
- The one lifetime question that matters, the pins, spans both halves.
- The only clean seam is the renderer (about 110 lines). Splitting it out would leave the first PR either writing a stem that is silently wrong or failing every transposed stem, and still about 800 lines.
- Keep it as one PR. Say so in the PR body, and note that 163 of the 903 added lines (18 %) are comment-only.

## Notes

- **Hardware gate.** Part 3a's merge is gated on the owner's Pi 5 run (E11, plan decision 20). Nothing here substitutes for it.
- **A semitone step plays dry until its render lands.** `le_cache_schedule_source` keeps retired renders for a step back (two entries per lane under LRU). A semitone step plays dry until the new key renders (decision 5, §8 question 3), rather than keeping the previous pitch. That is consistent with the plan.
- **Overdub while bypassed.** Overdub is allowed while bypassed, and un-bypassing then transposes the new layer too. This is the plan's rule (`transpose_st != 0 && !bypass`), and the test pins it. The owner may want it on the Transpose face's checklist, since the bypass tile says "pitches retained".
- **Pin sweep load order.** The sweep reads `a_turn_src` before `a_src_pin`, while the callback writes the turn pin and then clears the selection pin. That is safe under the two rules traced above. Reading `a_src_pin` first would make the check correct without relying on them, at no cost.
- **Probe-only edits.** I made them in a scratch worktree and did not keep them.

Verdict: Request changes (M1 needs the owner's sign-off or the per-slot key; M2 is four tests already written; M3 is items on the owner's appliance list; the merge stays gated on the Pi 5 run).

## Delta review (0725bb619)

Model: Claude Opus (subagent), in-session

### Scope

- `ed04a95ca`: the rebase of `fd3b8970d`. `git range-diff` shows context changes only (it now sits on 2a's `36debe826` and 2b's `ddda2e10d`).
- `0725bb619` "fix(engine): make Transpose Undo cache-hot, hold the loop fold's level, keep stopped renders", which adds:
  - `a_src_key` / `a_slot_key` and `pass_key`;
  - two published candidates per lane (`a_src[LE_SRC_CANDIDATES]`);
  - the fold law;
  - `le_ca_evictable` for stopped tracks;
  - graveyard sizing;
  - the 192 MiB cap and the joint budget text;
  - the bench row with every track transposed;
  - six new transpose tests and a fold-level test.

### Runs

| Run | Result |
|---|---|
| `git merge-tree` against `origin/claude/segno-integration` (`890f04936`) | conflicts in `segno_engine_api.h` and the regenerated bindings only: the trunk's `LE_ERR_NOT_FOUND`/`LE_ERR_TRUNCATED` (#1198) sit where this stack adds `LE_ERR_TRANSFORMED`. Both are kept by hand, then ffigen is re-run. A rebase chore, not a defect. |
| Native suite, plain / ASAN / telemetry-off | ALL PASSED x5 each, exit 0 |
| Core test binary under TSAN through the Reverse, Speed and Transpose tests, with the real cache worker | 51 tests, 0 failures, 0 TSAN warnings |
| 9 mutations on the new code (below) | 5 killed, 4 survived |
| Fold probe (`foldprobe2.c` and a bass variant) through this head's `le_stretch_render_loop` against fold 0 | below |

| Mutation | Result |
|---|---|
| K1 Undo/Redo never reuse the slot's key | killed (`test_transpose_undo_redo_cache_hot`) |
| K2 no key filed for a first pass's pre-image | killed (same) |
| K3 a slot handed out for new PCM keeps its old key (`engine_commands.c:163`) | **survived** |
| K4 no `copy_rev` seqlock on a source copy | survived; unreachable today (see Notes) |
| K5 a stopped track's render evictable again | killed |
| K6 the callback looks at one candidate only | killed |
| K7 the fold back to a plain linear blend (g = 1) | killed (`fabs(db) <= 1.5`, 24 checks) |
| K8 `pass_key` not cleared after the first pass (`engine_process.c:1625`) | **survived** |
| K9 an import does not forget slot keys | **survived** |

### Status of the first review's findings

- **M1 (Undo not cache-hot), fixed.**
  - Source renders key on `a_src_key`, which follows the revision except at an Undo, Redo or Peel swap (`le_track_publish_live(..., reuse_key=1)`). Those swaps restore the key the slot's PCM had when it last sounded.
  - Both retained renders per lane are published, so the callback finds the swapped-in render in the same block.
  - The test proves this: render, bypass, overdub, un-bypass, then Undo and Redo, each sounding its own earlier render sample for sample, with no dry block and no third render.
  - Prints still key on the revision. A Clear Undo takes a fresh key; its pitch resets anyway.
- **M2 (four untested paths), fixed.**
  - My four probes are now tests: the selection pin, the 328 at arm, two lanes, no print while transposed.
  - The earlier T3, T7, T9 and T10 mutations would now fail them; the tests are the probes' oracles.
- **M3 (memory and CPU budget), addressed.**
  - The cap is 192 MiB: the prints' 64 MiB plus eight transposed single-lane 30 s tracks at 96 kHz and one job.
  - It is reasoned against #1200's D11 memory table, and D11's wet-cache row moves from 64 to 192 MiB.
  - The joint CPU scenario with #1197 is defined: pitch/time's share is 8 x 8 with live chains, every track transposed, at 8x.
  - The owner's appliance list now includes peak RSS and that row.
  - Note: the 64 MiB print share is a sizing argument, not an enforced sub-cap. Prints alone may now use all 192 MiB. That is still inside the D11 row, so this is not a defect.
- **L1 (loop-fold level), fixed.**
  - The fold is linear and scaled by the two signals' 2.5 ms local powers and correlation, capped at +12 dB (`le_stretch.cpp:298-337`). K7 is killed.
  - My probe, against the unfolded render's head:
    - chords, noise and 110 Hz: mostly within ±1 dB, where the old law swung from -5.2 to +4.6 dB;
    - outliers: +3.0 dB (2 s chord, -12 st) and +3.9 / +3.8 dB (55 Hz, -12 and -7 st). The old law gave +5.2 dB on the same 55 Hz case.
  - Steps inside the fold on 82 Hz inputs are the same size under the old and new law. They come from my synthetic input's own wrap discontinuity, not from the fold.
- **L2 (stopped renders), fixed.** `le_ca_evictable` (`engine_cache.c:481`) protects the current render of any transposed, unbypassed track with material. A job that needs that room is refused, and the test proves the stopped track sounds its pitch at the next Play. K5 is killed.
- **L3, fixed.**
  - The graveyard adds `2 x LE_MAX_TRACKS x LE_MAX_LANES` for the pinned stragglers (`engine_cache.c:144`), and the comment says why.
  - Configure resetting pitch and bypass is tested.
- **L4 (swap restarts a window).** Unchanged, as accepted.

### Findings

#### Low

**L-D1. Two lines that keep a content key truthful have no test (K3, K8 survive).**

- K8 shows that clearing `pass_key` after a session's first pass is load-bearing:
  - Scenario: with Transpose bypassed, record a two-pass overdub, un-bypass, then Undo the second pass.
  - Without the clear, the slot holding the after-first-pass content would be filed with the pre-session key, and the callback would sound the pre-session render over different PCM.
  - With the clear it re-renders, which is correct, but no test fails if the line goes.
- K3 shows the same for the key reset when a slot is handed out for new PCM.
- **Fix:** add the two-pass Undo case, with a literal comparison against a fresh render.

### Notes

- **K4 is unreachable today.** A source job only runs while the track is transposed and unbypassed (3a), or off its span with Pitch Unchanged (4a-ii). Both refuse a punch-in, so no write can tear the copy. The check is defence in depth; keep it.
- **Possible bump race.** `le_audio_rev_bump` now stores `a_src_key` from a read-back of `a_audio_rev` rather than from `fetch_add`'s value (for the non-Clang C++ shim). It is correct only while bump sites never race on one track, which the comment asserts. The control thread (Undo swap, import) and the audio thread (punch-in, pass retire) both bump. I did not find a reachable interleaving on a track whose key matters, which needs it transposed, so overdub is refused. A CAS loop would remove the assumption.
- **numbering.** events.log is 9 here, colliding with Multiply/Divide P1's 9; versions are assigned at landing.

Verdict: Approve (L-D1 is a test to add).
