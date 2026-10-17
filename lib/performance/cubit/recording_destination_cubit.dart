import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:storage_repository/storage_repository.dart';

part 'recording_destination_state.dart';

/// The recorder's `Save to` (#1177 Part 6, pen 48 `cH9UX`): Internal or a
/// mounted USB drive, chosen before Start.
///
/// App-wide, beside the recorder, which reads [state] at arm. A chosen drive
/// that goes (pulled, ejected, remounted read-only) puts the choice back on
/// Internal, so a take never arms onto a drive that is no longer there; a
/// take already recording on it is ended by the recorder's lease, not here.
class RecordingDestinationCubit extends Cubit<RecordingDestinationState> {
  /// Creates a [RecordingDestinationCubit]. [sampleRate] reads the applied
  /// engine rate the remaining-time estimate is made at.
  RecordingDestinationCubit({
    required StorageRepository repository,
    required int Function() sampleRate,
  }) : _repository = repository,
       _sampleRate = sampleRate,
       super(RecordingDestinationState(volumes: repository.current)) {
    _volumes = repository.volumes.listen(_onVolumes);
    unawaited(refresh());
  }

  /// The recording estimate's frozen format: stereo 24-bit PCM at the
  /// applied rate, as on the Storage page (accepted behaviour §6.7).
  static const int bytesPerFrame = 2 * 3;

  /// How much faster than the recording a drive must write to be chosen:
  /// headroom for the drain's bursts.
  static const int headroom = 2;

  final StorageRepository _repository;
  final int Function() _sampleRate;
  late final StreamSubscription<List<RemovableVolume>> _volumes;

  void _onVolumes(List<RemovableVolume> volumes) {
    var destination = state.destination;
    var awaiting = state.awaitingDrive;
    String? fellBackFrom;
    if (destination is RemovableDestination &&
        !_canRecordTo(volumes, destination.generation)) {
      final generation = destination.generation;
      fellBackFrom = state.volumes
          .where((v) => v.generation == generation)
          .map((v) => v.label)
          .firstOrNull;
      destination = const StorageDestination.internal();
    }
    if (awaiting) {
      for (final volume in volumes) {
        if (_canRecordTo(volumes, volume.generation)) {
          destination = StorageDestination.removable(volume.generation);
          awaiting = false;
          break;
        }
      }
    }
    emit(
      state.copyWith(
        volumes: volumes,
        destination: destination,
        awaitingDrive: awaiting,
        fellBackFrom: () => fellBackFrom,
      ),
    );
    unawaited(refresh());
  }

  /// The write rate a drive must have measured to be chosen; 0 while the
  /// engine has no rate (then any measured drive will do).
  int get _requiredBytesPerSecond => _sampleRate() * bytesPerFrame * headroom;

  /// Whether the drive [generation] can take a recording: mounted
  /// read-write, and its write probe has landed at or above the
  /// requirement. A drive still being measured is not chosen yet; one
  /// measured too slow is never chosen.
  bool _canRecordTo(List<RemovableVolume> volumes, int generation) {
    final measured = volumes
        .where(
          (v) =>
              v.generation == generation &&
              v.status == RemovableVolumeStatus.mounted &&
              v.mountPoint != null,
        )
        .map((v) => v.writeBytesPerSecond)
        .firstOrNull;
    return measured != null && measured >= _requiredBytesPerSecond;
  }

  /// Chooses [destination]. A drive that cannot take a recording (gone,
  /// read-only, unsupported, being ejected) is not chosen.
  Future<void> choose(StorageDestination destination) async {
    if (destination is RemovableDestination &&
        !_canRecordTo(state.volumes, destination.generation)) {
      return;
    }
    emit(
      state.copyWith(
        destination: destination,
        awaitingDrive: false,
        fellBackFrom: () => null,
      ),
    );
    await refresh();
  }

  /// The Connect USB sheet opened: the next drive that can take a recording
  /// is chosen as soon as it is mounted. One already mounted is chosen now
  /// (the sheet's `Try again`).
  void awaitDrive() {
    for (final volume in state.volumes) {
      if (_canRecordTo(state.volumes, volume.generation)) {
        unawaited(choose(StorageDestination.removable(volume.generation)));
        return;
      }
    }
    emit(state.copyWith(awaitingDrive: true, fellBackFrom: () => null));
  }

  /// The Connect USB sheet was cancelled: the take stays on Internal.
  void stopAwaitingDrive() => emit(state.copyWith(awaitingDrive: false));

  /// Re-reads how long a take fits on the chosen destination.
  Future<void> refresh() async {
    final destination = state.destination;
    final bytesPerSecond = _sampleRate() * bytesPerFrame;
    final remaining = bytesPerSecond > 0
        ? await _repository.recordingTimeRemaining(destination, bytesPerSecond)
        : null;
    if (isClosed || state.destination != destination) return;
    emit(
      state.copyWith(
        remaining: () => remaining,
        bytesPerSecond: bytesPerSecond,
      ),
    );
  }

  @override
  Future<void> close() async {
    await _volumes.cancel();
    return super.close();
  }
}
