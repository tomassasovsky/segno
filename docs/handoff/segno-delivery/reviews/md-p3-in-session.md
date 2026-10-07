Model: Claude Opus (subagent), in-session

# Review of origin/claude/multiply-divide-1168-p3 (ffd50cd95): feat(control): foot Multiply / Divide surface, mappings and notices

## Scope

- Head `ffd50cd95`, stacked on #1244 (`5eb8517d3`). It is:
  - `46f85bbb4`, the surface;
  - plus the merge of Part 2, which brings the beat grid, schema 14 and the trunk with Peel P3.
- This review covers `git diff 5eb8517d3 ffd50cd95`: 49 files, +2965/-43.
- Reviewed against:
  - the plan's section 3 and its Part 3 notes;
  - accepted behaviour section 4 (line 304), and the line 591 journey;
  - **pen section 16, "Performance · Multiply & Divide"** (node `fmAqg` in the main checkout's `segno-ui.pen`, 8 screens), read through the pencil MCP. I read every screen's pedal roles and captions and screenshotted 01 and 04;
  - the owner rules, and the popup-severity call (never two notices for one cause).

## Runs

All runs were made in a fresh worktree at `ffd50cd95`.

| Run | Result |
|---|---|
| `run_native_tests.sh`, 3 runs, separate TMPDIR each | ALL PASSED x3 |
| TSAN races binary | exit 0 |
| segno_engine | +389, all passed |
| looper_repository | +824, all passed, including `length_journey_native_test`, `length_history_refusal_test` and `length_native_test` |
| session_repository | +252, all passed |
| App suite, after `flutter gen-l10n` | +3499, ~56 skipped, all passed. The 4 new `foot_length_*` goldens pass. |
| `dart analyze --fatal-infos lib test packages` | No issues found |
| `bloc lint lib test packages` | 0 issues |

## Verified correct (traced)

- **Dispatch** (`control_foot_length.dart`).
  - Every role fires on contact.
  - Exit works even while editing is blocked.
  - The track pedals select only a recorded track, against the current bank. Bank pages without moving the cursor.
  - Edits act on the shared cursor, and an empty cursor track is silent.
  - `trackPressed` is inert in this mode.
  - `allowsAllTracks` excludes multiply, divide-first and divide-last.
  - Custom, CTRL and MIDI reach `_runAssignedLength` through `FootLengthActions.edit`, the same adapter the surface uses.
- **Refusals.**
  - The busy pre-check (capturing, layer in flight, pending, launch) runs before the engine is asked.
  - The engine's verdicts map one to one: NOT_READY → busy, MODE_MISMATCH → incompatible, CAPACITY → capacity, anything else → failed.
  - A refusal that lands after its surface visit or Session ended is dropped. An assigned edit always says why.
- **LED and frame.**
  - The LED is red on the selected recorded track and off otherwise.
  - Slot-less pedals follow accepted contacts.
  - `PedalMode.custom` is used for both the frame and its invariant.
- **Peel P3 merge.**
  - Every `InteractionMode.peel` arm in `lib/` has a matching `length` arm (12 files, equal counts).
  - The retired Pedal plate is gone.
  - Analyze and bloc lint are clean.
- **Undo-refusal counter.**
  - `a_length_history_refusals` (relaxed, written on the control thread only) counts:
    - a refusal at the tap;
    - a callback refusal of a posted Undo or Redo (in `le_length_collect`, op ≠ 0);
    - queued taps that stop at a length edit (once per drop).
  - It is published per track. The repository diffs it on every poll; the first read is the baseline, and a lower count is treated as a new engine.
  - The app shows one toast from any mode.
- **Loop lengths in beats.**
  - `loopCountWords` is the single reading (bars, else whole beats, else "—"). It is used by:
    - the stage meta row and its spoken form;
    - the track column;
    - the wave row;
    - the mixer strip;
    - the overview.
- **The visible "6 beats" change.** A 1.5-bar Free take (or any track whose length is a whole number of beats but not of bars at the tempo) now reads "6 beats" where it read "—". I judge this acceptable:
  - it is truthful at the unchanged tempo and consistent with the owner's beat decision;
  - it only applies within a frame of a whole beat, so ordinary free takes still read "—";
  - it should be written back to the pen with the rest.
- **Journey.** The line 591 journey (Record → overdubs → Divide → Peel → Undo/Redo) runs on the native engine. A Divide bakes the overdub passes into the kept half, so Peel refuses until Undo restores the length and its layers. That is consistent with Peel never crossing a LENGTH entry.

## Findings

### High

**H1. The surface does not follow pen section 16, which the build notes say does not exist.**

The Part 3 notes in the plan say "`segno-ui.pen` has no Multiply / Divide frame. The surface follows the Fade, Reverse and Peel layout." That is wrong. Section 16, "Performance · Multiply & Divide" ("Current study · proposal · 8 screens"), is in the main checkout's pen. Worktrees cannot see the untracked design files.

It answers the plan's own open question about the pedal assignment (Rec/Play as Double versus keeping it as transport) differently from what was built:

| | Pen 16 | Built (`foot_length.dart` `pedalRoles`, `foot_length_view.dart`) |
|---|---|---|
| Surfaces | Two: titlebar "Multiply" (01-02) and "Divide" (03-08) | One combined "Multiply / Divide" mode |
| REC/PLAY | "Record / Play · Track 1" on all 8 screens; the transport stays | Double |
| Multiply | CLEAR = "Double length · Repeat to 4 bars" (after the Double: "Repeat to 8 bars"); UNDO = "Undo · Nothing to undo / Length edit" | — |
| Divide | UNDO = "First half · Bar 1 / Beats 1–2 / Beats 1–6", with "Hold · Undo"; CLEAR = "Last half · Bar 2 / Beats 3–4 / Beats 7–12" | UNDO = First half, CLEAR = Last half, no hold; no Undo anywhere in the mode |
| Read-out | A "Selected track length" panel: track, length, segment cells, and an outcome line ("Speed and pitch unchanged", "Repeated to 4 bars", "First 1 bar kept") | An eight-track "Loop length" overview |
| Empty or recording track (07, 08) | Edit pedals captioned "Select a track" or "Finish recording", plus a status line ("No recorded audio in this bank", "Finish recording to change length") | Dimmed and silent |

Consequences:
- Rec/Play changes meaning inside this mode. The keyboard Rec/Play still records (control_cubit.dart:1592-1597, "this keyboard call keeps its record meaning"), so the screen key and the footswitch disagree.
- A mistaken Divide can only be undone by leaving the mode, whereas the pen keeps Undo one stomp (or one hold) away.

Suggested fix:
- Rebuild the surface to pen 16:
  - two surfaces (or one mode toggled between Multiply and Divide);
  - Rec/Play as transport;
  - Double on CLEAR in Multiply, with UNDO kept as Undo;
  - in Divide, First half on UNDO (hold for Undo) and Last half on CLEAR;
  - the selected-track panel, with outcome captions in bars or beats;
  - the 07 and 08 states.
- Or, if the owner prefers the built layout, record that as an explicit owner decision and write the departure back into the pen (geometry plus a `c/` note), per the "deviating updates the pen" rule. The write-back list in the plan currently assumes there is no frame to compare with.

### Medium

**M1. One Undo tap can raise two notices.**

Where:
- engine_commands.c `le_length_history` counts every synchronous refusal through `le_length_history_refused`;
- looper_repository.dart:1772 `_reportRecoveryResult` already turns the same NOT_READY or MODE_MISMATCH return into a `RecoveryRefusal`.

Scenario: a quantized Record arm is waiting on a track whose top entry is a length edit, and the player presses Undo.
1. `le_engine_history_mode_gate` passes: the LENGTH verdict ignores the track's own arm unless it is re-clocking.
2. `le_engine_undo` reaches `le_length_history`.
3. `le_length_busy` sees `armed[ch]` and returns NOT_READY, and also increments the counter.
4. The app then shows both `recoveryRefused` ("wait") and `lengthHistoryRefused` ("not undone or redone, try again") for one press.

The same happens for an Undo pressed within the block after a Stop (a pending state command) or a crown or mode change (a pending clock command).

This breaks the owner's "never two notices for one cause" call.

Suggested fix: count only what the caller cannot see:
- a callback refusal of an Undo or Redo that was posted with LE_OK;
- queued taps dropped at a length edit.

Remove the count from the synchronous refusal in `le_length_history`, and update `test_length_refused_history_motion` and `test_length_history_gate` to expect no count for a refusal returned directly.

### Low

**L1. Stale "bars" wording after the beat decision.**
- `footLengthIncompatible`: "That length does not fit the other loops or the bars." (and the Spanish "…ni con los compases").
- The `FootLengthRefusal.incompatible` doc: "would not keep whole bars".
- The `46f85bbb4` commit message names `le_reclock_whole_bars`.
- A sole loop is now refused only at a half-beat. Suggested wording: "…does not fit the other loops, or would leave half a beat."

**L2. `lengthHistoryRefused` always says "Try again."**
- When the cause is that the length no longer fits the rig (MODE_MISMATCH, at the tap or from the callback), a retry meets the same verdict until the rig changes.
- Name the cause, or drop "Try again" for that case.

## Notes

- **The beat display needs the pen write-back too:**
  - "2 beats" or "6 beats" on the stage;
  - the 4+2 click accent of a 6-beat 4/4 loop (see the P1 delta);
  - the Free-take "6 beats" reading.
- **Appliance evidence.** The physical footswitch, LED and listening proof (the last success criterion) is still outstanding, as the notes say.
- **Prerequisites.** P1 at `be963fd81` and P2 at `5eb8517d3` are approved and must land first. This branch already contains both.

## Verdict

Request changes. H1: build to pen section 16, or get the owner's explicit sign-off and write the departure back to the pen. M1: one notice per Undo.

## Delta review (264aea8c7)

Model: Claude Opus (subagent), in-session

### Scope

- Head `264aea8c7` ("separate Multiply and Divide surfaces to pen section 16"), PR #1269, base `claude/multiply-divide-1168-p2` (`5eb8517d3`).
- The whole diff `5eb8517d3..264aea8c7`: 50 files, +3790/-49. It covers the first build (`46f85bbb4`), the Part 2 merge and the rebuild.
- Reviewed against:
  - the plan's Part 3 build notes and decision 12;
  - pen section 16 (`fmAqg`), read only, through the pencil MCP with the main-checkout path. I read every caption on all 8 screens, the pedal geometry of screen 01, and a screenshot of screen 04. Nothing in the pen was edited or saved;
  - owner rules 1 to 5;
  - the earlier findings H1, M1, L1 and L2 above.

### Runs

Fresh worktree at `264aea8c7` under the scratchpad.

| Run | Result |
|---|---|
| `run_native_tests.sh` (own TMPDIR) | 5 suites, ALL PASSED, exit 0 |
| looper_repository: `length_history_refusal_test`, `length_journey_native_test`, `length_native_test` (with `SEGNO_ENGINE_LIB`) | +6, all passed |
| App: `foot_length_dispatch`, `foot_length_projection`, `foot_length_view`, `loop_count_words`, `tracks_view`, `app_test`, `tracks_screenshots_test` | +328 ~6. The 5 new `foot_length_*` goldens and the updated `pedal_setup_picker` golden ran and passed. |
| `test/l10n/arb_completeness_test.dart` | Not on this branch. It exists only in `938c42ff8` (the usb-storage branches). I ran that file against this tree: passed. I then removed it. |
| `dart analyze --fatal-infos lib test packages/looper_repository packages/segno_engine` | **1 issue**: `lines_longer_than_80_chars` at looper_repository.dart:1090 |
| PR CI (`gh pr checks 1269`) | **`build / build` and `looper-repository / build` fail** on that same info. Every other check passes. |
| Bloc lint | Cannot run in a worktree. Checked by reading: every new public cubit method returns `void`, except `editFootLengthTrack`, which returns `Future<void>`, the same shape as `toggleFootFadeTrack` on trunk. |
| Mutation: drop the `_lengthEditable` re-check inside both Divide gesture closures (control_foot_length.dart:44 and :47) | **Survives** the dispatch, view and tracks_view suites (+168, all passed) |
| Probe: `FootLengthOutcome(doubled, fromFrames: 96000).describes(track at 48000)` | Returns **true** (see M1 below) |

### Earlier findings: status

- **H1 (pen 16): fixed.**
  - Two modes with their own titles and `ModeAction` (`mode:multiply`, `mode:divide`).
  - Rec/Play stays Record / Play. The keyboard and the footswitch agree; the test is at foot_length_dispatch_test.dart:323.
  - Multiply: Clear is "Double length · Repeat to N"; Undo keeps the Tracks gesture.
  - Divide: First half on Undo, on release, with Hold for Undo; Last half on Clear.
  - The selected-track panel and screens 07 and 08 are built.
  - Pen captions checked against every screen: "Repeat to 4/8 bars", "Bar 1"/"Bar 2", "Beats 1–2"/"3–4", "Beats 1–6"/"7–12", "First 1 bar kept", "Last 1 bar kept", "Hold · Undo" (only while there is something to undo), "Select a track", "No recorded audio in this bank", "Finish recording" and "Finish recording to change length". The panel shows per-bar cells, not halves, while the track records (08).
  - Geometry matches screen 01 to within about 15 px: Clear and Bank centres, the panel's inner origin x=1000, and the pedal row from x=100 to 1820.
  - The plan lists the departures to write back.
- **M1: fixed for the reported case.**
  - `le_length_history` no longer counts a refusal returned at the tap.
  - The counter now rises only in two places:
    - `le_apply_queued_undo` (engine_commands.c:653). It counts once per drained batch, and line 681 zeroes the remaining taps.
    - `le_length_collect` for op ≠ 0 (line 3104).
  - The native assertions were updated, and they fail if either increment is removed.
  - The residue is L1 below.
- **L1, L2: fixed.**
  - "or would leave half a beat" (en and es).
  - The Undo notice now reads "If pressing again changes nothing, that length no longer fits the other loops."

### Verified correct (traced)

- **Divide Undo, release versus hold. There is no double fire.**
  - `_onLengthPress` arms `_undoGesture` through `_armGesture`. That uses `_longPress`, the pedal long-press setting (default 800 ms), the same threshold as the Tracks Undo/Redo and every other system hold.
  - When the hold fires, `_HoldGesture` clears `_onTap`, so the release is silent.
  - `release()` runs the tap only when no hold fired and `stillValid` holds (not closed, not take-locked, same Session).
  - `press()` ignores a second arm while the gesture is active, and `_pressedButtons` admits one contact per button. A footswitch and a screen contact therefore cannot both arm.
  - The channel is latched at contact.
  - A screen cancel (`footMixerCancelled`) cancels the gesture.
  - The test holds for 900 ms and asserts one Undo and no third edit.
- **Saved assignments (owner rule 3).**
  - `mode:length` existed only in `46f85bbb4`. `git branch -r --contains 46f85bbb4` lists only the P3 branch, and no 1168 part has been merged to `segno-integration` or `master`. No shipped install can hold the key.
  - A stored `mode:length` from a development install parses to `UnavailableAction`. It shows as "Unavailable · mode:length" in the pedal, CTRL and MIDI editors, and the press is inert. It is never remapped to another action.
  - The track-operation tokens (`multiply`, `divide-first`, `divide-last`) are unchanged from `46f85bbb4`.
  - The interaction mode itself is not persisted. Only the boot default is, and `bootDefaultFromToken` coerces it.
  - No migration is needed.
- **M1 under the RT/control split.**
  - Both increments run on the control thread:
    - the event drain;
    - `le_length_collect`, after the acquire on `a_state_acks`. Its `length_op` is a control-only field.
  - The snapshot fill reads the counter on the control thread too.
  - A relaxed atomic is sufficient for a monotonic counter that has a single writer thread.
  - The repository diffs the counter per channel on every `_snapshotAndSettleImages`. The first read is the baseline, and a lower count (a new engine) only resets the baseline.
- **Outcome reset.** `footLengthOutcome` resets on entering either surface. A refusal after its visit or Session ended is dropped.
- **Pedal contacts.**
  - The LED is red only on the selected recorded track.
  - An empty track cannot be selected.
  - A busy recorded track is refused before the engine, with the busy notice.
- **Spanish.** Every new key has a Spanish string. The completeness test passes.

### Findings

#### High

**H1. CI is red: an 81-character comment line.**

- Where: packages/looper_repository/lib/src/looper_repository.dart:1090, the doc comment on `_noticeLengthHistoryRefusals`:
  - "/// [recoveryRefusals] instead, never on both. The first read is the baseline, and a"
- Failure: `dart analyze --fatal-infos` and CI's `flutter analyze` report `lines_longer_than_80_chars`. Both `build / build` and `looper-repository / build` fail. The PR cannot get `ready-to-merge`, and the Bloc Lint step after analyze has not run in CI.
- Fix: rewrap the comment, then rerun CI. `dart format` does not wrap comments.

#### Medium

**M1. The outcome line and Multiply's Undo caption can describe an edit that no longer applies.**

- Where: foot_length.dart:209-212 `describes`, used at foot_length_view.dart:433 and :492.
- `describes` only checks that the length differs from `fromFrames`. It does not check that the length equals what the edit produced, or that nothing was stacked on top of it.
- Scenario 1, all on the Multiply surface:
  1. A 1-bar Track 1.
  2. Clear doubles it to 2 bars, then Clear again to 4 bars. The outcome is now: doubled, from 2 bars.
  3. Undo, Undo. The track is back to 1 bar.
  4. 1 bar ≠ 2 bars, so `describes` is true. The panel reads "Repeated to 1 bar" and the Undo pedal reads "Length edit", although the next Undo removes something older.
  - Probe: `describes` returns true for fromFrames 96000 against a 48000-frame track.
- Scenario 2:
  1. Double a track.
  2. Rec/Play overdubs it (Rec/Play is Record / Play here) and the pass is closed.
  3. Undo still reads "Length edit", but the next tap removes the overdub layer.
  - The plan (line 842) promises "Last change when its top entry is not a length edit made here."
- Fix: record `toFrames` and the track's `undoDepth` (Track.undoDepth, track.dart:124) when the edit is accepted. `describes` then requires `lengthFrames == toFrames && undoDepth == recorded`. Add a dispatch test for both scenarios.

#### Low

**L1. Residue of M1: two refusal codes at the tap are now silent.**

- Before M1, `le_length_history` counted every synchronous refusal. The repository's `_reportRecoveryResult` (looper_repository.dart:1772) reports only `modeMismatch` and `notReady`.
- A length Undo or Redo that `le_length_post` → `le_push_cmd` refuses because the command ring is full returns `LE_ERR_INVALID` (engine.c:1559). `le_length_history_post` does not check the ring first, unlike `le_engine_edit_length`.
- That refusal is now reported nowhere: the tap does nothing and nothing is said.
- This is rare, since the ring only fills under an audio-thread stall.
- Fix, either of:
  - have `le_length_history_post` pre-check ring room and return `LE_ERR_NOT_READY`, as the edit path does;
  - or have the repository report any non-OK result of a history tap.
- Also: `le_length_history` (engine_commands.c:3088) is now a one-line pass-through to `le_length_history_post`. Fold the two into one (rule 4).

**L2. A screen reader cannot Redo on the Multiply surface.**

- `multiplyRoles[undo]` has no `hold`, so foot_length_view.dart:552 passes `onHold: null`.
- A physical or touch hold on Undo redoes (the Tracks gesture). The semantic long-press does nothing.
- Fix: give Multiply's Undo a semantic hold that calls `redo(state.cursor)` (for example a `FootLengthAction.redo` hold role), and test it.

**L3. Test gaps found by mutation.**

- (a) Removing the `_lengthEditable` re-check inside both Divide gesture closures (control_foot_length.dart:44 and :47) leaves every suite green.
  - Failure it would hide: hold Undo in Divide, press MODE to return to Tracks, release Undo. First half then fires on the selected track in Tracks mode. A hold that crosses the exit would Undo there instead.
- (b) The cubit's `holdFootLengthPedal` and `activateFootLengthPedal(PedalButton.undo)` are only verified as mocked calls in the view test, never executed against the cubit.
- (c) No test ties Divide's hold to the configured long-press. A hard-coded threshold below 900 ms would still pass.
- Fix: add one dispatch test each: exit mid-hold; semantic hold and activate; and a non-default `loadPedalLongPressMs` with a release just under it.

**L4. `editFootLengthTrack` (control_cubit.dart:2230) is public API with no caller in `lib/`.**

- Only tests call it (foot_length_dispatch_test and tracks_view_test).
- Fix: drive those tests through the pedal contacts, or mark the method `@visibleForTesting`.

### Notes

- **Pen write-back is still outstanding.** Section 16 has no `c/` note yet. The plan's list covers:
  - the Rec/Play caption naming the selected track;
  - "Last change" and "Select a track";
  - the wider busy copy;
  - the notices;
  - beats on the stage.
- **Sibling conventions, not departures of this PR.**
  - Uppercase track names ("TRACK 2") and the Spanish Rec/Play caption truncation ("Grabar / Repr...") are the same on the Peel goldens.
  - The pen's "STAGE" crumb is absent on every foot surface.
- **Busy notice when a sibling is busy.** The engine's NOT_READY for a re-clock that waits on a sibling's arm or Count-in maps to `busy`, which reads "The track is busy" although the selected track is idle. This is minor; consider naming the rig instead.
- **Appliance evidence** (footswitch, LED, listening) is still outstanding, as the plan says.

### Verdict

Request changes. H1 is a one-line rewrap that turns CI green. M1 makes the outcome and Undo captions state something false after Undo or an overdub. L1 to L4 can land with it or as follow-ups.

## Delta review (8bfabe310)

Model: Claude Opus (subagent), in-session

### Scope

- Commit `8bfabe310` ("Multiply / Divide delta review fixes") on top of `264aea8c7`: 12 files, +467/-64.
- It claims fixes for findings H1, M1 and L1 to L4 of the 264aea8c7 delta above.
- Reviewed in a fresh scratch worktree at `8bfabe310`.

### Runs

| Run | Result |
|---|---|
| `run_native_tests.sh` (own TMPDIR) | 5 suites ALL PASSED, exit 0 |
| `foot_length_dispatch`, `foot_length_projection`, `foot_length_view`, `tracks_view`, `tracks_screenshots_test` | +213, all passed |
| `dart analyze --fatal-infos lib test packages/looper_repository packages/segno_engine` | No issues found |
| PR CI on `8bfabe310` (`gh pr checks 1269`) | All 25 checks pass, including `build / build` (which runs Bloc Lint) and `looper-repository / build` |
| Mutation A: drop the `_lengthEditable` re-check in both Divide gesture closures | **Killed** by "Divide: a gesture that outlives its surface or its editable state does nothing" |
| Mutation B: restore the old `describes` (`lengthFrames != fromFrames`) | **Killed** by 5 tests: the model test, both dispatch scenarios, and both view scenarios |
| Mutation C: remove the full-ring pre-check in `le_length_history` | **Killed**: `test_length_history_full_ring` fails at line 1201 |

### Claims checked

1. **H1 (comment line): fixed.** The comment is rewrapped. Analyze is clean and CI is green.
2. **M1 (outcome): fixed.**
   - `FootLengthOutcome` records `fromFrames` and `fromUndoDepth` at the press.
   - It binds `toFrames` and `toUndoDepth` only once the published track has moved off both before-values. The binding is attempted at acceptance and again in `_bindLengthOutcome` on every looper state, so the order in which length and depth are published does not matter.
   - `describes` requires the exact bound length and depth.
   - Both of my scenarios are now covered at the model, cubit and view levels:
     - Double twice, then Undo twice;
     - an overdub on top of a Double.
   - A Redo of the edit restores the bound state and reads "Repeated to..." again. That is correct.
3. **L1 (ring full): fixed.**
   - `le_length_history` now pre-checks ring room, as `le_engine_edit_length` does: tail is read relaxed (control is the only producer) and head is acquired. When the ring is full it returns NOT_READY, which `_reportRecoveryResult` reports as a refusal.
   - The pass-through wrapper is folded into `le_length_history`.
   - `test_length_history_full_ring` asserts four things: NOT_READY, an unchanged history, no count, and that the same tap succeeds after a drain.
4. **L2 (Redo for screen readers): fixed.**
   - `multiplyRoles[undo]` has `hold: redo`, so the semantic hold runs `redo(cursor)`.
   - The physical and touch gesture is unchanged: the `undo` press branch still arms `_armUndo`, before the hold branch.
   - The pedal is enabled on `canUndo || canRedo`.
   - "semantic activation and hold run the same roles on the real cubit" covers both surfaces.
5. **L3 (test gaps): fixed, and my MODE-exit scenario was wrong.**
   - **Independent check of the builder's claim:** `setMode` (control_cubit.dart:1444) calls `_invalidateGestures()` at line 1450, before any emit. That function cancels `_undoGesture` and every other system gesture (line 3067). An Undo held across a MODE exit therefore never fires First half or Undo. The failure I described in L3(a) of the 264aea8c7 delta cannot happen, and I withdraw it.
   - **Where the re-check does matter:** a Session load that begins during the press. `reserveSessionLoad` sets `sessionTransitionActive` without changing the Session revision, so `stillValid` still passes. Only the closure's `_lengthEditable` check keeps both the tap and the hold back. The new test covers both, and mutation A proves it.
   - **Long-press setting:** at 300 ms, a 400 ms press is a hold; at 1500 ms, a 900 ms press is a tap. The threshold is read from `pedal.long_press_ms`.
   - The real-cubit semantic tests replace the mocked-only coverage.
6. **L4: fixed.** `editFootLengthTrack` is removed, and its tests now go through `activateFootLengthPedal`.

### Findings

None blocking.

### Notes

- **At the history limit the outcome can stay unbound** (`LE_POOL_SLOTS` = 256).
  - When every pool slot is in use, an edit or an overdub evicts the oldest undo entry and pushes a new one, so the published `undoDepth` does not move.
  - At that depth a Double leaves the outcome unbound: the panel reads "Speed and pitch unchanged" and Undo reads "Last change". That is the safe direction.
  - An overdub on a bound Double at that depth would leave "Length edit" showing.
  - This needs about 255 retained steps on one track, so it is not worth a change now. An engine-published history revision would close it if it ever matters.
- **Still outstanding, as before:**
  - the pen write-back (a `c/` note on section 16) of the departures listed in the plan;
  - the appliance footswitch, LED and listening evidence.

### Verdict

Approve.
