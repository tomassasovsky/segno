Model: Claude Opus (subagent), in-session

# Review of PR #1260 (claude/foot-surfaces-1229-p2 at df21c639c): the FX pedal-map face, Toggle and Hold per pedal, and Track FX off/on

## Scope

- **The commit:** `df21c639c`, a single commit on the current trunk `890f04936`.
- **Plan:** Part 2 of the foot surfaces plan at `ff4cf38ec`, including:
  - D1;
  - D3 and O3 (the panic dropped; `Track FX off` and `Track FX on` added);
  - D13 (MODE as Exit);
  - the one-time notice;
  - write-back W3.
- **Design:** pen 10/03 `noDGu`, read through the pencil MCP without saving, and its held state `ri60q` from the earlier reads.
- **Rules:** AGENTS.md and the owner rules.

## Diff integrity (the accidental-revert check)

- **Base:** `git merge-base HEAD origin/claude/segno-integration` is `890f04936`, the trunk head itself. The branch is one commit on top of the trunk, so no trunk commit can be reverted outside this diff.
- **Size:** `git diff --stat 890f04936..df21c639c` shows exactly 28 files, +1631/−1258.
- **Every file is accounted for.** I read each file's diff:

| Files | What changed |
|---|---|
| `app_en.arb`, `app_es.arb` | Removes only the twelve #692 re-dress strings (`stageFx*`, `a11yTrackTileFxOn/Off`) and adds the ten new `footFx*` and `actionTrackFx*` strings. The `bluetoothRetiredNotice` line in `es` changes only by its trailing comma. |
| `track_column.dart` (−515) | Removes only the FX dressing: `fxTarget`, `inputNames`, `_FxChainDressing`, `_FxNoChain`, `_FxCellIdentity`, `_FxPowerPill`, `_FxEntryRun`, `_stageFxTargetLabel` and the 40 % meter recede. |
| `wave_track_row.dart`, `interaction_mode.dart` | The FX arms and their comments only. |
| `tracks_view.dart`, `tracks_view_test.dart` | The face branch and the FX listener, plus the removed tests and golden. |
| `control_action.dart`, `control_action_labels.dart`, `app_toasts.dart`, `app.dart`, `settings_repository.dart` and its test | The two commands and the notice. |
| `control_projection.dart`, `control_cubit.dart`, `control_state.dart`, `foot_fx.dart`, `foot_fx_view.dart` | The face, the dispatch changes and the published switch readings. |
| `control_cubit_test.dart`, `control_action_test.dart`, `external_dispatch_test.dart`, `control_sequence_fuzz_test.dart`, `foot_fx_view_test.dart`, `tracks_screenshots_test.dart` | Tests. |
| Goldens | Three added (`foot_fx_default`, `foot_fx_held`, `foot_fx_spanish`); `tracks_fx_window` removed. |

Nothing outside Part 2's scope moves.

## Runs

The runs used a scratch worktree at `df21c639c`, `SEGNO_ENGINE_LIB` from `build_test_lib.sh`, and a separate TMPDIR.

- **App suite, in three bounded runs:**

| Run | Result |
|---|---|
| `test/control` | +942, all passed |
| `test/looper`, `test/visualizer`, `test/fuzz`, `test/app`, `test/screenshots` | +1488 ~56, all passed |
| The remaining 17 test directories | +1034, all passed |

  - Total: 3464 passed, 56 skipped, 0 failed.
  - A first unbounded full run stalled after 22 minutes with runner errors ("Cannot close sink while adding stream") and 30-second time-outs. I killed it, and the bounded runs above replace it.
- **`packages/settings_repository`:** +204, passed.
- **`dart analyze --fatal-infos lib test packages`:** no issues.
- **`bloc lint lib test packages`:** 0 issues, exit 0.
- **Mutations:** run against `control_cubit_test`, `foot_fx_view_test` and `external_dispatch_test`. Each was reverted, and all four were killed.

| Mutation | Result |
|---|---|
| The FX MODE Exit is removed from `_onPress` | killed: "MODE exits on contact despite an attempted remap" |
| A stale binding gives no notice | killed |
| `footFxCancelled` keeps a held momentary | killed |
| Bound Rec/Play, Stop, Undo and Clear LEDs go dark | killed |

## Verified correct (traced)

- **Every bindable switch is projected.** That is Rec/Play, Stop, Undo, Clear and the four track switches; only MODE and Bank are unbindable.
  - The face (`foot_fx.dart` `_project`) and the LEDs read one published map, `ControlState.fxSwitches`. `_pushProjected` computes it beside the frame and emits only on change, so the screen and the plate cannot disagree.
  - The track LEDs still go through `boundChains`.
  - A stale binding stays enabled, reads "Target missing", and its press, on screen or by foot, gives `footFxUnavailable` once.
  - A refused write gives `footFxFailure`.
  - Both are mode-gated to FX and dismissed with the view.
- **The panic is gone everywhere.** That covers `_armStop`, `_armStopRestore`, the public `panicTrackChains`/`restoreAllTrackChains`, the FX arm of `stop()` and the bound-Stop restore hold.
  - `_sweepTrackChains` remains as the body of `ControlCommand.trackFxOff` and `trackFxOn`, members of `ControlActionGroup.fx` with en and es labels.
  - An unbound Stop is inert and dark in FX.
- **MODE in FX exits on contact** to `_fxReturn`, from the foot and from the header back button (`activateFootFxPedal(mode)`). That is D13, and it matches `noDGu`, where MODE reads `Exit`, lit.
- **The one-time notice.**
  - It is latched in memory at the first FX entry and persisted to `fx.stop_change_notice_shown`.
  - `_fxStopNoticeShown` defaults to `true` until `load()`, so a pre-load FX entry says nothing.
  - The listener fires on the false→true edge only.
- **Cancelled contacts.** An on-screen cancelled contact runs `_releaseBinding`, so a momentary cannot be stranded on (B1).
- **Pen 10/03.** The default golden and `noDGu` match on structure:
  - unbound Rec/Play, Stop, Undo and Clear are drawn at the disabled opacity;
  - Exit is lit;
  - Bank reads `Bank A` / `Switch bank` with no hint;
  - the track switches have their titles and `Toggle`/`Hold` lines;
  - the dark stage has no purple surface (pen fill `#111215`);
  - the held golden matches `ri60q`'s brightened Hold line.
- **The recorded departure.** The third line, the stage label (`Input 1`), is visible in the app but not drawn in the pen. It is recorded for write-back W3.

## Findings

### M1. Medium: the FX face rebuilds every pedal on every poll tick while audio plays

- **Where:** `foot_fx_view.dart:30` has `final looper = context.watch<LooperBloc>().state;`, and `projectFootFx` runs inside `build`.
- **Precedent:** every other face subscribes through `context.select` to an Equatable projection:
  - `foot_fade_view.dart:67`;
  - `foot_mixer_view.dart:49`;
  - `foot_reverse_view.dart:29`;
  - `foot_peel_view.dart:36`.
- **Why it matters:** `LooperState` carries per-track peaks and positions, so it changes on every poll tick. `tracks_view.dart:96-102` records what a whole-surface rebuild per tick cost on the Pi (#638: 10.98 ms p50 against a 16.7 ms frame), and why the stage stopped watching `LooperBloc`.
- **Scenario:** in FX mode with loops playing, all ten `PerformancePedal`s and their `TracksCubit` and `LooperRepository` lookups rebuild every tick. That is the surface a performer uses mid-song.
- **Fix:** select an Equatable projection (`FootFxPedal` is already Equatable; wrap the map), for example:
  `context.select<LooperBloc, _FxFaceTracks>((b) => _FxFaceTracks.of(b.state))`, holding only `effects` and `chainEnabled` per channel.
- **Test:** pump a peak-only `LooperState` change and assert the face does not rebuild, with a build counter in the test as the Mixer tests do.

### M2. Medium: pedal titles name the first effect's type, not the rack the pen draws

- **Where:** `foot_fx_view.dart`:
  - `_targetName` returns `fxBlockName(l10n, entries.first)` for a chain target;
  - the unbound track switch uses `fxBlockName(l10n, effects.first)`.
- **What `fxBlockName` returns:** the effect type label (`Reverb`, `Wah`) or a plugin name (`fx_block_chip.dart:9-16`).
- **What the pen draws:** pen 10/03 titles the pedals `Light FX 1`, `Funk Wah` and `Ballad`. These are rack names: pen 04 `WmJsF` lists the same racks as A2–A4. The model has them, as `TrackEffect.rack?.name` (`FxRack`, `track_effect.dart:80-110`, "named groups of pedals the player adds, renames…").
- **Scenario:**
  1. The player loads the `Funk Wah` rack (envelope filter, then drive) on Input 1 and binds pedal 3 to that chain.
  2. The face reads `Filter` with the hint `Input 1`, not `Funk Wah`.
  3. A chain of two racks reads as only its first effect.
- **Fix:**
  - Title with `rack.name` when the entries the target reaches belong to one rack.
  - Use `fxBlockName` for a standalone effect or a slot target.
  - Use the slot name (`footFxSlot`, which the pen uses for pedal 1, `FX A1`) when a chain spans several racks.
- **Test:** a rack-named chain.

### L1. Low: the Stop-change notice also shows on fresh installs

- **Where:** `_fxStopNoticeShown` is false whenever the flag is unset, so a console set up today is told that "Stop no longer switches every track's effects off" about a behaviour it never had.
- **Fix:** seed the flag as shown on a first boot (no stored pedal setup or bindings), or accept it and record that in the plan.

### L2. Low: keyboard 1–8 in FX still toggle the column's own track chain

- **Where:** `tracks_commands.dart:316-321`.
- **The mismatch:** the face now says pedal 1 drives, for example, `Reverb / Input 1`, while key `1` toggles track 1's Track-stage chain. The earlier-application shortcut copy (`FfZQI`, in `02 EARLIER APPLICATION`) read "in FX mode, toggle the FX chain bound to that key".
- **Status:** this predates P2, but the new face makes the mismatch visible.
- **Fix:** route digits 1–4 through `activateFootFxPedal(track N)` for the current bank, or file a follow-up issue.

### L3. Low: D13 drops the configured MODE pair in FX without a word

- **The change:** on the trunk, a MODE press in FX ran the configured pair (default: Mute on press, Custom on hold). Now it is Exit only, so a player who held MODE in FX to reach Custom loses that shortcut.
- **Status:** this is the pen and accepted §4.
- **Fix:** the one-time notice text could mention it in one clause (rule 3).

## Notes

- **Accessible activation of a momentary binding is a silent no-op,** as documented, because a semantic activation has no contact to hold. Momentary bindings are therefore unusable from a screen reader. Consider making the semantic long-press act as press-and-hold until a second activation; acceptable as a follow-up.
- **The Pending Hold cue is not wired into this face,** as documented. PR #1247 currently conflicts with the trunk in `control_cubit.dart` and `control_state.dart` (merge-tree against `890f04936`). Whichever lands second must pass `holdPending` in `foot_fx_view.dart` and add the new `_armGesture` sites.

Verdict: Request changes (M1, M2). The dispatch, the commands, the notice, D13 and the removal of the re-dress are correct and well tested.

## Delta review (13ed4750a)

### Scope

- The branch was rebased onto the trunk `c4b5cf909`.
  - `git range-diff` reports `df21c639c = 2a2e96c85`: the reviewed commit is unchanged.
  - `c4b5cf909..2a2e96c85` is still exactly 28 files, +1631/−1258.
- The fix commit `13ed4750a` changes 16 files, +462/−80.
- Every file in the delta is Part 2's own: `app.dart`, `control_action_labels.dart`, `control_cubit.dart`, `foot_fx.dart`, the en and es arb files, `foot_fx_view.dart`, `tracks_commands.dart`, tests and three goldens. No trunk file outside Part 2 moves.

### Runs

- **Tests at `13ed4750a`:** `test/control`, `test/looper`, `test/screenshots` and `test/app` gave +2322 ~56, all passed.
- **Mutations:** run against `control_cubit_test`, `foot_fx_view_test`, `tracks_view_test` and `test/app`. Each was reverted, and all four were killed.

| Mutation | Result |
|---|---|
| Fresh-install detection disabled | killed: "a fresh install never hears about the old Stop, and stores that at its first FX entry" |
| A bindings save does not store the decision | killed: "… stores that at a bindings save" |
| Keys 1–8 ignore bindings | killed: "a number key runs its track switch binding in FX mode, bank B on 5 to 8" |
| Titles fall back to the effect type, not the rack | killed |

### Earlier findings, re-checked

- **M1: resolved.**
  - The face now selects an Equatable `FootFxProjection` from `LooperBloc` (`foot_fx_view.dart`).
  - The chain lookup is injected as `FxChainLookup chainAt` (`repository.chainEntriesAt`), so `projectFootFx` stays pure.
  - The projection holds `effects`, `targetEntries` and `holdEntries`. `TrackEffect`'s numeric fields are settings (`placement`, `level`, `params`), not meters, so a meter or playhead tick leaves it equal.
  - The new widget test "meter ticks do not redraw the pedals" pins this.
- **M2: resolved, and it matches pen 10/03.** `_chainName` reads:
  - the rack's name when every entry shares one rack;
  - the effect's name for a single standalone effect;
  - the pedal's slot (`FX A1`) for a track switch whose chain spans several racks;
  - the effect for a slot target.
  - The new default golden reads `FX A1` / Toggle, `Light FX 1` / Hold, `Funk Wah` / Hold and `Ballad` / Toggle. Those are exactly `noDGu`'s titles and lines. (`Ballad` is drawn lit in the golden and unlit in the pen. That is fixture state, not fidelity.)
- **L1: resolved within a stated limit. I accept it, with a note.**
  - An install with no stored pedal setup, no stored bindings and no retired boot default is treated as fresh. It is never told, and that decision is stored at its first FX entry or its first setup or bindings save.
  - **The limit:** an upgrading console that ran on defaults is classified as fresh and gets no notice. Defaults here means it never saved a pedal setup or bindings and never stored a boot default. Yet the old FX Stop panic needed no setup: FX mode was reachable by the `M` key or chip cycle, and its unbound Stop panicked.
  - **A second gap:** the retired boot default is read with `takeRetiredDefaultInteractionMode`, which consumes it. If the "always start in Record" change reaches a console in an earlier update than this one, that signal is already gone.
  - A more reliable "has been used" signal would be any session in the Library or any stored mixer or monitor setting.
  - The cost of a miss is one unseen info toast, and the release note still carries the change, so this is acceptable. I would add one sentence to plan §10 naming the limit.
- **L2: resolved.**
  - In FX, key N runs switch ((N−1) % 4) + 1 of bank (N−1) ÷ 4 through `activateFootFxPedal` when that switch is bound. `selectTrack` reveals the key's bank first, so the activation's `activeBank` lookup agrees.
  - An unbound switch still toggles its track's chain.
  - **Remaining gap (Low):** a key bound to a momentary is a silent no-op, because `activateFootFxPedal` treats a momentary as press-and-release. A key-down/key-up pair could hold it instead.
- **L3: resolved.**
  - The one-time toast now carries a second line naming the player's MODE assignment that still works elsewhere: `footFxModeChanged` or `footFxModeChangedHold`, built from `PedalSetup`.
  - The English is slightly stiff ("Its Mute and Hold · Custom still work in the other modes."), but it is accurate. Both strings are in en and es.

### Delta verdict

Approve. The only open points are the L1 limit note for the plan and the momentary-key gap; neither blocks the merge.
