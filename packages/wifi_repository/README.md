# wifi_repository

Repository for WiFi on the Segno appliance. `WifiRepository` forwards each call
to a `WifiClient` from `wifi_client`, so the app's cubits depend on this
package and not on the data client. It also re-exports the client types the
app needs to build one (`createWifiClient`, `WifiStatus`, `WifiNetwork`,
`WifiHelperException`, and the fake and unsupported clients).

## Usage

```dart
import 'package:wifi_repository/wifi_repository.dart';

final wifi = WifiRepository(client: createWifiClient());

if (wifi.isSupported) {
  final status = await wifi.status();
  final networks = await wifi.scan();
  await wifi.connect('Studio', psk: 'secret');
  final online = await wifi.checkConnectivity();
}

// Hold background reconnects for the length of a performance.
await wifi.holdReconnects(hold: true);
```

The app creates one `WifiRepository` in `lib/app/run_segno.dart`. Off the
appliance it uses `UnsupportedWifiClient`, which reports `isSupported` as
`false` and returns empty results.

## Testing

Pure Dart package:

```sh
dart test
```

## License

Part of [Segno](../../README.md), licensed under the GNU General Public License
v3.0 or later. See [LICENSE](../../LICENSE).
