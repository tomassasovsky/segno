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

  final StorageRepository _repository;
  final int Function() _sampleRate;
  late final StreamSubscription<List<RemovableVolume>> _volumes;

  void _onVolumes(List<RemovableVolume> volumes) {
    var destination = state.destination;
    var awaiting = state.awaitingDrive;
    if (destination is RemovableDestination &&
        !_canRecordTo(volumes, destination.generation)) {
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
      ),
    );
    unawaited(refresh());
  }

  static bool _canRecordTo(List<RemovableVolume> volumes, int generation) =>
      volumes.any(
        (v) =>
            v.generation == generation &&
            v.status == RemovableVolumeStatus.mounted &&
            v.mountPoint != null,
      );

  /// Chooses [destination]. A drive that cannot take a recording (gone,
  /// read-only, unsupported, being ejected) is not chosen.
  Future<void> choose(StorageDestination destination) async {
    if (destination is RemovableDestination &&
        !_canRecordTo(state.volumes, destination.generation)) {
      return;
    }
    emit(state.copyWith(destination: destination, awaitingDrive: false));
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
    emit(state.copyWith(awaitingDrive: true));
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
