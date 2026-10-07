Model: Claude Opus (subagent), in-session

# Review of PR #1247 (claude/foot-surfaces-1229-p1 at 1dd9842ac): show a pending hold on the performance pedals

## Scope

- **The diff:** one commit, `1dd9842ac`, on trunk `097e1ef68`. It touches 11 files, +590/−3.
  - `_HoldGesture` gains an `onSettled` callback.
  - `_armGesture` gains a `cue` argument.
  - `ControlState` gains `pendingHolds` and `holdThreshold`.
  - `PerformancePedal` gains the bar and the hint brightening.
  - Two `SurfaceTheme` tokens are added.
  - The Mixer and Fade faces are wired to the cue.
- **Plan:** Part 1 of the foot surfaces plan at `da5c89bf9`.
- **Design:** pen `PRSrG`. `IBL3g` is a bar 159.16 x 3 at y 221, with track `#303b4b` and fill `#a8c7fa`. The hint brightens to `#d2e3ff`.
- **Rules:** AGENTS.md and the owner rules.

## Runs

- **App suite:** `flutter test` in a scratch worktree, with `SEGNO_ENGINE_LIB` from `build_test_lib.sh`.
  - Result: +3481 ~56 −3.
  - The three failures were time-outs in `count_in_session_shutdown_test.dart` (two cases) and `fx_chain_persistence_test.dart`. Five suites were running at once.
  - Re-run alone, those files pass: +93.
- **Mutations:** run against `pending_hold_test`, `performance_pedal_test`, `foot_mixer_view_test` and `foot_fade_view_test`. Each was reverted.

| Mutation | Result |
|---|---|
| `cancel()` no longer settles | killed (close test) |
| The timer path no longer settles before `onHold` | killed |
| `release()` no longer settles | killed |
| The Fade face passes `cue: null` | killed |
| Drop `!armed` in `_armGesture` | survives. It is equivalent: `_onPress` drops a second contact on a held button before arming. |
| Drop the `_closing \|\| isClosed` guard in `_setHoldPending` | survives. The guard is unreachable on tested paths, because `close` retires input first. It is harmless defence. |
| `forward(from: 0)` → `forward()` | survives. It is equivalent, because a settled hold resets the value to 0. |

- **Probe:** a temporary test in the P1 rig, removed afterwards. In Record mode it pressed and released track 1, then Rec/Play, through `FakePedalLink`, and counted `ControlState` emits.
  - With the cue: 1 emit on each press and 1 on each release.
  - With `_setHoldPending` disabled: 0 and 0.

## Verified correct (traced)

- **The settle edges are exactly the pending edges.**
  - `_settle()` runs once, before `onHold`, on `release`, and on `cancel`, including the `!stillValid` timer branch.
  - `_onSettled` is nulled after use, so a release after a fired hold is a no-op.
  - The cue is published only when `press` actually armed: the `armed`/`_active` check.
- **Every arm site is covered.**
  - Each pedal arm site passes its own button: Custom, bound hold, Undo, Stop restore, MODE, Bank, Rec/Play hold, track hold, Mixer and Fade.
  - The CTRL jacks pass `null`.
  - No button can hold two pending gestures at once. Holds exist only on track buttons for bindings (`holdable`), and the Record-mode track hold runs only in Record mode.
- **Retirement.** Mode change (`_invalidateGestures`), session change (`_cancelSurfaceHolds`), `takeLocked` releases (`cancel`) and close all retire the cue. A disconnected pedal at worst lets the timer settle the cue at the threshold, so nothing sticks.
- **No reflow.** The slot is 5 + 3 + 8 px, the same 16 px that already sat between face and caption. The existing Mixer, Fade and Reverse goldens are unchanged, and the full suite ran them.
- **Timing.** The bar is timed by the widget's own `AnimationController` against `holdThreshold`. The state publishes only a set, so a wall-clock step cannot move the bar.
- **High-contrast flavour.** It has its own pair of tokens.
- **Pending Hold copy.** The hint brightening follows `PRSrG`: `#aebdd2` goes to `#d2e3ff`.

## Findings

### M1. Medium: the cue costs a full Tracks rebuild on every stomp in Record and Mute, where it is never drawn

- **Where:**
  - `control_cubit.dart:2729` and `:2733-2745` emit on every arm and every settle, in every mode.
  - `tracks_view.dart:92` rebuilds the whole TracksView on any `ControlState` change (`context.watch<ControlCubit>().state`).
  - `app.dart:1196` also runs `_updateDisplayContext` on every `ControlState` emit.
- **Scenario:**
  - In Record mode with the default pedal setup, every press of a track switch, Rec/Play, MODE, Bank or Undo arms a hold. The defaults are `trackHold.armOverdub`, `recordHold.undoRecording`, `modeHold.custom`, and Undo and Bank always arm.
  - The probe measures 1 extra `ControlState` emit per press and 1 per release, against 0 and 0 without the cue.
  - The release emit lands in a frame of its own, so each stomp now costs one full TracksView build on the Pi.
  - `tracks_view.dart:96-102` records what that build costs: 10.98 ms p50 against a 16.7 ms frame (#638).
  - Owner decision O1 says Tracks and Mute draw no cue, so this work buys nothing on the main performance screen.
- **Fix:** do either of the following, and pin it with a test that a Record-mode track press and release emit no `ControlState`.
  - **Gate the publication on the mode.** Call `_setHoldPending` only when `state.mode` draws pedals: mixer, fade, reverse, fx, custom, and later tuner and peel.
  - **Or move `pendingHolds` out of the state TracksView watches.** For example, use a separate `ValueListenable<Set<PedalButton>>` on the cubit that the faces select.

### L1. Low: the bar's track colour departs from the pen

- **Where:** `_HoldProgress` uses `surface.controlStrong` for the track. That is `#3A3A40` in the dark theme (`surface_theme.dart:505`).
- **The pen:** the `IBL3g` track is `#303b4b`, a blue-grey.
- **Width:** the bar is 156 px, matching the app's face width rather than the pen's 159. That part is fine, but neither departure is recorded.
- **Fix:** either add a `holdTrack` token at `#303b4b`, or add the departure to write-back W1.

### L2. Low: the `_closing || isClosed` guard is untested

- **Where:** `control_cubit.dart:2735`.
- **The gap:** the mutation that removes the guard survives, because `close()` retires input and cancels gestures while the cubit is still open.
- **Fix:** if the guard is meant as defence, add a test that cancels a gesture after `close()`. For example, call `_cancelSurfaceHolds` from a late session-change event, or close while a hold is pending and then fire the timer. Otherwise say in the comment that it is unreachable.

## Notes

- The plan's §9 still says Part 1 regenerates goldens. The build record is right that none move. This is plan finding DL1 in the plan review.
- Semantics do not announce the pending hold. The pen draws no text for it, so this is acceptable. A screen-reader user gets the hold result, not the progress.

Verdict: Request changes (M1). The cue itself is correct and well tested.

## Delta review (c390b19f5)

### Scope

- `1dd9842ac..c390b19f5`, two commits.
  - `ffa51848c` adds the mode gate, the `holdTrack` token, documents the guard and adds tests.
  - `c390b19f5` fixes spelling.
- Five files.

### Runs

- `test/control`, `test/looper/view` and `test/theme` at `c390b19f5`: +1397, all passed.
- **Mutation:** removing the gate (`_cueModes.contains(state.mode)` replaced by `true`) is killed by the new test "a record-mode stomp publishes no cue".
- **Merge check:** `git merge-tree` against the current trunk `890f04936` conflicts in `control_cubit.dart` and `control_state.dart` (Peel P3 and P2's neighbours have landed). The PR needs a rebase.

### Earlier findings, re-checked

- **M1: resolved.**
  - `_setHoldPending(cue, true)` now runs only when `state.mode` is mixer, fade, reverse, fx or custom.
  - Clearing still runs in every mode, so a hold armed on a face that settles after a mode change leaves the set empty.
  - The new tests press and release Undo and Bank in Record and in Mute, and assert that no published state ever has a pending hold. With the publication gated, a Record-mode stomp emits no `ControlState`, because the clear is a no-op for an absent button, so the Tracks screen no longer rebuilds for it.
- **L1: resolved.**
  - `holdTrack` is `#303B4B`, matching pen `IBL3g` (`#4A586C` in high contrast). It is wired through the constructor, `copyWith` and `lerp`.
  - A widget test pins the two `ColoredBox` colours.
- **L2: documented rather than tested. I accept this.**
  - The guard is one line that stops an emit into a closed cubit, which would throw `StateError`.
  - No current path reaches it, because `close()` retires input first and that settles every gesture while the cubit is open.
  - Testing it would need a test-only hook to settle a gesture after close. That is more machinery than the risk warrants.
  - The comment now says plainly that it is a defence. This also follows the owner rule to fail safe.

### On the rebase

- When it rebases onto the trunk, the PR must:
  - give the trunk's newer `_armGesture` sites a `cue` (the required parameter makes the compiler enforce this; `control_foot_fade.dart` now has two sites);
  - wire `holdPending` into P2's `foot_fx_view.dart` if P2 lands first.
- **Peel:** Peel has no hold sites on the trunk today. If the Peel face gains holds, it joins `_cueModes`.

### Delta verdict

Approve, after a clean rebase onto the trunk.
