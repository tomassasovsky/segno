part of 'recording_destination_cubit.dart';

/// Where the next take is recorded, what it can choose from, and how long a
/// take fits there.
class RecordingDestinationState extends Equatable {
  /// Creates a [RecordingDestinationState].
  const RecordingDestinationState({
    this.destination = const StorageDestination.internal(),
    this.volumes = const [],
    this.remaining,
    this.awaitingDrive = false,
    this.bytesPerSecond = 0,
  });

  /// Where the next take goes. Internal until a mounted drive is chosen, and
  /// Internal again when that drive goes.
  final StorageDestination destination;

  /// The removable volumes, in every state; the picker decides which can be
  /// chosen.
  final List<RemovableVolume> volumes;

  /// How long a take at the frozen format still fits on [destination], or
  /// null when that cannot be known (no capacity, no rate, a drive that
  /// cannot take a recording).
  final Duration? remaining;

  /// Whether the Connect USB sheet is waiting for a drive: the next mounted
  /// volume to appear is chosen.
  final bool awaitingDrive;

  /// The frozen format's rate at the applied sample rate, in bytes a second;
  /// 0 while the engine has no rate.
  final int bytesPerSecond;

  /// Returns a copy with the given fields replaced; [remaining] takes a
  /// function so null can be set.
  RecordingDestinationState copyWith({
    StorageDestination? destination,
    List<RemovableVolume>? volumes,
    Duration? Function()? remaining,
    bool? awaitingDrive,
    int? bytesPerSecond,
  }) => RecordingDestinationState(
    destination: destination ?? this.destination,
    volumes: volumes ?? this.volumes,
    remaining: remaining != null ? remaining() : this.remaining,
    awaitingDrive: awaitingDrive ?? this.awaitingDrive,
    bytesPerSecond: bytesPerSecond ?? this.bytesPerSecond,
  );

  @override
  List<Object?> get props => [
    destination,
    volumes,
    remaining,
    awaitingDrive,
    bytesPerSecond,
  ];
}
