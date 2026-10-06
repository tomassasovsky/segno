# Library and Sessions: full-screen Library, explicit Open, identity, New Loop

Tracking: #1178 (M5 items E7-1..E7-6 of the 2026-10-06 gap inventory),
`stage:plan`, `autonomy:merge-gate` (a redesign of a user-facing surface plus
one new native voice: verifiable here, but taste and blast radius are the
owner's). Base: `origin/claude/segno-integration` at `c3714abc2`. Unless a
branch is named, every `file:line` below is on that head. Precedent for the
format: `docs/plan/2026-10-05-feat-engine-reopen-plan.md`.
Status: approved 2026-10-06 with required review edits E1-E8, which are
applied in this text (the review and the coordinator's preservation decision
are recorded in section 3 and section 8).

Owner decisions applied (planner brief, 2026-10-06): the settings tray and the
Bluetooth page are retired (not this plan's work; this plan stops adding to
them); DAW export is kept and re-homed under Library > Audio; computer-facing
USB gadget mode is out of scope. The USB storage service (#1177) is planned in
parallel; this plan consumes it only through an interface it defines itself
(section 4.3) and ships a no-USB default, so every part here is mergeable
before #1177 lands.

## 1. Current boundary (verified, pre-change)

- **The Library is the earlier Sessions dialog.** The stage's Library mark
  (`lib/looper/view/stage_top_bar.dart:52-54`) opens `showSessionsManager`,
  a 744-wide `ConsoleDialogShell` (`lib/session/view/sessions_manager_dialog.dart:21-37`,
  `:150-244`) with a load-on-tap row list (`:252-300`) and an action row of
  Rename, Duplicate, Delete, Save as, Save (`:305-356`). The same dialog is the
  target of the cleared-reopen banner's `Sessions…` action
  (`lib/looper/view/connectivity_banners.dart:87-91`) and of the quick Save's
  `saveAsRequested` prompt (`lib/looper/view/tracks_commands.dart:371-375`).
  Its footswitch dismissal lives in `SessionsManagerCubit`
  (`lib/session/cubit/sessions_manager_cubit.dart:19-33`). Two app tests reach
  it by key (`test/app/view/app_test.dart:1312-1314`, `:3490-3493`) and
  `test/session/view/sessions_manager_dialog_test.dart` (553 lines) covers it.
- **Session identity is the folder name.** `SessionSummary` is name-only
  (`packages/session_repository/lib/src/models/session_summary.dart:12-27`);
  the name IS the slug and is "read straight from the directory listing"
  (`session_repository.dart:330-350`). Rename moves the directory
  (`:367-379`), Duplicate copies it (`:385-398`), Delete removes it (`:417-422`).
  The manifest (`Session`, schema `formatVersion = 11`, `models/session.dart:847`)
  carries no display name and no folder, and `Session.fromJson` refuses any
  other version (`:752-760`). There is no automatic naming: `SessionCubit.save`
  with no open session emits `saveAsRequested` and the UI prompts
  (`lib/session/cubit/session_cubit.dart:164-175`).
- **Load is one apply path and already lands stopped.** `SessionCubit.loadNamed`
  (`session_cubit.dart:231-384`) reads the bundle, disarms performance capture,
  checkpoints the mix store, releases held pedal bindings, blocks start for the
  session boot and calls `LooperRepository.applySession`
  (`packages/looper_repository/lib/src/looper_repository.dart:3729-3824`),
  whose private body clears every track destructively, resets the per-track
  settings that survive a clear, imports and commits (`:3826-4100`). Recall
  publishes recorded tracks stopped since #1134 (`docs/PROGRESS.md:57-69`).
  Nothing preserves the outgoing rig and nothing confirms a playback
  interruption: a tap on a row loads immediately (`sessions_manager_dialog.dart:297`).
- **A session without audio can be applied at any device rate**
  (`session_repository.dart:541-575`; `applySession` checks the device only
  when `rig.tracks.isNotEmpty`, `looper_repository.dart:3734-3739`), and
  `_importSessionAudio` returns at once for an empty rig (`:4253-4262`). This
  is the seam New Loop reuses.
- **The save already writes a flattened preview.** Every save writes
  `mixdown.wav`, every unmuted lane's live layer summed at its level, balance
  and track fader (`session_repository.dart:495-504`, `:802-833`;
  `docs/design/session-bundle-format.md` "Layout"). Nothing plays it: the
  engine has no file or preview voice. The click is the only generated voice
  and it is summed before the output buses (`engine_process.c:6563-6579`);
  the performance tap sits inside `output_bus_frame` (`:6580-6586`,
  `perf_tap_master_pair` `:4004-4009`) and the master gain and limiter run
  after it (`master_bus_frame` `:6588-6589`, `:4096-4130`). Engine paths in
  this document are under `packages/segno_engine/src/core/` unless a `src/test`
  path is given. `save` writes `mixdown.wav` only when the mix is non-empty and
  `_pruneOrphanLayers` never touches it (`session_repository.dart:495-511`), so
  a re-save of an emptied rig leaves the previous mixdown on disk.
- **Legacy exports.** `SessionRepository.exportMixdown`/`exportStems`
  (`session_repository.dart:593-628`) and `SessionCubit.exportMixdown`/
  `exportStems` (`session_cubit.dart:104-115`) have no caller outside the cubit
  and its state enum (`session_state.dart:37-41`; `tracks_commands.dart:389-391`
  only localizes the outcomes). The DAW export that IS reachable is the
  performance completion sheet's **Re-export** (`performance_completion_sheet.dart:345-353`),
  which calls `PerformanceRecorderCubit.reExport` (`performance_recorder_cubit.dart:592-635`)
  to write `project.als` and `fx-chains.txt` into the finished capture bundle
  through `daw_export` (`:637-656`), where the user cannot reach them. The
  capture bundle already holds the main output and one stream per captured
  input (`performance_repository.dart:979-1000`); #1198 (plan D3, PR #1205)
  writes them as ordered 32-bit float WAV parts that the sidecar's `parts`
  list names, and this plan reads them only through that list.
  `DawManifestReader` reads `performance.json`
  (`packages/daw_export/lib/src/manifest_reader.dart:28`), so `.als` is
  capture-only; a session bundle has no DAW project.
- **Storage facts are internal only.** `ConsoleFactsClient.exportDestination`
  returns `''` on every real platform (`packages/console_facts_client/lib/src/local_console_facts_client.dart:116-121`);
  only the fake mounts `/media/usb0` (`fake_console_facts_client.dart:28`).
  There is no removable-drive service; #1177 plans it.
- **Full-screen pages share one frame and one navigator.** Settings, FX,
  Loop settings and Audio routing are pushed on the root navigator through
  `desktopPageRoute` with a duplicate guard (`lib/app/segno_navigator.dart:62-185`,
  `lib/theme/page_transitions.dart:47-58`) and draw inside
  `LoopSettingsFrame(crumb, title, onBack, onStage, children)` on the pen's
  1920 x 1080 canvas (`lib/looper/view/fx/fx_page.dart:765-783`). Stage pops
  to the first route (`:765-768`).

## 2. Design source

The pen is `segno-ui.pen`, group `01 CURRENT UX`, read through the pencil MCP.
Screens this work must match (node ids in parentheses):

| Pen screen | What it fixes |
|---|---|
| 19/01 `Session library` (`HPb9F`) | The shell: topbar `Back` 64 x 64 at x 36, crumb tabs `Sessions` / `Audio` 180 x 64 (`t5LjWd`), `Stage` 113 x 64 at the trailing edge; title `Library`; actions `Internal` / `USB` 160 x 64 segment and `New loop` 157 x 64 accent (`ROjjJ`); a 709-wide session list (`gicQQ`: `Search sessions` 556 x 64, `New folder` 144 x 64, folder chips `All` / `Unfiled` 56 tall, rows 699 x 148 with title, meta line and the eight-slot mini track strip) and a 1028-wide preview card `#171a20` r14 (`WUvgE`: name + `Manage` 137 x 64, `84 BPM · 4/4 · 3 tracks` + `Listen` 160 x 64, per-track lane rows 952 x 74 whose clip width is the track's length share, footer `15 FX · 0 backing tracks`, `Back up to USB` 220 x 64, `Return to tracks` 235 x 64 accent). |
| 19/03 `Session recall / Selected` (`OltOM`) | A non-current row selected: its meta reads `7 Sept · 3 tracks`, the current row reads `Current session`, the footer action becomes `Open session`. Selection previews; it does not load. |
| 19/02 `New loop / Keep current session` (`U2bRH`) | The New loop sheet: "`Evening loop` stays in your Library. Keep your effects, tempo and pedal setup." `Cancel` / `Start new loop`. |
| 19/06 `New loop / Ready` (`uRKTE`) | The stage after New loop: header `New loop 2`, four empty tracks, tempo `84.0 BPM 4/4` kept, `MULTI` kept, `00:00:00`. |
| 19/04 `Session name` (`cPmYI`) | Rename and Save as use the fixed bottom keyboard sheet with `Cancel` / `Done` (the existing `showConsoleRenameSheet`). |
| 19/05 `Session save / Storage error` (`lb1U1`) | The failure banner in the Library: "Could not save your current loop. Nothing was changed." |
| 34 `Backup in Library`, `Inline copy progress`, `USB session list`, `Matching backup name`, `Restored session selected`, `Retry an interrupted copy` (`npwR1`, `mdwSD`, `C0Mogf`, `ZECDn`, `f2sBAc`, `vzH8N`) | Sessions > USB: `Back up to USB` with inline progress and `Cancel`; the USB list (`Session` / `Saved` columns, `Restore to Library`, "Adds a new session to Library."); name match `Cancel` / `Keep both` / `Replace`; a restored copy named `Evening loop (2)`; interruption "USB drive disconnected. Nothing was changed." `Cancel` / `Retry`. |
| 18/01 `Audio library / Internal` (`bx7vK`), 18/06 `USB disconnected` (`jsmae`), 20/07 `Export a recording` (`KGCxw`), 20/09 `Matching filename`, 20/10 `Connect USB drive`, 20/11 `Export storage error`, 20/12 `Export complete` | The Audio tab geometry (title `Audio library` with the sub-nav row `Prepared audio` / `Save audio` / `Record performance` (`Lr5u5`), `Internal` / `USB drive`, `Search audio`, a 1061-wide file list with group headings such as `Performances`, a 684-wide preview card with kind, name, waveform, a `Preview` control and actions) and the USB export dialogs (20/12 has `Show on USB` and `Done`). |

Only the Sessions tab, the Audio tab's `Performances` and `Sessions` groups
with Export to USB and the re-homed DAW export, and section 34 are in this
plan. 18/02-18/05 and 18/07-18/15 (prepared audio, backing, Save audio, track
import) are E7-7..E7-10.

**Deviations the build must write back into the pen** (a shipped departure is
a design change; this plan does not edit the pen):

1. `Manage` opens a titled options sheet (the `showFxOptionsSheet` idiom,
   `lib/looper/view/fx/fx_options_sheet.dart:24-29`) with `Save`, `Save as…`,
   `Duplicate`, `Rename`, `Move to folder…`, `Delete`. The pen draws the button
   but not the sheet. Section 34's tiles label the same button `Rename`; the
   build follows 19/01.
2. The Audio tab's preview gains a `DAW project` action for a performance
   recording (the owner's re-home of the `.als` export), and its `Export to
   USB` offers two packages for a recording (the single WAV, or the DAW
   package: the whole bundle). The pen's four actions (`Add to prepared`,
   `Export to USB`, `Use as backing`, `Use in loop`) stay where they are; the
   two that belong to E7-7/E7-9 are not drawn until those parts exist (no
   disabled stand-ins for features that do not exist).
3. The Audio tab's sub-nav row (`Prepared audio`, `Save audio`, `Record
   performance`) belongs to E7-8, E7-10 and E7-11; this plan draws the title
   row without it until those parts exist. The pen's audio preview button
   reads `Preview`; the build uses `Preview` on the Audio tab and `Listen` on
   the Sessions tab, as drawn. 20/12's `Show on USB` is not built: there is no
   file browser on the appliance to show it in; `Done` alone closes it.
4. A `Sessions` group under Library > Audio lists each saved session's
   mixdown (E1 of the review): the pen has group headings (`Backing tracks`,
   `Performances`) but not this one.
5. Part 2 as built (until the later parts add what is missing):
   - The topbar draws only the `Sessions` tab, and the preview card has no
     `Listen` or `Back up to USB` (`Manage` and `New folder` arrive in
     Part 3).
   - The search box opens the keyboard sheet (19/04's idiom) titled
     `Search sessions`, since the console has no keys.
   - The empty catalog, a search with no match, nothing selected, a session
     without audio and an unreadable session each get one line of copy that
     the pen does not draw. A selection the search or a chip hides reads as
     nothing selected.
   - A refused Open shows a failure banner above the lanes of the session
     that refused, and only there: the sample-rate and newer-version texts,
     or the generic session error with its reason (the pen draws none).
   - The USB location without a drive uses 18/06's notice with
     "Your internal sessions are still available." and Lucide's `usb`
     glyph, and the preview card keeps the internal selection. A drive that
     is plugged in but unreadable gets "This USB drive can't be used" with
     #1177's reason ("`HFS+` isn't supported. Format the drive as exFAT.",
     or a failed mount).
   - `New loop` is drawn disabled until Part 5 builds it; the pen draws it
     enabled.
   - The preview card sits at x 765 but is 1027 wide: the pen's 1028 runs
     one pixel past its own 1792 layout.
   - Saved dates read `7 Sep` (the English locale data), not the pen's `7 Sept`.
   - Preview lanes draw the clip without a waveform (D11, until Part 6b).
6. Part 3 as built (`lib/library/view/library_manage.dart`; its tests are in
   `test/library/view/library_page_test.dart`):
   - `Manage` opens the options sheet (deviation 1) for the selected
     session: `Save`, `Save as…`, `Duplicate`, `Rename`, `Move to folder…`,
     `Delete`, with `Delete` dimmed on the open session. On a session that
     is not open, the two save rows say whose rig they save, since they act
     on the live rig (D5): `Save New loop 2`, `Save New loop 2 as…`, or `Save
     the current loop` when no session is open. `Manage` is also drawn for a
     session whose preview cannot be read, so it can still be renamed, moved
     or deleted.
   - Save as, Duplicate and Rename ask for the name on the app's shared
     console keyboard sheet, titled `Session name` with a subtitle naming
     the action (`Save as new session`, `Duplicate as…`, `Rename session`);
     New folder and Rename folder use it titled `Folder name`. That sheet
     replaces 19/04's whole layout, not only its buttons: it is much
     smaller (a title of about 18 pt against the pen's 30, keys of about 16
     against 26), with `Cancel` at the top right and `Save` where 19/04 has
     `Done`. A name that is invalid (including one shaped like a session
     id), taken, or refused by the cubit is answered inside the sheet, which
     stays open.
   - `Move to folder` is a second options sheet: `Unfiled`, each folder and
     `New folder…`, with where the session already is dimmed. The pen draws
     none of it.
   - A long press on a folder chip opens `Rename folder` and `Delete
     folder`; Delete is dimmed while a session is filed in the folder, asks
     first, and the repository still refuses a folder holding anything
     ("That folder still holds sessions. Move them out first."). The pen
     draws neither.
   - Delete asks first with the console's confirm dialog (`Delete "name"?`);
     the pen draws no confirmation.
   - The 19/05 line is drawn in the failure token (`rec`), not the pen's
     `#efbea0`. Besides the pen's save failure it reports a refused delete
     ("The open session cannot be deleted."), a folder that still holds
     sessions, and any other failed catalog action ("That did not work. Try
     again."); an Open's refusal stays on its preview card. It reports only
     failures of actions taken while the Library is open; any but a failed
     save goes once another row is selected.
   - "Nothing was changed" is true of a failed write-back too: a save over
     an existing bundle writes a whole new bundle beside it
     (`<id>.saving`) and swaps it in with two renames (the previous one
     steps aside as `<id>.old` until the new one is in place). A failure
     before the swap leaves the previous save as it was; a power cut between
     the renames is undone on the next catalog read, which puts `<id>.old`
     back (Part 3 review, finding 1).
   - The automatic name is `New loop N` in every language: a name is the
     session's data, not interface copy. So the Spanish UI shows a `Nuevo
     loop` button beside sessions named `New loop N`.
   - Decision (rule 4, D4): the quick Save's name prompt is removed rather
     than repointed to the Library. A Save with no open session now saves
     as `New loop N` and the toast says so ("Saved as New loop 2"), so
     nothing is left to prompt for; naming is Rename in Manage. The
     power-off flow's own Save-as prompt is outside this plan and stays.

7. Part 4 as built:
   - `Open session` while a track plays, records or overdubs asks with the
     console's confirm dialog: "Stop playback and open <name>?", "Your
     current loop stays in your Library.", `Cancel` / `Open`. The pen draws
     no such dialog; the body line is ours.
   - Opening the session that is already open does nothing. The Library
     never offers it (its footer reads `Return to tracks`), and reloading it
     would discard its unsaved edits.
   - The D7 fingerprint is `SessionRepository.fingerprint`: the manifest a
     save would write, from the same capture, with each lane's layers
     replaced by `AudioEngine.trackAudioRev` (a new `SessionIo` read over
     `le_engine_track_audio_rev`; the snapshot is unchanged). A save records
     the fingerprint taken just before its own capture, so an edit landing
     in between costs one more save later, never a skipped one.
   - The reference is recorded after every save and open, and as a boot
     baseline once the app's settings have loaded
     (`SessionCubit.recordBaseline`, from `AppRuntime.start`). When the two
     cannot be compared (no baseline, or a capture that cannot run while a
     setting awaits recovery), the outgoing rig is saved only when it holds
     recorded audio: the part nothing else brings back is kept, an untouched
     rig is not saved, and an Open that resolves a recovery notice still
     works.
   - An unnamed rig preserved as `New loop N` becomes current at once, so a
     target refused after the save leaves the saved rig open under its new
     name.
   - A failed preservation shows the 19/05 line, not a refusal on the
     target's preview card.
   - Stopping an audition on Open belongs to Part 6, which builds Listen.
   - Review fixes (PR #1215): the fingerprint keys each track on its audio
     revision and on whether it is capturing, never on playing or stopped,
     so a session that was only played is not saved again. An Open first
     ends every take in progress with the record control's Stop (at its
     Record timing) and waits until none captures, so the take is saved
     with the outgoing session as the dialog promises; a take still
     capturing after 20 s refuses the Open with its own line ("The take has
     not finished yet. Nothing was changed; try again when it has."), and
     nothing is saved, opened or cleared. During a settings recovery the
     capture cannot run, so a rig holding audio cannot be preserved and the
     Open is refused as a failed save: the safe side.
   - A real-engine test drives a real `SessionCubit` with the real
     fingerprint (`test/session/open_preserves_engine_test.dart`): the
     round trip of the plan's criterion, a played-and-stopped session not
     saved again, a recording take and an overdub kept.
8. Part 5 as built:
   - `SessionCubit.newLoop()` is the one method a foot binding (E6-9) will
     call. Inside `runExclusive` it preserves the outgoing rig (D7),
     releases a held momentary (its values belong to the outgoing rig, not
     to the chains the new loop keeps), captures the live settings and
     chains, mints the next `New loop N` id, applies the empty rig through
     the apply path Open uses (`_applyRig`, the former body of `_open`), and
     then saves that empty rig under the new id, which becomes current.
   - The empty rig is `rigForNewLoop(SessionRepository.liveSession(...))`:
     `liveSession` is the manifest a save would build, without tracks, and
     `Session.forNewLoop()` names every field it keeps, so Open and New loop
     map settings through the same `rigFromBundle`. The field-table test
     builds a `Session` with every manifest key away from its default and
     pins the exact key list, so a new field fails it until its New loop
     fate is written into `forNewLoop`. `name` is dropped too: the new loop
     takes its own.
   - The transforms reset inside the apply, with the clear: lane mutes go
     with the tracks, Fade returns to unity and Reverse to forward with the
     material (`LE_CMD_RESET_TRANSFORMS`, pushed on import). The real-engine
     test checks all three. **Speed and Transpose are not built yet: their
     resets attach to this same apply path (the engine's transform reset or
     `applySession`) when E6-4 and E6-5 land**, not to a Library-side list.
   - A failed preservation applies nothing and mints no id. A refusal before
     the apply gives the minted id back. If the empty rig cannot be written
     after the apply, the new loop stays started and current under its new
     name, the Library shows its generic failure line, and the first Save
     writes the bundle.
   - The sheet (19/02) always asks. The current session's name is drawn
     brighter, as the pen does; a loop with no name yet reads "Your current
     loop stays in your Library." (our copy; the pen always has a name).
     The before strip fills the tracks holding audio, the after strip is
     empty. A started new loop returns to the stage (19/06), whose header
     names it; an Open still stays in the Library.
   - Pen departures: the sheet uses the theme's card, strong border and
     accent tokens rather than the pen's `#202735`, `#6d6d6d` and muted
     `#89a2c5` strip fill; the encoder-focus ring the pen draws on `Cancel`
     is not drawn (the Library has no encoder focus yet).
   - Review fixes (PR #1216): New loop ends a take in progress first and
     saves it with the outgoing session, as Open does (Part 4's fix), and a
     played session is not saved again. When the empty rig cannot be
     written, the failure is its own (`SessionError.newLoopNotSaved`): the
     Library returns to the stage, which says "New loop N started, but it
     could not be saved yet. Save it to keep it." The real-engine cubit test
     covers New loop from a played session and with a take recording.
9. Part 6a as built (`claude/library-1178-p6a`, based on the backing
   player's Part 2, #1200 PR #1223, which must land first):
   - The engine has one audio-file decoder, the backing player's
     (`engine_decode.c`: WAV and MP3; FLAC is compiled out until the
     vendored miniaudio carries the fix for CVE-2024-41147; band-limited
     rate conversion). A preview is its bounded read:
     `le_backing_decode_file(path, rate, 0, LE_AUDITION_MAX_SECONDS * rate)`
     keeps the first 120 s and sets `info.truncated`. **A preview at another
     rate is converted, not refused**, so the plan's rate-mismatch refusal
     is gone, and the app has no Dart decode path: `wav_codec` writes files
     and models headers and parts only.
   - The voice uses the backing player's buffer type (`le_backing_buffer`)
     and its hand-back: the callback returns a buffer it will never read
     again through an `a_audition_dead` slot and the control thread frees it
     in `le_engine_audition_state` (the collect point), before every start,
     at configure, reopen and destroy. Its registry is its own
     (`LE_AUDITION_MAX_BUFFERS` 2), so a preview never takes a backing
     slot or budget; a start replacing a preview while the one before is not
     yet handed back reads `LE_ERR_NOT_READY`. This replaces the plan's
     `a_audition_ack` generation.
   - The mix point is the plan's: after the output-bus loop (whose pre-level
     tap is the performance capture), before `master_bus_frame`; a disabled
     jack is never written. Commands 136 (`AUDITION_START`) and 137
     (`AUDITION_STOP`), this part's range in the numbering ledger; raw posts are
     refused. A performance arm and Cut sound end the preview on the audio
     thread; a start while armed reads `LE_ERR_ALREADY_RUNNING`. State is a
     dedicated `le_engine_audition_state` (like the backing's), not snapshot
     fields. Stop with the callback stopped does not free at once: the
     buffer is freed at the next configure or reopen, as the backing's are.
   - Dart: the `EngineAudition` role (`auditionStartFile`, `auditionStop`,
     `auditionState`). The decode runs in `Isolate.run`, which opens the
     library itself (`openSegnoEngineLibrary`); the buffer comes back as an
     address. One retry after `auditionRetryWait` on `notReady`.
10. Part 6b as built:
   - `SessionRepository.startAudition(id)` plays the bundle's `mixdown.wav`
     on output pair 0 (no mixdown: refused before the engine);
     `stopAudition`, `auditionState`; `readPeaks(id, track)` reads the lane-0
     live layer's peaks with the decoder's streaming probe
     (`le_backing_probe_file`, no PCM kept) through a new
     `EngineAudition.filePeaks`, in `Isolate.run`.
   - `LibraryCubit.listen()` toggles; it polls `auditionState` every 100 ms.
     Listen ends on a new selection, a footswitch press and when the page
     closes (cubit); before Open and New loop and when a track starts
     recording (page); on a performance arm and a device reopen the engine
     ends it and the poll reads it gone. A start that has not landed yet is
     given five polls.
   - Pen departures: 19/01 draws `Listen` only. `Stop`, the `0:12 / 2:00`
     readout beside it, the `Preview plays the first 2:00` line and the
     refusal banners (no preview, no device, a performance armed, still
     stopping) are ours. The waveform is one filled bar per peak in the
     accent token, where the pen draws a smooth path in `#9eb9dc`.
   - Review fixes (#1264): the clock counts at the engine's rate, which the
     start now reports (`AuditionStart.rate`), not the session's saved
     rate. Each press is one request: `startAudition` hands the engine a
     `stillWanted` check that it asks after the decode and before each
     start, so a start the player withdrew, or that a later selection
     superseded, never reaches the voice; the button reads `Stop` while the
     preview decodes, and a second press withdraws it. A start never seen
     playing is withdrawn from the engine when the cubit gives up on it.
     Dropping the selection ends Listen. Any track entering recording ends
     it, not only the first. A session without a mixdown (an empty or
     all-muted mix) shows no `Listen` (`SessionPreview.hasMixdown`). The
     button carries a leading play glyph (`Stop` a square), standing for
     the pen's 28-point icon, whose path the pen MCP does not expose.
11. Part 7 as built:
   - **Recovered takes are listed and kept** (owner decision): the
     `Performances` folder lists the takes boot recovery moved under
     `recovered/`, marked `Recovered` in the row and the card, beside the
     others. Removing the 30-day prune is #1198 Part 2's change; this part
     lists what is there and adds the only delete, the recording's `Delete`
     (confirmed; refused while a take is being recorded, finalized or
     rendered, and through the guard table during a shutdown).
   - **Parts.** The listing reads a take's audio from the sidecar's `parts`
     list in stream and index order, and a take written before that format
     as its single `master.wav` and `live-input-<n>.wav`. Until #1198
     Part 5 (`TakePart`, `PerformanceManifest.parts`) is on the trunk,
     `CapturePart` in `performance_repository` reads the same JSON with the
     same checks; it is replaced by `TakePart` when that lands. `Preview`
     plays the first main-output part; the waveform spans every main-output
     part in proportion to its length. `Recording only (WAV)` writes one
     `<name>.wav`, or a multi-part take as consecutive
     `<name> · Part 001.wav`, `Part 002.wav`... files.
   - **The DAW package** is the parts, the rendered `stems/dry` and
     `stems/wet` files the Live Set points at, `project.als` and
     `fx-chains.txt`, copied keeping their paths so the Live Set opens on
     the drive. `DAW project` and the package write the project through
     `writeDawProject` (`lib/performance/application/daw_project_export.dart`),
     which the capture pipeline also calls.
   - **All or nothing on the drive.** Loose files are removed if a later one
     fails; a package or a stems set is copied into a hidden `.segno-export`
     directory and renamed into place once complete. `Keep both` picks one
     free `<name> (n)` for every file of the export. `Replace` on a package
     moves the old directory aside until the new one is in place.
   - **The delete guard.** A recording's delete enters `sessionWrite` on
     the bundle's path: the guard table has no kind for a recording
     delete, and `sessionWrite` refuses during a shutdown and over the same
     item, which is what a delete needs. A `recordingWrite` kind is the
     owner's call if one is wanted.
   - Pen departures: the top of the browser lists the two folders
     (`Performances`, `Sessions`) with a file count; the path row reads
     `Internal` there. The search filters the open folder. The USB location
     shows 18/06's notice or an empty list (browsing a drive's audio is not
     this part). 20/12 has no `Show on USB` (deviation 3). The chooser and
     the line's read-only, failed-export, DAW-project and delete texts are
     ours.

## 3. Decisions

Owner decisions are repeated inline above. The rest are taken under the
standing rules (1 preserve installs, 2 fail safe, 3 no silent change,
4 consolidate, 5 drop uncertain native state with a notice); the build
records any departure.

Owner answers recorded from the plan review (2026-10-06): (1) Save with no
identity saves as `New loop N`, no prompt (D4 stands). (2) Open and New loop
preserve by saving first (D7 stands); the review's note that an unnamed rig
without recorded content is not preserved is superseded by the coordinator's
decision under rule 2, written into D7: any rig with unsaved changes since its
last save, open or New loop is preserved, whatever kind of change, and an
unchanged rig is not re-saved. (3) The DAW project action lives on the
recording preview under Library > Audio and the completion sheet's Re-export
goes now (D13), amended by review edit E1 so that the mixdown, the stems and
the `.als` all remain reachable.

- **D1 Identity is a directory id; the name is manifest metadata.** A bundle
  is `sessions/[<folder>/]<id>/`. New bundles take `s-YYYYMMDD-HHMMSS`
  (plus `-2`, `-3` on a same-second collision), the convention
  `performance_slug.dart` already uses for captures. An id is taken when
  any directory at the root or one level down has that name (a bundle, a
  folder, an interrupted save, a reservation), and `newSessionId` creates
  the bundle directory when it issues the id, so a same-second Save as and
  Duplicate, or a folder named like an id, cannot share a directory; a save
  that then writes nothing gives the empty directory back
  (`releaseSessionId`) (Part 1 review, finding 1). An empty directory named
  like a minted id is a reservation, never a folder, so one a crash leaves
  behind shows no chip; `createFolder` refuses such a name. A Duplicate whose
  copy fails removes its own partial copy (delta review D1), and it writes
  the copy's manifest last, so a copy cut short by a power cut is a hidden
  interrupted save rather than a listed half copy (delta review D2). The
  manifest gains an
  optional `name` field read leniently; absent, the name is the directory
  basename, which is exactly what every existing bundle shows today (rule 1,
  one line, no migration pass). `formatVersion` stays 11: a bump would turn
  every installed session into `SessionUnsupportedVersion`
  (`session.dart:756-760`). Rename rewrites `name` only (accepted 6.2,
  "Rename is metadata-only"); it never moves audio. It writes the manifest
  to `session.json.tmp`, flushes it and renames it over `session.json`, so a
  power cut leaves the old name or the new one, never a torn manifest that
  cannot be opened (Part 1 review note).
  **Name collisions are case-sensitive (decided under rule 1, Part 1 review
  finding 3).** Save as, Duplicate and Rename refuse a display name another
  session carries exactly, and accept one that differs only by case. Before
  this plan the name was the directory, and the appliance's ext4 is
  case-sensitive, so `Song` and `song` could both be saved; refusing that now
  would turn a Save as that worked into an error, and installs may already
  hold such pairs. Automatic names (D4) still skip numbers case-insensitively,
  which never refuses anything and keeps `New loop 2` from appearing beside
  `new loop 2`.
- **D2 Folders are directories, one level.** `sessions/<folder>/` with no
  manifest is a folder; bundles directly under the root are `Unfiled`. Move
  is a same-filesystem `rename`. No index file (rule 4: the filesystem is the
  one truth; `session-bundle-format.md` already says the manifest is the only
  truth inside a bundle). An empty folder persists until deleted from
  `Manage`; the folder chips are the directory list, nothing else. A
  manifest-less directory that contains layer WAVs (`track*_lane*_L*.wav`) or
  `mixdown.wav` is an interrupted save, not a folder: it is excluded from the
  chips and from the catalog, and left in place (rule 2; cleaning it up is
  E7-19's transaction work). Deleting a folder is therefore refused while
  any directory inside it holds anything, an interrupted save included, not
  only while it holds a bundle (Part 1 review finding 2).
- **D3 Listing reads the manifest leniently.** `listSessions` today never
  parses a manifest so that a newer-version bundle still lists
  (`session_repository.dart:330-335`). The row now needs name, tempo,
  signature, track count and saved time, so the summary reads those keys from
  the decoded JSON map directly, not through `Session.fromJson`; a bundle
  whose manifest does not parse still lists by basename with `unreadable`
  set, and the preview panel shows the existing localized refusal
  (`sessionErrorUnsupportedVersion`, `sessionErrorSampleRate`) when selected.
- **D4 Automatic names.** `New loop N`, N the smallest positive integer not
  used by any catalog name (case-insensitive). `Save` with no identity no
  longer prompts: it saves under the next automatic name and the toast names
  it (`Saved as New loop 2`); `Rename` is one tap away in `Manage`. The
  `saveAsRequested` outcome and its prompt path are removed (accepted 6.2,
  "automatic names make naming optional").
- **D5 Save, Save as, Duplicate are three operations on two things.** `Save`
  writes the live rig back to the current identity. `Save as` writes the live
  rig under a new identity and makes it current. `Duplicate` copies the
  **selected saved** bundle under a new identity and leaves the current
  pointer alone. All three are the existing repository methods with ids in
  place of names (`session_repository.dart:385-398`, `:451-511`). A duplicated
  bundle's manifest is rewritten with the new `name` (a copy that still
  carried the source's name would list under it); the same holds for a
  restored backup (Part 8).
- **D6 Delete protection.** `Delete` is disabled in `Manage` for the current
  session, and `SessionCubit.deleteSession` refuses it too (the cubit is the
  authority, the sheet is fast feedback). Nothing else needs protecting yet:
  every bundle owns its audio files (duplicate copies them); the first shared
  reference arrives with backing (E7-7/E7-8), which must then add a
  reference check before deleting an audio item. Recorded as a non-goal.
- **D7 Preserve outgoing work by saving it (coordinator decision, rule 2).**
  `Open` and `New loop` first save the outgoing rig whenever it has unsaved
  changes since its last save, open or New loop: recorded content, FX, mixer
  or any other rig edit. A named rig is saved to its identity; an unnamed rig
  is saved under an automatic name. An unchanged rig is not re-saved, so a
  fresh untouched rig writes nothing and a fresh rig with an FX edit becomes
  `New loop N`. A failed save stops the operation before anything else changes
  (19/05, rule 2). Change detection is a **fingerprint**, not a dirty flag:
  `SessionCubit` runs the same capture a save runs
  (`SessionSettingsCoordinator.capture`, inside `runExclusive`), builds the
  manifest JSON the save would write (`_sessionFrom`, no file I/O) with each
  track's layer list replaced by its per-track content revision
  (`le_engine_track_audio_rev`, `segno_engine_api.h:2892-2895`, exposed on
  `AudioEngine` and on the `LooperState` track in Part 4 if it is not already)
  and the pedal remap string, and compares it with the fingerprint recorded
  after the last successful save, open or New loop. Equal means unchanged.
  Settings, chains, mix, routing, pedal remap and audio are all inside that
  JSON, so no edit can escape it; the capture itself is what a save does
  first, so an unchanged rig costs one capture and no write.
- **D8 Interruption confirm.** `Open session` while any track is playing or
  capturing (`LooperState.tracks.any((t) => t.state == TrackState.playing ||
  t.isCapturing)`, `packages/looper_repository/lib/src/models/track.dart:222`)
  asks `Stop playback and open <name>?` with `Cancel` / `Open`.
  `TransportState.isRunning` is the audio device being open
  (`models/transport_state.dart:43-44`), not playback, and must not be the
  predicate. `New loop` always asks (19/02). Neither asks when every track is
  stopped or empty. Restored transport starts stopped (#1134).
- **D9 New loop is `applySession` of an empty rig.** The new rig keeps every
  manifest field except `tracks` (none), `baseLengthFrames` and `loopBars`
  (0: an empty rig with a grid would lock the next take's length, the hazard
  `session_repository.dart:733-739` already names), `primaryTrack` (-1; the
  crown dies with the content) and `laneMix` (per captured lane). It keeps
  every other manifest key: `tempoBpm`, `tempoSource`, `tsNum`, `tsDen`,
  `syncTempo`, `quantizeDiv`, `looperMode`, `recordTiming`, `overdubDecay`,
  `defaultOneShot`, `defaultLengthPresetBars`, `defaultFadeDurationMs`,
  `trackFadeDurationOverrides`, `trackRecordTimingOverrides`,
  `trackOverdubDecayOverrides`, `trackOneShotOverrides`,
  `trackLengthPresetOverrides`, `clickMode`, `clickOutputMask`, `clickVolume`,
  `countInBars`, `recDub`, `autoRecord`, `defaultMultiple`, `trackLevels`,
  `trackPans`, `laneInputs`, `laneOutputs`, `laneCounts`, `inputSetup`,
  `outputSetup`, `monitors`, `laneChains`, `trackChains`, `outputChains`,
  `allTracksChain`, `pedalBindings`, `sampleRate`, `channels` (all of them
  owned settings per `settingsFromLooper`, `lib/session/session_mapping.dart:103-135`,
  or the live chains). The apply path
  already forgets lane mutes with the clear and resets Fade with the material
  (`looper_repository.dart:3884-3885`, `LE_CMD_RESET_FADE` applied at `engine_process.c:3159`,
  `segno_engine_api.h:516`). Reverse (E6-1) has landed and resets with the
  material too (`LE_CMD_RESET_TRANSFORMS`). Transpose and Speed do not exist
  yet; when E6-4/E6-5 land their reset belongs in this same apply path, not
  in a Library-side list. The new identity is created at once by saving the
  empty rig (manifest only, no audio), so the stage header reads `New loop 2`
  (19/06) and the Library lists it as `Current session`.
- **D10 Listen is a native audition voice fed from `mixdown.wav`.** The
  accepted behavior wants audition isolated from the rig and not loading the
  session (6.3). The engine owns the only output device, so the voice must be
  native. It is one interleaved buffer the control thread publishes and the
  callback sums into one output pair **after** the output-bus loop (so after
  the performance tap, and untouched by any output bus's level or mute) and
  **before** the master bus, so stems and `master.pcm` never contain it and
  only the master gain and limiter shape it (`engine_process.c:6580-6589`).
  **The voice is bounded**: `kAuditionMaxSeconds = 120`, so the buffer is at
  most 120 s x rate x channels floats (46 MB at 48 kHz stereo, 23 MB for a
  mono mixdown). **The engine's decoder is the app's one audio reader**
  (rule 4): `le_backing_decode_file` decodes every file the Library plays or
  draws, in `Isolate.run`, reading at most that many frames from disk and
  setting `info.truncated`, and its streaming probe `le_backing_probe_file`
  gives the peaks without keeping PCM. `wav_codec` is only the writer and
  the header and part model; it decodes nothing for the Library. The panel
  says `Preview plays the first 2:00` when the file is longer. A
  `mixdown.wav` is an LCM period and a recording part can be 2 GB; neither
  may be read whole on the UI isolate. A streamed ring (the perf ring's shape
  reversed) is the upgrade if a longer audition is ever wanted; not this plan.
  A file at another rate is converted by the decoder, not refused (Part 6a,
  as built). Audition ends on navigation,
  on `Open`, `New loop`, performance arm, any track entering recording, and a
  device reopen or reconfigure (#1158: configure frees the buffer, so the
  cubit ends Listen when `audition_frames` reads 0 before the progress reached
  the end). For a performance recording the same voice plays the first
  main-output part of the take's `parts` list (#1198).
- **D11 The waveform is real or absent.** Preview lanes draw peaks decoded
  from the lane-0 live layer WAV (`track{c}_lane0_L{undoCount}.wav`) in an
  isolate; until Part 6 lands, lane rows draw length only (the clip's width
  share), never a placeholder waveform (accepted 6.3, "missing waveform data
  is explicit").
- **D12 USB through a port shaped like #1177.** The Library depends on
  `RemovableVolumes` (section 4.3), an interface this plan defines in the app
  layer with the exact model shapes of #1177's `storage_repository`
  (`claude/usb-storage-plan-1177` section 2.3 and Part 4), with
  `InternalOnlyVolumes` as the shipped default. #1177's `StorageRepository`
  implements the port directly or through a one-file adapter; until then the
  `USB` segment shows the pen's "Connect a USB drive" state (18/06) and every
  USB action is unavailable with that reason. File copies to a drive go
  through the port's `copyFile` (the `.part` + fsync + rename protocol and the
  `Keep both` suffixing live in #1177, once); this plan's repositories keep
  only bundle-level orchestration. Directory listing of a drive stays here
  (#1177's Part 4 names it this plan's). No fake drive outside tests.
- **D13 DAW export moves; mixdown and stems exports are re-based on saved
  bundles (review E1).** The completion sheet's `Re-export` button,
  `PerformanceRecorderCubit.reExport`, `isReExporting` and `reExportFailed`
  are removed; the `.als` and `fx-chains.txt` writer becomes a shared
  app-layer function the capture pipeline and the Library > Audio `DAW
  project` action both call, and `Export to USB` on a recording offers the
  DAW package (the take's parts in the order its `parts` list gives them,
  the rendered `stems/dry` and `stems/wet` files the Live Set points at,
  `project.als`, `fx-chains.txt`) or the recording alone (its main-output
  parts, a multi-part take as consecutive files). `.als` stays
  capture-only. The live-rig `SessionRepository.exportMixdown`/`exportStems`
  (`session_repository.dart:593-628`) are not deleted but re-based on a saved
  bundle: `exportMixdown(id, destination)` copies the bundle's `mixdown.wav`,
  `exportStems(id, destinationDir)` copies each lane's live layer
  `track{c}_lane{l}_L{undoCount}.wav` as `track{c}_lane{l}_L0.wav`; the two
  `SessionCubit` methods and outcomes that exported the live rig are removed
  (unreachable today) and the Library > Audio `Sessions` group reaches the
  re-based exports with `Export to USB` (mixdown) and `Export stems`. The
  `mixdown.wav` write stays: Listen and the mixdown export need it; a save
  whose mix is empty deletes it (review E5).
- **D14 Footswitch in the Library.** A footswitch press while the Library is
  open returns to Tracks before it acts, as the dialog does today
  (`sessions_manager_cubit.dart:28-33`), and stops any audition. Encoder
  turns do not. New loop by foot is E6-9 and binds to the same
  `SessionCubit.newLoop` later.

## 4. Architecture

### 4.1 Ownership

| Concern | Owner | Notes |
|---|---|---|
| Catalog layout, ids, folders, lenient summaries, previews, re-based mixdown and stems exports, backup and restore bundle orchestration, audition file read | `SessionRepository` (`packages/session_repository`) | Path-addressed; knows nothing about USB or the engine's transport. Drive-side file copies go through the port's `copyFile`. |
| Audition voice | `AudioEngine` (`packages/segno_engine`), new `EngineAudition` role interface | Native contract in 4.4. |
| Current identity, Save / Save as / Duplicate / Rename / Delete / Move, Open with preservation, New loop | `SessionCubit` | Already composes the session, looper and performance repositories and the settings coordinator (`session_cubit.dart:25-67`). Keeps its `_run` envelope, boot-recovery fence and `runExclusive` ordering. |
| Library presentation state: tab, location, search text, folder filter, selected id, preview facts and peaks, audition progress, pedal dismissal | new `LibraryCubit` (`lib/library/cubit/`) | Replaces `SessionsManagerCubit`. Reads `SessionCubit` state through the view, never the other way round. |
| Removable volumes | `RemovableVolumes` port (`lib/library/application/removable_volumes.dart`) | Default `InternalOnlyVolumes`; #1177 supplies the adapter. |
| Finished recordings list, their facts, the DAW package file list | `PerformanceRepository` (`packages/performance_repository`) | Gains `listCaptures()` and `dawPackageFiles(path)`; the bundle shape is already fixed (`performance_repository.dart:979-1000`, `manifestName`). Copies go through the port. |

### 4.2 Catalog model (session_repository)

```dart
typedef SessionId = String;            // the bundle directory basename

@immutable class SessionSummary {
  final SessionId id; final String name; final String? folder;
  final DateTime? modifiedAt; final int trackCount; final double tempoBpm;
  final int tsNum, tsDen; final int fxCount; final bool unreadable;
}
@immutable class SessionPreview {      // from Session.fromJson, no WAV decode
  final SessionSummary summary; final List<SessionPreviewTrack> tracks; // populated only
  final int fxCount; final int backingCount; // 0 until E7-8
}
@immutable class SessionPreviewTrack {
  final int channel; final int lengthFrames; final int baseLengthFrames;
  final int bars;           // 0 when tempo unknown; then the UI shows seconds
  final int layers;         // undoCount + 1 of lane 0 (depths are track-wide)
  final bool muted;         // every lane muted
  final int fxCount;        // lane chains + track chain entries
  final String liveLayerFile; // for Part 6 peaks
}
```

Repository surface (ids everywhere a name was): `listSessions()`,
`listFolders()`, `createFolder(name)`, `deleteFolder(name)` (empty only),
`moveSession(id, {String? folder})`, `renameSession(id, name)` (metadata),
`duplicateSession(id, name) -> SessionId`, `deleteSession(id)`,
`bundlePathOf(id)`, `readPreview(id)`, `nextAutomaticName(prefix)`,
`newSessionId(now)`, `save(path, …)` unchanged plus a `name:` argument and
the empty-mix `mixdown.wav` deletion, `read(path)` unchanged,
`exportMixdown(id, destinationPath)` and `exportStems(id, destinationDir)`
re-based on the saved bundle (D13). Name collisions are checked on display
names, case-sensitively (D1), and still raise `SessionNameCollision`.
`newSessionId()` reserves the directory it names; `releaseSessionId(id)`
removes it again while it is empty.

### 4.3 The removable-volumes port

The port reuses #1177's model shapes verbatim (its section 2.3), so that
`StorageRepository` can implement it without translation: volumes are keyed by
`generation` (a replug is `generation + 1`, so a stale callback can never
address the new drive), the mount is `mountPoint`, space is a call, a lease
carries its `purpose` (the Storage page shows it on the disabled Eject), and
failures are #1177's typed `StorageFailure`.

```dart
abstract interface class RemovableVolumes {
  /// #1177's RemovableVolume{generation, fingerprint, label, fsType, mountPoint,
  /// sizeBytes, status, writeBytesPerSecond, failureReason}; emits on change.
  Stream<List<RemovableVolume>> get volumes;
  List<RemovableVolume> get current;
  /// #1177's VolumeSpace{totalBytes, freeBytes}; null when unknown.
  Future<VolumeSpace?> space(StorageDestination destination);
  /// Holds a WriteLease{target, purpose} for [body]'s duration, so Eject is
  /// refused naming [purpose]; completes with StorageFailure.volumeLost when
  /// the drive goes away before or during.
  Future<T> withWriteLease<T>(StorageDestination target, String purpose,
      Future<T> Function(String mountPoint) body);
  /// #1177's copyFile: `.part` + fsync + rename, ConflictPolicy.ask throws
  /// NameConflict(existingPath) before writing, keepBoth suffixes ` (2)`,
  /// replace renames over; typed failures full / readOnly / volumeLost /
  /// unsupported / io; the part file is deleted on any failure.
  Future<String> copyFile(String sourcePath, StorageDestination destination,
      String relativePath, {required ConflictPolicy onConflict});
}
class InternalOnlyVolumes implements RemovableVolumes { /* no volumes; copyFile to a removable destination throws StorageFailure.unsupported */ }
```

Until #1177's package exists, the model types (`RemovableVolume`,
`RemovableVolumeStatus`, `StorageDestination`, `VolumeSpace`, `WriteLease`,
`ConflictPolicy`, `NameConflict`, `StorageFailure`) are declared beside the
port in `lib/library/application/` with #1177's fields and names; when
`packages/storage_repository` lands, that file imports them from there and the
local declarations are deleted (one commit, no behavior change).

Library layout on a drive: `<mount>/Segno/Sessions/<id>/` (a bundle copy with
its manifest) and `<mount>/Segno/Performances/<name>.wav` or
`<mount>/Segno/Performances/<name>/` for a DAW package (20/12 "USB drive /
Performances"). Reading a drive's `Segno/Sessions/` listing is this plan's
(`listBackups`); #1177 leaves browsing to the Library. Nothing in this plan
imports #1177's client.

### 4.4 Native audition contract (`segno_engine_api.h`)

```c
/* Audition: the Library's isolated preview voice. Control thread. Copies
 * `frames` interleaved float32 samples (`channels` 1 or 2, frames <=
 * LE_AUDITION_MAX_SECONDS * sample_rate) into an engine-owned buffer and plays
 * it once (no loop) into output pair `bus`, summed AFTER the output-bus loop
 * (so after the performance tap; no output bus level or mute touches it) and
 * BEFORE the master bus (gain, limiter, metering), so stems and master.pcm
 * never contain it. Refused with LE_ERR_INVALID when frames <= 0 or over the
 * cap, channels not 1 or 2, sample_rate != the engine rate, bus out of range,
 * or performance capture is armed; LE_ERR_NOT_RUNNING when not configured;
 * LE_ERR_NOT_READY while a previously replaced buffer still awaits the audio
 * thread's release (retry after one block). A second start replaces the
 * first at the next block. */
LE_EXPORT int32_t le_engine_audition_start(le_engine*, const float* pcm,
    int32_t frames, int32_t channels, int32_t sample_rate, int32_t bus);
LE_EXPORT int32_t le_engine_audition_stop(le_engine*);
/* le_snapshot: int32_t audition_frames (0 = none); int32_t audition_pos. */
```

Mechanics (review E4): `_Atomic(le_audition*) a_audition` with a generation,
and an audio-thread `a_audition_ack`. The callback loads the pointer once per
block with acquire, mixes `frames - pos` samples (or to the block end),
advances `audition_pos`, and stores `a_audition_ack = generation` with
release **after the last mixed sample of the block**, never at block entry:
`engine_private.h:1033-1035` records that a plain command ack lands before the
block's frames finish, so an ack at entry would let the control thread free a
buffer the block is still reading. At the end of the material it publishes
`audition_frames = 0`. `stop` and `start` (replace) park the old buffer in one
`audition_retired` slot; the control thread frees it when `a_audition_ack`
has reached the retiring generation, or immediately when the callback is not
running (`a_running == 0`, `engine_private.h:1420`: no block can hold the
pointer). While the slot is occupied and unacked, a further `start` returns
`LE_ERR_NOT_READY` (the existing "a pending report prevents a safe decision"
code, `segno_engine_api.h:51`) and the Dart seam retries once after one block
period; `stop` with an occupied slot waits for that ack on the control thread
(bounded by one block period) and then frees both. `le_perf_arm`
(`engine_process.c:3819`, applied on the audio thread) is preceded on the
control side by the same park, and the mixer skips the voice while
`e->perf.armed`, so a race cannot put audition samples into a capture.
`le_engine_quiesce_workers` (`engine.c:358`, run by configure and reopen)
frees both slots with the callback stopped. Nothing is freed on the audio
thread and nothing allocates there. No new command code: publication is an
atomic pointer swap, not a ring command.

## 5. Parts

Sizes are production lines (Dart or C), excluding tests, generated bindings
and docs. Dependencies: P1 -> P2 -> P3 -> P4 -> P5; P6a -> P6b, both after P2;
P7 after P2 (Preview on recordings after P6b); P8 after P3. Every part leaves
the app working end to end and ships its own tests.

### Part 1: catalog identity, folders, lenient summaries, previews, and the SessionCubit id migration (about 520 lines)

Files, package: `packages/session_repository/lib/src/models/session_summary.dart`
(replace), new `models/session_preview.dart`, `session_repository.dart`
(`:303-427` catalog block rewritten for ids and folders; `save` gains `name`
and deletes `mixdown.wav` when the mix is empty (E5); `:593-628`
`exportMixdown`/`exportStems` re-based on a saved bundle (D13); `_sessionFrom`
writes `name`), `models/session.dart` (optional `name`, read at `:745-775`,
written at `:1018-1020`, `formatVersion` unchanged), `session_name.dart`
(`sessionSlug` stays for display-name sanitizing; the slug is no longer a
path), new `session_id.dart` (`newSessionId`, pattern `performance_slug.dart`),
`docs/design/session-bundle-format.md` (layout, `name`, the empty-mix rule).

Files, app (the id migration the review moved here out of Part 2, so that the
package change and the one caller change land together and the app keeps
compiling): `lib/session/cubit/session_cubit.dart` (`currentSessionId` beside
`currentSessionName`; `loadNamed(name)` becomes `open(id)` with the same body;
`renameSession`, `duplicateSession`, `deleteSession` take ids; `saveAs` creates
`newSessionId` and passes `name:`; the live-rig `exportMixdown`/`exportStems`
methods and their two outcomes removed, `saveAsRequested` kept until Part 3),
`session_state.dart`, `lib/session/view/sessions_manager_dialog.dart` (rows
keyed and loaded by id, highlight by id; otherwise unchanged, it is retired in
Part 2), `lib/looper/view/tracks_commands.dart:389-391` (the two export
outcome strings go), `app_en.arb`/`app_es.arb` (`mixdownExported`,
`stemsExported` removed).

Behavior: listing walks one level (section 3 D2), skips manifest-less
directories that hold layer WAVs or a mixdown, reads each manifest as a JSON
map for the summary keys (D3) and sorts by `modifiedAt` descending;
`readPreview` uses `Session.fromJson` and derives bars from `lengthFrames`,
`tempoBpm`, `tsNum`/`tsDen` and the sample rate (0 when `tempoBpm == 0`).
Automatic names count every catalog name. Folder and name validation reuse
`sessionSlug` (letters, digits, space, hyphen, underscore). Duplicate
rewrites `name` in the copy's manifest. The dialog behaves exactly as before
for the user; only its keys change.

Tests (`packages/session_repository/test/session_catalog_test.dart` rewritten,
`session_repository_test.dart` extended, `test/session/cubit/session_cubit_test.dart`
and `test/session/view/sessions_manager_dialog_test.dart` adapted to ids):
a legacy `sessions/<slug>/` bundle lists with `id == name == slug`; a bundle
with `name` lists by its name; an unparseable manifest lists `unreadable` by
basename and `readPreview` throws the typed refusal; folders list and bundles
inside them carry `folder`; a manifest-less directory holding
`track0_lane0_L0.wav` is neither a folder nor a session; a nested second level
is ignored; `moveSession` to and from `Unfiled`; `renameSession` changes only
the manifest and keeps every WAV byte-identical; duplicate rewrites the copy's
`name` and deletes by id; `nextAutomaticName` skips `New loop 1` and `new loop
3` to return `New loop 2`; `deleteFolder` refuses a non-empty folder;
`newSessionId` same-second suffixing; a save whose captured mix is empty
deletes a stale `mixdown.wav` and a non-empty one rewrites it;
`exportMixdown(id, path)` copies the bundle's mixdown byte-identically and
`exportStems(id, dir)` writes `track{c}_lane{l}_L0.wav` equal to the bundle's
live layer for every lane; the cubit opens, renames, duplicates and deletes by
id and the dialog highlights by id.

```success-criteria
GOAL: Sessions have a stable directory identity, a renameable display name and one level of folders, listed without loading anything; every installed bundle still lists and loads unchanged; the saved bundle is the source for the mixdown and stems exports; and the app compiles and behaves as before on ids.
SUCCESS CRITERIA:
- A pre-existing `sessions/<slug>/` bundle with no `name` field lists under its slug, previews and loads exactly as before; a bundle saved with `name` lists under that name and keeps `version: 11`. | verify: (cd packages/session_repository && /Users/Tomas/development/flutter/bin/flutter test)
- Rename touches only `session.json`; every layer WAV and `mixdown.wav` is byte-identical before and after; a duplicate carries the new name in its own manifest. | verify: (cd packages/session_repository && /Users/Tomas/development/flutter/bin/flutter test test/session_catalog_test.dart)
- Folders are directories: create, move in and out, refuse deleting a non-empty folder, ignore a second level, never list an interrupted save as a folder; summaries carry name, folder, saved time, track count, tempo, signature and FX count without a full decode. | verify: (cd packages/session_repository && /Users/Tomas/development/flutter/bin/flutter test)
- A save with an empty mix removes a stale `mixdown.wav`; `exportMixdown(id, …)` and `exportStems(id, …)` read the saved bundle, never the live engine; the package coverage floor of 89% holds. | verify: (cd packages/session_repository && /Users/Tomas/development/flutter/bin/flutter test --coverage) && dart analyze --fatal-infos packages/session_repository
- The app's session cubit and dialog work on ids with unchanged user-visible behaviour; the live-rig export methods and outcomes are gone. | verify: /Users/Tomas/development/flutter/bin/flutter test test/session test/app/view/app_test.dart test/looper/view && ! grep -rn "mixdownExported\|stemsExported" lib && dart analyze --fatal-infos && bloc lint lib test packages
NON-GOALS:
- The Library page, folders UI, shared audio references, migration of directory names, waveform peaks, USB.
VERIFICATION COMMAND: (cd packages/session_repository && /Users/Tomas/development/flutter/bin/flutter test --coverage) && /Users/Tomas/development/flutter/bin/flutter test test/session test/app/view/app_test.dart test/looper/view && dart analyze --fatal-infos && bloc lint lib test packages
```

### Part 2: the Library shell replaces the Sessions dialog (about 560 lines)

Files: new `lib/library/view/library_page.dart` (`LibraryPage` in
`LoopSettingsFrame`, crumb tabs, `Stage`), `library_sessions_tab.dart`
(search, folder chips, rows, preview card, footer), `library_preview_card.dart`,
new `lib/library/cubit/library_cubit.dart` + `library_state.dart` (tab,
location, query, folder filter, selected id, preview, pedal dismissal),
new `lib/library/application/removable_volumes.dart` (section 4.3 with
`InternalOnlyVolumes`), `lib/app/segno_navigator.dart` (`openLibrary({LibraryTab initial})`
with the duplicate guard and route name `segno/library`),
`lib/app/view/app.dart` (provide `RemovableVolumes`; `InternalOnlyVolumes` in
every composition root, `lib/app/run_segno.dart`), `stage_top_bar.dart:54`,
`connectivity_banners.dart:91` and `tracks_commands.dart:371-375` repointed to
`openLibrary` (the cubit is already on ids after Part 1); delete
`lib/session/view/sessions_manager_dialog.dart`,
`lib/session/cubit/sessions_manager_cubit.dart`, their tests, and the
`sessionsManagerTitle`, `sessionsEmpty`, `sessionNewTitle`, `sessionManage`
strings in `app_en.arb`/`app_es.arb` (new `library*` keys replace them).

Behavior: the Library opens on the Sessions tab with the current session
selected; a tap on a row selects and previews (never loads); the footer reads
`Return to tracks` for the current session and `Open session` otherwise, and
`Open session` calls `SessionCubit.open(id)`, the existing load body by id
(review E6: there must be a way to switch sessions between this part and
Part 4; the D7 preservation and the D8 confirm layer onto this same call in
Part 4, so until then Open behaves as the retired dialog's row tap did, minus
the accidental tap); the `Audio` crumb is present and opens the Part 7 tab
(until Part 7 the crumb is
not drawn: nothing is shown that does not work); `USB` is shown and, with
`InternalOnlyVolumes`, selecting it shows "Connect a USB drive" with "Your
internal sessions are still available." (18/06 wording adapted); `New loop`
is drawn disabled until Part 5 ships it (the one deliberate stand-in, because
the actions row's geometry needs it; recorded for the pen write-back); a
footswitch press returns to Tracks (D14). Preview lanes draw the length share
only (D11). Search filters by case-insensitive substring; the folder chip
filters by folder; `Unfiled` is the root.

Tests: `test/library/view/library_page_test.dart` (the screen renders from a
fixture catalog with selection, search, chips, preview facts; the current row
reads `Current session`; a non-current row's meta reads the saved date and
track count; the footer label switches; the pedal press pops; the USB segment
shows the connect message with the default port), `test/library/cubit/library_cubit_test.dart`,
`test/app/view/app_test.dart:1312`, `:3490` updated to `library_page`,
`test/looper/view/connectivity_banners_test.dart` (the Sessions action opens
the Library), `test/looper/view/stage_top_bar_test.dart` if present.

```success-criteria
GOAL: The Library is a full-screen page with Sessions and Audio crumbs, Internal and USB locations, search, folders and a preview that never loads, and the Sessions dialog is gone.
SUCCESS CRITERIA:
- Tapping the stage Library mark pushes `segno/library` drawn to pen 19/01 (topbar, 709/1028 split, row and preview geometry) and no `sessions_manager` key exists anywhere in `lib/`. | verify: /Users/Tomas/development/flutter/bin/flutter test test/library test/app/view/app_test.dart && ! grep -rn "sessions_manager\|showSessionsManager" lib
- Selecting a row changes the preview and footer only; `LooperRepository.applySession` is never called by a selection (mock verify); `Open session` on a non-current row calls `SessionCubit.open(id)` once and the loaded session lands stopped. | verify: /Users/Tomas/development/flutter/bin/flutter test test/library
- Search, `All`/`Unfiled`/folder chips and the `USB` location with the default port behave as specified; a footswitch press pops the page. | verify: /Users/Tomas/development/flutter/bin/flutter test test/library test/app/view/app_test.dart
- Analyzer, Bloc lint, formatting and the root 90% coverage floor stay green. | verify: dart analyze --fatal-infos && bloc lint lib test packages && /Users/Tomas/development/flutter/bin/flutter test --coverage
NON-GOALS:
- Manage actions, preservation and the interruption confirm on Open, New loop, Listen, the Audio tab's contents, USB backup.
VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos && bloc lint lib test packages
```

### Part 3: Manage: Save, Save as, Duplicate, Rename, Move to folder, Delete; New folder; automatic names (about 380 lines)

Files: new `lib/library/view/library_manage.dart` (the options sheet,
deviation 1), `library_sessions_tab.dart` (`Manage`, `New folder`, storage
error banner 19/05), `lib/session/cubit/session_cubit.dart` (`save` with
automatic name, `saveAs(name)`, `duplicateSession(id, name)`,
`renameSession(id, name)`, `moveSession(id, folder)`, `deleteSession(id)`
refusing the current id with new `SessionError.currentSessionProtected`;
`saveAsRequested` removed from `session_state.dart:19-42`),
`tracks_commands.dart:371-395` (the quick Save toast names the automatic
name; no prompt), l10n keys.

Behavior per D4, D5, D6. Name prompts use `showConsoleRenameSheet` (19/04)
with the inline collision check kept as fast feedback; the cubit stays the
authority (`SessionNameCollision`). A failed `Save`/`Save as` shows the
19/05 banner in the Library and leaves the catalog and the current pointer
unchanged (the existing `_run` failure envelope). `Move to folder…` lists the
folders plus `Unfiled` and `New folder…`.

Tests: `test/session/cubit/session_cubit_test.dart` (automatic name on a
nameless Save; Save as makes the new identity current and leaves the old
bundle intact; Duplicate of a non-current session leaves the current pointer;
Rename of the current session updates the header name and not the id; Delete
of the current id refuses with the typed error and deletes nothing; a write
failure leaves `currentSessionId` and `sessions` as before),
`test/library/view/library_page_test.dart` (the manage group: rows, disabled Delete on
the current session, folder picker, the banner on failure).

```success-criteria
GOAL: Every identity operation is explicit and distinct, naming is optional, and no failure changes the catalog or the open session.
SUCCESS CRITERIA:
- Save on an unnamed rig creates `New loop N` without a prompt; Save as creates a new current identity; Duplicate copies a saved session without touching the current pointer; Rename is metadata-only; Delete refuses the current session. | verify: /Users/Tomas/development/flutter/bin/flutter test test/session/cubit/session_cubit_test.dart
- A failed save shows "Could not save your current loop. Nothing was changed." and the catalog, current pointer and every bundle on disk are unchanged. | verify: /Users/Tomas/development/flutter/bin/flutter test test/library test/session
- `saveAsRequested` no longer exists. | verify: ! grep -rn "saveAsRequested" lib && dart analyze --fatal-infos
NON-GOALS:
- Open, New loop, USB, shared-audio reference checks.
VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos && bloc lint lib test packages
```

### Part 4: Open preserves outgoing work and confirms interruption (about 300 lines)

Files: `session_cubit.dart` (`open(id)` gains the D7 preservation step with
the fingerprint, recorded after every successful save, open and New loop; the
no-op when `id == currentSessionId`), `packages/segno_engine/lib/src/audio_engine.dart`
and `native_audio_engine.dart` (`trackAudioRev(channel)` over
`le_engine_track_audio_rev` if the snapshot does not already carry it; the
mock and fakes count it up on every write), `library_sessions_tab.dart` (the
D8 confirm dialog via `showConsoleConfirmDialog` `console_surface.dart:2960`,
the 19/05 banner on a preservation failure), `library_cubit.dart` (stop
audition hook for Part 6), l10n.

Behavior: `Open` runs inside one `runExclusive` scope: capture and fingerprint
-> save when changed (identity or automatic name) -> read the target -> disarm
capture -> apply stopped -> make current -> record the new fingerprint. A
preservation failure aborts before the read and shows 19/05; a target refusal
(rate, version, corrupt layers) shows the existing localized banners in the
preview and leaves the outgoing rig and its just-written save in place.
While any track plays or captures, the player is asked first (D8); `Cancel`
changes nothing.

Tests: `session_cubit_test.dart` (an outgoing named rig with a changed track
rev is saved before the target applies, verified by call order on the mocks;
an outgoing named rig whose fingerprint matches is not saved; an unnamed rig
with only an FX chain change is saved under an automatic name; an unnamed rig
with only a mixer level change is saved; a fresh untouched rig writes nothing;
a preservation failure applies nothing and the state carries the error; a
target `SessionSampleRateMismatch` after a successful preservation leaves the
current pointer on the outgoing session), `library_page_test.dart` (a
fixture with one track in `TrackState.playing` shows the confirm; one in
`TrackState.recording` shows it; all tracks stopped or empty with
`transport.isRunning == true` does not; `Cancel` calls nothing; the current
session's footer is `Return to tracks`).

```success-criteria
GOAL: Opening a session is an explicit act that never loses outgoing work of any kind, never re-saves an unchanged rig, and never interrupts playback without asking.
SUCCESS CRITERIA:
- A changed outgoing rig (audio, FX, mixer or settings) is saved first, to its identity or as `New loop N`; an unchanged rig is not re-saved; a fresh untouched rig writes nothing. | verify: /Users/Tomas/development/flutter/bin/flutter test test/session/cubit/session_cubit_test.dart
- A failed preservation shows the 19/05 banner and applies nothing; a refused target after preservation keeps the outgoing session current and its save on disk. | verify: /Users/Tomas/development/flutter/bin/flutter test test/session test/library
- A playing or capturing track is asked before Open; Cancel changes nothing; stopped tracks on a running device are not asked. | verify: /Users/Tomas/development/flutter/bin/flutter test test/library
- Round trip on the real engine: save, record on another identity, Open the first; the first plays back byte-exact from the head after Play. | verify: /Users/Tomas/development/flutter/bin/flutter test test/session/session_layers_roundtrip_test.dart
NON-GOALS:
- Dirty detection, New loop, audition.
VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos && bloc lint lib test packages
```

### Part 5: New loop (about 240 lines)

Files: `session_cubit.dart` (`newLoop()`: preserve as in Part 4, build the
empty rig per D9 from `SessionSettingsCoordinator.capture`
(`session_settings_coordinator.dart:67-80`) and the live chains, apply through
`_looper.applySession`, save the empty rig under `New loop N` and make it
current), `lib/session/session_mapping.dart` (a `rigForNewLoop(captured)`
beside `rigFromBundle` `:265-343`), new `lib/library/view/new_loop_sheet.dart`
(19/02), `library_sessions_tab.dart` (`New loop` enabled), l10n.

Tests: `session_cubit_test.dart` (the applied rig has no tracks, `baseLengthFrames 0`,
`loopBars 0`, `primaryTrack -1`, and the outgoing tempo, signature, mode,
defaults, click, count-in, Fade durations, levels, pans, lane routing, input
and output setup, all four chain stages and the pedal remap; the outgoing
session is saved first when changed; the new identity is `New loop N` and
current; a preservation failure applies nothing), `test/session/session_mapping_test.dart`
(the field-table test, review E8: build a `Session` with every field at a
non-default value, including every `track*Overrides` map, `monitors`, chains
and `pedalBindings`; run it through the bundle mapper and `rigForNewLoop` and
back through `_sessionFrom`/`toJson`; assert that the resulting key set equals
the source key set minus exactly `{tracks, baseLengthFrames, loopBars,
primaryTrack}` plus those four at their reset values, and that every remaining
key's value equals the source's. A field added to `Session` later appears in
the source key set and not in the drop set, so the equality fails until its
New loop fate is written down), `library_page_test.dart` (the sheet's copy
names the outgoing session; `Cancel` calls nothing), and one real-engine test
in `test/session/` (record two tracks with a muted lane and a mid-fade, New
loop, then: every track EMPTY, no lane muted, every Fade at unity, master
length 0, tempo and mode unchanged, the previous session reloadable
byte-exact).

```success-criteria
GOAL: New loop preserves the current session, clears every track and its history, keeps the sound, tempo and pedal setup, and resets the performance transforms, by foot or touch later through one cubit method.
SUCCESS CRITERIA:
- The applied rig keeps every D9 key with its value and drops exactly `tracks`, `baseLengthFrames`, `loopBars` and `primaryTrack` (key-set equality against a fully non-default `Session`; a new manifest field fails it). | verify: /Users/Tomas/development/flutter/bin/flutter test test/session/session_mapping_test.dart test/session/cubit/session_cubit_test.dart
- On the real engine, after New loop every track is EMPTY with no mute and Fade at unity, the master length is 0 and the tempo and mode are unchanged; the outgoing session reloads byte-exact. | verify: /Users/Tomas/development/flutter/bin/flutter test test/session
- The stage header reads the automatic name and the Library lists it as the current session. | verify: /Users/Tomas/development/flutter/bin/flutter test test/library test/looper/view
NON-GOALS:
- The foot binding (E6-9), Transpose/Speed resets (land with E6-4/5 in the apply path; Reverse already resets there), backing.
VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos && bloc lint lib test packages
```

### Part 6a: the native audition voice and its Dart seam (native about 200 lines, Dart about 120 lines)

Files, native (`packages/segno_engine/src/core/`): `segno_engine_api.h`
(section 4.4 contract, `LE_AUDITION_MAX_SECONDS 120`, snapshot fields),
`engine_private.h` (`a_audition`, `a_audition_ack`, `audition_retired`),
`engine_commands.c` (start/stop/park/free, the `LE_ERR_NOT_READY` path, the
pre-arm park), `engine_process.c` (one mix step between the output-bus loop
and `master_bus_frame` at `:6580-6589`, the block-end release store of the
ack, the `perf.armed` skip), `engine.c` (`le_engine_quiesce_workers` frees
both slots), `engine_snapshot.c`, new `src/test/test_engine_audition.h`
included from `test_engine_core.c` like `test_engine_reopen.h` (`:33541`).
Dart engine (`packages/segno_engine/lib/src/`): `audio_engine.dart`
(`EngineAudition` role on `AudioEngine`: `auditionStart(Float32List
interleaved, {channels, sampleRate, bus})`, `auditionStop()`, the snapshot's
`auditionFrames`/`auditionPosition`, and a one-retry wrapper for
`notReady`), `native_audio_engine.dart`, `pumped_native_engine.dart`,
`mock_audio_engine.dart` and the test fakes; bindings regenerated and
formatted (`ffigen.yaml`, `dart format` per `docs/PROGRESS.md`).

Native tests (literal oracles, `test_engine_audition.h`): a 64-frame mono
ramp into bus 0 appears exactly once on both channels of the pair and the
next block is silent, `audition_pos` advances by the block and
`audition_frames` reads 0 after the end; a stereo buffer keeps L/R
interleave; stop between blocks silences the next block and the parked
buffer is freed (ASAN); a second start replaces the first with no leak; a
third start while the replaced buffer is unacked returns `LE_ERR_NOT_READY`
and succeeds after one block; the ack is observed only after the block's
last frame (a test harness that inspects `a_audition_ack` mid-block through
the per-frame hook sees the old generation); with the callback stopped,
`stop` frees immediately; with `perf` armed the start is refused and an armed
capture after a start finds the voice cleared, the master ring containing no
audition sample; master gain 0.5 halves the voice and a ceiling of 0.25
limits it; an output bus at level 0 or muted leaves the voice at unity; with
a playing loop the output equals loop plus voice sample-exactly; a rate
mismatch, channels 3, frames 0 and frames over the cap are refused;
configure and reopen free both slots; a track recording while the voice
plays records none of it (the lane capture reads inputs, not outputs,
`engine_process.c:6539-6557`).

Dart tests: `pumped_native_engine_test.dart` (start, progress, stop, the
`notReady` retry through the real FFI), `audio_engine` fakes.

```success-criteria
GOAL: An isolated, bounded native preview voice that never reaches stems, captures or recordings and never frees a buffer the audio thread may still read.
SUCCESS CRITERIA:
- Native: the voice sums exactly once into the chosen pair after the output-bus loop and before the master bus; the ack lands after the block's last mixed frame; stop, replace, perf arm, configure and reopen free the buffers on the control thread; a replace while a retired buffer is unacked reads `LE_ERR_NOT_READY`; refusals match the contract. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- Sanitizer and telemetry-off builds pass; bindings and symbol parity are clean. | verify: EXTRA_CFLAGS='-fsanitize=address -g' bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-DLE_CALLBACK_TELEMETRY=0' bash packages/segno_engine/src/test/run_native_tests.sh && (cd packages/segno_engine && dart run ffigen --config ffigen.yaml && dart format lib/src/generated/segno_engine_bindings.dart && git diff --exit-code lib/src/generated)
- The Dart seam starts, reports progress, stops and retries once on `notReady` through the real FFI. | verify: (cd packages/segno_engine && SEGNO_ENGINE_LIB=<built lib> /Users/Tomas/development/flutter/bin/flutter test)
NON-GOALS:
- Repository, cubit, UI, resampling, looping the preview, streaming.
VERIFICATION COMMAND: bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-fsanitize=address -g' bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-DLE_CALLBACK_TELEMETRY=0' bash packages/segno_engine/src/test/run_native_tests.sh && (cd packages/segno_engine && /Users/Tomas/development/flutter/bin/flutter test)
```

### Part 6b: Listen, bounded decode and the preview waveform (about 320 lines)

Files: `session_repository.dart` (`startAudition(id)`: the bundle's
`mixdown.wav` through `EngineAudition.auditionStartFile`, which decodes at
most `kAuditionMaxSeconds` of it with the engine's one decoder,
`le_backing_decode_file`, in `Isolate.run`; `stopAudition()`;
`auditionState()`; `readPeaks(id, track, buckets)` over the lane-0 live layer
through `EngineAudition.filePeaks`, the decoder's streaming probe, in
`Isolate.run`). `wav_codec` is unchanged: it writes files and models headers
and parts, and never decodes for the Library. `library_cubit.dart` (Listen
state, a 100 ms progress timer while playing, the truncated flag, stop on
navigation, Open, New loop, pedal press, capture arm, any track recording via
`LooperBloc` state, and a device reopen or reconfigure observed as
`auditionFrames == 0` before the end), `library_preview_card.dart`
(`Listen`/`Stop` 160 x 64 with progress, `Preview plays the first 2:00` when
truncated; lane peaks), l10n.

Tests: the engine's decoder tests (a file longer than the cap decodes
exactly the cap and reports truncation; another rate is converted),
`session_repository` tests (`startAudition` hands the bundle's `mixdown.wav`
to the engine and refuses a bundle without one before it; `readPeaks` reads
the lane-0 live layer through the engine), a real-engine test (a saved
session's preview plays on the audition voice and its lane reads back as
peaks), `library_cubit_test.dart` (Listen ends on each
of the seven triggers), `library_page_test.dart` (the button, progress and
truncation line; lanes draw peaks when present and length-only when the read
fails).

```success-criteria
GOAL: Listen plays a session's saved preview through the native voice within the bound, decoded off the UI isolate, and the preview lanes draw real peaks or nothing.
SUCCESS CRITERIA:
- A preview longer than 120 s plays exactly its first 120 s and says so; the UI isolate never decodes a WAV (the engine's decoder runs in `Isolate.run`) and nothing in the app decodes audio with `wav_codec`. | verify: (cd packages/session_repository && /Users/Tomas/development/flutter/bin/flutter test) && bash packages/segno_engine/src/test/run_native_tests.sh
- Audition ends on navigation, Open, New loop, a footswitch press, performance arm, a track entering recording and a device reopen; a file at another rate plays converted. | verify: /Users/Tomas/development/flutter/bin/flutter test test/library
- Appliance: Listen is audible on the main outputs, a performance recording armed during Listen contains none of it, and a loop recorded during Listen contains none of it. | verify: manual on the console: 1. Listen, hear the preview. 2. Arm Record performance; the take's main-output parts are silent where the preview was. 3. Record a take during Listen; the take holds only the input. [HARDWARE]
NON-GOALS:
- Resampling, looping the preview, audition of arbitrary files, streaming past the cap.
VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test && (cd packages/session_repository && /Users/Tomas/development/flutter/bin/flutter test) && bash packages/segno_engine/src/test/run_native_tests.sh && dart analyze --fatal-infos && bloc lint lib test packages
```

### Part 7: Library > Audio with Performances and Sessions groups, Export to USB and the re-homed DAW export (about 560 lines)

Files: `packages/performance_repository/lib/src/performance_repository.dart`
(`listCaptures()` -> `CaptureSummary(path, name, startedAt, durationFrames,
sampleRate, recovered, hasDawProject, parts)` from `performance.json`,
skipping unfinalized bundles and listing the `recovered/` ones marked
recovered (item 11); `dawPackageFiles(capture)` listing the take's parts in
the order its `parts` list gives them, its rendered stems, `project.als` and
`fx-chains.txt` that exist; `deleteCapture`, `startAudition`, `readPeaks`), new
`lib/performance/application/daw_project_export.dart` (the writer moved from
`performance_recorder_cubit.dart:637-656`, called by `_finishRender`
`:528-560` and by the Library), `performance_recorder_cubit.dart` and
`performance_recorder_state.dart` (`reExport`, `isReExporting`,
`reExportFailed` removed), `performance_completion_sheet.dart:315-353`
(`Re-export` button and banner removed), new `lib/library/view/library_audio_tab.dart`
(18/01 geometry: title `Audio library` without the sub-nav row (deviation 3),
`Internal`/`USB drive`, `Search audio`, the `Performances` group and the
`Sessions` group (each saved session's mixdown, deviation 4), the 684-wide
preview with kind `WAV`, duration, name, waveform via Part 6b's peaks,
`Preview` through the same voice, actions `Export to USB` and, for a
recording, `DAW project`; for a session item `Export to USB` (mixdown) and
`Export stems`), `library_cubit.dart` (Audio tab state, export progress and
conflict, the package choice), the dialogs 20/09-20/12 (`Already on USB` with
`Cancel`/`Keep both`/`Replace file`; `Connect a USB drive` with
`Cancel`/`Try again`; `Not enough space. Free up storage and try again.`;
`Exported to USB` with `Done`) and a two-row package chooser (`Recording only
(WAV)` / `DAW package (WAV, stems, Ableton project)`), l10n.

Behavior: every export runs inside `RemovableVolumes.withWriteLease(target,
purpose)` with a purpose the Storage page can show (`Exporting <name>`); a
`space()` check against the package's byte total precedes the copy; each file
goes through the port's `copyFile` with the chosen `ConflictPolicy`
(`ask` first, so a conflict surfaces 20/09 before anything is written), to
`Segno/Performances/<name>.wav` for a single WAV, `Segno/Performances/<name>/`
for a DAW package (which first writes `project.als` and `fx-chains.txt` into
the internal bundle through the shared function if they are missing),
`Segno/Sessions/<name>.wav` for a session mixdown and `Segno/Sessions/<name>
stems/` for its stems (via the re-based `exportStems` into a temp directory,
then `copyFile` per file). A multi-file package that fails midway removes the
files it already placed on the drive (the destination directory is renamed
into place only after every file landed) so cancel, a missing drive, a full
disk or a write error leave both the drive and the internal recording as they
were (accepted 6.8). `DAW project` alone writes the two files into the bundle
and reports success or the typed failure in the preview. With
`InternalOnlyVolumes` the `USB drive` segment shows 18/06 and `Export to USB`
opens 20/10.

Tests: `packages/performance_repository/test` (listing skips unfinalized and
recovered bundles, reads the slug and duration; `dawPackageFiles` lists only
files that exist), `test/performance/cubit/performance_recorder_cubit_test.dart`
(render still writes the DAW files through the shared function; `reExport`
gone), `test/performance/view/performance_completion_sheet_test.dart:351-381`
removed, `test/library/view/library_audio_tab_test.dart` (both groups,
preview, Preview, the package chooser, the four dialogs driven by a fake
`RemovableVolumes` whose `copyFile` records calls and can throw each
`StorageFailure`), `library_cubit_test.dart` (the fake records exactly one
`copyFile` per package file with the chosen policy; a `full` on the third
file of a package removes the two already placed; `volumeLost` mid-package
leaves the drive-side directory absent).

```success-criteria
GOAL: Finished recordings and saved sessions' mixdowns are browsable in Library > Audio and exportable to USB as a WAV, a stems set or a DAW package through #1177's copy protocol, without ever altering the internal copy; the DAW project export lives there and nowhere else.
SUCCESS CRITERIA:
- The Performances group lists finalized captures with name and duration, recovered ones marked, and excludes unfinalized bundles; a recording can be deleted after a confirmation; the Sessions group lists every catalog session that has a mixdown. | verify: (cd packages/performance_repository && /Users/Tomas/development/flutter/bin/flutter test) && /Users/Tomas/development/flutter/bin/flutter test test/library
- Export with a fake port: single WAV, DAW package, mixdown and stems each issue one `copyFile` per file with the chosen policy; `ask` surfaces the conflict before any copy; `full`, `volumeLost`, `readOnly` and `io` midway leave the drive without the partial package and the internal bundle byte-identical. | verify: /Users/Tomas/development/flutter/bin/flutter test test/library && (cd packages/performance_repository && /Users/Tomas/development/flutter/bin/flutter test)
- `DAW project` writes `project.als` and `fx-chains.txt` into the bundle; the completion sheet has no re-export control; `reExport` no longer exists. | verify: /Users/Tomas/development/flutter/bin/flutter test test/performance test/library && ! grep -rn "reExport" lib
- The performance repository's 99% floor and the root 90% floor hold. | verify: (cd packages/performance_repository && /Users/Tomas/development/flutter/bin/flutter test --coverage) && /Users/Tomas/development/flutter/bin/flutter test --coverage
- Appliance: with #1177's `StorageRepository` behind the port, export a recording as WAV and as a DAW package to a real drive, then unplug mid-copy and retry. | verify: manual on the console with a FAT32 and an exFAT drive: the files land under `Segno/Performances`, the interrupted package leaves nothing on the drive, Retry completes, Eject is refused during the copy naming the export. [HARDWARE, after #1177]
NON-GOALS:
- Backing, prepared audio, Use in loop, Save audio, import from USB, preset export (E5-5), `Show on USB` (deviation 3).
VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test && (cd packages/performance_repository && /Users/Tomas/development/flutter/bin/flutter test --coverage) && dart analyze --fatal-infos && bloc lint lib test packages
```

### Part 8: Sessions > USB: Back up to USB and Restore to Library (about 430 lines)

Files: `session_repository.dart` (`bundleFiles(id)` listing the manifest and
every referenced WAV; `listBackups(root)` reading a drive's `Segno/Sessions/`
with the same lenient summaries; `restoreFrom(sourceDir, {name})` copying a
backup bundle into the internal root under a fresh id, rewriting `name` in
the restored manifest and, on a name match, `<name> (2)` (pen `f2sBAc`)),
`library_cubit.dart` (backup orchestration: lease with purpose `Backing up
<name>`, `space()` check, one `copyFile` per bundle file into
`Segno/Sessions/<id>.part/` on the drive, then a directory rename to
`Segno/Sessions/<id>/`; `Replace` renames the existing backup to `.old`
first and deletes it only after the new directory is in place; progress,
cancel, conflict, interruption and retry; the USB location lists backups and
offers `Restore to Library`), `library_sessions_tab.dart` (section 34 tiles:
inline progress "Backing up <name>…" with `Cancel`; `A backup has this name`
with `Cancel`/`Keep both`/`Replace`; `Backup interrupted` "USB drive
disconnected. Nothing was changed." with `Cancel`/`Retry`; the USB list with
`Session`/`Saved` columns and "Adds a new session to Library."), l10n.

Behavior: the drive side goes through the port (`withWriteLease`, `space`,
`copyFile`; the per-file `.part` protocol is #1177's), and this plan keeps
only the bundle-level steps (the `.part` directory, the rename, the `.old`
swap). A `StorageFailure` mid-copy removes the part directory and shows the
interruption tile; `Retry` repeats with the same choices. Restore reads the
drive (no lease needed for reading) and never touches the live rig; the
restored copy appears selected in the preview with `Open session`
(`f2sBAc`). Backups keep their manifest `name`; the restored id is fresh
(`newSessionId`) and its manifest carries the restored name.

Tests: `session_repository_test.dart` (`bundleFiles` lists exactly the
manifest plus the referenced WAVs and the mixdown; `listBackups` over a temp
root; restore creates a fresh id, rewrites `name`, suffixes `(2)` on a match;
the live rig's bundles are untouched), `library_cubit_test.dart` (with a fake
port recording `copyFile`: one call per bundle file into the `.part`
directory, then the rename; `volumeLost` on the third file removes the part
directory and leaves an existing backup intact; Replace keeps the `.old`
backup when the new copy fails and deletes it when it lands; cancel between
files removes the part directory; Keep both suffixes), `library_page_test.dart`
(the six tiles).

```success-criteria
GOAL: A session can be backed up to a drive and restored as an independent copy through #1177's copy protocol, and no interruption, conflict or cancel ever changes what was there before.
SUCCESS CRITERIA:
- Backup places every bundle file through the port into `Segno/Sessions/<id>.part/` and renames it into place; cancel, drive loss or any typed failure leaves no part directory and an existing backup intact; Replace deletes the old backup only after the new one landed. | verify: /Users/Tomas/development/flutter/bin/flutter test test/library && (cd packages/session_repository && /Users/Tomas/development/flutter/bin/flutter test)
- Restore adds a new identity whose manifest carries the restored name, suffixes a matching name with ` (2)`, and never calls `applySession`. | verify: (cd packages/session_repository && /Users/Tomas/development/flutter/bin/flutter test) && /Users/Tomas/development/flutter/bin/flutter test test/library
- The six section-34 tiles render and act as specified against a fake volume, including the interruption and Retry path. | verify: /Users/Tomas/development/flutter/bin/flutter test test/library
- Appliance: back up to a real drive, unplug mid-copy, replug, Retry; restore the backup; open it. | verify: manual on the console: the backup lands, the interrupted copy leaves nothing, Retry completes, the restored session opens stopped and plays byte-exact. [HARDWARE, after #1177]
NON-GOALS:
- Complete appliance backup and restore (E7-15), recordings and presets backup, crash-consistent publication (E7-19), repair flows (E7-16..18).
VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test && (cd packages/session_repository && /Users/Tomas/development/flutter/bin/flutter test --coverage) && dart analyze --fatal-infos && bloc lint lib test packages
```

## 6. Recall ownership audit (E7-6)

What the manifest owns today, by `models/session.dart` and `SessionSettings`
(`session_repository.dart:69-262`): audio layers and history per lane
(`tracks[].lanes[].layers`, `undoCount`, `redoCount`), per-lane volume, mute,
output mask, input, pan, balance; per-track multiple, length, Fade amount;
master length and grid (`baseLengthFrames`, `loopBars`); tempo and source,
signature, sync, quantize; record timing, decay, Loop/Once, length preset and
their per-track overrides; Fade default and overrides; click mode, mask,
volume; count-in; `recDub`, `autoRecord`, `defaultMultiple`; looper mode and
crown; track levels and pans; lane inputs, outputs, counts; input setup
(trims, pans, pairs); output setup (level, mute, mono, balance); the four FX
stages; the pedal remap (`pedalBindings`). This matches accepted 6.9's
musical list for everything that exists.

Appliance-owned by exclusion (settings_repository, never in a bundle):
audio device and rate, display brightness and calibration, network, update
state, controller global assignments (the session carries only its remap),
external pedal calibration. Correct per 6.9.

Still to confirm when their owners exist, not now: instruments (E8-7), custom
pedal LED colours and per-session actions beyond the remap (check whether
`PedalBindingSet.encode` carries colours when E8 adds them), expression ranges
(E7-6 note in the inventory), prepared backing (E7-8). New loop's keep-list
(D9) is the actionable result of this audit and is pinned by Part 5's field
table test, so a later field added to the manifest fails that test until its
New loop fate is decided.

## 7. Hardware-only

Audible isolation of Listen from captures and takes (Part 6b), real drive
behavior for export, backup and restore including FAT32 and exFAT, unplug
mid-write and Retry (Parts 7 and 8, both after #1177's `StorageRepository`
stands behind the port), Eject refused during a Library write naming its
purpose, and the footswitch return-to-Tracks timing on the console.
Everything else is verified by the commands above.

## 8. Review record and answered questions

The plan was reviewed on 2026-10-06 and approved with eight required edits,
all applied above: E1 (keep mixdown and stems reachable; DAW package export;
`.als` capture-only) in D13, Part 1 and Part 7; E2 (the playback predicate) in
D8 and Part 4; E3 (bounded audition decode off the UI isolate) in D10, 4.4
and Part 6b; E4 (block-end ack, immediate free when stopped, `LE_ERR_NOT_READY`
on a busy retired slot, reopen as a stop trigger, `le_perf_arm`, engine paths)
in 4.4, D10 and Part 6a; E5 (stale mixdown deleted) in Part 1; E6 (Open
wired in Part 2) in Part 2; E7 (the port shaped like #1177 and copies through
its `copyFile`) in D12, 4.3, Parts 7 and 8; E8 (the key-set field-table test
and the complete D9 keep list) in D9 and Part 5. The review's acceptable
notes are applied too: duplicate and restore rewrite `name` (D5, Part 8),
interrupted saves are not folders (D2, Part 1), the three pen deviations are
listed in section 2, Part 6 is split into 6a and 6b, and the SessionCubit id
migration moved from Part 2 into Part 1.

The three questions the first draft asked were answered (section 3, "Owner
answers recorded"): automatic `New loop N` with no prompt; preserve by saving
first, amended by the coordinator's rule-2 decision that any unsaved change
is preserved and an unchanged rig is not re-saved; the DAW project action on
the recording preview with Re-export removed now, amended by E1. No question
remains open for the build.
