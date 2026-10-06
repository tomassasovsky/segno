import 'package:equatable/equatable.dart';

/// Why a write to a destination did not happen. Every variant guarantees the
/// same thing: existing content was left intact, and no partial file is left
/// under a final name.
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
  const factory StorageFailure.io(String reason) = StorageIo;

  @override
  List<Object?> get props => const [];
}

/// The destination ran out of space.
class StorageFull extends StorageFailure {
  /// Creates a [StorageFull].
  const StorageFull();
}

/// The destination refuses writes.
class StorageReadOnly extends StorageFailure {
  /// Creates a [StorageReadOnly].
  const StorageReadOnly();
}

/// The removable volume is gone.
class StorageVolumeLost extends StorageFailure {
  /// Creates a [StorageVolumeLost] for [generation].
  const StorageVolumeLost(this.generation);

  /// The generation that is no longer present or usable.
  final int generation;

  @override
  List<Object?> get props => [generation];
}

/// The destination cannot be written at all.
class StorageUnsupported extends StorageFailure {
  /// Creates a [StorageUnsupported].
  const StorageUnsupported();
}

/// Any other I/O failure.
class StorageIo extends StorageFailure {
  /// Creates a [StorageIo] with the OS's [reason].
  const StorageIo(this.reason);

  /// What the OS said.
  final String reason;

  @override
  List<Object?> get props => [reason];
}
