# midi_device_repository

Repository for the MIDI input device Segno listens to. `MidiDeviceRepository`
lists the host's MIDI inputs, opens and closes the selected one through
`midi_client`'s `MidiControllerSource`, saves the selection through
`settings_repository`, and checks for unplug and replug. It publishes the
result as a `MidiConnection` stream, and passes the device's raw messages on
`messages`. It has no audio dependency, so changing or losing a MIDI device
never restarts audio. The app creates it in `lib/app/run_segno.dart`; the
MIDI setup cubit, the control cubit and the idle dimming host read it.

## Usage

```dart
import 'package:midi_device_repository/midi_device_repository.dart';
import 'package:settings_repository/settings_repository.dart';

Future<void> pickFirstDevice(SettingsRepository settings) async {
  final midi = MidiDeviceRepository(
    source: createNativeMidiSource(),
    settings: settings,
  );

  midi.connections.listen((connection) {
    print('${connection.status}: ${connection.selectedName}');
  });

  final devices = midi.connection.devices;
  if (devices.isNotEmpty) await midi.select(devices.first.id);
}
```

## Notes

- The source is borrowed. `ControllerRepository` owns the
  `MidiControllerSource` and disposes it; `MidiDeviceRepository.dispose` only
  stops its own timer and stream.
- `createNativeMidiSource` returns null instead of throwing when the platform
  has no MIDI backend. The repository then lists no devices and `select` does
  nothing.
- On creation it reopens the saved device. A saved device that is not
  present gives `MidiConnectionStatus.deviceGone`; the selection is kept, and
  the device opens again when it comes back.
- The device list is checked every 2 seconds (`pollInterval`).
  `MidiConnection.connectivity` reports the most recent lost or restored
  change. Pass `Duration.zero` to turn the timer off and call `refresh`
  yourself.
- Selections run one at a time, and `select` saves the choice before it
  opens the port. A failed save leaves input stopped, sets
  `MidiConnection.pinUncertain`, and completes the returned future with the
  error, so the caller can retry.

## Testing

```sh
flutter test
```

## License

Part of [Segno](../../README.md), licensed under the GNU General Public License
v3.0 or later. See [LICENSE](../../LICENSE).
