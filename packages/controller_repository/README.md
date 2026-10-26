# controller_repository

Repository for Segno's control inputs. `ControllerRepository` owns every
`ControllerSource` (the MIDI capture from `midi_client` and the console's CTRL
jacks from `pedal_repository`) and forwards console CTRL samples on
`bindingEvents`. The package also holds the MIDI mapping model:
`MidiDecoder` reads raw messages in an explicit `MidiProtocol` (standard,
14-bit CC, NRPN, bank and program, relative), and `MidiMappingEngine` turns
complete readings into operations on opaque target keys. The app's
`ControlCubit` uses all of it; `midi_client` and `midi_device_repository`
depend on its types.

## Usage

```dart
import 'package:controller_repository/controller_repository.dart';

final stopwatch = Stopwatch()..start();
final decoder = MidiDecoder(clock: () => stopwatch.elapsed);
final mappings = MidiMappingEngine(
  read: (key) => currentValue(key),
  step: (key) => 0.01,
);

void configure(String deviceId) {
  mappings.setMappings(
    MidiMappingSet(
      mappings: [
        MidiMapping(
          id: 'cutoff',
          source: MidiSource(
            device: deviceId,
            kind: ControllerSourceKind.midiCc,
            number: 74,
          ),
          behavior: MidiBehavior.continuous,
          controls: [MidiParameterControl(key: 'track0.cutoff', low: 0, high: 1)],
        ),
      ],
    ),
  );
}

void onMessage(MidiInputMessage message) {
  final reading = decoder.feed(
    message.session.device,
    message.input,
    MidiProtocol.standard,
  );
  if (reading == null) return;
  for (final proposal in mappings.prepare(reading)) {
    final accepted = {
      for (final op in proposal.operations)
        if (apply(op)) op.controlIndex,
    };
    mappings.settle(proposal, accepted);
  }
}
```

`currentValue` and `apply` stand for the caller's own code.

## Notes

- `bindingEvents` carries only console CTRL kinds (`consoleSwitch`,
  `consoleExpression`). MIDI messages reach the mapping engine through
  `MidiDeviceRepository.messages`, not through this repository.
- The mapping engine is pure and stateful: call `prepare` and `settle` one
  after the other. Pickup, toggle state and held values change only for the
  rows the caller reports as accepted in `settle`.

## Testing

```sh
flutter test
```

## License

Part of [Segno](../../README.md), licensed under the GNU General Public License
v3.0 or later. See [LICENSE](../../LICENSE).
