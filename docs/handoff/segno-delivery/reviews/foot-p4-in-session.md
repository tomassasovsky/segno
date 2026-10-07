Model: Claude Opus (subagent), in-session

# Review of PR #1248 (claude/foot-surfaces-1229-p4 at edad8d249): a tuner-owned mute for the input being tuned

## Scope

- **The commit:** one commit, `edad8d249`, on `claude/tuner-latency-909-trunk` `c54865297`, the trunk port of #912. It touches 23 files, +615/−5.
- **Native changes:**
  - `LE_CMD_SET_TUNER_MUTE = 132` and `le_engine_set_tuner_mute`;
  - `a_tuner_mute_mask`, ORed into `mon_mut` in `snapshot_monitor_fx`;
  - the mask is cleared on every `LE_CMD_SET_TUNER_INPUT` and in `le_engine_reset_runtime`;
  - the snapshot field `tuner_mute_mask`;
  - a new `test_engine_tuner.h` with 5 tests.
- **Dart changes:**
  - `AudioEngine.setTunerMute` in the native, mock and fake engines;
  - `EngineSnapshot.tunerMuteMask` and `TunerReading.muteMask`;
  - `LooperRepository.setTunerMute`, with the mask remembered and re-sent after the arm on restart;
  - the bindings are regenerated;
  - the event-log format doc is updated.
- **Also read:** the port's `engine_private.h` conflict resolution (`git show --remerge-diff c54865297`).
- **Checked against:** Part 4 of the plan (`da5c89bf9`), the coordinator's four checks, AGENTS.md and the owner rules.

## Runs

All runs used scratch worktrees at `edad8d249` and a separate TMPDIR per run.

- **Native, normal:** ALL PASSED. All 5 `test_tuner_mute_*` tests ran, and so did the port's tuner tests.
- **Native, ASAN** (`-fsanitize=address -fno-omit-frame-pointer -g`): ALL PASSED.
- **Native, telemetry off** (`-DLE_CALLBACK_TELEMETRY=0`):
  - The first run, with five suites in parallel, failed one CHECK: `test_engine_fade.h:898`. That is a 5 s wait for the layer-staging ring to drain, in a Fade restore test that P4 does not touch.
  - Re-run alone: ALL PASSED, 0 FAIL.
- **Packages:**

| Package | Result |
|---|---|
| `looper_repository` | +809, passed |
| `segno_engine` | +377, passed |
| `performance_repository` | +130, passed |
| `session_repository` | +188 −1 under load; the failure was a 30 s time-out in the B5c round-trip test. Re-run alone: +52, passed. |

- **App suite:**
  - Result: +3465 ~56 −4.
  - The four failures were time-outs under load: `count_in_session_shutdown` ×2, `fx_chain_persistence` and the `monitor_cubit` debounce test.
  - Re-run alone, those files pass: +93.
- **Native mutations:** run with the core binary, `SEGNO_REVERSE_TESTS_ONLY=1`. Each was reverted, and all five were killed.

| Mutation | Result |
|---|---|
| No mask clear on `LE_CMD_SET_TUNER_INPUT` | killed, `test_engine_tuner.h:114-115` |
| No clear in `le_engine_reset_runtime` | killed, `:146` |
| No disarmed guard in the handler | killed, `:104-105` |
| No `in_channels` clamp | killed, `:55` |
| The command `le_plog_push`ed | killed, `:243` |

## Verified correct (traced) — the coordinator's checks

1. **ORed into `mon_mut`.**
   - `mon_mut[c] = load_i32(&m->a_muted) || (tuner_mute & (1u << c)) != 0u` (`engine_process.c:4973`).
   - The mask is loaded once per block, so everything downstream of `mon_mut` treats the input as muted: `mix_monitors_frame` (`:5591-5593`), the zero `perf_tap_monitor_frame` for a captured input, and the unprocessed-slot settle.
   - `test_tuner_mute_literal` checks the sums with literal values: 1.0, 0.3, 0 and 1.0.
2. **Cleared on input change and on `reset_runtime`.**
   - Every `LE_CMD_SET_TUNER_INPUT` stores 0 (`:3518`): arm, move and disarm alike. That is D12, stricter than the plan's "on disarm".
   - `le_engine_reset_runtime` stores 0 beside the tuner disarm (`engine.c:800`), and it runs on configure and on a retained reopen.
   - A mask posted while disarmed is stored as 0 (`:3534-3542`).
   - `test_tuner_mute_owned_by_arm` covers the disarm, the move, the out-of-range disarm (input 9 on 4 inputs) and the configure case.
3. **The saved monitor mute is never touched.**
   - The handler writes only `a_tuner_mute_mask`, and nothing writes `a_muted`.
   - `test_tuner_mute_keeps_monitor_mute` holds a persistent mute through mask on/off, and checks `a_muted` directly (`:90-91`).
   - On the Dart side, `setTunerMute` never touches `_monitorMute`, settings or Session capture, and `monitorMuted` does not report it.
4. **Not perf-logged.**
   - The handler has no `le_plog_push`, and the mutation that adds one is caught.
   - `test_tuner_mute_not_logged` also checks that a captured monitor stem holds the silence (`le_engine_perf_monitor_pop_for_test`).
   - The format doc states this.

**Other checks:**
- The detector and track capture both read `in_c`, before the monitors. `test_tuner_mute_detector_and_capture_independent` compares 4800 recorded frames literally, and reads 220 Hz within 1 Hz at confidence ≥ 0.5 while the input is muted.
- The 32-input clamp is guarded (`in_channels < 32`), as review L3 asked.
- A raw `le_engine_post_command(132, …)` takes the same handler as the typed call, which is acceptable.
- **Restart order on the Dart side:**
  - `setTunerInput`, then `setTunerMute`, both on the restart path (`looper_repository.dart:2546-2552`). The fake engine records that order, and a test pins it.
  - `setTunerInput` clears the remembered mask (review L4).
  - A mute sent while stopped lands after the arm on the next start, and a test covers it.
- **The mock engine** follows the native rules: cleared on arm, refused while disarmed, absent inputs dropped.
- **The port's conflict resolution** in `engine_private.h` is sound. Both new types are kept, and every tuner member exists once.

## Findings

None blocking.

### L1. Low: a second arm caller would silently unmute the tuned input

- **Where:** on this branch, `TunerCubit` still re-pushes `setTunerInput(input: state.input)` whenever the snapshot's `tuner_input` differs from its own (`lib/tuner/cubit/tuner_cubit.dart:148-151` on the trunk).
- **The mechanism:** with D12, any `setTunerInput` now also clears the mask, in Dart and natively.
- **Scenario:** nothing calls `setTunerMute` yet, so nothing is wrong today. But if the foot Tuner (Part 6) arms while a `TunerCubit` with its own selection is still alive, as with the interim tray of review L5, the cubit's re-push on the first mismatched snapshot unmutes the input mid-tune and leaves the tuner on the wrong input.
- **Fix:** Part 5 must remove the mismatch re-push before Part 6 arms from Control. The plan has Part 5 clear on a mismatch, which is the right shape. Add a test there: "`TunerCubit` never calls `setTunerInput` on a snapshot mismatch".

### L2. Low: the port has no PR of its own

- **The branch:** PR #1248 targets `claude/tuner-latency-909-trunk`, which has no pull request into the trunk.
- **Effect:** merging #1248 does not reach the trunk, and the port has had no CI or review of its own.
- **What CI covers:** CI on #1248 runs the whole stack, so the native suites cover the port too.
- **Fix:** open the port PR and retarget #1248 after it merges (see plan-review DN1).

## Notes

- The doc comment on `a_tuner_mute_mask` says "Written by the audio thread only". `le_engine_reset_runtime` also writes it from the control thread, while the engine is stopped. That is the same discipline as `a_tuner_input`, but the comment should say "audio thread, or configure while stopped".
- Commands 133–135 stay reserved in the header comment, while plan D8 says they are "returned to the ledger". Make the two agree.

Verdict: Approve.
