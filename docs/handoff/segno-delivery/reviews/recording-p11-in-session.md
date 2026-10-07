Model: Claude Opus (subagent), in-session

# Review of PR #1221: #1198 Part 11, one guard table checked at each operation's commit

**Branch:** `claude/recording-1198-p11` at 7e82f82c1, base `claude/segno-integration`. Note: the branch has since moved to a7e961204 (10:00), which changes only the table and its literal test (Finding 1). Everything else below is the same at both heads.

## Scope

- 23 files, +1042/−3:
  - the new `packages/operation_guards` (`GuardKind`, `GuardRule`, `GuardScope`, `ActiveOperation`, `ActiveOperationSource`, `GuardRefused`, `OperationGuard`, `GuardRegistry`) and its CI job;
  - the capture guard in `PerformanceRepository.arm`/finalize, with `armRefusals`;
  - `PerformanceRecorderIdle.refusedBy`;
  - the `sessionApply` guard in `SessionCubit.loadNamed`;
  - the `sessionWrite` guard in `SessionRepository.save`;
  - one registry threaded through `runSegno`, `main_mock`, `App` and `AppRuntime`.
- Against plan `docs/plan/2026-10-06-feat-recording-recovery-plan.md` D8 and Part 11, as of `claude/recording-recovery-plan-1198` 69972aa2f, the revision after review that adds L6.

## Runs

- `packages/operation_guards` `flutter test --coverage`: 71/71, lcov **58/58**.
- `packages/performance_repository`: 134/134. `packages/session_repository`: 125/125.
- App suite: 3345 passed, 49 skipped.
- `dart analyze --fatal-infos lib test packages/operation_guards packages/performance_repository packages/session_repository`: no issues. `bloc lint lib test packages`: 0 issues in 846 files.
- No native change, so there is no native suite to run.
- 7 mutations, each removing one release or the refusal plumbing: the release on perfArm failure, on finalize, on a cancelled failed arm, in `save`'s `finally`, and in `loadNamed`'s `finally`; keeping the refused arm's directory; dropping the cubit's refusal handler. **All 7 killed.**
- One probe for a leak the suite does not cover (Finding 3).

## Table versus D8

I checked cell by cell against the plan's matrix (row = wants to commit, column = active):

| Row | Plan | 7e82f82c1 | a7e961204 |
| --- | --- | --- | --- |
| capture | – r a **v** v r r r | r r a **a** v r r r | r r a v v r r r ✓ |
| sessionApply | a r r a a r r r | same ✓ | ✓ |
| sessionWrite | a a i a a a a r | same ✓ | ✓ |
| transfer | **v** a a a v a a r | **a** a a a v a a r | v a a a v a a r ✓ |
| eject | v a a v r a a r | same ✓ | ✓ |
| deviceChange | r r a a a r r r | same ✓ | ✓ |
| calibration | r r a a a r r r | same ✓ | ✓ |
| restart | r r r r r r a – | r r r r r r a r | same |

- The plan's "–" diagonal cells (capture over capture, restart over restart) are `refuse` in code. That is the safe reading of "cannot happen".
- The literal test enumerates all 64 pairs × {same volume, other volume, same item, other item}, so a transposed cell or a reordered enum fails.

## Verified correct (traced)

1. **Check and register are one synchronous step.** `enter` computes `blockers` and appends the guard with no `await`, so on one isolate nothing can slip between. A refused `enter` registers nothing (tested).
2. **Scope semantics.** `sameVolume` compares generations (null = Internal). `sameItem` is the same volume and (either item null, or equal items), so a whole-volume operation covers every bundle on it. `refuseSameVolume` therefore also refuses same-item pairs, as the test asserts.
3. **Sources.** `active` is recomputed from `ActiveOperationSource`s on every call, so an owner's lease shows the moment it is taken and disappears when released, with no copy of the owner's state (rule 4). Tested.
4. **Capture guard lifetime.** Entered after the last `await` of `_armGated`, just before `perfArm`. That is after the re-check of `_armedDir`/salvage/render, so a refused or superseded arm never holds it. Released:
   - when `perfArm` fails;
   - in `_cancelFailedArm` when the native disarm succeeds;
   - at the end of `_finalizeArmed`.
   When the native disarm fails, the guard stays held together with `_armedDir`, which is right: the capture is still live. A refused arm deletes the directory it created and calls no `perfArm` (tested and mutation-checked).
5. **`sessionApply`** is entered after the bundle is read and validated and before `disarmAndFinalize`, the first change to the rig. It is released in the outer `finally`, after the boot completes or fails, so every error path in `loadNamed` (validation, mix write, rollback, apply, boot persistence) releases it.
6. **`sessionWrite`** is entered after `_capture` and before the bundle directory is created, so a refusal leaves the bundle untouched. It is released in `finally` around `_writeBundle`.
7. **One registry** is built in `runSegno` (or injected with all three repositories, which the assert enforces) and shared by the session and performance repositories and `AppRuntime`'s `SessionCubit`. `main_mock` does the same.
8. **CI:** `main.yaml` adds the `operation_guards` package job with `min_coverage: 100`, and lcov is at 100%.

## Findings

### 1. Medium, fixed on the branch head: the reviewed table missed the plan's L6 revision

- **Where:** `guard_registry.dart:206,213` at 7e82f82c1. The capture row's transfer cell and the transfer row's capture cell were `allow`. The plan (review L6) makes them `refuseSameVolume` both ways: an export or backup to the stick a take records on competes for its bandwidth and ends the take as `slow_storage`. The test's `_d8` transcription had the same two cells, so it could not catch this.
- **Status:** a7e961204 sets both cells to `_v` and updates `_d8` to match. I checked that diff. It is exactly the two cells, with the comment updated, and nothing else moved. Nothing consumes the transfer row until USB Part 6 reports leases, so no behaviour shipped from the gap.
- **Ask:** review and land the branch at a7e961204 or later, not 7e82f82c1.

### 2. Medium: a refused arm is not visible anywhere yet

- **Where:** `PerformanceRepository.arm` returns `EngineResult.ok` on refusal and emits on `armRefusals`. `PerformanceRecorderCubit._onArmRefused` emits `PerformanceRecorderIdle(refusedBy: kind)`. **No view reads `refusedBy`.** `git grep refusedBy lib` finds only the cubit and the state. Compare `lowDiskBlocked`, which `lib/looper/view/tracks_commands.dart:441` turns into a message.
- **Scenario at this commit:** the player presses Record, or long-presses the pedal's MODE, while an Open is applying (`sessionApply` is held from disarm through boot, a second or more on the appliance). Before this PR the take armed. Now nothing happens and nothing is said: a silent behaviour change (rule 3) on the console's most consequential control.
- **Part 12 makes it worse.** Every device change, latency measurement and restart will refuse an arm the same way.
- **Also lost:** a refusal that arrives while the state is `Idle(recovering: true)`, `Armed`, `Finalizing` or `Rendering` is dropped. That is right for `Armed`, but it also drops the reason entirely.
- **Answer to the brief's question:** the silent `ok` is a reasonable contract for the pedal's direct call, given that `arm` already answers `ok` for its other refusals. But the stream only helps if something renders it, and nothing does yet.
- **Fix:** in this PR, render `refusedBy` where `lowDiskBlocked` is rendered. Use a toast: it is low-stakes and needs no immediate action (the popup-severity rule), with a localized reason per `GuardKind`, for example "Wait for the session to finish opening". Add a widget test for the toggle path and for the pedal path. If the owner wants the words to wait for Part 13, record that in the plan, because Part 11's criteria currently stop at the state field.

### 3. Low: the capture guard outlives the capture when finalize throws after the engine disarmed

- **Where:** `_finalizeArmed` (`performance_repository.dart` around `:560-616`): `perfDisarm()` succeeds, then `await _finalize(...)` throws, and `_releaseCaptureGuard()` is never reached.
- **Probe** (a temporary test, removed):
  - Arm, write the sidecar and `master.pcm`, and make `master.wav` a directory, then call `disarmAndFinalize()`.
  - It threw `FileSystemException ... Is a directory`. `perfDisarmCalls` was 1, `armedDirectory` was still set, and `guards.active` still held `capture/recording`.
  - A retry after removing the obstacle released it.
- **Realistic trigger:** ENOSPC while writing `master.wav`, at the end of a take that stopped because the disk filled.
- **Impact:**
  - At this commit nothing new is blocked: the recorder is stuck in `Finalizing`, which already refused power-off before this PR.
  - With Part 12, the stale guard also refuses audio apply, rate change and latency measurement until something retries the finalize. Today that is only an Open (`disarmAndFinalize`).
- **Fix:** release the capture guard as soon as `perfDisarm` succeeds. From then on nothing is capturing; the finalize is file work that `_finalizesInFlight` already fences. Or wrap `_finalize` in `try/finally`. Add the probe as a test.

### 4. Low: every owner silently falls back to a private table

- **Where:** `guards ?? GuardRegistry()` in `PerformanceRepository`, `SessionRepository` and `SessionCubit` (and `AppRuntime` passes `widget.guards`, null by default).
- **Scenario:** a future entrypoint, or the USB Part 6 wiring, builds an owner without passing the shared registry. Each owner then checks its own empty table and nothing refuses anything, with no error. That is the failure mode the "one table" rule exists to prevent.
- **Fix:** make `guards` required on the repositories' production constructors. Tests can pass `GuardRegistry()` explicitly. Or keep the default, but assert in debug that an app-wide registry was supplied (for example by having `runSegno` register it in a zone or a single locator).

### 5. Low: a refused Open or save surfaces as an unknown error with a developer string

- **Where:** `GuardRefused` thrown from `loadNamed`'s `enter` (or from `SessionRepository.save`) reaches `_performRun`'s `on Object` branch. It becomes `SessionError.unknown` with `errorMessage: 'GuardRefused(GuardKind.sessionApply, blocked by [ActiveOperation(...)])'`.
- **Fix:** map `GuardRefused` to a `SessionError.busy` (or similar) carrying the blocking kind, so the dialog can say what to wait for.

## Notes

- **Coverage of D8's rows is partial by design, but two gaps are not scheduled.** Part 11 wires `save` for `sessionWrite` and `loadNamed` for `sessionApply`. D8 also lists rename, duplicate, delete and restore-into-Internal under `sessionWrite`, and New loop under `sessionApply`. Part 12 covers power, restart, audio apply and latency, and USB Part 6 covers transfer and eject. No part names New loop or rename/duplicate/delete. Add them to Part 12 or to the Library parts that own those actions.
- **Item identity is a path string.** `GuardScope.internal(item: directory)` compares raw strings, so `/data/sessions/a` and `/data/sessions/a/` (or a symlinked root) are different items. Normalize the path (`p.normalize`, or the canonical bundle id) before entering.
- **The purposes already diverge from the storage leases' vocabulary** (`'recording'`, `'saving a session'`, `'opening a session'` here; `'copy'`, `'export'` in #1195). The usb-p5 review (Finding 3) proposes one typed purpose; the table's `GuardKind` is the natural key.
- **`retryLoadedSession`** re-runs the boot of the retained image without a `sessionApply` guard. It does not re-apply the rig to the engine, so it may not need one, but a one-line comment would save the next reader the trace.

**Verdict:** Request changes, for Finding 2: the refusal needs a visible consumer, or an owner decision recorded in the plan that it waits for Part 13. Finding 1 is already fixed at a7e961204; review and land that head. Findings 3-5 are low.

## Delta review (85e583ece)

Model: Claude Opus (subagent), in-session

**Scope:** `git log 7e82f82c1..85e583ece`. a7e961204 (the L6 table fix, already checked above) and 85e583ece: 62 files, +424/−32. Most of them are test call sites that now pass the required registry. The production changes are in `app.dart`, `app_runtime.dart`, `session_cubit.dart`, `session_state.dart`, `tracks_commands.dart`, the two ARB files, `performance_repository.dart` and `session_repository.dart`. Also checked: the plan at `claude/recording-recovery-plan-1198` 57a5324b8, which adds the D8 row owners. Worked in a temporary worktree, removed afterwards.

**Runs:**

| Suite | Result |
| --- | --- |
| `operation_guards` | 71/71 |
| `performance_repository` | 135/135 |
| `session_repository` | 125/125 |
| App suite | 3349 passed, 49 skipped |
| `dart analyze --fatal-infos lib test packages/operation_guards packages/performance_repository packages/session_repository` | no issues |
| `bloc lint lib test packages` | 0 issues in 847 files |

I also ran one probe on the refusal toast (Finding 1 below).

### Earlier findings

| # | Now |
| --- | --- |
| 1 Medium: L6 cells | **Fixed** (a7e961204). |
| 2 Medium: refused arm invisible | **Fixed for the first refusal.** A repeat refusal is still silent; see new Finding 1. |
| 3 Low: guard outlives a finalize that throws | **Fixed.** |
| 4 Low: private fallback tables | **Fixed.** |
| 5 Low: `GuardRefused` shown as an unknown error | **Fixed.** |
| Note: D8 rows with no owner | **Fixed in the plan.** |
| Note: item identity is a raw path | **Owned by the plan:** Part 7 uses the bundle id. |
| Note: `retryLoadedSession` | **Addressed:** a doc comment says why it takes no guard. |

How each was checked:

- **Earlier 2, refused arm.** `onPerformanceRecorderState` (the Tracks view's recorder listener) now shows a SnackBar for `PerformanceRecorderIdle(refusedBy:)` with `perfArmRefused(operationBusy(kind))`, one line per `GuardKind`, in English and Spanish. A snackbar is the toast tier, which suits a refusal that needs only waiting (the popup-severity rule). It sits next to `lowDiskBlocked`'s, so the toggle and the pedal both reach it through the cubit. Widget tests pin the copy and that every kind has distinct words.
- **Earlier 5, `SessionError.busy`.** `_performRun` catches `GuardRefused` before `SessionException` and emits `SessionError.busy` with `refusedBy` set to the first blocker's kind. `showSessionOutcome` prints `operationBusy(kind)`, so the developer string never reaches the screen (a test asserts that). `refusedBy` is per-transition in `copyWith`, like `error`, so it cannot leak into a later outcome.
- **Earlier 3, guard after `perfDisarm`.** `_releaseCaptureGuard()` now runs as soon as `perfDisarm` succeeds, before `_finalize`. A new test makes `_finalize` throw after the disarm and asserts `guards.active` is empty. Releasing earlier is safe:
  - From that point nothing captures, and a new arm is still fenced by `_armedDir` (kept until the finalize completes) and by `_finalizesInFlight`.
  - A failed `perfDisarm` still keeps the guard together with the live capture.
- **Earlier 4, private tables.** `guards` is now `required` on `PerformanceRepository`, `SessionRepository`, `SessionCubit`, `AppRuntime` and `App`, and `?? GuardRegistry()` appears nowhere. Every test call site passes one explicitly.
- **D8 row owners, plan 57a5324b8.** A paragraph under D8 names who enters each row:
  - Part 11: capture, Open's `sessionApply`, and save's `sessionWrite`.
  - Library Part 5's `newLoop()`: New loop's `sessionApply`.
  - Part 7: rename, duplicate, delete, move and restore into Internal enter `sessionWrite`, keyed by the bundle id, not a raw path, so `/a` and `/a/` are one item. Part 7's own list says the same.
  - USB Part 6: transfer and eject.
  - Part 12: power, restart, audio apply and latency.

  Every row of the table now has a named owner.

### New findings

#### 1. Low-Medium: a second refused press is silent, because the cubit drops an equal state

- **Where:** `PerformanceRecorderCubit._onArmRefused` emits `PerformanceRecorderIdle(refusedBy: kind)`. `Cubit.emit` skips a state equal to the current one, and `Idle` is Equatable over `(lowDiskBlocked, recovering, refusedBy)`.
- **Probe** (a temporary test, removed): with `sessionApply` held, toggle, then a direct `arm()` (the pedal), then toggle again. Three refusals, **one** emitted state, so one toast. The second and third presses show nothing.
- **Why it matters:** on the console that is the common case: a player presses again because nothing happened. With Part 12 the window grows to every audio apply and latency run.
- **The suite misses it:** the cubit test's "from the toggle and from a direct call alike" asserts the state after the pedal call, which is unchanged from the toggle's refusal, so that assertion passes even if the pedal's refusal were ignored.
- **Same root as before:** `lowDiskBlocked` has the same equal-state behaviour.
- **Fix:** give each refusal its own identity, for example a monotonically increasing `refusal` counter in `Idle`, included in `props`. Alternatively, deliver refusals as one-shot notices (a stream the view listens to) rather than as state. Then test two consecutive refusals produce two toasts, and the pedal path from a fresh cubit.

#### 2. Low: the Library plan does not yet know it owns New loop's guard

- **Where:** the recording plan (57a5324b8) assigns New loop's `sessionApply` to "Library Part 5's `newLoop()`". But `docs/plan/2026-10-06-feat-library-sessions-plan.md` Part 5 ("New loop", latest on `claude/library-1178-p3-lows`) does not mention `sessionApply`, `GuardRegistry` or operation guards.
- **Risk:** a builder working from the Library plan alone will not enter the guard, and nothing will fail.
- **Fix:** add one line and one success criterion to the Library plan's Part 5: `newLoop()` enters `sessionApply` at its commit and is refused with `SessionError.busy`.

### Notes

- **Where the toasts appear:** the toast comes from the Tracks view's listener. A refusal while the Sessions dialog is open (an Open refused by a save) shows the SnackBar on the page under the dialog's barrier, the same place every other session SnackBar already goes.
- **`operationBusy` takes the kind as a `String`** (`GuardKind.name`) in an ICU `select`. Renaming an enum value would fall through to `other` silently. The "every kind has its own words" test catches that, so it is pinned.

**Verdict:** Approve. Every earlier finding is fixed and tested, and the D8 rows all have named owners. Finding 1 is worth fixing before Part 12 widens the refusal window (a counter in `Idle` and a two-press test). Finding 2 is a one-line plan edit.

## Delta review (760e64697)

Model: Claude Opus (subagent), in-session

**Scope:** `git log 85e583ece..760e64697`, two first-parent commits:

- **ab678bb86** merges trunk 097e1ef68 (the Library P2/P3 catalog, save-back swap and Reverse). Read with `git show --remerge-diff`. It resolves conflicts in eight files and adds the guard plumbing to new trunk call sites.
- **760e64697** adds a refusal counter to `PerformanceRecorderIdle` and makes the Tracks view's recorder listener fire for refused idle states. 5 files, +105/−10.

P11 changes nothing under `packages/segno_engine` or `firmware` relative to trunk 097e1ef68, so I did not run its native suites separately. The P2 review's three native runs cover trunk's engine plus P2.

**Runs:**

| Suite | Result |
| --- | --- |
| `operation_guards` | 71/71 |
| `performance_repository` | 135/135 |
| `session_repository` | 192/192 |
| `wav_codec` | 7/7 |
| App suite with `SEGNO_ENGINE_LIB` | 3478 passed, 56 skipped, 1 failed: `midi_persistence_test.dart`, a timing flake. It also fails on the P2 branch under parallel load, and passes 6/6 idle on trunk, P2 and P11 alike. |
| App suite without the library | 3333 passed, 202 skipped |
| `dart analyze --fatal-infos lib test packages/operation_guards packages/performance_repository packages/session_repository` | no issues |
| `bloc lint lib test packages` | 0 issues in 884 files |

**Mutations: 4 tried, all killed.**

1. `refusal` removed from `Idle.props`.
2. The listener's `Idle` clause removed.
3. The low-disk refusal emitted without advancing the counter.
4. The listener firing only for `refusedBy` and not for `lowDiskBlocked`.

### Earlier findings

| # | Now |
| --- | --- |
| Delta 1, Low-Medium: a second refused press is silent | **Fixed.** `_refusals` is advanced on every refused arm, for both the guard refusal and the free-space refusal, and `refusal` is in `props`, so equal states can no longer be dropped. The cubit test now records the emitted states: toggle and then the pedal's direct `arm()` give `refusal: 1` and `refusal: 2`, and two low-disk presses give two states. That closes the earlier "asserts the unchanged state" gap. |
| Delta 2, Low: the Library plan does not name New loop's guard | Not in this delta; still open in the plan. |

### Verified correct (traced)

1. **The low-disk toast was unreachable, and is now reachable.**
   - **The claim:** the listener's `Idle` clause was removed by #681 (32f19634e, which dropped the recover-prompt clause). Since then `listenWhen` let through only `Rendering` and `Completed` entries, so `onPerformanceRecorderState`'s `lowDiskBlocked` branch (`tracks_commands.dart:446`) never ran in the app. On trunk, nothing else calls `onPerformanceRecorderState` (`git grep`).
   - **Confirmed** from the history and the trunk source.
   - **Now:** `listenWhen` adds `current is Idle && (lowDiskBlocked || refusedBy != null)`. Each refusal is a distinct state, so every press fires.
   - **Tested:** the widget test drives refusal 1, 2 and then a low-disk refusal 3, and finds each toast. The mutations confirm it.
2. **No spurious toasts.** Every other `Idle` emission (`recovering: true`, the plain `Idle()` after recovery) has neither flag set. `BlocListener` never fires for the initial state, so remounting the Tracks view cannot replay an old refusal.
3. **The merge keeps the guard at the commit of the new save-back swap.** In `SessionRepository.save`:
   - `sessionWrite` is entered after `_capture` and before `_saveCaptured`, which creates the stage or the new bundle;
   - it is released in `finally` after the swap.

   So a refusal touches no file, and the guard covers write and swap together. The other conflicts are additive:
   - `App`/`SessionCubit` lose trunk's removed `exportDirectory` and keep `guards`;
   - `SessionError` keeps `busy` beside trunk's `saveFailed`, `currentSessionProtected` and `folderNotEmpty`;
   - test call sites gain `guards: GuardRegistry()`.
4. **The merge also adds `LibraryFailure.busy`** (`library_page.dart:187-243`). That is a new line on the Library page that names the blocking operation through `operationBusy`. The switch over `SessionError` is exhaustive, so the mapping was required for the merge to compile.

### New findings

#### 1. Low: the Library page's new busy line has no test

- **Where:** `lib/library/view/library_page.dart:210` (`SessionError.busy => LibraryFailure.busy`) and `:243`, added in the merge commit rather than in either parent. `git grep 'LibraryFailure.busy' test` finds nothing.
- **Risk:** a later edit could map `busy` to `actionFailed` ("action failed") with no test failing.
- **Fix:** one widget test. A Library rename or duplicate refused by a held `sessionWrite` should show the line with `operationBusy('sessionWrite')`.

### Notes

- **Two messages for one refusal (pre-existing pattern, not this delta's).** A refused Library save now shows both the Library line and the Tracks SnackBar (`showSessionOutcome` maps `busy` too). That is the same double surface trunk already uses for `saveFailed`, `currentSessionProtected` and `folderNotEmpty`. The popup-severity rule ("never two bars for one cause") argues for suppressing the SnackBar while the Library is the visible surface. That belongs to the Library work, not here.
- **Silent refusals in non-idle states (unchanged and acceptable).** A refusal that arrives while the recorder is `Idle(recovering: true)`, `Finalizing` or `Rendering` is still not shown. The button is already disabled in those states, and the pedal's direct call is the only way in. The earlier review noted it.

**Verdict:** Approve. The repeat-refusal finding is fixed and pinned by tests that kill all four mutations. The low-disk toast is reachable again for the first time since #681. The trunk merge keeps the guard at the commit of the new save-back swap. The one new finding is a missing test.
