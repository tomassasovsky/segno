Part of #1026 (part 4g, the last PR). Stacked on the MIDI controls page PR.

## What goes

The accepted design has no reserved CC command scheme: a MIDI controller does nothing until it is mapped on the MIDI controls page. The old model is removed rather than kept beside the new one (AGENTS.md).

- **`controller_repository` package.**
  - Deleted: `ControllerRepository`, `ControllerMapping` (the fixed CC 80-86 transport map), `LooperAction`, `ControllerEvent`, `ControllerBinding` / `ContinuousBinding` / `DiscreteBinding`, their set and events, `ControllerSource` and `SimulatedControllerSource`, with their tests.
  - Kept: `RawControllerInput`, `ControllerSourceKind`, the formats, mappings, engine and signal levels.
  - `BindingBehavior` moves into `lib/control/binding/pedal_binding.dart`, its only user.
- **`MidiControllerSource`** keeps one undebounced message stream. The debounced `inputs` stream, which only the old repository read, is gone.
- **`ControlCubit`** loses the old binding, learn and simulate paths and the `controller.mappings` settings key. **`LooperBloc`** loses its controller subscription. Nothing in the app ever disposed `ControllerRepository`, so no disposal path is lost with it.
- **UI.**
  - The Control face drops its MIDI tab and the tab strip: one body, with the Pedal setup and MIDI controls rows.
  - Audio settings drops EXTERNAL MIDI CONTROL.
  - 66 strings used only by the removed screens are deleted from both locales.
- The `controller.mappings` blob on existing devices is never read again. There is no migration.

## What is added

- **Tap tempo** (`command:tap-tempo`) joins the shared action catalogue, as the accepted catalogue lists it. The fixed scheme was the only external way to reach it. The fixed scheme's click toggle and cancel-arm have no entry in the accepted catalogue, so they go with it.

## Tests carried over

Three old controller tests covered behaviour the new path still has. They now run against the MIDI mappings:
1. master gain stays in step with the encoder;
2. a mapped parameter that no longer exists writes nothing and throws nothing;
3. a knob value holds when the controller disconnects.

The old reference-counted "two momentary controls on one target" behaviour is not carried over. The engine restores each mapping's own Released value.

## Verification

- **Tests:** `flutter test` passes at the root (2380) and in `controller_repository`, `midi_client`, `midi_device_repository`, `settings_repository` and `pedal_repository`.
- **Screenshots:** the control center tray goldens were regenerated and compared by eye. Two MIDI tray goldens are deleted.
- **Static checks:**
  - `dart analyze --fatal-infos` and `bloc lint lib` are clean. The ten pre-existing infos in `packages/looper_repository/test/models/fx_chain_group_test.dart` are untouched.
  - cspell is clean on the changed docs; `NRPN` was added to the word list.
- **Docs:** `docs/MIDI_FOOT_CONTROLLER.md` is rewritten for the MIDI controls page. `docs/PROGRESS.md`, `docs/RUNNING_ON_RPI.md` and the engine header's MIDI section no longer describe CC 80-83.
