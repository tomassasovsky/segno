import 'package:equatable/equatable.dart';

/// Where a write goes: Internal storage, or one removable volume named by its
/// generation.
sealed class StorageDestination extends Equatable {
  const StorageDestination();

  /// Internal storage (the `/data` volume on the appliance).
  const factory StorageDestination.internal() = InternalDestination;

  /// The removable volume with this [generation].
  const factory StorageDestination.removable(int generation) =
      RemovableDestination;
}

/// Internal storage.
class InternalDestination extends StorageDestination {
  /// Creates an [InternalDestination].
  const InternalDestination();

  @override
  List<Object?> get props => const [];
}

/// One removable volume.
class RemovableDestination extends StorageDestination {
  /// Creates a [RemovableDestination] for [generation].
  const RemovableDestination(this.generation);

  /// The volume's per-boot generation. A replug is a new generation, so a
  /// destination never addresses a drive other than the one it was made for.
  final int generation;

  @override
  List<Object?> get props => [generation];
}
