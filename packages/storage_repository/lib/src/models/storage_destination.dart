import 'package:equatable/equatable.dart';

/// Where a write goes: Internal storage, or one removable volume named by its
/// generation.
sealed class StorageDestination extends Equatable {
  const new();

  /// Internal storage (the `/data` volume on the appliance).
  const factory internal() = InternalDestination;

  /// The removable volume with this [generation].
  const factory removable(int generation) = RemovableDestination;
}

/// Internal storage.
final class InternalDestination extends StorageDestination {
  /// Creates an [InternalDestination].
  const new();

  @override
  List<Object?> get props => const [];
}

/// One removable volume.
final class RemovableDestination extends StorageDestination {
  /// Creates a [RemovableDestination] for [generation].
  const new(this.generation);

  /// The volume's per-boot generation. A replug is a new generation, so a
  /// destination never addresses a drive other than the one it was made for.
  final int generation;

  @override
  List<Object?> get props => [generation];
}
