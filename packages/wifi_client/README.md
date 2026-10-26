# wifi_client

Data client for WiFi on the Segno appliance. `SystemWifiClient` runs the
`/usr/bin/segno-wifi-ctl` helper and parses the JSON it prints into
`WifiStatus` and `WifiNetwork`. `wifi_repository` wraps this package, and the
app builds the client with `createWifiClient()`.

## Usage

```dart
import 'package:wifi_client/wifi_client.dart';

final client = createWifiClient();
if (client.isSupported) {
  final status = await client.status();
  final networks = await client.scan();
  try {
    await client.connect('Studio', psk: 'secret');
  } on WifiHelperException catch (error) {
    // error.restored names the network the helper brought back, if any.
  }
}
```

`createWifiClient()` returns:

- `FakeWifiClient` when the app is built with
  `--dart-define=SEGNO_FAKE_RADIOS=true` (`kFakeRadios`), so the WiFi pages
  can be used on a desktop;
- `SystemWifiClient` on Linux when the helper is installed;
- `UnsupportedWifiClient` everywhere else.

## Notes

- The helper is started with `spawn_process` (`posix_spawn`), never with
  `dart:io` `Process`, because forking the app stalls the audio thread.
- Passwords go to the helper on stdin, never as arguments, and are replaced
  with `***` in any error text.
- `holdReconnects(hold: true)` writes `/run/segno/wifi-hold` so the
  appliance's background reconnect does not scan or join during a
  performance.
- A non-zero helper exit throws `WifiHelperException` with the helper's stderr.

## Testing

Pure Dart package:

```sh
dart test
```

## License

Part of [Segno](../../README.md), licensed under the GNU General Public License
v3.0 or later. See [LICENSE](../../LICENSE).
