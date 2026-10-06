import 'dart:async';

import 'package:equatable/equatable.dart';

/// The Library's view of removable storage: the port it reads drives through
/// and copies files with, shaped exactly like the appliance storage service's
/// domain model (#1177, `storage_repository`) so that service can stand behind
/// it without translation.
///
/// Until that package lands, the model types live here with the service's
/// field names. When it lands, this file imports them from there and these
/// declarations go: one commit, no behaviour change.
abstract interface class RemovableVolumes {
  /// The mounted, readable drives; empty when none. Emits on every change.
  Stream<List<RemovableVolume>> get volumes;

  /// The drives as of now.
  List<RemovableVolume> get current;

  /// The total and free bytes of [destination], or `null` when unknown
  /// ("unknown capacity cannot claim available time").
  Future<VolumeSpace?> space(StorageDestination destination);

  /// Holds a write lease on [target] for [body]'s duration, so Eject is
  /// refused naming [purpose], and runs [body] with the target's mount point.
  /// Completes with [StorageFailure.volumeLost] when the drive goes away
  /// before or during.
  Future<T> withWriteLease<T>(
    StorageDestination target,
    String purpose,
    Future<T> Function(String mountPoint) body,
  );

  /// Copies [sourcePath] to [relativePath] under [destination]: write to
  /// `<name>.part`, fsync, rename. [ConflictPolicy.ask] throws
  /// [NameConflict] before writing; [ConflictPolicy.keepBoth] suffixes
  /// ` (2)`, ` (3)`…; [ConflictPolicy.replace] renames over. Failures are
  /// typed [StorageFailure]s and the part file is deleted on any of them.
  /// Returns the path written.
  Future<String> copyFile(
    String sourcePath,
    StorageDestination destination,
    String relativePath, {
    required ConflictPolicy onConflict,
  });
}

/// A drive's lifecycle state as the storage service reports it.
enum RemovableVolumeStatus {
  /// Mounted read-write.
  mounted,

  /// Mounted read-only.
  readOnly,

  /// Present but with a filesystem the appliance cannot use.
  unsupported,

  /// Present but the mount failed.
  mountFailed,

  /// An eject is in progress.
  ejecting,

  /// Unmounted; safe to remove.
  ejected,
}

/// One removable drive. Keyed by [generation]: a replug is `generation + 1`,
/// so a stale callback can never address the new drive.
class RemovableVolume extends Equatable {
  /// Creates a [RemovableVolume].
  const RemovableVolume({
    required this.generation,
    required this.fingerprint,
    required this.label,
    required this.fsType,
    required this.sizeBytes,
    required this.status,
    this.mountPoint,
    this.writeBytesPerSecond,
    this.failureReason,
  });

  /// The attach counter the service assigned this plug-in.
  final int generation;

  /// The drive's stable identity across replugs (filesystem UUID or serial).
  final String fingerprint;

  /// The volume label, or the service's fallback name.
  final String label;

  /// The filesystem type, as mounted.
  final String fsType;

  /// Where it is mounted, or `null` when it is not.
  final String? mountPoint;

  /// The volume's size in bytes.
  final int sizeBytes;

  /// The lifecycle state.
  final RemovableVolumeStatus status;

  /// The measured write rate, when the service has one.
  final int? writeBytesPerSecond;

  /// Why the drive is [RemovableVolumeStatus.mountFailed] or
  /// [RemovableVolumeStatus.unsupported], when it is.
  final String? failureReason;

  /// Whether the Library can read it right now.
  bool get readable =>
      (status == RemovableVolumeStatus.mounted ||
          status == RemovableVolumeStatus.readOnly) &&
      mountPoint != null;

  @override
  List<Object?> get props => [
    generation,
    fingerprint,
    label,
    fsType,
    mountPoint,
    sizeBytes,
    status,
    writeBytesPerSecond,
    failureReason,
  ];
}

/// Where a write goes: the appliance's internal storage, or one removable
/// drive by its [RemovableVolume.generation].
sealed class StorageDestination extends Equatable {
  const StorageDestination();

  /// The internal storage.
  const factory StorageDestination.internal() = InternalDestination;

  /// The removable drive attached as [generation].
  const factory StorageDestination.removable(int generation) =
      RemovableDestination;
}

/// The appliance's internal storage.
final class InternalDestination extends StorageDestination {
  /// Creates an [InternalDestination].
  const InternalDestination();

  @override
  List<Object?> get props => const [];
}

/// One removable drive, by generation.
final class RemovableDestination extends StorageDestination {
  /// Creates a [RemovableDestination] for [generation].
  const RemovableDestination(this.generation);

  /// The drive's attach counter.
  final int generation;

  @override
  List<Object?> get props => [generation];
}

/// A destination's capacity.
class VolumeSpace extends Equatable {
  /// Creates a [VolumeSpace].
  const VolumeSpace({required this.totalBytes, required this.freeBytes});

  /// The volume's size.
  final int totalBytes;

  /// The bytes free for writing (after any reserve the service keeps).
  final int freeBytes;

  @override
  List<Object?> get props => [totalBytes, freeBytes];
}

/// A write in progress on a destination; the Storage page shows [purpose] on
/// the disabled Eject.
class WriteLease extends Equatable {
  /// Creates a [WriteLease].
  const WriteLease({required this.target, required this.purpose});

  /// Where the write goes.
  final StorageDestination target;

  /// What the write is, for the player.
  final String purpose;

  @override
  List<Object?> get props => [target, purpose];
}

/// What a copy does when the destination name already exists.
enum ConflictPolicy {
  /// Throw [NameConflict] before writing anything.
  ask,

  /// Write beside the existing file under a ` (2)`, ` (3)`… suffix.
  keepBoth,

  /// Replace the existing file.
  replace,
}

/// A copy with [ConflictPolicy.ask] found [existingPath] in the way.
class NameConflict implements Exception {
  /// Creates a [NameConflict].
  const NameConflict(this.existingPath);

  /// The file already at the destination.
  final String existingPath;

  @override
  String toString() => 'a file already exists at $existingPath';
}

/// A storage operation's typed failure. Existing content is intact after
/// every one of them.
sealed class StorageFailure implements Exception {
  const StorageFailure();

  /// The destination ran out of space.
  const factory StorageFailure.full() = StorageFull;

  /// The destination is mounted read-only.
  const factory StorageFailure.readOnly() = StorageReadOnly;

  /// The drive [generation] went away before or during the operation.
  const factory StorageFailure.volumeLost(int generation) = StorageVolumeLost;

  /// The destination cannot be used on this build or filesystem.
  const factory StorageFailure.unsupported() = StorageUnsupported;

  /// Another I/O error, with the OS's [reason].
  const factory StorageFailure.io(String reason) = StorageIo;
}

/// See [StorageFailure.full].
final class StorageFull extends StorageFailure {
  /// Creates a [StorageFull].
  const StorageFull();

  @override
  String toString() => 'the destination is full';
}

/// See [StorageFailure.readOnly].
final class StorageReadOnly extends StorageFailure {
  /// Creates a [StorageReadOnly].
  const StorageReadOnly();

  @override
  String toString() => 'the destination is read-only';
}

/// See [StorageFailure.volumeLost].
final class StorageVolumeLost extends StorageFailure {
  /// Creates a [StorageVolumeLost].
  const StorageVolumeLost(this.generation);

  /// The drive that went away.
  final int generation;

  @override
  String toString() => 'drive $generation was removed';
}

/// See [StorageFailure.unsupported].
final class StorageUnsupported extends StorageFailure {
  /// Creates a [StorageUnsupported].
  const StorageUnsupported();

  @override
  String toString() => 'the destination is not supported';
}

/// See [StorageFailure.io].
final class StorageIo extends StorageFailure {
  /// Creates a [StorageIo].
  const StorageIo(this.reason);

  /// The OS's description.
  final String reason;

  @override
  String toString() => 'storage I/O failed: $reason';
}

/// The build with no removable storage: desktop, and the appliance until the
/// storage service stands behind the port. No drive is ever reported and
/// every removable operation is refused as unsupported, so the Library shows
/// "Connect a USB drive" and never a fake drive.
class InternalOnlyVolumes implements RemovableVolumes {
  /// Creates an [InternalOnlyVolumes].
  const InternalOnlyVolumes();

  @override
  Stream<List<RemovableVolume>> get volumes =>
      const Stream<List<RemovableVolume>>.empty();

  @override
  List<RemovableVolume> get current => const [];

  @override
  Future<VolumeSpace?> space(StorageDestination destination) async => null;

  @override
  Future<T> withWriteLease<T>(
    StorageDestination target,
    String purpose,
    Future<T> Function(String mountPoint) body,
  ) async => throw const StorageFailure.unsupported();

  @override
  Future<String> copyFile(
    String sourcePath,
    StorageDestination destination,
    String relativePath, {
    required ConflictPolicy onConflict,
  }) async => throw const StorageFailure.unsupported();
}
