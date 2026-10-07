Model: Claude Opus (subagent), in-session

# Review of PR #1213 (origin/claude/pitch-time-1179-p2b, ffe645ef9): feat(looper): set and observe the global Speed through receipts

## Scope

- **What was reviewed:** one commit, `ffe645ef9`, on top of Part 2a's head `aa99ecc3f`. It is 17 files (+406/-6) and Dart only.
  - segno_engine: `SpeedFactor`, `AudioEngine.setSpeed`, `EngineResult.transformed`, `EngineSnapshot.speed`, `TrackSnapshot.headRate`, the native and mock engines.
  - looper_repository: `setSpeed` through `_requestReceipt`, and the `LooperState.speed` projection.
  - The four fakes.
  - Tests: `speed_native_test.dart`, `speed_receipt_test.dart`, and the engine_result, snapshot and mock tests.
- **Reviewed against:**
  - plan `docs/plan/2026-10-06-feat-pitch-time-core-plan.md`, Part 2b (`:870-893`) and decision 22;
  - AGENTS.md;
  - the owner rules;
  - the pen's "15 Performance · Speed" screens, read through the pencil MCP and not saved.

## Runs

| Run | Result |
|---|---|
| `git merge-tree` against `origin/claude/segno-integration` (`7a9fdcbd9`) | clean |
| `flutter test` packages/segno_engine (SEGNO_ENGINE_LIB from `build_test_lib.sh`) | +372, all passed |
| `flutter test` packages/looper_repository (same lib) | +808, all passed |
| `speed_native_test.dart` and `speed_receipt_test.dart` alone, expanded reporter | +4, all passed (the native case ran; it did not skip) |
| `flutter test` at the app root | +3195 ~195, all passed |
| `dart analyze --fatal-infos lib test packages` | No issues found |
| `bloc lint lib test packages` | 0 issues, 845 files analysed |
| Native suites (plain, ASAN, telemetry-off) on Part 2a's head, which 2b does not change | all ALL PASSED x5 (see the 2a delta) |

## Verified correct (traced)

- **Receipt semantics.**
  - `NativeAudioEngine.setSpeed` (`native_audio_engine.dart:845`) calls `le_engine_set_speed`, maps the admission through `EngineResult.fromCode`, and frees the `Uint64` in `finally`.
  - `LooperRepository.setSpeed` (`looper_repository.dart:2027`) goes through the same `_requestReceipt` as Fade and Reverse. An admission refusal completes at once with nothing posted. Otherwise it completes with the callback's own outcome, and a timeout expires as `notReady`.
  - The native test proves that queue acceptance is not the outcome: the future does not complete until the callback runs.
- **`EngineResult.transformed`.** It maps -10 (`audio_engine.dart:76`), which closes the first review's L3. `record` passes it through unchanged. The native test asserts `transformed` for a record on a playing track and on an empty one, and that the track stays PLAYING.
- **Projection.**
  - `EngineSnapshot.speed` comes from `speed_numer/denom` through `SpeedFactor.fromRatio`.
  - `TrackSnapshot.headRate` is `head_rate_milli / 1000`.
  - Both take part in `==`, `hashCode` and `copyWith`.
  - `LooperState.speed` is projected at `looper_repository.dart:2348` and is in `props`.
  - The engine's M2 reset (an empty loop returns to 1x) therefore reaches the repository state without any extra Dart path. The native publication is the announcement, and Part 6a must render it.
- **Mock.** It resets Speed and its receipt table at configure, answers each receipt once, and refuses record while Speed is not Normal. Fade and Reverse requests in the mock still read `invalid`, as before.
- **Fakes.** All four implement `setSpeed`, and the two receipt-modelling fakes take a configurable admission and result. `dart analyze` over lib, test and packages is clean, so no exhaustive switch on `EngineResult` was missed.
- **No app surface changes,** as the plan requires.

## Findings

### High

None.

### Medium

**M1. The repository sets a Speed on an empty rig, which then refuses the first take. This is the Part 2a M-D1 gap, now reachable from Dart.**

- **Where:** `LooperRepository.setSpeed` (`looper_repository.dart:2027`) has no guard of its own and relies on the engine. The engine accepts the request on an all-EMPTY rig (probe in the 2a delta: admit `LE_OK`, `speed=1/2`, then record returns -10).
- **Why it matters:** no surface calls `setSpeed` in 2b, but this is the seam Part 6a binds the pen's empty-loop pedals to (`04 / Speed / Empty loop`, YMPRG, shows ½× … 8× beside "No recorded audio").
- **Fix:**
  - Take the native fix of 2a M-D1, and add a repository case: `setSpeed(half)` on an empty rig does not leave `LooperState.speed == half`, and `record` returns ok.
  - Mirror the rule in `MockAudioEngine.setSpeed` (`mock_audio_engine.dart:675`). The mock never holds material, so as written the mock flavor would refuse every record once a factor is chosen.

### Low

**L1. The plan's "record-refusal notice path for `transformed`" is not built.**

- **What the plan says:** Part 2b (`plan:879`) lists it.
- **What was built:** the repository returns `transformed`, and `ControlCubit._recordAccepted` (`lib/control/cubit/control_cubit.dart:1628`) only treats it as not accepted (the contact stays dark), with no notice. That matches how Reverse's `EngineResult.reversed` is handled today, and it is unreachable until Part 6a.
- **Fix:** move the item explicitly to Part 6a's checklist, which already has "a refused change shows one notice", so a record refusal under Speed is not silent when the face ships.

**L2. `SpeedFactor.fromRatio` hides an unexpected factor.** It maps any pair it does not know to `normal` (`engine_snapshot.dart:419`). The only pair the engine publishes outside the five is 0/0 before configure. An engine change that published a new factor would show as Normal, which is a silent mismatch. Map 0/0 explicitly and assert, or log, on anything else.

## Notes

- `TrackSnapshot.headRate` reads 0 before configure (`head_rate_milli` is 0 in a calloc'd engine), while its Dart default is 1. Cosmetic; the first review noted the native side of this.
- `speed_native_test.dart` is fuzz-tagged like `fade_native_test.dart`. CI runs it in the job that builds the library (`flutter test --tags fuzz`, main.yaml), and I confirmed it runs locally with the library set.

Verdict: Request changes (M1, which is the Dart face of 2a M-D1; it closes with the native fix plus one repository case).

## Delta review (ddda2e10d)

Model: Claude Opus (subagent), in-session

### Scope

- `f3bf57eda`, the rebase of `ffe645ef9`: `git range-diff` shows only context changes (one export line).
- `ddda2e10d` "fix(looper): refuse Speed on an empty rig in the mock and pin the repository case".
- 2a's `36debe826` underneath, reviewed in the 2a delta.

### Runs

| Run | Result |
|---|---|
| `git merge-tree` against `origin/claude/segno-integration` (`890f04936`) | conflicts in `segno_engine_api.h` and the bindings only (the trunk's `LE_ERR_NOT_FOUND`/`LE_ERR_TRUNCATED` next to `LE_ERR_TRANSFORMED`); a rebase chore |
| `flutter test` packages/segno_engine (SEGNO_ENGINE_LIB from this head) | +378, all passed |
| `flutter test` packages/looper_repository (same lib) | +811, all passed |
| `flutter test` at the app root (same lib) | +3469 ~56, all passed |
| `dart analyze --fatal-infos lib test packages` | No issues found. The first run reported 389 issues, all in packages the scratch worktree had not run `pub get` in (storage_repository and others); after `pub get` it is clean. |
| `bloc lint lib test packages` | 0 issues, 882 files analysed |

### Status

- **M1 (Speed on an empty rig), fixed.**
  - The native refusal (2a's decision 26) reaches Dart as `EngineResult.invalid`.
  - The new native repository case starts an empty rig: `setSpeed(half)` is refused, `state.speed` stays Normal, `record()` is not `transformed`, and the engine's first take records.
  - The mock now refuses Speed the same way. It never holds material, and capture stays open.
- **L1 (record-refusal notice), moved.** It is now in Part 6a's text and its first success criterion ("a record refused with `transformed` shows one notice"), together with "the empty-loop face shows the factor pedals unavailable".
- **L2 (`fromRatio`), changed.** It now maps 0/0 to Normal and throws `ArgumentError` on any other unknown pair. See L-D1.

### Findings

#### Low

**L-D1. `fromRatio` can now throw on a torn read of the factor, and the factor can be torn.**

- **Cause:**
  - The callback publishes the factor as two separate relaxed stores, `a_speed_numer` and then `a_speed_denom` (`engine_process.c:3465-3466`).
  - `le_engine_get_snapshot` loads them as two separate atomics (`engine_snapshot.c`).
  - A snapshot taken between the two stores during ½× → 2x, 4x or 8x reads 2/2, 4/2 or 8/2. `EngineSnapshot.fromNative` then throws.
  - The throw lands in `LooperRepository._poll` (`looper_repository.dart:2059`), so that tick's settling and Clear Undo bookkeeping are skipped, and in every synchronous caller of `snapshot()`, `record()` among them.
  - The other direction (8x → ½× read as 1/1) shows Normal for one poll. That is the silent case the change meant to remove.
- **Likelihood:** the window is two adjacent instructions, so this is rare. But it turns a one-poll wrong label into an exception on the UI thread (rule 2).
- **Fix:** publish the factor as one atomic, for example `numer << 8 | denom` in an `int32`, read once. Keep the throw only for a value no build can publish, or map it to Normal with a logged error.

### Notes

- `Track`/`LooperState` projection and the four fakes are unchanged since the first review.

Verdict: Approve (L-D1 is a follow-up worth taking before Part 6a draws the factor).
