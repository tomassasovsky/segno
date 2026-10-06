import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:segno/storage/cubit/storage_state.dart';
import 'package:storage_repository/storage_repository.dart';

export 'storage_state.dart';

/// Projects the [StorageRepository] for the Storage page and the power-off
/// gate (#1177).
///
/// App-wide, so shutdown can ask about transfers outside the page. Capacity
/// is the engine's `statvfs`, read on three occasions only: when the page
/// opens ([startWatching]), on every change to the volume list, and every
/// five seconds while the page is open. There is no app-wide timer.
/// Shutdown asks the repository itself whether a transfer is in flight: a
/// lease can be taken between two of this cubit's reads.
class StorageCubit extends Cubit<StorageState> {
  /// Creates a [StorageCubit]. [sampleRate] reads the applied engine rate the
  /// recording estimate is made at.
  StorageCubit({
    required StorageRepository repository,
    required int Function() sampleRate,
    Duration refreshInterval = const Duration(seconds: 5),
  }) : _repository = repository,
       _sampleRate = sampleRate,
       _refreshInterval = refreshInterval,
       super(
         StorageState(removableSupported: repository.isRemovableSupported),
       ) {
    _volumes = repository.volumes.listen(_onVolumes);
  }

  /// The recording estimate's frozen format: stereo 24-bit PCM at the
  /// applied rate (accepted behaviour §6.7).
  static const int recordingChannels = 2;

  /// Bytes per sample of [recordingChannels].
  static const int recordingBytesPerSample = 3;

  /// How often the open page re-reads capacity.
  final Duration _refreshInterval;

  final StorageRepository _repository;
  final int Function() _sampleRate;
  late final StreamSubscription<List<RemovableVolume>> _volumes;
  Timer? _watch;

  void _onVolumes(List<RemovableVolume> volumes) {
    final failed = state.ejectFailed;
    // A failure stands while the drive is there and not ejected: a drive the
    // helper ejected after all (an answer that came late) is Safe to remove,
    // and "Could not eject" under it would contradict the card.
    final failureStands =
        failed != null &&
        volumes.any(
          (v) =>
              v.generation == failed &&
              v.status != RemovableVolumeStatus.ejected,
        );
    emit(
      state.copyWith(
        volumes: volumes,
        ejectFailed: failureStands ? null : () => null,
        ejectTaken: state.ejectTaken && volumes.any(_isEjecting),
        ejectStuck:
            volumes.any(
              (v) => v.generation == state.ejectStuck && _isEjecting(v),
            )
            ? null
            : () => null,
      ),
    );
    unawaited(refresh());
  }

  static bool _isEjecting(RemovableVolume volume) =>
      volume.status == RemovableVolumeStatus.ejecting;

  /// Reads every capacity the page draws once.
  Future<void> refresh() async {
    final rate = _sampleRate();
    final internal = await _repository.space(
      const StorageDestination.internal(),
    );
    final time = rate > 0
        ? await _repository.recordingTimeRemaining(
            const StorageDestination.internal(),
            rate * recordingChannels * recordingBytesPerSample,
          )
        : null;
    final spaces = <int, VolumeSpace>{};
    final holders = <int, Set<WritePurpose>>{};
    for (final volume in state.volumes) {
      final destination = StorageDestination.removable(volume.generation);
      if (await _repository.space(destination) case final space?) {
        spaces[volume.generation] = space;
      }
      final leases = _repository.leasesOn(destination);
      if (leases.isNotEmpty) {
        holders[volume.generation] = {for (final l in leases) l.purpose};
      }
    }
    if (isClosed) return;
    emit(
      state.copyWith(
        internalSpace: () => internal,
        volumeSpace: spaces,
        sampleRate: rate,
        recordingTime: () => time,
        lowInternalSpace: StorageRepository.isLowInternalSpace(internal),
        holders: holders,
      ),
    );
  }

  /// The page opened: read now, then every few seconds until
  /// [stopWatching].
  void startWatching() {
    _watch?.cancel();
    _watch = Timer.periodic(_refreshInterval, (_) => unawaited(refresh()));
    unawaited(refresh());
  }

  /// The page closed: no more periodic reads.
  void stopWatching() {
    _watch?.cancel();
    _watch = null;
  }

  /// Ejects [generation]. Does nothing while another eject is in flight. A
  /// lease holding the drive refuses it (the repository's guard); the page
  /// then re-reads the holders and draws Eject disabled with their purpose.
  /// A failed eject is kept in [StorageState.ejectFailed] until the next
  /// attempt, until the drive goes, or until it reads ejected after all. One
  /// the helper took and has not answered is not a failure: the drive keeps
  /// reading `Ejecting…` until it does.
  Future<void> eject(int generation) async {
    if (state.volumes.any(_isEjecting)) return;
    emit(state.copyWith(ejectFailed: () => null, ejectTaken: false));
    final EjectOutcome outcome;
    try {
      outcome = await _repository.eject(generation);
    } on EjectRefused {
      await refresh();
      return;
    }
    if (isClosed) return;
    if (outcome == const EjectOutcome.failed(StorageRepository.stillEjecting) &&
        state.volumes.any(
          (v) => v.generation == generation && _isEjecting(v),
        )) {
      emit(state.copyWith(ejectStuck: () => generation));
      return;
    }
    if (outcome is EjectFailed &&
        outcome.reason != StorageRepository.stillEjecting &&
        state.volumes.any((v) => v.generation == generation)) {
      emit(state.copyWith(ejectFailed: () => generation));
    }
  }

  /// Withdraws the eject in flight if the helper has not taken it yet. If it
  /// has, nothing can stop it, and [StorageState.ejectTaken] says so.
  Future<void> cancelEject() async {
    final withdrawn = await _repository.cancelEject();
    if (isClosed || withdrawn) return;
    if (state.volumes.any(_isEjecting)) emit(state.copyWith(ejectTaken: true));
  }

  @override
  Future<void> close() async {
    _watch?.cancel();
    await _volumes.cancel();
    return super.close();
  }
}
