Model: Claude Opus (subagent), in-session

# Review of origin/claude/pitch-time-1179-p2a (224aaf3f2): feat(engine): play tracks at a fractional speed through one read head

## Scope

- One commit, `224aaf3f2`, on top of `2e3d25f50`. It is 9 commits behind `origin/claude/segno-integration` (`5c163d11f`). The local trunk is at `56033baf0`, 18 commits ahead of the merge base, with three USB-storage merges that are not pushed.
- Reviewed against `docs/plan/2026-10-06-feat-pitch-time-core-plan.md`: §2.1–2.6, Part 2a, §6 sequencing, the §7 decisions, and the two "As built in Part 2a" addenda labelled E4 and E2. Also reviewed against AGENTS.md, the owner rules, and the pen group "01 CURRENT UX", section "15 Performance · Speed" (SO34L, Q29ROp, jY5NQ, YMPRG, usAz6), which I read through the pencil MCP and did not save.
- Files: `engine_read_head.h` (the in-place generalization of `engine_direction.h`), `engine_process.c`, `engine_commands.c`, `engine.c`, `engine_core.h`, `engine_private.h`, `engine_snapshot.c`, `lockfree_ring.h`, `perf_log_ring.h`, `perf_drain.c`, `perf_render.c`, `segno_engine_api.h`, the regenerated bindings, the format doc, `test_engine_speed.h`, and the edited read-head and Reverse tests.

## Runs

All runs used scratch worktrees and a fresh TMPDIR for each run.

| Run | Result |
|---|---|
| `git merge-tree` against `origin/claude/segno-integration` (`5c163d11f`) | clean (tree `34260adfc`) |
| `git merge-tree` against the local trunk `56033baf0` | clean (tree `af6f68513`) |
| Native suite, plain | ALL PASSED x5, exit 0 |
| Native suite, ASAN (`-fsanitize=address -g`) | ALL PASSED x5, exit 0 |
| Native suite, telemetry-off (`-DLE_CALLBACK_TELEMETRY=0`) | ALL PASSED x5, exit 0 |
| Native plain on the merge with the origin trunk (`aa6e8dac2`, review-only commit, not pushed) | ALL PASSED x5, exit 0 |
| `flutter test` packages/segno_engine (SEGNO_ENGINE_LIB from `build_test_lib.sh`) | +370, all passed |
| The same on the merge with the origin trunk | +370, all passed |
| `flutter test` packages/looper_repository | +804, all passed |
| `dart analyze --fatal-infos` packages/segno_engine; `dart format --set-exit-if-changed` on the bindings | clean; 0 changed |
| `check_ffi_symbols.sh` on the macOS test dylib | exit 1: the script uses `nm -D`, which is ELF-only, so this is not a defect of the branch. A manual `nm -gU` against the bindings shows every symbol exported, including `le_engine_set_speed`, except the five MIDI symbols, which the test lib does not build. |
| C++17 syntax check of `engine_read_head.h` (`-Wall -Wextra -Werror`) and of `engine_private.h` under `extern "C"` | clean |
| `bench_pitch_time.sh --smoke` | exit 0 |

Six reviewer probes and nine mutations, run through `SEGNO_RV_PROBES` and `SEGNO_SPEED_TESTS_ONLY`, are cited in the findings below.

## Verified correct (traced)

- **Bit-exact at rate 1.**
  - With an integral origin, `le_head_index` does double arithmetic on integers below 2^53, so it is exact. `head_idx` stays -1 and the mixer keeps `lbuf[seg_base + trk_pos]` verbatim.
  - The unbounded `le_track_song_position` (`laps*L + position`) reduces to the old `(laps % k)*L + position` for multiples (mod `k*L`) and for divisions (`L % (L/n) == 0`).
  - Every pre-existing test passes unchanged except two edits. The read-head unit test now uses Reverse's `(origin - 1 - pos)` convention. `rev_log_facts` now uses `LE_TEST_EVENTS_VERSION`. Both edits are consistent with E12.
- **Exactness of the dyadic rates.** ½, 2, 4 and 8 are powers of two, so `rate*pos`, the re-origin and Q32.32 are all exact. That is why live and renderer agree bit for bit wherever both are anchored from the same exact index.
- **Real-time safety.**
  - `le_head_box` loops at most `floor(rate)` ≤ 8 times, clamped to `len`. Its `while (j < 0)` runs at most once because `0 ≤ i < len` and `n ≤ len`.
  - `le_speed_change_safe` and the `LE_CMD_SET_SPEED` handler do bounded per-track work: plain stores and one `le_plog_push` per track.
  - No allocation, no locks and no libm. Worst case is 32 reads per lane-frame (8x decimated with a turn).
- **Command, fact and version numbering.**
  - `LE_CMD_SET_SPEED = 85` leaves 84 free for Multiply/Divide's `LE_CMD_SET_LENGTH` (plan #1168 §1.3).
  - `LE_PLOG_SPEED = 327` leaves 326 free for `LE_PLOG_LENGTH`. Peel holds 325 and Reverse 324.
  - `LE_ERR_TRANSFORMED = -10` is the next free code. The M/D plan reserves no error code.
  - events.log version 8 is the next free version. It has its own row in the format doc, and 326 is documented as held.
  - Across every origin branch, only p2a and p2b use 85, 327, -10 or version 8.
  - `LE_CMD_SET_SPEED` is on both the `le_engine_post_command` refusal list and the `le_log_extract` exclusion list.
  - `speed_log` is 16 bytes and identical in `le_command` and `le_log_command`.
- **Capture guards.**
  - `le_record_impl` refuses a start from EMPTY, PLAYING or STOPPED with `LE_ERR_TRANSFORMED` (`engine_commands.c:1731-1739`), judged by the factor the posted requests predict (`le_effective_speed_one`). Cancels and finishes still pass.
  - `handle_record` drops a start that fires anyway (`engine_process.c:1990-1992`).
  - Mutation M1 (remove the callback drop) fails 74 checks, so the drop is pinned.
  - `le_engine_toggle_section` is play/stop only. Count-in members go through `le_record_impl`, and a count-in blocks admission (`a_counting_in`).
  - Control-side admission covers RECORDING and OVERDUBBING, `a_pending`, `armed[]` and `a_pending_launch`. The callback recheck adds `od_gain`, `xfade_capture` and `pending_record`. Together they close the window in which a record could be admitted under one factor and applied under another.
- **E6.** A repeated factor writes a receipt only. The twin-engine test proves the mix is byte-identical and that exactly one 327 is written.
- **E2 (as built), accepted.**
  - The 322/323 phase stays in source space. It is `floor` of an index that `le_head_wrap` keeps in `[0, len)`, so `perf_render.c:924` cannot fail on it in Part 2a.
  - The next expected phase is `floor(index(song + 1))`. That value is still correct across a lap wrap because `laps*L + L-1 + 1 == (laps+1)*L + 0`.
  - Song space would have changed the phases Reverse already logs, so the departure is reasoned, labelled in the plan and tested (zero 323 over two laps at ½× and one lap at 8x).
  - Mutation M7 (rate-1 prediction everywhere) fails that test.
  - Part 4a must revisit this, because a `len_src != play_len` track changes the reasoning. That belongs in 4a's plan, not here.
- **E4 (as built), accepted.**
  - Both heads read `buf[t][l]`, the lane's live buffer pointer for the block (`engine_process.c:6118-6128`). The turn window therefore holds no pointer to a print or another slot, and there is nothing to pin until Part 3a's source swaps.
  - When a step is taken, a printed lane is disengaged, so the printed PCM is never read through the head.
  - Mutations M11 (lane engage at a non-integral head) and M12 (no disengage on a step) both fail tests.
  - I agree with deferring `a_turn_source` and the collector deferral to 3a. The "ASAN" test cannot fail by construction under this design (see Notes).
- **Reopen and reset.**
  - Speed and per-track rate are material. `le_engine_reset_material` sets them to 1/1. A retained reopen keeps them and resets only origin, turn and control's in-flight view (`speed_posted`, `speed_pending_one`, `a_speed_applied`).
  - Normal (`{1,1}`) changes only the rate: direction is kept, and Fade is a separate gain stage.
- **Renderer.** It re-anchors at the logged Q32.32 index with the logged turn, steps by the rate and reads through the same `le_head_read`. Parity at ½x, at Reverse 87.5 and at 8x, then back to Normal, is checked sample-exactly against the live output.
- **Snapshot.** The trailing `speed_numer/denom` on `le_snapshot` and `head_rate_milli` on `le_track_snapshot` are regenerated in the bindings. `position_frames` is `floor(index)`, so it runs at the head's rate (asserted).

## Findings

### High

**H1. Normal after ½× can leave a track permanently low-passed, and its print never comes back.**

- **Where:** `engine_process.c:2753-2769` (`le_head_set_rate`), `engine_read_head.h:72-75` (`le_head_is_integral`), `engine_process.c:6048` and `:6210` (the engage conditions).
- **Cause:** At ½× the index is `origin + pos/2`, which falls on `x.5` on every odd song frame. A Speed change re-origins for continuity (`origin = cur - rate*pos`). When Normal lands on an odd frame, the new origin is fractional. From then on, at 1x:
  - every dry read is a linear interpolation at fraction 0.5, a two-tap average with response `cos(pi f/fs)`. That is -3 dB at fs/4 and -11.7 dB at 20 kHz at 48 kHz; about -2 dB at 20 kHz at the appliance's 96 kHz;
  - `le_head_is_integral` is false, so neither the whole-track print nor the lane Pre print ever re-engages. The live chains keep running, which costs CPU on the Pi and drops the printed sound.
- **How long it lasts:** until a material reset or a transport hold. Roughly half of all ½× round trips hit it, as does any ½× session that later uses Reverse.
- **Probe:** `reverse_fixture`, 37 frames, ½×, 101 frames (index 87.5), then Normal. After that, 2400 of 2400 samples sit on `x.5` (`out[2500] = 587.5`). In the cached twin, after ½× and an odd frame count, then 1x and four more loops, `cache_engaged == 0`.
- **Why it matters:** the accepted text says "Normal restores only that factor", but here the sound changes and stays changed with no indication, which breaks owner rule 3. The existing render-parity test runs exactly this path (Normal after a `.5` index) and only checks live against replay, so it passes.
- **Fix:**
  - When the new rate is integral (certainly at rate 1), round `cur` to the nearest whole sample for the new head, and log the rounded index in 327. The old head keeps `cur`, and the equal-gain window absorbs the half-sample offset of at most 0.5.
  - Add a test: Normal after ½× on an odd frame gives integral reads afterwards, and the print re-engages at the next lap top.

### Medium

**M1. A material reset while Speed is not 1x re-origins the head without the exact-index fact, so the stem goes inexact without failing.**

- **Where:** `engine_process.c:261-267` (`le_head_reset`), `perf_render.c:772-776` (`le_pr_anchor`), and the false comment at `perf_log_ring.h:190-193`.
- **What the plan required:** §2.6 (E3) has 327 pushed "at every accepted change, at every re-origin (hold, Stop/Play, relaunch, retiming) and at every material reset".
- **What was built:** 327 is logged only at a Speed change and at PERF_ARM. The format doc row says "A material reset … logs 324 alone". The `perf_log_ring.h` comment still claims material resets log it. This deviation from E3 is not labelled as one.
- **Failure:** `le_head_reset` sets `origin = 0`. When the material returns (Clear Undo, import), the renderer has only the integral 322/323 phase. `le_pr_anchor` keeps its own continuing fraction only if the floors agree, and otherwise takes the integer. Either way it can be off by half a sample.
- **Probe:**
  - Setup: two tracks playing; arm the performance capture; ½× at frame 37; Clear track 0 at frame 437; Undo at frame 501 (odd); play.
  - Result: 1501 of 2002 stem frames differ from live by 0.5 (live 250.5, replay 250.0). The render does not fail; it is simply inexact.
  - The plan's rule is "the stem is exact or it fails" (rule 3, decision 15).
- **Fix:**
  - Push 327 with the exact index at every re-origin while `rate != 1`: `le_head_reset` (`le_transform_reset`), `le_restart_once`, and the transport hold. An alternative is to push it whenever the head's fraction is nonzero.
  - Correct the `perf_log_ring.h` comment and the format doc.
  - Add the clear-undo-at-odd-frame parity test.

**M2. Speed survives into an all-empty rig, which then refuses to record a new loop.**

- **Where:** the master reset in `handle_clear` (`engine_process.c:2452-2460`) and the restore drop (`:1892-1902`) leave `speed_numer/denom` as they were.
- **Probe:** ½×, then Clear the only track. The snapshot reads `state=0, master_length_frames=0, speed=1/2`, and `le_engine_record(e, 1)` returns -10.
- **Why it matters:**
  - The rig is effectively a new loop. The accepted text says New Loop "resets … global Speed", and plan decision 9 lists Clear and new capture as resets.
  - The pen's `04 / Speed / Empty loop` (YMPRG) shows "No recorded audio" with no factor, so in Part 6a the performer would be refused a first recording with no visible Speed to explain why.
  - No Dart path reaches this in 2a, but the native contract set here is the one 2b and 6a inherit.
- **Fix:** at the "every track EMPTY resets the master" sites, reset Speed to 1/1 for every track. That means `head.rate = 1`, publishing `a_speed_*` and `a_head_rate_milli`, and logging 327. Alternatively, refuse `le_engine_set_speed` while no track holds material. Add a test either way.

**M3. The plan's gate on "the real mixer path at ½×, 4× and 8×" cannot be run.**

- **Where:** `bench_pitch_time.c:367-390`.
- **Problem:** `scenario_baseline` drives `le_engine_process` at 1x only. No scenario calls `le_engine_set_speed`, and `head` times the kernel outside the mixer.
- **Why it matters:** two Part 2a success criteria depend on this. One is the proxy bench "with the real mixer path"; the other is the hardware criterion `bench_pitch_time.sh --budget-us 667 --assert` at ½×, 4× and 8× on the appliance. Neither can measure the shipped mixer path: head reads, turn windows, the extra `le_track_song_position` calls per frame, and the live chains running because prints disengage.
- **Fix:** add a `baseline` variant that sets each factor through `le_engine_set_speed` before timing, and thresholds for it.

### Low

**L1. A second turn inside the turn window drops the old head and clicks.**

- **Where:** `engine_process.c:2761` and `:3360`.
- **Cause:** `prev_head = head` overwrites a head that is still being mixed. This happens on a second Speed step, or a Speed step during a Reverse turn (other than Reverse's own cancel case).
- **Probe:** 1x, then 2x at frame 37, then 4x 100 frames later. The output jumps from 156.5 to 237.5 in one frame, on a ramp whose steady slope is 4.
- **Why it matters:** the API doc promises "click-free". The plan's "receipts for rapid double presses" test is not written. A double press within 10 ms is rare on a footswitch, so this is Low.
- **Fix (pick one):**
  - defer the step until `turn_left == 0`;
  - fold the current mix weight into a new window that starts from the old pair;
  - at minimum, test and document the behaviour.

**L2. Untested paths (each mutation passes the whole speed suite).**

- M2: `le_speed_change_safe` returning 1 always. The callback recheck is untested.
- M4: removing the PERF_ARM 327 for a track not at 1x. Nothing arms while sped up and renders.
- M9: dropping `* tr->head.rate` from the shared-clock Once condition.
- M10: the whole-track print engage at a fractional head.

Also missing from the plan's own Part 2a list:
- "Fade continues through a step";
- "refused while OVERDUBBING / count-in";
- receipts for rapid presses of different factors;
- "undo-to-empty / new capture / import reset the head and log the fact". Only Clear is exercised, and its comment says "logs the reset" without asserting it.

My probe shows shared-clock Once at ½× behaves correctly today, so these are coverage gaps, not defects.

**L3. `LE_ERR_TRANSFORMED` is not visible to Dart yet.** `EngineResult.fromCode` (`packages/segno_engine/lib/src/audio_engine.dart:63-75`) maps -10 to `invalid`. 2a has no Dart Speed seam, so nothing can reach it, but 2b must add `EngineResult.transformed` so a refused record is not shown as "invalid". Flag it for 2b's checklist.

## Notes

- **Deviations named in the commit.** E12 (in-place generalization) and E6 (receipt-only) match the plan as written. The two "As built" addenda (E4, E2) are judged above; both are accepted.
- **Two unlabelled deviations.** M1 (no 327 at material reset or re-origin) and the bench gap (M3).
- **Overclaiming test.** `test_speed_print_and_turn_source` claims to retract and free the print "inside the window" under ASAN. In the as-built design the window never reads the print, so the test cannot fail. Rename it, or describe it as a parity test.
- **Overdub at 1x with a fractional origin.** This is what H1 leaves behind. It writes at `floor(index)` while the performer hears `index + 0.5`. The write uses `lbuf[wdub]`, not the interpolated `loopsample`, so repeated passes do not compound the filter. H1's fix removes the case.
- **Print engaging during a turn.** A print can engage at `rp == 0` while a turn window is still mixing (Normal from 2x within 10 ms of a lap top). The printed path then ignores the turn mix. Reverse already had this; it is rare.
- **Speed before configure.** Before `le_engine_configure`, `speed_numer/denom` and `head_rate_milli` read 0 (the engine is calloc'd). The API comment says "1/1 before any request". Cosmetic.
- **Session commit.** `commit_session` does not reset Speed, so a recalled Session plays at the factor in force. Plan Part 5 owns this, but its default should be decided alongside M2.
- **Pen.** `01-03 / Speed` keep "Record / Play" on the footswitch row while sped up. The engine refuses record (§8 question 1, default taken). Part 6a must show the refusal.
- **Trunk drift.** The trunk's engine changes since the base (`le_volume_space` in `perf_drain.c`, the API header and tests) merge without conflict, and the merged tree passes the native and segno_engine suites.

Verdict: Request changes

## Delta review (aa99ecc3f)

Model: Claude Opus (subagent), in-session

### Scope

- `aa99ecc3f` "fix(engine): address the Speed review" on `origin/claude/pitch-time-1179-p2a`, plus the trunk merge `5a329c3fa` it rides on. Files: `engine_process.c`, `perf_render.c`, `perf_log_ring.h`, `segno_engine_api.h`, the bindings comment, `bench_pitch_time.c`, `test_engine_speed.h`, the format doc, the plan (decisions 22-25) and the spike findings.
- Checked each finding of the first review (H1, M1, M2, M3, L1, L2), plus the pen screen `04 / Speed / Empty loop` (YMPRG), read through the pencil MCP and not saved.

### Runs

| Run | Result |
|---|---|
| `git merge-tree` against `origin/claude/segno-integration` (now `7a9fdcbd9`) | clean |
| Native suite, plain | ALL PASSED x5, exit 0 |
| Native suite, ASAN (`-fsanitize=address -g`) | ALL PASSED x5, exit 0 |
| Native suite, telemetry-off | ALL PASSED x5, exit 0 |
| `bench_pitch_time.sh --smoke` | exit 0; the six new Speed rows print (timings taken under build load, so not quoted) |
| Mutations D1-D9 below, each through the core test binary up to the Speed tests | 9 of 9 killed |
| Probe: `le_engine_set_speed` on a configured, all-EMPTY rig | see M-D1 |

Mutations (each applied alone, then reverted):

| Mutation | Killed by |
|---|---|
| D1 no whole-sample landing (H1) | `test_speed_normal_lands_on_whole_sample` (2399 checks) |
| D2 no window carry in `le_turn_begin` (L1) | `test_speed_step_inside_window` (slope and stem parity) |
| D3 no 327 after a 322/323 off whole samples (M1) | `test_speed_clear_undo_stem_exact` |
| D4 no 327 in `le_head_reset` | `test_speed_track_print_and_resets` (fact counts only) |
| D5 no empty-loop reset (M2) | `test_speed_empty_loop_resets` |
| D6 `le_speed_change_safe` always 1 (old L2 survivor) | `test_speed_refusals_while_writing` |
| D7 no PERF_ARM 327 (old L2 survivor) | `test_speed_arm_while_sped_up_and_fade` |
| D8 Once without `* head.rate` (old L2 survivor) | `test_speed_shared_once_full_lap` |
| D9 renderer without the window carry | `test_speed_step_inside_window` (stem parity) |

### Status of the first review's findings

- **H1, fixed.** `le_head_set_rate` (`engine_process.c:2803-2822`) lands an integral rate on `round(cur)`, wrapped, and logs that index. The old head keeps `cur`, so the window absorbs the offset. The test proves the 480-frame equal-gain blend and then 1920 bit-exact frames (`out[k] == (278 + k) % len`), and that the Pre print re-engages after Normal. D1 is killed.
- **M1, fixed.** Two parts:
  - `le_head_reset` logs 327 with the reset index when the rate is not 1.
  - `mix_tracks_frame` follows every 322/323 of a PLAYING track off whole samples with a 327 at the same frame.
  - The Clear-then-Undo-at-an-odd-frame stem now matches live to 2e-3 over 2502 frames, with more than 500 fractional frames, so the probe from the first review is now a test. D3 and D4 are killed.
  - The `perf_log_ring.h` comment and the format doc now describe what is written.
- **M2, fixed for the Clear path, and announced.** `le_speed_reset_if_empty` runs at the three sites: `handle_clear` (per track and at the master reset), `apply_undo_to_empty`, and a reopen whose drops empty the rig. It resets every head to 1x through `le_head_set_rate`, publishes `a_speed_numer/denom` and `a_head_rate_milli`, and logs a 327 at 1/1 for every track.
  - The change is announced, not silent:
    - plan decision 22 and the API and bindings doc state it;
    - the snapshot carries it;
    - the events log carries it;
    - Part 2b projects it into `LooperState.speed`.
  - No notice exists yet, and none is needed in Part 2a. The pen's empty-loop screen shows no factor, so Part 6a must show Normal on the face once the next loop exists.
  - The decision text lists "a void take" as a reset site. The void-take path (`engine_process.c:1415`) does not call the reset, but it cannot run while Speed is not 1x, because capture is refused then. This is a wording nit.
  - The path back into the M2 state is still open: see M-D1.
- **M3, fixed in its stated scope.** `scenario_baseline` now takes a factor, sets it through `le_engine_set_speed`, runs 64 periods past the window, checks the receipt, and times `le_engine_process`.
  - Rows exist for 1/2, 4/1 and 8/1 at 8x1 and 8x8.
  - The judged row is 8x1: p50 at most 25 % on the proxy, p99 at most 50 % on the Pi.
  - Residual: see L-D2.
- **L1, fixed.** `le_turn_begin` keeps a running window and its old head. `le_pr_reanchor` carries `turn_into0` and the old head over. The test checks the slope of the blend (at most 4.01 on the ramp) and stem parity through four rapid presses, two of them in one drain. D2 and D9 are killed. The new head is not quite continuous at the carried change: see L-D1.
- **L2, fixed.** Tests now cover:
  - the callback recheck (punch-out tail);
  - refusal while OVERDUBBING and during a count-in;
  - arming while sped up;
  - Fade through a step;
  - shared-clock Once at 1/2x;
  - the whole-track print at a fractional head;
  - undo-to-empty and import with their facts;
  - rapid presses.
  The three survivors from the first review (D6, D7, D8) are now killed, and E4's test is renamed truthfully.
- **L3** belongs to 2b and is addressed there (`EngineResult.transformed`).
- **events.log version.** This branch still writes version 8. Part 3a (#1214) bumps it to 9, and Multiply/Divide P1 (`origin/claude/multiply-divide-1168-p1`, `perf_drain.c:826`) also writes 9. Versions are assigned at landing, so this is flagged, not counted.

### Findings

#### Medium

**M-D1. An empty rig still accepts a Speed, and then refuses the first take. Decision 22 holds only on the way down.**

- **Where:** `le_engine_set_speed` (`engine_commands.c:2843-2865`) and the callback's `le_speed_change_safe` (`engine_process.c:2765`). Neither checks whether any track holds material.
- **Probe:** configure an engine and post nothing. `le_engine_set_speed(e, 1, 2)` returns `LE_OK`. After one block the snapshot reads `speed=1/2`, and `le_engine_record(e, 0)` returns `-10` (`LE_ERR_TRANSFORMED`).
- **Why it matters:**
  - The API doc this commit adds says "An empty loop has no speed".
  - The pen's `04 / Speed / Empty loop` (YMPRG) still shows the five factor pedals ("½× Half speed" … "8× 8 times speed") beside "No recorded audio".
  - A performer who presses ½× on an empty loop is therefore refused the first recording, with no factor on screen to explain it. That is the rule-3 failure M2 described, reached by a different door.
  - It is also reachable today through Part 2b's `LooperRepository.setSpeed`, and the mock engine models it the same way.
- **Fix:** Make the rule hold both ways.
  - Option 1: refuse `le_engine_set_speed` while every track is effectively EMPTY (`LE_ERR_NOT_READY`, or a receipt-only no-op that leaves 1/1), and recheck it in `le_speed_change_safe`.
  - Option 2: if the pedals should stay live on the empty face, have record ignore Speed while the rig is empty and reset to 1x at the first capture start.
  - Either way, add the empty-rig case to `test_speed_empty_loop_resets` and mirror it in `MockAudioEngine`.

#### Low

**L-D1. A carried window with an integral rate is not continuous at the change.**

- **Where:** `le_head_set_rate` (`engine_process.c:2812-2821`) with `le_turn_begin` (`:2750`).
- **Cause:** When a change lands inside a running window, `prev_head` stays the head from before the window. The head being replaced (at `cur`) leaves the mix at weight `x`, and its replacement starts at `round(cur)`.
- **Effect:**
  - Example: ½× then Normal within 10 ms.
  - The output steps by `x * (A(cur) - B(round(cur)))`: up to half a sample of the material, weighted by how far the window has run.
  - Decision 24 says the new head "is value-continuous with the one it replaces"; that holds only for non-integral rates.
  - Rare (two Speed presses within 10 ms), and the stem reproduces it.
- **Fix (pick one):**
  - skip the rounding when `t->turn_left > 0`, and land on the whole sample at the next change outside a window;
  - or correct the decision text.

**L-D2. The Speed gate asserts only the 8 x 1 rig, without FX chains.**

- **Where:** `bench_pitch_time.c:738-747`, where only `lanes == 1` feeds `speed_worst`.
- **What is not measured:**
  - The 8 x 8 rows print but are not judged.
  - The rig has no Pre chains. At any Speed other than 1x every print disengages and the live chains run on the audio thread (`le_track_disengage_prints`), and that cost is not measured.
- **Why it matters:** the appliance rig is up to 8 x 8 with chains, and Part 3a and the instruments plan (#1197, D2: "the pitch/time baseline … plus 32 voices … p99 at most 50 %") build on this number.
- **Fix:** judge the 8 x 8 rows too. Add one row with a Pre chain on every lane at 8x, so prints are off and chains are live. Record it with the Part 3a appliance run.

### Notes

- **A 322 inside a turn window.** When an Undo lands within 10 ms of a Speed step, the renderer starts a new segment without the window, but live keeps mixing `prev_head` over the new slot. The M1 327 that follows has `turn_frames` 0, so it does not carry the window. This is the existing E2-class gap, at most 10 ms, and it is not new in this delta.
- **Probe-only edits.** I made them in a scratch worktree and did not keep them.

Verdict: Request changes (M-D1; the rest of the first review is fixed and pinned by tests).

## Delta review (36debe826)

Model: Claude Opus (subagent), in-session

### Scope

- `36debe826` "fix(engine): refuse Speed on an empty rig and keep a carried window continuous", on top of the trunk merge `0c192bea1` (which brings in Reverse P3, Library P1-P3, Recording P1, USB storage P4 and Peel P2).
- Checked against the second delta's M-D1, L-D1 and L-D2, plan decisions 26-27, and the pen's `04 / Speed / Empty loop` (YMPRG) through the pencil MCP (not saved).

### Runs

| Run | Result |
|---|---|
| `git merge-tree` against `origin/claude/segno-integration` (`890f04936`) | conflicts in `segno_engine_api.h` and the regenerated bindings only: the trunk's `LE_ERR_NOT_FOUND`/`LE_ERR_TRUNCATED` (#1198) sit where this stack adds `LE_ERR_TRANSFORMED`. Both are kept by hand, then ffigen is re-run. A rebase chore, not a defect. |
| Native suite, plain / ASAN / telemetry-off | ALL PASSED x5 each, exit 0 |
| `bench_pitch_time.sh --smoke` | exit 0. The new 8 x 8 rows and the "8 x 8 with Pre chains at 8/1" row print. Timings were taken under build load and are not quoted. |
| Dart, through 2b's head (which contains this) | see the 2b delta |

### Status

- **M-D1, fixed.**
  - `le_engine_set_speed` returns `LE_ERR_INVALID` while no track is effectively non-EMPTY (`engine_commands.c:2830-2841`).
  - The callback refuses a request that lands after the rig emptied with receipt `LE_ERR_INVALID`, and does not take the factor.
  - `test_speed_refused_on_empty_rig` covers admission and the callback case (a Clear posted before the request in the same drain), and checks that the first take then records.
- **The pen agrees, and I correct my earlier reading.** On YMPRG the five factor captions (½×, Normal, 2×, 4×, 8×) sit in frames at opacity 0.35, while Record / Play, Stop and Exit are at full opacity. The face already draws the factors as unavailable; my M-D1 text said only that the pedals were shown. Decision 26 matches the pen.
- **L-D1, fixed.**
  - An integral step inside a running window now continues from the exact `cur` and sets `land_whole`.
  - `le_head_land`, run at the top of every block after the command drain, lands it on the whole sample once the window ends, through its own equal-gain window and 327.
  - `test_speed_integral_step_inside_window` checks:
    - the literal carried blend (old 1x head at `k`, new head from 87.5);
    - every step within the blend's slope;
    - zero fractional reads after the landing;
    - stem parity over 3138 frames.
- **L-D2, fixed.** The 8 x 8 rows are judged at every factor (proxy p50, Pi p99). An 8 x 8 rig with a two-entry Pre chain on every lane at 8x is printed, and judged on the Pi only (decision 27, findings table).

### Findings

None new.

### Notes

- **Imported but uncommitted tracks count as empty.** A track that holds imported PCM but is not committed reads EMPTY, so `le_engine_set_speed` before `commitSession` is refused. Part 5's Session recall must install Speed after the commit, unlike Transpose's install, which accepts that state. Worth one line in Part 5.
- **`land_whole` and resets.** `land_whole` is not cleared by `le_head_reset` or a reopen. That is harmless, because `le_head_land` re-checks that the origin is fractional at an integral rate before acting.

Verdict: Approve.
