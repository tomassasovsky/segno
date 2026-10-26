# midi_client

Data client for native MIDI on Segno. `MidiClient` wraps the engine
library's `le_midi_*` input functions (list ports, open, close) and
`MidiOutClient` wraps the `le_midi_out_*` output functions. Both are called
through Dart FFI with the `segno_engine` bindings. `MidiControllerSource`
adapts the input side to `controller_repository`'s `ControllerSource`: it
opens one device at a time and publishes each Note, CC and Program Change
message as a `RawControllerInput`. In the app, `midi_device_repository`
creates the source and manages which device is open, and
`ControllerRepository` owns it and disposes it.

## Usage

```dart
import 'package:midi_client/midi_client.dart';

void openFirstInput() {
  final source = MidiControllerSource();
  final devices = source.enumerate();
  if (devices.isEmpty) return;

  source.messages.listen((message) {
    print('${message.session.device}: ${message.input}');
  });
  if (source.open(devices.first.id) != 0) {
    print('Could not open ${devices.first.name}');
  }
}
```

## Notes

- The MIDI functions live in the `segno_engine` native library.
  `SEGNO_ENGINE_LIB` overrides where it is loaded from (the appliance image
  sets it); otherwise it is the process itself on macOS and iOS,
  `segno_engine.dll` on Windows and `libsegno_engine.so` elsewhere.
- Creating a `MidiClient` or `MidiOutClient` throws `MidiException` when the
  platform has no MIDI backend. `open`, `close` and `send` return the native
  result code, where 0 means success.
- Every `open` starts a new `MidiInputSession` with a higher epoch, and
  callbacks from a closed port are dropped, so a message is never credited
  to the wrong device. Messages are not debounced.
- Device ids are stable per platform (the CoreMIDI unique id on macOS, the
  port name on ALSA and WinMM). Output ids are not interchangeable with input
  ids.

## Testing

```sh
flutter test
```

The tests inject fake engine bindings, so they do not need the native
library.

## License

Part of [Segno](../../README.md), licensed under the GNU General Public License
v3.0 or later. See [LICENSE](../../LICENSE).
