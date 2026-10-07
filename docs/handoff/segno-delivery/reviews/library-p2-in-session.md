Model: Claude Opus (subagent), in-session

# Review of PR #1193, Library Part 2 (#1178): the full-screen Library shell

**Branch:** `claude/library-1178-p2`, head 4d9074a27, base `claude/library-1178-p1` at 76096cfde.

**Scope:**
- `git diff origin/claude/library-1178-p1...origin/claude/library-1178-p2`;
- the PR body;
- the plan's Part 2 and the §2 item 5 departures;
- plan §4.3 (the port);
- #1177's plan §2.3 and Part 4, read from `origin/claude/usb-storage-1177-p3`. No `-p4` branch exists, and no `packages/storage_repository` exists yet on any #1177 branch.

**Design source:** `segno-ui.pen`, read through the pencil MCP. I did not edit or save it.
- 19/01 `HPb9F`, 19/03 `OltOM`, 18/06 `jsmae`;
- for accent buttons, also 19/02 `U2bRH`, 19/05 `lb1U1`, 18/01 `bx7vK` and 20/07 `KGCxw`.

I compared these against the three goldens on the branch.

**Runs at 4d9074a27:** I ran these in my own agent worktree with `SEGNO_ENGINE_LIB` from `build_test_lib.sh`, exported by a scratch script.

| Check | Result |
| --- | --- |
| `dart analyze --fatal-infos lib test packages` | No issues |
| `flutter test test/library test/session test/looper` | +1027, all passed |
| `flutter test test/app/view/app_test.dart test/screenshots/library_screenshots_test.dart` | +115 ~9, all passed (the screenshot goldens skip off the author's machine) |
| `session_repository flutter test` | +157, all passed |
| `bloc lint lib test packages` (scratch `git worktree add` under the scratchpad, removed after) | 0 issues in 836 files |

## Verified correct (traced)

1. **Selection never applies.**
   - `LibraryCubit` holds only `SessionRepository` (`listFolders`, `readPreview`), the volumes port and the pedal stream. It has no looper and no `SessionCubit`, so a row tap cannot reach the engine.
   - The only load is `LibraryPreviewFooter` calling `SessionCubit.open(id)`. It is disabled while the cubit is `working`.
   - **Open lands stopped:** that is `open`'s existing path. `blockStartForSessionBoot` runs around `applySession`, and nothing in the Library starts the transport.
   - Open keeps the Library on screen, as the retired dialog's "tapping a row loads it and the dialog stays open" did. The footer then flips to `Return to tracks`, and a test covers this with two pumps.
2. **The superseded-read guard.**
   - `select` bumps `_previewRequest`, emits the new id with the preview cleared, and drops a result whose request is stale or that lands after close.
   - `a superseded preview read never lands` exercises the real interleaving: the slow read completes after the fast one.
   - A new selection also clears a previous error.
3. **Search and folders.**
   - Search is a trimmed, case-insensitive substring of the display name.
   - `Unfiled` admits `folder == null`, which is a bundle at the root, legacy bundles included. `FolderSessions` matches the directory name.
   - Chips come from `listFolders`. If that read fails, the chips fall back to `All`/`Unfiled` and selection still works (tested).
   - The empty-catalog and no-match lines are distinct.
4. **USB without a drive.**
   - `InternalOnlyVolumes` reports no drive, so `USB` shows the 18/06-style notice and the preview keeps the internal selection, as listed.
   - Switching back to `Internal` restores the rows (tested).
5. **Footswitch return.**
   - Any `ButtonPressed` sets `dismissalRequested` once. Encoder deltas and releases are ignored.
   - The listener calls `popUntil(isFirst)` on the root navigator, which also pops the search keyboard sheet stacked above the Library (tested). The app-level test drives a real `PedalRepository` through `FakePedalLink`.
   - The encoder push is not a `PedalButton`, so activating a focused row cannot dismiss the page.
6. **Retiring the dialog: every entry point is repointed.**
   - At the base, `showSessionsManager` had exactly two callers, `stage_top_bar.dart:54` and `connectivity_banners.dart:91`. Both now call `openLibrary()`, and the duplicate-push guard is reset in `resetSegnoNavigatorForTest`.
   - `promptSaveAs` moved verbatim (case-sensitive since Part 1) to `session/view/session_name_prompt.dart`. `onSessionState` in `tracks_commands.dart:372` still opens it on `saveAsRequested`, so Quick Save with no session still prompts. That is covered by `session_name_prompt_test` (five cases) and by the cubit's `saveAsRequested` test.
   - `! grep -rn "sessions_manager\|showSessionsManager" lib` passes.
   - The `sessionsManagerTitle`, `sessionsEmpty` and `sessionManage` strings are gone from both ARBs. `sessionNewTitle` stays for the kept prompt. All 26 `library*` keys exist in `es`.
7. **The port.** These match #1177 §2.3/Part 4 exactly, in names and fields:
   - `RemovableVolumeStatus` with its six values;
   - `RemovableVolume` and its nine fields;
   - `StorageDestination.internal()` and `.removable(int generation)`;
   - `VolumeSpace{totalBytes, freeBytes}` and `WriteLease{target, purpose}`;
   - `ConflictPolicy{ask, keepBoth, replace}` and `NameConflict(existingPath)`;
   - `StorageFailure.{full, readOnly, volumeLost(generation), unsupported, io(reason)}`.

   `withWriteLease` adapts #1177's `acquire`/`release`, as plan §4.3 accepts.
8. **VGV.**
   - Layering is view → cubit → repository/port, and the port sits in `lib/library/application`.
   - Colours come from `context.surface` tokens.
   - No new widget takes pixel parameters; the only new frame parameter is `LoopSettingsFrame.tabs`, a `Widget`.
   - Every piece is an extracted widget class.
   - Cubit methods return `void` or `Future<void>`, and bloc lint is clean.
9. **Tests.**
   - Both stream-push widget tests ("an opened session…", "a refused Open…") pump twice.
   - No test awaits `sub.cancel()` inline. The cubit's `close` awaits its own cancels, which is production code, not a `testWidgets` body.
   - The geometry test pins the 709/1028 split. `app_test` covers the boot-recovery Open through the real `SessionCubit`.

## Findings

### 1. Medium: an Open that fails for any reason other than sample rate or schema version is silent in the Library

- **Where:** `library_preview_card.dart:176-186` maps only `sampleRateMismatch` and `unsupportedVersion` to a banner. Every other failure surfaces only through `showSessionOutcome`'s SnackBar on the Tracks `Scaffold` (`tracks_commands.dart:384-420`).
- **Trigger:**
  - Tap `Open session` while the open is refused by `StateError('audio device must be running before session load')`. That happens on the appliance whenever the interface is unplugged and the session has tracks.
  - Or by `audio device changed…`, `corruptLayers`, or an I/O error.
- **Impact:**
  - The Library is an opaque `desktopPageRoute` with no `Scaffold` (unlike `LoopSettingsPage:102`), so the SnackBar is hosted by the offstage Tracks scaffold.
  - The player taps Open, nothing changes, and no reason is shown. The stale message appears later, on return to Tracks.
  - The retired dialog was a barrier route over Tracks, so the same SnackBar was visible. Its own comment said "the other error kinds surface where their actions run (… snackbars)". This is a regression from retiring it. (Traced, not reproduced.)
- **Fix:** show every Open failure in the Library. Map the remaining `SessionError`s to `sessionErrorGeneric(errorMessage)` in the same `ConsoleBanner`, and tie it to the id that was opened (see 2). Wrapping `LibraryView` in a `Scaffold` is a smaller stop-gap, but it leaves the message detached from the row it concerns. Add a widget test that pushes a `failure`/`unknown` state.

### 2. Low: a refused Open's banner follows the selection onto other sessions

- **Where:** `library_preview_card.dart:176-186`. The condition is "the cubit is in `failure` and the previewed id is not current". It never checks which id failed.
- **Trigger:** Open `A` on a 96 kHz device when `A` was saved at 48 kHz, so the banner shows on `A`. Then select `B`.
- **Impact:** `B` shows "sample rate mismatch" although `B` was never tried and may open fine. The banner stays until the next `SessionCubit` action changes the status. The comment ("its reason shows on the session that refused, which is still selected") assumes the selection does not move.
- **Fix:**
  - Record the id at the call site: the `LibraryCubit` keeps `openingId` when the footer calls `open`.
  - Alternatively, have `SessionState` carry `failedId`.
  - Show the banner only when it equals the previewed id.
  - Extend the existing test to select another row and expect no banner.

### 3. Low: accent buttons at regular weight should be fixed in the shared button, not written back to the pen

- **Where:** `loop_settings_widgets.dart:461`. `LoopOutlinedButton` builds its label without a `fontWeight`, and the departure is listed in plan §2 item 5.
- **What the pen draws:** every accent-filled button is `fontWeight 700` in each screen I checked:
  - `New loop`, `Return to tracks` and `Open session` (19/01, 19/03, 19/05);
  - `Start new loop` (19/02);
  - `Use as backing` (18/01, 20/07).
- **Impact:**
  - Writing "regular weight" back to three Library buttons would make section 19 contradict sections 18 and 20, which stay bold.
  - The deviation is not specific to the Library. The same shared button renders all 15 accent call sites, including FX, pedal setup and MIDI.
- **Fix:** in `LoopOutlinedButton`, set `fontWeight: FontWeight.w700` when `tone == LoopButtonTone.accent`, and drop the item from the write-back list. This is one line, but it re-renders every accent button and the goldens that show one, so it suits a small separate PR landing before the pen write-back.

### 4. Low: the musical facts and track figures use the UI face; the pen draws them in the mono face (not a listed departure)

- **Where:**
  - `library_preview_card.dart:103-145`: `84 BPM`, `4/4`, `3 tracks`;
  - `:315-330`: `_TrackFact` values such as `2` and `4`.
- **What the pen draws:** `session-musical-meta` and `session-audio-facts` numbers are `JetBrains Mono` 21 (`lStgX`, `U5Wjez`, `hkkp7`, `DT3rC`). The units (`bars`, `layers`) are in the UI face.
- **Impact:** a visible type departure that neither the PR nor §2 item 5 lists. `SurfaceTheme.monoFont` exists and is used for numerics elsewhere (stage footer, top bar, FX editor).
- **Fix:** add `fontFamily: SurfaceTheme.monoFont` to those two styles.

### 5. Low: `savedDateLabel`'s today and yesterday branches are untested, and the deleted dialog tests covered them

- **Where:** `library_sessions_tab.dart:487-505`.
- **What changed:** the retired `sessions_manager_dialog_test` had "a session saved today reads as today, with the time" and "older saves read as yesterday, then as a short date". No library test exercises the `today HH:mm` or `yesterday` branches; the fixtures all use 7 Sep.
- **Impact:** a mutation of the day arithmetic or the `padLeft` survives. Because the function reads `DateTime.now()` directly, it is hard to test.
- **Fix:** inject `now` (as a parameter, or through the clock the repository already takes) and port the two retired tests.

## Nits

- **The disabled `New loop` stand-in is not on the write-back list.** The pen draws `New loop` enabled; the build dims it. Part 2's behaviour text says this is "recorded for the pen write-back", but neither §2 item 5 nor the PR's "Pen departures" list it.
- **The search placeholder colour differs from the pen.** It uses `textSecondary`; the pen's `Search sessions` is primary `#e7edf6` (`w14oC5`). That is defensible as placeholder styling, but unlisted.
- **`Open session` while busy has no visual cue.** It is inert but not dimmed. `LoopOutlinedButton` leaves dimming to the caller, and `New loop` is wrapped in `Opacity` but this button is not.
- **The port's `volumes` doc is narrower than #1177's stream.**
  - The doc says "the mounted, readable drives", but #1177 Part 4's stream keeps `ejected`, `unsupported` and `mountFailed` records. The cubit filters with `readable`, so behaviour is right; the doc should say "every drive the service reports".
  - With a present but unusable drive, the USB location would say "Connect a USB drive", which is the wrong copy for an unsupported drive. It is unreachable with `InternalOnlyVolumes`, so it only matters for #1177.
- **`InternalOnlyVolumes` refuses the internal destination too.** `copyFile` and `withWriteLease` throw `unsupported` for `StorageDestination.internal()`, but plan §4.3 says only a removable destination is refused. Nothing calls them in Part 2.
- **The port invents subclass names.** `InternalDestination`, `RemovableDestination`, `StorageFull`, `StorageVolumeLost` and the rest do not appear in #1177's spec. Expect a rename at the swap if #1177 names them differently.
- **`LibraryTrackStrip` takes its slot count from `TracksState` constants.** That imports the Tracks cubit's state into a Library view. It is harmless, but a shared constant would decouple the two features.
- **A row selected by search stays previewed after it is filtered out.** The preview card keeps showing a row the search has hidden. That is plausible behaviour, but untested.

## Design conformance summary

| Matches the pen | Listed departures | Unlisted | Systemic (not this PR) |
| --- | --- | --- | --- |
| Topbar geometry (Back 64 at x 36, Sessions tab 180x64 at x 124, Stage 113 at x 1771); title 42 at x 64; Internal/USB 160x64 with 12 gap; New loop 157x64; search 556x64; chips 56 tall at y 302; rows 699x148 starting at y 384; strip 8x(37x13) over 340; preview at x 829 (765 local), 820 tall, r14, padding 33; lanes 74 tall with track rows 150/162; footer 76 tall; button widths 235/208 | Audio tab; Manage, Listen and Back up to USB; New folder; empty and error copy; USB notice wording; regular-weight accent labels; no waveform; `7 Sep` | Mono numerics (4); disabled New loop; placeholder colour | Accent and selection palette (pen `#c4d4eb`/`#8496b0`/`#89a2c5` vs the app's bright `accent`/`accentSurface`); Arimo vs Inter. These come from the app theme tokens, which this PR uses correctly. |

The goldens are meaningful as layout references. They render the real fonts at 1920x1080 and show the three states the pen draws. However, they skip everywhere except the author's machine, so CI cannot catch a layout regression through them; the geometry test (`places the list and the preview on the pen grid`) is the one that guards layout in CI.

**Verdict:** Changes requested, for one Medium.
- Fix Finding 1 before this stack lands. Fix Finding 2 at the same time, since both touch the same banner and need to know which id was opened.
- Findings 3 to 5 and the nits can follow. For Finding 3, I recommend fixing the shared button rather than writing regular weight back to the pen.
- Everything else hunted is sound: Open lands stopped and selection never applies; the superseded-read guard holds; search and folder filtering are correct; the USB notice works; the footswitch closes stacked sheets; every entry point is repointed; Quick Save still prompts; and the port matches #1177.

---

## Delta review (fffdc7fca)

**Scope:**
- d5ff747f7: Part 2 rebased onto the new Part 1. `git range-diff 76096cfde..4d9074a27 12b90fcba..d5ff747f7` reports `=`, so the patch is identical to the 4d9074a27 I reviewed above.
- 2ca55e91d: review fixes.
- fffdc7fca: bold accent labels and 54 regenerated goldens.

**Setup:**
- Scratch worktrees at fffdc7fca and at the stack's trunk base c3714abc2, all removed afterwards.
- `SEGNO_ENGINE_LIB` came from `build_test_lib.sh`.
- `SEGNO_SCREENSHOT_FONT_DIR` was set to the SDK's material fonts. The external-pedal and MIDI suites skip without it, so CI and most local runs never execute them.

**Runs at fffdc7fca:**

| Check | Result |
| --- | --- |
| `dart analyze --fatal-infos lib test packages` | No issues |
| `flutter test test/screenshots` (fonts set) | +121 ~2, all passed |
| `flutter test test/library test/session test/looper/view/loop_settings test/app/view/app_test.dart` | +331 ~6, all passed |

## Earlier findings: status

1. **Medium, Open failures invisible behind the Library: fixed.**
   - `SessionState.failedSessionId` is set from `_run(subject: id)` on every failure path of `open`, including the early boot-recovery and load-in-progress refusals.
   - The preview card maps every error except `bootPersistence` to a banner, using `sessionErrorGeneric(errorMessage)` for the rest.
   - `bootPersistence` is left to the toastification `ControlSettingsNotice`, which is app-wide and so shows above the Library route.
   - Tests cover the audio-device-not-running refusal, and a failure of another action showing no Open banner.
2. **Low, banner following the selection: fixed.** The banner shows only when `failedSessionId == preview.summary.id`. The test now selects another row and expects no banner.
3. **Low, accent buttons at regular weight: fixed in the shared button**, as recommended.
   - `LoopOutlinedButton` uses w700 for `LoopButtonTone.accent` only.
   - `loop_outlined_button_test.dart` pins both the accent tone and the three other tones.
   - The item is dropped from the write-back list.
4. **Low, mono numerics: fixed.** Both the musical facts and `_TrackFact` use `SurfaceTheme.monoFont`, and a `type` test pins it.
5. **Low, `savedDateLabel` untested: fixed.** It takes an optional `now`. The two retired cases (today with the time; yesterday, then a short date) are ported.

**Nits:** each one is either fixed or recorded in plan §2 item 5.
- The disabled `New loop` is now listed.
- The search placeholder is drawn in the primary colour, as the pen draws it.
- `Open session` is dimmed while busy, and tested.
- The port's `volumes` doc now says "every drive the service reports". A plugged-in but unreadable drive gets its own notice with #1177's reason, tested for unsupported, mount-failed and ejected.
- `InternalOnlyVolumes` refusing the internal destination is documented as deliberate.
- The invented subclass names are documented as file-local.
- `LibraryTrackStrip` uses `kMaxTracks`, exported from the engine and equal to `LE_MAX_TRACKS` 8, the same as the old 4 × 2.
- A selection hidden by search or a chip reads as "nothing selected", and that is tested.

## The 54 regenerated goldens: rot or a hidden regression?

**Method:**
- I ran `external_pedal_screenshots_test.dart` and `midi_controls_screenshots_test.dart` with fonts at the stack's trunk base c3714abc2, before any Library commit.
- Exactly the 17 goldens the commit names fail there (11 `external_pedals_*`, 6 `midi_controls_*`), so the Library stack did not cause any of them.
- I then compared each master image with its test image.

**Nine are rot from intended trunk changes:**

| Goldens | Intended change |
| --- | --- |
| `midi_controls_connected`, `_disconnected`, `_paused`, `_unavailable` | The new `None` device button (788999121, #1101) |
| `midi_controls_click_destination`, `external_pedals_expression_destinations` | The new `Loop controls` destination tab |
| `external_pedals_expression_controls` | The longer control list (Overdub decay, Loop length) |
| `external_pedals_controls_pick` | That list's scrollbar |
| `midi_controls_mixer_gains` | Live-input volume reads `50%`/`100%` instead of `-27.0 dB`/`+6.0 dB` (623a5a7ba, #1124: live input is now a 0–100 % linear range by plan) |

**Eight show a real regression, which the regeneration has now baked in.** These are:
- `external_pedals_controls`, `_controls_parameter`;
- `_click_held_released`, `_decay_held_released`, `_playback_held_released`;
- `_expression`, `_mixer_expression`, `_mixer_pan`.

In each, the control row's value (`On`, `Held`, `−17.1 dB`, `31%`, `—`) has moved from the row's right edge to the middle of the card. That is D-1 below.

## Findings

### D-1. Low: the golden regeneration recorded a trunk layout regression in the control rows as the new baseline

- **Where:** `lib/control/view/pedal_setup/control_row_list.dart:152`, which is on trunk and not Library code. Commit 8749688c5 ("feat(control): share record length across input controls") wrapped the value in `Flexible`.
- **Cause:** the name column is `Expanded` (flex 1), and the value is now `Flexible` (flex 1, loose). The row gives each half the free width, so the value starts at the card's midpoint.
- **What it should be:** the widget's own doc says "What it is doing, on the right", and the earlier goldens drew it there.
- **Trace:** the 8 goldens listed above, before and after, with the `On` label at x ≈ 1756 in the master and x ≈ 1368 in the test image of `external_pedals_controls`. The regenerated goldens at fffdc7fca now show it centred.
- **Impact:**
  - Every pedal and MIDI control row on the appliance draws its value in the middle of the card.
  - The only check that could catch this (the opt-in, font-gated goldens) now asserts the regression.
  - No data risk.
- **Fix:** keep the `Flexible` (it stops long values overflowing), but right-align the value inside it:
  - `Flexible(child: Align(alignment: AlignmentDirectional.centerEnd, child: AppText(...)))`;
  - or give the value `textAlign: TextAlign.end` under `FlexFit.tight`.

  Then regenerate those 8 goldens. This belongs in a small trunk PR, not in #1178. Until then, the commit message should say that 8 of the 17 record a known regression rather than call all 17 "already differed".

## Notes

- **Raw exception text:** the generic Open banner shows the raw exception text, for example "Bad state: audio device must be running before session load". The most common refusal on the appliance, the interface unplugged, deserves its own localized line. This copy existed before, so it is not a finding.
- **The SnackBar behind the Library:** for any failed Open it is still queued on the offstage Tracks scaffold and appears on return. That is now redundant with the in-Library banner rather than the only signal.

**Verdict (delta):** Approve.
- The Medium and all four Lows are fixed and tested.
- Every nit is resolved or recorded.
- D-1 is a trunk regression that this commit's golden refresh hides, not one it introduced. Fix it in trunk and regenerate the 8 goldens.

---

## Delta review (c46c81a33)

Model: Claude Opus (subagent), in-session

**Scope:** Part 2 rebased onto trunk 56033baf0. `git range-diff c3714abc2..fffdc7fca 56033baf0..c46c81a33` shows:
- b487f0773: identical (`=`).
- 9b3464281: the review-fix commit, changed only in a rebase comma in the `looper_repository.dart` export list (`kTrackEffectParams,` now that the trunk adds a name after it).
- c46c81a33: the bold-accent commit, which **no longer regenerates the 17 external-pedal and MIDI goldens**. It regenerates 37 goldens and leaves those 17 at the trunk's versions, as delta finding D-1 asked. The commit message now says so.

**Runs:**

| Check | Result |
| --- | --- |
| Whole app suite at p5 (cd721f202), fonts set | +3493 ~8 -17 |
| The two font-gated screenshot files at trunk 56033baf0, fonts set | exactly the same 17 goldens fail (11 `external_pedals_*`, 6 `midi_controls_*`) |
| `git diff 56033baf0 cd721f202` over those 17 files | untouched by the stack |

So every golden the stack touches passes, and the only failures are the trunk's own control-row regression. No regression from the Library stack hides among them.

## Findings

None.

## Notes

- The trunk has since moved to 7a9fdcbd9, which fixes the control-row layout and regenerates goldens. A trial `git merge-tree` of p5 onto it reports binary conflicts in 5 goldens that both sides regenerated:
  - `external_pedals_count_in_expression`;
  - `external_pedals_count_in_held_released`;
  - `external_pedals_hear_click_held_released`;
  - `external_pedals_record_length_held_released`;
  - `external_pedals_record_timing_held_released`.

  These are mechanical: take either side, then regenerate those 5 with fonts set, so each carries both the bold label and the right-aligned value.

**Verdict (delta):** Approve.
