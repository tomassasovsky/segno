Model: Claude Opus (subagent), in-session

# Review of PR #1263 (claude/library-1178-p6a): Library Part 6a (#1178), the isolated audition voice

**Branch:** `origin/claude/library-1178-p6a`, head 22b841ecb (the commands are already 136/137 there; the branch has no later head). One commit, 24 files, +1262/-1. Its parent is the backing stack (#1200 P1 and P2), but as the older commits 28517aafc to d81d14170, not the approved #1223 head caaabe6f0 (Finding 1).

**Scope:**
- The commit `d81d14170..22b841ecb`.
- Plan D10 and Part 6a.
- The numbering ledger (`docs/plan/2026-09-09-segno-implementation-ledger.md`).
- AGENTS.md conventions.
- The owner rules.
- The backing decoder and buffer type it reuses (#1223, approved) are reviewed only where this commit calls them.

## Runs

Everything ran in a scratch worktree at 22b841ecb, removed afterwards, with one `TMPDIR` per run.

| Check | Result |
| --- | --- |
| Native suite, plain | ALL PASSED (7 binaries), exit 0 |
| Native suite, ASan (`-fsanitize=address -g`) | ALL PASSED, exit 0, no reports |
| Native suite, telemetry off (`-DLE_CALLBACK_TELEMETRY=0`) | ALL PASSED, exit 0 |
| TSAN races (`-fsanitize=thread`, `NATIVE_TESTS_ONLY=races`) | engine races, plugin runtime races, FX recipe ownership and backing handoff races: all pass, 0 TSAN warnings |
| `segno_engine` Dart tests with `SEGNO_ENGINE_LIB` | +384, all passed (includes the real-library `audition_test.dart`) |
| `dart analyze --fatal-infos lib test packages` | No issues, after `pub get` in `packages/storage_repository` (my worktree's setup) |
| Command codes 136/137 across all 582 remote branches | no other use. The ledger records the move from 96/97 to 136-137 |
| `git merge-tree` onto #1223's head caaabe6f0, and onto the trunk | **conflicts** (Finding 1) |

**Probe** (a native test added to `test_engine_audition.h`; reverted afterwards):
- Steps:
  1. `le_perf_arm(e, dir)`;
  2. `le_engine_audition_start(e, buf, 0)`, called before any block has applied the arm;
  3. drain, then run one block.
- Result: the start returns `LE_OK`; afterwards `a_perf_armed == 1`, the audition reads `frames=4096, position=64`, and the output carries the preview. See Finding 2.
- In that probe build, an unrelated test (`test_fade_restore_staging_and_manifest_capacity`, line 898) failed once while the TSAN build was running beside it. The same test passed in all three full configurations, so I count it as a load-sensitive flake, not this commit.

## Verified correct (traced)

1. **Commands and raw posts.**
   - `LE_CMD_AUDITION_START = 136` and `LE_CMD_AUDITION_STOP = 137` collide with nothing in the enum on this branch, on the trunk or on any remote branch, and match the ledger.
   - `le_engine_post_command` refuses both. A raw START could not carry the owned buffer pointer anyway.
   - Neither command is perf-logged: the apply path calls `le_audition_apply` before the logging cases, so an offline render or replay can never contain a preview.
2. **The mix point.**
   - `audition_frame` runs after the output-bus loop and before `master_bus_frame`.
   - The performance tap is inside `output_bus_frame` (`perf_tap_master_pair`, `tap_here`), so a capture never contains the preview.
   - Loop takes record inputs only.
   - Destination level, mute and chains do not touch it; master gain and the limiter do.
   - The native tests pin each with exact samples: output level 0 and mute still pass it, master gain halves it, the limiter caps it, it sums sample for sample with a playing loop, a take recorded under it is byte-identical, and the capture holds none of it.
3. **The two-buffer registry and the hand-back.** It follows the backing's ownership rules on its own arrays (`audition_owned[2]`, `a_audition_dead[2]`):
   - A start collects first, then takes a free slot, then publishes ownership before the push, and undoes it if the push fails.
   - The callback returns the buffer it replaces, stops or finishes through a CAS on a dead slot (release), and never frees.
   - The control thread exchanges it out (acquire) and frees it.
   - At most two buffers exist, so a dead slot is always free for a return, and no buffer is returned twice: `audition_frame` nulls it right after the return, and `le_audition_clear` returns only the current one.
   - `le_audition_release` (configure, reopen, destroy) runs with the callback stopped, before the rings are dropped, so a START still queued in the ring is freed rather than leaked. ASan confirms this in `test_audition_refusals` and `test_audition_lifetimes`.
   - The command ring is drained before the frame loop (`engine_process.c` around 6676), and no deferred in-loop action touches the voice. So `audition_live`, computed once per block and refreshed after each frame, can never point at a cleared buffer.
4. **The end triggers.**
   - Performance arm (`le_audition_clear` in the arm apply) and Cut sound (`handle_cut_sound`) each hand the buffer back on the callback.
   - Configure and every reopen free everything and bump `a_audition_epoch` (tested: the epoch goes up by one each time, and nothing is owned afterwards).
   - A start while armed is refused with `LE_ERR_ALREADY_RUNNING`, and the caller keeps the buffer.
5. **The bounded decode.** The Dart seam calls `le_backing_decode_file(path, rate, 0, 120 * rate, ...)` inside `Isolate.run`, from the top-level `_decodeAudition`, which opens the library itself and returns the buffer as an address.
   - `start_frame` is 0, so it reads from the beginning.
   - `info.truncated` becomes `AuditionStart.truncated`.
   - The engine refuses a buffer over `120 * rate` frames, so the bound holds even for a caller that skips the decoder.
   - At 384 kHz, `120 * rate` is 46,080,000, well inside `int32`.
   - The native test decodes a longer WAV and reads 120 s and `truncated`.
6. **The Dart seam's ownership.**
   - If the engine was disposed during the decode, the buffer is freed.
   - On `NOT_READY` it waits 30 ms and retries once.
   - Any other refusal frees the buffer.
   - `auditionState()` is the collect point, so a dead buffer is freed on the next poll.
   - The mock and every fake implement the interface. The `le_audition_state` struct is in the ffigen includes, and the functions come in through `le_.*`.
7. **Build lists.** `engine_audition.c` is in `src/CMakeLists.txt`, in both Apple forwarders (`macos/Classes`, and the SPM `Sources/segno_engine`), and in the native runner and `build_test_lib.sh` through their `src/core/engine*.c` glob.

## Findings

### 1. Medium: the branch is built on a superseded copy of the backing stack and does not merge onto the approved #1223 or the trunk

- **The base:** p6a's parents are 28517aafc to d81d14170. #1223, approved, is now caaabe6f0, a rewritten stack. It adds decoder fixes that this commit's bounded read relies on:
  - "an empty bounded read is empty, not damaged";
  - format whitelisting before miniaudio, bounded I/O, and refusal of non-finite samples;
  - refusal of samples beyond 60 dB over full scale;
  - `NOT_READY` while a backing buffer fades.
- **The conflicts:** `git merge-tree caaabe6f0 22b841ecb` conflicts in 16 files, among them `engine_process.c`, `engine_private.h`, `segno_engine_api.h`, `engine_decode.c` and the generated bindings. Against the trunk it conflicts in 5.
- **Impact:**
  - The audition as reviewed has not run against the decoder that will ship.
  - The resolution touches the audio-thread mix loop and the shared `le_backing_buffer` code.
- **Fix:**
  - Rebase onto caaabe6f0 (or onto the trunk once #1223 lands), and regenerate the bindings with ffigen, then `dart format`.
  - Rerun the four native configurations, `segno_engine` and `audition_test.dart`.
  - Check that the hardened decoder's new refusals (non-finite, over 60 dB) reach the Library as `invalid`, which the seam already maps to "This preview cannot be played".

### 2. Low: a start posted between a performance arm's post and its apply plays during the capture

- **Where:** `engine_audition.c` `le_engine_audition_start`, which checks `a_perf_armed`. That flag is set by the callback when it *applies* the arm (`engine_process.c`, the `LE_CMD_PERF_ARM` case). `le_audition_apply` does not look at `e->perf.armed`.
- **Mechanism:** the control thread posts ARM, then a Listen start (whose 0.1 to 1 s decode just finished) passes the flag check, and the ring holds ARM then START. The callback applies the arm, which clears nothing, then the start, so the preview plays while the take records.
- **Reproduced:** in the probe, `a_perf_armed=1`, the audition reads `frames=4096, position=64`, and the output is not zero.
- **Impact:**
  - It breaks D10's "audition ends on performance arm" and the API doc's `LE_ERR_ALREADY_RUNNING` promise, in a window of about one block.
  - The capture does not contain the preview, because the mix point is after the tap. But the preview is audible on the main pair during the performance.
- **Fix:**
  - In `le_audition_apply`, when `e->perf.armed` is set, hand the buffer back and do not start it.
  - Pin it with the probe above as a test.

### 3. Low: the audition hand-back has no TSAN coverage

- **Where:** `run_native_tests.sh`. The TSAN job builds only the race binaries, and `test_backing_races.c` exercises the backing's load, stage and clear against the callback, but nothing calls `le_engine_audition_start` or `le_engine_audition_state` while blocks run on another thread.
- **What exists:** the audition tests are single-threaded (`bk_run` on the test thread). The atomics are the backing's pattern and look right, but nothing checks that.
- **Fix:** add an audition loop to `test_backing_races.c`: start, collect and stop from the control thread while a pump thread runs blocks, with a performance arm in the mix.

### 4. Low: the Dart doc promises FLAC, which the decoder refuses

- **Where:** `audio_engine.dart`, the `EngineAudition` doc ("WAV, FLAC, MP3").
- **The decoder's own contract:** `segno_engine_api.h` says "FLAC is compiled out until the vendored miniaudio carries the fix for CVE-2024-41147".
- **Impact:** a FLAC preview is refused as unplayable, so the doc is wrong.
- **Fix:** drop FLAC from the doc until the decoder takes it.

## Notes

- **The mock never ends a preview.** `MockAudioEngine.auditionStartFile` sets one second of frames, never advances `position`, and a performance arm does not clear it. On the mock flavour, Listen plays until Stop. That is harmless, but it differs from the native voice the Library cubit polls.
- **The rate is read before the decode.** `auditionStartFile` reads `snapshot().sampleRate` first. If a reconfigure changes the rate during the decode, the start is refused as a rate mismatch (`invalid`) and shown as unplayable rather than "try again".
- **The window and the meters include the preview.** The loop-visualisation tap and the output meters are inside `master_bus_frame`, so they show the preview. That is correct for "what you hear", but worth knowing when reading the meters during a Listen.

**Verdict:** Request changes, for Finding 1, the rebase onto the approved #1223 with a rerun. The voice itself is sound:
- commands 136/137 are unique and refused raw;
- the mix point is after every bus and its tap;
- the two-buffer registry and hand-back hold under ASan;
- the bounded decode runs off the UI isolate;
- configure, reopen and Cut end the preview.

Findings 2 to 4 are Lows that can land with the rebase.

---

## Delta review (8c4cb9c48)

Model: Claude Opus (subagent), in-session

PARTIAL - stopped for cloud migration

**Scope:**
- 1b74322de: the audition commit rebased onto #1223's head caaabe6f0. Its range-diff against 22b841ecb shows context only.
- 8c4cb9c48: the Lows commit.

**Runs at 8c4cb9c48** (one `TMPDIR` per run):

| Check | Result |
| --- | --- |
| Native suite: plain, ASan, telemetry off | ALL PASSED (7), exit 0, no ASan reports |
| TSAN races (`NATIVE_TESTS_ONLY=races`) | all pass, 0 warnings. The backing race binary reports about 1,600 previews and 51 arms per run |
| `segno_engine` Dart tests | +387, all passed |
| `dart analyze packages/segno_engine` | No issues |

**Merge state:**
- p6a merges onto caaabe6f0 cleanly.
- p6a, P2 itself and p8 each conflict with the current trunk in the same 5 engine files (the bindings, `engine.c`, `segno_engine_api.h`, `run_native_tests.sh` and `test_engine_core.c`). These are #1223's conflicts with the trunk, not this PR's.

## Earlier findings: status

1. **Finding 1 (stale base): fixed.** p6a sits on caaabe6f0.
2. **L1 (the arm race): fixed.** `le_audition_apply` hands a START back unplayed when `e->perf.armed` is set. `test_audition_start_racing_an_arm` is my probe, made a test.
3. **L2: fixed.** A start with `2 * bus >= a_out_channels` is refused with `LE_ERR_INVALID`. A mono device still takes pair 0, mixed to the middle.
4. **L3: fixed.** The mock preview advances a block per snapshot and ends after its last frame. It also ends on arm, Cut sound, stop, start and reopen. It refuses while armed and on a missing pair, and bumps its epoch per configure.
5. **L4: fixed.** The doc names WAV and MP3, with FLAC compiled out.
6. **L5: fixed.**
   - `NativeAudioEngine.offIsolate`, which defaults to `Isolate.run`, is used through a top-level function, and a real-library test checks that it was called once.
   - `test_backing_races.c` now starts, stops and collects previews, cuts the sound, and arms and disarms a capture against a pumping thread.

## The paused pump

**Disarm.** The contract does exclude a concurrent `process` there, and only on a device-free engine. `le_perf_disarm` (`engine_commands.c`) has two branches:
- With `a_running == 1` (a real device), it never calls `le_engine_process`. It waits for `a_frames` to cross buffer boundaries.
- With `a_running == 0`, it calls `le_engine_process(engine, NULL, NULL, 0)` itself to consume the queued ARM and DISARM.

The race binary's pump is device-free (`a_running` 0), so letting it run through a disarm would mean two concurrent `process` calls, which no contract allows. Parking it there is required, and it hides no production race. A consequence is that the race binary never exercises the real-device disarm handshake. That handshake is pre-existing perf code, and it touches no audition state.

**Arm.** `le_perf_arm` never calls `le_engine_process` in either mode, so no contract requires parking the pump around it.
- The race the coordinator worried about (a start versus the arm's apply) is not hidden. The ARM is applied by a later pump block after resume, and the next operations race that apply.
- I checked the one thing the arm pause could hide: the arm's control-side setup (ring allocation, log-ring and layer-staging re-init) overlapping a running callback.
- Mutation: park the pump only around the disarm. TSAN, 3 runs: 0 warnings each, about 1,610 previews and 51 arms each.
- So no race is masked today. Still, I recommend parking only around the disarm, so TSAN keeps watching the arm path the way production runs it.

**The restack:** p6b 13756eab6, p7 da9eab036 and p8 7d59cdf74 differ from their reviewed heads only by the restack.
- The range-diff is `=` for 8bcd8d58d, 8114b6d5e, da9eab036 and 7d59cdf74.
- 3167b0fbd and 13756eab6 differ only where they adapt to p6a's new mock and native seam. p6b's own top-level decode helper is dropped in favour of p6a's `_decodeAuditionOffIsolate(offIsolate, ...)`.
- `git diff 1d296cf34 7d59cdf74` is empty outside `packages/segno_engine`.

## Findings

### D-1. Low: the race binary parks the pump around the arm without needing to

- **Where:** `test_backing_races.c`, case 12.
- **Fix:** park only around `le_perf_disarm`.

**Remaining** (not done because of the stop):
- the full app suite at 7d59cdf74 after the restack;
- a native-test mutation run for L1 and L2.

**Verdict (delta, provisional):** Approve.
