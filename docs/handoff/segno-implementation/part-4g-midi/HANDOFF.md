# Handoff: part 4g, the MIDI controls page and removal of the old MIDI model

Written 2026-09-14. Epic #1009, slice issue #1026, part 4g. This folder is untracked
(like the rest of `docs/handoff` and `docs/design`); a git worktree cannot see it, so
read it from the main checkout at `/Users/Tomas/Documents/Work/opensource/loopy`.

> This is the detailed part 4g handoff. The handoff for the whole implementation, including every earlier slice, the PR stack, and the master changes (#984, #986) that affect slice 4, is `../HANDOFF.md`.

## Progress since this was written

Both PRs are built and committed locally. Neither is pushed: the GitHub CLI token expired (`gh auth status` reports it invalid), so pushing and opening PRs needs the owner to run `gh auth login` first.

- **PR A, branch `claude/midi-controls-page-1026`** (worktree `.../scratchpad/wt-4fe`, base `claude/midi-engine-wiring-1026`).
  - Commit `5a9679af` adds the editor session in `ControlCubit`: `beginMidiEdit`, `startMidiLearn(protocol)`, `cancelMidiLearn`, `endMidiEdit`, with `ControlState.midiEdit` replacing `midiLearn`. It also adds the 15 s Learn timeout, write-first serialized MIDI writes, the paused-after-disconnect fix, `MidiSource.withChannel`, `MidiMappingSet.nextId` and `MidiSignalLevels`.
  - Commit `2b9e39c9` adds the page: `lib/control/view/midi_controls/`, `MidiMappingDraft`, `midi_labels`, the `openMidiControls` route, the Control face row, strings, tests and 13 screenshots.
  - Commit `efa5a24f` fixes what an independent review found (26 candidates, checked one by one against the code, each fix mutation-tested).
  - The PR body is in `pr-a-body.md` in this folder.
- **PR B, branch `claude/midi-old-model-removal-1026`** (worktree `.../scratchpad/wt-4ff`, stacked on PR A).
  - The one commit on it (rebased onto `efa5a24f`) does everything in section 8, plus `command:tap-tempo` in the shared catalogue.
  - The body is in `pr-b-body.md` in this folder.
- **Verified:**
  - PR A: root suite 2468 passing; PR B: 2380 passing.
  - Package suites, `dart analyze --fatal-infos`, `bloc lint` and cspell are clean.
  - Mutation checks on the session, page and model rules.
  - Screenshots compared with the pen by eye.
- **Not yet done:**
  - Push both branches, open both PRs with labels `stage:in-review`, `autonomy:merge-gate`, `ci:red`, `review:pending`.
  - Post the #1026 progress note with the section 5 decisions and the pen departures listed in `pr_a_body.md`.
- **Gotchas found:**
  - `bloc lint` refuses public cubit methods and getters that return values, so the MIDI cubit methods return `Future<void>` and the page reads state afterwards.
  - The ARB files contain duplicate keys; edit them as text, never through a JSON round trip.
  - A cubit method that chains on a stored future hangs inside `tester.runAsync`.
  - Close stream controllers unawaited in widget-test `tearDown`.

## 0. Read these first, in this order

1. `/Users/Tomas/Documents/Work/opensource/loopy/AGENTS.md` and `docs/TRACKING.md` (engineering, build, tracking and review contract).
2. `docs/handoff/segno-app/IMPLEMENTATION_PROMPT.md` and the files it references (`accepted-behavior.md`, `implementation-map.md`, `delivery-checklist.md`, `reference-gates.md`).
3. This file.
4. The research reports in this folder. Each claim in them carries `file:line` references against commit `63d8d7b5`.
   - `research-pen-spec.md`: every screen, state and string of the accepted design, from pen sections 26 and 53, the design docs and the prototype.
   - `research-cubit-map.md`: the old and new MIDI paths in `ControlCubit`, the tests on each, and the gaps the page needs closed.
   - `research-ui-navigation-map.md`: the Control tray and audio settings UI being removed, Settings navigation, reusable pen-size widgets, l10n keys and screenshot rigs.
   - `research-old-model.md`: the complete removal inventory for the old controller model, symbol by symbol, with every file to delete or edit, tests, ARB keys and tracked docs. Where it disagrees with the other reports, it is the later and more exact reading (see section 8).
   - `pen/*.png`: exports of the pen screens (scale 0.5). The reports cite these under an older scratchpad path; the same files are here.
5. Design docs (main checkout only): `docs/design/2026-09-07-midi-controls-ux.md`, `docs/design/2026-09-09-optional-controls.md`, prototype `docs/design/midi-controls-study.js`, `docs/design/midi-protocol-study.js`, `docs/design/pedal-action-catalogue.js`.
6. The design source is `/Users/Tomas/Documents/Work/opensource/loopy/segno-ui.pen`. Read it only through the pencil MCP tools (`execute` with `filePath` and `input`; `Get`/`Print`/`Export`). Never Read or grep the `.pen` file. The owner has uncommitted edits in it; never commit it.

## 1. The standing request and the constraints

Owner request, verbatim: "Read @docs/handoff/segno-app/IMPLEMENTATION_PROMPT.md and the context it references, then begin implementing the accepted designs throughout the app. Follow the implementation order and verification requirements. Reuse the existing architecture, preserve the accepted UX, and keep the product working after each slice. Proceed autonomously. Document progress and remaining gaps, and only ask me when a genuine product decision or missing external resource blocks you."

Owner decisions already made (do not reopen):
- Row pictures use the Looper X factory images in `packages/fx_catalogue` (`fxModuleArt(module)`, `fxFootswitchAsset(slug)`, `Image.asset(..., package: FxCatalogueLoader.package)`). Never generate artwork.
- AGENTS.md: "Do not preserve backward compatibility. Remove obsolete paths instead of adding compatibility layers, fallbacks, or migrations."
- The accepted design has no reserved CC command scheme: a MIDI controller does nothing until the performer maps it.

Working rules:
- No emojis anywhere, including commits, PRs and issue comments.
- No attribution lines in commits or PR bodies.
- Plain literal prose (see `~/.claude/CLAUDE.md`): "When a literal phrase is available, use it."
- Commit from a git worktree, never the main checkout (the main checkout carries the owner's uncommitted work).
- Push with `git -c credential.helper='!gh auth git-credential' push` (plain `git push` hangs on the keychain in this sandbox).
- Before `git add -A`, run `git checkout -- packages/*/analysis_options.yaml`.
- Never run `dart format .` at the repo root. In a fresh worktree run `flutter pub get` (and `flutter gen-l10n` if l10n changed) first, then format only the directories you touched. Formatting an unresolved worktree rewrites about 200 files.
- A shipped departure from `segno-ui.pen` is a design change: write it back into the pen (geometry plus a `c/` note) or record it on the issue; never leave it only in a PR body.
- Do not start Agent subagents or workflows unless the owner or the session settings ask for them.

## 2. Where things are

- Main checkout: `/Users/Tomas/Documents/Work/opensource/loopy` (branch `master`, dirty with owner work; do not commit there).
- Worktree used so far: `/private/tmp/claude-501/-Users-Tomas-Documents-Work-opensource-loopy/1a736a10-cdfb-4daa-ad93-3176a9204d1d/scratchpad/wt-4fe`. It sits on the new branch `claude/midi-controls-page-1026`, created at `63d8d7b5` (the head of #1049), with **no commits and no changes yet**. That path is session scratch and may be gone; if so, create a new worktree from `origin/claude/midi-engine-wiring-1026` and branch from it.
- The open PR stack for epic #1009, oldest first. Each PR's base is the previous branch. All are `stage:in-review`, `autonomy:merge-gate`, `ci:red`. CI stays red across the stack until the #1011 gate is fixed.
  - Slice 3: #1017, #1018, #1020, #1021, #1022, #1024.
  - Slice 4 (#1026): #1027, #1028, #1029, #1030, #1031, #1032, #1034, #1035, #1036, #1039, #1041, #1043, #1044, #1045.
  - Part 4g: #1047 (`claude/midi-formats-1026`), #1048 (`claude/midi-mapping-engine-1026`), #1049 (`claude/midi-engine-wiring-1026`). All three are `review:clean`.
- Issue #1040 (open, needs an owner call): one MIDI input is captured at a time, and that input is shared with the Segno pedal.

## 3. What part 4g has already built

**#1047, formats.**
- Native Program Change capture: `LE_MIDI_PROGRAM`, ALSA `SND_SEQ_EVENT_PGMCHANGE`, and `ControllerSourceKind.midiProgram`.
- `packages/controller_repository/lib/src/midi_protocol.dart` defines three types:
  - `MidiProtocol`: `standard`, `cc14`, `nrpn`, `bankProgram`, `relative`.
  - `MidiSource`: `device`, `kind`, `number`, `channel` (null means all channels), `protocol`, `parameter`, `bank`. It has `overlaps` and `footprint`, and no `copyWith` yet.
  - `MidiDecoder`: pairs must arrive within 100 ms.
- `isPedalProtocolInput` (pedal_repository) marks the CTRL jacks' Notes 10-13 and CCs 0x11/0x12 as pedal traffic, so Learn skips them.

**#1048, the pure mapping model and engine.**
- `midi_mapping.dart`:
  - `MidiBehavior` and `MidiEdge`.
  - `MidiControl`, one of `MidiParameterControl{key, low, high}` or `MidiActionControl{key, trigger}`.
  - `MidiMappingProblem`.
  - `MidiMapping{id, source, behavior, controls, enabled}`, with `defaultBehavior` and `problem`.
  - `MidiMappingSet`, with `conflictWith(source, {exceptId})`; `withMapping` throws on a problem or an overlap.
- `midi_mapping_engine.dart` (`MidiMappingEngine`) returns `MidiParameterWrite`, `MidiActionRun` and `MidiActionEnd` outputs. It implements:
  - pickup
  - relative steps
  - momentary and toggle (a toggle writes only when the latch moves)
  - releases on Control off, disable, delete, pause and connection change.

**#1049, wiring into `lib/control/cubit/control_cubit.dart`.**
- `MidiDeviceRepository.messages` is the undebounced stream. Do not switch it to the debounced `inputs` stream: the 30 ms debounce drops half of a 14-bit or NRPN pair.
- Settings keys `midi.mappings` and `midi.control_enabled`.
- State: `ControlState.midiMappings`, `midiControlEnabled`, and `midiLearn` (type `MidiLearn` in `lib/control/binding/midi_learn.dart`; not exported from `lib/control/control.dart`).
- Public methods: `saveMidiMapping`, `deleteMidiMapping`, `setMidiMappingEnabled`, `setMidiControlEnabled`, `startMidiLearn(protocol, {editingId})`, `endMidiEdit()`.
- `MidiMappingSet.fromJson` drops stored mappings that are invalid, duplicated, overlapping, or have a `problem`.

Signatures and line numbers are in `research-cubit-map.md` section 3.

## 4. What remains in part 4g

The plan posted on #1026 describes the last part as "the MIDI controls page as the pen draws it, the cubit dispatching the engine's writes and actions, and the old model and the Control tray's mapping editor removed rather than kept beside it."

It is large. The recommended split is two stacked PRs, each leaving the app building and working:

- **PR A, `feat(midi): the MIDI controls page`**, base `claude/midi-engine-wiring-1026`: the cubit fixes and editor-session API (section 6), then the page, route and entry point (section 7). The old tray editor still exists at this point; both paths already coexist since #1049.
- **PR B, `refactor(midi): the old MIDI binding model and fixed CC scheme are removed`**, base PR A: the removals in section 8 and the tests ported in section 9.

A single PR is acceptable if it stays reviewable. Either way the PR body says `Part of #1026`.

## 5. Open questions, with the default to use unless the owner says otherwise

None of these block the work. Record each one on #1026 when it is decided or deferred.

1. **Entry point.**
   - The pen's Settings home is a 10-tile grid with a MIDI tile (`gVIpz`), which the app does not have (`research-ui-navigation-map.md` section 3).
   - Today MIDI sits in the header gear tray, Control face, MIDI tab (`ControlTab.midi`).
   - Default: remove the tab strip from the Control face (the Pedal body stays) and add a "MIDI controls" route row there that opens the page. This matches the "Pedals setup" row, which opens `PedalSetupPage`.
   - Add `segnoMidiControlsRouteName`, a `_midiControlsOpen` guard, `openMidiControls()` and its reset in `resetSegnoNavigatorForTest`, all in `lib/app/segno_navigator.dart`.
   - Trap: a new `TrayRailEntry` route row must update `_routeGlyph`, `_routeLabel` and `_openRoute`. Otherwise it silently gets Loop's icon, label and route.
2. **Controls / Sync top-bar tabs.** MIDI Sync is not built, and `SettingsTrayDestination` forbids placeholders. Default: draw the page title with no Sync tab. Record the gap on #1026, since it is missing scope and not a design change.
3. **Device cards and #1040.**
   - The app has one pinned input (`MidiConnection.selectedId`) plus the currently enumerated `devices`. `MidiDevice` has no USB/DIN transport field and no per-device connected state.
   - Default: cards list the enumerated devices plus the pinned device even while it is unplugged (the tray already dims an unplugged pinned device).
   - Tapping a card calls `MidiSetupCubit.select(id)`, exactly what the tray does today. The mapping rows filter to the selected card's device.
   - Do not invent USB/DIN labels the backend cannot report; record that gap.
   - Selecting a controller replaces the pedal's shared input. That is existing behaviour and the subject of #1040; do not change it here.
4. **Who owns mappings.**
   - `accepted-behavior.md` item 9 says session recall restores "musical MIDI assignments" and preserves "global MIDI enable/sync settings".
   - #1049 stores mappings in app settings.
   - Default: keep app settings, the same place pedal actions and expression ranges live today, and record that the session-recall slice moves all three together. Check how pedal actions are stored before writing that note.
5. **Pan and balance targets.**
   - The pen's "Choose a parameter" lists Volume and Pan. `ControlValueTarget` has only `FxParamTarget`, `TrackVolumeTarget` and `MasterGainTarget`, so `expressionTargetName` cannot name pan.
   - `IMPLEMENTATION_PROMPT.md` says not to drop a feature because its API does not exist yet. If `LooperRepository` exposes pan read and write (slice 3a built the mix model with pan), add a pan target in the same shape; otherwise record the gap.
6. **Held-instrument rule** ("While held needs a momentary Note or CC button..."). Instruments are not built. Leave it out and record it with the instruments slice.
7. **Relative step.** It is fixed at `0.01` for every parameter (`control_cubit.dart` around line 342). The design says "the target's step". Use the encoder step where a target defines one; otherwise keep 0.01 and record the gap.

## 6. Cubit work needed before the page (PR A, first commits)

**Confirmed bug from #1049 (fix first, with a test).**
- Trigger: the open device disconnects or is swapped while Learn is open.
- `_onMidiConnection` clears `midiLearn` but never calls `_midi.resume(device)`.
- `MidiMappingEngine.connectionChanged` does not remove the device from `_paused`.
- `endMidiEdit` returns early when `midiLearn == null`.
- Result: when the same device reconnects, its mappings never dispatch again, until the next Learn on it.
- The existing test "a device going away ends Learn" (`test/control/control_cubit_midi_test.dart` around line 335) checks only that Learn is cleared. Add an assertion that a mapping dispatches after reconnect.

**Gaps.** Details and evidence are in `research-cubit-map.md`, "Gap list". Recommended shape:
- **An editor session separate from Learn.** The design says editing an existing mapping pauses its device even without Learn, and entering an edit releases its held values.
  - Add `beginMidiEdit({required String device, String? editingId})`, which pauses the device and emits a session state.
  - `startMidiLearn(protocol)` needs an open session on the connected device.
  - `cancelMidiLearn()` clears Learn and keeps the device paused.
  - `endMidiEdit()` always resumes the session's device and clears the session and Learn.
  - Keep the draft widget-local, as `PedalSetupPage` and `ExternalPedalPage` do. The page calls `endMidiEdit` from `dispose` (precedent: `ExternalPedalPage.dispose` calls `setCalibrating(null)`).
- **Save must report its outcome.**
  - `saveMidiMapping` returns `Future<void>` and refuses silently.
  - `_persistMidiMappings` emits and updates the engine before the settings write completes, so a failed write leaves state and disk different.
  - The design says a failed save keeps the draft open with "Could not save. Your changes are still here." and keeps the previous saved mapping.
  - Return a result: saved, refused (problem or conflict), or write failed. Commit state only after the write succeeds, or roll back.
- **Mapping ids.** There is no id generator and no uuid dependency. Generate an id that is unique within the set, for example a microsecond timestamp in base 36 with a collision check.
- **Learn timeout.** It is 15 s in the design. On timeout Learn ends with "No message received. Try Learn again.", or "Reconnect the controller to continue." while offline. The old path had a `_learnTimeout`; the new one has none.
- **"Edit existing mapping" after a conflict.** It switches the session to the conflicting mapping id.
- **Received readout.** The editor shows it only after a successful Learn in the session, so `MidiLearn.reading` is enough for the editor.
  - The list rows also draw a signal meter per mapping ("Last received value N").
  - That needs a last level per mapping from the engine or cubit. Throttle state emits so a moving fader does not rebuild the page on every message.
- **`MidiSource.copyWith`.** The channel picker needs it (Omni or channels 1-16).
- **`ControlCubit.close()`** does not release engine holds. The design stores held values as Released. Check and test what a close during a hold persists.
- **Export `midi_learn.dart`** (and any new session type) from `lib/control/control.dart`.

## 7. The page (PR A)

The full spec is `research-pen-spec.md`. Summary:

**Size.**
- Pen screens exist only at 1920x1080.
- Settings pages render one pen size through `LoopPenCanvas` / `LoopSettingsFrame` (`lib/looper/view/loop_settings/loop_settings_frame.dart`; the shared widgets are in `loop_settings_widgets.dart` beside it). The 7-inch display shows the selected track while Settings is open.
- So the "both display sizes" check means a 1920x1080 screenshot, plus confirming the 7-inch window is unchanged.

**Views.** Use an in-page view enum with Back stepping through the views, like `ExternalPedalPage`.
1. **List** (`RIrL3`):
   - Title "MIDI controls". Actions "MIDI control On" / "MIDI control Off" and "Add mapping".
   - Device cards.
   - Rows: the source name (for example "CC 21 · Ch 1") over the target labels joined by " · ", then a signal meter, a warning ("Missing control" or "Disconnected"), and a power button.
   - The power button saves immediately. A disabled row is drawn at opacity 0.5.
2. **No mappings** (`vsyj4`): a centred "No mappings".
3. **Disconnected** (`sSpdN`): the card reads "USB · Disconnected", the row warning reads "Disconnected", and the page notice reads "Controller disconnected". Learn is disabled while offline.
4. **Editor**: title "Mapping", actions Delete (saved mappings only), Cancel, Save (primary; disabled while there is no source, no controls, a conflict, or Learn is active).
   - Source panel (480 px), from top to bottom:
     - device name
     - source name, or "No control selected"
     - Message format picker (section 53)
     - "Received ..." readout
     - "Receive · Channel N" / "Receive · Omni"
     - Learn / "Learn another control", or while listening a box reading "Move a control" / "Reconnect controller" plus "Cancel Learn"
     - conflict text "This control overlaps an existing channel mapping." plus "Edit existing mapping"
     - "Knob / fader" | "Button" (standard-format CC only)
     - "Momentary" | "Toggle" (buttons that are not Program)
   - Controls column: "Controls" heading, "Add control", placeholder "Choose what this control changes.". Each card has a label, "Change control" / "Repair control" and a remove button.
     - Parameter card: two sliders captioned From/To (continuous), Off/On (toggle), Released/Held (momentary), or a single "Value" (Program).
     - Action card: "When" followed by "Pressed" | "Released" (Program shows "Pressed" only).
   - "Add mapping" creates the draft and starts Learn at once.
5. **Pickers the pen does not draw** (built from the prototype):
   - Choose a destination: "Performance actions" first, disabled with "· use a button" for 14-bit, NRPN and Relative; then the destinations.
   - Choose a parameter (`l3ouX`).
   - Performance actions with group tabs.
   - Receive channel: "Omni · All channels", then "Channel 1" to "Channel 16".
   - Message format: five rows with details. Choosing a format starts Learn immediately. It is refused with "Remove action targets before learning a high-resolution or relative control." while action controls exist.
6. **Notices**: "Saved", "Mapping removed", "This source now overlaps another mapping.", "Actions need a button.", "MIDI controls enabled" / "MIDI controls paused", "Could not save MIDI control setting".

**Section 53 readouts.**
- Source names: "CC 21 / 53 · 14-bit · Ch 1", "NRPN 259 · Ch 1", "Bank 260 · Program 8 · Ch 1", "CC 22 · Relative · Ch 1".
- Received lines: "Received 8193 / 16383", "Received 127 / 127", and "Received -1 step" / "Received +3 steps" (ASCII hyphen).

**Reuse, do not rebuild** (constructor signatures in `research-ui-navigation-map.md` section 4):
- `LoopSettingsFrame`
- `ControlRowTile` / `ControlRowList`
- `ExpressionDestinationPicker` / `ExpressionControlPicker`
- `expressionTargetName` / `expressionRowName` / `expressionDestinations` / `expressionTargetArt` (row art must come from here)
- `showControlActionPicker` and `controlActionCatalogue`: one action catalogue for every picker
- `LoopSlider`, `LoopChoiceButton`, `LoopOutlinedButton`, `LoopNote`
- The `MidiSetupCubit` status mapping from `midi_tray_body.dart` lines 311-332, moved rather than copied.
- There is no pen-size toggle widget. "MIDI control On" is a selected/unselected `LoopOutlinedButton` in the pen, so none is needed.

**Code placement.**
- Proposed files: `lib/control/view/midi_controls/midi_controls_page.dart`, `midi_mapping_list.dart`, `midi_device_cards.dart`, `midi_mapping_editor.dart`, and `lib/control/binding/midi_labels.dart` (source-name and received-line formatting, localized).
- The existing strings `midiLearnCcControl`, `midiLearnNoteControl` and `midiLearnProgramControl` can be reused for source names.
- Extract widget classes, not `_build` methods; no pixel parameters in widget APIs; tokens from `context.surface` (VGV rules in memory `loopy-vgv-architecture-standards`).

**Tests.**
- Cubit tests for every new method and the bug fix.
- Widget tests modelled on `test/control/external_pedal_page_test.dart`.
- A screenshot suite modelled on `test/screenshots/external_pedal_screenshots_test.dart` (tag `screenshots`, `skip: !hasScreenshotFonts`, 1920x1080, `tester.runAsync` + `precacheImage` for artwork, goldens `goldens/midi_controls_<state>.png`). Eyeball every golden against `pen/*.png`.
- Mutation-check the important rules: temporarily break the code and confirm a test fails.

## 8. Removal inventory (PR B)

Sources: `research-cubit-map.md` sections 1 and 2, and `research-ui-navigation-map.md` sections 1, 2 and 5. Grep again before deleting; line numbers drift.

**Delete these files.**
- `lib/control/view/midi_tray_body.dart`
- `lib/audio_setup/view/midi_learn_section.dart`, plus its export in `lib/audio_setup/audio_setup.dart`
- `lib/control/binding/controller_learn.dart`, plus its export in `lib/control/control.dart`
- In `packages/controller_repository/lib/src/`:
  - `controller_binding.dart`
  - `controller_binding_event.dart`
  - `controller_binding_set.dart`
  - `controller_mapping.dart`
  - `looper_action.dart`
  - `controller_event.dart`
  - `simulated_controller_source.dart`
  - `controller_repository.dart`, the class itself: once the fixed scheme and binding set are gone it has no job; confirm with grep first.
- `lib/control/control_tab.dart`, if the Control face drops its tabs.

**Keep.**
- `binding_behavior.dart` (`BindingBehavior`): the pedal footswitch assignment uses it (`lib/control/binding/pedal_binding.dart`, `lib/pedal/view/pedal_assignment_page.dart`).
- `controller_input.dart` (`RawControllerInput`, `ControllerSourceKind`) and `controller_source.dart`, if `MidiControllerSource` still implements it.
- The midi_* files.
- Rewrite the library doc in `packages/controller_repository/lib/controller_repository.dart`.

**Edit these files.**
- `ControlCubit` and `ControlState`: every old field and method listed in `research-cubit-map.md` 1a and 1b, including `flushMappings` and the tail of `_onMidiConnection` that calls `releaseAllControllerMomentary()`. Keep everything in 1d; `_applyValueTarget`, `_runAction` and `_takeLocked` are shared.
- `lib/app/run_segno.dart` and `lib/app/view/app.dart`:
  - Remove the `ControllerRepository` / `SimulatedControllerSource` construction, providers and constructor parameters.
  - Remove the PowerOff `flushMappings` block.
  - Nothing in `lib/` ever calls `ControllerRepository.dispose()`, so removing it removes no working disposal path. Keep `final midiSource = createNativeMidiSource();` in `run_segno.dart`.
  - Checked: `MidiControllerSource.activity` emits without any listener on `inputs`, so removing the repository's `inputs` subscription does not stop `messages`.
- `packages/midi_client/lib/src/midi_controller_source.dart`: only `ControllerRepository` reads the debounced `inputs` stream. Remove `implements ControllerSource`, the `debounce` parameter, `_inputs`, `_lastEmitUs`, `_triggerKey` and the debounce block; keep `activity`, `enumerate`, `open`, `close`, `pushForTest`, `dispose`. Switch `packages/midi_client/test/midi_controller_source_test.dart` from `inputs` to `activity` and delete its debounce group. Delete `controller_source.dart`.
- `packages/controller_repository/lib/src/controller_input.dart`: delete `MappingTrigger` and the `RawControllerInput.trigger`, `channelTrigger` and `isPress` getters; keep `RawControllerInput` and `ControllerSourceKind`.
- `lib/looper/bloc/looper_bloc.dart`: remove the `controller` parameter, the subscription and `_onControllerEvent`. `_toggleMetronome` and `_cancelPendingArms` have no other caller and go too. Also `lib/looper/view/looper_page.dart`.
- **Tap tempo gap.** The fixed CC scheme is today's only external path to tap tempo, the click toggle and cancel-arm. The accepted catalogue (`docs/design/pedal-action-catalogue.js`) has `command:tap-tempo` ("Tap tempo", Loop transport group); the app's `ControlAction` catalogue has no tap-tempo entry. Add a `ControlAction` for tap tempo that calls `TempoCubit.tapTempo`, so a mapping can reach it, or record the gap on #1026. The accepted catalogue has no click-toggle or cancel-arm entry; losing those two follows the design.
- `lib/control/view/control_tray_panel.dart`, the settings tray state and cubit (`controlTab`, `showControlTab`).
- `lib/control/binding/binding_labels.dart`: `controlLabel(MappingTrigger)` is dead once the old UI is gone. `valueTargetLabel` has no caller outside the removed UI either (`research-cubit-map.md` says otherwise; that line is wrong). Reuse it on the new page or delete it with `midiLearnTargetVolume`, `midiLearnTargetMaster` and `midiLearnTargetParam`.
- Package metadata: rewrite the descriptions in `packages/controller_repository/pubspec.yaml` and `packages/midi_client/pubspec.yaml` and the library docs in `controller_repository.dart`, `midi_client.dart` and `midi_device_repository.dart`; drop the now unused `fake_async` and `mocktail` dev dependencies from controller_repository. Fix the doc at `packages/pedal_repository/lib/src/pedal_protocol_traffic.dart:11`.
- `lib/audio_setup/view/audio_settings_section.dart`: stop mounting `MidiLearnSection`.
- `packages/settings_repository`: the `controller.mappings` load and save methods and their test.
- l10n: remove the keys used only by removed UI (list in `research-ui-navigation-map.md` section 5), and also the seven keys already unused there. Keep `midiLostToast*`, `midiReconnectedSnackbar`, the `pedalAssign*` keys, and any `midiStatus*` / `midiDevice*` keys the new page reuses.
- Tracked docs that describe the old model: `docs/MIDI_FOOT_CONTROLLER.md` (whole file: fixed CC 80-86 table, sweep and switch, jump-on-first-move takeover; rewrite for the new page and pickup), `docs/RUNNING_ON_RPI.md` lines 453-454, and `docs/PROGRESS.md` lines 155, 163, 168 and 756-758. There are no package READMEs. The `controller.mappings` blob on existing devices is simply never read again; no migration.

**Tests** (full list in `research-cubit-map.md` section 2).
- Delete:
  - `test/control/control_cubit_controller_test.dart`
  - `test/audio_setup/view/midi_learn_section_test.dart`
  - `test/looper/bloc/midi_looper_integration_test.dart`
  - the six old tests in `packages/controller_repository/test/`
- Edit:
  - `control_face_test.dart`: delete the "MIDI tab" group, the `showMidi` helper, and the controller and simulated-source wiring.
  - `control_center_preview_test.dart`: delete the two MIDI tests and the goldens `control_center_control_midi.png` and `control_center_control_midi_device.png`.
  - `binding_labels_test.dart`
  - `audio_settings_section_test.dart`: drop the mock `ControlCubit` and `MidiSetupCubit`.
  - `settings_tray_test.dart`, `app_test.dart`, `looper_page_test.dart`, `looper_bloc_test.dart` (the ControllerMapping cases), `settings_repository_test.dart`.

## 9. Tests to port before deleting the old ones

`control_cubit_midi_test.dart` does not yet cover these behaviours, which the old controller test did:
1. Master gain keeps the encoder accumulator in step (old test around line 225; the shared `_applyValueTarget`).
2. A stale target writes nothing and does not throw (around line 245).
3. A continuous value holds when the source disconnects (around line 270).

The old reference-counted "two momentary controls on one target" behaviour (around line 444) is deliberately not ported: the engine restores each mapping's own low value. Say so in the PR body.

## 10. Verification and shipping checklist

Commands:
- Dart tests: `/Users/Tomas/development/flutter/bin/flutter test` (a bare `flutter test` or `dart test` is hook-blocked; the very_good MCP test tool is broken). Run the root suite and each touched package: `packages/controller_repository`, `packages/settings_repository`, `packages/midi_device_repository`, `packages/midi_client`, `packages/pedal_repository` if touched.
- Static checks:
  - `dart analyze --fatal-infos` in each touched package and at the root.
  - `~/.pub-cache/bin/bloc lint lib`. In some worktree locations it checks zero files and exits 64; confirm the checked-file count.
- Native tests: `bash packages/segno_engine/src/test/run_native_tests.sh`, only if native code changes (none is planned).
- Screenshots: they run only on the author's machine, which has the fonts. Regenerate with `--update-goldens` and look at every changed PNG.
- Before opening the PR, check the semantic PR title (`feat(midi): ...`, `refactor(midi): ...`) and run cspell on changed markdown.

Tracking steps (docs/TRACKING.md):
- The PR body says `Part of #1026`.
- Labels: `stage:in-review`, `autonomy:merge-gate`, `ci:red` (the stack is red until #1011), `review:pending`.
- Run `/code-review` on the PR, fix what it finds, then set `review:clean`. `ready-to-merge` needs CI green and review clean; a human merges.
- Post a progress note on #1026 covering what shipped, the decisions from section 5, and the remaining gaps.
- Update the memory file `~/.claude/projects/-Users-Tomas-Documents-Work-opensource-loopy/memory/loopy-segno-slice4g-midi.md`.

## 11. Gotchas that have already cost time on this stack

- Widget tests: a bloc push needs two pumps (one delivers the event, the next rebuilds).
- Widget tests: an inline `await sub.cancel()` inside `testWidgets` hangs; use `unawaited` or `tearDown`.
- Widget tests: pen-sized rows overflow the 800x600 test surface; set the view size or wrap readouts in a shrink-to-width box.
- A mocked `MidiDeviceRepository` must stub `messages`, `connections`, `activity` and `connection`, or the cubit subscribes to null.
- Artwork in goldens needs `tester.runAsync(() => precacheImage(...))`; images decode off the fake clock.
- `chainEntriesAt` is an extension (`FxChainLookup`) and cannot be mocked.
- Pen coordinates: screen-local is tile minus 72, main-local is tile minus 168; `LoopSettingsFrame` children use main-local.
- Pencil does not autosave MCP edits. Saving the pen needs the File > Save menu in the Pencil app, and the computer-use tools were disconnected in the last session. Verify a pen save by comparing blob hashes; `git status` does not show it.

## 12. After part 4g

- Remaining parts of #1026: 4h Reverse, 4i Speed, 4j Fade, 4k Transpose, 4l Multiply/Divide, 4m Bounce/Peel, 4n foot Mixer and feedback.
- Then slices 5, 6 and 7 of epic #1009, in the order in `IMPLEMENTATION_PROMPT.md`.
- Open items carried forward:
  - double-tap reset and encoder editing of slider values (shared slider and encoder-focus work)
  - #1040 (single shared MIDI input)
  - the #1011 CI gate
  - the untracked `docs/design` folder (226 MB)

## 13. Research coverage

The old-model inventory finished and is `research-old-model.md`. A completeness critic over all four reports failed twice on the usage limit and was not run; nobody has cross-checked the reports against each other beyond the corrections folded into section 8. Confirm every deletion with grep before making it.
