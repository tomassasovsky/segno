Model: Claude Opus (subagent), in-session

# Review of PR #1261 (origin/claude/instruments-1197-p2b @ e71f8d2ce, stacked on #1234): feat(engine): instrument sources 32-39 through the mix and Dart bounds

## Scope

- One commit on `46327b5ed`, 19 files, +445/−104 (about 395 lines of
  C/header change):
  - `segno_engine_api.h` (`LE_INSTRUMENT_SOURCE_BASE`, `LE_MAX_SOURCES`,
    `LE_MAX_MONITORED_INPUTS = LE_MAX_SOURCES`, a 64-bit `monitor_mask`,
    per-source monitor gain and pan, snapshot `input_peaks`,
    `monitor_peaks` and `input_trim` widened to 40);
  - `engine_instruments.h` (`le_source_is_instrument`,
    `le_instrument_source_sample`, `inst_bus_live`);
  - `engine_process.c` (capture, the sound trigger, monitors, the perf tap,
    and the mix image), `engine_commands.c` (`le_mix_valid`,
    `le_record_preflight`, `le_perf_arm`, the conditioning API bounds),
    `engine_snapshot.c`, `perf_drain.c`, `engine.c`;
  - 244 lines of tests;
  - Dart: the hardware-input loops in `monitor_cubit`,
    `input_conditioning_cubit`, `monitor_migration` and
    `fx_chain_persistence` move to `kMaxChannels`; `kMaxMonitoredInputs`
    becomes 40; the bindings are regenerated.
- Reviewed against:
  - Part 2b and D3 of the plan at `5e36d2666`;
  - the plan review's H1, H4 and L2;
  - AGENTS.md and the owner rules.

## Runs

Each run used a fresh TMPDIR, in a scratch worktree at `e71f8d2ce`.

**Native suites.** The machine's load average was about 40 throughout,
because other agents were running.
- First round: plain rc 1, ASAN ALL PASSED, telemetry off rc 1. Both
  failures are the same check, `test_fade_restore_staging_and_manifest_capacity`
  (`test_engine_fade.h:898`, a 5 s wait for the perf-drain consumer).
- Plain re-runs 2 and 3: ALL PASSED.
- The fade group alone (`SEGNO_HISTORY_TESTS_ONLY=1`), on the prebuilt
  binaries:
  - Part 2a: failed 1 of 4 under that load, then passed 3 of 3;
  - this branch: failed 4 of 4, then passed 3 of 3.
- So this is a timing flake that depends on load and already exists in
  Part 2a; it is not caused by this change. See Notes.

**Other runs.**
- TSAN races job: 0 failures (the instrument race scenario reported 0 stuck
  notes).
- Bench smoke: `bench_instruments.sh` and `bench_pitch_time.sh` both pass.
- Dart:
  - `packages/segno_engine` with `SEGNO_ENGINE_LIB`: 370/370;
  - `packages/looper_repository`: 753 passed, 51 skipped;
  - `test/app` and `test/audio_setup` (after `flutter gen-l10n`): 643
    passed, 9 skipped;
  - `dart analyze --fatal-infos lib test packages/segno_engine packages/looper_repository`:
    no issues.
- PR CI on `e71f8d2ce`: 16 checks passed and 7 were pending when I read
  it. native-bench-arm64 passed, with joint p50 at 35.3 % against 37.5 %.

## Verified correct (traced)

- **One source index space.** Source `32 + k` is instrument slot `k`, and
  `LE_MAX_SOURCES = 40`. Physical-only stages stay at `LE_MAX_CHANNELS` with
  their 32-bit masks:
  - conditioning (`cond[]`, the API bound and the command bound);
  - clip arrays;
  - capture trim (`trim_mask`, `input_trim[32]`);
  - loopback exclusion.
- Every `1u << c` that could see `c >= 32` is now guarded or 64-bit:
  - `le_mix_valid`, the mix image, `snapshot_monitor_fx`,
    `LE_CMD_SET_MONITOR_INPUT`'s excluded check and
    `LE_CMD_SET_LANE_INPUT`;
  - `le_perf_*` and `perf_drain.c`;
  - `le_lane_input_bits` (instrument lanes have no legacy bit).
- **Capture.** `mix_tracks_frame` reads `le_instrument_source_sample` for
  sources 32-39, with no trim and no loopback check. An empty slot's bus is
  silence. An oversize block reads silence through `inst_bus_live`.
- The test proves the take is sample-for-sample equal to the bus with Hear
  live off (output exactly zero), and that a lane routed to 33 with no patch
  records silence.
- **The sound trigger** takes `|bus|` per frame for instrument sources. The
  test confirms the start lands in the block after the strike, at the exact
  frame, and that an empty slot refuses the arm (`le_record_preflight`
  requires a patch).
- **Monitors.**
  - `mix_monitors_frame` now always visits the eight instrument sources and
    skips device channels when there is no input.
  - Every array is initialised for every index it reads
    (`mon_on = {0}`, `mon_peak = {0}`, and `snapshot_monitor_fx` fills
    32-39).
  - Peaks for 32-39 are stored after the frame loop.
  - The test checks bus × 0.5 × the pan law within 1e-6.
- **Mix transaction (H1, H4).**
  - A 64-bit `monitor_mask` with bits above 40 refused.
  - Lane inputs `[−1, 40)` are accepted, an empty slot included.
  - A stray physical route (`lane_input 5` on a 2-in device) is still
    accepted (rule 1).
  - Lane input 40 and a monitor bit at 40 are refused.
  - All of these are tested.
- **Performance stems.** `le_perf_arm` captures every monitored instrument
  source whose slot has a patch (`input-33.pcm`), and skips a monitored
  empty slot. Tested.
- **Snapshot.**
  - `input_peaks[32+k]` is the bus peak and `input_trim[32+k]` is 1.
  - `monitor_peaks` is read from every source.
  - The tuner refuses source 32 at apply (`tuner_input == -1`).
  - `input_cond_mask` and `input_clip_mask` never carry an instrument bit.
- **Dart L2.**
  - The four physical loops named in the plan now scan `kMaxChannels`, so
    the app's behaviour is unchanged until Part 3c.
  - `EngineSnapshot` still sizes `inputPeaks` and `monitorPeaks` to the
    device's inputs.
- **Real-time cost.** The extra work is 8 more monitor iterations per frame
  and 8 more monitor snapshots per block, with no allocation or lock.

## Findings

### Low

**L1. Dart's input-conditioning setters now accept sources 32-39, which the engine refuses (`packages/looper_repository/lib/src/looper_repository.dart:5263`, `:5283`).**

`setInputConditioningEnabled` and `setInputConditioningParam` still bound
the input by `kMaxMonitoredInputs`, which is now 40. They record
`_condEnabled[32]` and `_condParams[32]` before calling the engine. The
engine bounds conditioning at `LE_MAX_CHANNELS` (`engine_commands.c:3853`,
`:3860`) and returns invalid.

Failure scenario: any caller passing an instrument source (Part 3c
widening by mistake, or a fuzz case) leaves Dart state that disagrees with
the engine. That state would be replayed after every restart and refused
every time. No current caller passes 32 or above, so this is latent.

Fix: bound both setters by `kMaxChannels` (conditioning is a hardware
stage, as the commit says), and add one test that 32 is refused.

**L2. `setMonitorMute` and the chain-inheritance helpers silently widened too (`:3211`, `:4879`, `:5242`).**

For these three, accepting 32-39 is right: an instrument's monitor can be
muted, and an instrument lane inherits its monitor chain. But the commit
says "the app's behaviour is unchanged until Part 3c", and these are
behaviour changes for any caller passing 32+.

There are no such callers today. Either note them in the commit or plan, or
leave them for Part 3c's `isSource` sweep and its per-site tests.

## Notes

- **The fade flake.** `test_fade_restore_staging_and_manifest_capacity`
  waits at most 5 s for the perf-drain consumer, and fails under heavy load
  on Part 2a as well. It is pre-existing, outside this PR, and worth its
  own issue: wait on a completion signal, or give it a longer bound.
- **ABI.** The snapshot's widened arrays sit mid-struct, so every consumer
  must be rebuilt against the regenerated bindings. The bindings are in this
  PR and the Dart suites pass.
- **Order of struct members.** `le_mix_settings.monitor_mask` moved ahead of
  `trim_mask` when it was widened. Only the generated bindings and C touch
  the struct.

Verdict: Approve (L1 is latent and a one-line fix; it can ride Part 3c if preferred).
