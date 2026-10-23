# usb_storage_client

Data client for removable USB drives on the Segno appliance. The operating
system mounts each drive (`segno-usb-ctl`, see `deploy/yocto`) and describes it
in a JSON file under `/run/segno/usb/volumes/`. This package reads those files,
watches the directory with inotify, and files eject requests. It starts no
process and does not poll. `storage_repository` is its only consumer; the app
creates the client with `createUsbStorageClient()` and passes it there.

## Usage

```dart
import 'package:usb_storage_client/usb_storage_client.dart';

final client = createUsbStorageClient();

client.volumes.listen((records) {
  for (final volume in records) {
    print('${volume.generation} ${volume.label} ${volume.status}');
  }
});

final requestId = await client.requestEject(generation);
// The outcome arrives through `volumes`: the record's `eject` names
// requestId, and on success its status is
// RemovableVolumeRecordStatus.ejected.
```

`createUsbStorageClient()` returns `FakeUsbStorageClient` when the app is built
with `--dart-define=SEGNO_FAKE_RADIOS=true`, `LinuxUsbStorageClient` on Linux
when `/run/segno/usb/volumes` exists, and `UnsupportedUsbStorageClient`
otherwise.

## Notes

- `generation` is a per-boot attach counter. A drive that is plugged in again
  gets a new generation, so work started against the old drive cannot
  complete against the new one.
- Only files named `<digits>.json` are read. The helper writes through a
  dotfile and renames it into place.
- If inotify drops events or the watch ends, the client lists the directory
  again and restarts the watch with a growing delay.
- Capacity, write leases and eject policy are not here; they belong to
  `storage_repository`.

## Testing

Pure Dart package:

```sh
dart test
```

## License

Part of [Segno](../../README.md), licensed under the GNU General Public License
v3.0 or later. See [LICENSE](../../LICENSE).
