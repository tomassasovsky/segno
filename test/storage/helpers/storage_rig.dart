import 'package:operation_guards/operation_guards.dart';
import 'package:storage_repository/storage_repository.dart';
import 'package:usb_storage_client/usb_storage_client.dart';

/// The pen's own numbers (31 `Storage overview`): Internal 128 GB with 64 GB
/// free, a 32 GB stick labelled SEGNO USB with 24.2 GB free.
const internalTotal = 128000000000;
const internalFree = 64000000000;
const usbTotal = 32000000000;
const usbFree = 24200000000;

/// Where the rig says Internal is.
const exportsRoot = '/segno-storage-rig-absent/exports';

/// A [StorageRepository] over a [FakeUsbStorageClient], whose statvfs
/// answers from [spaces] and counts every read in [reads].
class StorageRig {
  StorageRig({
    List<RemovableVolumeRecord> volumes = const [],
    Duration ejectTimeout = const Duration(seconds: 20),
    Duration ejectServedTimeout = const Duration(minutes: 2),
    GuardRegistry? guards,
  }) : client = FakeUsbStorageClient(initial: volumes) {
    repository = StorageRepository(
      client: client,
      ejectTimeout: ejectTimeout,
      ejectServedTimeout: ejectServedTimeout,
      guards: guards ?? GuardRegistry(),
      exportsRoot: () async => exportsRoot,
      volumeSpace: (path) {
        reads++;
        return spaces[path];
      },
    );
  }

  final FakeUsbStorageClient client;
  late final StorageRepository repository;

  /// The engine's answers, by path. The exports root does not exist on the
  /// test machine, so Internal is read at the nearest existing parent: `/`.
  final spaces = <String, VolumeSpace?>{
    '/': const VolumeSpace(totalBytes: internalTotal, freeBytes: internalFree),
  };

  /// How many statvfs reads have been made.
  int reads = 0;

  /// Sets Internal's free space.
  void internal({int? free, int total = internalTotal}) => spaces['/'] =
      free == null ? null : VolumeSpace(totalBytes: total, freeBytes: free);

  Future<void> dispose() async {
    await repository.dispose();
    await client.dispose();
  }
}

/// The mount point the rig gives generation [g].
String mountPoint(int g) => '/run/media/segno/$g-SEGNO_USB';

/// A helper record for generation [g], as `segno-usb-ctl` writes it.
RemovableVolumeRecord usbRecord(
  int g, {
  String label = 'SEGNO USB',
  String fsType = 'exfat',
  RemovableVolumeRecordStatus status = RemovableVolumeRecordStatus.mounted,
  bool mounted = true,
  int? writeBytesPerSecond = 16777216,
}) => RemovableVolumeRecord(
  generation: g,
  kname: 'sda1',
  fingerprint: 'SanDisk_Ultra_4C530001-1A2B-3C4D',
  label: label,
  fsType: fsType,
  mountPoint: mounted ? mountPoint(g) : null,
  sizeBytes: usbTotal,
  status: status,
  readOnly: status == RemovableVolumeRecordStatus.readOnly,
  writeBytesPerSecond: writeBytesPerSecond,
);
