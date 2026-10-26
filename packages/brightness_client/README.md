# brightness_client

Data client for the Segno appliance's displays. `BrightnessClient` sets a
panel's brightness through the image's `segno-brightness-ctl` helper, and
`DisplayOutputs` reports which DRM connector each screen is drawn on and
whether a panel is plugged into it. It is pure Dart with no Flutter
dependency. The app creates both in `lib/app/run_segno.dart`; the display
brightness cubit and the Displays settings page use them.

## Usage

```dart
import 'package:brightness_client/brightness_client.dart';

Future<void> dimMainScreen() async {
  final brightness = createBrightnessClient();
  final outputs = createDisplayOutputs();

  final connector = (await outputs.screenConnectors())['main'];
  if (connector == null) return;
  if (await outputs.isConnected(connector) != true) return;
  if (await brightness.isSupported(connector)) {
    await brightness.set(connector, 0.4);
  }
}
```

## Notes

- Linux only. `createBrightnessClient` returns the no-op
  `UnsupportedBrightnessClient` on other platforms or when
  `/usr/bin/segno-brightness-ctl` is missing. `createDisplayOutputs` returns
  `UnknownDisplayOutputs` on other platforms or when
  `/etc/segno/homescreen.toml` is missing.
- Every brightness call names one connector (for example `HDMI-A-1`), so it
  changes that panel and no other. `set` clamps the value to `0..1` and
  passes the helper a whole percent.
- The helper is started with `runProcess` from `spawn_process`, which uses
  `posix_spawn` instead of `fork`. A call that runs longer than 10 seconds is
  killed, and a non-zero exit throws a `ProcessException`.
- `SystemDisplayOutputs` only reads files: the `[[view]]` entries of the
  embedder configuration and each connector's `status` under
  `/sys/class/drm`. It never starts a process.

## Testing

```sh
dart test
```

`dart_test.yaml` runs the suites from source, because the tests start a real
helper through `spawn_process`.

## License

Part of [Segno](../../README.md), licensed under the GNU General Public License
v3.0 or later. See [LICENSE](../../LICENSE).
