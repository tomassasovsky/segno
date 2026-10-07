Model: Claude Opus (subagent), in-session

# Review of `claude/backing-1200-p5` (d92267d66): feat(backing): the player's owner, its mix families and the session's backing (#1200 Part 5)

## Scope

- **Head and diff:** head `d92267d66`, on P4 `8f9bcba92`. It merges #1196's session-migration branch (`cc3463373`). The part's own diff is `cc3463373..d92267d66`: 58 files, +3,181 lines.
- **What it adds:**
  - `BackingPlayer`: the prepared order, one selection, the Play rules, Use as backing, automatic Next staging, recall and capture;
  - `BackingCubit`;
  - `BackingSettings`, with the #1159 families `BackingMixFamily` (one record, one address per field) and `ClickPanFamily`;
  - the settings checkpoint keys `backing.mix` and `tempo.click_pan`;
  - `SessionBacking` and `clickPan` in the Session (schema 13 on this branch), with the 12 → 13 migration step;
  - `SessionBackingPort` in the settings coordinator: Open installs, and boot Retry installs again;
  - the internal copier, the wiring and the l10n.
- **Reviewed against:**
  - the plan at `519107563`: D4, D9, D10, Part 5 and its build record;
  - AGENTS.md;
  - the owner rules.
- **Schema number:** the branch claims 13, but Reverse P2 took 13 on trunk, so P5 will renumber to 15. As asked, I judged the step's logic, not the number.
- **Pen:** not read. This part has no screens.

## Runs

**Native** on `d92267d66`: plain, ASan, telemetry-off and TSAN races all passed. The decoder fuzz driver reports 3,000 inputs and 0 violations.

**Dart:**

| Suite | Result |
|---|---|
| App suite | 3,529 passed, 56 skipped |
| `segno_engine` | 404 passed |
| `session_repository` | 241 passed |
| `settings_repository` | 203 passed |
| `backing_repository` | 38 passed |
| `looper_repository` | 806 passed |
| `dart analyze --fatal-infos lib test packages` | clean |
| `bloc lint lib test packages` | 0 issues |

**Probe test** (`repro/p5_play_after_configure_probe_test.dart`, run in `test/backing` with the PR's `BackingFixture`, then removed):
1. Use as backing (loaded, stopped).
2. The interface changes rate: `MockAudioEngine` stop, then start at 44.1 kHz.
3. Press Play once.
4. Press Play again.

The result is in M1.

**Merge:** conflicts mechanically with trunk `890f04936`. Besides the stack's engine conflicts (P3 L3), it conflicts in `run_segno.dart`, `app.dart` and `main_mock.dart`.

## Verified correct (traced)

**Play rules (D4).**
- Play on the loaded selection toggles Pause.
- Play on another selection decodes while the old file plays, then switches. Before that decode, it releases the staged Next, so at most two buffers are resident (D1, M1).
- Stop cancels a pending decode, through the repository generation.
- Use as backing asks for a confirmation while another file plays.
- Remove keeps the playing file and moves the selection to the neighbour.
- Add is idempotent.
- Move keeps the selection.

**Automatic Next.**
- The following item is staged only while End is Next, the loaded file is prepared, and something follows it. There is no wrap.
- Staging re-runs whenever the mix owner changes, so switching End to Next stages at once.
- On `advanced`, the selection follows only when it was on the outgoing file.
- On `nextMissing`, the following item's own stage failure, or Missing, is reported.

**Session (D9).**
- `capture` writes the prepared order, the loaded item and the durable mix.
- On Open, `SessionCubit.open` installs the mix and click pan through their owners, inside the Session exclusion and after Fade. It then calls `recall`, which stops, restores the order, selects the loaded item, and reloads it stopped at 0 unless the engine already holds it.
- Boot Retry installs it again.
- `SessionBacking.fromJson` is strict: exactly six keys, unique digests, `sha256:<64 hex>`, values in range. The current schema refuses a manifest without `backing`.

**The families.**
- `BackingMixFamily` is one stored record. `durableAfter` takes only the edited field, so a level controller is never superseded by a pan edit.
- An unreadable record repairs to the defaults.
- `ClickPanFamily` keeps an absent key absent at centre.
- Both apply through the repository, which replays them after an engine restart.

### The migration step (12 → 13): is "a migrated session keeps the live backing setup" right under rules 1 and 3?

**What `_v12ToV13` does** (`session_migration.dart:409`):
- It fills `backing` and `clickPan` from `c.live`. That is `SessionSettingsCoordinator.current()`, which now includes `_backing?.backing` and `clickPan`.
- It records each as "taken from the live setting" in the conversion notes, which are logged.
- With no live player it writes an empty backing and a centred click.
- The test opens the real `v12_peel_097e1ef68` fixture both ways and checks the notes and that the session's own content is untouched.

**Rule 1 (preserve installs): right.**
- A v12 session never said anything about backing, and opening it on the previous build left the player as it was.
- Filling the block with defaults instead (empty list, nothing loaded, mask 0) would make the first Open of every old session after the upgrade silently wipe the performer's prepared list and unroute the backing. The prepared list exists nowhere else.
- Keeping the live setup is the only choice that loses nothing, and it follows the schema 8 precedent for former globals.

**Rule 3 (no silent behaviour change): right, with one consequence to state.**
- Opening the converted session changes nothing audible beyond what any Open does under D9: it stops the backing, and the loaded file stays loaded, because `recall` keeps a file the engine already holds.
- The player is told the session was converted, and the original manifest is kept beside it.
- Taking a value from the live setting is not an audible change, so it is rightly absent from `SessionConversionChange`.
- **The consequence:** `_commitConversion` writes the converted manifest back. The prepared list that happened to be live at the first open becomes that old session's own list for later recalls. This is the same "converted once, from what was live" semantics schema 8 has, so it is consistent. It should be stated in D9 or in the build record, in those words, so nobody later reads it as a bug.

**Verdict on the deviation: correct.** Renumbering to 15 changes only the key, the constant and the regenerated fixture. The step's logic carries over unchanged.

## Findings

### Medium

**M1. After an interface change, the player forgets its loaded file: the UI says nothing is loaded, the next Save drops it, and the first Play press does nothing.**

- **Where:**
  - `BackingRepository.load` (`backing_repository.dart:113`) emits `clearLoading` before its `refresh()`. That gives one state with `loaded == null` and `loading == null`.
  - `BackingPlayer._onPlayer` (`backing_player.dart:240-242`) clears the player's `loaded` on exactly that state.
  - Nothing restores it afterwards. `_onPlayer` copies `loaded` from the repository only on `advanced`, and the restart path reloads through `BackingRepository.load` directly (`_restarted`, `:340`), not through `BackingPlayer._load`, which would set it.
  - Separately, nothing refreshes the repository on an engine restart while it is stopped. Polling runs only while it is playing or loading. So the reload starts only at the next user action.
- **Reproduced** with the PR's fixture:

| Step | Engine | Player |
|---|---|---|
| Before | item 1 | `loaded` a.wav |
| After the 48 → 44.1 kHz configure and one Play | Stopped, item 2 (reloaded) | `loaded` null, 0 notices |
| Second Play | Playing, after a second decode of the same file | |

- **Failure scenario:**
  1. The performer has a file loaded, stopped or paused.
  2. The interface renegotiates (unplugged, re-plugged, or a rate change).
  3. Play does nothing: the press is spent triggering the reload, and no notice is shown because nothing was playing.
  4. Meanwhile the Backing views show "No audio loaded", while the engine holds the file.
  5. A Save in this window writes `loaded: null`, so the session loses which file was loaded.
  6. The next Play decodes the file a second time.
- **Owner rules:** this breaks rule 3 (a press silently does nothing, and the state is wrong) and D10 ("re-decodes the loaded item … stopped at 0").
- **Fix:**
  1. In `BackingRepository.load`, refresh before clearing `loading`, or clear it in the same emit.
  2. In `_onPlayer`, set `loaded` from `player.loaded` whenever the repository reports one (`_itemOf(player.loaded)`), not only on `advanced`.
  3. Have `AppRuntime` call `backing.refresh()` on the looper's device or epoch change, so the reload starts when the interface comes back rather than at the next press.
  4. Add the probe as a test.

### Low

**L1. A recalled loaded item whose file is missing is dropped from the session at the next Save.**
- **Where:** in `recall` (`:339-346`), a failed `_load` calls `clear()`, which empties `loaded`. `capture` then writes `loaded: null`.
- **Why it matters:** when that item is not also prepared (allowed: Remove keeps the playing file), the session loses its only reference to it. #1198's repair row (`missingBacking`, by digest) can then no longer offer it, contrary to D9's "never dropped silently". A failure is reported at Open, but Save makes the loss permanent.
- **Fix:** keep the recalled `loaded` item as a Missing reference in the player's state, as the prepared rows are kept, until the performer clears it or loads something else. Capture it as it was.

**L2. The plan's Part 5 text still specifies a defaulting migration.** The text (plan `:811-814`) says the step defaults "an empty prepared list, nothing loaded, End Stop, level 1, pan 0, mask 0 and click pan 0, recorded as defaulted fields". The build record (plan `:1321-1328`) records the live-keeping departure. Rewrite the Part 5 text to the as-built rule, as was done for Parts 1 and 2, and add the "converted once, from what was live" sentence above.

## Notes

- **New Loop's stop is not wired.** `SessionBackingPort.stop` exists for Library Part 5 to call (plan build record). Nothing calls it yet.
- **The internal copier is sound.** It refuses `.` and `..` segments in the relative path, writes `<name>.part`, flushes (`RandomAccessFile.flush`), renames, and deletes the part file on any failure.

Verdict: Request changes (M1).

## Delta review (851f55374, PR #1258)

Model: Claude Opus (subagent), in-session

### Scope

- **Stack:** rebased onto trunk `890f04936`. P5 is now `ab65d323f` and `851f55374`, on P4 `908da2250`.
- **The fix commit `851f55374`** (5 files, +208/−14) answers M1 and L1.
- **Repository side:**
  - `load` ends with one `_refresh(clearLoading:)`, so the end of a load and the engine's answer arrive in one state;
  - `play()` refreshes first; while a restart's reload of the loaded file is decoding (`_reload`), Play waits for it and then plays.
- **Player side:**
  - `_onPlayer` takes the repository's loaded file as the truth, naming one it did not load from the store;
  - it no longer clears a loaded item that is marked Missing;
  - `play()` treats "selected and loaded" as loaded only while the repository holds or is loading a file;
  - `recall` keeps a loaded item that fails to load, as Missing, instead of clearing it.
- **Settings side:** `BackingMixFamily.retireLive`, which runs whenever the looper's mix generation moves (start, reopen, stop and session apply), re-applies the mix, and each setter refreshes the repository. So a restart is seen at once.
- **Schema:** 14 on this branch (Reverse took 13, so the step is now `13: _v13ToV14`), landing as 15. As asked, I judged only the step logic.

### Runs

**P5 head:**
- `dart analyze --fatal-infos lib test packages`: clean.
- `bloc lint lib test packages`: 0 issues.
- `backing_repository`: 41 passed. `session_repository`: 250 passed. `segno_engine`: 409 passed.
- App suite: 3,498 passed, 56 skipped, 1 failed. The failure was `test/control/foot_mixer_dispatch_test.dart` ("Custom saved hold enters Mixer…", expected `mixer`, got `custom`). It is a hold-timing test, ran under parallel load and is outside the backing code. Re-run alone, the file passed 3 times out of 3 (21 tests).

**The first review's probe** (`repro/p5_play_after_configure_probe_test.dart`), re-run on `851f55374`:
- After the 48 → 44.1 kHz configure and **one** Play, the engine is **Playing** item 2, the player still names `a.wav`, and no notice is shown.
- A second Play pauses it, which is correct.
- M1 is fixed.

**A new probe** (`repro/p5_pause_during_reload_probe_test.dart`) gates the restart's reload decode. Play, then Pause before the decode finishes: the engine ends **Playing**. See L3.

### Verified correct (traced)

**M1, the loaded file through a restart.**
- During the reload the repository reads "not loaded, loading" (the player keeps its item because a load is pending).
- At the end the single combined emit reports the file loaded and loading cleared, which matches the player's item.
- If the item had changed, `_onPlayer` adopts the repository's file, so a reload the player did not start keeps it named. That covers the old `_restarted`-only path.
- Save therefore captures the loaded item.
- The reload now starts on the restart itself, through `retireLive`. The new `app_runtime_test` pins that stop and start refresh the backing, and that an ordinary state change does not.
- A Play pressed before the reload finishes is queued on `_reload` instead of being spent.

**L1, a missing file stays named.**
- `recall` marks a loaded item whose load fails as Missing and keeps it as `loaded`. `_onPlayer` does not clear a Missing loaded item.
- `capture` therefore writes it, and #1198's repair row can still find it.
- An explicit Clear, or loading another file, still replaces it.
- A Play on it attempts a load and reports the failure again, rather than toggling a voice that is not there, because of the `held` check.

**The migration step (13 → 14 here, 15 at landing).**
- The step is unchanged: it fills `backing` and `clickPan` from the live setup, as described in the first review, and is now chained after Reverse's step.
- A v12 manifest runs Reverse's step (`reversed: false` per track) and then this one, so the order does not matter: they write disjoint keys.
- My earlier judgement stands: keeping the live setup is right under rules 1 and 3.

### Findings

#### Low

**L3. A Pause pressed while a restart's reload decodes is overridden by an earlier queued Play.**
- **Where:** `BackingRepository.play` (`backing_repository.dart`). The queued `reload.then(play)` runs whatever was pressed after it.
- **Scenario:** Play (queued on the reload), then Pause (`_transport(pause)` on an empty voice, a no-op). When the decode lands the file starts **playing** although the last press was Pause. Reproduced by the probe above.
- **Coverage:** Stop is safe, because it bumps the generation, so the reload's load returns false and the queued Play is skipped.
- **Owner rules:** rule 3 (the last press wins).
- **Fix:** record a `_wantPlay` intent that Pause, Stop and Clear reset, and check it in the `then`. Alternatively, have Pause cancel the queued Play.

### Verdict

Approve. M1 and L1 are resolved and verified with the original probe. L3 is a narrow corner.
