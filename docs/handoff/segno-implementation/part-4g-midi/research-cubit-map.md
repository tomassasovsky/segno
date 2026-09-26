# ControlCubit MIDI map for the MIDI controls page PR (#1026 part 4g)

Worktree: `/private/tmp/claude-501/-Users-Tomas-Documents-Work-opensource-loopy/1a736a10-cdfb-4daa-ad93-3176a9204d1d/scratchpad/wt-4fe` (HEAD `63d8d7b5`). All paths below are relative to it.

**Confirmed bug from #1049: a device paused by Learn stays paused if it disconnects.**
- If a device disconnects or is swapped while Learn is open, `_onMidiConnection` clears `midiLearn` (`lib/control/cubit/control_cubit.dart:2509-2513`) but never calls `_midi.resume`.
- `MidiMappingEngine.connectionChanged` does not remove the device from `_paused` (`packages/controller_repository/lib/src/midi_mapping_engine.dart:148-151`, `_paused` at :98).
- `endMidiEdit` returns early once `midiLearn == null` (`control_cubit.dart:2646-2647`).
- Result: when the same device reconnects, `receive` returns nothing (`midi_mapping_engine.dart:179`). Its mappings stay dead until the next Learn on that device.
- The test `'a device going away ends Learn'` (`test/control/control_cubit_midi_test.dart:335-340`) only checks `midiLearn == null`. It never checks that dispatch works after reconnect.

---

## 1. Old controller-binding / learn / simulate paths

### 1a. `lib/control/cubit/control_cubit.dart`: old-only (remove)

| Lines | Item | What it does |
|---|---|---|
| 17 | `import …/controller_learn.dart` | Old learn model |
| 176-189 | Constructor doc for `controller` and `simulatedSource` | Rewrite; keep the `midiDevices` sentence, reworded |
| 195, 209 | `ControllerRepository? controller` → `_controller` (248) | Old binding and learn seam |
| 197, 210 | `SimulatedControllerSource? simulatedSource` → `_simulatedSource` (250-255) | #519 push seam |
| 199, 211 | `learnTimeout` → `_learnTimeout` (256) | Old learn timeout |
| 200, 212 | `mappingsWriteDebounce` → `_mappingsWriteDebounce` (257) | Debounce for `controller.mappings` writes |
| 201-202, 213-214 | `simulateTick`, `simulateSweepLeg` → fields (259-264) | Simulation pacing |
| 222, 272 | `_bindingSub = controller?.bindingEvents.listen(_onControllerBindingEvent)` | Old dispatch subscription |
| 379-399 | `_heldControllerRestore` (keyed by target string, `holders: Set<MappingTrigger>`) | Reference-counted MIDI momentary restore |
| 401-404 | `_learnTimer` | Old capture timeout |
| 406-413 | `_simulateTrigger`, `_simulateQueue`, `_simulateTimer` | Simulation state |
| 415-420 | `_learnGeneration` | Makes a superseded `learnNext` completion inert |
| 422-428 | `_mappingsWriteTimer`, `_pendingMappingsBlob` | Pending debounced blob write |
| 430-436 | `_controllerValueTargets`, `_controllerSwitchTargets` | Target strings decoded once per edit |
| 493-495 | `_restore`: `ControllerBindingSet.decode(loadControllerMappings())` | Reads `controller.mappings` |
| 516-520 | `_restore`: `_controller?.setBindings(...)`, `_cacheControllerTargets(...)` | Pushes the old set to the repository |
| 526 | `_restore` emit: `controllerBindings:` | |
| 2095-2126 | `setControllerBindings` | Cancels a relearn whose row was removed, releases stranded holds, `setBindings`, cache, emit, debounced write |
| 2128-2158 | `_releaseControllerMomentariesMissingFrom` | Releases holds the edit strands |
| 2160-2174 | `_cacheControllerTargets` | Continuous → `ControlValueTarget`; discrete → `FxBindingTarget` |
| 2176-2188 | `_scheduleMappingsWrite` | |
| 2190-2197 | `_flushMappingsWrite` → `saveControllerMappings` | |
| 2199-2201 | `flushMappings()` (public) | Called from `lib/app/view/app.dart:511` |
| 2203-2212 | `updateControllerBinding`, `removeControllerBinding` | |
| 2214-2263 | `learnControllerBinding({target, continuous, replacing})` | Releases all MIDI holds, arms the timer, emits `ControllerLearn`, `controller.learnNext()` |
| 2265-2272 | `confirmControllerLearn` | Replace confirmation (R28) |
| 2274-2285 | `cancelControllerLearn` | Bumps generation, `_controller?.cancelLearn()` |
| 2287-2294 | `_liveBinding((MappingTrigger, String)?)` | |
| 2296-2324 | `_onLearnCaptured` | Checks `isTriggerBound`, emits `withCaptured` or applies |
| 2326-2371 | `_applyLearn` | Builds a Continuous or Discrete binding and calls `setControllerBindings` |
| 2373-2394 | `_onControllerBindingEvent` | |
| 2396-2403 | `_applyControllerValue` | Looks up the cached target, then calls the shared `_applyValueTarget` |
| 2419-2472 | `_applyControllerSwitch` | Toggle/momentary through `_looper.setBindingEnabled` |
| 2474-2496 | `releaseAllControllerMomentary()` (public) | |
| 2515-2516 | Tail of `_onMidiConnection`: `if (connected) return; releaseAllControllerMomentary();` | Remove only these 2 lines; 2498-2514 is new-path code |
| 2652-2801 | Simulate section: `simulateMapping` 2656-2673, `simulateStatusRow` 2675-2695, `_sweepValues` 2697-2710, `_sweepDwell` 2715, `_switchValues` 2721, `_sweepSteps` 2726-2732, `_startSimulation` 2734-2749, `_tickSimulation` 2751-2761, `_drainSimulation` 2763-2777, `_cancelSimulation` 2779-2787, `_pushSimulated` 2789-2801 | Synthetic CC through `SimulatedControllerSource` |
| 2966-2976, 2982 | `close()`: `_learnTimer?.cancel()`, `_cancelSimulation()`, `_controller?.cancelLearn()`, `_flushMappingsWrite()`, `_bindingSub?.cancel()` | |

### 1b. `lib/control/cubit/control_state.dart`: old-only

| Lines | Item |
|---|---|
| 25-26 | Constructor: `controllerBindings`, `controllerLearn` |
| 107-120 | Fields and docs (the doc at 108 names `controller.mappings` and "MIDI-learn settings section") |
| 193-195 | `copyWith` params: `controllerBindings`, `controllerLearn`, `clearControllerLearn` |
| 212-217 | `copyWith` body for those fields |
| 236-237 | `props` entries |

The new fields survive: `midiMappings` 27/122-124, `midiControlEnabled` 28/126-127, `midiLearn` 29/129-130, `copyWith` 196-199/218-220, `props` 238-240.

### 1c. `lib/control/binding/*.dart`

| File | Status |
|---|---|
| `controller_learn.dart:1-55` | Delete. Imported only by the cubit (17). Exported from `lib/control/control.dart:36`; remove that export. |
| `midi_learn.dart:1-51` | New (#1049). **Not exported** from `lib/control/control.dart`. A page that wants to name the type must import it directly, or the barrel must add it. |
| `binding_labels.dart:108-126` `controlLabel(l10n, MappingTrigger)` | Used only by the old UI (`midi_tray_body.dart:619,682,737`, `midi_learn_section.dart:181,437`). Dead after removal. `bindingTargetLabel` (50) and `valueTargetLabel` (71) stay; they are used by the pedal tray, the assignment page and the expression catalogue. |
| `control.dart:18-23` | Library doc describes "external-MIDI mappings (part 7)"; rewrite it. |
| All other binding files | Pedal, external-pedal and expression code, unrelated to the old MIDI path. |

### 1d. Shared with surviving paths (keep)

| Lines | Item | Surviving users |
|---|---|---|
| 49-137 | `_HoldGesture`, `_Gestures` | Pedal plate and external switches |
| 204, 216, 266 | `_takeLocked` | `recPlay` 789, pedal release 1187-1194, `_applyMidi` 2559 |
| 277-278 | `_encoderStep`, `_masterGain` | Encoder 1169-1175; `_applyValueTarget` |
| 2405-2417 | `_applyValueTarget` | Expression pedal 1248, `_applyMidi` 2555. Its master-gain accumulator is covered only by the old test `control_cubit_controller_test.dart:225` (see §2). |
| 1648 | `_runAction` | Custom pedal mode, external switches, `_applyMidi` 2561 |
| 366-377 + state `heldMomentary` (105) | `_heldRestore` | Pedal remap momentaries (`FxBindingTarget`) |
| 1980-2093 | `_invalidateGestures`, `releaseAllMomentary`, `_pressBinding`, `_scoped`, `_releaseBinding` | Pedal remap only; they never touched MIDI |
| 2033, 2036 | `BindingBehavior` | Defined in `packages/controller_repository/lib/src/binding_behavior.dart`, re-exported by `lib/control/binding/pedal_binding.dart:11-12`. It must survive (or move) when `controller_binding*.dart` is deleted. |
| 2 | `dart:convert` | `_encodeExternalOn` 1463, `_decodeMidiMappings` 2574 |
| 16, 21 | `ControlValueTarget`, `FxBindingTarget` imports | New engine read 337 and `_applyMidi` 2554; pedal `_heldRestore`/`_scoped` |
| — | `RawControllerInput`, `ControllerSourceKind` (`controller_input.dart`) | `_onMidiMessage` 2523, `MidiDeviceRepository.messages` (`packages/midi_device_repository/lib/src/midi_device_repository.dart:108`), `isPedalProtocolInput` (`packages/pedal_repository/lib/src/pedal_protocol_traffic.dart:25`) |
| 196, 223-224, 273, 334-352, 2498-2514, 2519-2650 | `midiDevices`, `_midiSub`, `_midiMessageSub`, `_midi`, `_midiClock`, `_midiDevice`, all new MIDI methods | New path |

### 1e. Coupled removals outside the cubit

- **`lib/app/view/app.dart`**
  - 117-124: `controllerRepository` and `simulatedControllerSource` fields.
  - 183 `_control`: its only remaining use is 511 plus the assignment at 564.
  - 211: `RepositoryProvider.value(controllerRepository)`.
  - 495-518: the PowerOffCubit `flushMappings` block. The new path writes directly at `control_cubit.dart:2583`, so nothing needs flushing.
  - 550-561: `controller:`, `simulatedSource:`.
- **`lib/app/run_segno.dart:108-122`**: builds `SimulatedControllerSource` and `ControllerRepository(sources:, learnIgnore: isPedalProtocolInput)`.
  - **Ownership issue:** `ControllerRepository` owns and disposes the native `midiSource`. `MidiDeviceRepository` (`midi_device_repository.dart:25-27`) and the pedal repository (`native_pedal_repository.dart:62`) only borrow it. Deleting the repository requires a new owner for disposal.
- **Fixed CC scheme:**
  - `packages/controller_repository/lib/src/controller_repository.dart`: `_mapping` 84, `events` 104, `mappingChanges` 111, `bind` 254, `setMapping` 260.
  - `lib/looper/bloc/looper_bloc.dart`: 25, 767, 784, `_onControllerEvent` 1142-1163, 1237.
  - `lib/looper/view/looper_page.dart:40`.
  - Transport-map list in `midi_tray_body.dart:396-408`.
- **Settings keys:** `packages/settings_repository/lib/src/settings_repository.dart:571-589` (`controller.mappings`) is used only at `control_cubit.dart:494` and 2196. New keys: 591-612.
- **UI:**
  - `lib/control/view/midi_tray_body.dart` (whole file).
  - `lib/control/view/control_tray_panel.dart:42`.
  - `lib/control/control_tab.dart` (`ControlTab.midi`).
  - `lib/audio_setup/view/midi_learn_section.dart` (whole file), mounted by `lib/audio_setup/view/audio_settings_section.dart:111-113`.

---

## 2. Tests

### Delete whole file

| File | Tests |
|---|---|
| `test/control/control_cubit_controller_test.dart` (1104 lines) | Group `'ControlCubit external MIDI'` (57).<br>**continuous bindings:** 208 `a CC sweep writes the mapped value into the rig`; 225 `master gain keeps the encoder accumulator in step`; 245 `a stale target writes nothing and does not throw`; 270 `a value HOLDS when the MIDI source disconnects`.<br>**discrete bindings:** 291 `a toggle CC flips the chain on the ON edge only`; 308 `a momentary CC enables on press and restores on release`; 327 `MIDI disconnect releases a held momentary (B1)`; 350 `a still-connected status leaves a held momentary alone`; 370 `an unrelated edit leaves a held momentary alone`; 405 `turning a held momentary into a toggle releases it`; 427 `editing the mappings releases a held momentary (B1)`; 444 `two momentary controls on one target hold independently`; 478 `a repeated press does not re-capture the state it enabled`.<br>**persistence:** 507 `an edit writes the global blob and reaches the repository`; 526 `a burst of edits coalesces into one write`; 563 `close() flushes an edit the debounce was still holding`; 591 `flushMappings commits an edit the debounce was still holding`; 624 `load() restores the blob into state and the repository`.<br>**learn:** 645 `a captured control binds, with the channel it arrived on`; 662 `a discrete learn binds the switch shape`; 677 `an already-mapped control waits for the replace confirmation`; 709 `keeping the old mapping cancels the capture`; 727 `a relearn keeps the row ranges and drops the old control`; 755 `a capture nobody feeds times out and stops swallowing input`; 777 `starting a capture releases a held momentary (B1)`; 799 `close() ends a capture instead of leaving the stream swallowed`; 815 `relearning a row its OWN control asks nothing, even after an edit`; 850 `removing the row a capture is relearning ends the capture`; 877 `cancelling a capture leaves the mappings untouched`.<br>**simulate input (#519):** 894 `a sweep row moves its target through the range and back`; 918 `a switch row flips a toggle once`; 934 `a switch row holds a momentary, then lets it go`; 952 `the global button feeds a listening learn capture`; 966 `the global button routes to the open row when not learning`; 985 `the global button is inert with no learn and no open row`; 996 `a new simulation drains the previous — no stranded momentary`; 1059 `close() stops the simulation ticker`. |
| `test/audio_setup/view/midi_learn_section_test.dart` | Group `MidiLearnSection` (195): 196, 205, 225, 240, 271, 285, 308, 325, 347, 373, 408, 431, 449, 470 (all 14) |
| `test/looper/bloc/midi_looper_integration_test.dart` | Fixed ControllerMapping to LooperBloc |
| `packages/controller_repository/test/`: `controller_binding_set_test.dart`, `controller_binding_test.dart`, `controller_bindings_dispatch_test.dart`, `controller_mapping_test.dart`, `simulated_controller_source_test.dart`, `controller_repository_test.dart` | Old model and repository |

**Port before deleting.** The new `control_cubit_midi_test.dart` does not cover these:
- 225 master-gain accumulator: the shared `_applyValueTarget` 2412-2417 has no other MIDI test. Expression tests at `control_cubit_test.dart:4054-4075` check `setMasterGain` but not the encoder follow-up.
- 245 stale target: the engine skips a null read (`midi_mapping_engine.dart:246-247`); there is no cubit test.
- 270 a continuous value holds across disconnect: engine `_release` writes only momentary values (304-307).

Behaviour change, not a port: 444 used reference-counted holders. The new engine restores each mapping's own `low` independently.

### Edit

| File | Change |
|---|---|
| `test/control/control_face_test.dart` | Remove group `'MIDI tab'` 464-1042: 492, 517, 547, 568, 604, 617 `states the fixed transport map…`, 636, 672, 693, 716, 767, 809, 830, 855, 870, 903, 939, 963, 992. Remove the `showMidi` helper 205-208, the `source`/`simulated` fields 67-68, and the `ControllerRepository`/`SimulatedControllerSource`/`simulateTick`/`simulateSweepLeg` wiring 141-160. Edit or delete `'the tab strip swaps the body'` 211-221 (asserts `midi_tray_body`). Keep `'Pedal tab'` 231-462. |
| `test/screenshots/control_center_preview_test.dart` | Delete 897 `control domain, midi tab on a live link` and 946 `control domain, midi device chooser open`. Delete goldens `test/screenshots/goldens/control_center_control_midi.png` and `control_center_control_midi_device.png`. |
| `test/control/binding/binding_labels_test.dart` | Delete group `controlLabel` 202-240 (tests 203, 228) if `controlLabel` goes. |
| `test/audio_setup/view/audio_settings_section_test.dart` | Mounts `AudioSettingsSection` (147) with `_MockControlCubit` (25, 37-39) for the MIDI-learn section; drop that dependency. |
| `test/looper/view/settings_tray_test.dart:157-163` | Drop `ControllerRepository` and the `controller:` param. |
| `test/app/view/app_test.dart` | 188, 209, 222, 234, 254, 374, 415, 450, 574, 656: `controllerRepository` param. |
| `test/looper/view/looper_page_test.dart:33` | `ControllerRepository` |
| `test/looper/bloc/looper_bloc_test.dart:2640-2852` | ControllerMapping/LooperAction cases |
| `packages/settings_repository/test/settings_repository_test.dart:881-889` | `controller.mappings` round-trip |

`test/control/control_cubit_test.dart` (4186 lines) has no old-path references; no change needed.

---

## 3. New MIDI engine wiring (#1049)

### Construction and inputs
- `_midi = MidiMappingEngine(clock, read: ControlValueTarget.tryParse → _looper.readValueTarget, step: (_) => 0.01)` at `control_cubit.dart:334-343`. The step is one fixed value for every parameter (342).
- Subscriptions:
  - `midiDevices?.connections.listen(_onMidiConnection)` (223). The stream yields the current connection first (`midi_device_repository.dart:90-93`).
  - `midiDevices?.messages.listen(_onMidiMessage)` (224). This is the undebounced `_source.activity` (`midi_device_repository.dart:108-109`), the same stream the pedal decodes (`native_pedal_repository.dart:62`).
- `_restore` (506-512, 527-528): `_decodeMidiMappings(loadMidiMappings())` (2571-2578; a `FormatException` yields an empty set), `loadMidiControlEnabled`, then `_applyMidi(_midi.setMappings)`, `_applyMidi(_midi.setControlEnabled)`, emit.

### How the open device id is known
- `_midiDevice` (350) is set only in `_onMidiConnection`: `connection.selectedId` when `status == connected`, else `null` (2499-2501).
- It is **not in `ControlState`**. It is visible only as `midiLearn.device` while Learn is open.
- The page must read the device from `MidiSetupCubit.state.connection` (`lib/audio_setup/cubit/midi_setup_cubit.dart:18-56`, provided eagerly at `app.dart:489-494`).

### Connection change: `_onMidiConnection` (2498-2514)
- If the device changed: `_applyMidi(_midi.connectionChanged(previous))` and `connectionChanged(device)`. Each resets the decoder and releases that device's mappings (`midi_mapping_engine.dart:148-151, 292-309`).
- Then `_midiDevice = device`.
- If `midiLearn.device != device`, emit `clearMidiLearn`. **No resume** (the bug above).

### Message path: `_onMidiMessage` (2523-2547)
- No open device: dropped.
- Learn open on that device:
  - If already captured (`!isListening`): return. Every later message is dropped (2528).
  - `isPedalProtocolInput` messages are dropped (2531).
  - `reading = _midi.learn(device, msg, learn.protocol)` (engine 158-171; ignores Note value 0 and relative delta 0).
  - `conflict = state.midiMappings.conflictWith(reading.source, exceptId: learn.editingId)`.
  - Emit `learn.captured(reading, conflictId:)`.
- Otherwise: `_applyMidi(_midi.receive(device, msg))`. `receive` is gated by `_controlEnabled`, `_paused` and `mapping.source.device == device` (engine 178-195).

### `_applyMidi` (2550-2569)
- `MidiParameterWrite` → `ControlValueTarget.tryParse` → `_applyValueTarget`.
- `MidiActionRun` → skipped if `_takeLocked()`, else `ControlAction.tryParse` → `_runAction`.
- `MidiActionEnd` → no-op.

### Public methods

| Signature | Lines | Engine calls | State and persistence |
|---|---|---|---|
| `Future<void> saveMidiMapping(MidiMapping mapping)` | 2593-2598 | `setMappings` through `_persistMidiMappings` (2580-2584) releases gone, disabled or changed mappings (engine 112-121) | Returns silently if `mapping.problem != null` or `conflictWith(source, exceptId: id) != null`. Otherwise emits `midiMappings`, then `saveMidiMappings(jsonEncode)`. Does **not** end Learn or resume. |
| `Future<void> deleteMidiMapping(String id)` | 2601-2604 | `setMappings` | No-op for an unknown id |
| `Future<void> setMidiMappingEnabled(String id, {required bool enabled})` | 2607-2613 | `setMappings` (disabled → released) | No-op if unknown or unchanged |
| `Future<void> setMidiControlEnabled({required bool enabled})` | 2617-2622 | `setControlEnabled` (off releases all, engine 125-130) | Emit, then `saveMidiControlEnabled`. Learn still captures while Control is off; the learn branch runs before `receive`. |
| `void startMidiLearn(MidiProtocol protocol, {String? editingId})` | 2629-2642 | `_applyMidi(_midi.pause(device))`: adds to `_paused`, resets the decoder, releases all mappings on the device (engine 134-138) | Silent no-op if `_midiDevice == null` (no emit, no result). Emits a fresh `MidiLearn(device, protocol, editingId)` with `reading: null`. |
| `void endMidiEdit()` | 2645-2650 | `_midi.resume(learn.device)` (return value is void; engine 141-144) | No-op when `midiLearn == null`. Emits `clearMidiLearn`. |

### `MidiLearn` lifecycle (`lib/control/binding/midi_learn.dart`)
- Fields: `device` (18), `protocol` (22), `editingId` (26), `reading: MidiControlEvent?` (29), `conflictId` (34); `isListening => reading == null` (37); `captured()` (40-47) keeps `editingId`.
- Order: `startMidiLearn` → listening → first learnable reading → captured, with `conflictId` when overlapping. Later messages are ignored. Ends by `endMidiEdit`, or by device change (cleared without resume).
- No timeout. The old path had `_learnTimeout` 15 s (199, 2241).

### How conflicts are reported
- During Learn: `MidiLearn.conflictId`. It counts disabled mappings (`midi_mapping.dart:330-341`).
- On save: silent refusal (2595-2596) with no return value. `MidiMappingSet.withMapping` would throw `ArgumentError` (`midi_mapping.dart:348-354`), but the cubit checks first, so it never throws.
- Draft edits made without Learn (channel set to All, number, protocol): the page must call `state.midiMappings.conflictWith(draft.source, exceptId: draft.id)` itself (pure model).

### Model API the page edits
- **`MidiSource`** (`packages/controller_repository/lib/src/midi_protocol.dart:43-210`)
  - Fields: `device` (82), `kind` (87), `number` (91), `channel` (94; `null` means All), `protocol` (97), `parameter` (100; NRPN only), `bank` (103; bankProgram only).
  - `maxWord` 106, `isValid` 109-135, `sameAs` 139-148, `overlaps` 157-162, `footprint` 165-172, `toJson`/`fromJson` 57-80, 179-187.
  - **No `copyWith`**; the editor has to rebuild the object to change the channel.
- **`MidiControlEvent`** (213-238): `source` (with the channel it arrived on), `value`, `maximum` (127 or 16383), `delta`.
- **`MidiProtocol`** (10-33): `standard`, `cc14`, `nrpn`, `bankProgram`, `relative`.
- **`midi_mapping.dart`**
  - `MidiBehavior` 6-28: `continuous`, `momentary`, `toggle`, `trigger`.
  - `MidiEdge` 31-45.
  - `MidiControl` sealed 52-86: `MidiParameterControl{key, low, high}` + `copyWith` 93-125; `MidiActionControl{key, trigger}` 128-144.
  - `MidiMappingProblem` 147-166.
  - `MidiMapping{id, source, behavior, controls, enabled}` 169-288.
  - `static MidiBehavior defaultBehavior(MidiSource source, {bool drivesActions = false})` 224-238.
  - `MidiMappingProblem? get problem` 241-261; `copyWith` 264-275 (id is fixed).
  - `MidiMappingSet`: `byId` 323, `conflictWith(MidiSource, {String? exceptId})` 335, `withMapping` 348, `withoutMapping` 366; `fromJson` drops invalid or overlapping entries 297-317.

---

## 4. How ControlCubit reaches the widget tree

### Providers
- `app.dart:542-568`: `BlocProvider(lazy: false)` inside `MultiBlocProvider`. Arguments: `looper`, `pedal`, `settings`, `performance`, `controller`, `midiDevices: context.read<MidiDeviceRepository>()`, `simulatedSource`, `takeLocked: () => context.read<PowerOffCubit>().state.isUiUp`. Then `_control = cubit` and `unawaited(cubit.load())`.
- Repositories come from `MultiRepositoryProvider` at `app.dart:208-224`: `MidiDeviceRepository` at 212, `ControllerRepository` at 211.
- `MidiSetupCubit` is at `app.dart:489-494`.

### Routes
- `lib/app/segno_navigator.dart`: `openPedalSetup` 98-115, `openExternalPedals` 117-137 (`desktopPageRoute`, module-level duplicate guards 36-40, `resetSegnoNavigatorForTest` 168-177).
- A MIDI controls page route would follow the same pattern.

### How existing pages read ControlCubit
- **`lib/looper/view/settings_page.dart`**: `context.watch<ControlCubit>().state.defaultMode` (160); `context.read<ControlCubit>().setDefaultMode` (191).
- **`lib/control/view/pedal_setup/pedal_setup_page.dart`**: widget-local draft `PedalSetup? _draft` (62); `context.watch<ControlCubit>()` with `_draft ?? state.pedalSetup` (93-94); dirty when `_draft != null` (157); Save → `control.setPedalSetup(setup)`, then `_draft = null` (218-221). Live readout comes straight from a repository: `context.read<PedalRepository>().lastFrame` (118).
- **`lib/control/view/pedal_setup/external_pedal_page.dart`**: `_draft` (85); cubit cached in `ControlCubit? _control` (112-114) so `dispose()` can call `_control?.setCalibrating(null)` (156-160). This is the precedent for calling `endMidiEdit` on dispose. `setCalibrating(jack)` pauses expression dispatch (`control_cubit.dart:1233, 1255-1261`; calls at 467/476/489). Live position from `context.read<PedalRepository>().expressionPositions` (310). Save at 645-650.
- **`lib/control/view/midi_tray_body.dart`** (old): `context.select<MidiSetupCubit, MidiConnection>` (145); `buildWhen` on `controllerLearn`/`controllerBindings` (163-164); `cubit.select(id)` (262).

---

## Gap list for the settings page editor

| # | Gap | Evidence |
|---|---|---|
| G0 | **Bug:** a device paused by Learn stays paused after a disconnect or swap. | See top of report. Fix: call `_midi.resume(learn.device)` before clearing Learn at 2511-2512, or have `connectionChanged` drop the device from `_paused`. Add a reconnect-dispatch assertion to the test at 335-340. |
| (a) | No way to pause a device while editing without Learn. Pausing happens only in `startMidiLearn`, which also requires an open device (2630-2632). `endMidiEdit` resumes only through `midiLearn` (2646-2648). The engine's `pause(String device)` accepts any id (engine 134). Design: "Learn and editing pause dispatch from the controller being configured. Entering an edit releases its active momentary parameter changes." | `docs/design/2026-09-07-midi-controls-ux.md:43-44` (main checkout) |
| (b) | No editing-session concept. There is no state for "editor open for mapping X / new on device D" separate from Learn, no draft in the cubit, and `editingId` exists only inside `MidiLearn`. Cancel and Save are separate calls (`endMidiEdit`, `saveMidiMapping`); Save neither ends the session nor reports refusal. Following the pedal-page pattern, the draft stays widget-local; the cubit needs begin/end-edit with a pause keyed by `source.device`. | 2593-2650; `midi_learn.dart:24-26` |
| (b2) | Failed save is not expressible. `saveMidiMapping` returns `Future<void>` on both refusal paths (2595-2596). `_persistMidiMappings` emits and updates the engine **before** awaiting the settings write (2581-2583), so a thrown write leaves state ≠ disk. Design: "A failed save preserves the draft and the previous saved mapping." | design doc :17-18 |
| (b3) | No mapping id generator. `MidiMapping.id` is required (`midi_mapping.dart:171-172`); no uuid dependency or id helper in `lib` or the pubspecs. | |
| (c) | No live value readout. `MidiLearn.reading` holds only the **first** captured reading (value, maximum, delta, arrival channel). After capture every message is dropped (2528). While editing without Learn nothing is recorded. Options: a live last-reading field fed through the decoder in the draft's protocol, or the page subscribing to `MidiDeviceRepository.messages` (precedent: `PedalRepository.expressionPositions`), which carries raw bytes, not decoded 14-bit/NRPN values. `MidiDeviceRepository.activity` is `Stream<void>` (97-98). | 2523-2545; `midi_protocol.dart:213-238` |
| (d) | Device list for cards is minimal and single-device. `MidiConnection` (`packages/midi_device_repository/lib/src/models/midi_connection.dart:44-121`) has currently enumerated `devices`, one pinned `selectedId`/`selectedName` (kept while gone), `status`, `connectivity`. `MidiDevice` has only `id`, `name`, `isDefault` (`packages/midi_client/lib/src/midi_device.dart:11-27`): no USB/DIN transport and no per-device connected state. Known but disconnected devices (other than the pin) are not remembered; mapping sources store a device id with no name. Only **one** input is open at a time (`midi_controller_source.dart:70-73`), and it is shared with the Segno pedal (`native_pedal_repository.dart:62`; auto-bind `midi_device_repository.dart:291-320`), so selecting an external controller replaces the pedal's input. On ALSA the id is the client name (`packages/segno_engine/src/midi/midi_backend_linux.c:11,82`): stable across replug, but two identical controllers collide. Design wants "distinguishes USB and DIN and keeps disconnected devices visible". | design doc :20 |
| (e1) | Restarting Learn works by calling `startMidiLearn` again: pause resets the decoder, `reading` goes null. But `editingId` is lost unless passed again (2637-2638). | |
| (e2) | Changing the format mid-Learn works the same way: `startMidiLearn(newProtocol, editingId:)`. Half-received pairs are discarded (engine 135-136). No dedicated API. | |
| (e3) | Cancelling Learn while keeping the editor open (device still paused) cannot be expressed: `endMidiEdit` both clears Learn and resumes (2645-2650). | |
| (e4) | No Learn timeout (the old path had 15 s at 199/2241). The design's verification list includes "Learn filtering and timeout". | design doc :72 |
| (e5) | "Edit existing mapping" after a conflict: state carries only `conflictId`. Switching the session to that mapping needs the begin-edit API from (a)/(b). | `midi_learn.dart:31-34` |
| G6 | `startMidiLearn` with no device is a silent no-op (2631). The page must gate Learn on `MidiSetupCubit.state.connection.status == connected`. | |
| G7 | `close()` (2963-2986) does not release engine holds. Whether a Held momentary value gets persisted is not verified here. Design: "Temporary held values are stored as Released". | design doc :49-50 |
| G8 | `MidiLearn` is not exported from `lib/control/control.dart` (only `controller_learn.dart` at 36). | |
| G9 | Relative step is hard-coded to `0.01` for every parameter (342). | |
| G10 | Ownership of the native MIDI source moves when `ControllerRepository` is removed (`run_segno.dart:113-122`; `midi_device_repository.dart:25-27, 331-340`). | |