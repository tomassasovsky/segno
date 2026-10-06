# Library and Sessions: full-screen Library, explicit Open, identity, New Loop

Tracking: #1178 (M5 items E7-1..E7-6 of the 2026-10-06 gap inventory),
`stage:plan`, `autonomy:merge-gate` (a redesign of a user-facing surface plus
one new native voice: verifiable here, but taste and blast radius are the
owner's). Base: `origin/claude/segno-integration` at `c3714abc2`. Unless a
branch is named, every `file:line` below is on that head. Precedent for the
format: `docs/plan/2026-10-05-feat-engine-reopen-plan.md`.

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
  after it (`master_bus_frame` `:6588-6589`, `:4096-4130`).
- **Legacy exports.** `SessionRepository.exportMixdown`/`exportStems`
  (`session_repository.dart:593-628`) and `SessionCubit.exportMixdown`/
  `exportStems` (`session_cubit.dart:104-115`) have no caller outside the cubit
  and its state enum (`session_state.dart:37-41`; `tracks_commands.dart:389-391`
  only localizes the outcomes). The DAW export that IS reachable is the
  performance completion sheet's **Re-export** (`performance_completion_sheet.dart:345-353`),
  which calls `PerformanceRecorderCubit.reExport` (`performance_recorder_cubit.dart:592-635`)
  to write `project.als` and `fx-chains.txt` into the finished capture bundle
  through `daw_export` (`:637-656`).
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
| 18/01 `Audio library / Internal` (`bx7vK`), 18/06 `USB disconnected` (`jsmae`), 20/07 `Export a recording` (`KGCxw`), 20/09 `Matching filename`, 20/10 `Connect USB drive`, 20/11 `Export storage error`, 20/12 `Export complete` | The Audio tab geometry (1061-wide file list with a group heading such as `Performances`, 684-wide preview card with kind, name, waveform, controls and actions) and the USB export dialogs. |

Only the Sessions tab, the Audio tab's `Performances` group with Export to USB
and the re-homed DAW export, and section 34 are in this plan. 18/02-18/05 and
18/07-18/15 (prepared audio, backing, Save audio, track import) are E7-7..E7-10.

**Deviations the build must write back into the pen** (a shipped departure is
a design change; this plan does not edit the pen):

1. `Manage` opens a titled options sheet (the `showFxOptionsSheet` idiom,
   `lib/looper/view/fx/fx_options_sheet.dart:24-29`) with `Save`, `Save as…`,
   `Duplicate`, `Rename`, `Move to folder…`, `Delete`. The pen draws the button
   but not the sheet. Section 34's tiles label the same button `Rename`; the
   build follows 19/01.
2. The Audio tab's preview gains a `DAW project` action for a performance
   recording (the owner's re-home of the `.als` export). The pen's four actions
   (`Add to prepared`, `Export to USB`, `Use as backing`, `Use in loop`) stay
   where they are; the two that belong to E7-7/E7-9 are not drawn until those
   parts exist (no disabled stand-ins for features that do not exist).

## 3. Decisions

Owner decisions are repeated inline above. The rest are taken under the
standing rules (1 preserve installs, 2 fail safe, 3 no silent change,
4 consolidate, 5 drop uncertain native state with a notice); the build
records any departure.

- **D1 Identity is a directory id; the name is manifest metadata.** A bundle
  is `sessions/[<folder>/]<id>/`. New bundles take `s-YYYYMMDD-HHMMSS`
  (plus `-2`, `-3` on a same-second collision), the convention
  `performance_slug.dart` already uses for captures. The manifest gains an
  optional `name` field read leniently; absent, the name is the directory
  basename, which is exactly what every existing bundle shows today (rule 1,
  one line, no migration pass). `formatVersion` stays 11: a bump would turn
  every installed session into `SessionUnsupportedVersion`
  (`session.dart:756-760`). Rename rewrites `name` only (accepted 6.2,
  "Rename is metadata-only"); it never moves audio.
- **D2 Folders are directories, one level.** `sessions/<folder>/` with no
  manifest is a folder; bundles directly under the root are `Unfiled`. Move
  is a same-filesystem `rename`. No index file (rule 4: the filesystem is the
  one truth; `session-bundle-format.md` already says the manifest is the only
  truth inside a bundle). An empty folder persists until deleted from
  `Manage`; the folder chips are the directory list, nothing else.
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
  place of names (`session_repository.dart:385-398`, `:451-511`).
- **D6 Delete protection.** `Delete` is disabled in `Manage` for the current
  session, and `SessionCubit.deleteSession` refuses it too (the cubit is the
  authority, the sheet is fast feedback). Nothing else needs protecting yet:
  every bundle owns its audio files (duplicate copies them); the first shared
  reference arrives with backing (E7-7/E7-8), which must then add a
  reference check before deleting an audio item. Recorded as a non-goal.
- **D7 Preserve outgoing work by saving it.** `Open` and `New loop` first
  save the outgoing rig: to its identity when it has one, under an automatic
  name when it has none and holds recorded content, nothing when it is empty
  and unnamed. A failed save stops the operation before anything else changes
  (19/05, rule 2). The cost is a redundant write-back when nothing changed;
  the engine exposes per-track `audio_rev` (`segno_engine_api.h:2892-2895`),
  so a later part can skip the audio files when every rev matches the last
  save, but settings and chains have no single revision, so the manifest
  would still be rewritten. Not this plan.
- **D8 Interruption confirm.** `Open session` while the transport is running
  (`LooperState.transport.isRunning`) asks `Stop playback and open <name>?`
  with `Cancel` / `Open`. `New loop` always asks (19/02). Neither asks when
  stopped. Restored transport starts stopped (#1134).
- **D9 New loop is `applySession` of an empty rig.** The new rig keeps every
  manifest field except `tracks` (none), `baseLengthFrames` and `loopBars`
  (0: an empty rig with a grid would lock the next take's length, the hazard
  `session_repository.dart:733-739` already names), `primaryTrack` (-1; the
  crown dies with the content) and `laneMix` (per captured lane). It keeps
  tempo, signature, mode, record and playback defaults, click, count-in, Fade
  durations, track levels and pans, lane inputs/outputs/counts, input and
  output setup, all four FX stages and the pedal remap. The apply path
  already forgets lane mutes with the clear and resets Fade with the material
  (`looper_repository.dart:3884-3885`, `LE_CMD_RESET_FADE` applied at `engine_process.c:3159`,
  `segno_engine_api.h:516`). Reverse, Transpose and Speed do not exist yet;
  when E6-1/E6-4/E6-5 land their reset belongs in this same apply path, not in
  a Library-side list. The new identity is created at once by saving the
  empty rig (manifest only, no audio), so the stage header reads `New loop 2`
  (19/06) and the Library lists it as `Current session`.
- **D10 Listen is a native audition voice fed from `mixdown.wav`.** The
  accepted behavior wants audition isolated from the rig and not loading the
  session (6.3). The engine owns the only output device, so the voice must be
  native. It is one interleaved buffer the control thread publishes and the
  callback sums into one output pair **after** the performance tap and
  **before** the master bus, so stems and `master.pcm` never contain it and
  the limiter still protects (`engine_process.c:6580-6589`). No resampling:
  a file at another rate is refused and the panel says so (the same honesty
  as `SessionSampleRateMismatch`). Audition ends on navigation, on `Open`,
  `New loop`, performance arm and any track entering recording. For a
  performance recording the same voice plays its `master.wav`.
- **D11 The waveform is real or absent.** Preview lanes draw peaks decoded
  from the lane-0 live layer WAV (`track{c}_lane0_L{undoCount}.wav`) in an
  isolate; until Part 6 lands, lane rows draw length only (the clip's width
  share), never a placeholder waveform (accepted 6.3, "missing waveform data
  is explicit").
- **D12 USB through a port.** The Library depends on
  `RemovableVolumes` (section 4.3), an interface this plan defines in the app
  layer, with `InternalOnlyVolumes` as the shipped default. #1177's service
  provides the adapter; until then the `USB` segment shows the pen's
  "Connect a USB drive" state (18/06) and every USB action is unavailable
  with that reason. No fake drive outside tests.
- **D13 DAW export moves, legacy session exports go.** The completion
  sheet's `Re-export` button, `PerformanceRecorderCubit.reExport`,
  `isReExporting` and `reExportFailed` are removed; the `.als` and
  `fx-chains.txt` writer becomes a shared app-layer function the capture
  pipeline and the Library > Audio `DAW project` action both call.
  `SessionRepository.exportMixdown`/`exportStems` and the two `SessionCubit`
  methods and outcomes are deleted (unreachable today; D3 in the inventory
  resolved by the owner's re-home). The `mixdown.wav` write stays: Listen
  needs it.
- **D14 Footswitch in the Library.** A footswitch press while the Library is
  open returns to Tracks before it acts, as the dialog does today
  (`sessions_manager_cubit.dart:28-33`), and stops any audition. Encoder
  turns do not. New loop by foot is E6-9 and binds to the same
  `SessionCubit.newLoop` later.

## 4. Architecture

### 4.1 Ownership

| Concern | Owner | Notes |
|---|---|---|
| Catalog layout, ids, folders, lenient summaries, previews, backup and restore file I/O, audition file read | `SessionRepository` (`packages/session_repository`) | Path-addressed; knows nothing about USB or the engine's transport. |
| Audition voice | `AudioEngine` (`packages/segno_engine`), new `EngineAudition` role interface | Native contract in 4.4. |
| Current identity, Save / Save as / Duplicate / Rename / Delete / Move, Open with preservation, New loop | `SessionCubit` | Already composes the session, looper and performance repositories and the settings coordinator (`session_cubit.dart:25-67`). Keeps its `_run` envelope, boot-recovery fence and `runExclusive` ordering. |
| Library presentation state: tab, location, search text, folder filter, selected id, preview facts and peaks, audition progress, pedal dismissal | new `LibraryCubit` (`lib/library/cubit/`) | Replaces `SessionsManagerCubit`. Reads `SessionCubit` state through the view, never the other way round. |
| Removable volumes | `RemovableVolumes` port (`lib/library/application/removable_volumes.dart`) | Default `InternalOnlyVolumes`; #1177 supplies the adapter. |
| Finished recordings list, their facts and export copy | `PerformanceRepository` (`packages/performance_repository`) | Gains `listCaptures()`; the bundle shape is already fixed (`performance_repository.dart:979-1000`, `manifestName`). |

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
`newSessionId(now)`, `save(path, …)` unchanged plus a `name:` argument,
`read(path)` unchanged. Name collisions are checked on display names,
case-insensitively, and still raise `SessionNameCollision`.

### 4.3 The removable-volumes port

```dart
abstract interface class RemovableVolumes {
  /// Mounted, readable drives; empty when none. Emits on every change.
  Stream<List<RemovableVolume>> get volumes;
  List<RemovableVolume> get current;
  /// Runs [body] while the drive is leased for writing: the storage service
  /// refuses Eject for the lease's duration and the body receives the mount
  /// path. Throws [VolumeUnavailable] when the drive is gone before or during.
  Future<T> withWriteLease<T>(String volumeId, Future<T> Function(String mountPath) body);
}
@immutable class RemovableVolume { final String id, label, mountPath; final int? freeBytes; final bool writable; }
class VolumeUnavailable implements Exception { final String volumeId; }
class InternalOnlyVolumes implements RemovableVolumes { /* always empty */ }
```

Library layout on a drive: `<mount>/Segno/Sessions/<id>/` (a bundle copy with
its manifest) and `<mount>/Segno/Performances/<file>.wav` (20/12 "USB drive /
Performances"). #1177's adapter implements the port over its service; nothing
in this plan imports that service.

### 4.4 Native audition contract (`segno_engine_api.h`)

```c
/* Audition: the Library's isolated preview voice. Control thread. Copies
 * `frames` interleaved float32 samples (`channels` 1 or 2) into an engine-owned
 * buffer and plays it once (no loop) into output pair `bus`, summed AFTER the
 * performance tap and BEFORE the master bus (gain, limiter, metering), so
 * stems and master.pcm never contain it. Refused with LE_ERR_INVALID when
 * frames <= 0, channels not 1 or 2, sample_rate != the engine rate, bus out of
 * range, or performance capture is armed; LE_ERR_NOT_RUNNING when not
 * configured. A second start replaces the first at the next block. */
LE_EXPORT int32_t le_engine_audition_start(le_engine*, const float* pcm,
    int32_t frames, int32_t channels, int32_t sample_rate, int32_t bus);
LE_EXPORT int32_t le_engine_audition_stop(le_engine*);
/* le_snapshot: int32_t audition_frames (0 = none); int32_t audition_pos. */
```

Mechanics: `_Atomic(le_audition*) a_audition` plus an audio-thread
`a_audition_ack` generation, the same publish/ack shape the state commands
use (`engine_private.h:1019-1036`). The callback loads the pointer once per
block, mixes `frames - pos` samples (or to the block end) and advances
`audition_pos`; at the end it publishes `audition_frames = 0`. `stop`,
`start` (replace), `le_engine_perf_arm` and configure park the old buffer and
free it on the control thread once the ack passes the generation; nothing is
freed on the audio thread and nothing allocates there. `le_engine_perf_arm`
also clears the pointer, and the mixer skips the voice while `e->perf.armed`,
so a race cannot put audition samples into a capture. `LE_CMD_AUDITION_STOP`
is not needed: publication is an atomic pointer swap, not a command.

## 5. Parts

Sizes are production lines (Dart or C), excluding tests, generated bindings
and docs. Dependencies: P1 -> P2 -> P3 -> P4 -> P5; P6 after P2; P7 after P2
(Listen on recordings after P6); P8 after P3. Every part leaves the app
working end to end and ships its own tests.

### Part 1: catalog identity, folders, lenient summaries, previews (about 420 lines)

Files: `packages/session_repository/lib/src/models/session_summary.dart`
(replace), new `models/session_preview.dart`, `session_repository.dart`
(`:303-427` catalog block rewritten for ids and folders; `save` gains `name`;
`:593-628` `exportMixdown`/`exportStems` deleted; `_sessionFrom` writes
`name`), `models/session.dart` (optional `name`, read at `:745-775`, written at
`:1018-1020`, `formatVersion` unchanged), `session_name.dart` (`sessionSlug`
stays for display-name sanitizing; the slug is no longer a path), new
`session_id.dart` (`newSessionId`, pattern `performance_slug.dart`),
`docs/design/session-bundle-format.md` (layout and `name`).

Behavior: listing walks one level (section 3 D2), reads each manifest as a
JSON map for the summary keys (D3) and sorts by `modifiedAt` descending;
`readPreview` uses `Session.fromJson` and derives bars from `lengthFrames`,
`tempoBpm`, `tsNum`/`tsDen` and the sample rate (0 when `tempoBpm == 0`).
Automatic names count every catalog name. Folder and name validation reuse
`sessionSlug` (letters, digits, space, hyphen, underscore).

Tests (`packages/session_repository/test/session_catalog_test.dart` rewritten,
`session_repository_test.dart` extended): a legacy `sessions/<slug>/` bundle
lists with `id == name == slug`; a bundle with `name` lists by its name; an
unparseable manifest lists `unreadable` by basename and `readPreview` throws
the typed refusal; folders list and bundles inside them carry `folder`; a
nested second level is ignored; `moveSession` to and from `Unfiled`;
`renameSession` changes only the manifest and keeps every WAV byte-identical;
duplicate and delete by id; `nextAutomaticName` skips `New loop 1` and
`new loop 3` to return `New loop 2`; `deleteFolder` refuses a non-empty
folder; `newSessionId` same-second suffixing; the mixdown is still written
and the two export methods are gone (compile-time).

```success-criteria
GOAL: Sessions have a stable directory identity, a renameable display name and one level of folders, listed without loading anything, and every installed bundle still lists and loads unchanged.
SUCCESS CRITERIA:
- A pre-existing `sessions/<slug>/` bundle with no `name` field lists under its slug, previews and loads exactly as before; a bundle saved with `name` lists under that name and keeps `version: 11`. | verify: (cd packages/session_repository && /Users/Tomas/development/flutter/bin/flutter test)
- Rename touches only `session.json`; every layer WAV and `mixdown.wav` is byte-identical before and after. | verify: (cd packages/session_repository && /Users/Tomas/development/flutter/bin/flutter test test/session_catalog_test.dart)
- Folders are directories: create, move in and out, refuse deleting a non-empty folder, ignore a second level; summaries carry name, folder, saved time, track count, tempo, signature and FX count without a full decode. | verify: (cd packages/session_repository && /Users/Tomas/development/flutter/bin/flutter test)
- `exportMixdown` and `exportStems` no longer exist; the package coverage floor of 89% holds. | verify: (cd packages/session_repository && /Users/Tomas/development/flutter/bin/flutter test --coverage) && dart analyze --fatal-infos packages/session_repository
NON-GOALS:
- UI, the cubit, shared audio references, migration of directory names, waveform peaks.
VERIFICATION COMMAND: (cd packages/session_repository && /Users/Tomas/development/flutter/bin/flutter test --coverage) && dart analyze --fatal-infos packages/session_repository
```

### Part 2: the Library shell replaces the Sessions dialog (about 650 lines)

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
`openLibrary`; `SessionCubit` moves to ids (`currentSessionId` plus
`currentSessionName` for the header; `loadNamed` becomes `open(id)` in Part 4,
here only renamed to take an id); delete
`lib/session/view/sessions_manager_dialog.dart`,
`lib/session/cubit/sessions_manager_cubit.dart`, their tests, and the
`sessionsManagerTitle`, `sessionsEmpty`, `sessionNewTitle`, `sessionManage`
strings in `app_en.arb`/`app_es.arb` (new `library*` keys replace them).

Behavior: the Library opens on the Sessions tab with the current session
selected; a tap on a row selects and previews (never loads); the footer reads
`Return to tracks` for the current session and `Open session` otherwise
(`Open` itself is Part 4: until then the button is `Return to tracks` for the
current session and absent for others, so no row can load by accident); the
`Audio` crumb is present and opens the Part 7 tab (until Part 7 the crumb is
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
- Selecting a row changes the preview and footer only; `LooperRepository.applySession` is never called by a selection (mock verify). | verify: /Users/Tomas/development/flutter/bin/flutter test test/library
- Search, `All`/`Unfiled`/folder chips and the `USB` location with the default port behave as specified; a footswitch press pops the page. | verify: /Users/Tomas/development/flutter/bin/flutter test test/library test/app/view/app_test.dart
- Analyzer, Bloc lint, formatting and the root 90% coverage floor stay green. | verify: dart analyze --fatal-infos && bloc lint lib test packages && /Users/Tomas/development/flutter/bin/flutter test --coverage
NON-GOALS:
- Manage actions, Open, New loop, Listen, the Audio tab's contents, USB backup.
VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos && bloc lint lib test packages
```

### Part 3: Manage: Save, Save as, Duplicate, Rename, Move to folder, Delete; New folder; automatic names (about 380 lines)

Files: new `lib/library/view/library_manage_sheet.dart` (the options sheet,
deviation 1), `library_sessions_tab.dart` (`Manage`, `New folder`, storage
error banner 19/05), `lib/session/cubit/session_cubit.dart` (`save` with
automatic name, `saveAs(name)`, `duplicateSession(id, name)`,
`renameSession(id, name)`, `moveSession(id, folder)`, `deleteSession(id)`
refusing the current id with new `SessionError.currentSessionProtected`;
`saveAsRequested`, `mixdownExported`, `stemsExported` removed from
`session_state.dart:19-42`), `tracks_commands.dart:371-395` (the quick Save
toast names the automatic name; no prompt), l10n keys.

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
`test/library/view/library_manage_sheet_test.dart` (rows, disabled Delete on
the current session, folder picker, the banner on failure).

```success-criteria
GOAL: Every identity operation is explicit and distinct, naming is optional, and no failure changes the catalog or the open session.
SUCCESS CRITERIA:
- Save on an unnamed rig creates `New loop N` without a prompt; Save as creates a new current identity; Duplicate copies a saved session without touching the current pointer; Rename is metadata-only; Delete refuses the current session. | verify: /Users/Tomas/development/flutter/bin/flutter test test/session/cubit/session_cubit_test.dart
- A failed save shows "Could not save your current loop. Nothing was changed." and the catalog, current pointer and every bundle on disk are unchanged. | verify: /Users/Tomas/development/flutter/bin/flutter test test/library test/session
- `saveAsRequested`, `mixdownExported` and `stemsExported` no longer exist. | verify: ! grep -rn "saveAsRequested\|mixdownExported\|stemsExported" lib && dart analyze --fatal-infos
NON-GOALS:
- Open, New loop, USB, shared-audio reference checks.
VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos && bloc lint lib test packages
```

### Part 4: explicit Open that preserves outgoing work and confirms interruption (about 260 lines)

Files: `session_cubit.dart` (`open(id)`: the preservation step of D7, then the
existing load body `:231-384` with the id-based path; the no-op when
`id == currentSessionId`), `library_sessions_tab.dart` (`Open session`
footer, the D8 confirm dialog via `showConsoleConfirmDialog`
`console_surface.dart:2960`, the 19/05 banner on a preservation failure),
`library_cubit.dart` (stop audition hook for Part 6), l10n.

Behavior: `Open` runs inside one `runExclusive` scope: preserve (save or
automatic save or nothing) -> read the target -> disarm capture -> apply
stopped -> make current. A preservation failure aborts before the read and
shows 19/05; a target refusal (rate, version, corrupt layers) shows the
existing localized banners in the preview and leaves the outgoing rig and
its just-written save in place. While running, the transport is asked first
(D8); `Cancel` changes nothing.

Tests: `session_cubit_test.dart` (outgoing named rig is saved before the
target applies, verified by call order on the mocks; an unnamed rig with
content is saved under an automatic name; an empty unnamed rig writes nothing;
a preservation failure applies nothing and the state carries the error; a
target `SessionSampleRateMismatch` after a successful preservation leaves the
current pointer on the outgoing session), `library_page_test.dart` (running
transport shows the confirm; `Cancel` calls nothing; stopped transport opens
without asking; the current session's footer is `Return to tracks`).

```success-criteria
GOAL: Opening a session is an explicit act that never loses the outgoing work and never interrupts playback without asking.
SUCCESS CRITERIA:
- With a named outgoing session, Open saves it first and then applies the target stopped; with unnamed recorded content it saves `New loop N` first; with an empty unnamed rig it saves nothing. | verify: /Users/Tomas/development/flutter/bin/flutter test test/session/cubit/session_cubit_test.dart
- A failed preservation shows the 19/05 banner and applies nothing; a refused target after preservation keeps the outgoing session current and its save on disk. | verify: /Users/Tomas/development/flutter/bin/flutter test test/session test/library
- A running transport is asked before Open; Cancel changes nothing; a stopped transport is not asked. | verify: /Users/Tomas/development/flutter/bin/flutter test test/library
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
session is saved first; the new identity is `New loop N` and current; a
preservation failure applies nothing), `test/session/session_mapping_test.dart`
(`rigForNewLoop` field table), `library_page_test.dart` (the sheet's copy
names the outgoing session; `Cancel` calls nothing), and one real-engine test
in `test/session/` (record two tracks with a muted lane and a mid-fade, New
loop, then: every track EMPTY, no lane muted, every Fade at unity, master
length 0, tempo and mode unchanged, the previous session reloadable
byte-exact).

```success-criteria
GOAL: New loop preserves the current session, clears every track and its history, keeps the sound, tempo and pedal setup, and resets the performance transforms, by foot or touch later through one cubit method.
SUCCESS CRITERIA:
- The applied rig keeps every D9 field and drops tracks, grid, crown and lane mix (field table test). | verify: /Users/Tomas/development/flutter/bin/flutter test test/session/session_mapping_test.dart test/session/cubit/session_cubit_test.dart
- On the real engine, after New loop every track is EMPTY with no mute and Fade at unity, the master length is 0 and the tempo and mode are unchanged; the outgoing session reloads byte-exact. | verify: /Users/Tomas/development/flutter/bin/flutter test test/session
- The stage header reads the automatic name and the Library lists it as the current session. | verify: /Users/Tomas/development/flutter/bin/flutter test test/library test/looper/view
NON-GOALS:
- The foot binding (E6-9), Reverse/Transpose/Speed resets (land with E6-1/4/5 in the apply path), backing.
VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos && bloc lint lib test packages
```

### Part 6: Listen and the preview waveform (native about 190 lines, Dart about 380 lines)

Files, native: `segno_engine_api.h` (section 4.4 contract, snapshot fields),
`engine_private.h` (`a_audition`, `a_audition_ack`, parked buffer),
`engine_commands.c` (start/stop/park/free), `engine_process.c` (one mix step
between `output_bus_frame` and `master_bus_frame` at `:6580-6589`, the
`perf.armed` skip), `engine.c` (free on configure and quiesce),
`engine_snapshot.c`, new `src/test/test_engine_audition.h` included from
`test_engine_core.c` like `test_engine_reopen.h` (`:33541`). Dart engine:
`audio_engine.dart` (`EngineAudition` role on `AudioEngine`),
`native_audio_engine.dart`, `pumped_native_engine.dart`, `mock_audio_engine.dart`
and the test fakes; bindings regenerated and formatted (`ffigen.yaml`,
`dart format` per `docs/PROGRESS.md`). Repository: `session_repository.dart`
(`startAudition(path)` decoding with `WavCodec.decodeFloat32`
(`packages/wav_codec/lib/src/wav.dart:90`), `stopAudition()`,
`auditionProgress()`; `readPeaks(id, channel, buckets)` in `Isolate.run`).
App: `library_cubit.dart` (Listen state, a 100 ms progress timer while
playing, stop on navigation, Open, New loop, pedal press, capture arm and any
track recording via `LooperBloc` state), `library_preview_card.dart`
(`Listen`/`Stop` 160 x 64 with progress; lane peaks).

Native tests (literal oracles, `test_engine_audition.h`): a 64-frame mono
ramp into bus 0 appears exactly once on both channels of the pair and the
next block is silent, `audition_pos` advances by the block and
`audition_frames` reads 0 after the end; a stereo buffer keeps L/R
interleave; stop between blocks silences the next block and the parked
buffer is freed (ASAN); a second start replaces the first with no leak; with
`perf` armed the start is refused and an armed capture after a start finds
the voice cleared, the master ring containing no audition sample; master gain
0.5 halves the voice and a ceiling of 0.25 limits it; with a playing loop the
output equals loop plus voice sample-exactly; a rate mismatch, channels 3 and
frames 0 are refused; configure frees the buffer; a track recording while the
voice plays records none of it (the lane capture reads inputs, not outputs,
`engine_process.c:6539-6557`).

Dart tests: `pumped_native_engine_test.dart` (start, progress, stop through
the real FFI), `session_repository_test.dart` (`startAudition` of a bundle's
`mixdown.wav` hands the decoded frames at the bundle rate; a 44.1 kHz file on a
48 kHz engine is refused with a typed error; `readPeaks` of a known ramp),
`library_cubit_test.dart` (Listen ends on each of the six triggers),
`library_page_test.dart` (the button and progress; lanes draw peaks when
present and length-only when the read fails).

```success-criteria
GOAL: Listen plays a session's saved preview through an isolated native voice that never reaches stems, captures or recordings, and the preview lanes draw real peaks or nothing.
SUCCESS CRITERIA:
- Native: the voice sums exactly once into the chosen pair after the performance tap and before the master bus; stop, replace, perf arm and configure free the buffer on the control thread; refusals match the contract. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- Sanitizer and telemetry-off builds pass; bindings and symbol parity are clean. | verify: EXTRA_CFLAGS='-fsanitize=address -g' bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-DLE_CALLBACK_TELEMETRY=0' bash packages/segno_engine/src/test/run_native_tests.sh && (cd packages/segno_engine && dart run ffigen --config ffigen.yaml && dart format lib/src/generated/segno_engine_bindings.dart && git diff --exit-code lib/src/generated)
- Audition ends on navigation, Open, New loop, a footswitch press, performance arm and a track entering recording; a rate-mismatched file is refused with the reason shown. | verify: /Users/Tomas/development/flutter/bin/flutter test test/library && (cd packages/session_repository && /Users/Tomas/development/flutter/bin/flutter test)
- Appliance: Listen is audible on the main outputs, a performance recording armed during Listen contains none of it, and a loop recorded during Listen contains none of it. | verify: manual on the console: 1. Listen, hear the preview. 2. Arm Record performance; master.wav is silent where the preview was. 3. Record a take during Listen; the take holds only the input. [HARDWARE]
NON-GOALS:
- Resampling, looping the preview, audition of arbitrary files, a second output device.
VERIFICATION COMMAND: bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-fsanitize=address -g' bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-DLE_CALLBACK_TELEMETRY=0' bash packages/segno_engine/src/test/run_native_tests.sh && /Users/Tomas/development/flutter/bin/flutter test
```

### Part 7: Library > Audio with Performances, Export to USB and the re-homed DAW export (about 520 lines)

Files: `packages/performance_repository/lib/src/performance_repository.dart`
(`listCaptures()` -> `CaptureSummary(path, slug, name, startedAt, durationFrames,
sampleRate, hasDawProject)` from `performance.json`, skipping unfinalized and
`recovered/` bundles; `copyTo(path, destinationDir, {conflict})` with
temp-then-rename), new `lib/performance/application/daw_project_export.dart`
(the writer moved from `performance_recorder_cubit.dart:637-656`, called by
`_finishRender` `:528-560` and by the Library), `performance_recorder_cubit.dart`
and `performance_recorder_state.dart` (`reExport`, `isReExporting`,
`reExportFailed` removed), `performance_completion_sheet.dart:315-353`
(`Re-export` button and banner removed), new `lib/library/view/library_audio_tab.dart`
(18/01 geometry: `Internal`/`USB drive`, `Search audio`, the `Performances`
group, the 684-wide preview with kind `WAV`, duration, name, waveform via
Part 6's peaks over `master.wav`, `Listen` through the same voice, actions
`Export to USB` and `DAW project`), `library_cubit.dart` (Audio tab state,
export progress and conflict), the four dialogs 20/09-20/12 (`Already on
USB` with `Cancel`/`Keep both`/`Replace file`; `Connect a USB drive` with
`Cancel`/`Try again`; `Not enough space. Free up storage and try again.`;
`Exported to USB` with `Done`), l10n.

Behavior: export runs inside `RemovableVolumes.withWriteLease`; the
destination is `<mount>/Segno/Performances/<name>.wav`; a free-space check
against `RemovableVolume.freeBytes` precedes the copy; the copy writes
`<name>.wav.part` and renames; cancel, a missing drive, a full disk or a
write error delete the part file and leave the internal recording untouched
(accepted 6.8). `DAW project` writes `project.als` and `fx-chains.txt` into
the bundle and reports success or the typed failure in the preview. With
`InternalOnlyVolumes` the `USB drive` segment shows 18/06 and `Export to USB`
opens 20/10.

Tests: `packages/performance_repository/test` (listing skips unfinalized and
recovered bundles, reads the slug and duration; `copyTo` conflict policies,
part-file cleanup on a thrown write), `test/performance/cubit/performance_recorder_cubit_test.dart`
(render still writes the DAW files through the shared function; `reExport`
gone), `test/performance/view/performance_completion_sheet_test.dart:351-381`
removed, `test/library/view/library_audio_tab_test.dart` (group, preview,
Listen, the four dialogs driven by a fake `RemovableVolumes`), `library_cubit_test.dart`.

```success-criteria
GOAL: Finished recordings are browsable in Library > Audio, exportable to USB without ever altering the internal copy, and the DAW project export lives there and nowhere else.
SUCCESS CRITERIA:
- The Performances group lists finalized captures with name and duration and excludes unfinalized and recovered bundles. | verify: (cd packages/performance_repository && /Users/Tomas/development/flutter/bin/flutter test) && /Users/Tomas/development/flutter/bin/flutter test test/library
- Export to USB with a fake volume: success, Keep both, Replace, cancel mid-copy, drive removed, disk full and a write error each leave the internal recording byte-identical and never leave a `.part` file. | verify: /Users/Tomas/development/flutter/bin/flutter test test/library && (cd packages/performance_repository && /Users/Tomas/development/flutter/bin/flutter test)
- `DAW project` writes `project.als` and `fx-chains.txt` into the bundle; the completion sheet has no re-export control; `reExport` no longer exists. | verify: /Users/Tomas/development/flutter/bin/flutter test test/performance test/library && ! grep -rn "reExport" lib
- The performance repository's 99% floor and the root 90% floor hold. | verify: (cd packages/performance_repository && /Users/Tomas/development/flutter/bin/flutter test --coverage) && /Users/Tomas/development/flutter/bin/flutter test --coverage
- Appliance: with the #1177 adapter, export a recording to a real drive, then unplug mid-copy and retry. | verify: manual on the console with a FAT32 and an exFAT drive: the file lands under `Segno/Performances`, the interrupted copy leaves no part file, Retry completes. [HARDWARE, after #1177]
NON-GOALS:
- Backing, prepared audio, Use in loop, Save audio, import from USB, preset export (E5-5).
VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test && (cd packages/performance_repository && /Users/Tomas/development/flutter/bin/flutter test --coverage) && dart analyze --fatal-infos && bloc lint lib test packages
```

### Part 8: Sessions > USB: Back up to USB and Restore to Library (about 430 lines)

Files: `session_repository.dart` (`backupTo(id, destinationRoot, {conflict})`
copying the bundle to `<root>/<id>.part/` then renaming to `<root>/<id>/`;
`listBackups(root)` with the same lenient summaries; `restoreFrom(root, id,
{name})` copying into the internal root under a fresh id and, on a name match,
`<name> (2)` (pen `f2sBAc`)), `library_cubit.dart` (backup progress and
cancel, conflict, interruption and retry; the USB location lists backups and
offers `Restore to Library`), `library_sessions_tab.dart` (section 34 tiles:
inline progress "Backing up <name>…" with `Cancel`; `A backup has this name`
with `Cancel`/`Keep both`/`Replace`; `Backup interrupted` "USB drive
disconnected. Nothing was changed." with `Cancel`/`Retry`; the USB list with
`Session`/`Saved` columns and "Adds a new session to Library."), l10n.

Behavior: both directions run inside `withWriteLease` for the drive side;
`Replace` removes the old backup only after the new copy's rename succeeds
(swap through a `.old` rename, then delete); a `VolumeUnavailable` or I/O
error mid-copy deletes the part directory and shows the interruption tile;
`Retry` repeats with the same choices. Restore never touches the live rig; the
restored copy appears selected in the preview with `Open session` (`f2sBAc`).
Backups keep their manifest `name`; the restored id is fresh (`newSessionId`).

Tests: `session_repository_test.dart` (backup to a temp root is byte-identical
per file; Keep both suffixes the backup name; Replace swaps atomically and a
failure before the rename leaves the old backup intact; a thrown write leaves
no `.part`; restore creates a fresh id and `(2)` on a name match; the live
rig's bundles are untouched), `library_cubit_test.dart` (progress, cancel,
interruption, retry with a fake `RemovableVolumes` that drops the volume
mid-copy), `library_page_test.dart` (the six tiles).

```success-criteria
GOAL: A session can be backed up to a drive and restored as an independent copy, and no interruption, conflict or cancel ever changes what was there before.
SUCCESS CRITERIA:
- Backup writes an exact copy under `Segno/Sessions/<id>/` with no part directory left on success, cancel, drive loss or write error; Replace leaves the old backup when the new copy fails. | verify: (cd packages/session_repository && /Users/Tomas/development/flutter/bin/flutter test)
- Restore adds a new identity, suffixes a matching name with ` (2)`, and never calls `applySession`. | verify: (cd packages/session_repository && /Users/Tomas/development/flutter/bin/flutter test) && /Users/Tomas/development/flutter/bin/flutter test test/library
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

Audible isolation of Listen from captures and takes (Part 6), real drive
behavior for export, backup and restore including FAT32 and exFAT, unplug
mid-write and Retry (Parts 7 and 8, both after the #1177 adapter), and the
footswitch return-to-Tracks timing on the console. Everything else is
verified by the commands above.

## 8. Open questions for the owner

Only genuine product-direction points; the defaults above are taken under
the standing rules and the build proceeds on them.

1. **Save with no identity** now saves under `New loop N` without a prompt
   (D4). Alternative: keep a name prompt on the very first Save and use
   automatic names only for New loop and Open's preservation. Default taken:
   no prompt; Rename is in Manage.
2. **Preservation always writes back** (D7), so Open and New loop cost one
   save even when nothing changed. Default taken: correctness first; skip-when-
   unchanged is a later optimization behind `audio_rev`.
3. **The DAW project action's placement** (deviation 2): in the recording's
   preview actions under Library > Audio, alongside Export to USB. Confirm
   this is the intended home, and that the completion sheet should lose its
   Re-export control now rather than with E7-11's redesign of that sheet.
