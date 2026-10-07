Model: Claude Opus (subagent), in-session

# Review of PR #1241: feat(looper): selected render through the repository

## Scope

- PR #1241, `origin/claude/render-1202-p2` at `eebc8b160`, stacked on Part 1 (`claude/render-1202-p1` at `1ac22cb9b`). The Part 2 work is `0bb8cf190`, followed by a merge of Part 1.
- Issue #1202. Plan: PR #1225 at `0f1297987`, Part 2 and its build record.
- Read in full:
  - in `segno_engine`: `selected_render.dart`, the `EngineSelectedRender` role on `AudioEngine`, the `NativeAudioEngine` and `MockAudioEngine` implementations, and the `EngineResult` additions;
  - in `looper_repository`: `SelectedRender`, `SelectedRenderPlan`, `RenderProgress`, `RenderOutcome`, `RenderJob` and the repository methods;
  - the four fakes;
  - every new test.
- No UI in this part, so the pen is not involved.

## Runs

All in my own worktree, with `SEGNO_ENGINE_LIB` from `build_test_lib.sh` at this head.

- **segno_engine:** 389 passed, including the fuzz-tagged native render tests.
- **looper_repository:** 827 passed. With `--tags fuzz` (the CI job that runs the native repository test): 63 passed.
- **App suite:** 3,464 passed, 56 skipped, 0 failed.
- **Static checks:**
  - `dart analyze --fatal-infos lib test packages/segno_engine packages/looper_repository`: clean;
  - `bloc lint lib test packages`: 0 issues in 876 files.
- **Native probe on the Part 1 code under this seam:** the staging heartbeat count (finding M1).
- **CI coverage.** The `fuzz` job runs both packages' native-backed tests: `flutter test` in `packages/segno_engine` and `--tags fuzz` in `packages/looper_repository` (`main.yaml:425-440`). So `selected_render_native_test.dart` and `render_native_test.dart` do run in CI.

## Verified correct (traced)

- **The FFI mapping.**
  - Enum orders match the C enums: `RenderTails` wrap 0 / cut 1, `RenderTarget` memory 0 / file 1, `RenderJobState` codes 1-5.
  - `EngineResult.fromCode` maps −16 and −17. Codes reserved by other branches (−10..−15, −18, −19) still map to `invalid` until those land.
  - The request path is a `toNativeUtf8` freed in `finally`, and `calloc`'d structs and out-params are freed on every path (`native_audio_engine.dart:2478-2584`).
  - `copyRender` copies out of native memory before freeing.
  - `pollRender` returns `null` for an id the engine no longer holds.
- **Measure.** It sends a memory request, because a file request without a path is refused and the plan does not depend on the target.
  - The repository turns the plan into seconds, beats and bars with `snapshot.sampleRate` and `snapshot.tsNum`.
  - The plugin, faded and pending track sets pass through, which is what Part 3's warnings need.
- **The Session gate.** Both measure and begin return `notReady` while `_sessionAudioReserved` is true. A Session applied mid-render instead fails the job with `tracksChanged` through Part 1's revision checks, which fails safe.
- **RenderJob lifecycle.**
  - It polls on a periodic timer; each poll is also Part 1's staging heartbeat.
  - It publishes progress only on change.
  - It completes `outcome` exactly once and closes the progress stream.
  - A DONE file job is released at once (`render_job.dart:89-90`). A DONE memory job is kept until `release()` or the next render.
  - A failed job is not cancelled; Part 1's tick already frees its buffers, and the next begin retires it.
  - `cancel()` is idempotent. `release()` on an unfinished job cancels it.
  - `LooperRepository.dispose` cancels the job it started last (`looper_repository.dart:8018`).
- **Mock.** The mock engine answers `unsupported` rather than inventing audio, as the build record says.
- **Value types.** Value equality on the request, plan, progress and outcome types makes the repository tests literal.
- **Plan match.** The build matches Part 2's plan list:
  - `SelectedRender {sources, lengthBars?, tails, mixFx}`;
  - `measureRender`, `renderToFile`, `renderToMemory`;
  - a `RenderJob` with `Stream<RenderProgress>` and `cancel()`;
  - `notReady` under the Session reservation;
  - the bars/beats/seconds readout and the three track lists;
  - the engine role composed into `AudioEngine` like `EnginePerformanceCapture`.

## Findings

### Medium

**M1. Progress reads 0% for seconds while sources are staged, and staging speed is set by the poll interval.**
- **Where.**
  - Part 1 stages one 48,000-frame chunk per heartbeat (`engine_render.c:560`, "one bounded chunk per heartbeat").
  - `le_render_progress` counts only setup units and window passes (`:904-912`), so `permille` is 0 for the whole of staging.
  - `RenderJob` heartbeats every 16 ms. The repository's own snapshot poll also drains events, so at best about two chunks land per 16 ms.
- **Probe** (Part 1 at `1ac22cb9b`, eight mono 30 s sources):
  - staging took 241 heartbeats, 3.9 s at 16 ms;
  - `permille` stayed 0 throughout.
- **Scaling.** The time grows with the material: stereo doubles it, 96 kHz doubles it again, so a full stereo 96 kHz rig sits at 0% for about 15 s with one poller.
- **Failure.** Part 3's "Saving… N%" and Part 6's "Bouncing / N%" show 0% for seconds before anything moves. The player reads that as a hang, and the only exit offered is Cancel.
- **Fix.** Pick one or both:
  - let staging copy several chunks per heartbeat within a time budget (for example up to 2 ms of `memcpy`), and count staged frames in `permille`;
  - have `RenderJob` expose `RenderJobState.staging` as its own progress phase, so the surfaces can say "Preparing", and poll faster while staging.

  Add a repository test that a staging job reports non-zero progress before rendering.

### Low

- **L1. A job stuck in FREEZING never ends.** `RenderJob` has no timeout for that state. The freeze needs one audio callback. If the device is running but not calling back (the present-but-disconnected state before a reopen), the job sits in FREEZING until the reopen's configure fails it with `device`, and the surface shows 0% throughout. Add a bounded wait, for example 2 s in FREEZING, that cancels with a `device`-like outcome, or document that the reopen path always ends it.
- **L2. One kept memory job can be silently replaced.** `renderToMemory` keeps its result in the engine until `release()` or the next render, and the engine retires a DONE job at the next begin. If a Bounce result is waiting for commit and anything else starts a render, the Bounce job is silently replaced: its `copySamples` returns `null`, and Part 4a's `le_engine_bounce` will refuse the job id. Part 5 should hold its job across the commit, or the repository should refuse a new render while it holds an unreleased memory job (`alreadyRunning`).
- **L3. The bars readout and the engine can disagree on the time signature.** `SelectedRenderPlan.fromEngine` reports `bars: null` when `snapshot.tsNum` is 0. The native chosen length then treats the signature as 4/4 (`engine_render.c`, `if (num < 1) num = 4`). The readout and the native length can disagree on a rig with no time signature. Use the same default in both.
- **L4. Engine enums cross the repository boundary.** The repository re-exports `RenderJobState`, `RenderTails` and `RenderTarget` from `segno_engine`. That follows the existing practice (`RecordTiming`, `TrackHistory`), but Part 3's cubit will then import engine enums through the repository. A repository-owned enum, or `SelectedRender` carrying its own tails type, would keep the boundary. Not blocking.

## Notes

- **Disposal.** `dispose()` is called twice in the dispose test (once in the test, once in `tearDown`). It passes, so dispose is idempotent here; keep it that way.
- **Outcome naming.** `RenderOutcome(result: ok, cancelled: true)` for a cancel is documented. A dedicated `cancelled` result would read less ambiguously in Part 3's mapping.
- **Part 1 parity.** At this Part 1 head, the renderer, the budget and the WAV writer were re-verified in the Part 1 delta review (`render-p1-in-session/review.md`).

Verdict: Approve (M1 should be fixed before Part 3 shows progress; it does not block the seam)

## Delta review (23ba2a4e6)

### Scope

- `a4329bd5e`: RenderPhase, the freeze timeout, the `holdsResult` refusal, the bars default, enum ownership and `onceCutTracks`.
- `23ba2a4e6`: the native test changes material between the freeze and staging in one callback.
- Also a merge of Part 1 at `07d65b615`.

### Runs

At `23ba2a4e6`, with `SEGNO_ENGINE_LIB`:
- **segno_engine:** 390 passed.
- **looper_repository:** 831 passed, 1 failed.
  - The failure is `re-apply on restart … announces exact FX replay confirmation` (`looper_repository_test.dart:9193`). This PR does not touch it.
  - It passed 3 of 3 runs on its own. It failed only while two other suites were running.
  - The same suite at the 4a head passed (832).
- **looper_repository `--tags fuzz`:** 63 passed.
- **`dart analyze --fatal-infos lib test packages/segno_engine packages/looper_repository`:** clean.

### The asked-for checks

- **RenderPhase: done.**
  - `RenderProgress` now carries a repository-owned `RenderPhase` (freezing, staging, rendering, done, failed).
  - Native `none` is filtered out, and progress events are deduplicated.
  - With Part 1's staging progress, "Preparing" moves (M1 resolved).
- **Freeze timeout: done** (L1 resolved).
  - A job still FREEZING after 2 s (a `Stopwatch` started at the first FREEZING poll) is cancelled and ends with `EngineResult.device`.
  - A late callback can only apply a stale freeze, which Part 1's id gate ignores.
  - The interval and timeout are injectable, and tested.
- **`holdsResult` refusal: done** (L2 resolved).
  - While the last memory job is finished and not released, `renderToFile` and `renderToMemory` return `alreadyRunning` instead of letting the engine retire it.
  - `release()` and `cancel()` clear the hold.
  - A FAILED job is now cancelled in the engine, so it never blocks.
  - `dispose()` releases the job.
- **Bars default: done** (L3 resolved). Without a time signature the readout divides by 4, matching the native chosen-length default (`num < 1` → 4).
- **Enum ownership: done** (L4 resolved). The repository owns `RenderTailRule` and `RenderPhase` and no longer re-exports `RenderJobState`, `RenderTails` or `RenderTarget`. It maps `RenderTailRule` to the engine enum in `_renderRequest`.

### Findings

**L-F1 (Low). A held result can block Save audio indefinitely.**
- **Failure.** If Part 5/6 ever loses track of a finished Bounce job, for example by leaving the flow without calling `release()`, every later render returns `alreadyRunning` until the repository is disposed. Save audio then refuses with a busy reason the player cannot clear.
- **Fix.**
  - Part 5's tests should pin that Exit, cancel and commit all release.
  - Consider a distinct refusal (for example `notReady` with a "bounce waiting" reason), so Save audio's notice can say what holds it.

**L-F2 (Nit). One engine type still reaches the public surface.** `RenderJob`'s public constructor still takes `segno_engine`'s `RenderTarget`. Callers never construct a `RenderJob`, so this does not leak in practice. A `@visibleForTesting` or internal factory would finish the ownership change.

### Notes

- **Stale comment.** The comment at `_poll`'s `status == null` branch now says "a reconfigure retired it". A reconfigure keeps the job as FAILED/DEVICE (Part 1), so `null` really means it was cancelled or replaced. The behaviour (`invalid`) is fine.

Verdict: Approve
