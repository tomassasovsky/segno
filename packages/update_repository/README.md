# update_repository

Repository for software updates. `UpdateRepository` decides whether a
published update is newer than what is running or already staged, and passes
everything else to a `PlatformUpdateBackend`. The app's `UpdateCubit` drives
it. The app supplies the backend: `AppliancePlatformBackend` (in
`lib/update/appliance/`) on the Raspberry Pi appliance, and
`UnsupportedPlatformBackend` from this package everywhere else.

## Usage

```dart
import 'package:update_repository/update_repository.dart';

// createPlatformUpdateBackend() is the app's factory (lib/update/).
final updates = UpdateRepository(backend: createPlatformUpdateBackend());

if (updates.isSupported) {
  final recovery = await updates.recover(); // once, at startup
  final manifest = await updates.checkForUpdate(); // never downloads
  if (manifest != null) {
    // Only after the user asks for it:
    await for (final progress in updates.downloadAndStage(manifest)) {
      print('${(progress * 100).round()}%');
    }
  }
}
```

## Notes

- `checkForUpdate` returns a manifest only when its version is strictly
  greater, by semver precedence, than both the running and the staged
  version. `1.2.0` is newer than `1.2.0-experimental.7`.
- `UpdateManifest.fromJson` returns `null` when `version` is not valid semver
  or `bundle` is missing. The bundle's signature is checked by the backend;
  the manifest only says what is available.
- `normalizeUpdateChannel` maps any value other than `experimental` to
  `production`.
- On the appliance, the backend stages the signed RAUC bundle to the inactive
  slot through the `segno-update-ctl` helper. The reboot that applies it
  belongs to the app's power flow.

## Testing

```sh
flutter test
```

## License

Part of [Segno](../../README.md), licensed under the GNU General Public License
v3.0 or later. See [LICENSE](../../LICENSE).
