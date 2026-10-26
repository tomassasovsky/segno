# local_storage_client

Data client for local key-value storage in Segno. `KeyValueStore` is a small
asynchronous interface for reading and writing integers, strings, booleans
and doubles by key, and `SharedPreferencesKeyValueStore` implements it with
`shared_preferences`. `settings_repository` depends on the interface and
re-exports both types; the app passes a `SharedPreferencesKeyValueStore` to
`SettingsRepository` in `lib/app/run_segno.dart`.

## Usage

```dart
import 'package:local_storage_client/local_storage_client.dart';

Future<void> rememberBufferSize(KeyValueStore store) async {
  await store.setInt('buffer_frames', 128);
  final frames = await store.getInt('buffer_frames'); // 128
  await store.setBool('metronome_on', value: true);
  await store.remove('buffer_frames');
}

final KeyValueStore store = SharedPreferencesKeyValueStore();
```

## Notes

- `SharedPreferencesKeyValueStore` uses `SharedPreferencesAsync`, the
  uncached API: every read goes to the platform store. Pass a
  `SharedPreferencesAsync` instance to the constructor to substitute one in
  tests.
- Reads return `null` for a key that has no value. `clear` removes every key.
- Repositories should depend on `KeyValueStore`, not on `shared_preferences`,
  so their tests can use an in-memory fake.

## Testing

```sh
flutter test
```

## License

Part of [Segno](../../README.md), licensed under the GNU General Public License
v3.0 or later. See [LICENSE](../../LICENSE).
