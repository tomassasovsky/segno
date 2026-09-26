

=====
# PR #1011 feat(console): accepted Tracks view, selected-track display and first-take crown [open] claude/segno-app-implementation-7c90a8 <- master
labels: stage:in-review,autonomy:merge-gate,ci:green,review:clean,ready-to-merge,area:console,area:engine,area:design

## Description

Slice 1 of the accepted Segno design (epic #1009, design under #919). Ledger:
`docs/plan/2026-09-09-segno-implementation-ledger.md`.

**Main display.** `TracksView` is the accepted stage: four columns for the
active bank, each with name + primary crown, number · bars · layers · FX
marker over one whole-track meter (dB-linear over -60..0 dBFS, red clip cap),
the queued-action cue inside the track, a thin progress bar; shared dBFS
scales either side; `StageTopBar` (Library, session name, bank button, Track /
Wave view menu, Settings) and `StageFooter` (BPM · signature, elapsed, OUT
dBFS with CLIP, loop mode). The Wave view shows each track's own waveform with
a bar ruler and playhead. The mode pill, bank pair, readiness strip and the
crown tap are gone.

**Second display.** The 7" follows the selected track: number, crown, name,
state word, bars, its own waveform; footer with tempo and function · bank.
The volume overlay, MIX pill and control back-channel are retired.

**Crown ownership.** The engine crowns the first completed take when nothing
is crowned and clears the crown when every track is empty
(`le_primary_reconcile`); the designation still survives the primary's own
clear while a sibling holds audio (D18). The repository projects the drawn
crown (`resolvedPrimaryTrack`) and no longer re-crowns on restart. Explicit
`crownPrimary` remains the timing handoff for slice 2.

**Snapshot.** Trailing `position_frames` per track and `output_peak`, with
bindings regenerated (the diff also carries the ASIO doc drift the committed
bindings were behind on).

## Plan coverage vs derivations

- Deferred by design record: touch lock (slice 4), Mixer view (slice 3, no
  pan/solo/stereo metering in the engine), explicit crown handoff UI (slice 2).
- Departure from the pen: no CPU readout — the only honest source is the
  #722 telemetry, a session mean kept out of the render-rate snapshot; the
  performance-record light rides the top bar beside Library; bars read `—`
  until a tempo grid counts them. Written back into the pen as
  `c/ Implementation · slice 1` (node `B9Qoq4`, section 25) in the owner's
  working copy, saved through Pen.
- Desktop windows narrower than the pen scale the readout rows down
  (`ShrinkToWidth`) instead of overflowing.

## Checks

- Native: `run_native_tests.sh` 5 suites ALL PASSED (7 new crown / position /
  output-peak tests; the Sync "no primary" premise test rewritten).
- `segno_engine` 242, `looper_repository` 395, root `flutter test` 2170 passed
  with 91.7% line coverage; the 52 author-only screenshot goldens were
  regenerated and eyeballed.
- `dart analyze` clean, `bloc lint` 0 issues / 607 files, cspell clean.
- macOS development build driven live: a defining take crowned GUITAR, a later
  take on BOOM left the crown; tempo derived and clock ran; Wave view switched.

## Review round 1

`/code-review` (high) reported ten findings; all ten are fixed in
`533d8585` (see the ledger's "Review round 1"):

- Engine: configure drops the crown with the tracks it empties; a
  non-defining finalize reconciles the crown; the snapshot publishes what a
  pending arm waits for (`pending_trigger`), with three native tests.
- Stage: the queued cue reads the engine's trigger and names punch-out and
  section arms; the footer shows the count-in; the clip cap retires on a
  timer; wave rows and the second display read a waveform once per content
  change; the bar ruler paints in its own layer; the readout gate ignores a
  growing take and follows the cursor, not only the label; `Track.progress`
  reads 0 while recording; `Track.layers` replaces three copies of the
  formula; dead chrome state removed.
- The package analyzer infos that failed the first CI run are cleared.
- After the fixes: native 5 suites ALL PASSED, `segno_engine` 242,
  `looper_repository` 398, root 2234 tests passed at 91.8% coverage;
  analyzers and `bloc lint` clean.

## Review round 2

A re-review of the fix commit found the waveform cache wrong: the engine's
visual buffer is a lazily swept tap, so a copy keyed on steady facts froze a
flat or stale shape after a take, an undo or a stop. The copy now lives in
`LooperRepository.readTrackWaveform` with a lap-sweep policy (re-read until
the playhead has swept a lap past a content change, every call while
capturing, once per lap while moving, never while still); a queued take-end
reads Play (Overdub under rec/dub, now projected as `TransportState.recDub`);
the arm publish is release/acquire ordered; the ruler layer sits over the
wave again; the footer reuses `countingInLabel`. Details in the ledger.

## Review round 3

A re-review of the round-2 commit: the sweep is now measured on the clock
the engine buckets the tap on (the master loop; the track's own loop in
Free and Song), since a track's progress was the wrong lap for a multiple
and a Sync division; copies of tracks that lose their content or vanish
with a stopped engine are dropped per projection; `setRecDub` re-projects;
the ruler test asserts the layer order. Accepted as is: a rec/dub take-end
whose track had a mute deferred during the take lands playing (no
pending-mute fact reaches the UI); wrap detection needs a read per half lap,
which the visible stage and the second display's per-poll push provide.

## Not verified here

- The 7" face on a real second display (this Mac has one; the app skips the
  window). Widget tests cover the face and the push wiring.
- Appliance displays, touch, pedal LEDs and real audio levels.

## Type of Change

- [x] ✨ New feature (non-breaking change which adds functionality)
- [x] ❌ Breaking change (fix or feature that would cause existing functionality to change)
- [x] 🧪 Test





=====
# PR #1013 feat(engine): mode rules and reversible edits for the accepted design (slice 2a) [open] claude/segno-slice2-edits-1012 <- claude/segno-app-implementation-7c90a8
labels: stage:in-review,autonomy:merge-gate,ci:red,review:pending,area:console,area:engine

Part 2a of slice 2 (#1012, epic #1009). Stacked on #1011 (slice 1); retarget to master once that merges. Does not close #1012 (parts 2b and 2c follow).

## What changed

- **Mode changes with recorded audio** follow the accepted contract (`docs/design/2026-09-07-loop-mode-transitions-ux.md`). The engine measures what a change would do (`le_engine_looper_mode_gate`: open, capturing, queued, spans, playing). Multi needs equal spans; Sync and Band need whole multiples of the primary or the divisions the engine plays (a half or a quarter); Song and Free take anything. A playing rig is stopped ahead of the switch by the engine itself, so the switch lands on a stopped rig; the app asks "Stop loops and switch" first. Captures, queued arms and unfit spans refuse with their reason. Nothing is cleared, trimmed, repeated or stretched to make a mode fit; the old clear-then-switch flow and its strings are gone. Landing a switch re-clocks the takes: into Song/Free each take runs its own clock at its length and the master goes dormant; into Multi/Sync/Band the master is re-established from the primary's span and each take's multiple or division is re-derived from its unchanged length.
- **Undo during an overdub pass** punches out now (not at the grid) and peels the pass once it retires; redo puts the partial pass back without resuming the capture.
- **Undo during a take** cancels it: the take is finalized at its captured length exactly as a press would end it (a defining take still establishes the grid and tempo), the track reads empty, and redo plays it immediately. A later take keeps its whole-loop span with silence outside what was captured.
- **A user clear on a capturing track** freezes the take stopped at the clear and keeps it restorable; undo brings it back stopped, never as a resumed capture.
- **Clear All is one grouped edit** (`LooperRepository.clearAll`): the next undo on any member restores every member, the next redo re-clears the group; the group dissolves when a member loses its restore point. The Undo pedal and key reach the group through the ordinary undo.
- The console confirm dialog wraps long button labels instead of overflowing.

Accepted as is (documented in the ledger): the accepted mode cards with per-card reasons are slice 2c; this part surfaces the reason in a snackbar from the existing chooser.

## Checks

- Native: 5 suites ALL PASSED, also under `-fsanitize=address` and `-DLE_CALLBACK_TELEMETRY=0`; 10 new or rewritten tests (mode gate, re-clocking, undo during overdub and takes, clear during capture, partial-take silence).
- `segno_engine` 242, `looper_repository` 414, `performance_repository` 111, `session_repository` 84, root 2234 tests at 91.7% coverage; analyzers clean in every touched package; `bloc lint` clean; cspell clean. FFI bindings regenerated and formatted.

## Review round 1

Three independent review passes over the first commit reported real problems, all fixed in `7dd83dcf`: a cancelled take that captured nothing acked its state command twice; the cancel pre-zeroed the published length although the audio thread can decline a cancel that raced a finalize; a late cancel report could file a redo slot after a clear or a fresh take; an undo queued behind a freezing clear peeled a layer instead of restoring the frozen take; a freezing clear on a take with nothing captured finalized a one-frame master; Multi's gate refused the 2x takes Multi itself records (now: whole multiples of the shortest take, with one base-channel helper shared by both threads); the switch into a shared-clock mode did not re-establish the tempo grid; the remembered and persisted looper mode came from the call rather than from what the engine reports; the mode flow did not re-check the gate after the confirm; the clear-all group admitted takes with nothing to restore, dissolved on a frozen member's pending point, and re-cleared a member whose next redo was a layer (`le_engine_redo_reclears` now answers that); `ControlCubit.undoClearAll` picked a channel that need not be a member (the repository owns it now); a shipped Dart test still asserted the old content lock; stale content-lock comments. Seven more native tests pin the races and edges.

After the fixes: native 5 suites ALL PASSED, also under ASan and telemetry-off; `segno_engine` 242, `looper_repository` 417, `performance_repository` 111, `session_repository` 84, root 2234 tests at 91.8% coverage; analyzers and `bloc lint` clean.

## Review round 2

A second pass over the round-1 fixes found the remaining one-block races, fixed in `438df12c`: a record pressed behind a cancel in flight now resets the grid the cancel would have set; an undo tapped behind a freezing clear on a recording take waits for the restore point; a clear right behind a queued restore measures the length the restore will publish and keeps a restore point; a declined or void cancel still reports so its flag never lingers; an empty track never shows peelable layers on the wire (caught by the fuzz suite's depths-sane invariant against the real engine); a fresh capture drops a frozen take's layers with its pending point. The repository takes clear-all membership from the engine (`le_engine_clear_restore_pending`), ends a group when the engine retired a member's point or a single clear happens, and drops a mode request the reports never confirm. Four more native tests pin the races.

Also run locally against a hand-built engine library (the `tool/build_test_lib.sh` script does not build on this Mac): `pumped_native_engine_test` 31 and the fuzz suite 29 tests pass. Native 5 suites ALL PASSED plus ASan and telemetry-off; root 2234 at 91.8%; `looper_repository` 420; analyzers clean.

## Review round 3

A third pass (with the reviewer's own engine probes) found three more, fixed in the last commit: a clear right behind a queued restore recorded a master grid of 0 so its own restore left content with no master; a cancel of a take that captured nothing went through the clear handler and drifted the layer generation so later overdub layers never stacked on that track (the count-in grace abort had the same pre-existing bump and takes the same path now); a frozen member whose capture held nothing ended the whole clear-all group. Also: the restart replay of the looper mode is armed as a request; two tests now pin the guards they describe. Native 5 suites plus ASan and telemetry-off, pumped-native 31, fuzz 29, root 2234 at 91.8%, `looper_repository` 422; analyzers clean.

## Review round 4

A fourth pass found three more one-block races, fixed in the last commit: a record pressed on a sibling behind a queued restore of the only take read a master of 0 and took the defining path (the press now reads the master the pending restore re-establishes; one native test pins it); an undo tapped at a frozen clear (the engine queues it and restores the take when the point lands) never put the chains back; the clear-all group refused to answer while a frozen member's point was pending, so an undo in that window split the group (a frozen member is a member from the clear, and the grouped undo taps it too). Also: a mode request now gets six polls of a running engine before it is dropped, since the ring drains on the audio callback and a device can take longer than two polls to deliver its first one. Native 5 suites plus ASan, pumped-native 31, fuzz, `looper_repository` 424; analyzers clean.

## Review round 5

A fifth pass over the round-4 fixes: the new native test passed without its fix (the audio thread decides defining-or-not on its own clock), so it now arms with quantize on, which only a non-defining press does; the repository restored the pre-clear chains for an undo tapped at a frozen clear even when the capture turned out to hold nothing (the engine drops such a tap), so the tap is now held in the repository and taken on the first poll after the point lands, a void capture is forgotten, and a void member leaves the restored group's redo; a frozen capture is remembered audible, as the engine restores it; the running-engine guard on the mode request was unreachable and is gone, and the window is twelve polls. Native 5 suites, `looper_repository` 427, root 2234 at 91.8%; analyzers clean.

Note: this PR targets the slice-1 branch, so the repository's CI does not run on it (only GitGuardian does); the checks above were run locally, and CI runs once it is retargeted to master after #1011 merges.

## Not verified here

Hardware timing of stop-and-switch and of a cancelled take on the appliance.

## Type of Change

- [x] ✨ New feature (non-breaking change which adds functionality)
- [x] ❌ Breaking change (fix or feature that would cause existing functionality to change)
- [x] 🧪 Test







=====
# PR #1014 feat(engine): own record timing, overdub decay and Once per track (slice 2b) [open] claude/segno-slice2b-timing-1012 <- claude/segno-slice2-edits-1012
labels: stage:in-review,autonomy:merge-gate,ci:red,review:pending,area:console,area:engine

## Description

Slice 2b of the accepted-design programme (epic #1009, part 2b of #1012): timing ownership at the engine boundary. Stacked on the slice-2a branch (PR #1013) until that merges; targets `claude/segno-slice2-edits-1012`.

Contract: `docs/design/2026-09-06-loop-setup-ux.md` (Length & quantize, Playback & overdub), `docs/handoff/segno-app/accepted-behavior.md` section 2. Ledger: `docs/plan/2026-09-09-segno-implementation-ledger.md`, "Slice 2b".

- **Record timing is one setting** (`RecordTiming`: Immediately, Loop start, bar, 1/2, 1/4, 1/8, 1/16) that the engine's quantize gate and musical division pair into, by default and per track. The engine gains a per-track division override (`le_engine_set_track_quantize_div`) beside the existing per-track gate; the audio thread reads it live at every boundary check, so two armed tracks can fire on different grids in the same lap. The repository sets gate and division together (`setRecordTiming`, `setTrackRecordTiming`); `Track.recordTimingOverride` is the whole setting and the older three-way `quantizeOverride` is a getter over it.
- **Overdub decay** is a percent (0 = Off keeps every layer whole, 100 replaces the pass) by default and per track (`le_engine_set_track_overdub_feedback`, negative = inherit); the engine takes `1 - decay / 100` as feedback and ramps a change during a pass at the write head over the punch fade instead of stepping. Playback never decays.
- **Once in all five modes.** Free and Song keep the track's own clock wrap; in Multi, Sync and Band a track's lap ends on the shared clock (a k-multiple when the master wraps back to its first segment, a Sync/Band division every base/n frames, a 1x take at the wrap), checked before the grid arms fire so a take finalized at that boundary plays its first lap. The stop is the same transition as a manual Stop, shared by both paths (`le_one_shot_stop`).
- **Count-in and Sound start** exclude each other in the repository's re-apply caches and in the two cubits that own them (each persists the other's cleared value and follows the engine's report), as they already did in the engine (D9). The snapshot publishes `quantize`, `auto_record`, the global feedback and the per-track overrides, so surfaces and the session capture read what the engine holds.
- **Persistence:** per-track overrides in settings (`track_record_timing.N`, migrated from the old `track_quantize.N` gate on first read; `track_overdub_decay.N`), the default decay (`looper.overdub_decay`), and the session manifest captures the defaults like the tempo grid and captures and restores the per-track overrides with the track.
- Bloc events `LooperTrackRecordTimingChanged` and `LooperTrackOverdubDecayChanged`, `PlaybackOptionsCubit`, boot restore of the overrides and the default decay. The routing dialog's three-way now writes a timing override ("always" is the default's own timing when that waits, else the loop top). The accepted editors are slice 2c.

## Checks

- Native: `run_native_tests.sh` 5 suites ALL PASSED, plain, with `-fsanitize=address` and with `-DLE_CALLBACK_TELEMETRY=0`. New tests: per-track division (own boundary, forced loop top beside a sibling on the global grid, inherit, bounds), per-track feedback (override, sibling, inherit, the mid-pass ramp), Once in Multi (1x, a 2x multiple enabled mid-lap), a Sync division, a finalize at the wrap, and the published record start settings with the D9 exclusion.
- Against a hand-built engine library: `pumped_native_engine_test` 31 and the fuzz suite pass.
- Dart: `segno_engine` 242 (snapshot field golden extended), `looper_repository` 430, `settings_repository` 138, `session_repository` 84, `performance_repository` 111; root 2245 tests at 91.7% line coverage; `dart analyze` clean at the root and inside every touched package; `bloc lint` clean; cspell clean on the changed markdown.

## Review round 1

A review pass with native probes found three ordering races and one design gap, fixed in the second commit: the Once check ran before the grid and section arms fired, so a queued punch-out on a Once track landed as a punch-in on the stopped track (an extra lap), a Band section stop restarted the section, and the arm's record handler measured a transport the Once stop had just held and unparked user-stopped siblings; a take finalized mid-lap stopped on the tail of its own recording. The check now runs after both arm loops, a track whose arm fired into an overdub keeps that pass, and each track counts the frames it has been sounding so a lap end only stops it after a whole lap. Five native tests pin these. The count-in and Sound start mirrors in the cubits compared against the engine's report, which reads 0/off while the engine is stopped and would have persisted that; both are now projected from the repository's held values. Native 5 suites plus ASan and telemetry-off, pumped-native 31, fuzz, `segno_engine` 242, `looper_repository` 430, root 2245 at 91.7%; analyzers clean.

Note: this PR targets the slice-2a branch, so the repository's CI does not run on it (only GitGuardian does); the checks above were run locally, and CI runs once it is retargeted after #1013 merges.

## Not verified here

Hardware timing of the per-track grids and of the Once stop on the appliance; the decay ramp wants a listening check on hardware.

## Type of Change

- [x] ✨ New feature (non-breaking change which adds functionality)
- [x] 🧪 Test




=====
# PR #1015 feat(console): the Loop settings pages (slice 2c) [open] claude/segno-slice2c-loop-settings-1012 <- claude/segno-slice2b-timing-1012
labels: stage:in-review,autonomy:merge-gate,ci:red,review:clean,area:console

## Description

Slice 2c of the accepted-design programme (epic #1009), the last part of #1012: the Loop settings surfaces. Closes #1012 with #1013 and #1014. Stacked on the slice-2b branch (PR #1014) until that merges; targets `claude/segno-slice2b-timing-1012`.

Contract: `docs/design/2026-09-06-loop-setup-ux.md`, `docs/design/2026-09-07-loop-mode-transitions-ux.md`, pen section "Loop settings" in `segno-ui.pen`. Ledger: `docs/plan/2026-09-09-segno-implementation-ledger.md`, "Slice 2c".

- **Full-screen pages at the pen's size.** `LoopSettingsPage` is one page stack: the hub (six rows with a live summary each) and its submenus (Loop mode, Recording, Tempo & click with the Time signature page, Length & quantize, Playback & overdub, Audio & tempo), each a 1920 x 1080 canvas scaled down to fit a smaller window (`lib/looper/view/loop_settings/`). They open from the console tray's Loop rail entry and from the desktop Settings list's Loop entry (`openLoopSettings`). The tray's in-panel Loop domain (Tempo / Click / Mode tabs), the tempo keypad sheet, the desktop Tempo and Mode sections and `QuantizeCubit` are gone with their tests, so every loop setting has one path.
- **Defaults and per-track overrides with field-level inheritance.** Length & quantize and Playback & overdub carry a Tracks / Defaults / track selector; a track that departs from the default shows where its value comes from and a Use default button. The repository owns a default length preset and a default Loop/Once beside slice 2b's decay default (`setDefaultLengthPreset`, `setDefaultOnce`, `setTrackLengthPreset` with `null` = follow and `0` = an explicit Auto, `setTrackOnce`), pushes every track's effective value on start and on a mode change, and in Multi gives every track the shared default ("Shared in Multi"; the override stays stored but inactive). A session manifest keeps carrying effective values; on load they become overrides only where they differ from the default. Settings keys `looper.default_length_bars`, `looper.default_once`, `track_once.N`; `loadTrackLengthPreset` now distinguishes inherit from Auto.
- **Record timing has one owner in the app**, `RecordTimingCubit` (a `RecordTiming` value; the gate and the division persisted in their existing keys, applied as one repository call). The two audio-setup toggles read the gate off it. `TempoCubit` no longer carries a division.
- **Mode page:** cards show a refused mode's reason in place of its description (from the engine's gate) and a mode change with playing loops asks "Stop loops and switch" in the pen's own dialog (`requestLooperModeChange` takes a `confirm` callback; the console confirm dialog stays the default for its other callers). The stop body now reads "Playing loops will stop. Recordings stay intact."
- **Recording and Length lock** behind the pen's banner during a capture; Playback stays live. **Audio & tempo** is a readout: the recorded-speed state with its choices disabled and one line saying tempo following is not available yet.
- Undo, Redo and Clear All already reach slice 2a's grouped edits from keys (`Z`, `Y`, `C`, `Shift+C`) and pedals; no new wiring was needed.
- Bloc events `LooperTrackOnceChanged`, `LooperTrackLengthPresetChanged`; `RecordOptionsCubit.defaultLengthBars`; `PlaybackOptionsCubit.once`; boot restore of the defaults and the per-track Once. ~110 new `loop*` l10n strings in en and es.

## Pen departures (written into `segno-ui.pen` as note `c/ Implementation · slice 2c`, section EYla4)

- The pen's own icon glyphs are drawn with lucide equivalents (chevron, check, arrow-left, repeat, arrow-right-to-line, minus, plus, timer, music); the MCP cannot read path geometry.
- The pen's hex colours map onto the console theme tokens as slice 1 did.
- The Length page's lock banner sits under the scope selector with the sections moved down by 92.
- The tempo steps are two labelled buttons (1 BPM / 0.01 BPM) rather than the pen's unlabelled pair.

## Checks

- Root: 2184 tests pass, `dart analyze` clean, `bloc lint` clean; cspell clean on the changed markdown. New tests: `record_timing_cubit_test` and `loop_settings_test` (22: hub summaries and navigation, mode reasons and the dialog, the recording notes and lock, tempo taps and the signature grid, length scope and overrides and Multi sharing and lock, playback overrides and the decay slider, the audio readout).
- Goldens (author machine): `loop_settings_screenshots_test` adds eleven pages including the lock, the dialog and a per-track scope, checked against the pen; the screenshot suites now share one font loader (`test/helpers/screenshot_fonts.dart`) and the loop suite loads the lucide package font so the icons render as glyphs. `settings_audio_recording` and `settings_view_tracks` regenerated; the tray Loop and settings Tempo/Mode goldens are deleted with their tests.
- `looper_repository` 432, `settings_repository` 141; the engine is untouched by this part.

Note: this PR targets the slice-2b branch, so the repository's CI does not run on it (only GitGuardian does); the checks above were run locally, and CI runs once it is retargeted after #1014 merges.

## Review round 1

A review pass (eight finder angles, one verifier per candidate) confirmed ten findings, fixed in the second commit:

- The deleted Click tab had carried the click output routing and level, and a fresh unit's mask of 0 is silent in the engine; a `ClickOutputCard` / `ClickOutputSection` now sit on the Audio tray's Device tab and the desktop Audio section until the slice-3 Mixer owns them. The loop-to-grid sync switch went with the same tab; the design has no equivalent, so the `tempo.sync` key and `TempoCubit.setSyncTempo` are gone and the engine default (on) stands.
- `RecordTimingCubit` keeps the last musical division while the gate is off, so the two on/off switches no longer turn a chosen quarter into the loop top.
- The session manifest carries the length and Once overrides as session-level maps keyed by channel (`Session.lengthPresetOverrides`, `onceOverrides`; an empty channel can carry one, so they do not ride the content tracks) and the rig defaults, instead of effective values (`SessionLoopSettings`, `loopSettingsFromLooper`); `applySession` writes them verbatim after putting every track on the default; `oneShotChannels` is gone.
- The legacy per-track rows (the tray's Tracks > Lengths tab, the desktop Tracks section's length and One Shot rows) dispatched effective values as overrides and could not express "follow the default": retired with `LooperOneShotToggled`, `LooperAllOneShotToggled` and `LooperRepository.setOneShot`.
- A mode request the engine drops now re-pushes the presets it had moved (`_rememberLooperMode`); a mode change pushes only override channels across the Multi boundary and never Once; the setters write the engine before re-projecting (one state per tap); the default setters return early when unchanged; the track count comes from the last projection.
- The mode cards rebuild on the state the gate reads and share `looperModeRefusal`'s wording with the snackbar; the pen's stop dialog lives in `looper_mode_change.dart` as the one confirm.
- `LoopSlider` gained `onChangeEnd`: the tempo drag applies live and persists once; the decay drag previews locally and commits once.
- Cleanups: one page-id enum, the hub reads the defaults from the cubits like the pages, `scopedOrigin`, `LoopOutlinedButton` with four fills, `TrayRailEntry` and a desktop rail action instead of an empty section, 65 orphaned l10n keys and a duplicate `loopLengthAuto` removed, the screenshot suites share one font loader and the tracks goldens load the lucide font.
- Left as is: a `tempo.length_preset.N` of 0 saved by the previous build reads as an explicit Auto override (the repo adds no migrations; Use default clears it in one tap); the pen-width parameters on the Loop widgets stay, since the pages are pen-geometry canvases.

A second check of the round found the per-track manifest fields dropping an override on an empty channel (hence the session-level maps above), the mode cards' rebuild key missing the count-in and the in-flight layer (both added), and a cancelled slider gesture leaving its preview (it now ends at the committed value).

A third check found the slider's tap and drag recognizers each cancelling on the interaction the other wins (a plain tap committed twice, once at a stale value): the commit now rides the raw pointer, one pointer up, one commit. A manifest preset above the engine's 64-bar limit was cached while the engine refused it; every path clamps to the limit.

Checks after the rounds: root 2192 tests pass, `dart analyze` clean at the root and in `looper_repository` (435), `settings_repository`, `session_repository` (91) and `segno_engine`; control center, tracks and loop goldens regenerated and viewed.

## Not verified here

The pages on the appliance's two displays and by encoder; the pen's encoder focus rectangles are not implemented.

## Type of Change

- [x] ✨ New feature (non-breaking change which adds functionality)
- [x] 🧪 Test



=====
# PR #1017 feat(engine): the mix model (slice 3a) [open] claude/segno-slice3-mixer-fx <- claude/segno-slice2c-loop-settings-1012
labels: stage:in-review,autonomy:merge-gate,ci:red,review:clean,area:console,area:engine

## Description

Slice 3a of the accepted-design programme (epic #1009, part 3a of #1016): the mix model at the engine boundary. Stacked on the slice-2c branch (PR #1015) until that merges; targets `claude/segno-slice2c-loop-settings-1012`.

Contract: `docs/design/2026-09-07-audio-routing-ux.md` (input setup: pan, balance, trim), `docs/design/2026-09-07-mixer-performance-ux.md` and `docs/handoff/segno-app/accepted-behavior.md` (Mixer: Solo beside mute, pan, stereo peaks; live-input level never changes captured audio). Ledger: `docs/plan/2026-09-09-segno-implementation-ledger.md`, "Slice 3a".

- **Pan** is a per-lane engine value (`le_engine_set_lane_pan`, -1..1) applied to the lane's stereo pair after its chain and after the wet cache, with a unity-centre balance law: the near side stays at unity and the far side falls on a quarter-sine, exactly silent at the hard side. Centre is bit-identical to the engine before it (every existing native test and fingerprint holds); a lane routed to one output receives the pair's mid. The accepted records leave the pan law to engineering.
- **Solo** (`le_engine_set_track_solo`): while any track is soloed only soloed tracks route. It sits beside mute in the audible gate and never writes it; chains keep running, dry meters keep reading, monitors are unaffected. Performance state: not saved, cleared by a session load.
- **Capture trim** (`le_engine_set_input_trim`, 0..+12 dB linear; the repository speaks -24..+12 dB) scales only the sample a lane records; the monitor, the meters, the clip detector, the trigger and the tuner read the untrimmed input. A direct store, so it holds while stopped.
- **Every hardware input can be monitored**: `LE_MAX_MONITORED_INPUTS` is `LE_MAX_CHANNELS` (a monitor is 3.3 KB; 32 cost 106 KB).
- **The recorded image**: when a take starts the repository fixes each lane's pan and balance gain from its input's setup (a pair member hard on its side, a mono input where its pan put it) and gives the engine the lane's effective pan (image plus the track's pan) and volume (level times the balance gain). Later input edits move the live monitor and future takes only; a track's fader and pan move every lane together. Stereo pairs are two lanes; no stereo lane type was added.
- **Meters**: per-track post-fader stereo peaks (`peak_l`/`peak_r` after volume, pan and the track chain), per-input raw peaks, per-monitor peaks and per-output-channel peaks after the master bus, as trailing snapshot fields; projected per channel the device has.
- **Typed mix targets** (`MixTarget`: track level/pan, input level/pan, pair balance) with a byte-stable canonical string like `FxAddress`, for slice 4's assignments. Output buses join in 3b.
- `InputSetup` (trims, pans, pairs) is the repository's intent, on `LooperState`, in settings per device (`track_pan.N`, `input_trim/pan/pair/balance.<device>.N`), restored at boot, saved with the session (`tracks[].pan`, `lanes[].pan` as the recorded image, `monitors[].pan`, `inputSetup`) and restored on load. Bloc events `LooperTrackPanChanged`, `LooperTrackSoloToggled`, `LooperSoloCleared`, `LooperMixerReset` and the `LooperInputEvent` family.

No UI in this part; the surfaces are 3c (Audio routing and Output setup) and 3d (Mixer).

## Checks

- Native: `run_native_tests.sh` 5 suites ALL PASSED, plain, with `-fsanitize=address` and with `-DLE_CALLBACK_TELEMETRY=0`. New tests: the pan law (centre exact, hard side silent, half pan, clamp, the mono route's mid, reconfigure), solo (gating, independence from mute, monitors through a solo, clearing), trim (capture only, meters and monitor untrimmed, clamp, held while stopped, reconfigure), monitor pan on input 18 of 18, the stereo peaks following the fader. ffigen regenerated and formatted.
- Dart: `segno_engine` 262, `looper_repository` 451 (new `mix_model_test`: pan, solo, reset, trim, pairs and balance, the recorded image, session restore, `MixTarget`, `InputSetup`), `settings_repository` 146, `session_repository` 98, `performance_repository` 111; root 2207; `dart analyze` clean at the root and inside every touched package; `bloc lint` clean; cspell clean on the changed markdown.

Note: this PR targets the slice-2c branch, so the repository's CI does not run on it (only GitGuardian does); the checks above were run locally, and CI runs once it is retargeted after #1015 merges.

## Review round 1

A review pass (four finder angles, six verifiers) confirmed a set of findings, fixed in the second commit:

- A lane's level, image and balance are the repository's own values everywhere: `Lane.volume`/`Track.volume` show the level rather than the engine's level-times-balance, and the manifest carries `lanes[].volume` (level), `lanes[].pan` (image) and `lanes[].balance`, captured from the projection through `SessionLoopSettings.laneMix`; a save/load no longer folds a pair's balance into the level (the first fader move after a load used to un-silence the balanced-out side).
- A lane added after the defining take gets the track pan at once and its own image on its first take (an overdub); a lane that leaves the active window drops its image; boot restores the track pans after the lane counts.
- Solo gates the offline performance render and the DAW export like mute (an audibility gate across every track, seeded from the arm manifest's new per-track `solo`); pan stays out of both, which are mono.
- The meters read what reaches an output (a lane or monitor routed only to a disabled output meters nothing, on both routes); the pan's gains are computed when the pan is set; trim and solos are read once per block; the meter publish and the Dart snapshot lists are bounded by the device's channel counts; the Dart snapshot drops `inputTrim`.
- Pairing is refused while a track fed by either member is armed or capturing (the accepted rule) and past the engine's ceiling; Reset mixer walks every remembered track, so a reset while stopped clears what the next start would replay.
- The input setup is session-owned (the design: pairing, trim and position belong to the saved session setup; names stay appliance-wide): a load replaces it and now re-persists it and the track pans, so the next boot matches the loaded session; the settings writers are per input (`saveInputTrim/Pan/Pair`), with one whole-setup writer for the load; `setInputSetup` serves the boot restore and the load with one projection.
- Cleanups: `InputSetup.with*` helpers and one `_applyInputSetup` path; `MixTarget` follows `FxAddress` (`tryParse`, `canonicalString()`) and drops the track level that `TrackVolumeTarget` already names; the write-only `SessionMonitor.pan` and the dead dB-of-gain conversion are gone; the Dart balance law and the engine's pan law share pinned constants; the event-log format doc lists commands 58 to 60.

A second check found the fresh-take path still projecting and saving the engine's gain as the level (a lane whose fader was never touched had no level of its own), a grown lane pushed at unity instead of the track's level, the wholesale setup push posting sixty-four ring commands per load, and the DAW export leaving a track silent at arm without a breakpoint; fixed in the third commit.

Checks after the rounds: native 5 suites plain, ASan and telemetry-off (new `test_meters_read_only_what_routes`); `segno_engine` 263, `looper_repository` 457, `settings_repository` 148, `session_repository` 102, `performance_repository` 113, `daw_export` 100; root 2210; analyzers clean at the root and in every touched package; `bloc lint` clean.

## Not verified here

The pan law by ear and the meters on the appliance. The offline performance render replays solo but not pan (it renders lane 0 mono as before).

## Type of Change

- [x] ✨ New feature (non-breaking change which adds functionality)
- [x] 🧪 Test



=====
# PR #1018 feat(engine): output destinations (slice 3b) [open] claude/segno-slice3b-outputs <- claude/segno-slice3-mixer-fx
labels: stage:in-review,autonomy:merge-gate,ci:red,review:clean,area:console,area:engine

## Description

Slice 3b of the accepted-design programme (epic #1009, part 3b of #1016): output destinations at the engine boundary. Stacked on the slice-3a branch (PR #1017) until that merges; targets `claude/segno-slice3-mixer-fx`.

Contract: `docs/design/2026-09-07-output-setup-ux.md` (level, mute, Stereo/Mono, balance per destination; the performance capture boundary), `docs/design/2026-09-07-audio-routing-ux.md` (independent output selection per source), `docs/design/2026-09-07-performance-recording-ux.md` (the click is captured when routed there) and `docs/handoff/segno-app/accepted-behavior.md` (the tail distinctions: Stop/Clear drain Post and output tails, Mute gates the track while shared tails drain, bypass sends new audio dry and drains old wet tails, Cut clears every tail). Ledger: `docs/plan/2026-09-09-segno-implementation-ledger.md`, "Slice 3b".

- **Output buses.** Destination `k` is the stereo pair of outputs `2k` and `2k + 1` (`LE_MAX_OUTPUT_BUSES` = 16; an odd channel count leaves a single-jack last bus). Each bus owns a level (retained behind the mute), a mute, Stereo/Mono and a balance on the lane pan law, plus its own effect chain (`le_engine_set_output_level/mute/mono/balance`, `le_engine_set_output_fx*`, ring commands 61 to 66). The frame order is tracks, monitors, click, then per bus chain, capture tap, Mono or balance, level, mute, then the global master gain, limiter and output meters. A bus at its defaults with no chain costs nothing per frame. Every fact is a trailing snapshot field.
- **The Master insert is bus 0's chain**; `le_engine.master_fx` is gone and the master setters wrap bus 0. The chain colours everything summed onto the first pair, monitors and the click included (the old D-MASTER "monitors uncoloured, first ENABLED pair" rule is retired). The Dart `FxStage.master` keeps addressing that chain until slice 3f rebuilds the FX surfaces around per-destination chains.
- **The click rides the bus**: it sums in before the buses, so a destination's chain, level and mute process it, and it reaches the output meter and the master gain.
- **The performance capture tap** defaults to the captured bus after its chain and before its level, Mono, balance, mute, master gain and limiter; `le_perf_set_follow_output` sets the policy the next arm freezes (`EnginePerformanceCapture.setPerfFollowOutput`, `PerformanceRepository.setFollowOutput`). The captured bus is the first with an enabled channel. The arm snapshot records `followOutput`, `outputLevel` and `outputMuted`; `perf_render` skips the master stage for a default take and replays bus 0's level and mute before the master gain under Follow. The golden parity test runs both policies.
- **Cut all sound** (`le_engine_cut_sound`): every playing or capturing track stops through the Stop handler, a count-in is cancelled, every chain on every stage has its DSP state and delay rings cleared while its settings stay; `tail_reset_rev` advances.
- **Bypass drains the tail**: `enable_mix` now scales the slot's feed (`dry * (1 - mix) + effect(dry * mix)`), so after the 5 ms ramp the slot keeps running on silence and its tail sums onto the dry signal until quiet (1e-4 for 50 ms) or 8 s, then settles to bit-exact passthrough; a re-enable mid-drain keeps the state. A latency-bearing slot (the octaver) keeps the crossfade: its delayed dry copy must not double the direct path.
- **Stop drains Post tails, Mute gates them**: the lane body has a feed gate (playing, not gated) and an output gate (not muted, not soloed away); the Track chain routes via the gate-open lanes' destinations, so its tail drains after a Stop and is gated with the track on Mute; the output chains are the shared tails that keep draining under Mute.
- **Persistence**: `OutputSetup` (an `OutputBus` per destination off its defaults) is the repository's intent on `LooperState`, in settings per device (`output_level/mute/mono/balance.<device>.<bus>`), restored at boot, saved with the session (`outputSetup`) and restored and re-persisted on load. Bloc events `LooperOutputLevelChanged/MuteChanged/MonoChanged/BalanceChanged` and `LooperCutSoundPressed`; `LooperRepository.setTrackOutput` routes a track as one source and `OutputSetup.maskOfBuses/busesOfMask` translate destinations to channel masks.
- Kept: the global master gain and limiter as the final stage after the buses (retiring the global gain for bus 0's level is a slice 3c surface decision); bus level changes are instant like the lane volume.

No UI in this part; the surfaces are 3c (Audio routing and Output setup).

## Checks

- Native: `run_native_tests.sh` 5 suites ALL PASSED, plain, with `-fsanitize=address` and with `-DLE_CALLBACK_TELEMETRY=0`. Flipped: the click through the bus, the count-in click captured, the output chain colouring monitors, the master chain fixed on bus 0, bypass draining its tail; new: the pre-level tap, the Follow policy frozen per take, the first bus with an enabled channel, level/mute/mono/balance per bus with the snapshot, setter rejection and clamps, Cut, new audio dry on bypass, Stop draining a lane tail and Mute gating it; the golden parity test under both policies; the ramp-continuity bound follows the feed ramp. ffigen regenerated and formatted.
- Dart: `segno_engine` 269, `looper_repository` 464, `settings_repository` 152, `session_repository` 103, `performance_repository` 115; root 2217; `dart analyze` clean at the root and inside every touched package; `bloc lint` clean; the changed markdown adds no word the repository's markdown does not already carry.

Note: this PR targets the slice-3a branch, so the repository's CI does not run on it (only GitGuardian does); the checks above were run locally, and CI runs once it is retargeted after #1017 merges.

## Not verified here

The bus stage and the tail drain by ear on the appliance (the drain floor and window are engineering values the listen check may move). The offline render replays bus 0's level and mute but not its Mono, balance or chain. The Follow output preference has no surface or setting yet.

## Type of Change

- [x] ✨ New feature (non-breaking change which adds functionality)
- [x] 🧪 Test

## Review round 1

Eight finder angles (line scan, removed behavior, cross-file tracer, reuse, simplification, efficiency, altitude, conventions) then a verify pass. Fixed in the second commit:

- **A disabled output channel carried audio.** The bus stage read and wrote both channels of its pair regardless of the structural output gate, so a decorrelating chain put its right-hand output onto a disabled jack and Mono halved a pair with one jack disabled. The per-block bus snapshot now carries the pair's enabled bits.
- **A retype mid-drain replayed the old effect's ring.** The re-enable edge skips its clean reset while a drain is in flight and nothing cleared the drain budget on a type change; `le_fx_entry_reset` now does.
- **The bypass drain was applied to types that have no tail.** Only a linear ring-owning type (delay, echo, reverb) uses the feed-scaled ramp and drain; a kernel with no memory would overshoot both endpoints on the ramp (a drive at 15x reads +2 dB above wet at mix 0.2), the octaver's delayed dry copy would double the direct path, and a hosted plugin owns its own tail. They keep the original crossfade.
- **Cut all sound memset every ring in one callback** and bypassed the spacing the re-enable path exists to enforce; the clear now goes through that spaced path, and the stop is perf-logged per track like the one-shot stop's synthetic entry.
- **The Follow-output render assumed destination 0**, but the engine captures the first destination with an enabled channel. The snapshot publishes it, the arm manifest records it, and the render replays that destination.
- **A pre-3b take rendered without the master gain**: an absent `followOutput` now reads as Follow (those takes were captured post-gain), and the key is always written.
- **The capture policy reverted on every device change**; it is a preference, not device state.
- **The pumped test engine dropped every new snapshot field**; `EngineSnapshot.copyWith` replaces its hand-written rebuild. A verifier showed that only moved the hand-written list, since the constructor's parameters are optional with defaults, so a source-level golden now pins the `copyWith` parameter names to the declared field list; dropping one parameter fails the suite.
- **A track-wide output route was speculative and leaky.** `setTrackOutput` had no caller, was not persisted, was not cleared on a session load, and missed the case where the engine trims lanes behind the repository's cache. It and the unused destination/mask helpers are removed: per-source routing already exists per lane, per monitor and for the click, and a track-wide convenience belongs with slice 3c's Audio routing surface, which owns its persistence.
- **One edit posted four ring commands and four preference writes**, so a level ride could delete a mute set between two of its ticks. Each setter pushes its own fact and settings has one writer per fact.
- **The compatibility layer went** (AGENTS.md): `le_engine_set_master_fx*`, ring codes 51 and 52 and the Dart `setMasterFx*` family are deleted; the engine interface speaks output buses and the repository owns the `FxStage.master` to destination 0 mapping.
- Cleanups: one pan-store helper for the three pan/balance handlers, one push helper for the two capture taps, one ring-clear helper for the two clear sites, one snapshot struct per destination instead of eleven parallel arrays and a seventeen-parameter call, `OutputSetup.fromMaps`/`toMaps` instead of four hand-written conversions, `kMaxChannels` instead of a literal, and the stale comments (D-MASTER, D-MASTERCH, "the click is excluded from the capture") rewritten to what the code does.

Checks after the round: native 5 suites plain, ASan and telemetry-off, with three more tests (a destination honouring its disabled channels, a retype mid-drain starting clean, the policy surviving a reconfigure with the captured destination published); `segno_engine` 274, `looper_repository` 464, `settings_repository` 152, `session_repository` 103, `performance_repository` 117, `daw_export` 100; root 2217; analyzers clean at the root and in every touched package; `bloc lint` clean; cspell clean on the changed markdown against the repository's dictionary.

## Review round 2

Every round-1 fix was handed to a skeptic told to refute it, then four critics swept the change for new bugs, unaddressed findings and test honesty. Three fixes were themselves wrong and several tests passed against their own reverted fix. Fixed in the third commit:

- **The capture destination was recorded before the arm.** The engine settles it inside `le_perf_arm` from the output gate as it stands then, but the manifest read it from a snapshot taken before lane export and manifest I/O, the same race that retired the old `clockFrame` anchor. A manifest naming one destination while the take captured another sends the offline render to the wrong level rides, silently.
- **The snapshot copy helper only relocated its hand-written field list.** The constructor's parameters are optional with defaults, so a field added later without a `copyWith` parameter compiles and yields the default. Two source-level goldens now pin the parameter list to the field list and check each parameter feeds its own field.
- **The spaced ring clear was worse than the memset it replaced.** Deferring a slot means passing it dry, and dry is the wrong output for a fully wet effect, so Cut clears at once again with the reasoning in the code.
- **A jack's structural gate is not a bus mute**, and a verifier read the new gating as a regression. It is not: every source already masks by the enabled mask, so a disabled channel never carried anything to capture, before this slice or after. A test pins the mute and the disable side by side.
- **The test-library build script had stopped compiling** before the vendored denoiser and the restore units landed, so every FFI-gated Dart test was skipping silently. Repairing it brings back 32 pumped-engine tests, 11 in the looper repository and 29 at the root.
- **Tests that passed against their own reverted fix were rebuilt to fail.** The Cut and retype tests read uninitialised ring positions because they never filled the delay ring; the render's capture-destination filter had no coverage, and now a fourth golden-parity run names a destination the take did not capture and requires the render to diverge; the pumped snapshot had none. Each is mutation-checked: revert the fix, the test fails; restore it, it passes.
- Smaller: the guards the first round dropped, the published channel mirror the rest of the snapshot uses, the Cut stop entry asserted in the log, the plugin install path clearing the drain state, the two format documents brought up to date, and the last "Master insert" labels on what are now sixteen-destination loops.

Checks after this round, with the test library built so the FFI-gated suites actually run: native 5 suites plain, with ASan and with telemetry off; `segno_engine` 306, `looper_repository` 475, `settings_repository` 152, `session_repository` 103, `performance_repository` 118, `daw_export` 100; root 2246; analyzers clean at the root and in every touched package; `bloc lint` clean; cspell clean on every changed markdown against the repository's dictionary.



=====
# PR #1020 feat(console): Audio routing and Output setup (slice 3c) [open] claude/segno-slice3c-routing-surfaces <- claude/segno-slice3b-outputs
labels: stage:in-review,autonomy:merge-gate,ci:red,review:pending

Part 3c of the accepted-design implementation (epic #1009, slice 3 issue #1016), stacked on #1018.

The pen's `21 Audio routing` and `Output setup` sections, built as one route with four tasks: Settings → Audio routing.

## What lands

**Input setup.** Pick a jack, record it on its own or as one half of a stereo pair, place it, and set the gain the capture branch records it at. First consumer of the slice-3a input events; a linked pair shows one Balance where a mono jack shows Pan.

**Recording inputs.** Pick a track, then the jacks it records. Unchecking frees that lane in place, because compacting would renumber the lanes and move a recorded take onto another source. A new jack fills a free lane; only a full track grows, and the growth is dispatched before the routing.

**Output routing.** Live inputs, recorded tracks and the click each carry their own destinations, so a recording-only track route never becomes a live input route. A track's choice is the whole track's and writes every lane — the track-wide route `setLaneCount` deferred to this slice. Hear live belongs to the live inputs, says whether Auto is hearing anything now, and says when the monitor is muted in Mixer.

**Output setup.** Format, level, balance and mute per destination, with the meters reading that destination's own jacks and a muted destination metering silence.

**The name pages.** The header action opens the names list for the side of the rig the task is on, behind the same frame. Outputs are listed per destination, not per jack. Renaming goes through the console's one rename sheet, with an empty name allowed.

**Destination names are new.** Settings keys, an `OutputsCubit` and a pair-shaped label resolver: the unit is the stereo pair a player patches, not the jack, and the per-jack output gate keeps its own key.

## Two judgement calls

**The backing-track source is not built.** The accepted design's third source kind is "Backing & click"; this console has no backing player and no engine, repository or bloc seam for one. The kind ships with the accepted label and the click alone, because a card for a source that routes nothing would be a control that does nothing.

**The Signal face's per-jack output gate stays.** It is a structural switch per hardware output with the last-live-output guard (#569) behind it, where Output setup's mute is a per-destination mix fact that retains its level. The accepted design does not replace it, so retiring it would drop a shipped feature. It needs a design answer before it can move.

## What retired

The Tracks routing tab and its per-track dialog were the only dispatchers of the lane routing events, which the two new tasks now own; their quantize group is already covered by slice 2's Length & quantize page, which writes the same override. The interim click output card and the desktop section's output chips go the same way, leaving the click's level where it is until the Mixer holds it. The Tracks tray panel lost its strip. Twenty-nine strings and five goldens went with them.

## A defect fixed in passing

The routing meter lit cells in proportion to amplitude while the scale under it prints four evenly spaced ticks, so a signal at -24 dBFS lit a sixteenth of the meter under a label that says a third.

## Verification

- Root suite 2223 passing, 35 skipped; `looper_repository` 468 passing; `settings_repository` 155 passing.
- `dart analyze` clean at the root and in both touched packages; `bloc lint` clean over 237 files.
- Both arb files at 1086 keys, with no key present in one and missing from the other.
- Every behavioural claim above is mutation-checked: the fix is reverted, the test is confirmed to fail, and the fix is restored. Twenty-six mutations, each killing exactly the tests that name it.
- Five goldens regenerated and eyeballed; five deleted with their surfaces.

CI is red until #1011 is merged and this stack is retargeted.

Part of #1016



=====
# PR #1021 feat(console): the Mixer view (slice 3d) [open] claude/segno-slice3d-mixer <- claude/segno-slice3c-routing-surfaces
labels: stage:in-review,autonomy:merge-gate,ci:red,review:pending

Part 3d of the accepted-design implementation (epic #1009, slice 3 issue #1016), stacked on #1020.

The stage's third view. Four channel strips per bank, drawn from the pen's `Mixer` tile.

## What lands

**A third stage view, not a page.** `StageView` gains `mixer`, and the two exhaustive switches over it — the header's view menu and the instrument area — name every site that had to change. The chrome, the two dB scales and the session strip stay the stage's own.

**One owner, two surfaces.** Mute, Solo, pan and level dispatch the events slice 3a built and nothing else. The accepted design is explicit that a Mixer edit must not create a second mixer state.

**The level marker rides the meter.** The pen draws one control over the thing it governs rather than a fader beside it. Dragging anywhere in the meter's height sets the level, the lanes keep metering underneath, and a double tap returns the track to unity, as the pan double tap returns it to centre.

**Both sides meter separately**, from the per-track `peakL` and `peakR` that slice 3a added and nothing drew until now. They are subscribed in their own leaf, so a level tick redraws two bars rather than the whole strip.

**The dB scale follows the view.** It aligned to the Track column's meter by construction. It now takes the insets of whichever view is showing, so it lines up with the meter beside it either way.

**Reset mixer** appears only in the Mixer, and clearing every Solo is a long press on a Solo button. Both events already had handlers and no way to reach them.

## Three deviations from the pen

**No FX edit button.** The pen draws a pair, edit and bypass. The FX editor is slice 3f and does not exist yet, so that button would open nothing. The bypass ships; the edit button lands with the surface it opens.

**No Backing & click sheet.** The pen draws it as a modal over the Mixer with four controls. Only the click's volume has an owner in this product: there is no backing player anywhere, and the engine has no click pan. This is the call slice 3c made for the routing source, made once for both.

**The strip scales below the pen's height.** The pen's strip is 858 tall with every part fixed, which is right at 1080p and impossible in a desktop window a third of that. Below its minimum the whole strip scales as one piece rather than silently sacrificing a part.

## The foot Mixer is not here

The accepted design's foot Mixer is a Mixer *action* in the custom-binding vocabulary issue #763 approved on 2026-08-26, not a fourth interaction mode. The pedal wire has one free mode value and #763's approved direction spends it on `custom`. That issue is `stage:plan` with no implementation and sits outside this epic, so part 3d is complete as far as this slice can take it. Recorded on both #1016 and #763.

## Verification

- Root suite 2253 passing, 35 skipped; `dart analyze` clean over `lib` and `test`; `bloc lint` clean over 239 files; both arb files at 1107 keys.
- Mutation-checked: a pan that writes on every drag tick, a Solo long press that does nothing, two lanes reading one side, Reset mixer drawn in every view, and a level double tap that does not return to unity each fail exactly the test that names them.
- One golden added for the view, with a panned track, a soloed one, a muted one and an empty one.

CI is red until #1011 is merged and this stack is retargeted.

Part of #1016



=====
# PR #1022 feat(engine): FX placement and printing (slice 3e) [open] claude/segno-slice3e-fx-placement <- claude/segno-slice3d-mixer
labels: stage:in-review,autonomy:merge-gate,ci:red,review:pending

Part 3e of the accepted-design implementation (epic #1009, slice 3 issue #1016), stacked on #1021.

FX placement and printing, in the engine and the repository. The surfaces that drive it are part 3f.

## Placement

Every chain entry now says where it sits relative to the loop player. Pre is recorded into the loop, Post runs downstream and can ring after Stop.

Placement rides the entry, not the address. A pedal binding persists an address plus a slot id, and the accepted design requires a placement move to keep its assignment, so putting placement on the address would break the one thing the move must preserve.

A chain is stored Pre entries first, so the split the engine has to know is one boundary index rather than a per-slot flag. The write boundary partitions before it clamps, the partition is stable, and a reorder across the boundary is refused rather than honoured and then undone. Post is the wire default and is omitted, so a chain with no Pre entry persists byte for byte as before.

## Printing

The loop-stage wet cache becomes the printer. It renders exactly the Pre prefix from the lane's dry pool and swaps the result in at the lane's own loop boundary, which is the accepted "prepared from original sources" and "switched at an audio-safe boundary". The recording is untouched: the print is a rendered copy, so the dry original stays the render source however many times the Pre chain is edited.

**Post stays live, printed or not.** That is not a choice. A Post tail has to be able to drain past a Stop and a baked tail cannot, so the whole-chain render the cache used to do was already at odds with the tail contract slice 3b shipped. The cost is that a cached lane now pays its Post chain's CPU, where before it paid none and its Post tail could not drain at all.

The print's key is the Pre prefix, so editing a Post entry leaves it standing rather than dropping the lane to live processing for a change that cannot make the render stale.

Stop takes the Pre tails with it. There is no single place a track stops in this engine, so the edge out of sounding is watched per track and clears each lane's Pre slots, leaving its Post slots to drain.

## A live input's Pre run is what its takes record

Record already copies a routed input's chain onto the lane by value, so carrying each entry's placement through that copy is all it takes. New instances on a live input are created Pre, which is the accepted default and the one that matches what the chain is for.

## All tracks

The chain applied after the loop tracks are combined, and only them: live monitoring, the click and the output chains all join after it. One config, one DSP instance per destination, because since slice 3b every source picks its own outputs and a track on Main and a track on Monitor are two different recorded mixes. It persists with its own settings key and a manifest field at schema v8.

## Channel handling and level

Per instance, on every chain owner: the input choice before its effects, the output choice and then the level after them, on the engine's one unity-centre pan law. The choices ride the entry's feed, so a bypassed entry passes the pair through exactly as it arrived. Four values, one call, because they are one control and a half-applied change is audible.

## Two defects fixed in passing

Retyping a lane or input entry rebuilt it from its type alone, dropping the slot id and the power decision: a retype silently re-minted the entry and dangled every binding on it, and powered a bypassed device back on. The bus stage already kept both and is the rule the other two were missing.

The All-tracks instances' settled bypasses were being applied to the shared config's unused DSP state rather than to the instances themselves.

## A whole track's Pre

The owner settled the open question on 2026-09-10: keep the switch, and build a non-destructive rendered copy of the combined track. That landed here.

A track's Pre run is rendered over the combination of its parts — each part's own printed material at its level, mute and pan, summed — and swapped in at the track's loop top. The combination is processed as one signal, which is the point: a compressor on a sum is not the same as the same compressor on each part. The parts' prints are the render's input rather than something it re-renders, so the job costs one stereo buffer.

**It renders only while every part's chain is wholly Pre.** A part carrying a Post entry keeps the track's Pre run live, with the reason reported. Nothing is disabled and nothing sounds different, because the live path computes the same function the render materializes. That condition is what keeps a part's Post tail draining past a Stop, and with it the promise that part's own switch makes.

My first boundary put the parts' whole chains inside the render, making a part's Post tail captured material. An adversarial review of the design confirmed twenty-six objections against it; the decisive one is that flipping a switch in the Whole track editor would change what a part's own editor promises, on the default configuration. The boundary that survived is recorded in `docs/design/2026-09-10-whole-track-pre-render.md`.

Engaging removes the parts from the bus rather than merely bypassing their slots, because a bypassed entry is unity passthrough and not silence. The key is refolded every buffer rather than memoised: it spans every part's chain, level, pan and mute, so a memo would want a bump on fifteen setters and one miss would play a render that no longer describes the track.

## Two more defects fixed in passing

The idle-track lane skip left a stopped track out of the lane loop when none of its parts carried a chain. The track's own chain kept running but the routing mask is built inside that loop, so a Track-stage Post reverb drained into nothing — Stop drained Post tails for a track whose parts had effects and silently did not for a track with all its effects on the track itself.

The cache's in-flight accounting assumed one mono source in three hard-coded places, and its graveyard sizing, LRU scan, budget and shutdown were all lane-indexed. All of it is now derived from the job's shape and generic over both entry classes.

## What is not here

**The All tracks chain is not an addressable stage yet.** An address is what a pedal binding persists, so it arrives with the surface that can show what a binding points at.

**Playback transforms.** Speed, Reverse, pitch preservation and Follow tempo do not exist in this engine. The accepted direction for Speed is to stream from originals inline, which composes with a render from originals since both read the same recordings, but nothing tests that until Speed exists.

## Verification

- Native suite green in all five variants, before and after every change.
- Root suite 2262 passing, 35 skipped; `looper_repository` 496; `session_repository` 105; `settings_repository` 155; `segno_engine` 283. `dart analyze` clean at the root and in every touched package.
- The whole-track render carries the owner's own verification list as native tests: the combination processed as one signal, live and printed agreeing, edits re-rendering from the originals rather than compounding, the recording and its layers surviving an overdub and an Undo underneath an engaged render, a part's Post entry keeping the track live and still sounding right, the boundary swap, and Stop taking the Pre tails while the Post run drains.
- Twenty mutations, each failing exactly the test that names it. Three tests were rewritten after a mutation survived them: the stage-end move had no stage-mate to be ordered behind, the per-destination All-tracks claim used a memoryless effect, and the printability rule needed a part carrying BOTH placements, because a wholly-Post part is refused by a different gate.
- Two of my own claims were withdrawn rather than shipped unobservable.

Sample-level tests cover the placement, the tails, the print's key and the channel arithmetic. Hardware ports and clipping proof stay out of reach here and remain listed as not verified.

CI is red until #1011 is merged and this stack is retargeted.

Part of #1016




=====
# PR #1023 chore(deps): bump lucide_icons_flutter from 3.1.17 to 3.1.19 [open] dependabot/pub/lucide_icons_flutter-3.1.19 <- master
labels: dependencies,dart

Bumps [lucide_icons_flutter](https://github.com/vqh2602/lucide-flutter-main) from 3.1.17 to 3.1.19.
<details>
<summary>Release notes</summary>
<p><em>Sourced from <a href="https://github.com/vqh2602/lucide-flutter-main/releases">lucide_icons_flutter's releases</a>.</em></p>
<blockquote>
<h2>Beta v3.1.18-beta.1</h2>
<h2>🧪 Beta Release v3.1.18-beta.1</h2>
<p>This is a <strong>pre-release beta version</strong> from the <code>develop</code> branch.</p>
<p><strong>⚠️ Warning</strong>: This version is for testing purposes only and may contain bugs or incomplete features.</p>
<h3>Installation</h3>
<p>Add to your <code>pubspec.yaml</code>:</p>
<pre lang="yaml"><code>dependencies:
  lucide_icons_flutter: 3.1.18-beta.1
</code></pre>
<h3>Commit</h3>
<ul>
<li>SHA: a95235c7ce806177a3177a6ae17cb6607c98932e</li>
<li>Branch: develop</li>
</ul>
<p>See <a href="https://github.com/vqh2602/lucide-flutter-main/blob/develop/CHANGELOG.md">CHANGELOG.md</a> for details.</p>
</blockquote>
</details>
<details>
<summary>Changelog</summary>
<p><em>Sourced from <a href="https://github.com/vqh2602/lucide-flutter-main/blob/main/CHANGELOG.md">lucide_icons_flutter's changelog</a>.</em></p>
<blockquote>
<h2>3.1.19</h2>
<p>1.41.0</p>
<ul>
<li>Enable icon font tree shaking ([PR <a href="https://redirect.github.com/vqh2602/lucide-flutter-main/issues/23">#23</a>](<a href="https://redirect.github.com/vqh2602/lucide-flutter-main/pull/23">vqh2602/lucide-flutter-main#23</a>))</li>
</ul>
<h3>Lucide 1.41.0 Changelog</h3>
<h4>What's Changed</h4>
<ul>
<li>feat(icons): Add new icons <code>germ</code> and <code>germ-off</code> by <a href="https://github.com/rrod497"><code>@​rrod497</code></a> in <a href="https://redirect.github.com/lucide-icons/lucide/pull/4056">lucide-icons/lucide#4056</a></li>
<li>feat(icons): added <code>door-stairwell</code> icon &amp; updated <code>door-*</code> icons by <a href="https://github.com/jguddas"><code>@​jguddas</code></a> in <a href="https://redirect.github.com/lucide-icons/lucide/pull/3554">lucide-icons/lucide#3554</a></li>
<li>feat(icons): added <code>credit-card-reader</code> icon by <a href="https://github.com/jguddas"><code>@​jguddas</code></a> in <a href="https://redirect.github.com/lucide-icons/lucide/pull/4616">lucide-icons/lucide#4616</a></li>
<li>feat(icons): added 'engine' icon by <a href="https://github.com/benhaube"><code>@​benhaube</code></a> in <a href="https://redirect.github.com/lucide-icons/lucide/pull/4598">lucide-icons/lucide#4598</a></li>
<li>feat(icons): fixed <code>germ</code> &amp; <code>germ-off</code> by <a href="https://github.com/karsa-mistmere"><code>@​karsa-mistmere</code></a> in <a href="https://redirect.github.com/lucide-icons/lucide/pull/4789">lucide-icons/lucide#4789</a></li>
<li>chore(deps): bump the vue-deps group with 2 updates by <a href="https://github.com/dependabot"><code>@​dependabot</code></a>[bot] in <a href="https://redirect.github.com/lucide-icons/lucide/pull/4771">lucide-icons/lucide#4771</a></li>
<li>feat(icons): added <code>virus</code>/<code>virus-off</code> icon by <a href="https://github.com/karsa-mistmere"><code>@​karsa-mistmere</code></a> in <a href="https://redirect.github.com/lucide-icons/lucide/pull/4765">lucide-icons/lucide#4765</a></li>
<li>chore(copilot-reviews): Improve use-cases description. by <a href="https://github.com/ericfennis"><code>@​ericfennis</code></a> in <a href="https://redirect.github.com/lucide-icons/lucide/pull/4558">lucide-icons/lucide#4558</a></li>
<li>feat(icons): add <code>can-soda</code> icon by <a href="https://github.com/jaynewey"><code>@​jaynewey</code></a> in <a href="https://redirect.github.com/lucide-icons/lucide/pull/4718">lucide-icons/lucide#4718</a></li>
<li>feat(icons): added <code>square-alert</code> Icon by <a href="https://github.com/viralcodex"><code>@​viralcodex</code></a> in <a href="https://redirect.github.com/lucide-icons/lucide/pull/3687">lucide-icons/lucide#3687</a></li>
<li>chore(lab): Add label for lab icons by <a href="https://github.com/ericfennis"><code>@​ericfennis</code></a> in <a href="https://redirect.github.com/lucide-icons/lucide/pull/4793">lucide-icons/lucide#4793</a></li>
<li>feat(icons): changed <code>lab/bottle-toothbrush-comb</code> icon by <a href="https://github.com/karsa-mistmere"><code>@​karsa-mistmere</code></a> in <a href="https://redirect.github.com/lucide-icons/lucide/pull/4756">lucide-icons/lucide#4756</a></li>
<li>ci(<code>@​lucide/lab</code>): Create automatic release flow for <code>@lucide/lab</code> by <a href="https://github.com/ericfennis"><code>@​ericfennis</code></a> in <a href="https://redirect.github.com/lucide-icons/lucide/pull/4792">lucide-icons/lucide#4792</a></li>
<li>fix(icons): removed <code>trash</code> icon in favour of <code>trash-2</code> by <a href="https://github.com/jguddas"><code>@​jguddas</code></a> in <a href="https://redirect.github.com/lucide-icons/lucide/pull/3141">lucide-icons/lucide#3141</a></li>
<li>feat(icons): changed <code>leaf</code> icon by <a href="https://github.com/karsa-mistmere"><code>@​karsa-mistmere</code></a> in <a href="https://redirect.github.com/lucide-icons/lucide/pull/4801">lucide-icons/lucide#4801</a></li>
</ul>
<p><strong>Full Changelog</strong>: <a href="https://github.com/lucide-icons/lucide/compare/1.40.0...1.41.0">https://github.com/lucide-icons/lucide/compare/1.40.0...1.41.0</a></p>
<h2>3.1.18</h2>
<p>1.40.0</p>
<h3>Lucide 1.40.0 Changelog</h3>
<h4>What's Changed</h4>
<ul>
<li>feat(icons): added <code>can</code> icon by <a href="https://github.com/l0uisgrange"><code>@​l0uisgrange</code></a> in <a href="https://redirect.github.com/lucide-icons/lucide/pull/4767">lucide-icons/lucide#4767</a></li>
<li>feat(icons): added <code>bridge</code> icon by <a href="https://github.com/Nykoula"><code>@​Nykoula</code></a> in <a href="https://redirect.github.com/lucide-icons/lucide/pull/3949">lucide-icons/lucide#3949</a></li>
<li>feat(icons): added <code>shrimp-off</code> icon by <a href="https://github.com/jguddas"><code>@​jguddas</code></a> in <a href="https://redirect.github.com/lucide-icons/lucide/pull/3613">lucide-icons/lucide#3613</a></li>
<li>feat(icons): added <code>shopping-cart-plus</code> &amp; <code>shopping-cart-minus</code> icons by <a href="https://github.com/Ajay199210"><code>@​Ajay199210</code></a> in <a href="https://redirect.github.com/lucide-icons/lucide/pull/4248">lucide-icons/lucide#4248</a></li>
<li>fix(docs): updated artboard name on illustrator template by <a href="https://github.com/EthanHazel"><code>@​EthanHazel</code></a> in <a href="https://redirect.github.com/lucide-icons/lucide/pull/4724">lucide-icons/lucide#4724</a></li>
<li>chore(deps): bump softprops/action-gh-release from 3.0.2 to 3.0.3 in the github-actions group by <a href="https://github.com/dependabot"><code>@​dependabot</code></a>[bot] in <a href="https://redirect.github.com/lucide-icons/lucide/pull/4781">lucide-icons/lucide#4781</a></li>
<li>feat(icons): added <code>lighthouse</code> icon by <a href="https://github.com/Xougui"><code>@​Xougui</code></a> in <a href="https://redirect.github.com/lucide-icons/lucide/pull/4507">lucide-icons/lucide#4507</a></li>
</ul>
<p><strong>Full Changelog</strong>: <a href="https://github.com/lucide-icons/lucide/compare/1.39.0...1.40.0">https://github.com/lucide-icons/lucide/compare/1.39.0...1.40.0</a></p>
</blockquote>
</details>
<details>
<summary>Commits</summary>
<ul>
<li>See full diff in <a href="https://github.com/vqh2602/lucide-flutter-main/commits">compare view</a></li>
</ul>
</details>
<br />


[![Dependabot compatibility score](https://dependabot-badges.githubapp.com/badges/compatibility_score?dependency-name=lucide_icons_flutter&package-manager=pub&previous-version=3.1.17&new-version=3.1.19)](https://docs.github.com/en/github/managing-security-vulnerabilities/about-dependabot-security-updates#about-compatibility-scores)

Dependabot will resolve any conflicts with this PR as long as you don't alter it yourself. You can also trigger a rebase manually by commenting `@dependabot rebase`.

[//]: # (dependabot-automerge-start)
[//]: # (dependabot-automerge-end)

---

<details>
<summary>Dependabot commands and options</summary>
<br />

You can trigger Dependabot actions by commenting on this PR:
- `@dependabot rebase` will rebase this PR
- `@dependabot recreate` will recreate this PR, overwriting any edits that have been made to it
- `@dependabot show <dependency name> ignore conditions` will show all of the ignore conditions of the specified dependency
- `@dependabot ignore this major version` will close this PR and stop Dependabot creating any more for this major version (unless you reopen the PR or upgrade to it yourself)
- `@dependabot ignore this minor version` will close this PR and stop Dependabot creating any more for this minor version (unless you reopen the PR or upgrade to it yourself)
- `@dependabot ignore this dependency` will close this PR and stop Dependabot creating any more for this dependency (unless you reopen the PR or upgrade to it yourself)


</details>


=====
# PR #1024 feat(app): the accepted FX surfaces, and the Signal tray retires [open] claude/segno-slice3f-fx-surfaces <- claude/segno-slice3e-fx-placement
labels: stage:in-review,autonomy:merge-gate,ci:red,review:pending,area:console,area:fx

Closes #1016 part 3f: the FX surfaces the accepted design draws, end to end.

## What this adds

**One chain per destination, and All tracks gets an address.** `FxStage.master`
becomes `output`, keyed by bus, and All tracks becomes addressable from the app
for the first time. A destination exists because the rig has it, not because it
already carries effects.

**The Effects destinations page.** One page for every destination rather than
one per stage: the Sound type row picks the strip, the strip picks the source,
and the chain underneath is whatever that source carries. A live input, a
recorded part, a whole track, All tracks and an output all arrive at the same
editor.

**The chain ceiling is 64.** The accepted chain is built out of racks, and one
factory rack is about six pedals, so eight slots held roughly one rack where
the design shows ten. The cap was never a CPU limit; the audio callback's
stack was.

| Ceiling | Callback frame | Engine struct |
| --- | --- | --- |
| 8 (before) | 32,048 B | 1.27 MB |
| 64 (naive) | 194,672 B | 4.73 MB |
| 64 (shipped) | 7,200 B | 4.92 MB |

The per-buffer snapshot arrays moved off the stack into the engine struct.
Nothing about them is state — each is written and read inside a single callback
— so they need no atomics; they live there only so their size is charged to an
allocation whose size is known.

**The factory catalogue ships** as `packages/fx_catalogue`: nine families, 159
presets, 66 images, at 100% coverage against the real files.

**Two hand-written tables, pinned by test.** A preset is a flat parameter map
that never says which modules it holds, and three vocabularies in the source
disagree about naming the same pedal: the power key, the parameter prefix and
the artwork. The correspondence is written down rather than derived, and the
readiness map says plainly that six of twenty-six modules have DSP here.

**Add effects and the two editors.** A rack becomes one entry per module in one
write, every entry bypassed whatever the preset says. The single-effect editor
has its parameters as direct controls and the Pre/Post switch in its footer,
offered only where the placement is the player's to choose.

**The rack becomes a first-class thing.** A chain entry gains the rack it
belongs to — an id shared by every module, a name and an artwork slug — and the
catalogue's own name for the pedal. A card on the destination chain is a rack;
opening it opens the rack chain editor, with one column per pedal, its own
power, artwork, controls and a persistent scrollbar, plain cables between them,
and the rack's channel handling in the footer.

**Rack options and reorder.** Rename, reorder effects, remove one pedal, remove
the rack. One reorder surface arranges both a destination's racks and a rack's
own pedals; its draft is local, the stage is a boundary it will not cross, and
Cancel discards it.

**Saved sounds.** Save preset names a sound and copies it; a name already taken
offers Replace or Use another name, and cancelling keeps the previous preset.
My presets lives inside Add effects and lists each saved sound as a card over
the row that renames or deletes it. A saved preset is a copy, not a reference,
which is what makes every accepted rule about it true.

**The Signal tray domain retires.** Its rail row becomes the Effects route, in
the same position and with the same glyph. Nine view files, two helpers only
they used, the lane-cache indicators and their preference go with it.

## Decisions taken

- **Ship the extracted assets.** The catalogue is in the repository.
- **Raise the engine ceiling first**, before building the rack surfaces on it.
- **Drop the hosted-plugin browser with the Signal tray.** The accepted Add
  effects offers the factory catalogue and Single FX, and the pen draws no
  plugin entry. Plugin hosting stays in the engine, the repository and the
  chain model; what is gone is the console surface that added one.

## What this deliberately does not do

- **No invented parameter mappings.** The reverb's brightness is not wired into
  the engine's damping even though it is that control's complement: inverting
  another product's control into ours is the silent substitution the accepted
  design forbids. Twenty of the twenty-six catalogue modules become passthrough
  entries that keep their name and artwork and say this build does not process
  them.
- **No rack-level bypass bit.** A rack's power writes every pedal's own, so a
  rack turned off and on comes back with every pedal on. The engine has one
  enable per slot and nothing above it; a fourth bypass masked at every write
  path and folded into the fingerprint is a slice of its own.
- **Import and Export of presets are drawn and inert.** Moving a preset on or
  off this console is the USB export domain's job, and that domain is not built.
- **My presets has no artwork of its own.** The accepted design gives it
  matching original art, which is not in this repository.

## Defects found and fixed on the way

- `performance_repository`'s suite had stopped compiling at slice 3e, so a
  package with a 99% floor was silently absent. `settings_repository` did the
  same here, and is fixed. The root analyzer reaches neither.
- Two tests were stubbing an EXTENSION method through `when(...)`, registering
  against whichever member it last touched.
- A shared button drew an inert control exactly like a live one.
- Every FX golden had been photographing a half-loaded page: a widget test
  pumps in fake async and an asset load is real async, so the artwork never
  arrived. They carry the real artwork now.

## Written back into the pen

`c/signal-domain-retired`, recording the rail's Signal row becoming an Effects
route, the landing moving to Control, and the two things dropped with the
domain.

## Verification

- The native suite green in all five variants, plus AddressSanitizer,
  telemetry-disabled and the C++ header shim.
- Root suite 2081 passing, 35 skipped. Every package suite green, all
  twenty-one of them.
- `dart analyze`, `bloc lint` and cspell clean.
- Twenty-two mutations across the slice, each caught by exactly the test that
  names it. Three tests that turned out vacuous were rewritten.
- Eleven FX screenshots.



=====
# PR #1027 feat(control): Press and Hold, and the selected-track scope [open] claude/segno-slice4-assignments <- claude/segno-slice3f-fx-surfaces
labels: stage:in-review,autonomy:merge-gate,ci:red,review:pending,area:console,area:pedal

Part of #1026 (slice 4 parts 1 and 2), stacked on #1024.

## Press and Hold are separate actions

Holds were four hard-wired switches — undo, MODE, BANK and Stop-in-FX — each with a field of its own and each armed by hand. A bound switch had no hold at all, and fired its press on contact with no way to retract it.

A binding now carries a hold beside its press, and a switch carrying both moves its press to the **release**: until the threshold passes, neither half is known to be the one the foot meant. Firing the hold retires the tap, so the release after it stays silent — the same rule every system gesture already used.

### Which switches may carry a hold

The four track footswitches, and only those. Every exclusion is the accepted design's own:

- **Record/Play and Stop** keep immediate contact. Delaying a rhythm-sensitive command until the release to learn whether the foot is holding is explicitly not approved.
- **Undo, Stop, MODE and Bank** already carry a long-press system gesture, which a remap never overrides.
- **Clear** is the one irreversible stomp on the plate.
- **A momentary press** cannot carry one either: holding IS the momentary gesture, so there is no hold left to assign and no press to defer.

A persisted hold on a switch that cannot carry one is dropped rather than rejected with the binding. The press half is still a usable assignment, and losing it because a file claimed a hold on Stop would punish the performer for the file.

### Cancelling a gesture needed a generation

Dropping a pending hold is easy; a release already on its way up the wire cannot be recalled. Every pending gesture, system and bound, now lives in one registry that retires a generation: a press belongs to the generation it started in, and a release landing in a later one runs nothing. One call point is reached from every invalidating path the rule names — a mode change, a binding-set edit, a session's bindings applied, a mode-switch-style change and pedal disconnect.

## A binding acts on the selected track, or the one it names

The accepted rule gives a binding an explicit scope, resolved once. The same chain target means a different chain under each, so the scope rides beside the target rather than being folded into the address, and a press and a hold each carry their own. It is omitted from the encoding when it is fixed, so adding the field moved no bytes.

**There is no following machinery.** The scope is read at the instant the action fires rather than when the switch goes down, which is both halves of the accepted rule at once: a pending hold acts on the newly selected track because it reads the cursor when it fires, and it stays attached to what it resolved because the momentary restore captures the resolved target.

Identity for a track here is its engine channel. Tracks are never reordered, so a channel is not a visible slot that could drift under a binding, and no second identity was invented for something that already had one. Only the two stages whose index is a track are repointed; an input, an output and All tracks are honoured as written. A lane survives the repoint, because dropping it would widen the binding to the whole track. An unrecognised scope decodes to fixed, never to selected.

## Two defects this exposed

- **Unbinding the pedal left the hold timers armed.** Disconnect released held momentaries, but nothing dropped the pending holds, so a redo or the FX-door hold could fire into a rig with no pedal on it.
- **The take lock reached the press but not the release.** A press taken just before a take started still ran its latched tap when the foot came up. The held momentary still restores, because a target left enabled by a swallowed release is the wedge the release-all rule exists to prevent.

## What is not here

The all-track scope. The accepted design names it among direct actions — "Clear All is one grouped edit, not eight Clear calls" — which belongs with the action catalogue rather than with FX chain targets, and lands with it.

## Verification

- Root suite 2110 passing, 35 skipped; analyze and bloc lint clean.
- Eighteen binding-model tests and ten cubit tests.
- Five mutations, each caught by exactly the test that names it: a press that never defers, an invalidation that cancels nothing, a lock that stops at the press, a resolver that never repoints, and a hold resolved at press rather than at dispatch.

Physical footswitch evidence is out of reach here and stays listed as not verified.


=====
# PR #1028 feat(control): Pedals setup, and one action catalogue for every picker [open] claude/segno-slice4c-pedals-setup <- claude/segno-slice4-assignments
labels: stage:in-review,autonomy:merge-gate,ci:red,review:pending,area:console,area:pedal

Part of #1026 (slice 4, part 4c). Stacked on #1027.

## What this is

The accepted Pedals setup, Layout A: the hardware map stays on screen while
the chosen switch's Press and Hold are edited together. And the shared action
catalogue behind it, which the external-pedal and MIDI pickers will draw from
rather than each inventing their own vocabulary.

**Track controls** edits the fixed plate. MODE carries a pair; Record / Play
carries a hold; the four track switches carry one hold between them and are
selected and marked as one group, because one setting covers all four and
marking only the tapped cap would promise a per-switch assignment that does
not exist. Stop, Undo, Clear and Bank are drawn dimmed **with what they do**,
rather than offering an assignment the model would refuse.

**Custom controls** is the free map: eight switches, each with its own pair.
The four track caps carry a pair per bank; a transport switch carries one
whatever the bank, which is what the accepted design means by shared
transport assignments not duplicating across banks. MODE and BANK are not
assignable here at all, so neither can stop being the way out and the way to
the other four tracks.

**Everything lands in a local draft.** Nothing reaches the rig until Save.
That is what lets Cancel mean something, what lets Clear custom assignments
offer Restore, and what keeps an unfinished draft from riding out on some
other surface's save: it never leaves the page.

## The catalogue

One vocabulary, named once: the modes, the transport commands, the track
pedals and the per-track operations by scope (the selected track, one named
track, all tracks). Keys are identity and labels are not, so renaming a
picker row cannot re-point an assignment, and a key this build cannot honour
reads as unassigned rather than binding to whatever now sorts nearby.

The catalogue lists what the rig can actually do. The eight performance
operations with no engine behind them are absent, and the part that builds
each one adds its entries with it; the headings they will sit under are
declared, so a later part adds actions instead of re-deciding the shape of
the picker. `direct:clear:all` is refused on the way in as well as absent
from the list: clearing everything is one grouped edit with one undo, and
eight separate clears behind a single stomp would leave eight undo steps.

## ModeSwitchStyle retires into it

The two-way setting was a partial answer to the question the accepted design
answers in full, and keeping both would leave two places deciding what MODE
means. A press enters the mode it names; a hold enters the mode it names;
either one leaves that mode when the rig is already in it. Nothing a foot can
stomp can strand it, and the accepted `Exit` is exactly that rule.

With no hold assigned the press acts on contact and no gesture is armed at
all. With one assigned the press moves to the release, because until the
threshold passes neither half is known to be the one the foot meant. BANK
goes back to paging and nothing else.

Record / Play and the four track switches keep their immediate contact: their
holds are layered on top rather than deferring the press, which is what the
accepted design pins them to. Neither arms in FX mode, where Record / Play is
inert and the track switches carry the remap's own gestures.

## One gap this opens

The foot has no path to arming a performance recording until the Custom
controls mode lands. It was the MODE hold, which now belongs to the mode
pair. The catalogue carries the action; the mode that dispatches it is the
next part, and it needs a wire code for the fourth mode, which is the same
protocol bump part 4d needs for LED colour. The toolbar and the keyboard's
`A` are unaffected.

## Departures from the pen, written back into it

A `c/ Implementation · slice 4c` note now sits in the pen's `08 Pedal setup &
LEDs` section recording these:

- The pedal caps are drawn as geometry (body, rubber pad, nameplate, LED
  pill) rather than the pen's rendered metal art. Hand-built artwork would
  look worse than the shapes it stands for.
- Pedals is reached from the Control face's Pedal tab rather than from a
  Settings tile grid, because the shipped console IA is the tray rail rather
  than that grid. A ninth rail row was tried and reverted: it ate the spacer
  the rail keeps above Brightness.
- The LED colors context and the External pedals button are absent until
  parts 4d and 4e build them.
- The Mode picker offers Exit, Mute and FX, and gains Custom and Tuner with
  the modes themselves.
- The Double press (Solo) field arrives with the optional controls.
- None leads the first picker group rather than taking a tab of its own,
  which would be a heading over one button.

## Verification

- Root suite: 2152 passing, 35 skipped.
- All twenty-one package suites green, including `settings_repository`'s own
  after the `pedal.mode_switch_style` key was replaced by `pedal.setup`.
- Native suite green (untouched by this part).
- `dart analyze --fatal-infos` on the app and on `settings_repository`; bloc
  lint clean across `lib test packages`.
- Eleven mutations run against the new tests, each caught by the test naming
  it. One survived and exposed a real gap: the FX guard on the track hold had
  no test, and now does.
- Five screenshots: Track controls, the track group, Custom controls on bank
  B, the action picker, and the Clear confirmation.

## Not verified

Physical footswitch evidence. The holds, the deferral and the gesture
retirement are proven against the decoded wire in tests; a foot on a real
plate is not.



=====
# PR #1029 feat(pedal): protocol v4 unreserves the mode field's fourth value [open] claude/pedal-protocol-v4-763 <- claude/segno-slice4c-pedals-setup
labels: stage:in-review,autonomy:merge-gate,ci:red,review:pending,area:pedal

Part of #763 — slice 1 of the approved plan (`docs/plan/2026-08-25-feat-pedal-custom-mode-protocol-v4-plan.md`), direction approved 2026-08-26. Stacked on #1028.

## Why a version, and not a spare value

The mode field has had two bits since v3, and its fourth value has been
reserved-and-rejected by both decoders ever since. A custom-mode frame sent at
v3 would not render as the wrong mode; it would be refused whole and blank the
pedal. That rejection is the entire reason this version exists, and the test
that proves it relabels a v4 frame's version byte, since the encoder will not
write those bits below v4 on its own.

## What v4 is

The smallest version that has ever shipped here: version byte `0x04`, the same
17-byte payload for a third time, and value `3` meaning custom from v4 on and
nothing below it. That is D2's zero-growth wire as approved.

Encoding custom below v4 writes it as mute, the inert-safe degrade FX already
takes below v3. An un-reflashed pedal shows the wrong mode LED rather than no
LEDs at all, and button behaviour is app-side and unaffected either way.

## Amber, in all three places

Both sketches and the on-screen plate. The firmware drift gate already holds
the two `modeColor` functions identical to each other; the plate's widget test
now pins every mode rather than only FX, so a mode added to the wire with no
colour on screen fails here instead of rendering whatever the switch fell
through to.

## Fixtures

`custom_mode_v4` and the same frame on the v3 wire. The v3 twin isolates the
mode degrade from the LED degrade the FX twins already pin: v3 carries blue
chain LEDs, so the only byte that moves is the mode. Both are in the C
contract test's golden round trip.

## What this does not do

No app-side mode. Nothing constructs a custom frame until the mode lands, so
this changes no behaviour a user can see.

Nothing in the console selects v4 either: `selectFirmwareVersion` has no UI
caller today, so a real pedal stays at the unknown-firmware v2 floor. The
simulator speaks max, which is what renders custom on screen.

## Verification

- `bash firmware/test/run_tests.sh` green against both protocol copies,
  including the new custom-mode round trip, the version gate and the downgrade
  twin.
- `pedal_repository` suite green, fixtures regenerated (existing fixture bytes
  unchanged — only the manifest grew).
- Root suite green; `dart analyze --fatal-infos` clean.

## Not verified, and by whom

Everything wire-level is proven by the contract tests. Nothing about rendering
on real LEDs is, and the hardware that will do that rendering is not the one
these sketches target.

The console ships a **Pico 2 / RP2350** on console board v2, linked to the Pi
over UART (Pico uart0 GP16/17 to Pi uart3 GPIO8/9) and cold-flashed over SWD
from the Pi's GPIO24/25. No Pico 2 firmware exists in this repo yet, and there
is no UART `PedalTransport` app-side — the three that exist are noop, native
MIDI and the simulator.

That is exactly why the plan called for v4 to land once in the shared plain-C
`pedal_protocol.{h,c}`: the Pico 2 bring-up speaks v4 from its first compile
rather than needing a second protocol change. What it will still owe is its
own `modeColor` amber arm — the drift gate holds the two Arduino sketches
identical to each other, and cannot cover a file that does not exist.

The Arduino sketches remain the V1 standalone pedal. Amber there, and the
degrade on an un-reflashed one, are checkable whenever that hardware is in
hand; the console's mode LED waits on the Pico 2 firmware.




=====
# PR #1030 feat(control): Custom controls, the fourth mode [open] claude/custom-controls-mode-763 <- claude/pedal-protocol-v4-763
labels: stage:in-review,autonomy:merge-gate,ci:red,review:pending,area:console,area:pedal

Part of #763 (slices 3 and 4 of the approved plan) and of #1026 part 4d. Stacked on #1029.

## What it is

The mode the Pedals setup's Custom map runs in. Every switch but MODE and BANK
does whatever the setup put on it, and an unassigned one does nothing at all.
This is the one mode with no contextual defaults to fall back on, which is
what "fully user-defined" costs, and is why an unassigned switch is inert
rather than guessing.

MODE and BANK keep their jobs here as everywhere. The binding model refuses to
hold an assignment on either, so in the mode where every other switch has been
handed over, the way out and the way to the other four tracks are still there.

Press and hold follow the rule the rest of the plate follows: a switch with
only a press acts on contact, and one carrying both moves its press to the
release, because until the threshold passes neither half is known to be the
one the foot meant.

## One dispatch point

`_runAction` is the single place the shared catalogue is interpreted. The
built-in switches reach it here, and the external and MIDI surfaces will reach
the same method rather than growing interpreters of their own — which is the
whole reason the catalogue was built as one vocabulary in #1028.

Scope resolves once, at dispatch. A selected-track action fires on whatever
the cursor holds when the foot commits; a fixed-track one never follows the
bank, which is the point of naming a track.

## The LEDs report the switch, not the track

Lit when that switch carries an assignment, dark when it does not. Most of the
catalogue has no on/off state a lamp could report, and what a performer needs
to know before stomping is whether the switch does anything at all.

That is its own invariant (`custom-led-mirrors-assignment`), and it is why the
`empty-track-dark` rule now exempts this mode as it already exempted FX: in
custom mode the lamp is not about the track.

## Two consequences

The accepted MODE default lands now that the mode exists: Mute on the press,
Custom on the hold.

And the foot gets its path back to arming a performance recording, which #1028
took when `ModeSwitchStyle` retired into the MODE pair.
`command:record-performance` has been in the catalogue since then; this is the
mode that dispatches it.

## On-screen

The tiles select and stop. What a control does in Custom controls is assigned
per footswitch, and a tile is not one; running some other switch's assignment
from a tap would be a guess. The mode joins the keyboard's `M` cycle and the
7-inch readout's function word, and takes amber — the pedal's own custom hue —
wherever a mode is coloured.

## Verification

- Root suite green: 2193 passing, 6 skipped, with the engine test library
  built so the FFI-backed tests actually run.
- The control sequence fuzzer green, including the seeded random sequences —
  custom is reachable there through the existing mode cycle, so it is fuzzed
  without adding to the alphabet. Two corpus cases were rewritten: they walked
  the old three-stop cycle by tapping MODE, which is a pair rather than a
  cycle now.
- All twenty-one package suites, the firmware protocol suite, the native suite
  and bloc lint green; `dart analyze --fatal-infos` clean.
- Four mutations run against the new tests. Three were caught. One survived:
  reading the assignment live at dispatch instead of latching it at press
  changes nothing, because every setup edit retires the pending gestures
  outright. The latch stays as consistency with every other gesture here, and
  its doc comment now says that is what it is rather than claiming to be the
  enforcement.

## Not verified

How any of this feels under a foot, and the mode LED on the hardware that
ships: the console's pedal controller is a Pico 2 over a UART link to the Pi,
whose firmware is not in this repo yet (see #1029 for what it will owe). The
wire value and the degrade are proven by the contract tests either way, and
button behaviour is app-side — it works in custom mode whatever the pedal
displays.




=====
# PR #1031 feat(pedal): v4 carries a colour per footswitch, and the decoder stops trusting the wire about length [open] claude/pedal-v4-colours-763 <- claude/custom-controls-mode-763
labels: stage:in-review,autonomy:merge-gate,ci:red,review:pending,area:pedal

Part of #763. Stacked on #1030.

## Why this reopens a decided question

D2 approved a zero-growth v4 and rejected per-pedal LED bytes as "wire bytes
for feedback no hardware can show: V1 has no transport indicators, and the v2
faceplate deliberately dropped them (#792 — six pills)".

That premise is stale. `hardware/segno_wiring.md` records the change under
#930: the pills went from 6 single LEDs to **ten 8-LED segments**, one per
footswitch, in full colour. The reasoning behind D2 still holds — do not pay
wire bytes for feedback nothing can render. The answer changed because the
renderer did, and the accepted design assumes the new one when #1026 asks for
colour "on all ten including the fixed-action pedals".

Widening v4 rather than spending a v5: nothing has been flashed with v4, since
#1029 is unmerged and no Pico 2 firmware exists. The version is still being
written, so completing it now is what keeps "v4 lands once" true when the
console's controller arrives.

## The shape

Thirty bytes appended at v4: one RGB triplet per footswitch, indexed by
`PedalButton`, so the order is the one both sides already share for note
numbers rather than a new convention.

Raw RGB, not a palette index, for three reasons. The colours a user picks
reach the LED unquantised. The frame is pushed a handful of times a second, so
thirty bytes that rarely change cost nothing on a link that is a UART to the
Pi. And the pedal is left holding no second thing that can go stale across a
reboot the app did not see.

Below v4 the colours fall off the wire entirely and decode as the default
palette — white on all ten — because reporting a colour nothing sent would be
an invention. Every pre-v4 fixture is byte-identical; only the v4 one grew.

**Nothing renders them yet.** What lights an indicator is still the frame's
own state, and this adds the hue dimension beside it. How a configured colour
combines with a fixed-action pedal's own signal — the MODE LED currently says
which mode by its colour — is a behaviour call that belongs with the palette
editor, not smuggled into a wire change.

## The decoder was reading past its buffer

Separate from the above, and the reason this is worth reviewing carefully.

`pedal_unpack7` writes one byte per payload byte it finds, into a fixed-size
stack buffer, and the length came straight off the wire unchecked. A long
SysEx walked off the end. That predates this change — the buffer was 17 bytes
before — and it is reachable from anything that can send MIDI to the app or to
the pedal.

Both copies now bound the body before unpacking it. The contract test builds
with AddressSanitizer and UBSan so this is a failure rather than a silent
write: removing the guard makes the suite report

```
ERROR: AddressSanitizer: stack-buffer-overflow
  [32, 79) 'payload' <== Memory access at offset 79 overflows this variable
  SUMMARY: ... in pedal_unpack7
```

which is how the guard was verified. The Dart twin allocates rather than
writing into a fixed buffer, so there the same bound limits the work instead;
its comment says which is which.

## Verification

- `bash firmware/test/run_tests.sh` green against both protocol copies, now
  sanitized, with new arms for the colour array, the truncated-v4 rejection
  and the over-long body.
- Two new golden fixtures (`pedal_colors_v4` and its v3 twin) carry ten
  **distinct** hues, so a codec that wrote one colour ten times or indexed the
  array backwards fails rather than passing on a palette of identical whites.
- `pedal_repository` suite and the root suite green; `dart analyze
  --fatal-infos` and bloc lint clean.
- Three mutations run. Two were caught. The third — dropping the Dart bound —
  survives by construction, because Dart cannot overflow there; that is why
  the test for it lives in C, under the sanitizer.

## Not verified

The sketches are not compiled by any gate, only diffed for their colour
vocabulary. The struct grew by thirty bytes and `PEDAL_FRAME_MAX_BYTES` by
thirty-two, which is nothing on the V1 boards but is untested by a build here.



=====
# PR #1032 feat(pedal): the ten indicators take the performer's colours, and state stops being the hue [open] claude/pedal-led-colours-1026 <- claude/pedal-v4-colours-763
labels: stage:in-review,autonomy:merge-gate,ci:red,review:clean,area:console,area:pedal

Slice 4 part 4e of #1026, stacked on #1031 (protocol v4's colour bytes). It is the half that picks the colours and the half that renders them.

## What the accepted design actually says

One indicator, two questions. **Function state decides whether it is lit. The performer's palette decides what colour it comes up in.** Both sides of the wire answered the second question for themselves until now: a track LED read green for playing and red for recording, and the MODE LED said which mode it was in by its hue.

That reading is what `4. LEDs represent function state ... Color is configurable on all ten, including pedals with fixed actions` asks for, and both pen scenes show it. `03 / Pedals / LED colors` has every indicator dark on an idle rig in the normal mode; `04 / LED colors — Toggle active` has MODE lit in its configured white and Track 1 lit in its configured blue while FX is engaged. The accepted prototype builds every indicator the same way: one colour from the palette, one boolean from the rig.

This is the behaviour call I deliberately left open on #1031. The design source answers it, so it is answered here rather than asked.

## The palette

Eight built-in hues plus any number the performer mixes. A custom colour is a **reference**, not a value on the switch: several footswitches can point at one, and editing it moves all of them. That is what makes it reusable, and it would be impossible if each switch held its own copy of the hue.

It rides in `PedalSetup`, so it is the same draft, the same Save and the same Cancel as the assignments — and `Clear custom assignments` keeps it, because the confirmation says it will.

The editor is Hue, Saturation and Brightness over a live swatch and its hex. A new colour opens mid-space rather than on the switch's current one: white has neither hue nor saturation, so two of the three sliders would move with nothing happening on screen.

`PedalColor.defaultColor` becomes the palette's white rather than full white, so the default is one number instead of one on each side of the wire. Both firmware copies move with it.

## What is lit

`PedalStateFrame.isLit` is the one definition, mirrored by `indicatorFor` in both sketches, which the firmware drift gate holds token-identical.

- Record / Play: while a take is live.
- Stop, Undo: never. Both do a thing and finish, so an indicator on them could only report that the function exists.
- MODE: in every mode but the normal one. Dark in Tracks.
- Track 1-4: the LED of the track the active bank drives.
- Clear: while the fade runs. Bank: on bank B.
- The shutdown frame darkens everything.

## The consequence, stated plainly

**A lit track indicator no longer says whether the track is playing or recording.** Both are that switch's own colour now. The default palette is white on all ten, so a performer who never opens the editor loses the green/red reading and gains nothing for it.

The accepted design is unambiguous that colour is configurable on all ten and that a lamp reports function state, so that is what shipped. If the recording state should keep a hue of its own — red winning over the configured colour while a take is live — that is a design change and a one-line precedence rule, and it is worth saying so before a unit is flashed.

## Also fixed

`Restore` after `Clear custom assignments` put the whole draft back, so a colour picked after the clear was rewritten by the recovery. The recovery point is the assignments now, which is what `2026-09-08-pedal-closure-pass.md` asks for: *Recovery does not rewrite LED colors or other fields edited after clearing.*

## Verification

- Root suite 2200 passing / 35 skipped; screenshot goldens 68 passing, three new (LED colors, a mixed colour, the editor).
- `pedal_repository` 199 passing. The v4 golden fixtures were regenerated for the new default; only `custom_mode_v4` moved.
- Firmware contract suite green against both protocol copies under AddressSanitizer and UndefinedBehaviorSanitizer, and both sketches compile (32u4 17020 bytes, UNO 9654).
- `dart analyze --fatal-infos` clean on the app, tests and the package; bloc lint clean.
- Five mutations run, five caught: the MODE lit rule, the palette's default-is-not-an-edit rule, the palette surviving a clear, and the restore scope both ways.

**Not verified: anything physical.** The console's ten pills still have no driver and the standalone pedal has indicators for seven of its ten switches. What a real WS2812 makes of these eight hues at stage distance is a bench question.

Part of #1026
Part of #763


=====
# PR #1034 feat(console): the Pedals setup map draws the footswitch instead of a rectangle [open] claude/pedal-face-art-1033 <- claude/pedal-led-colours-1026
labels: stage:in-review,autonomy:merge-gate,ci:red,review:clean,area:console,area:pedal

Closes #1033. Stacked on #1032.

The map drew each switch as a rounded rectangle with a pad block and a nameplate block. It draws the real thing now: a tapered metal body under a four-stop gradient, two side hinges, left and right rolled edges, a textured rubber pad carrying thirty grips on the pitch it was moulded to, and a trapezoid nameplate. Selecting a switch brightens its alloy and lights its edge, which is how the study says so.

## It is a port, not a drawing

Every outline is a path constant from `docs/design/pedal-hardware-widget.js` — the vector reconstruction of the populated Fusion assembly, and the same source the pen's `Hardware / Segno pedal face` was built from. A test holds the two together: each of the study's seven outlines must be quoted in the port, so an eighth added there fails until it is carried across. Break one coordinate in a quote and the test names it.

What that test pins is the quoting. That the `Path` calls under each quote build the outline is pinned by the setup goldens, which run on the author's machine only. So a coordinate typed wrong fails the goldens, and an outline the study changed fails everywhere.

## Why 4c shipped rectangles

Two reasons, both worth writing down.

The pencil tool elides every path's `geometry` as `"..."`, even for a single node, so the pen's outlines cannot be read through it. That was never said out loud; the simplification went into a source comment instead, which is what the "write a departure back into the pen" rule exists to prevent.

And **the art was in the repository the whole time — untracked.** `docs/design/pedal-hardware-widget.js` builds this face parametrically and `docs/design/pedal-hardware/README.md` names it and points at the Pen counterpart. Neither is in git. They sit in the working copy along with 377 other entries under `docs/design`, so a worktree cannot see them. That is the actual root cause, and it will cause this again.

The four files this port reads are committed here: the widget, the README, `geometry.json` and `labels.json`, about 41 KB. The rest of that directory is 226 MB, mostly preview renders, and what to do with it is your call.

## Deliberate departures

**The nameplate keeps app text** rather than the manufacturing ink in `labels.json`. Those outlines exist for TRACK1 to TRACK4 only, because that is what the silkscreen carries, and the map names the channel the active bank drives — TRACK 5 on bank B. The affordance is worth more than the exact ink.

**No new dependency.** The outlines are short enough to transcribe into `Path` calls and the grips are circles, so an SVG runtime would have been a large thing to add for one illustration.

**The faceplate simulator is untouched.** It draws its switches the same simplified way and should eventually share this painter, but it has its own millimetre geometry from the enclosure model and that is its own change.

## Verification

- Root suite 2208 passing / 35 skipped; the eight Pedals setup goldens regenerated and eyeballed.
- `dart analyze --fatal-infos` clean on the app and tests; bloc lint clean.
- One mutation: a coordinate changed in a quoted outline, caught by the transcription gate and nothing else.
- The hardware art file is added to the token-adoption allowlist for the same reason the faceplate is — these are the switch's own moulded colours, and a theme token would repaint the metal.


=====
# PR #1035 feat(console): the CTRL jacks take a switch, and the switch does something [open] claude/external-pedals-1026 <- claude/pedal-face-art-1033
labels: stage:in-review,autonomy:merge-gate,ci:red,review:clean,area:console,area:pedal

Part of #1026, the first of three for part 4f. Stacked on #1034.

The two external jacks had no model and no screen. They have both now, for the switch half: choose CTRL 1 or CTRL 2, say whether a single or a dual switch is plugged in, and give each button its actions from the same catalogue the built-in map draws from.

## What it does

**A jack keeps every type's assignments side by side.** Plugging a dual pedal in for one song and the single one back afterwards must not cost either of them what it carried, and the accepted design says so outright.

**The hardware is a setting, not a preference.** A momentary switch reports a closure and a release, so it has a Press and a Hold. A latching switch reports only that its state changed, so there is nothing to time a hold against and it carries one action. The screen says which, and says why, rather than offering a Hold that could never fire. That distinction also has to persist on its own: a switch told it is latching, with nothing on it yet, is a switch the performer has configured.

**Both ports save as one draft**, on its own screen, discarded by leaving. An unrelated Save elsewhere cannot commit it.

## The artwork

The study's own generated art, downscaled to what the screen actually draws and converted to WebP: **284 KB against the 2.6 MB the PNGs weigh**, which is worth caring about on an appliance image. It depicts a category of pedal, not a product anyone can buy and not the Segno faceplate.

What is exact is where the switches are, because that is what a performer points at. The centres are measured in the source raster and the hit targets are placed as fractions of it, so the markers stay on the switch at any size and on either artwork's aspect.

## Not in this part

- **Expression.** It is in the model and out of the type picker. What it needs — calibration with reversed travel, and a list of destinations each with its own heel and toe — is its own part, and a type that opened an empty panel would be worse than one not offered yet.
- **The Controls panel**, where one button drives any number of FX activations and parameter values with On/Off or Held/Released conditions. Same reason.
- **Dispatch.** Nothing drives these jacks yet: the controller repository speaks MIDI Note and CC and has no source kind for a jack, so the contact dot has nothing to report and no assignment fires. This part is the setup; the events are the next one.

## Also

The action picker moved into one function both screens call, so the built-in map and the jacks cannot drift about what a control can be asked to do. `PedalSetupField` gained the sizes the narrower external editor needs rather than being copied.

## Verification

- Root suite 2234 passing / 35 skipped, including 13 model tests and 9 screen tests; three new goldens and eight regenerated for the External pedals button now on the Pedals row.
- `dart analyze --fatal-infos` clean on the app and tests; bloc lint clean.
- The screen test caught a real one: a switch told it was latching, with no action on it, was dropped on write because the hardware did not count toward "carries something". It counts now.

**Not verified: anything physical.** There is no jack transport, so nothing has been plugged in.


=====
# PR #1036 feat(pedal): the CTRL jacks reach the same interpreter the footswitches do [open] claude/external-dispatch-1026 <- claude/external-pedals-1026
labels: stage:in-review,autonomy:merge-gate,ci:red,review:clean,area:console,area:pedal

Part of #1026, the second of three for part 4f. Stacked on #1035.

The jacks had a screen and no dispatch: what a performer assigned to an external switch did nothing, because nothing carried a jack's contact into the app.

## How a jack reaches segno

The console board reads the CTRL jacks alongside the ten footswitches and the encoder, so an external switch arrives the way a footswitch does — a Note on the same link, at numbers that follow the plate's. A build that predates them decodes nothing rather than mistaking one for a footswitch.

Those numbers are a wire contract with firmware that does not exist yet, so both protocol copies carry them and the C suite pins them: overlap the first external number with the plate's last and the suite says so.

**One event for both edges**, rather than the plate's pressed and released pair. A latching switch has no press and no release, only a contact that is now closed or now open, and both hardwares have to arrive the same way for the setup to decide what a change means.

## The accepted event rules

- **Momentary with a hold** waits for the release, because until the threshold passes neither half is known to be the one the foot meant. Reaching the threshold runs the hold and consumes the release.
- **Momentary with no hold** acts on contact, like the plate's own switches.
- **Latching** runs its action on every change. A state that did not change is not a change: a resent message or a bouncing switch must not act twice.
- **Only the active type dispatches.** A dual pedal's second switch is silent while the jack is set to a single one, whatever it still carries.
- **A pending hold is retired when the configuration is saved**, because the foot is still down on a switch that may no longer mean what it meant.

The contact register tracks the wire, not the assignment, so a switch that was down while nothing was listening is still down when something starts.

## One mechanism, not two

The gesture registry keys on a control's own enum now rather than on `PedalButton`, so the jacks and the plate share one state machine and cannot diverge about when a pending gesture is retired. Assignments run through `_runAction`, the single interpreter, so an external pedal cannot mean something different from the footswitch beside it.

## Verification

- Root suite 2246 passing / 35 skipped, including nine new dispatch tests covering each rule above.
- `pedal_repository` 206 passing, with the wire contract pinned: every external note is rejected by the footswitch decoder and vice versa.
- Firmware contract suite green against both protocol copies under sanitizers.
- `dart analyze --fatal-infos` clean across the app, tests and the package; bloc lint clean.
- Three mutations, three caught: the duplicate-state guard, the active-type guard, and a note overlap in the C header.

**Nothing plugs in yet.** No firmware sends these notes and no jack transport exists, so this is tested end to end in software and not at all in hardware. What it closes is that an assignment now has a path to the interpreter.


=====
# PR #1038 fix(enclosure): the row-2 pedestals print solid, not as a modelled shell [closed] claude/second-row-platforms-solid-d9d1e9 <- master
labels: stage:in-review,autonomy:merge-gate,review:pending,area:enclosure

Closes #1037

`segno_platform_mid_ring` (CLEAR / BANK, ×2) was a 3 mm perimeter shell over a
29.9 mm cavity with four 12 mm boss columns at the chassis stations. It is a
solid block now; the slicer's infill does the hollowing, which is how the mini
tray's tubs have always been built (#539).

Why: the shell is what the slicer lays down at the perimeter regardless, and
modelling it pinned the wall at 3 mm — on the one printed part that carries a
stomp from the sled into the base plate (#1019). Density belongs in a print
setting, not in the geometry.

## What moves

| | before | after |
|---|---|---|
| mid ring enclosed volume | 155.3 cm³ | 412.7 cm³ |
| front ring | 46.8 cm³ | 46.8 cm³ |

Nothing else changes. The front ring is 2.0 mm tall and never had a cavity. The
four chassis clearance bores were already cut full height, so no fastener, hole,
seat or assembly dimension moves. `PLAT_WALL` and `PLAT_DECK` had no other
reader and are gone.

At ≥40% infill the part is now roughly 250 g of filament and a long print, ×2.
That cost is stated on the row in `hardware/MANUFACTURING.md`, which no longer
calls the part hollow.

## Verification

- `segno_enclosure.py` full build: geometry assertions ALL PASS, drawing/package
  assertions ALL PASS.
- Point classification on the rebuilt mid ring: all four chassis bores clear
  through the height, material either side of each, body solid at z = 3 / 20 / 35.
- Regenerated outputs are limited to the three files that actually changed
  (`segno_platform_mid_ring.step/.stl`, `segno_assembly.step`); the rest of
  `out/` differed only by DXF timestamps and STEP header GUIDs and was reverted.


=====
# PR #1039 feat(pedal): an expression pedal's wire numbers, travel and value dispatch [open] claude/external-expression-1026 <- claude/external-dispatch-1026
labels: stage:in-review,autonomy:merge-gate,ci:red,review:clean

The third piece of part 4f: what an expression pedal sends, what the app
learns about it, and what a sweep writes.

## The jacks are the same two, the wire is not

An expression pedal is a potentiometer the console board reads on the same CTRL
jack a switch uses, so its position arrives on the link the ten footswitches and
the encoder already share. A switch sends a Note; a pedal sends an absolute
Control Change, one number per jack, carrying the RAW reading. Both protocol
copies hold the numbers and the C contract suite pins them, because they are a
contract with firmware that does not exist yet.

**7 bits, one message, and the cost of that.** The inbound half of this link is
3-byte MIDI only: segno's native capture drops SysEx, so nothing wider than a
Control Change can arrive. A higher-resolution position needs MIDI's 14-bit
MSB/LSB pair and a half-assembled value held between two messages, which would
move the wire contract out of the codec and into whatever held that state.

128 steps of raw travel is what a commercial expression input delivers. The cost
lands at the bottom of the calibration range: a span near the accepted 10%
minimum leaves about 13 distinct positions, which is a staircase on a volume
sweep. The accepted design leaves resolution and smoothing unspecified, so this
decides nothing it had settled -- but if the bench shows that stepping, the
answer is a 14-bit pair on the wire rather than anything the app can do with 7
bits. Recorded in the code on both sides.

## Calibration is why the wire sends raw

A pedal's electrical range and its travel are not the same thing. Two pedals of
one model reach different ends of their pots, and a pedal can be wired the other
way round. So the board sends what it read and the app is taught both ends.

- **Reversed travel needs no special case.** The same subtraction puts 0 at
  whichever end was captured as the heel. A test pins the case that separates a
  correct implementation from one that sorted the two ends: a reading *past* one
  end of a reversed travel has to clamp to the end it went past.
- **A travel too short to divide by positions nothing.** Under the accepted 10%
  minimum span the two captures came from nearly the same place, and dividing by
  it would turn the remaining noise into a full sweep. The threshold is the
  design's own study assumption, not a measured electrical requirement.
- **A jack calibrated but not yet assigned anything is not empty.** The taught
  travel is work done to the jack, and a setup that read as empty would throw it
  away on the next save. Same rule the switch hardware already follows.

## Dispatch reuses the continuous model

Nothing new was built for what a sweep writes. Part 4b's continuous binding
model already carries one normalized target, resolved against the live rig and
skipped when what it named is gone, and a learned MIDI CC already goes through
it. An expression mapping is the same target plus two endpoints.

- **A target that disappeared is skipped, never repointed.** A pedal bound to a
  filter cutoff must not start sweeping the delay that replaced it.
- **One pedal sweeps every control it carries**, each between its own two
  endpoints, and a toe value below the heel inverts that control rather than
  being a mistake to correct.
- **Both continuous sources now write through one method.** Master gain has a
  second reader in this cubit -- the encoder, and the ring meter the frame
  carries -- and a write that skipped the accumulator would make the next detent
  jump back to whatever the encoder last set. That was a real hazard in copying
  the write rather than sharing it.
- **Only the active type dispatches**, so a jack still holding expression
  mappings is silent while it is set to a switch.
- **Not gated on the take lock**, which every switch path is. That lock stops a
  take starting behind the power-off route, and sweeping a filter starts
  nothing. A pedal that went dead under a dialog would be the worse surprise.

## One stale assumption this broke

A codec test checked that "an unrelated CC number" decodes to nothing, and chose
the encoder's number plus one. The expression jacks sit immediately above the
encoder, so that number is now pedal input. Fixed to a genuinely unrelated one,
with the reason written down.

## What the screen still needs, and is not here

The expression type stays out of the setup screen's type picker until the next
PR. A type that opened an empty panel would be worse than one not offered yet.
That PR carries the position readout, the calibrate view, the destination and
parameter picker, and the heel/toe editors -- and with them the accepted rule
that movement during calibration does not dispatch, which needs the UI state
that has not been built. A rule with nothing able to set it would be dead code
today.

## Verification

- Root suite: 2280 passing, 35 skipped.
- `pedal_repository`: 214 passing.
- `firmware/test/run_tests.sh`: green against both protocol copies, including
  the new CC-collision and clamp checks.
- `dart analyze --fatal-infos` clean in the app and the package; bloc lint clean
  over 257 files.
- Mutation-checked every guard added, all caught: the active-type check, the
  unusable-travel check, reversed travel (both a sorted-ends and an
  unsigned-distance implementation), the named jack resolution, the master-gain
  accumulator, the take-lock asymmetry, the duplicate-target drop, the
  expression half of the jack's emptiness rule, and the codec's clamp.

Part of #1026



=====
# PR #1041 feat(control): the expression half of External pedals [open] claude/expression-screen-1026 <- claude/external-expression-1026
labels: stage:in-review,autonomy:merge-gate,ci:red,review:clean

The screen an expression pedal needs. The type picker finally offers
Expression, because there is now something behind it.

## Four bodies, one page, one draft

The accepted design draws the calibration and both pickers as whole views rather
than panels over the page, so they are states of this page rather than routes of
their own. Back steps through them; Save and Cancel appear only on the main
body, because a Save offered from a half-chosen control would commit a decision
the performer has not finished making.

## The meter and the number say different things

That is the point of the pair. The **meter** shows the raw reading whether or not
the pedal has been taught anything, so a performer can see the jack is alive. The
**number** shows the position within the taught travel, and shows nothing until
there is a travel to measure against. A percentage of an unknown range would be a
number that means nothing.

A jack that has reported no position at all reads as not connected. That is only
honest if a connected pedal always reports, so the protocol header now carries
the obligation: the board sends each jack's current position once when the link
comes up, then on change. It is the only place that obligation can live, since
the firmware does not exist yet.

## Teaching the travel is a draft of a draft

- **Use calibration** stages the captures into the page's draft; **Save** commits
  them. A half-taught pedal never replaces a working one.
- **A travel under the accepted 10% minimum is refused in the panel**, not stored
  and quietly ignored later. The one place a performer can see why is where they
  are standing.
- **The captures are discarded when the link drops.** They were readings from a
  board that is no longer there, and half of an old travel must not meet half of
  a new one.
- **Sweeping to teach the ends writes nothing.** The interpreter is told before
  the view opens rather than after, so a sweep arriving in between is not
  dispatched by a pedal the performer is already teaching. It is deliberately not
  told when the link drops either: the view is still open when the cable comes
  back.

## Choosing what to sweep

No second catalogue. Part 4b's continuous targets, grouped: pick a destination,
then a control on it.

- **A track's own fader and the effects on its whole-track chain are ONE
  destination.** They are one thing to the performer. The rig reports them from
  different places, which is not a reason to ask for the track twice.
- **The kinds are the Effects page's own** Live inputs / Recorded tracks /
  Outputs, reusing `FxDestinationKind` and its strings rather than inventing a
  fourth spelling of the same three words.
- **A control already swept is offered and refused, not hidden.** A control that
  vanished from the list would read as a rig that does not have it.
- **Repointing keeps the endpoints.** The performer chose how far this pedal
  should travel; a different destination does not change that.
- **A control the rig has lost keeps its row and says so**, and is never
  repointed at whatever replaced it.

## Two things the pen draws that are not here

Both for the same reason: the app has no source for them, and inventing one would
be worse than the gap.

- **The 52 x 68 illustration on each row.** The study's icons come from the
  extracted Looper X factory images, which the owner already rejected for
  shipping over resolution and visible branding. No surface in this app draws
  effect icons, so this one does not either. Worth an owner call if generated
  icons are wanted.
- **Double-tap to reset an endpoint, and encoder editing.** Both are accepted
  interactions that no slider on this console implements; this app's shipped
  idiom for resetting a value is an explicit button. They belong to a change to
  the shared slider and the encoder-focus model, not to this screen.

## Two rendering bugs my own eyes caught

The goldens are why. **The meter drew its track and no fill** — a fractionally
sized box given only a width hands its child loose height constraints, and a
`ColoredBox` with no child takes none of them. And **Add control showed a bare
plus**: the shared button's `icon` replaces the label outright, where
`leadingIcon` is the one that sits in front of it.

## Verification

- Root suite: 2309 passing, 35 skipped. `pedal_repository`: 219 passing.
- Five new screenshots, all eyeballed: the empty jack, a pedal sweeping a
  control, the calibration mid-capture, and both pickers. The three switch
  goldens are regenerated for the third type button.
- `dart analyze --fatal-infos` clean; bloc lint clean over 262 files; the
  firmware contract suite green against both protocol copies.
- Mutation-checked every guard, all caught: the calibration suppression and its
  lifting, the captures cleared on a link drop, Calibrate needing a reading, Use
  calibration refusing a short travel, and repointing keeping the endpoints.

## Also

`docs/design/external-pedal-art/generation.json` is now tracked. It records that
these three illustrations are generated and unbranded and what produced them,
which is the provenance the accepted design points at for artwork the app ships.
The PNG sources stay untracked with the rest of `docs/design`.

Part of #1026



=====
# PR #1042 fix(enclosure): the CLEAR/BANK collar is solid, with a driver bore per deck screw [open] claude/mid-collar-solid-1037 <- claude/sheet-metal-enclosure-analysis-6c2aa4
labels: stage:in-review,autonomy:merge-gate,review:pending,area:enclosure

Closes #1037

Based on `claude/sheet-metal-enclosure-analysis-6c2aa4`, not master: that branch
is where the design lives, and master's collar is two revisions behind it.

The tall collar was a 3 mm shell over an open cavity with four Ø12 columns
carrying the base inserts. It is solid now and the slicer's infill does the
hollowing. The shell is what the slicer lays down at the perimeter anyway, so
modelling it only pinned the wall thickness and the part's density in geometry,
on the one printed part that carries a stomp from the sled into the base plate
(#1019). The print also loses its one support problem: it used to hang a
17,000 mm² ceiling over a void.

## The cavity's job is kept

The cavity was tool access for the 2026-09-09 two-joint mount, so filling it
outright would leave the four deck screws unreachable. Each deck-screw axis now
has its own Ø12 bore instead, sunk from the floor to the deck underside, blind
at the deck and open at the floor. The Ø6 × 3 head and the Ø8 straight driver
that the mounting brainstorm qualified both work inside one, with 2 mm of
radial slack.

The bench cost: those screws now go up a 30.3 mm tube rather than an open
cavity, so that step wants a long driver with the screw held on it. The
manufacturing notes say so.

| | before | after |
|---|---|---|
| enclosed volume | 165.9 cm³ | 420.9 cm³ |
| filament at 40% | about 150 g | about 240 g |
| fully solid would be | | 434.6 cm³ |

Nothing dimensional moves: base pockets, deck pattern, sled, stadium cable
opening, seating heights and every metal part are untouched. The front collar
never had a cavity and is byte-identical.

## Verification

- The branch's own suite: 98 tests, all pass, including every mid-platform
  mount test for driver access, head bearing and blind pockets.
- One test added for the solid underside. It checks the four Ø12 spans and
  probes the whole region between floor and deck for material. Against the old
  geometry that probe finds 129,271 mm³ of air, so it is not passing vacuously.
- Full generator run: geometry assertions and drawing/package assertions both
  ALL PASS.
- Regenerated outputs are limited to `segno_platform_mid_ring.step/.stl`. Every
  other file in `out/` differed only by timestamps or STEP entity renumbering
  and was reverted.

Fusion still holds the old collar in both documents. Re-importing it is a
follow-up, and the outside of the part has not changed, so nothing but a
section or a mass reading would show the difference.


=====
# PR #1043 feat(pedal): an external button drives effects and parameters beside its actions [open] claude/external-controls-1026 <- claude/expression-screen-1026
labels: stage:in-review,autonomy:merge-gate,ci:red,review:clean

The dispatch half of part 4f's Controls panel: an external button can turn any
number of effects on and off and set any number of parameters, in the same
gesture that runs its Press, Hold or On change. The panel that edits these is
the next PR.

## Two facts about a button, and they are not the same fact

**ON / OFF is logical.** Each completed press flips it, a latching switch sets it
to its contact, and it is remembered across a restart, because an effect being on
is part of how the rig sounds. **HELD is physical:** the contact is closed right
now.

An effect is active **On**, **Off**, **Held** or **Released**. A parameter
switches between two chosen values on **On / Off** or on **Held / Released**. Two
conditions rather than four for a parameter, because Off is On with the values
swapped.

## The accepted rules

- **With no Hold, a press is complete on contact** and flips the button there.
  **With a Hold, only a completed short press flips it**, and running the Hold does
  not also flip it; that is what makes a hold usable beside On / Off. The tap is
  armed even when the button has no press action, because the controls hang off
  the gesture, not off the action.
- **Held and Released follow the contact** and do not wait for the hold threshold.
  A latching switch never reports how long a foot stayed on it, so they are
  skipped on one.
- **Writes are edge-triggered, never level.** Saving a mapping, opening the screen
  or plugging a pedal in writes nothing, and a control the performer moved by hand
  stays where they put it until the button next says otherwise.
- **A button the active type does not have writes nothing**, so an Off or Released
  control cannot turn an absent source into an active effect.
- **Disconnect and Save both end a hold** and apply what Released means. On Save
  that happens under the setup the hold was pressed under, and a foot still down
  after a Save has to lift before it counts again. Only momentary contacts are
  held back that way: a latching switch's next change is a real change, not the
  end of a retired gesture.

ON / OFF has its own settings key, apart from the setup. The setup is
configuration, edited as a draft and undone by Cancel; a stomp is not.

## One departure from the accepted design's storage, and why

The design keeps an effect's activation rule **on the rack**, with the external
editor staging changes to it. This app has no rack activation rule to keep it on.
Every source that already toggles an effect here — a footswitch binding, a learned
MIDI switch — carries its binding on the source, so this one does too. The
behaviour the design describes is unchanged: removing an activation stops future
writes and leaves the effect's bypass flag where it is. If a rack-owned activation
rule is ever built, this is the binding that moves onto it.

## Verification

- Root suite: 2337 passing, 35 skipped. `settings_repository`: 157 passing.
- `dart analyze --fatal-infos` clean; bloc lint clean over 263 files.
- Fourteen dispatch tests and thirteen model tests. Mutation-checked, all caught:
  the suppressed contact after a Save, the hold ending on Save, the hold ending on
  unplug, a Hold that also flipped the button, a tap left unarmed without a press
  action, Released read off a latching switch, and ON / OFF not restored.
- One mutation survived and taught something: a separate "is this effect still in
  the rig" lookup before each write changed nothing, because the resolver's own
  write already refuses a missing target and reports it. The lookup is gone; the
  write's return value decides whether the LEDs are re-projected.

Part of #1026



=====
# PR #1044 feat(control): a button's Controls panel [open] claude/external-controls-panel-1026 <- claude/external-controls-1026
labels: stage:in-review,autonomy:merge-gate,ci:red,review:clean

The screen half of part 4f's last piece, on top of [#1043](https://github.com/tomassasovsky/segno/pull/1043)'s dispatch. A button's
editor gains the accepted **Actions / Controls** tab, and Controls lists every
effect and parameter the button drives, with the rule of the one open below it.
With this, part 4f is complete.

## The panel

- **An effect's rule is its condition**: On, Off, Held or Released, with the line
  under it saying what the choice means.
- **A parameter's rule is its behavior**, On / Off or Held / Released, and its two
  values, labelled Off and On or Released and Held to match.
- **On a latching switch**, the two conditions that read how long a foot stayed
  on the button are offered and refused rather than hidden, with the reason
  written under them.
- **A control the rig has lost keeps its row and says Unavailable.**

## Adding a control

It happens **inside the button's editor**, not over the page, as the pen draws it:
the switch art stays beside it, because the performer is still adding to that
button.

- The destination step reuses the expression pedal's picker at one column.
- The control step lists the destination's effects first, each named
  "· Activation" as the pen names them, then its parameters, in one list. That
  list has no section headings, so a parameter row names its effect.
- **A newly added parameter starts at the value it has now, on both sides**, so
  adding the mapping invents no sound change. Moving a value edits the draft and
  writes nothing to the rig.
- Controls already on the button are offered with a check and refused.
- Back steps from the control list to the destinations, then out of the picker,
  before it ever leaves the page.

## Three pieces now shared, because this PR would otherwise have written a third copy

- **One control row**, used by the expression pedal's sweeps, a button's controls
  and both pickers, so the three read as one list.
- **One list around it, which keeps the open row in view.** That is not
  decoration. The list shrinks when a parameter's values open below it, and my
  first screenshot showed exactly the failure: a newly added parameter selected,
  its values open, and its row scrolled out of sight. The test that pins the fix
  fails without it.
- **The accepted design's overflow arrow**, which neither list had. Nonfocusable,
  out of the accessibility tree, and it never takes a touch meant for the row
  under it.

The repository gains a master-gain reader and the value resolver a read, both for
the starting value above.

## Not built, and why

The pen's 68 x 68 illustration on each row has no source in the app, for the
reason given on the expression screen: the study's icons are extracted Looper X
factory images, already rejected for shipping. Recorded on #1026 as an open
decision.

## Verification

- Root suite: 2355 passing, 35 skipped. `looper_repository`: 548 passing.
- Eleven widget tests for the panel, three resolver tests, three new screenshots
  eyeballed. The switch goldens are regenerated for the new tab.
- `dart analyze --fatal-infos` clean in the app; bloc lint clean over 266 files.
  `looper_repository` reports ten infos in `fx_chain_group_test.dart`, which this
  PR does not touch and which are present without it.
- Mutation-checked, all caught: Held refused on a latching switch, the starting
  value read from the rig, the open row kept in view, and Back stepping out of
  the picker.

Part of #1026



=====
# PR #1045 feat(control): the External pedals rows draw the factory pedal pictures [open] claude/external-row-art-1026 <- claude/external-controls-panel-1026
labels: stage:in-review,autonomy:merge-gate,ci:red,review:clean

The External pedals rows now draw pedal pictures, per the owner's call: the
Looper X factory illustrations for now, the same ones the Effects page already
draws from the `fx_catalogue` package. No generated artwork.

## Which picture a row draws

Resolved the way the Effects page resolves them, so a pedal in a row here is the
pedal on that page.

- **A parameter, or one effect**, draws the pedal it belongs to: its module's
  stomp illustration.
- **A whole chain** draws its rack's footswitch picture when the chain is one rack
  end to end, and nothing when it is several racks or a rack beside a lone effect.
  There is no single pedal to show for those.
- **A fader or the master gain** draws nothing, as the pen draws them.
- **An effect the rig no longer has** draws nothing: there is no entry left to ask
  what it was.

## Where

Every list on the screen, each at the pen's size and gap:

| List | Picture |
| --- | --- |
| Expression pedal sweeps | 52 x 68 |
| A button's controls, and its control picker | 68 x 68 |
| Expression control grid | 42 x 54 |

A picture that fails to load keeps its space, so every row's names stay in one
column.

## One path, one place

The footswitch asset path was spelled in the FX chain strip and would have been
spelled again here. It now lives in the catalogue package as `fxFootswitchAsset`,
beside the family and stomp paths it belongs with, and both FX views call it.

## Verification

- Root suite: 2363 passing, 35 skipped. `fx_catalogue`: 20 passing.
- Five catalogue tests for the resolution rules and one widget test that a row
  draws its pedal and a fader row draws none. The five affected screenshots were
  regenerated and eyeballed.
- `dart analyze --fatal-infos` clean in the app and the package; bloc lint clean
  over 266 files.
- Mutation-checked, both caught: dropping the one-rack rule, and a row not passing
  its picture to the shared tile.

Part of #1026



=====
# PR #1047 feat(midi): Program Change is captured, and MIDI formats are read explicitly [open] claude/midi-formats-1026 <- claude/external-row-art-1026
labels: stage:in-review,autonomy:merge-gate,ci:red,review:clean

The foundation of part 4g, MIDI Learn formats. Two things the explicit-format
Learn needs before it can exist, and one learn-hygiene gap they exposed. Nothing
the performer sees changes yet; the Learn that uses this is the next PR.

## Program Change reaches the app

It was dropped at the first step: the native parser classified `0xC0` as ignored,
and the Linux backend never forwarded it.

- The parser reports `LE_MIDI_PROGRAM`: one data byte, value always 0, so the
  ring, drain and callback keep their one message shape. A stray second byte
  belongs to the next message and is never read as a value.
- ALSA's `PGMCHANGE` is forwarded (its program rides in `value`, not `param`).
  CoreMIDI already framed one-data-byte messages.
- The Dart source carries it as `ControllerSourceKind.midiProgram`.
- **The existing 7-bit bindings do not learn or dispatch it.** They read a value
  and a release, and a Program has neither. It is carried for the formats.

## The formats, as a pure module

`MidiProtocol`, `MidiSource` and `MidiDecoder`: Standard Note/CC/Program, 14-bit
CC, NRPN, Bank + Program and relative CC.

**Nothing is inferred from one byte.** `CC 21 = 64` is a plain knob, the high half
of a 14-bit one, and a relative step all at once. The decoder is told the format
and returns only complete readings.

**Every worked Learn example in the design document is a test, verbatim:**

| Format | Messages | Reading |
| --- | --- | --- |
| 14-bit CC | CC 21=64, CC 53=1 | 8193 / 16383 |
| NRPN | 99=2, 98=3, 6=64, 38=7 | parameter 259, 8199 / 16383 |
| Bank + Program | 0=2, 32=4, Program 8 | bank 260, program 8 |
| Relative CC | CC 22=127 | one step down |

**The receiver choices the design records as prototype contracts are the
decoder's**, each tested: a 100 ms freshness window with a fresh pair per update;
RPN selection and the NRPN null selection cancelling NRPN; Data Increment and
Decrement discarding pending data; a partial bank invalidating the one before it.
Partial state is kept per device, channel and protocol, and resets per device.
The design is explicit that these need physical controller validation.

**A source's identity** is its device, channel or All, format, number, and the
NRPN parameter or bank. **Overlap is refused across formats** on any shared raw
footprint, on channels that meet, on the same device: a CC 53 knob and a 14-bit
CC 21/53 knob cannot both be mapped, because every message of one is a message of
the other. Distinct NRPN parameters and banked Programs stay independent.

## The gap it exposed

The predicate that keeps the pedal's own traffic out of MIDI Learn did not know
the CTRL jacks. The external switch Notes (#1036) and the expression CCs (#1039)
were learnable, so a MIDI binding learned from a jack would run beside the pedal
setup's own assignment: the same stomp, or the same sweep, twice. It claims them
now, and the test that said "CC 17 is a third-party controller" is corrected.

## Verification

- Native suites: all passing, including a Program Change parse test and the ring
  keeping Program while still dropping channel pressure.
- `controller_repository`: 101 passing. `midi_client`: 55. `pedal_repository`:
  220. Root suite: 2363 passing, 35 skipped.
- `dart analyze --fatal-infos` clean in the app and all three packages; bloc lint
  clean.
- Mutation-checked, all caught: the freshness window, the fresh pair per update,
  RPN cancelling NRPN, a partial bank invalidating the previous one, cross-format
  footprint overlap, device identity across formats, and the jack notes in learn
  hygiene. The device-identity mutation first survived: the test compared two
  sources of one format, where `sameAs` already separated them. It now compares
  across formats, where only the device check does.

The Linux backend's new case is inside the ALSA build, which this Mac's native
suite does not compile. CI's Linux job does.

Part of #1026



=====
# PR #1048 feat(midi): the MIDI mapping engine [open] claude/midi-mapping-engine-1026 <- claude/midi-formats-1026
labels: stage:in-review,autonomy:merge-gate,ci:red,review:clean

The second of part 4g's three PRs: what a mapped MIDI control does, as a pure
engine in `controller_repository`. Nothing reads it yet. The MIDI controls page,
the cubit wiring and the removal of the old binding model are the third PR.

## The model

A **mapping** is one source with any number of controls:

- **parameters**, swept between two values: a knob's bottom and top, a momentary
  button's Released and Held, a toggle's Off and On. Either value may be the
  larger, which is how a control inverts a parameter.
- **actions**, run on a press or a release.

Its **behavior** is a knob, a momentary or toggle button, or a Program trigger. A
mapping can be **disabled** without losing its source. Every control's key is
opaque here, so the package stays free of the looper and of the app's action
vocabulary.

## The runtime rules

The engine returns outputs rather than writing, and reads a parameter's current
value only because two accepted rules need it. Each rule below is tested and
mutation-checked:

- **A knob writes nothing until it takes over**: its value lands within a step of
  the parameter's, or crosses it. Opening a rig never jumps a parameter.
- **A relative control** moves from the current value by the parameter's step, in
  the direction its range runs, and stays inside the range.
- **A button is down while any channel it listens on is down.** A toggle flips on
  press; a press action is ended on release; a Program is always a press and is
  never released.
- **Turning Control off, disabling or deleting a mapping, pausing its device for
  Learn, or a disconnect all end every hold**: momentary parameters return to
  Released and held actions end. None of them runs an action.
- **A reconnect** clears contacts, takeover and toggle latches, so the next input
  starts from nothing.

**Saving refuses an overlapping source, disabled mapping or not.** A disabled
mapping keeps its source so it can be turned back on, which it could not be if
something else had taken it. A mapping that cannot drive what it carries says
why: a 14-bit, NRPN or relative control has no edge to run an action on, and a
Program has no release. A learned source starts with the behavior it fits.

## One departure from the prototype's implementation, not its design

A toggle's parameters are written when the latch moves, not again on release.
The prototype re-writes the unchanged value on release; that would snap back a
value the performer adjusted on screen since the press.

## Verification

- `controller_repository`: 135 passing, 34 of them for the engine and model.
- `dart analyze --fatal-infos` clean in the package and the app.
- Mutations run, and all but one caught: takeover, takeover by crossing, the
  relative clamp and direction, a button down on any channel, Control off
  releasing, pause stopping dispatch, a disconnect releasing, and the reconnect
  resetting the latch. The survivor was the engine's early filter by device: it
  only saves decoding another device's messages, because the source comparison
  after it already refuses them, and that comparison is pinned in #1047.

Part of #1026



=====
# PR #1049 feat(midi): the control interpreter runs the MIDI mapping engine [open] claude/midi-engine-wiring-1026 <- claude/midi-mapping-engine-1026
labels: stage:in-review,autonomy:merge-gate,ci:red,review:clean

The first half of part 4g's last piece: the MIDI mapping engine from #1048, wired
into the control interpreter, persisted, and fed. The MIDI controls page that
creates mappings, and the removal of the old binding model, are the next PR.
Until then the new set starts empty, so nothing a performer has already mapped
changes.

## What is wired

- **Undebounced messages.** `MidiDeviceRepository.messages` publishes every
  recognized message with its values. The existing input stream drops a repeat of
  one control inside 30 ms so a bouncing footswitch cannot double-toggle a take;
  14-bit and NRPN pairs repeat far faster than that, which is the constraint
  recorded on #1047.
- **Device identity.** The open device, while connected, is the identity a
  mapping's source must name. A device going away or being swapped ends its holds
  under the engine's rules, and the arriving one starts from nothing.
- **Writes and actions.** Parameter writes go through the same value-target path
  a learned CC and an expression pedal use, so the master-gain accumulator stays
  in step. Actions go through the shared catalogue's one interpreter, and are
  refused behind the power-off route like a footswitch's.
- **Learn** listens on the open device in the chosen format and never takes the
  pedal's own traffic. It reports the saved mapping the captured source overlaps,
  disabled or not. It pauses that device, which releases the device's momentary
  values, and leaving the editor resumes it. The device going away ends Learn, and
  with no device connected there is nothing to learn from.
- **Save** refuses an overlap, or a mapping that cannot drive what it carries.
  Mappings and Control enable persist under their own settings keys. Control off
  keeps every mapping and ends every hold.

## Verification

- Root suite: 2378 passing, 35 skipped. Fifteen new cubit tests.
- `midi_device_repository`, `settings_repository` and `controller_repository`
  suites pass; `dart analyze --fatal-infos` clean in all three and in the app;
  bloc lint clean over 267 files.
- Mutation-checked, all caught: pedal traffic refused by Learn, the take lock on
  MIDI actions, Learn ending with its device, a disconnect releasing a hold, Save
  refusing an overlap, Control off releasing, and Learn releasing holds on start.
  The last one first survived: Learn already stops dispatch by never reaching the
  engine, so a test that only checked dispatch could not see the release. It now
  checks the hold returning to Released when Learn starts.

Part of #1026



=====
# PR #1051 fix(engine): with sync off, the click after the first recording follows the loop [open] fix/click-sync-off-loop-beats-1050 <- master
labels: stage:in-review,autonomy:merge-gate,review:clean,area:engine

## Problem

With **Sync tempo off**, the click was in time during the first recording and out of time on every recording after it (bench report, appliance build 136, 90 BPM, click "while recording").

Sync off leaves the defining loop without a beat grid, so later clicks came from `click_frame`'s free-running scheduler. That scheduler restarts its downbeat whenever the click gate opens, so each new recording counted beats from its own record press.

## Fix

Once a loop exists, `grid_beat_frame` schedules the click whether or not sync gave it a grid:

- **Grid-free loop:** beat = loop position / nominal frames-per-beat. This is the same `llround(60 * sr / bpm)` the free-running scheduler clicked the defining take with, so beat k lands where the take was played.
- **Loop top:** starts the count again. A loop that isn't a whole number of beats has a short last beat.
- **A punch mid-beat** waits for the next beat, the same rule as on a grid.
- **Beat publication:** a grid-free loop publishes `current_beat` only while the click sounds, as the free-running scheduler did (keeps `test_commit_session_resets_stale_grid`).
- The free-running scheduler now runs only for the defining take (no loop yet).

## Evidence

Engine probe: 90 BPM, 4.3 s first take, second track recorded mid-beat at 11.0 s. Loop positions of that track's clicks:

| | positions |
|---|---|
| before | 114785, 146785, 178785, 4385, 36385 ... (counted from the press, moving every cycle) |
| after | 128000, 160000, 192000, 0, 32000 ... (the take's beats, every cycle) |

Sync on is unchanged.

New test `test_click_sync_off_second_recording_follows_loop_beats` fails on master (3 checks) and passes here. `run_native_tests.sh`: ALL PASSED.

## Verification left

Ear check on the appliance: sync off, record a loop to the click, then record another track and listen to the click.

Closes #1050

