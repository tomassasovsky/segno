import 'package:equatable/equatable.dart';

/// Why a write to a destination did not happen. Every variant guarantees the
/// same thing: existing content was left intact, and no partial file is left
/// under a final name.
///
/// Each one says what happened in words a log line or the UI can print, the
/// same words the Library's `RemovableVolumes` port uses.
sealed class StorageFailure extends Equatable implements Exception {
  const StorageFailure();

  /// The destination ran out of space.
  const factory StorageFailure.full() = StorageFull;

  /// The destination refuses writes (a read-only mount).
  const factory StorageFailure.readOnly() = StorageReadOnly;

  /// The removable volume [generation] is gone: unplugged, ejected, or being
  /// ejected.
  const factory StorageFailure.volumeLost(int generation) = StorageVolumeLost;

  /// The destination cannot be written at all (no filesystem, one the image
  /// cannot drive, or a mount that failed).
  const factory StorageFailure.unsupported() = StorageUnsupported;

  /// Any other I/O failure, with the OS's own words.
  const factory StorageFailure.io(String reason, {String? writtenTo}) =
      StorageIo;

  @override
  List<Object?> get props => const [];
}

/// The destination ran out of space.
final class StorageFull extends StorageFailure {
  /// Creates a [StorageFull].
  const StorageFull();

  @override
  String toString() => 'the destination is full';
}

/// The destination refuses writes.
final class StorageReadOnly extends StorageFailure {
  /// Creates a [StorageReadOnly].
  const StorageReadOnly();

  @override
  String toString() => 'the destination is read-only';
}

/// The removable volume is gone.
final class StorageVolumeLost extends StorageFailure {
  /// Creates a [StorageVolumeLost] for [generation].
  const StorageVolumeLost(this.generation);

  /// The generation that is no longer present or usable.
  final int generation;

  @override
  List<Object?> get props => [generation];

  @override
  String toString() => 'drive $generation was removed';
}

/// The destination cannot be written at all.
final class StorageUnsupported extends StorageFailure {
  /// Creates a [StorageUnsupported].
  const StorageUnsupported();

  @override
  String toString() => 'the destination is not supported';
}

/// Any other I/O failure.
final class StorageIo extends StorageFailure {
  /// Creates a [StorageIo] with the OS's [reason].
  const StorageIo(this.reason, {this.writtenTo});

  /// What the OS said.
  final String reason;

  /// Where the file is, complete, when only the last step failed: the copy
  /// was renamed into place but the drive did not confirm the rename is
  /// durable. A caller says "copied, but the drive did not confirm it"
  /// rather than "failed", and a retry is not needed for the bytes (a
  /// `keepBoth` retry would only add a second copy). Null when nothing was
  /// published.
  final String? writtenTo;

  @override
  List<Object?> get props => [reason, writtenTo];

  @override
  String toString() => writtenTo == null
      ? 'storage I/O failed: $reason'
      : 'copied to $writtenTo, but the drive did not confirm it: $reason';
}
