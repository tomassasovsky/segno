Model: Claude Opus (subagent), in-session
# Review of claude/library-1178-p6b (60d1a112b): Library Part 6b (#1178), Listen and lane peaks

## Scope

Diff `f148fa201..60d1a112b` (34 files, +1446/-61): commits c76cdfe7a "feat(library): Listen plays a session's preview, and the lanes draw its peaks" and 60d1a112b "docs(library): the plan's Listen reads through the engine's one decoder and #1198's parts". f148fa201 merges p6a (the native audition voice), which is reviewed separately; here I checked only how p6b uses its Dart seam (`EngineAudition.auditionStartFile` / `auditionStop` / `auditionState`) and the new `filePeaks`.

Reviewed against: the plan `docs/plan/2026-10-06-feat-library-sessions-plan.md` (D10, D11, "Part 6b as built", Part 6b success criteria), AGENTS.md, the owner rules, and the pen `segno-ui.pen` (01 CURRENT UX, section 19 `BYESA`: 19/01 `HPb9F`, node `session-listen` `JxpRu` and the `session-audio-preview` lanes `OAJIj`; section 18 `JvDpn` for the Preview/Stop vocabulary). Pen read only through the pencil MCP; not saved.

Files traced: `lib/library/cubit/library_cubit.dart`, `library_state.dart`, `lib/library/view/library_page.dart`, `library_preview_card.dart`, `new_loop_sheet.dart`, `packages/session_repository/lib/src/session_repository.dart` (`startAudition`, `stopAudition`, `auditionState`, `readPeaks`, `readPreview`, the mixdown writer), `packages/segno_engine/lib/src/native_audio_engine.dart` (`auditionStartFile`, `filePeaks`, `_decodeAudition`, `_filePeaks`), `packages/segno_engine/src/core/engine_audition.c`, both ARBs, the new and changed tests, and the 9 changed goldens.

## Runs

All in a scratch worktree at 60d1a112b, with `SEGNO_ENGINE_LIB` from `packages/segno_engine/tool/build_test_lib.sh` and `SEGNO_SCREENSHOT_FONT_DIR` set.

| Command | Result |
|---|---|
| `flutter pub get` | ok |
| `bash packages/segno_engine/tool/build_test_lib.sh` | built `segno_engine_test.dylib` |
| `flutter test test/library` (includes the real-engine `listen_engine_test.dart`) | 137 passed |
| `flutter test test/screenshots/library_screenshots_test.dart` | 9 passed, goldens unchanged (`git status` clean) |
| `packages/session_repository`: `flutter test` | 260 passed |
| `packages/segno_engine`: `flutter test` | 386 passed |
| `dart analyze --fatal-infos lib test packages` | No issues found |
| `bloc lint lib test packages` | 0 issues, 876 files, exit 0 |

Probe tests (temporary files, removed afterwards) against the mocked repository and the page:

| Probe | Observed |
|---|---|
| 44.1 kHz session, 48 kHz engine, capped preview (`frames = 120 * 48000`) | `LibraryListen.frames ~/ sampleRate` = 130, so the readout shows `x / 2:10` beside "Preview plays the first 2:00" |
| Listen A (decode held), select B, Listen B; B lands, then A lands | cubit calls `stopAudition()` while `state.listen.id == 's-b'` (log `[start a, start b, stop]`) |
| Two Listen taps during one decode | `startAudition` called twice; the second tap starts a second decode instead of cancelling |
| Start accepted but never reported playing | after five polls `listen == null` and no `stopAudition()` was sent |
| `clearSelection()` while Listen plays | `selectedId == null`, `preview == null`, `listen.id == 's-a'`, no stop |
| Page: track 1 already recording, Listen, then track 2 enters recording | `stopAudition()` never called |

Mutations (each applied alone, the relevant suite run, then reverted):

| # | Mutation | Suite | Result |
|---|---|---|---|
| M1 | Open does not stop Listen (`openWithConfirm`) | test/library | killed ("Open stops it first") |
| M2 | Drop the Listen request counter (`request != _listenRequest`) | test/library | killed ("a start that lands after a stop is stopped") |
| M3 | Drop the peaks request counter in `_readPeaks` | test/library | **survived** |
| M4 | Never show the 2:00 notice | test/library | killed |
| M5 | Peaks from `layers.first` (L0) instead of the live layer | session_repository | killed (`readPreview` pins `track0_lane0_L2.wav`) |
| M6 | `select()` stops Listen even for the playing session | test/library | **survived** |
| M7 | No grace polls before the start lands | test/library | killed |
| M8 | Recording listener does nothing | test/library | killed |
| M9 | Footswitch press does not stop Listen | test/library | killed |
| M10 | `clearSelection()` drops `listen` without stopping | test/library | **survived** (neither behaviour is tested) |
| M11 | Lanes never receive peaks | test/library | killed |

## Verified correct (traced)

- Peaks read the lane-0 live layer: `readPreview` takes `lane0.layers[lane0.undoCount].file` (the live index, `session.dart:140`), `readPeaks` checks the name against `_layerFilePattern` and existence before handing it to the engine, and the existing `readPreview` test pins `track0_lane0_L2.wav` for `undoDepth: 2` (mutation M5 killed).
- No decode on the UI isolate: `startAudition` goes through `auditionStartFile`, whose decode runs in `Isolate.run` (`_decodeAudition`, bounded by `kAuditionMaxSeconds * rate`); `filePeaks` runs `le_backing_probe_file` in `Isolate.run` with only `buckets` floats allocated. Nothing in the diff uses `wav_codec` to decode. The only UI-isolate file work is `File.existsSync` checks.
- Waveform is real or absent (D11): `_Lane` draws `CustomPaint` only when `peaks != null`; a track whose read returns null or throws is left out of `state.peaks` and draws the clip box only. The painter clamps to 0..1 and draws nothing for zero peaks. Page tests cover both branches; M11 (peaks never reach the lane) is killed.
- Stale preview reads: `_readPeaks` checks `isClosed || request != _previewRequest` after every track; `copyWith(clearPreview: true)` also clears `peaks`, so a new selection never shows the old peaks during its read.
- Listen ends on the cubit-side triggers: new selection of another session, footswitch press (before the dismissal check), Listen again, and `close()` (route pop by Back, Stage, Return to tracks or footswitch). Open (`openWithConfirm`, after the confirm) and New loop (`startNewLoop`, after the confirm) call `stopListening()` before the session action, with `verifyInOrder` tests. Engine-side ends (performance arm, Cut sound, configure/reopen, natural end) read as `frames == 0` and end Listen at the next poll once it was seen playing.
- A start that lands after `stopListening()` or after `close()` stops itself (`request != _listenRequest` / `isClosed`), and M2 is killed.
- Timer: one periodic timer per started Listen, cancelled in `_endListen` and again in `close()`; `_pollListen` returns when closed or not listening. I found no path that creates a second timer while one runs (a second `listen()` that reaches the timer line requires `request == _listenRequest`, which the earlier call no longer matches).
- Refusals map as the seam documents: `notRunning` -> "Connect an audio device to listen.", `alreadyRunning` (perf armed, `engine_audition.c:66`) -> "Not while a performance is recording.", `notReady` after p6a's one retry -> "The last preview is still stopping. Try again.", anything else or a thrown error -> "This preview cannot be played." A refusal clears on the next Listen or selection.
- The 120 s notice: `truncated` comes from the decoder's `info.truncated`; the line shows while that preview plays (M4 killed). A file at another rate is converted by the decoder, not refused, matching the as-built plan; no refusal copy is needed for a rate mismatch.
- l10n: all 8 new keys are in `app_en.arb` (with descriptions and placeholders) and `app_es.arb`.
- Accessibility: `LoopOutlinedButton` wraps its content in `Semantics(button: true, label: ...)`, so the control reads "Listen"/"Stop" as a button; the progress text is plain text.
- Cubit API: `listen()` returns `Future<void>`, `stopListening()` returns void; bloc lint is clean.
- `LooperBloc` is provided app-wide (`app.dart:505`), so the new page listener resolves on the real Library route; the connectivity test now provides it too.
- Goldens: all 9 regenerated Library goldens differ only by the Listen button in the facts row and the drawn peaks in each lane (plus the new `library_listen.png`). I compared `library_selected` before and after and opened `library_listen`, `library_usb_disconnected` and `library_save_failed`; the changes are the intended ones. The `library_save_failed` lane 3 clip at the bottom predates this branch (the 19/05 layout is 60 px shorter and the list scrolls).
- The docs commit is consistent with the as-built code (the engine decoder is the one reader, rate conversion instead of refusal, #1198 parts for recordings).

## Findings

### High

None.

### Medium

**M-1. The Listen readout uses the session's saved rate, but the frames it divides count at the engine's rate.**
`lib/library/cubit/library_cubit.dart:159` sets `LibraryListen.sampleRate` from `state.preview?.sampleRate`, which is the rate the session was recorded at (`SessionPreview.sampleRate`, the mixdown's own rate). `AuditionStart.frames` and `AuditionState.position` are at the engine's rate: the decoder converts (`le_backing_decode_file(path, rate, ...)` with `rate = snapshot().sampleRate`, `native_audio_engine.dart:2478-2483`; `AuditionStart.frames` is documented as "frames at the engine's rate"). `library_state.dart:95` even documents `sampleRate` as "The rate [frames] and [position] count at", which is not what is stored.
Failure scenario: a session saved at 44.1 kHz previewed on a 48 kHz device: a capped preview reads `0:00 / 2:10` next to "Preview plays the first 2:00" (probe confirmed 130 s). A 48 kHz session on a 96 kHz device reads double: a 30 s mixdown shows `1:00` total and the clock runs at twice real time. The as-built plan explicitly allows other rates ("converted by the decoder, not refused"), so this is a supported path. The tests never use differing rates (the cubit test's preview and the start both imply 48 kHz).
Fix: carry the rate the frames count at with the start (for example an `engineRate`/`rate` field on `AuditionStart`, filled from the `rate` `auditionStartFile` already reads) and use it in `LibraryListen`; add a cubit test with a 44.1 kHz preview on a 48 kHz start.

**M-2. A superseded start still reaches the engine, replaces the preview that is playing, and the cubit then stops it.**
`auditionStartFile` calls `le_engine_audition_start` as soon as its decode returns (`native_audio_engine.dart:2497`); the cubit only learns the start is stale afterwards and then sends `stopAudition()` (`library_cubit.dart:141-146`). There is no way for the cubit to cancel between decode and start.
Failure scenario: select session A with a long mixdown and press Listen (on the Pi the 2:00 decode and conversion takes a noticeable time); select session B, a short loop, and press Listen. B decodes first, starts and shows `Stop` with progress. A's decode then lands: the engine replaces B with A (A is audible), the cubit sees the stale request and sends `stopAudition()`, the voice goes silent, and the next poll ends B's Listen. The user pressed Listen on B and hears a fragment of A followed by silence. Probe confirmed the cubit calls `stopAudition()` while `state.listen.id == 's-b'`. The same mechanism makes a second tap during a decode start a second decode rather than cancel (no in-progress state; probe: two `startAudition` calls), which on the appliance holds two 2:00 buffers at once, and a Library close during a decode lets the stale start sound for a block before the stop.
Fix: give the start a cancellation check that runs after the decode and before `le_engine_audition_start` (for example `startAudition(id, {bool Function()? stillWanted})` passed through to `auditionStartFile`, which frees the buffer and returns a `cancelled` result when it reads false), and show a starting state on the button so a second tap stops instead of starting again. Add the A-then-B ordering as a cubit test.

### Low

**L-1. The recording trigger only fires when the rig goes from no capturing track to some capturing track.**
`lib/library/view/library_page.dart:136-139` uses `!previous.tracks.any(isCapturing) && current.tracks.any(isCapturing)`. D10 says Listen ends when "any track entering recording".
Failure scenario: track 1 is overdubbing (started from MIDI or sound-start, which do not dismiss the Library); the player presses Listen (nothing refuses it), then track 2 enters recording. No transition from "none" is seen, so Listen keeps playing. The probe page test confirmed `stopAudition()` is never called. Audio isolation is not affected (the lane capture reads inputs), so this is the trigger contract, not a recording leak.
Fix: fire when any channel's `isCapturing` goes false -> true (compare per track), and either refuse Listen or end it at the first poll while a track is capturing.

**L-2. When the cubit gives up on a start that never reported playing, it does not send a stop.**
`lib/library/cubit/library_cubit.dart:186-187`: after five polls without `playing`, `_endListen()` clears the state but leaves the queued `LE_CMD_AUDITION_START` in the command ring. `le_engine_audition_start` accepts the start whenever `a_configured` is set (`engine_audition.c:56-73`), whether or not the callback is running.
Failure scenario: the device stalls (configured, callback not running) when Listen is pressed; after 500 ms the button returns to `Listen`; if the callback resumes without a configure or reopen (which would free the queued buffer), the preview plays with no `Stop` on screen. Probe confirmed no `stopAudition()` is sent on this path. Owner rule 2 (fail safe) favours sending the stop.
Fix: call `_sessions.stopAudition()` in the never-seen-playing branch before `_endListen()` (it is a no-op when nothing plays).

**L-3. `clearSelection()` keeps Listen playing with no control on screen.**
`lib/library/cubit/library_cubit.dart:216-227` copies `listen: state.listen` into the cleared state. The Listen/Stop control lives inside the preview body, which is not shown without a selection.
Failure scenario: no session is open, the player selects a saved session, presses Listen, then deletes that session from Manage; `_reselect` finds neither the selection nor a current session and calls `clearSelection()`. The deleted session's preview keeps playing for up to 2:00 with nothing on screen to stop it except leaving the Library. Probe confirmed `listen.id == 's-a'` with `selectedId` and `preview` null.
Fix: call `stopListening()` in `clearSelection()` (then the copied `listen` is always null and the field can go).

**L-4. Listen is offered for sessions that have no mixdown and then refused with failure copy.**
`startAudition` returns `EngineResult.invalid` when `mixdown.wav` is absent (`session_repository.dart:694-698`), and the save writes no mixdown when every lane is muted or the rig is empty (`session_repository.dart:1209-1222`, `_mixdown` skips muted lanes). `LibraryListenControl` is shown for every preview, including `no tracks`.
Failure scenario: select the empty `New loop 2` (or a session whose tracks are all muted) and press Listen: a failure-tone banner says "This preview cannot be played." for a session that is simply silent. That reads as damage, not as an empty session.
Fix: hide or disable Listen when the preview has no unmuted tracks, or give the "no mixdown" case its own neutral copy (both ARBs).

**L-5. The pen's Listen button has a leading icon; the build drops it without recording the departure.**
Pen 19/01 `session:listen` (`M2LaUZ`, 160 x 64) holds a 28 x 28 `ui-icon` at x 28 (`Iy2ST`) before the `Listen` label at x 67.5; every `session:listen` instance in section 19 (five screens: `blYnT`, `a0Nsfa`, `TRrZo`, `F45PLM`, `M2LaUZ`) has the same icon. `library_preview_card.dart:666-671` builds a label-only `LoopOutlinedButton`, although the widget has `leadingIcon`. The plan's "Pen departures" (section 2, item 10) lists `Stop`, the readout, the 2:00 line, the banners and the waveform style, but not the missing icon.
Fix: pass the pen's glyph as `leadingIcon` (and a stop glyph for `Stop`), or add the departure to the plan and write it back into the pen.

**L-6. Untested behaviour that the code gets right today (surviving mutations).**
- M3: removing the `request != _previewRequest` check in `_readPeaks` (`library_cubit.dart:117`) survives; then session A's peaks can land on session B's lanes (keyed by channel) after a fast reselect. Add a test that holds A's `readPeaks`, selects B, completes A and expects B's peaks only.
- M6: making `select()` always stop Listen survives. `_reselect` calls `select()` with the same id after every successful session action (for example an automatic save), so such a regression would end Listen on every save. Add a test that reselecting the playing session keeps Listen.
- M10: `clearSelection()` with Listen playing has no test either way (see L-3).

**L-7. Every 100 ms progress tick rebuilds the whole preview card and the session list.**
`LibraryPreviewCard` (`library_preview_card.dart:31`), `LibraryPreviewTracks` (`:267`) and `LibrarySessionRows` (`library_sessions_tab.dart:344`) `watch` the whole `LibraryState`, so each `listen.position` emit rebuilds all session rows and all track rows ten times a second for as long as Listen plays (only `LibraryListenControl` uses `select`). On the Pi this is avoidable UI-thread work during audio playback.
Fix: `select` the fields each widget uses (selection, preview, peaks, refusal, `listen?.id`/`truncated`), leaving only `LibraryListenControl` to follow `position`.

## Notes

- Listen keeps playing while another route covers the Library (for example `openDeviceSettings` from a connectivity banner, or the update banner's `openUpdateSettings`), because the cubit lives until the Library route pops. The plan says "navigation"; if that means any screen change rather than leaving the Library, a `RouteAware` stop would be needed. Not ranked as a finding because the plan text is ambiguous.
- The "Preview plays the first 2:00" line appears only while the preview plays, and inserts 36 px above the track list, shifting the lanes down when Listen starts and back when it ends. That matches "Part 6b as built" but is a layout jump the pen does not show (the pen has no playing state for 19/01).
- `Stop` as the button's accessible name is generic; "Stop preview" (as a `semanticLabel`) would be clearer to a screen reader. Cosmetic.
- The peaks are 256 fixed buckets drawn as filled bars in the accent token; the pen draws a smooth `#9eb9dc` path. The plan records this departure.
- The appliance success criterion (Listen audible, absent from a performance take and from a loop recorded during Listen) is hardware-gated and was not exercised here.

**Verdict:** Request changes

---

## Delta review (04977d09e, PR #1264)

Model: Claude Opus (subagent), in-session (a direct review, no sub-agents)

**Scope:** 04977d09e, "Listen counts at the engine's rate and a superseded start never reaches the voice", checked against M-1, M-2 and L-1 to L-7 above.

**Runs:** a scratch worktree at 1d296cf34 (p8, which contains this commit unchanged), removed afterwards. `SEGNO_ENGINE_LIB` and the fonts were set.

| Check | Result |
| --- | --- |
| Whole app suite | +3714 ~8 -1 |
| The one failure | `library_cubit_test` "a preview never seen playing ends after five polls" (L-B below). Alone, the file passes (+41) |
| `segno_engine` | +388, all passed |
| `session_repository` | +273, all passed |
| `dart analyze` | No issues |
| `bloc lint` | 0 issues in 897 files |

**Mutations** (each reverted). All are caught:

| Mutation | Result |
| --- | --- |
| The Listen clock at the session's rate | caught |
| The native `stillWanted` check removed before the start | caught by `audition_test.dart` "a start its caller withdrew while it decoded never reaches the voice" |
| `clearSelection` keeps Listen | caught |

## Earlier findings: status

- **M-1, fixed.** `AuditionStart.rate` carries the engine's rate, read before the decode, and the clock divides by it. The mock reports its configured rate too.
- **M-2, fixed.**
  - The cubit marks the press with `starting` and hands `stillWanted` (its request counter) to `startAudition`.
  - The native seam asks it after the decode and again before the retry, and frees the decoded buffer when the answer is no.
  - The engine therefore never receives a superseded start.
  - A start that was accepted and is then superseded can only be seen after the synchronous `le_engine_audition_start` returns. That is handled by the existing stop, and no user event can run in between.
  - A second press while starting withdraws the request without a `stopAudition` (nothing reached the voice).
  - The isolate body is a top-level function, so the closure no longer captures `stillWanted`.
- **L-1, fixed for the case reported.** `trackStartedCapturing` fires for any channel newly capturing.
- **L-2, fixed.** A start never seen playing sends `stopAudition` when the cubit gives up.
- **L-3, fixed.** `clearSelection` ends Listen.
- **L-4, fixed.** `SessionPreview.hasMixdown` hides Listen.
- **L-5, fixed.** A leading play glyph (and a square for Stop) stands for the pen's icon, and the plan says so.
- **L-6, fixed.** Tests were added for stale peaks and for reselecting the playing session.
- **L-7, fixed.**
  - The card and the row list select `state.withoutListen`, which is equal across progress ticks.
  - The lanes select only their own fields.

## Findings

### L-A. Low: Listen can still start while a take records

- **Where:** `library_cubit.dart` `listen()`.
- **The gap:** the engine refuses an audition only while a performance is armed. Starting Listen while a loop take records is accepted, and `trackStartedCapturing` only ends a Listen that was already playing when a track starts.
- **Impact:** the preview plays over a take in progress. D10's "ends on any track entering recording" is about the other order, but the plan does not say this order is allowed.
- **Fix:** refuse with `LibraryListenRefusal.performanceArmed`'s sibling ("a take is recording") when `LooperBloc` shows a capturing track, or note the case in the plan.

### L-B. Low: the poll tests depend on wall-clock timing

- **Where:** "a preview never seen playing ends after five polls" uses a real `Timer.periodic`.
- **What happened:** it failed once with the suite under parallel load (Listen still `starting`), and passes alone.
- **Fix:** run it under `fakeAsync`, or inject the poll clock.

**Verdict (delta):** Approve. M-1, M-2 and every Low are fixed and pinned. L-A and L-B are small.
