import 'dart:io';

import 'package:storage_repository/storage_repository.dart';
import 'package:usb_storage_client/usb_storage_client.dart';

const int gib = 1 << 30;

/// A temp directory standing in for the appliance: `exports/` is Internal,
/// `media/<gen>-SEGNO_USB/` are mount points (real directories, so copies
/// can land in them), and [spaces] answers the engine's statvfs by path.
class Harness {
  Harness() : root = Directory.systemTemp.createTempSync('storage_repository');

  final Directory root;
  final spaces = <String, VolumeSpace?>{};
  late FakeUsbStorageClient client;

  String get exports => '${root.path}/exports';
  String get media => '${root.path}/media';
  String mountPoint(int generation) => '$media/$generation-SEGNO_USB';

  /// A helper record for [generation]; a [mounted] one gets its mount point
  /// created.
  RemovableVolumeRecord record(
    int generation, {
    RemovableVolumeRecordStatus status = RemovableVolumeRecordStatus.mounted,
    bool mounted = true,
    EjectOutcomeRecord? eject,
  }) {
    if (mounted) Directory(mountPoint(generation)).createSync(recursive: true);
    return RemovableVolumeRecord(
      generation: generation,
      kname: 'sda1',
      fingerprint: 'SanDisk_Ultra_4C530001-1A2B-3C4D',
      label: 'SEGNO USB',
      fsType: 'exfat',
      mountPoint: mounted ? mountPoint(generation) : null,
      sizeBytes: 32 * gib,
      status: status,
      readOnly: status == RemovableVolumeRecordStatus.readOnly,
      writeBytesPerSecond: 16777216,
      eject: eject,
    );
  }

  StorageRepository build({
    List<RemovableVolumeRecord> initial = const [],
    CopyBytes? copyBytes,
    Duration volumeLossGrace = const Duration(seconds: 2),
    bool createExports = true,
  }) {
    if (createExports) Directory(exports).createSync(recursive: true);
    client = FakeUsbStorageClient(initial: initial);
    return StorageRepository(
      client: client,
      exportsRoot: () async => exports,
      volumeSpace: (path) => spaces[path],
      copyBytes: copyBytes,
      volumeLossGrace: volumeLossGrace,
    );
  }

  /// A source file of [bytes] bytes with a recognisable pattern.
  File source(String name, int bytes) =>
      File('${root.path}/$name')
        ..writeAsBytesSync(List.generate(bytes, (i) => i % 251), flush: true);

  /// Every file under [dir], relative to it, sorted.
  List<String> filesUnder(String dir) {
    final base = Directory(dir);
    if (!base.existsSync()) return const [];
    return [
      for (final entity in base.listSync(recursive: true))
        if (entity is File) entity.path.substring(dir.length + 1),
    ]..sort();
  }

  void dispose() => root.deleteSync(recursive: true);
}

/// The exception a write meets for OS error [code].
FileSystemException osError(int code, String message) =>
    FileSystemException('write failed', 'part', OSError(message, code));
