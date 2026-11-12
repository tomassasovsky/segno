import 'package:equatable/equatable.dart';
import 'package:operation_guards/operation_guards.dart';

/// Why a write to a destination did not happen. Every variant guarantees the
/// same thing: existing content was left intact, and no partial file is left
/// under a final name.
///
/// Each one says what happened in words a log line or the UI can print.
sealed class StorageFailure extends Equatable implements Exception {
  const new();

  /// The destination ran out of space.
  const factory full() = StorageFull;

  /// The destination refuses writes (a read-only mount).
  const factory readOnly() = StorageReadOnly;

  /// The removable volume [generation] is gone: unplugged, ejected, or being
  /// ejected.
  const factory volumeLost(int generation) = StorageVolumeLost;

  /// The destination cannot be written at all (no filesystem, one the image
  /// cannot drive, or a mount that failed).
  const factory unsupported() = StorageUnsupported;

  /// Another operation the guard table says must not overlap this write is
  /// in flight on that destination (a take on the drive, a shutdown).
  const factory busy(GuardKind kind) = StorageBusy;

  /// A file of [fileBytes] is larger than the destination's filesystem
  /// ([fsType]) holds, [maxFileBytes] at most: refused before anything was
  /// written (#1794).
  const factory fileTooLarge({
    required String fsType,
    required int maxFileBytes,
    required int fileBytes,
  }) = StorageFileTooLarge;

  /// Any other I/O failure, with the OS's own words.
  const factory io(String reason, {String? writtenTo}) = StorageIo;

  @override
  List<Object?> get props => const [];
}

/// The destination ran out of space.
final class StorageFull extends StorageFailure {
  /// Creates a [StorageFull].
  const new();

  @override
  String toString() => 'the destination is full';
}

/// The destination refuses writes.
final class StorageReadOnly extends StorageFailure {
  /// Creates a [StorageReadOnly].
  const new();

  @override
  String toString() => 'the destination is read-only';
}

/// The removable volume is gone.
final class StorageVolumeLost extends StorageFailure {
  /// Creates a [StorageVolumeLost] for [generation].
  const new(this.generation);

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
  const new();

  @override
  String toString() => 'the destination is not supported';
}

/// Refused by the guard table: [kind] is in flight and must finish first.
final class StorageBusy extends StorageFailure {
  /// Creates a [StorageBusy] naming what holds the destination.
  const new(this.kind);

  /// What holds it.
  final GuardKind kind;

  @override
  List<Object?> get props => [kind];

  @override
  String toString() => 'busy: ${kind.name} is in flight';
}

/// A file is larger than the destination's filesystem holds.
final class StorageFileTooLarge extends StorageFailure {
  /// Creates a [StorageFileTooLarge].
  const new({
    required this.fsType,
    required this.maxFileBytes,
    required this.fileBytes,
  });

  /// The destination's filesystem, as the volume record names it (`vfat`).
  final String fsType;

  /// The largest file it holds.
  final int maxFileBytes;

  /// The size of the largest file that was to be written.
  final int fileBytes;

  @override
  List<Object?> get props => [fsType, maxFileBytes, fileBytes];

  @override
  String toString() =>
      'a file of $fileBytes bytes is larger than $fsType holds '
      '($maxFileBytes bytes)';
}

/// Any other I/O failure.
final class StorageIo extends StorageFailure {
  /// Creates a [StorageIo] with the OS's [reason].
  const new(this.reason, {this.writtenTo});

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
