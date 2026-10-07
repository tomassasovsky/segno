Model: Claude Opus (subagent), in-session

# Review of PR #1216 (claude/library-1178-p5): Library Part 5 (#1178), New loop starts an empty loop and keeps the sound, tempo and pedal setup

**Branch:** `origin/claude/library-1178-p5`, head cd721f202, one commit on 74e977324 (Part 4). 28 files, +1654/-159.

**Scope:**
- The full diff `74e977324..cd721f202`.
- Plan D7, D8, D9 (the field table) and Part 5, and §2 (Part 5 as built).
- AGENTS.md conventions.
- The owner rules.
- **Design:** `segno-ui.pen`, read through the pencil MCP without saving:
  - 19/02 `U2bRH` (dialog `tB82E`);
  - 19/06 `uRKTE`.

  I compared these against the new `library_new_loop` golden and the regenerated Library goldens.

## Runs

Everything ran in a scratch worktree at cd721f202, removed afterwards. `SEGNO_ENGINE_LIB` came from `build_test_lib.sh`, and `SEGNO_SCREENSHOT_FONT_DIR` was set to the SDK material fonts.

| Check | Result |
| --- | --- |
| Whole app suite (`flutter test`) | +3493 ~8 -17 |
| The 17 failures | all `external_pedals_*` / `midi_controls_*` goldens. The stack does not touch them, and the same 17 fail at trunk 56033baf0 with the same fonts. This is the trunk's control-row regression, which 7a9fdcbd9 fixes |
| `session_repository flutter test` | +185, all passed |
| `dart analyze --fatal-infos lib test packages` | No issues |
| `bloc lint lib test packages` | 0 issues in 859 files |
| `new_loop_engine_test.dart` (real engine) | passes |

**Probes:** those listed in the Part 4 review apply here unchanged. New loop runs the same `_preserveOutgoing`.

**Mutations:** the builder's set is caught:
- keeps grid, keeps crown, empty-rig default;
- live drops the remap;
- no preservation, no empty save;
- id not released, late write reported as a failed save;
- stale reference, reference not recorded;
- cancel starts, not inert when busy;
- no return to the stage, return on any success;
- toast on New loop;
- strip all filled, unnamed copy.

I did not repeat it.

## Verified correct (traced)

1. **The D9 field table.** `Session.forNewLoop` (`session.dart:1043-1085`) names every field explicitly, with no copy helper.
   - It drops `tracks`, `baseLengthFrames` (0), `loopBars` (constructor default 0), `primaryTrack` (default -1) and `name`.
   - It keeps the other 39 keys, exactly D9's keep list: tempo, signature, `syncTempo`, `quantizeDiv`, mode, the record defaults and their five per-track override maps, Fade, click, count-in, `recDub`, `autoRecord`, `defaultMultiple`, levels, pans, lane inputs, outputs and counts, input and output setup, all chain stages, monitors, the pedal remap, `sampleRate` and `channels`.
   - `laneMix` goes with the tracks, as D9 says.
   - The key-set test (`session_mapping_test.dart:1240`) builds a fully non-default `Session`, so a field added later fails until its fate is written.
2. **The live half is the save's own.** `liveSession` (`session_repository.dart:1281-1295`) is `_sessionFrom` over the live snapshot with no tracks.
   - Tempo, signature, mode and crown come from the snapshot while the device runs, exactly as a save takes them.
   - So New loop keeps what a save of the outgoing rig would have kept.
   - `rigForNewLoop` maps it through `rigFromBundle`, the mapper Open uses, so the two cannot disagree.
3. **The transforms reset inside the one apply path.** On the real engine (`new_loop_engine_test.dart`), after New loop:
   - every track is `empty` with zero undo/redo;
   - Reverse is off and Fade is at unity;
   - no lane is muted, and the master length is 0;
   - tempo (96), tempo source and mode are kept;
   - the outgoing bundle reloads byte for byte, mute included.

   Speed and Transpose do not exist yet, and the doc on `rigForNewLoop` says where their reset belongs.
4. **Failure paths leave no half-applied rig.** `newLoop` (`session_cubit.dart:467-542`):
   - A failure in preservation, capture, naming or minting, or a pre-apply failure inside `_applyRig`, applies nothing. It cancels the session load and gives the reserved id back. Both are tested.
   - A failure after the apply is `_SessionBootException`. The engine stops and the boot image is kept for `retryLoadedSession`, the same recovery path as Open.
   - The one partial outcome is designed: the empty rig is applied but its manifest cannot be written. The loop is then started and current under its new name, with no bundle yet. The next Save writes into the still-reserved `<root>/<id>`, which `_isReservation` hides meanwhile. This is tested.
5. **Order and naming.** The automatic name is taken *after* preservation, so an unnamed outgoing rig saved as `New loop N` is followed by `New loop N+1`, as in 19/06's `New loop 2`. A held momentary is released before the capture, so its temporary values are not stamped into the kept chains (tested).
6. **The reference after New loop** is the empty rig's fingerprint, so an Open straight after saves nothing more (tested).
7. **19/02 against the pen (`tB82E`).** The build matches:
   - 850 wide with 41 padding;
   - a 32 pt title and 24 pt body lines;
   - the name drawn in the primary colour;
   - two 346 × 36 strips of eight 38-wide slots with a 28 pt chevron centred between them;
   - "Keep your effects, tempo and pedal setup.";
   - `Cancel` 125 × 64 and `Start new loop` 216 × 64 in bold accent, with 24 between rows.

   The unnamed variant ("Your current loop stays in your Library.") is listed. `NewLoopKeptLine` finds the name by `indexOf`, and both locales put it first, so the bright span is always the placeholder.
8. **19/06.** On success the Library returns to the stage, whose header reads the new name, and no toast covers it. The `New loop` button is enabled, dimmed and inert while a session action runs (tested). `Cancel` calls nothing (tested).
9. **VGV.**
   - `LibraryTrackStripSize` is an enum of the two pen sizes, not pixel parameters.
   - The sheet is a widget class.
   - Both ARBs carry the four strings.
   - `newLoop` returns `Future<void>`.

## Findings

### 1. Medium (inherited from Part 4, Finding 1): a playing rig counts as changed, so New loop re-saves an untouched session

- New loop always asks (19/02) and is usually pressed while the loop plays.
- `fingerprint` keys each track on `track.state.name` (`session_repository.dart:1236`). An opened session that was only played therefore reads as changed, and `_preserveOutgoing` writes all of it again first, with Part 3's two-copy swap.
- The saved date moves, and on a nearly full disk the New loop is refused with "Could not save your current loop".
- **Fix:** the same one-line fix as Part 4 Finding 1.

### 2. Medium (inherited from Part 4, Finding 2): New loop while a track records drops the take, and while it overdubs it fails as a save

- The 19/02 sheet says "<name> stays in your Library." for a rig whose track 2 is still recording. The preservation save skips that track (`_capture`, `session_repository.dart:1394-1398`), then the clear removes it.
- An overdub times out the save's settle wait, and the New loop is refused as a failed save.
- The future foot binding (E6-9) will make this the common case: a player hits New loop mid-take.
- **Fix:** the same fix as Part 4 Finding 2. End the capture, or refuse it with its own words, before preservation.

### 3. Low: when the empty rig cannot be written, the Library says "That did not work. Try again." although the new loop has started

- **Where:**
  - `session_cubit.dart:509-522` throws `_SessionRefusal(SessionError.unknown, ...)` after the apply;
  - `library_page.dart` maps `unknown` to `actionFailed`;
  - the stage listener fires only on success, so the Library stays open over a rig that is already empty and renamed.
- **Impact:**
  - The player is told the action failed when it half succeeded: the tracks are cleared and the header reads `New loop N`, but nothing is in the catalog (rule 3).
  - "Try again" starts *another* new loop under a fresh id. That is harmless, because the first reservation stays hidden and is reused by nobody, but it is not what the line suggests.
- **Fix:** give this outcome its own message, for example "New loop N started, but could not be saved yet. Save it from Manage.", or return to the stage and raise the save-failed toast there. Add a widget test for the message.

## Notes

- **Every New loop creates a catalog entry at once** (D9: "the new identity is created at once"). Pressing New loop three times without recording leaves three empty `New loop N` sessions, each listed with "no tracks", as the golden shows. That is the plan's choice, but a later New loop from an unchanged empty rig could reuse its identity instead of minting another.
- **The double `_releaseHeldBindings`.** New loop releases held momentaries itself, and `_applyRig` releases them again. Both calls are expected to be idempotent, and the first is the one that matters (before the capture).
- **The double `cancelSessionLoad`.** It runs after a pre-apply failure in `_applyRig` and again in `newLoop`'s catch. `_open` has the same shape, so this is not new.
- **The plan's real-engine criterion** ("after New loop every track is EMPTY ... the outgoing session reloads byte-exact") is met at the repository and looper level. The engine test calls `session.save`, `liveSession` and `applySession` directly, not `SessionCubit.newLoop`. A cubit-level real-engine test with Play pressed first would have exposed Finding 1.

**Verdict:** Request changes.
- Findings 1 and 2 are Part 4's and are fixed there; this part needs no further change for them, only a rebase.
- Finding 3 is a small copy and test change.
- The D9 field table, the transform resets and every failure path are otherwise sound.

---

## Delta review (55ee5a373)

Model: Claude Opus (subagent), in-session

**Scope:** Part 5 rebased onto the new Part 4 on trunk 890f04936.
- 52e1d2947: the rebased feature commit.
- 55ee5a373: the fixes. New loop ends takes first, and the not-saved failure gets its own error.

**Runs:** the same as the Part 4 delta.
- At 55ee5a373: `test/session test/library test/looper/view test/app` +1111 ~6 and `session_repository` +255, all passed.
- At p7 (53c7978be): the whole app suite +3661 ~8 passed, and analyze and bloc lint are clean.

## Earlier findings: status

1. **Medium (inherited), a played rig counted as changed: fixed** by Part 4's fingerprint. The real-engine test "New loop from a session that was only played and stopped saves nothing of it and empties every track" pins it through `SessionCubit.newLoop`.
2. **Medium (inherited), New loop during a take: fixed.** `newLoop` now calls `_endCaptures()` before `_preserveOutgoing()`. The real-engine test "New loop while a take records keeps the take" checks that the take is in the outgoing session's bundle.
3. **Low, the failed empty save read as a generic failure: fixed.**
   - The post-apply write failure is `SessionError.newLoopNotSaved`.
   - The Library returns to the stage on it, as on success, by a listener keyed on the error.
   - The stage toast says "<New loop N> started, but it could not be saved yet. Save it to keep it.", using the current name, which is already the new loop's.
   - Both ARBs carry the string. There are tests for the toast, the 19/05 mapping and the return to the stage.

## Findings

None new. Part 4's D-1 (a pending arm is not ended or fenced) applies here too. New loop always asks, so the player is at the sheet when an arm fires. The same fix covers both.

**Verdict (delta):** Approve.
