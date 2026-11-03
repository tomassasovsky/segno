# midi_device_repository

Repository for the MIDI inputs Segno listens to. `MidiDeviceRepository` lists
the host's MIDI inputs and captures every plugged-in one at once, one
`midi_client` `MidiControllerSource` per device, so any connected controller
can feed the mappings learned from it. Each message on `messages` carries its
device's capture lifetime (`MidiInputSession`). The repository checks for
unplug and replug, saves which controller the MIDI page shows through
`settings_repository`, and publishes the result as a `MidiConnection` stream.
It has no audio dependency, so losing a MIDI device never restarts audio. The
app creates it in `lib/app/run_segno.dart`; the MIDI setup cubit, the control
cubit and the idle dimming host read it.

## Usage

```dart
import 'package:midi_device_repository/midi_device_repository.dart';
import 'package:settings_repository/settings_repository.dart';

Future<void> showFirstDevice(SettingsRepository settings) async {
  final midi = MidiDeviceRepository(
    captures: nativeMidiCaptures(),
    settings: settings,
  );

  midi.connections.listen((connection) {
    print('captured: ${connection.open}');
  });

  final devices = midi.connection.devices;
  if (devices.isNotEmpty) await midi.select(devices.first.id);
}
```

## Notes

- The repository owns its captures and disposes them in `dispose`.
- `nativeMidiCaptures` returns null instead of throwing when the platform has
  no MIDI backend. The repository then lists no devices and `select` does
  nothing.
- A device is identified by the id the native layer reports: the CoreMIDI
  unique id on macOS and the ALSA client name on Linux. Both survive a
  replug, so a device's mappings work again when it comes back.
- The device list is checked every 2 seconds (`pollInterval`). A device that
  appears is captured; one that goes is closed; a port that would not open is
  retried. `MidiConnection.connectivity` reports the most recent lost or
  restored device. Pass `Duration.zero` to turn the timer off and call
  `refresh` yourself.
- The selection only says which controller the MIDI page shows. A failed
  save sets `MidiConnection.pinUncertain` and completes the returned future
  with the error, so the caller can retry.

## Testing

```sh
flutter test
```

## License

Part of [Segno](../../README.md), licensed under the GNU General Public License
v3.0 or later. See [LICENSE](../../LICENSE).
