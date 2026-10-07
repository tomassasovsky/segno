Model: Claude Opus (subagent), in-session

# Review of PR #1271 (claude/foot-surfaces-1229-p3 at e708584a2): the Custom face, Stop recording while armed, and one notice for refused assignments

## Scope

- **The commit:** `e708584a2`, a single commit on the trunk `c4b5cf909`. It touches 17 files, +1922/−11.
- **What it adds:**
  - `foot_custom.dart`, the projection;
  - `foot_custom_view.dart`, the face and its recording pill;
  - Custom contacts in `ControlCubit`;
  - `customLit`, published beside the LED frame;
  - the `assignedActionFailure` notice, routed through `_runAction`, with the Custom early-return path and the MIDI unknown-key path;
  - `PerformancePedal` gains `titleMuted` and `titleMaxLines`;
  - the face branch and listener in `tracks_view.dart`;
  - tests and two goldens.
- **Plan:** Part 3 of the foot surfaces plan at `ff4cf38ec`: §3 rules 2 and 3, write-back W2, and L8 and L9.
- **Design:** pen `uEukr` and `E7kQV`, read through the pencil MCP without saving, plus note `MV9wz`.
- **Rules:** AGENTS.md and the owner rules.

## Runs

The runs used a scratch worktree at `e708584a2`, `SEGNO_ENGINE_LIB` from `build_test_lib.sh`, and a separate TMPDIR. Every run was bounded.

- **`test/control`:** +956, all passed.
- **`test/looper`, `test/screenshots`, `test/app`, `test/fuzz`, `test/performance`:** +1535 ~56, all passed.
- **`dart analyze --fatal-infos lib test packages`:** no issues.
- **`bloc lint lib test packages`:** 0 issues.
- **Mutations:** run against `foot_custom_dispatch_test`, `foot_custom_projection_test`, `foot_custom_view_test` and `tracks_view_test`. Each was reverted, and all four were killed.

| Mutation | Result |
|---|---|
| Reverse no longer excluded from the generic notice | killed: "a refused assignment says so once … from a Custom switch" |
| A Custom `UnavailableAction` stays silent | killed: "an on-screen press on an assignment this build cannot run says so" |
| `customLit` not published | killed: "the face and the switch LEDs read one published value" |
| "Stop recording" caption removed | killed |

## Verified correct (traced)

- **`customLit` comes from the LED map.**
  - `_pushProjected` computes `_physicalCustomStates` once, publishes it as `ControlState.customLit` only when it changes (`super.emit`, which avoids a second push), and passes the same map to `projectFrame`.
  - `projectFootCustom` reads `customLit[button]`, so the face and the plate cannot disagree (L8).
  - The map is empty outside Custom.
- **"Stop recording".**
  - A switch whose Press or Hold is `recordPerformance` reads `Stop recording` while `PerformanceRecorderArmed`, and is lit, because `_customActionIsActive` lights it while `_performanceArmed`.
  - The recording golden matches `E7kQV`: Stop reads `Stop recording`, lit, with no hint.
- **Enabled versus dimmed (§3 rule 2, W2).**
  - Only an unassigned switch is disabled.
  - An assignment that cannot run stays enabled, with its title muted (`titleMuted`), and its press gives the notice on screen and by foot.
  - A Hold-only switch is enabled; its tap does nothing, which is correct, because it is not a refusal.
  - So Record/Play (Hold · Peel) and Undo (Hold · Redo) are drawn active where `uEukr` dims them. That is the planned departure, write-back W2. Stop, which is unassigned, is dimmed as the pen draws it.
- **One notice across Custom, CTRL and MIDI.**
  - `_runAction` now wraps every assigned dispatch: `_fireCustomAction`, `_fireExternal` and the MIDI `MidiActionRun`. It reports once through `_reportAssignedAction`, which is session-scoped and silent when closed.
  - The Custom `UnavailableAction` early return (`:2553`) reports itself and never reaches `_runAction`, so there is no double report (L9).
  - An unknown MIDI key reports as `UnavailableAction(key)`.
  - The listener in `tracks_view.dart` is not gated on the mode.
- **No double toasts with Fade, Reverse or Peel.**
  - `_hasOwnRefusalNotice` excludes them.
  - Their reporters on the trunk fire from any mode: `_reportAssignedRefusal` for Fade and Reverse, and `_reportPeelRefusal` for Peel.
  - A test asserts exactly one counter moves per action, and the mutation that drops Reverse from the exclusion is caught.
- **MODE and Bank.** MODE exits to Record on contact, as the trunk's Custom route already did. Bank pages.

## Findings

### M1. Medium: an assigned Record/Play that the repository refuses with its own notice gets a second toast

- **Where:** `control_cubit.dart` `_runAction` reports every `false` except Fade, Reverse, Peel and `recordPerformance`. `TrackPedalAction` and `CommandAction(recordPlay)` reach `_recAdvance` → `_recordAccepted` → `LooperRepository.record`, which raises its own notices before returning a refusal:
  - `recordingInputRequired` (`looper_repository.dart:3013-3015`, shown by `app.dart` `_showRecordingInputRequired` as "Recording needs an input");
  - `_mixFailure` (`:3001-3002`, into `_mixSettingsFailures`).
- **Scenario:**
  1. Sound-start recording is on, and Track 2 is empty with no usable input routed.
  2. The player stomps a Custom switch assigned `Record / Play · Track 2`, or a CTRL or MIDI control with that action.
  3. Two toasts appear for one cause: "Recording needs an input" from the repository, and "Record / Play · Track 2 is unavailable right now."
- **Why it matters:** this breaks the plan's "one cause, one notice" (§3, D10). It is the double-toast case the review brief asked about, through a reporter other than Fade, Reverse and Peel.
- **Fix:**
  - Treat repository-reported record refusals as owned. For example, have the dispatcher see a refusal reason (`EngineResult.invalid` after `recordingInputRequired`, or `notReady` from a mix failure) and skip the generic notice. Or route the record actions' refusals entirely through the repository's notices.
  - Add a test: an assigned Record/Play on an input-less empty track gives exactly one toast.

### M2. Medium: an assigned Record performance that the engine refuses is silent, despite the test's name

- **Where:** `_hasOwnRefusalNotice` excludes `CommandAction(recordPerformance)` with the comment "a refused performance arm has its own toast".
- **What the code does:**
  - `_togglePerformanceRecordAccepted` calls `PerformanceRepository.arm` directly.
  - Only a guard refusal is published (`armRefusals`, `performance_repository.dart:396-400`, which the recorder cubit turns into a notice).
  - An engine `perfArm` failure returns the non-OK result and publishes nothing (`:402-407`).
  - The low-disk toast belongs to the recorder cubit's own `toggleArm` (`performance_recorder_cubit.dart:312-316`), which the assigned path never calls.
- **The test:** "a refused performance arm keeps its own toast" (`foot_custom_dispatch_test.dart:523-540`) sets `perfArmResult = invalid` and asserts only that the generic notice is absent. Nothing asserts that any toast appears, and none does.
- **Scenario:** Custom Stop is assigned Record performance. The engine refuses the arm (an I/O failure, for example). The switch stays dark and nothing says why. That breaks rule 3: an assigned-action refusal always gets a notice.
- **Fix:**
  - Either narrow the exclusion to the refusals that really have a notice (a guard refusal), and let an engine refusal take the generic notice;
  - or publish engine arm failures from the repository so the recorder's toast covers every caller.
  - Make the test assert the toast it names.

### L1. Low: an unavailable action shows its raw saved key on the stage

- **Where:** the face titles an `UnavailableAction` with `actionUnavailable(key)` (`Unavailable · {key}`), and its hint uses the same form.
- **In the golden:** `Unavailable · instrument:transpose` wraps mid-token, as `in` / `strument:tran…`, and the hints read `Hold · Unavailable · tuner` and `Hold · Unavailable · instrument:speed`. The notice also names the raw key ("tuner is unavailable right now.").
- **Context:** these are saved keys from another build, so this is rare. But at stage distance, a broken identifier is the worst form of the caption.
- **Fix:** title an unavailable assignment `Unavailable`, with the caption muted, and put the key in semantics. Or humanise known future keys (`tuner` → `Tuner`), as the pen draws them (`Transpose`, `Hold · Tuner`, `Hold · Speed`).

### L2. Low: two-line catalogue labels start the second line with the separator

- **Where:** the full catalogue labels on two lines are an accepted departure from the pen's one-word captions (`Mute`, `Fade`, `Mixer`).
- **The problem:** the wrap breaks at the space before the separator, so line 2 starts with it: `Selected track` / `· Mute` and `Selected track` / `· Fade` in the golden.
- **Fix:** use a non-breaking space before ` · `, or break after the dot, so a wrapped caption reads `Selected track ·` / `Mute`.

## Notes

- **The recording pill (departure).** The face draws its own pill (`foot_custom_recording`: a red square and `01:23`) in its header, beside Settings. `E7kQV` draws the timer in the stage top bar. The pill reads the same `PerformanceRecorderArmed` elapsed time and carries the `perfArmedElapsed` semantics. That is an acceptable departure for a face with no `StageTopBar`, to be noted in write-back W2 or W6.
- **Two sources for "armed".** "Stop recording" uses `PerformanceRecorderCubit` (`Armed`), while the switch LED uses the repository's `_performanceArmed`. They can differ for a frame around arm or disarm. That is harmless, but a single source would remove the window.
- **Notes outside the face.** The generic notice now also covers Undo or Redo with nothing to undo, Clear on an empty rig, and Cut sound, from any assigned control. That is consistent with rule 3 ("refused for any reason"), but the owner may find "Undo is unavailable right now." on an empty history noisy. It is worth a sentence in the PR.

Verdict: Request changes (M1, M2).

## Delta review (3d89de67f)

PARTIAL - stopped for cloud migration

### Scope

- The branch was rebased onto the trunk `787d51db6`.
  - `git range-diff` reports `e708584a2 = 7d42472c5`: the original commit is unchanged.
  - The fix commit `3d89de67f` changes 14 files, +315/−66.

### Runs

- **Tests at `3d89de67f`:** `test/control`, `test/looper`, `test/performance` and `test/app` gave +2375 ~6, all passed.
- **`packages/looper_repository`:** +827, passed.
- **`dart analyze --fatal-infos`:** clean.
- **`bloc lint`:** 0 issues.
- **Mutations:** run against `foot_custom_dispatch_test` and `tracks_view_test`. Each was reverted.

| Mutation | Result |
|---|---|
| (a) The generic notice ignores the notice mark | killed, but only by the low-disk test |
| (b) `_refusalNotices++` removed for `recordingInputRequired` (`looper_repository.dart:3062`) | **survives** |
| (c) The mix-failure counter removed | inconclusive: my sed hit `:640` instead of `:637`, so this run proves nothing |
| (d) The low-disk gate removed | killed |

### Verified so far

- **M1 mechanism.**
  - Two things count announced refusals:
    - `LooperRepository.refusalNotices` is bumped at its four announce sites: mix failure `:637`, overdub refusal `:2999`, input required `:3062` and record retry `:7542`.
    - `_ownNotices` counts the cubit's own announcements.
  - `_runAction` samples the mark before dispatch and skips the generic notice when it moved.
  - **Races.** The record actions (`TrackPedalAction`, `recordPlay`) dispatch synchronously, so nothing can interleave between the before and after samples.
    - A later retry refusal fires after the press was already accepted, so it cannot double.
  - **The one interleaving window is in `_assignedPerformanceToggle`.** It awaits the free-space probe. A second, concurrent assigned Record performance that hits low disk bumps `_ownNotices` during that await. The first press's later engine refusal then sees a moved mark and is silenced, which is a missed notice. This needs two Record performance controls within milliseconds, so it is Low. A fix is a per-call token, or comparing a mark scoped to this call.
- **M2.**
  - An engine arm refusal now gets the generic notice, because the exclusion is gone.
  - A guard refusal still returns OK from the repository and is announced by the recorder cubit's `armRefusals` listener: one notice.
  - Low disk is refused up front with `perfLowDiskBlocked`.
  - The disarm double-press guard returns OK, so there is no spurious notice.
  - Widget tests assert that the toasts appear.
- **L1 is resolved.** The face reads "Unavailable action", and the notice reads "This control's action isn't available in this version. Reassign it." The raw key is never shown.
- **L2 is resolved.** `footCustomActionLabel` replaces ` · ` with NBSP + `· `, so a wrap reads `Selected track ·` / `Mute`.

### New findings so far

- **DL1. Low: the M1 counter for the input-required case is untested.** Mutation (b) survives, so nothing pins "an assigned Record/Play on an input-less empty track gives exactly one toast".
  - **Fix:** add that test.
- **DL2. Low: `ControlCubit` imports a cubit file and duplicates its low-disk check.**
  - `ControlCubit` now imports `performance/cubit/performance_recorder_cubit.dart` for `lowDiskThresholdBytes`. The class doc says "no cubit ever depends on another cubit".
  - `_volumeTooFullToArm` also duplicates the recorder cubit's own check, against rule 4 (consolidate).
  - **Fix:** move the low-disk gate, or at least the threshold, into `PerformanceRepository`, so both callers share it.
- **DL3. Low: format-only churn in `looper_repository.dart`.** About 8 hunks collapse trailing commas in code the fix does not touch: around `:1394`, `:3168`, `:4292`, `:7562`, `:7648`, `:7849`, `:7952` and `:8148`. The trunk file was already format-clean.
  - This is the "format without `pub get`" trap, and CLAUDE.md forbids format-only churn.
  - **Fix:** revert those hunks.
- **DL4. Low: the `_assignedPerformanceToggle` await window described under M1 above.**
- **Undo with nothing to undo.** The generic "Undo is unavailable right now." on an empty history follows rule 3. A player who stomps Undo on an empty history learns why nothing happened. I do not flag it as noise.

### Remaining

- Re-run mutation (c) at the correct line (`:637`).
- Check whether `_overdubRefusals` and `_recordRefusals` have visible listeners, so that a counted notice is really shown.
- Compare the new goldens.
- Write the final verdict.

Provisional verdict: Approve with Low follow-ups (DL1–DL4), pending the remaining checks.
