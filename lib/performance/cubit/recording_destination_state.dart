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
    this.fellBackFrom,
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

  /// The label of the chosen drive that just went (pulled, ejected,
  /// remounted read-only), putting Save to back on Internal; set on that one
  /// state only, so the change can be said once.
  final String? fellBackFrom;

  /// Returns a copy with the given fields replaced; [remaining] takes a
  /// function so null can be set.
  RecordingDestinationState copyWith({
    StorageDestination? destination,
    List<RemovableVolume>? volumes,
    Duration? Function()? remaining,
    bool? awaitingDrive,
    int? bytesPerSecond,
    String? Function()? fellBackFrom,
  }) => RecordingDestinationState(
    destination: destination ?? this.destination,
    volumes: volumes ?? this.volumes,
    remaining: remaining != null ? remaining() : this.remaining,
    awaitingDrive: awaitingDrive ?? this.awaitingDrive,
    bytesPerSecond: bytesPerSecond ?? this.bytesPerSecond,
    fellBackFrom: fellBackFrom != null ? fellBackFrom() : null,
  );

  @override
  List<Object?> get props => [
    destination,
    volumes,
    remaining,
    awaitingDrive,
    bytesPerSecond,
    fellBackFrom,
  ];
}
