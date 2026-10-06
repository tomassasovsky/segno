import 'package:equatable/equatable.dart';
import 'package:storage_repository/storage_repository.dart';

/// What the Storage page draws: Internal and each removable volume, their
/// capacity, the recording time Internal still holds, and the eject state.
class StorageState extends Equatable {
  /// Creates a [StorageState].
  const StorageState({
    this.removableSupported = false,
    this.volumes = const [],
    this.internalSpace,
    this.volumeSpace = const {},
    this.sampleRate = 0,
    this.recordingTime,
    this.lowInternalSpace = false,
    this.holders = const {},
    this.ejectFailed,
    this.ejectTaken = false,
  });

  /// Whether this build can see removable volumes at all.
  final bool removableSupported;

  /// The removable volumes, sorted by generation.
  final List<RemovableVolume> volumes;

  /// Internal's capacity, or null while unknown.
  final VolumeSpace? internalSpace;

  /// Each mounted volume's capacity by generation; a volume missing here has
  /// not been measured (or cannot be).
  final Map<int, VolumeSpace> volumeSpace;

  /// The applied sample rate, in Hz, the recording estimate is made at; 0
  /// while the engine has none.
  final int sampleRate;

  /// How long a recording at the frozen format still fits on Internal after
  /// the reserve, or null when that cannot be known (no capacity, no rate).
  final Duration? recordingTime;

  /// Whether Internal has less free space than its reserve.
  final bool lowInternalSpace;

  /// What the leases holding each removable volume are for, by generation,
  /// each purpose once. A volume listed here cannot be ejected.
  final Map<int, Set<WritePurpose>> holders;

  /// The generation whose last eject failed, while it is still connected and
  /// not ejected after all.
  final int? ejectFailed;

  /// Whether a Cancel arrived after the helper had taken the eject: it is
  /// syncing and unmounting and cannot be stopped, so the page says so in
  /// place of offering Cancel again. Cleared when no drive is ejecting.
  final bool ejectTaken;

  /// Returns a copy with the given fields replaced. The nullable fields take
  /// a function, so null can be set rather than meaning "keep".
  StorageState copyWith({
    bool? removableSupported,
    List<RemovableVolume>? volumes,
    VolumeSpace? Function()? internalSpace,
    Map<int, VolumeSpace>? volumeSpace,
    int? sampleRate,
    Duration? Function()? recordingTime,
    bool? lowInternalSpace,
    Map<int, Set<WritePurpose>>? holders,
    int? Function()? ejectFailed,
    bool? ejectTaken,
  }) => StorageState(
    removableSupported: removableSupported ?? this.removableSupported,
    volumes: volumes ?? this.volumes,
    internalSpace: internalSpace != null ? internalSpace() : this.internalSpace,
    volumeSpace: volumeSpace ?? this.volumeSpace,
    sampleRate: sampleRate ?? this.sampleRate,
    recordingTime: recordingTime != null ? recordingTime() : this.recordingTime,
    lowInternalSpace: lowInternalSpace ?? this.lowInternalSpace,
    holders: holders ?? this.holders,
    ejectFailed: ejectFailed != null ? ejectFailed() : this.ejectFailed,
    ejectTaken: ejectTaken ?? this.ejectTaken,
  );

  @override
  List<Object?> get props => [
    removableSupported,
    volumes,
    internalSpace,
    volumeSpace,
    sampleRate,
    recordingTime,
    lowInternalSpace,
    holders,
    ejectFailed,
    ejectTaken,
  ];
}
