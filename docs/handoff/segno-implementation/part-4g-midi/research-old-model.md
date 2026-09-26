# Old controller model: removal inventory for #1026 part 4g (MIDI controls page PR)

Worktree root: `/private/tmp/claude-501/-Users-Tomas-Documents-Work-opensource-loopy/1a736a10-cdfb-4daa-ad93-3176a9204d1d/scratchpad/wt-4fe` (HEAD `63d8d7b5`). Paths below are relative to it. `integration_test/` and `test_driver/` have no references to any symbol listed here.

## 0. Findings that change the plan

- **`ControllerRepository` has no job left once the old model goes.** Delete it; do not keep a smaller version (§2).
- **Only `ControllerRepository` reads `MidiControllerSource.inputs`, the debounced stream.**
  - The pedal reads `activity` (`packages/pedal_repository/lib/src/native_pedal_repository.dart:62`).
  - The new MIDI path reads `activity` through `MidiDeviceRepository.messages` (`packages/midi_device_repository/lib/src/midi_device_repository.dart:108-109`).
  - So `inputs`, `debounce` and `implements ControllerSource` are dead too (§4).
- **Nothing in the app ever calls `ControllerRepository.dispose()`.** There is no call anywhere in `lib/`, so the native source is never disposed today either. Removing the repository takes away no working disposal path.
- **`LooperBloc._toggleMetronome` (1183-1188) and `_cancelPendingArms` (1216-1220) become dead.** Their only callers are `_onControllerEvent` at 1161 and 1163.
  - The shared action catalogue (`lib/control/binding/control_action.dart`) has no tap-tempo, click-toggle or cancel-arm entry.
  - After removal, those three functions cannot be reached from any external control. Tap tempo stays in `TempoCubit.tapTempo` (`lib/looper/cubit/tempo_cubit.dart:307`); click mode stays in `TempoCubit.setClickMode` (270).
- **`midi_tray_body.dart` holds the only MIDI device chooser and connection status in `lib/`.**
  - Device card at 197-272, status card at 276-386.
  - Nothing else calls `MidiSetupCubit.select`; `AudioSettingsSection` has no picker (`lib/audio_setup/view/audio_settings_section.dart:104-107`).
  - Removing the file removes device selection unless the new page carries it.
- **Correction to `docs/handoff/segno-implementation/part-4g-midi/research-cubit-map.md:76`.** It says `valueTargetLabel` is used by the pedal tray, the assignment page and the expression catalogue. It is not:
  - Its only `lib/` callers are `midi_learn_section.dart:121,292` and `midi_tray_body.dart:562,940`.
  - `expression_catalogue.dart:156` calls `fxParamName`, not `valueTargetLabel`.
  - After removal it is unused unless the new page calls it.

## 1. Symbol classification

### `packages/controller_repository/lib/src/binding_behavior.dart`

| Symbol | References outside the file | Class | Why |
|---|---|---|---|
| `BindingBehavior` {`toggle`, `momentary`, `fromName`} | **Kept users:** `lib/control/binding/pedal_binding.dart:7,11-12,125,141,144,160,169,181,183,196,213,234,237`; `lib/pedal/view/pedal_assignment_page.dart:355,440,444,449`; `lib/control/cubit/control_cubit.dart:2033,2036` (`_pressBinding`, pedal). **Removed users:** `control_cubit.dart:2142,2422,2439,2445`; `midi_tray_body.dart:846,851,855`; `midi_learn_section.dart:388,392,397`; `controller_binding.dart:48,83,153,175,198,212`; `controller_binding_event.dart:1,50,62`. **Tests kept:** `test/control/binding/pedal_binding_set_test.dart:116` (covers the `fromName` fallback), `pedal_binding_hold_test.dart`, `test/control/control_cubit_test.dart`, `test/pedal/view/pedal_assignment_page_test.dart` | **KEEP, reshape the doc** | The pedal footswitch remap needs it. Doc at 3-12 describes "a discrete on/off MIDI CC (part 7)" and "a binding is persisted here"; both go away. After removal no package uses it (pedal_repository does not), so moving it into `lib/control/binding/pedal_binding.dart` is also possible. The re-export doc at `pedal_binding.dart:7-10` needs rewriting either way. Separate type: `MidiBehavior` in `midi_mapping.dart:6`. |

### `controller_binding.dart` — DELETE the whole file

| Symbol | References | Why |
|---|---|---|
| `ControllerBinding` (`fromJson`, `trigger`, `target`, `key`, `toJson`), `ContinuousBinding` (`lo`, `hi`, `valueFor`, `copyWith`), `DiscreteBinding` (`defaultThreshold`, `minThreshold`, `hysteresis`, `threshold`, `behavior`, `isOn`, `copyWith`) | `control_cubit.dart:2141,2166,2169,2206-2207,2211,2230,2249-2250,2289,2344-2359,2657,2666-2670`; `midi_tray_body.dart:649,685-686,768,808,813,821,905,933-963`; `midi_learn_section.dart:158,271-272,286-306,349,367`; `controller_binding_set.dart`; `controller_binding_event.dart:2`; `controller_repository.dart:22-23,152-188`. Tests: `test/control/control_cubit_controller_test.dart`, `test/control/control_face_test.dart:473-490,576-1017`, `test/audio_setup/view/midi_learn_section_test.dart`, `test/screenshots/control_center_preview_test.dart:917,925`, package tests `controller_binding_test.dart`, `controller_binding_set_test.dart`, `controller_bindings_dispatch_test.dart`, `simulated_controller_source_test.dart` | Replaced by `MidiMapping` / `MidiControl` (#1048). |

### `controller_binding_event.dart` — DELETE the whole file

| Symbol | References | Why |
|---|---|---|
| `ControllerBindingEvent`, `ControllerValueEvent`, `ControllerSwitchEvent` | `control_cubit.dart:272,2382-2392`; `controller_repository.dart:74-75,108,194-201,233`; `controller_bindings_dispatch_test.dart`; `simulated_controller_source_test.dart` | Replaced by `MidiOutput` (`MidiParameterWrite` / `MidiActionRun` / `MidiActionEnd`), applied at `control_cubit.dart:2550-2569`. |

### `controller_binding_set.dart` — DELETE the whole file

| Symbol | References | Why |
|---|---|---|
| `ControllerBindingSet` (`decode`, `empty`, `bindings`, `isEmpty`, `isNotEmpty`, `length`, `matching`, `isTriggerBound`, `withBinding`, `replace`, `without`, `withoutTrigger`, `encode`) | `control_cubit.dart:493,2107-2125,2137,2161,2208,2212,2291,2315,2361-2367`; `control_state.dart:25,115,193,212,236`; `controller_repository.dart:55,85,117,273`. Tests: `control_cubit_controller_test.dart:205`, `control_face_test.dart:473`, `midi_learn_section_test.dart:147`, `control_center_preview_test.dart:915-916`, `controller_binding_set_test.dart` | Replaced by `MidiMappingSet`, stored under the `midi.mappings` key. |

### `controller_event.dart` — DELETE the whole file

| Symbol | References | Why |
|---|---|---|
| `ControllerEvent` | `lib/looper/bloc/looper_bloc.dart:784,1142`; `controller_mapping.dart:92`; `controller_repository.dart:70,104,145`; package `controller_mapping_test.dart`, `controller_repository_test.dart` | Only the fixed CC→`LooperAction` scheme produces it. |

### `controller_input.dart` — RESHAPE

| Symbol | References that remain | Class | Why |
|---|---|---|---|
| `ControllerSourceKind` {`midiNote`, `midiCc`, `midiProgram`, `fromName`} | `midi_protocol.dart:59` (`fromName`); `midi_mapping.dart`; `midi_mapping_engine.dart`; `packages/midi_client/lib/src/midi_controller_source.dart:109,116,123,130`; `packages/pedal_repository/lib/src/pedal_protocol_traffic.dart:29-35`; `native_pedal_repository.dart:64,72,74`; tests `control_cubit_midi_test.dart`, `midi_protocol_test.dart`, `midi_mapping_engine_test.dart`, pedal_repository tests, midi_client tests, midi_device_repository tests. To remove: `control_cubit.dart:2686` (simulate), `binding_labels.dart:117-122` (`controlLabel`) | **KEEP** | Used by the MIDI source, the decoder and the pedal protocol filter. Doc at 11-15 ("The 7-bit bindings… the repository does not learn or dispatch one") describes the old model; rewrite it. |
| `MappingTrigger` (`fromJson`, `kind`, `id`, `midiChannel`, `matches`, `toJson`) | `binding_labels.dart:110`; `controller_learn.dart:34,40,46`; `control_cubit.dart:398,411,2139,2289,2328,2421,2678,2734,2789`; `midi_tray_body.dart:59,91,98`; `controller_binding*.dart`; `controller_mapping.dart`; `controller_repository.dart:91-98,230`. Tests: `binding_labels_test.dart:202-237`, `looper_bloc_test.dart:2660-2668`, `control_face_test.dart`, `control_center_preview_test.dart:918,926`, `midi_learn_section_test.dart`, `control_cubit_controller_test.dart`, package tests | **DELETE** (lines 27-96) | Nothing in `midi_*.dart` uses it; `MidiSource` replaces it. |
| `RawControllerInput` (`kind`, `id`, `value`, `midiChannel`, `props`, `toString`) | `control_cubit.dart:352,2523`; `midi_device_repository.dart:108-109`; `midi_controller_source.dart:44-47,104-134`; `pedal_protocol_traffic.dart:25`; `native_pedal_repository.dart`; `midi_protocol.dart`; `midi_mapping_engine.dart`; tests | **KEEP** | This is the message type the new path and the pedal protocol use. |
| `RawControllerInput.trigger` (123-125), `.channelTrigger` (127-130), `.isPress` (132-133) | `control_cubit.dart:2311` (old learn); `controller_mapping.dart:87`; `controller_repository.dart:138`; `packages/midi_client/test/midi_controller_source_test.dart:50,101,132-133`; `controller_binding_test.dart:73`; `controller_bindings_dispatch_test.dart:287-288` | **DELETE** these members | They return `MappingTrigger` or serve only press-only resolve and learn. Update the midi_client test lines. |

### `controller_mapping.dart` — DELETE the whole file

| Symbol | References | Why |
|---|---|---|
| `MappingEntry`, `ControllerMapping` (`name`, `entries`, `defaults` = CC 80-86, `resolve`, `merge`, `withBinding`) | `controller_repository.dart:54,60,72-73,84,111,114,144,254-263`; `midi_tray_body.dart:408-411`; `looper_bloc_test.dart:2656-2672`; `control_face_test.dart:624`; package `controller_mapping_test.dart`, `controller_repository_test.dart` | The accepted design has no reserved CC scheme (`docs/handoff/segno-implementation/part-4g-midi/research-pen-spec.md:318`). The Segno pedal firmware does not send CC 80-86: its protocol is notes plus `encoderCc = 0x10` (`packages/pedal_repository/lib/src/pedal_codec.dart:148`). |

### `controller_repository.dart` — DELETE the whole file (§2)

### `controller_source.dart` — DELETE the whole file

| Symbol | References | Why |
|---|---|---|
| `ControllerSource` (`inputs`, `dispose`) | `midi_controller_source.dart:10,23` (`implements`); `simulated_controller_source.dart:21`; `controller_repository.dart:53,68`; test fakes `test/looper/bloc/looper_bloc_test.dart:20-29`, `test/audio_setup/view/midi_learn_section_test.dart:31`, `test/control/control_face_test.dart:32-47`, `test/control/control_cubit_controller_test.dart:21`, `packages/controller_repository/test/helpers/fake_controller_source.dart:6`; doc `packages/midi_client/lib/midi_client.dart:5` | Its only consumer is `ControllerRepository`. |

### `looper_action.dart` — DELETE the whole file

| Symbol | References | Why |
|---|---|---|
| `LooperAction` (10 values, `isChannelScoped`) | `looper_bloc.dart:1143-1163`; `controller_event.dart:13`; `controller_mapping.dart`; `midi_tray_body.dart:396-406`; `looper_bloc_test.dart:2661-2669`; package `controller_mapping_test.dart:5-19`, `controller_repository_test.dart` | Only the fixed scheme uses it. `ControlAction` is the shared catalogue. |

### `simulated_controller_source.dart` — DELETE the whole file (§3)

## 2. `ControllerRepository`

**Construction**
- `lib/app/run_segno.dart:107-122`: `ControllerRepository(sources: [?midiSource, simulatedControllerSource], learnIgnore: isPedalProtocolInput)`, passed on at 195-196.
- `lib/app/view/app.dart`:
  - Parameters and field: 61, 117-118.
  - `RepositoryProvider` at 211.
  - Read at 559 for `ControlCubit`.
- `lib/looper/view/looper_page.dart:40`: read for the page `LooperBloc`.
- The app-wide `LooperBloc` gets no controller (`app.dart:272-280`).

**What each part of the API is used for**

| API | Consumer | After removal |
|---|---|---|
| `events` (104) | `looper_bloc.dart:767` → `_onControllerEvent` 1142-1165 | Gone with the fixed scheme |
| `bindingEvents` (108) | `control_cubit.dart:222` → `_onControllerBindingEvent` 2382 | Gone; replaced by `_applyMidi` |
| `learnNext` / `cancelLearn` (240-251) | `control_cubit.dart:2259,2282,2973` | Gone; `MidiLearn` goes through `_midi.learn` (2532) |
| `setBindings` (273) | `control_cubit.dart:519,2122` | Gone |
| `mappingChanges`, `mapping`, `bindings`, `isLearning`, `bind`, `setMapping`, `smoothing`, `smoothingTick` | No `lib/` consumer; package tests only | Gone |
| `learnIgnore` filter (56,133) | Pedal traffic filter | The new path already calls `isPedalProtocolInput` directly (`control_cubit.dart:2531`) |
| `dispose` → `source.dispose()` (283-297) | No `lib/` caller | Nothing to replace |

**Sources**
- `MidiControllerSource` (`packages/midi_device_repository/lib/src/native_midi_source.dart:16`) and `SimulatedControllerSource`.
- `implements ControllerSource` exists only on those two plus test fakes.
- No GPIO source: GPIO was dropped (`docs/PROGRESS.md:770-772`).
- The keyboard and on-screen widgets call the bloc and cubit directly.
- The Segno pedal reads `midiSource.activity` (`native_pedal_repository.dart:62`), never this repository.

**Who can fire `LooperBloc._onControllerEvent`**
- Only `ControllerMapping.resolve` in `_onInput` (144-145).
- The input comes from a third-party MIDI controller sending CC 80-86, or from a simulated push.
- Nothing outside MIDI produces these events.

**Recommendation: delete the class.** Resulting changes:
- `lib/looper/bloc/looper_bloc.dart`:
  - Remove: import 4; doc 13-22; parameter 25; 767; 784; 1142-1165; dead helpers 1167-1220; 1237.
  - Reword the comment at 972 that points to `[_cancelPendingArms]`.
- `lib/looper/view/looper_page.dart`: import 1, 40.
- `lib/app/run_segno.dart`: import 6; 103-122 (keep `final midiSource = createNativeMidiSource();` at 107); comment 156-159 ("owned by the controller pipeline"); 196.
- `lib/app/view/app.dart`:
  - Remove: import 7; 61; 68; 117-124; 211; the 495-496 comment and the 510-518 `flushMappings` try block; the `_control` field 183 and its assignment 564 (no reader left); 550-561 (`controller:`, `simulatedSource:` and the comment).
  - Edit comments: 126-128 ("borrows … from [controllerRepository]") and 272-274.
- `test/looper/bloc/looper_bloc_test.dart`: `_FakeControllerSource` 20-29; group `'controller wiring'` 2628-2861; import 4.
- `test/looper/bloc/midi_looper_integration_test.dart`: delete (104 lines; source → default mapping → `LooperBloc`).
- `test/looper/view/looper_page_test.dart`: 33, 57, plus the provider.
- `test/looper/view/settings_tray_test.dart`: 133, 157, 163.
- `test/app/view/app_test.dart`: 188, 209, 222, 234, 254, 374, 415, 450, 574, 656, 790, 1008, 1353. Keep the `_MockMidiSource` at 182/634/637.
- `packages/controller_repository/test/`: delete `controller_repository_test.dart`, `controller_bindings_dispatch_test.dart`, `controller_mapping_test.dart`, `controller_binding_test.dart`, `controller_binding_set_test.dart`, `simulated_controller_source_test.dart`, `helpers/fake_controller_source.dart`. Keep `midi_mapping_engine_test.dart` and `midi_protocol_test.dart`; neither imports fake_async, mocktail or the helper.

## 3. `SimulatedControllerSource`

**What it does:** a broadcast `StreamController<RawControllerInput>` with a `push` method (`simulated_controller_source.dart:21-38`). `ControlCubit` paces what gets pushed:
- Sweep: CC 0→127, a 2-tick dwell, then 127→0 (`_sweepValues` 2702-2710).
- Switch: `[127,127,127,0]` (2721).
- Global button while a learn is listening: pushes CC 1 = 127 (2684-2690).

**Where it appears:**
- The status card's `midi_simulate_global` chip (`midi_tray_body.dart:371-380`), gated by `canSimulate` (290-306).
- The per-row `midi_simulate` pill (`midi_tray_body.dart:882-892`).
- `midi_learn_section.dart` has no simulate control.

**Users outside the old MIDI tray:** none.
- Cubit methods `simulateMapping` / `simulateStatusRow` are called only from `midi_tray_body.dart:376,891`.
- Construction and wiring: `run_segno.dart:113,115,196`, `app.dart:68,120-124,561`, `control_cubit.dart:183-186,197,201-202,210,213-214,250-264,406-413,2652-2801,2968`.
- Tests: `control_cubit_controller_test.dart:179-188,894-1100`; `control_face_test.dart:68,146-160,903-1041`.

**Classification:** DELETE, together with the `midiSimulate` and `midiSimulateGlobal` ARB keys.

## 4. Settings, and how `midi_device_repository` relates

**`packages/settings_repository/lib/src/settings_repository.dart`**
- 571-589 (`_controllerMappingsKey = 'controller.mappings'`, `loadControllerMappings`, `saveControllerMappings`): **DELETE**.
  - Callers: `control_cubit.dart:494,2196` only.
  - Test to delete: group `'controller mappings'` at `packages/settings_repository/test/settings_repository_test.dart:879-891`.
- 593-598 doc for `loadMidiMappings` ("Opaque, like the controller mappings"): edit.
- Keys to keep: `midi.mappings` 591-603, `midi.control_enabled` 605-613, `midi.input_device_id` / `midi.input_device_name` 351-380.
- No other settings key serves only the old model. There is no migration: AGENTS.md forbids compatibility layers, so the `controller.mappings` blob left on devices is simply never read.

**`MidiControllerSource` (`packages/midi_client/lib/src/midi_controller_source.dart`)**

| Stream | Consumers |
|---|---|
| `inputs` (debounced, 56-57, 87-93) | `ControllerRepository` only (`controller_repository.dart:64`) |
| `activity` (undebounced, 59-62, 85) | `MidiDeviceRepository.activity` (97-98) → `MidiSetupCubit` (`lib/audio_setup/cubit/midi_setup_cubit.dart:29`); `MidiDeviceRepository.messages` (108-109) → `control_cubit.dart:224`; the pedal (`native_pedal_repository.dart:62`) |

**Reshape of `MidiControllerSource`**
- Remove:
  - `implements ControllerSource` (23).
  - The `debounce` parameter and field (27-33, 39-40).
  - `_inputs` (44-45), `_lastEmitUs` (49-52), the `inputs` getter (56-57), the debounce block (87-93), `_triggerKey` (140-142), and `_inputs.close()` (165).
- Rewrite docs:
  - 10-22 names `ControllerRepository` and the debounce.
  - 59-62 says Program Change never reaches `activity`, which was already wrong: Program Change is parsed at 128-134.
  - 99-103 names the "action mappings".
- Keep: `activity`, `enumerate`, `open`, `close`, `pushForTest`, `dispose`, `_parse`.
- The package keeps its `controller_repository` dependency for `RawControllerInput` / `ControllerSourceKind`.

**`packages/midi_client/test/midi_controller_source_test.dart`**
- Parsing tests read `inputs` at 38, 57, 77, 95, 108, 120, 140, 153; switch them to `activity`.
- Delete group `'debounce'` 172-219.
- Rework `'activity tap'` 221-239.
- Dispose tests: `inputs` references at 296 and 314.
- Removed getters: `isPress` 50, 101; `trigger` / `channelTrigger` 130-133.

**`midi_device_repository`**
- Ownership docs name `ControllerRepository`: `lib/midi_device_repository.dart:6-7`; `lib/src/midi_device_repository.dart:25-27,333-336`.
- `messages` doc at 103-107 refers to "the debounced input stream".
- `native_midi_source.dart:4` says "for the controller pipeline".
- Test comments: `midi_device_repository_test.dart:123-124` (the debounced stream) and 602-603 ("owned by the ControllerRepository"). The `'does not dispose the borrowed source'` test at 597-605 still holds as a contract.

## 5. Package doc comment, pubspecs, README

- **`packages/controller_repository/lib/controller_repository.dart`**:
  - 1-3: the library doc describes "maps raw MIDI inputs to looper actions and to external-MIDI bindings… MIDI-learn capture". Rewrite it for the MIDI formats, mapping and engine.
  - Remove exports at 7-10 and 12-15: `controller_binding`, `controller_binding_event`, `controller_binding_set`, `controller_event`, `controller_mapping`, `controller_repository`, `controller_source`, `looper_action`, `simulated_controller_source`.
  - Keep exports: `binding_behavior` (unless it moves), `controller_input`, `midi_mapping`, `midi_mapping_engine`, `midi_protocol`.
- **`packages/controller_repository/pubspec.yaml`**:
  - 2-4: the description ("maps raw MIDI inputs to looper actions through a remappable mapping, with MIDI-learn capture") needs rewriting.
  - Dev dependency `fake_async` becomes unused; its only import is `controller_bindings_dispatch_test.dart:4`.
  - Dev dependency `mocktail` is already imported by no test in the package.
- **`packages/midi_client/pubspec.yaml:2-5`**: the description says it "feeds raw inputs to the controller_repository as a ControllerSource".
- **`packages/midi_client/lib/midi_client.dart:1-7`**: the library doc says "adapts it to the controller abstraction as a `MidiControllerSource` (implements `ControllerSource`)".
- **`packages/pedal_repository/lib/src/pedal_protocol_traffic.dart:11`**: "MIDI-learn passes this to `ControllerRepository` as its ignore filter (B8)". The caller is now `control_cubit.dart:2531`.
- **READMEs:** there is no `packages/*/README.md`. Root `README.md:11-12` only links `docs/MIDI_FOOT_CONTROLLER.md`; no edit needed.

## 6. Tracked docs that describe the old model

| File | Lines | Content |
|---|---|---|
| `docs/MIDI_FOOT_CONTROLLER.md` | 3-6, 12-19, 26-44, 46-124, 132-136 | Fixed CC 80-86 table; Add sweep / Add switch; LO/HI; threshold and hysteresis; jump-on-first-move takeover (the accepted design uses pickup instead, `docs/design/2026-09-07-midi-controls-ux.md:28`); the `controller.mappings` blob; learn swallowing all MIDI; "EXTERNAL MIDI CONTROL in Audio settings". The whole file needs a rewrite. |
| `docs/RUNNING_ON_RPI.md` | 453-454 | "Input arrives as **CC 80/81/82/83 on track 0** (`MidiControllerSource`)" |
| `docs/PROGRESS.md` | 155 | `controller_repository/ REPO — hardware-agnostic MIDI → looper actions` |
|  | 163 | `midi_client … (ControllerSource)` |
|  | 168 | `app/ App + MultiRepositoryProvider (looper, controller, settings)` |
|  | 756-758 | `MidiControllerSource` → `ControllerRepository` |
|  | 328, 788 | Historical phase log and test count (`controller_repository 18`, already stale) |
| `docs/plan/*`, `docs/brainstorm/*` | many | Historical records; not updated (checked against the tracked-doc grep). |

## 7. Tables

### Files to delete

| File | Reason |
|---|---|
| `packages/controller_repository/lib/src/controller_binding.dart` | Old binding model |
| `packages/controller_repository/lib/src/controller_binding_event.dart` | Old dispatch events |
| `packages/controller_repository/lib/src/controller_binding_set.dart` | Old `controller.mappings` payload |
| `packages/controller_repository/lib/src/controller_event.dart` | Fixed scheme |
| `packages/controller_repository/lib/src/controller_mapping.dart` | Fixed CC 80-86 scheme |
| `packages/controller_repository/lib/src/controller_repository.dart` | No remaining job (§2) |
| `packages/controller_repository/lib/src/controller_source.dart` | Only `ControllerRepository` consumed it |
| `packages/controller_repository/lib/src/looper_action.dart` | Fixed scheme |
| `packages/controller_repository/lib/src/simulated_controller_source.dart` | Only the old tray used it |
| `packages/controller_repository/test/controller_binding_set_test.dart`, `controller_binding_test.dart`, `controller_bindings_dispatch_test.dart`, `controller_mapping_test.dart`, `controller_repository_test.dart`, `simulated_controller_source_test.dart`, `helpers/fake_controller_source.dart` | Tests of deleted code |
| `lib/control/view/midi_tray_body.dart` | Old MIDI tray. It also holds the only device chooser and status card (§0). |
| `lib/audio_setup/view/midi_learn_section.dart` | Old Audio-settings learn section |
| `lib/control/binding/controller_learn.dart` | Old learn state |
| `test/control/control_cubit_controller_test.dart` | Old cubit paths. Before deleting, port 3 tests the new MIDI tests do not cover: master-gain accumulator, stale target, value held on disconnect. |
| `test/audio_setup/view/midi_learn_section_test.dart` | Deleted widget |
| `test/looper/bloc/midi_looper_integration_test.dart` | Source → fixed mapping → `LooperBloc` |
| `test/screenshots/goldens/control_center_control_midi.png`, `control_center_control_midi_device.png` | Goldens of the deleted tray |

### Files to edit

| File | Remove or change |
|---|---|
| `packages/controller_repository/lib/controller_repository.dart` | Doc 1-3; exports 7-10, 12-15 |
| `packages/controller_repository/lib/src/controller_input.dart` | Delete `MappingTrigger` 27-96 and `RawControllerInput.trigger` / `channelTrigger` / `isPress` 120-133; rewrite the `midiProgram` doc 11-15 |
| `packages/controller_repository/lib/src/binding_behavior.dart` | Doc 1-12, or move the enum to `lib/control/binding/` |
| `packages/controller_repository/pubspec.yaml` | Description 2-4; dev dependencies `fake_async` and `mocktail` |
| `packages/midi_client/lib/src/midi_controller_source.dart` | `implements`, debounce, `inputs` (§4); docs 10-22, 59-62, 99-103 |
| `packages/midi_client/lib/midi_client.dart` | Doc 1-7 |
| `packages/midi_client/pubspec.yaml` | Description 2-5 |
| `packages/midi_client/test/midi_controller_source_test.dart` | `inputs` → `activity`; delete debounce group 172-219; getters 50, 101, 130-133; activity tap 221-239; dispose 296, 314 |
| `packages/midi_device_repository/lib/midi_device_repository.dart` | Doc 6-7 |
| `packages/midi_device_repository/lib/src/midi_device_repository.dart` | Docs 25-27, 103-107, 333-336 |
| `packages/midi_device_repository/lib/src/native_midi_source.dart` | Doc 4 |
| `packages/midi_device_repository/test/midi_device_repository_test.dart` | Comments 123-124, 602-603 |
| `packages/pedal_repository/lib/src/pedal_protocol_traffic.dart` | Doc 11 |
| `packages/settings_repository/lib/src/settings_repository.dart` | 571-589; doc 595 |
| `packages/settings_repository/test/settings_repository_test.dart` | 879-891 |
| `lib/app/run_segno.dart` | Import 6; 108-122 (keep 107); 156-159; 196 |
| `lib/app/view/app.dart` | Import 7; 61; 68; 117-124; 126-128 doc; 183; 211; 272-274 comment; 495-496, 510-518; 550-561; 564 |
| `lib/looper/bloc/looper_bloc.dart` | Import 4; 13-22; 25; 767; 784; 972 comment; 1142-1220; 1237 |
| `lib/looper/view/looper_page.dart` | Import 1; 40 |
| `lib/control/cubit/control_cubit.dart` | Import 17; docs 176-186; parameters 195, 197, 199-202; initializers 209-214; 222; fields 248-264, 272, 379-436; `_restore` 493-495, 516-520, 526; 2095-2403 except that `_applyValueTarget` 2405-2417 stays (used at 1248 expression, 1443 external switches, 2555 MIDI); 2419-2496; 2515-2516; 2652-2801; `close` 2966-2976 (keep 2965, 2977), 2982 |
| `lib/control/cubit/control_state.dart` | 25-26; 107-120; 193-195; 212-217; 236-237 |
| `lib/control/control.dart` | Doc 18-23; export 36 (`controller_learn.dart`) |
| `lib/control/binding/binding_labels.dart` | Doc 12-14; delete `controlLabel` 108-127; `valueTargetLabel` 65-87 has no remaining caller (reuse on the new page or delete, with ARB `midiLearnTargetVolume/Master/Param`) |
| `lib/control/binding/pedal_binding.dart` | Doc 7-10 (the re-export rationale) |
| `lib/control/view/control_tray_panel.dart` | Import 6; tabs 34-43 (`ControlTab.midi` and the body) |
| `lib/control/control_tab.dart` | `midi` 14-15; the enum is left with one value, so decide whether the tab strip stays |
| `lib/audio_setup/view/audio_settings_section.dart` | Import 10; 111-113 |
| `lib/audio_setup/audio_setup.dart` | Export `view/midi_learn_section.dart` |
| `lib/l10n/arb/app_en.arb`, `app_es.arb` | See the key list below |
| `test/control/control_face_test.dart` | 30-47 fake; 60-68 fields as needed; 141-161 wiring; 205-208 `showMidi`; 211-221 tab test; group `'MIDI tab'` 464-1042 |
| `test/screenshots/control_center_preview_test.dart` | Tests 897-944 and 946-977 |
| `test/control/binding/binding_labels_test.dart` | Group `controlLabel` 202-237; group `valueTargetLabel` 126-170 if the helper is deleted |
| `test/audio_setup/view/audio_settings_section_test.dart` | `_MockControlCubit` 25-26, 37-39, 89-95, 140. `AudioSettingsSection` reads `ControlCubit` only through `MidiLearnSection`; `PedalSettingsSection` and `ClickVolumeSection` do not read it. |
| `test/screenshots/settings_screenshots_test.dart` | Comment 138-139. `goldens/settings_audio_recording.png` changes if the removed section was in frame; goldens are author-only, so regenerate there. |
| `test/looper/bloc/looper_bloc_test.dart`, `test/looper/view/looper_page_test.dart`, `test/looper/view/settings_tray_test.dart`, `test/app/view/app_test.dart` | Per §2 |
| `docs/MIDI_FOOT_CONTROLLER.md`, `docs/RUNNING_ON_RPI.md`, `docs/PROGRESS.md` | Per §6 |

**ARB keys (line numbers in `app_en.arb` / `app_es.arb`)**
- **Delete — used only by the deleted views or their tests:**
  - `a11yMidiLearnRow` 1770/1098, `a11yMidiLearnLo` 1782/1099, `a11yMidiLearnHi` 1783/1100, `a11yMidiLearnThreshold` 1784/1101.
  - `midiLearnGroup` 1685/1071 through `midiLearnDeviceMissing` 1722/1092: `midiLearnHint`, `Empty`, `AddSweep`, `AddSwitch`, `Learn`, `Relearn`, `Clear`, `Cancel`, `Listening`, `ReplacePrompt`, `Replace`, `Keep`, `Lo`, `Hi`, `Threshold`, `Behavior`, `Stale`, `StaleDetail`.
  - `midiSimulate` 1696/1079, `midiSimulateGlobal` 1700/1080.
  - `midiTransportMap` 2339/1616.
  - `midiAction*` 2348-2384 / 1625-1661.
  - `midiStateSweep` / `midiStateSwitch` 2388-2392 / 1665-1669.
  - `midiMappingsEmpty` 2396/1673.
  - `midiRequiredCcsHint` 1112/721 ("CC 80 record · 81 stop…"): already unused and belongs to the fixed scheme.
- **Delete with `controlLabel`:** `midiLearnCcControl`, `midiLearnNoteControl`, `midiLearnProgramControl`.
- **Reuse or delete, depending on the new page's device section:** `midiDeviceGroup` 2319, `midiDeviceRow`, `midiDeviceNone`, `midiDeviceUnplugged` 2400, `midiStatusConnected` 1088, `midiStatusConnecting`, `midiStatusDeviceGone`, `midiStatusOpenFailed`, `midiStatusNone`, `midiStatusReceiving`, `midiStatusWaiting` 2331.
- **Already unused, found in passing:** `midiInputGroup` 1075, `midiNoDevicesFound`, `midiNone`, `midiDeviceNotFound`, `midiActivityActive`, `midiActivityIdle` 1114.

### Symbols to keep

| Symbol | Location | Kept for |
|---|---|---|
| `BindingBehavior` | `binding_behavior.dart` (or moved app-side) | Pedal remap: `pedal_binding.dart`, `pedal_assignment_page.dart`, `control_cubit.dart:2033-2036` |
| `ControllerSourceKind` (+ `fromName`) | `controller_input.dart:4-25` | `MidiSource` JSON (`midi_protocol.dart:59`), decoder, MIDI source parse, `isPedalProtocolInput`, pedal decode |
| `RawControllerInput` (`kind`, `id`, `value`, `midiChannel`) | `controller_input.dart:98-141`, minus 3 getters | `MidiDeviceRepository.messages`, `ControlCubit._onMidiMessage`, `MidiMappingEngine`, pedal |
| `MidiProtocol`, `MidiSource`, `MidiDecoder`; `MidiMapping`, `MidiBehavior`, `MidiControl`, `MidiMappingProblem`, `MidiMappingSet`; `MidiMappingEngine`, `MidiOutput` | `midi_protocol.dart`, `midi_mapping.dart`, `midi_mapping_engine.dart` | New model (#1047/#1048) |
| `MidiControllerSource` (`activity`, `enumerate`, `open`, `close`, `pushForTest`, `dispose`) | `packages/midi_client` | Native capture for the device repository, the pedal and the new engine |
| `isPedalProtocolInput` | `pedal_protocol_traffic.dart:25` | Learn filter at `control_cubit.dart:2531` |
| `ControlCubit._applyValueTarget` | `control_cubit.dart:2405-2417` | Expression (1248), external switches (1443), MIDI (2555) |
| `bindingTargetLabel`, `fxStageLabel`, `fxSlotName`, `fxParamName` | `binding_labels.dart` | Pedal tray, assignment page, expression catalogue |
| Settings `midi.mappings`, `midi.control_enabled`, `midi.input_device_*` | `settings_repository.dart:351-380, 591-613` | New model and device pin |