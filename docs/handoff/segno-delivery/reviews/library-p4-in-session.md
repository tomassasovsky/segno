Model: Claude Opus (subagent), in-session

# Review of PR #1215 (claude/library-1178-p4): Library Part 4 (#1178), Open preserves outgoing work and confirms an interruption

**Branch:** `origin/claude/library-1178-p4`, head 74e977324, one commit on 9c646c2de (Part 3). 25 files, +919/-38.

**Scope:**
- The full diff `9c646c2de..74e977324`.
- Plan D7, D8 and Part 4, and §2 item 7 (Part 4 as built).
- AGENTS.md conventions.
- The owner rules.
- Pen 19/01 and 19/03 for the Open footer. The pen draws no interruption dialog, and the build lists that.

## Runs

Everything ran in a scratch worktree at p5 (cd721f202), which contains p4 unchanged, and was removed afterwards. `SEGNO_ENGINE_LIB` came from `build_test_lib.sh`, and `SEGNO_SCREENSHOT_FONT_DIR` was set to the SDK material fonts.

| Check | Result |
| --- | --- |
| Whole app suite | +3493 ~8 -17. The 17 are the trunk's control-row goldens, and the same 17 fail at trunk 56033baf0 |
| `session_repository flutter test` | +185, all passed |
| `dart analyze --fatal-infos lib test packages` | No issues |
| `bloc lint lib test packages` | 0 issues in 859 files |

**Probes** on the real engine (`PumpedNativeEngine`; throwaway tests, deleted afterwards):

1. **Fingerprint across a stop.** Record a take (track playing), fingerprint, `looper.stopTrack()`, pump, fingerprint again.
   - The fingerprints **differ**, only in `"rev1:playing"` against `"rev1:stopped"`.
   - Nothing a save writes changed. See Finding 1.
2. **A write-back while a track captures.** Two tracks recorded and saved, then `session.save` over the same bundle.
   - **Track 2 recording a new take:** the save succeeds and the bundle holds channels `[0, 1]`. The take is not in it.
   - **Track 0 overdubbing:** the save throws `StateError: engine commands or an overdub layer never settled`, after `_awaitLayersSettled`'s 64 × 8 ms.

   See Finding 2.

**Mutations** (each reverted):

| Mutation | Result |
| --- | --- |
| `fingerprint` drops `track.state.name` from the content key | survives (no test pins the "take in progress" reason) |

The builder's own set is caught, and I did not repeat it. It covers:
- no preservation, always preserve;
- no confirm, confirm always;
- fingerprint ignores audio;
- no boot baseline, baseline retaken;
- opened not recorded, save not recorded;
- the no-baseline rule both ways;
- save failure on the card;
- reopening the current session reloads it.

## Verified correct (traced)

1. **D7 order and failure paths.** `_open` runs inside `_captureSettings.runExclusive`, in this order:
   - `_preserveOutgoing`;
   - `read(bundlePathOf(id))`;
   - `_applyRig`;
   - `_recordOpenedFingerprint`.

   On failure:
   - A failed preservation is `_SessionRefusal(saveFailed)`. Nothing is read or applied, and `cancelSessionLoad` runs (`session_cubit.dart:446-451`).
   - A target refused after an unnamed rig was preserved leaves that rig current as `New loop N`, because the emit at `:326-333` precedes the read. The `_performRun` failure `copyWith` keeps the current id.
2. **No half-applied rig.** The only post-apply failure is `_SessionBootException`. It keeps the boot image for `retryLoadedSession`, which re-takes the fingerprint on success (`:720`). Every pre-apply failure rolls the mix back and cancels the session load.
3. **Fingerprint content against save content.** `fingerprint` (`session_repository.dart:1224-1275`) builds its manifest with the same `_sessionFrom`, from the same capture's settings and chains and the same pedal remap. The only difference is that each lane's layer list becomes `rev<trackAudioRev>:<state>`.

   I compared it field by field with `_capture` and `_sessionFrom`, and found no saved field outside it:
   - the track's `multiple`, length and fade amount;
   - the lane volume (settings first, then the engine), mute, output mask, input, pan, balance and undo/redo depths;
   - the grid, which comes from the snapshot;
   - every settings field, every chain stage and the pedal remap.

   The mixdown is derived from the above.
4. **`trackAudioRev` cannot alias.** `le_engine_track_audio_rev` reads `a_audio_rev`. It is only ever incremented, by `atomic_fetch_add` in `le_audio_rev_bump` (`engine_private.h:2055`), and never stored, so it is monotonic for the engine's lifetime. The engine is created once (`run_segno.dart:94`), and the fingerprint lives only in memory. A reset revision cannot make a changed rig look unchanged, and a 32-bit wrap would need about four billion writes.

   Every history operation re-points `a_live` through `le_track_publish_live`, which bumps the revision: undo, redo, clear-restore, undo-clear-all and layered finalize. The real-engine test pins three cases:
   - playing back is no write;
   - an overdub is one;
   - an undo is one.
5. **The fingerprint is taken before the save's own capture** (`_saveCurrentRig`, `:366-397`). An edit that lands between the two makes the stored reference older, so the next Open saves once more and never skips an edit.
6. **The no-baseline rule.** When the reference or the live capture is unknown, the rig is saved only if a track `hasContent` (`:299-300`). An Open that resolves a settings-recovery notice therefore stays possible, which is rule 2's recovery path. The boot baseline is taken after every owner has loaded (`app_runtime.dart:167`), and a failed load leaves none, which is the safe side.
7. **D8 predicate.** `openWithConfirm` (`library_preview_card.dart:537-556`) asks when `t.state == TrackState.playing || t.isCapturing`, not on `TransportState.isRunning`, as review E2 required. `Cancel` returns before calling anything. A running device with stopped tracks is not asked. All three are tested.
8. **Opening the current session does nothing** (`:412`). The footer already reads `Return to tracks`, and four recall steps in the persistence tests were re-routed through a `saveAs('Elsewhere')` so they still exercise recall.
9. **The 19/05 routing.** `libraryFailureOf` returns `saveFailed` before the `failedSessionId` gate, and the preview card maps `saveFailed` to no banner. So a failed preservation shows the page line, not a refusal on the target, as tested.
10. **VGV.**
    - The new `SessionIo.trackAudioRev` is implemented on the native engine, the mock and every fake.
    - No widget takes pixel parameters.
    - Both ARBs carry the three strings.
    - Cubit methods return `Future<void>`.

## Findings

### 1. Medium: starting or stopping playback changes the fingerprint, so an unchanged session is re-saved on almost every Open, and on a full disk the Open is refused

- **Where:** `session_repository.dart:1236`, `final content = 'rev${_engine.trackAudioRev(i)}:${track.state.name}';`.
- **Mechanism:**
  - `TrackState` separates `playing` from `stopped`, and neither is saved: a session always opens stopped (#1134).
  - Open records the reference with every track `stopped` (`_recordOpenedFingerprint`).
  - The player then presses Play, and later opens another session. That is exactly the D8 path, which asks "Stop playback and open …?".
  - The live fingerprint now says `playing`, so `_preserveOutgoing` saves the untouched session.
- **Reproduced:** probe 1.
- **Impact:**
  - It breaks the Part 4 criterion "an unchanged rig is not re-saved" on the most common Open.
  - Every such Open writes and fsyncs every layer of the outgoing session, and with Part 3's swap a whole second copy, before it starts loading. The Open is visibly slower on a large session.
  - The session's saved date changes, so it jumps to the top of the newest-first list. Nothing tells the player it was saved (rule 3).
  - On a nearly full disk, the needless save fails, and the Open is refused with "Could not save your current loop. Nothing was changed." The player has edited nothing and cannot tell why. They recover only by stopping playback first, which nothing suggests.
  - The same applies to New loop (Part 5), which always asks and is usually started from a playing rig.
- **Fix:** key the content on whether the track is capturing, not on its transport state. For example:

  ```dart
  final capturing = track.state == TrackState.recording || track.state == TrackState.overdubbing;
  final content = 'rev${_engine.trackAudioRev(i)}${capturing ? ':capturing' : ''}';
  ```

  Add a real-engine test that the fingerprint is unchanged across `stopTrack` and `play`. Probe 1 is that test.

### 2. Medium: Open while a track records or overdubs, which D8 explicitly confirms, drops the take or refuses with a false "could not save"

- **Where:**
  - `session_cubit.dart:286-334` (`_preserveOutgoing` saves the rig as it is);
  - `session_repository.dart:1394-1398` (`_capture` skips every track that is not `playing` or `stopped`);
  - `:1584` (`_awaitLayersSettled`);
  - `library_preview_card.dart:544` (the dialog asks for capturing tracks too, and says "Your current loop stays in your Library.").
- **Trigger 1, a recording take:**
  - Track 2 is recording its first pass. The player confirms Open.
  - The fingerprint differs (a new track), so the outgoing rig is saved, but without track 2 (probe 2).
  - `_applyRig` then replaces the rig, and the take is gone from both the engine and the disk.
  - If that take was the rig's only audio and the rig had no name, the preservation writes an **empty** `New loop N` into the catalog.
  - The dialog said the loop stays.
- **Trigger 2, an overdub:**
  - `layerInFlight` stays true for as long as the overdub runs, so `_awaitLayersSettled` times out after about half a second (probe 2).
  - The Open is refused with "Could not save your current loop. Nothing was changed."
  - The player confirmed "Stop playback and open", nothing was stopped, and the message names the wrong cause.
- **Impact:** rule 2 (an unfinished take is lost under a dialog that promises otherwise) and rule 3.
- **Fix:** on `Open` (and New loop), end any capture first, then preserve. Finish the take as the record control would, wait for `layerInFlight` to clear, and only then run `_preserveOutgoing`. If ending the take is not wanted, refuse with its own line, for example "Finish recording before opening another session", and do not offer `Open` in the dialog while capturing.

  Add a real-engine cubit test for each trigger.

### 3. Low: the Part 4 real-engine success criterion has no test, and such a test would have caught Findings 1 and 2

- **The criterion:** "Round trip on the real engine: save, record on another identity, Open the first; the first plays back byte-exact from the head after Play" (`session_layers_roundtrip_test.dart`).
- **What exists:**
  - That file gained only the fingerprint test.
  - The persistence tests that call `session.open` on the real engine check settings, not audio, and none of them plays before an Open.
  - Every D7 cubit test stubs `fingerprint` with fixed strings, so no test runs the real fingerprint through a real Open.
- **Fix:** add the criterion's test through `AppRuntime` or `SessionCubit` on `PumpedNativeEngine`, with Play pressed before the Open and a capture in progress in a second case.

## Notes

- **A capture that cannot run, on a rig with audio.** During a settings recovery, `_liveFingerprint` throws, and the rule then saves a rig that holds audio. That save runs the same capture, so it throws too, and the Open is refused as a save failure. The plan's "an Open that resolves a recovery notice still works" therefore holds only for a rig without audio. Refusing is the safe side, but say so in plan §2 item 7.
- **Open of the current session never reloads it,** so there is no way to discard unsaved edits by reopening. That is listed as deliberate. A later "Revert to saved" needs its own action.
- **The `New loop N` emit inside `_preserveOutgoing`** emits `status: working` with a new current id. Any `BlocListener` keyed on the current id sees the change before the Open finishes. I found none that act on it.
- **Part 3's D-A race** is more reachable here. An Open's preservation save can meet the preview read the row selection started. The fix is the same one-line reorder.

**Verdict:** Request changes.
- Fix Findings 1 and 2. Finding 1 is a one-line change plus a test. Finding 2 needs the capture ended, or a refusal, before preservation.
- Finding 3 is the test that pins both.

---

## Delta review (9dd764471)

Model: Claude Opus (subagent), in-session

**Scope:** Part 4 rebased onto trunk 890f04936.
- 8f63ab827: the rebased feature commit. Its range-diff against 74e977324 is the trunk's API only: `exportHistory`/`TrackHistory`, `reversed` in the fingerprint's track, `repository.open` with conversion, `SessionError.unconvertible`, operation guards and `LibraryFailure.busy`.
- 5d1ff03e7: the fixes for Findings 1 to 3.
- 9dd764471: a test that a schema-7 bundle renames in place and still previews through the trunk's `decodeSessionManifest`.

**Runs:**
- Scratch worktrees at 55ee5a373 (p5, which contains this part unchanged) and 53c7978be (p7), removed afterwards.
- `SEGNO_ENGINE_LIB` came from `build_test_lib.sh`, and `SEGNO_SCREENSHOT_FONT_DIR` was set to the SDK material fonts.

| Check | Result |
| --- | --- |
| `test/session test/library test/looper/view test/app` at p5 | +1111 ~6, all passed. This includes the new real-engine `open_preserves_engine_test.dart`, which runs and does not skip |
| `session_repository` at p5 | +255, all passed |
| Whole app suite at p7 (contains this part) | +3661 ~8, all passed. The trunk's 17 control-row goldens are fixed now |
| `dart analyze --fatal-infos lib test packages` and `bloc lint` at p7 | No issues; 0 issues in 892 files |

## Earlier findings: status

1. **Medium, a played session read as changed: fixed.**
   - `fingerprint` keys each track on `rev<trackAudioRev>`, plus `:capturing` only for `recording` or `overdubbing` (`session_repository.dart`, the content line in `fingerprint`).
   - `session_fingerprint_test.dart` pins that a stop and a play leave it unchanged.
   - The real-engine test "a session that was only played and stopped is not saved again" drives a real `SessionCubit` through Play, Stop and Open.
2. **Medium, a take in progress at Open: fixed.**
   - `_endCaptures` runs first inside `runExclusive`, before `_preserveOutgoing`. It calls `stopRecordControl` for every capturing track, the control that "finishes only a live capture".
   - It then polls `LooperState` every 8 ms until none captures, or refuses after 20 s with `SessionError.captureInProgress`. That refusal happens before anything is saved, read or applied.
   - The settle wait in `save` then covers the punch-out fade.
   - Real-engine tests: a recording take is finished and saved, and an overdub is punched out and saved, not refused.
   - The new line is routed to 19/05 and to the stage toast, and is kept off the target's preview card.
3. **Low, no real-engine round trip: fixed.** "The first session plays back exactly after another one was recorded, preserved and left" is the plan's criterion, through a real cubit.

**Rename across schemas** (9dd764471): `renameSession` edits the manifest as a JSON map and never decodes it, so an older-schema bundle is renamed without being converted, and `readPreview` still reads it through the migration chain. The test pins both. This is correct for rule 1, since an old install's bundle is never rewritten by a rename.

## Findings

### D-1. Low: a pending record arm is neither ended nor fenced, so a take that starts during the preservation save is cleared by the Open

- **Where:** `session_cubit.dart`, `_endCaptures`. It looks only at `Track.isCapturing` (`recording`/`overdubbing`).
- **The gap:**
  - A track can be `pending`: armed for the loop top, a bar, or a signal trigger.
  - Nothing ends that arm, and transport admission is only closed later, by `blockStartForSessionBoot` inside `_applyRig`.
  - The D8 dialog's predicate does not count it either.
- **Trigger:** the player arms track 3 for the next loop top, opens the Library, and taps Open on a stopped rig, so there is no dialog.
  - The arm fires while the outgoing rig is being saved.
  - `_capture` skips the now-recording track.
  - The apply then clears it.
- **Impact:** a just-started take is lost silently. It is short, which is why this is Low.
- **Fix:** in `_endCaptures`, also `cancelArm` every `pending` track (or call `blockStartForSessionBoot` before `_preserveOutgoing`), and count `pending` in the D8 predicate.

### D-2. Low: the timeout refusal says "Nothing was changed" after a Stop was already sent

- **Where:** `libraryTakeStillRunning`, "The take has not finished yet. Nothing was changed; try again when it has."
- **What actually happens:** by the time it shows, `stopRecordControl` has been issued, so the take still ends at its Record timing boundary.
- **Trigger:** an overdub on a loop longer than 20 s with Record timing at the loop top.
- **Impact:** a small rule 3 inaccuracy, with no data risk; the take is kept.
- **Fix:** "The take is finishing. Try again when it has stopped."

## Notes

- `_endCaptures` measures its deadline with `DateTime.now()`. A clock step on the RTC-less appliance (NTP sync at boot) can shorten or lengthen the 20 s. A `Stopwatch` is immune to that.
- The fingerprint now also carries `reversed` (from the trunk). Reverse is saved, so a Reverse toggle correctly counts as a change.

**Verdict (delta):** Approve. All three findings are fixed and pinned on the real engine. D-1 and D-2 are Lows and can follow.
