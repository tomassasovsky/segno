# storage_repository

Repository that decides where a write may go on the Segno appliance: Internal
storage or a removable USB volume. It lists the volumes, measures their free
space, tracks who is writing (leases), decides whether a drive may be ejected,
and copies files so that existing content is left intact on every failure. The
Storage page, the Library, the performance recorder, export and backup use it.
It builds on `usb_storage_client` for volumes and on `segno_engine` for
`statvfs` and durable renames.

## Usage

```dart
import 'package:storage_repository/storage_repository.dart';
import 'package:usb_storage_client/usb_storage_client.dart';

final storage = StorageRepository(
  client: createUsbStorageClient(),
  exportsRoot: performance.exportsRoot,
  volumeSpace: performance.volumeSpace,
  guards: guardRegistry,
);

storage.volumes.listen((volumes) { /* plug, unplug, eject */ });

final remaining = await storage.recordingTimeRemaining(
  const StorageDestination.internal(),
  48000 * 2 * 4, // bytes per second: 48 kHz stereo float
);

final written = await storage.copyFile(
  '/data/Documents/exports/perf-20261023-201500/master-001.wav',
  const StorageDestination.removable(3),
  'Segno/Performances/master-001.wav',
  onConflict: ConflictPolicy.keepBoth,
);

final outcome = await storage.eject(3);
```

## Notes

- A copy goes to a hidden part file, is synced, then renamed into place. The
  destination never holds a half-written file under its final name.
- Failures are typed `StorageFailure`s: `StorageFull`, `StorageReadOnly`,
  `StorageVolumeLost`, `StorageUnsupported`, `StorageBusy` and `StorageIo`.
- `eject` is refused with `EjectRefused` while a lease holds the volume.
- The repository registers with the app's guard table (`operation_guards`),
  so a session apply, a take or a shutdown sees its leases and ejects.
- Internal keeps a 1 GB reserve: `recordingTimeRemaining` and
  `lowInternalSpace` subtract it; `space` reports the raw figure.

## Testing

```sh
flutter test
```

## License

Part of [Segno](../../README.md), licensed under the GNU General Public License
v3.0 or later. See [LICENSE](../../LICENSE).
