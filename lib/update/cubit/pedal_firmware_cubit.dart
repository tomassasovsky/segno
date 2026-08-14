import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:update_repository/update_repository.dart';

/// Where the post-reboot pedal flash has got to.
enum PedalFirmwareStage {
  /// Asking the helper whether a flash is coming. Nothing is shown yet: this
  /// resolves in milliseconds on desktop and must not flash a screen.
  checking,

  /// Nothing to do — no firmware published, pedal already current, or no pedal.
  /// The looper is free to run.
  idle,

  /// Programming. The pedal is in its bootloader for the duration.
  flashing,

  /// The flash did not complete, after every retry. The user is let through
  /// anyway.
  failed,
}

/// State of the pedal firmware gate.
class PedalFirmwareState extends Equatable {
  /// Creates a [PedalFirmwareState].
  const PedalFirmwareState({
    this.stage = PedalFirmwareStage.checking,
    this.version,
    this.progress = 0,
    this.error,
    this.failureClass,
  });

  /// Where the flash has got to.
  final PedalFirmwareStage stage;

  /// The firmware version being written, when known.
  final String? version;

  /// Flash progress in `[0, 1]`.
  final double progress;

  /// Why the flash failed, when it did.
  final String? error;

  /// How far the failed flash got, when [stage] is
  /// [PedalFirmwareStage.failed]. Decides what the failed dialog may honestly
  /// claim: only [PedalFlashFailureClass.notStarted] permits "your pedal still
  /// works on its previous firmware".
  final PedalFlashFailureClass? failureClass;

  /// Whether the looper should be covered.
  bool get blocksLooper =>
      stage == PedalFirmwareStage.flashing ||
      stage == PedalFirmwareStage.failed;

  @override
  List<Object?> get props => [stage, version, progress, error, failureClass];
}

/// Runs the pedal firmware flash that an OS update left pending, and holds the
/// UI closed while it does.
///
/// The flash cannot run during the OS update itself — that code lives in the
/// image being replaced, so it would run the outgoing flasher (#444). Doing it
/// here, on the next start, means the flasher that runs is the one that shipped
/// with the running image.
///
/// It is blocking on purpose. A pedal being programmed sits in its Caterina
/// bootloader: the footswitches do nothing and the ring is dark. A user left in
/// the looper does not read that as an update, they read it as a dead pedal —
/// and if they are playing, it is one.
class PedalFirmwareCubit extends Cubit<PedalFirmwareState> {
  /// Creates a [PedalFirmwareCubit] over [updates].
  PedalFirmwareCubit({required UpdateRepository updates})
    : _updates = updates,
      super(const PedalFirmwareState());

  final UpdateRepository _updates;

  /// Total flash attempts before the failed dialog is shown (#670). The
  /// retries are silent — the gate keeps its "Finishing update" face — because
  /// most transient failures (a dropped manifest fetch, a missed bootloader
  /// window) self-heal on the next try, and a dialog about a problem that is
  /// about to fix itself would only alarm.
  ///
  /// The retry lives HERE, not in the helper: each `flash-pedal` invocation is
  /// deliberately stateless — one complete gated attempt with a legible exit —
  /// and the "try again" policy (like the original "next start will offer the
  /// flash again") has always been the cubit's. Re-invoking the verb re-runs
  /// every gate from the manifest down, which is exactly what a retry should
  /// mean.
  static const int maxAttempts = 3;

  /// Belt and braces over the helper's own budgets (`AVRDUDE_TIMEOUT`,
  /// `PEDAL_PORT_TIMEOUT`): if the helper process wedges and stops emitting
  /// progress entirely, the console must not be held hostage forever. Longer
  /// than the helper's longest silent stretch (the 300 s hex download cap), so
  /// it can only fire on a genuinely stuck helper.
  static const Duration stallTimeout = Duration(minutes: 6);

  /// Flashes the pending firmware, if any. Safe to call once per app start.
  Future<void> run() async {
    if (!_updates.isSupported) {
      emit(const PedalFirmwareState(stage: PedalFirmwareStage.idle));
      return;
    }

    final version = await _updates.pendingPedalFirmware();
    if (isClosed) return;
    if (version == null) {
      emit(const PedalFirmwareState(stage: PedalFirmwareStage.idle));
      return;
    }

    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      // Progress restarts from zero on a retry — an honest bar that starts
      // over beats one frozen where the last attempt died.
      emit(
        PedalFirmwareState(
          stage: PedalFirmwareStage.flashing,
          version: version,
        ),
      );
      try {
        await _flashOnce(version);
        if (isClosed) return;
        emit(const PedalFirmwareState(stage: PedalFirmwareStage.idle));
        return;
      } on Exception catch (error) {
        if (isClosed) return;
        // Unknown counts as interrupted: comfort that cannot be proven must
        // not be offered.
        final failureClass =
            await _updates.lastPedalFlashFailure() ??
            PedalFlashFailureClass.interrupted;
        if (isClosed) return;

        if (attempt < maxAttempts && await _worthRetrying(failureClass)) {
          if (isClosed) return;
          continue;
        }
        if (isClosed) return;
        emit(
          PedalFirmwareState(
            stage: PedalFirmwareStage.failed,
            version: version,
            error: '$error',
            failureClass: failureClass,
          ),
        );
        return;
      }
    }
  }

  /// One complete flash attempt: drains the helper's progress stream into
  /// [PedalFirmwareStage.flashing] states, completing on success and throwing
  /// on failure or on a stall.
  ///
  /// The stall guard is a hand-armed [Timer] re-armed on every progress event
  /// rather than `Stream.timeout`, which never resolves under the fake-async
  /// zones the tests run in (its events escape the zone's clock).
  Future<void> _flashOnce(String version) async {
    final done = Completer<void>();
    Timer? stall;

    void arm() {
      stall?.cancel();
      stall = Timer(stallTimeout, () {
        if (!done.isCompleted) {
          done.completeError(
            TimeoutException('update helper stopped responding', stallTimeout),
          );
        }
      });
    }

    arm();
    final sub = _updates.flashPedalFirmware().listen(
      (value) {
        arm();
        if (isClosed) return;
        emit(
          PedalFirmwareState(
            stage: PedalFirmwareStage.flashing,
            version: version,
            progress: value.clamp(0.0, 1.0),
          ),
        );
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!done.isCompleted) done.completeError(error, stackTrace);
      },
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
      cancelOnError: true,
    );
    try {
      await done.future;
    } finally {
      stall?.cancel();
      // Not awaited: awaiting a stream cancel inline can hang under the
      // widget-test fake clock (dart-lang/sdk#49353 shape; see the repo's
      // testWidgets stream-cancel note).
      unawaited(sub.cancel());
    }
  }

  /// Whether another silent attempt can help.
  ///
  /// `not-started` always can: nothing was written, so the pedal is intact and
  /// the failure was environmental (network, a missed bootloader window).
  /// `interrupted` can only help if the pedal re-presents its sketch port —
  /// asked via `pedal-pending`, which requires one. A pedal parked in its
  /// bootloader answers nothing, and re-touching it is pointless: fail fast to
  /// the honest dialog instead. (Flashing a parked pedal's bootloader port
  /// directly is slice 3 of #670, not a retry.)
  Future<bool> _worthRetrying(PedalFlashFailureClass failureClass) async {
    if (failureClass == PedalFlashFailureClass.notStarted) return true;
    return await _updates.pendingPedalFirmware() != null;
  }

  /// Dismisses a failure and lets the user into the looper. The pedal keeps
  /// whatever the flash left it with, and the next start will offer the flash
  /// again.
  void dismiss() =>
      emit(const PedalFirmwareState(stage: PedalFirmwareStage.idle));
}
