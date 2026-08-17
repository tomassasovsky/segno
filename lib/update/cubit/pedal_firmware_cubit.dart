import 'dart:async';

import 'package:clock/clock.dart';
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

  /// The in-flight attempt's teardown handles, so [close] can dismantle a
  /// flash mid-air: the stall [Timer] would otherwise sit armed for up to
  /// [stallTimeout] after the widget tree is gone, and the helper subscription
  /// would keep delivering into a closed cubit.
  Timer? _stall;
  StreamSubscription<double>? _sub;
  Completer<void>? _flashDone;

  /// The furthest the CURRENT attempt got, reset by every [_flashOnce]. A
  /// field rather than a local because it classifies failures the helper never
  /// got to record — see the classification in [run].
  double _lastProgress = 0;

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

  /// A ceiling on how long the silent retries may hold the gate.
  ///
  /// One attempt's worst case is the helper's own budgets stacked: 30 s
  /// manifest + 300 s hex + ~8 s bootloader window + 120 s avrdude + 10 s
  /// re-enumerate, ~7.8 min — and [stallTimeout] bounds a silent one at 6.
  /// [maxAttempts] of those back to back is over twenty minutes behind a
  /// `dismissible: false` gate with the ring restarting from zero and nothing
  /// said, which a lossy link is enough to produce. Retrying a few times and
  /// then saying it failed is still the policy; this only stops it costing a
  /// third of an hour. A retry is started only while under this budget, so the
  /// true ceiling is the budget plus one attempt, not [maxAttempts] of them.
  static const Duration retryBudget = Duration(minutes: 8);

  /// The helper's progress value at the moment it hands avrdude the
  /// bootloader port (`PROGRESS 50` in `segno-update-ctl flash-pedal`). A
  /// stall at or past this mark means a write may have begun; before it,
  /// nothing was written.
  static const double _writePhase = 0.5;

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

    // Through package:clock, not a Stopwatch: fake_async fakes the clock but
    // not Stopwatch, so a Stopwatch here would read ~0 forever under the
    // widget tests and the budget below would never be exercised.
    final startedAt = clock.now();
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
      } on Object catch (error) {
        // Not `on Exception`: an Error escaping here would leave the gate on
        // [PedalFirmwareStage.flashing] with [PedalFirmwareState.blocksLooper]
        // set, no Continue, and the stall timer already disarmed by
        // [_flashOnce]'s finally — an unrecoverable console lock, and
        // `run()` is called unawaited so nothing else would catch it either.
        // A failed dialog the user can dismiss beats that in every case.
        if (isClosed) return;

        // How far THIS attempt got is always true of this attempt. The marker
        // on disk may not be: the helper only writes one where it lives long
        // enough to, and a stall (it is killed), an OOM kill, a full /data or
        // a `set -e` abort on a line with no `write_pedal_fail` call all leave
        // whatever an EARLIER attempt wrote. Past [_writePhase] the helper had
        // handed avrdude the bootloader port, so a write may have begun.
        final reached = _lastProgress >= _writePhase
            ? PedalFlashFailureClass.interrupted
            : PedalFlashFailureClass.notStarted;
        final PedalFlashFailureClass failureClass;
        if (error is _FlashStalled) {
          // A stalled helper is killed, not just abandoned: left alive it
          // would fight the next attempt over the bootloader port, and its
          // eventual marker write could race the new attempt's. abort only
          // returns once the process is dead, so no retry can overlap it.
          await _updates.abortPedalFlash();
          if (isClosed) return;
          // The killed helper wrote no marker at all, so this attempt's own
          // progress is the only evidence there is.
          failureClass = reached;
        } else {
          // Both signals, and the more pessimistic wins: a stale `not-started`
          // must not launder an attempt that got as far as avrdude, and a
          // missing or unparseable marker counts as interrupted because
          // comfort that cannot be proven must not be offered.
          final marker =
              await _updates.lastPedalFlashFailure() ??
              PedalFlashFailureClass.interrupted;
          if (isClosed) return;
          failureClass = marker.worseOf(reached);
        }
        if (isClosed) return;

        if (attempt < maxAttempts &&
            clock.now().difference(startedAt) < retryBudget &&
            await _worthRetrying(failureClass)) {
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
  /// [PedalFirmwareStage.flashing] states, completing on success, throwing the
  /// stream's error on failure, and throwing [_FlashStalled] on a stall.
  ///
  /// The stall guard is a hand-armed [Timer] re-armed on every progress event
  /// rather than `Stream.timeout`, which never resolves under the fake-async
  /// zones the tests run in (its events escape the zone's clock).
  Future<void> _flashOnce(String version) async {
    final done = _flashDone = Completer<void>();
    _lastProgress = 0;

    void arm() {
      _stall?.cancel();
      _stall = Timer(stallTimeout, () {
        if (!done.isCompleted) done.completeError(_FlashStalled(_lastProgress));
      });
    }

    arm();
    _sub = _updates.flashPedalFirmware().listen(
      (value) {
        arm();
        _lastProgress = value.clamp(0.0, 1.0);
        if (isClosed) return;
        emit(
          PedalFirmwareState(
            stage: PedalFirmwareStage.flashing,
            version: version,
            progress: _lastProgress,
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
      _stall?.cancel();
      _stall = null;
      // Not awaited: awaiting a stream cancel inline can hang under the
      // widget-test fake clock (see the repo's testWidgets stream-cancel
      // note).
      unawaited(_sub?.cancel());
      _sub = null;
      _flashDone = null;
    }
  }

  @override
  Future<void> close() {
    // Dismantle any flash still in the air: stop listening, let the pending
    // attempt unwind, and kill the helper process so no privileged flasher
    // outlives its supervisor.
    //
    // The timer cancel is belt and braces — completing [_flashDone] below
    // unwinds [_flashOnce], whose finally does the real disarm — kept because
    // it costs nothing and the disarm must not depend on that ordering.
    _stall?.cancel();
    unawaited(_sub?.cancel());
    final done = _flashDone;
    if (done != null && !done.isCompleted) done.complete();
    unawaited(_updates.abortPedalFlash());
    return super.close();
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

/// The helper stopped emitting progress for [PedalFirmwareCubit.stallTimeout]
/// and was killed. Carries how far it had got, because the on-disk failure
/// marker cannot classify a stall — the killed helper never wrote one.
class _FlashStalled implements Exception {
  const _FlashStalled(this.lastProgress);

  /// The last progress value the helper reported before going quiet.
  final double lastProgress;

  @override
  String toString() =>
      'update helper stopped responding '
      '(last progress ${(lastProgress * 100).round()}%)';
}
