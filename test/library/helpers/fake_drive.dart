import 'dart:async';
import 'dart:io';

import 'package:mocktail/mocktail.dart';
import 'package:storage_repository/storage_repository.dart';

/// One `copyFile` call a [FakeDrive] received.
typedef DriveCopy = ({
  String source,
  String relativePath,
  ConflictPolicy policy,
});

/// A [StorageRepository] with one drive mounted at a real temporary
/// directory, so an export's files land where a test can read them.
///
/// `copyFile` follows the repository's contract (`ask` throws [NameConflict]
/// before writing, `keepBoth` suffixes ` (2)`, `replace` overwrites), and
/// records every call. [failOnCopy] makes the copy with that 1-based number
/// throw [failure] instead, before it writes anything, as the repository's
/// part protocol does.
class FakeDrive extends Fake implements StorageRepository {
  /// Creates a drive of [generation] mounted at [mount].
  new(
    this.mount, {
    this.generation = 3,
    this.status = RemovableVolumeStatus.mounted,
  });

  /// Where the drive is mounted.
  final String mount;

  /// The attach counter it was given.
  final int generation;

  /// Its state.
  RemovableVolumeStatus status;

  /// Whether it is plugged in at all.
  bool present = true;

  /// What [space] answers; null is unknown.
  VolumeSpace? spaceAnswer;

  /// The copy (1-based) that fails, and with what.
  int? failOnCopy;

  /// The failure [failOnCopy] throws.
  Exception failure = const StorageFailure.io('write error');

  /// Runs before each copy (1-based number), for a test that acts mid-way.
  void Function(int copy)? beforeCopy;

  /// When set, every lease is refused with it, as the repository refuses
  /// one the guard table forbids at its commit.
  StorageFailure? leaseRefusal;

  /// When set, every copy waits for it first: an export held mid-way.
  Completer<void>? hold;

  /// Every copy asked for, in order.
  final List<DriveCopy> copies = [];

  /// Every lease's purpose, in order.
  final List<WritePurpose> leasePurposes = [];

  final StreamController<List<RemovableVolume>> _changes =
      StreamController<List<RemovableVolume>>.broadcast();

  /// The drive as the repository reports it.
  RemovableVolume get volume => RemovableVolume(
    generation: generation,
    fingerprint: 'fake-$generation',
    label: 'USB',
    fsType: 'exfat',
    sizeBytes: 1 << 30,
    status: status,
    mountPoint: mount,
  );

  @override
  Stream<List<RemovableVolume>> get volumes => _changes.stream;

  @override
  List<RemovableVolume> get current => present ? [volume] : const [];

  @override
  Future<VolumeSpace?> space(StorageDestination destination) async =>
      spaceAnswer;

  @override
  Future<T> withWriteLease<T>(
    StorageDestination target,
    WritePurpose purpose,
    Future<T> Function(String root) body,
  ) async {
    leasePurposes.add(purpose);
    if (leaseRefusal case final refusal?) throw refusal;
    if (target != StorageDestination.removable(generation)) {
      throw StorageFailure.volumeLost(generation);
    }
    return await body(mount);
  }

  @override
  Future<String> copyFile(
    String sourcePath,
    StorageDestination destination,
    String relativePath, {
    required ConflictPolicy onConflict,
  }) async {
    copies.add((
      source: sourcePath,
      relativePath: relativePath,
      policy: onConflict,
    ));
    beforeCopy?.call(copies.length);
    if (hold case final hold?) await hold.future;
    if (failOnCopy == copies.length) throw failure;
    var target = '$mount/$relativePath';
    if (File(target).existsSync()) {
      switch (onConflict) {
        case ConflictPolicy.ask:
          throw NameConflict(target);
        case ConflictPolicy.keepBoth:
          final dot = target.lastIndexOf('.');
          final stem = dot < 0 ? target : target.substring(0, dot);
          final ext = dot < 0 ? '' : target.substring(dot);
          var n = 2;
          while (File('$stem ($n)$ext').existsSync()) {
            n++;
          }
          target = '$stem ($n)$ext';
        case ConflictPolicy.replace:
          break;
      }
    }
    File(target).parent.createSync(recursive: true);
    File(sourcePath).copySync(target);
    return target;
  }

  /// The drive's files at each volume sync, in order.
  final List<List<String>> volumeSyncs = [];

  /// When set, every volume sync waits for it after it records the drive:
  /// an export held at its last step.
  Completer<void>? syncHold;

  /// When set, every volume sync fails with it after it records the drive.
  StorageFailure? failOnSync;

  @override
  Future<void> syncVolume(StorageDestination destination) async {
    volumeSyncs.add(files);
    if (syncHold case final hold?) await hold.future;
    if (failOnSync case final failure?) throw failure;
  }

  /// Every file on the drive, relative to its root, sorted.
  List<String> get files {
    final root = Directory(mount);
    if (!root.existsSync()) return const [];
    return [
      for (final e in root.listSync(recursive: true))
        if (e is File) e.path.substring(mount.length + 1),
    ]..sort();
  }

  /// Reports a change to listeners.
  void announce() => _changes.add(current);

  /// Closes the change stream.
  Future<void> close() => _changes.close();
}

/// The storage of a console with no drive plugged in.
class NoDrive extends Fake implements StorageRepository {
  @override
  List<RemovableVolume> get current => const [];

  @override
  Stream<List<RemovableVolume>> get volumes => const Stream.empty();
}
