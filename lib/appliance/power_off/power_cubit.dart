import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:clock/clock.dart';
import 'package:equatable/equatable.dart';
import 'package:operation_guards/operation_guards.dart';
import 'package:segno/appliance/power_off/power_gate.dart';
import 'package:segno/appliance/power_off/power_step.dart';
import 'package:segno/logging/app_log.dart';
import 'package:update_repository/update_repository.dart';

export 'package:segno/appliance/power_off/power_step.dart';

part 'power_state.dart';

/// Drives Power options → save → Safe to switch off / Restarting for the
/// rear power button, Settings' Power row and the update's Install and
/// restart.
///
/// Restart and Shut down share one guarded path: refused while a take, an
/// update install or a transfer is in flight; otherwise stop the transport,
/// flush settings, save the session, hold [GuardKind.restart], wait for
/// storage leases, ask the installer again, then reboot or halt. The save
/// reports each of those stages as [PowerState.step], so the Saving face can
/// tick them off. A failed save keeps Segno on (Stay on / Retry); there is no
/// way to halt without saving. An unnamed session with nothing to lose
/// ([PowerSnapshot.sessionHasContent] false) skips only the session write:
/// there is nothing to name and nothing to write.
///
/// The press only sees the app's record of an update. RAUC's own state can
/// outlive it (#1498), so it is asked again once the save has landed, before
/// the goodbye face: an install there refuses with the update refusal
/// instead of showing Restarting or Safe to switch off. The helper asks it
/// once more at the reset itself, and its refusal reads the same way.
///
/// Never calls another cubit. Every step is an injected closure, and the
/// save is handed in at each commit by the host that owns the session.
/// Take-start is suppressed via [PowerState.isUiUp] — ControlCubit reads
/// that flag; there is no shared latch.
class PowerCubit extends Cubit<PowerState> {
  /// Creates a [PowerCubit].
  new({
    required this._stopTransport,
    required this._flush,
    required this._storageSettled,
    required this._guards,
    required this._pedalGoodbye,
    required this._powerOff,
    required this._reboot,
    required this._updateInstalling,
    this._markHold = const Duration(seconds: 2),
  }) : super(const PowerState());

  final void Function() _stopTransport;
  final FutureOr<void> Function({required bool retry}) _flush;
  final Future<void> Function() _storageSettled;
  final GuardRegistry _guards;
  final void Function() _pedalGoodbye;
  final Future<void> Function() _powerOff;
  final Future<void> Function() _reboot;
  final Future<bool> Function() _updateInstalling;
  final Duration _markHold;

  /// The save of the commit in progress, kept for Retry.
  Future<void> Function()? _save;

  /// The name [_save] writes the session under; null when it writes nothing.
  String? _session;

  /// A Retry sent this Save As: its save repairs, as the Retry would have.
  bool _repairOnSaveAs = false;
  OperationGuard? _guard;

  /// Marks the save in progress as slow once [slowSave] has passed.
  Timer? _slowTimer;

  /// How long a halt waits for storage writes and ejects to finish.
  static const Duration storageSettleLimit = Duration(seconds: 30);

  /// How long the save runs before the Saving face shows (owner, #1553). A
  /// faster save goes straight to the goodbye; the largest session measured
  /// on the console writes in about 250 ms.
  static const Duration slowSave = Duration(milliseconds: 500);

  /// A short press of `KEY_POWER`, or Settings' Power row. Opens Power
  /// options, or the refusal while a take, an update install or a transfer
  /// is in flight. No-op while any power UI is up.
  void press(PowerSnapshot snapshot) {
    if (state.isUiUp) return;
    if (_refused(snapshot)) return;
    _set(PowerPhase.options);
  }

  /// Cancel, Keep playing or Stay on: drops the power UI. No-op once the
  /// save is under way.
  void dismiss() {
    if (!state.isDismissible) return;
    _save = null;
    _session = null;
    _repairOnSaveAs = false;
    _set(PowerPhase.idle);
  }

  /// Saves, then reboots. From Power options, or straight from an update's
  /// Install and restart (which has asked already). An empty unnamed
  /// session reboots without a save.
  void restart(
    PowerSnapshot snapshot, {
    required Future<void> Function() save,
  }) => _commit(PowerAction.restart, snapshot, save);

  /// Saves, then halts. From Power options. An empty unnamed session halts
  /// without a save.
  void shutDown(
    PowerSnapshot snapshot, {
    required Future<void> Function() save,
  }) => _commit(PowerAction.shutDown, snapshot, save);

  /// The host named an unnamed session [name]; [save] writes it under that
  /// name.
  void commitSaveAs(
    PowerSnapshot snapshot, {
    required String name,
    required Future<void> Function() save,
  }) {
    if (state.phase != PowerPhase.saveAs) return;
    if (_refused(snapshot)) return;
    _save = save;
    _session = name;
    unawaited(_run(state.action!, retry: _repairOnSaveAs));
  }

  /// Retry after a failed save: the same steps, with the settings flush in
  /// its repairing mode. A commit that chose to write nothing decides again
  /// from [snapshot], so a session that gained content or a name since then
  /// is saved: Save As when unnamed, [save] when named. A session write
  /// already chosen (named, or the Save As name) is kept.
  void retry(PowerSnapshot snapshot, {required Future<void> Function() save}) {
    if (state.phase != PowerPhase.saveFailed || _save == null) return;
    if (_refused(snapshot)) return;
    final action = state.action!;
    if (_save == _nothingToSave && !_decide(action, snapshot, save)) {
      _repairOnSaveAs = true;
      return;
    }
    unawaited(_run(action, retry: true));
  }

  void _commit(
    PowerAction action,
    PowerSnapshot snapshot,
    Future<void> Function() save,
  ) {
    if (state.phase != PowerPhase.idle && state.phase != PowerPhase.options) {
      return;
    }
    if (_refused(snapshot)) return;
    _repairOnSaveAs = false;
    if (!_decide(action, snapshot, save)) return;
    unawaited(_run(action, retry: false));
  }

  /// Chooses the session write for [snapshot]: [save] for a named session,
  /// none for an empty unnamed one. An unnamed session with content goes to
  /// Save As instead, and this returns false.
  bool _decide(
    PowerAction action,
    PowerSnapshot snapshot,
    Future<void> Function() save,
  ) {
    if (snapshot.currentSessionName case final name?) {
      _save = save;
      _session = name;
      return true;
    }
    _session = null;
    if (snapshot.sessionHasContent) {
      _save = null;
      emit(PowerState(phase: PowerPhase.saveAs, action: action));
      return false;
    }
    AppLog.info('power: unnamed session is empty, nothing to save');
    _save = _nothingToSave;
    return true;
  }

  /// The session write of an empty unnamed session: none. Kept as the
  /// commit's save so Retry works after a failed flush or storage settle.
  static Future<void> _nothingToSave() async {}

  bool _refused(PowerSnapshot snapshot) {
    final refusal = powerRefusal(snapshot);
    if (refusal == null) return false;
    _save = null;
    _session = null;
    emit(PowerState(phase: PowerPhase.refuse, refusal: refusal));
    return true;
  }

  Future<void> _run(PowerAction action, {required bool retry}) async {
    final session = _session;
    final watch = clock.stopwatch()..start();
    var slow = false;
    void reach(PowerStep step) {
      if (isClosed) return;
      emit(
        PowerState(
          phase: PowerPhase.saving,
          action: action,
          step: step,
          session: session,
          slow: slow,
        ),
      );
    }

    _slowTimer?.cancel();
    _slowTimer = Timer(slowSave, () {
      if (isClosed || state.phase != PowerPhase.saving) return;
      slow = true;
      reach(state.step!);
    });
    reach(PowerStep.stopPlayback);
    try {
      _stopTransport();
      reach(PowerStep.saveSettings);
      await _flush(retry: retry);
      // An empty unnamed session's save writes nothing, so it has no step.
      if (session != null) reach(PowerStep.writeSession);
      await _save!();
    } on Object catch (error, stack) {
      AppLog.error('power: save failed', error: error, stack: stack);
      if (!isClosed) _set(PowerPhase.saveFailed);
      return;
    }
    if (isClosed) return;
    final savedAt = session == null ? null : clock.now();
    reach(PowerStep.finishOnDisk);
    // Held from here to the end: no take, session write or transfer may
    // start once the session is on disk. Not before, because the session
    // write itself is one of the operations a restart refuses.
    try {
      _guard = _guards.enter(
        GuardKind.restart,
        const GuardScope.internal(),
        purpose: action == PowerAction.restart ? 'restart' : 'shut down',
      );
    } on GuardRefused catch (error) {
      AppLog.warn('power: $error');
      _set(PowerPhase.saveFailed);
      return;
    }
    // Bounded: a lease that is never released must not hold the
    // non-dismissible Saving face forever. Segno stays on instead.
    try {
      await _storageSettled().timeout(storageSettleLimit);
    } on TimeoutException {
      AppLog.warn('power: storage still busy after $storageSettleLimit');
      _guard?.release();
      _guard = null;
      if (!isClosed) _set(PowerPhase.saveFailed);
      return;
    }
    if (isClosed) return;
    // What the slow-save threshold is tuned from. The timer runs on through
    // the installer check: a slow check shows the Saving face rather than
    // a screen that takes no touch and shows nothing.
    AppLog.info('power: saved in ${watch.elapsedMilliseconds} ms');
    if (await _installerBusy()) {
      AppLog.warn('power: the installer reports an update in progress');
      _refuseForUpdate();
      return;
    }
    if (isClosed) return;
    _slowTimer?.cancel();
    _pedalGoodbye();
    emit(
      PowerState(
        phase: PowerPhase.goodbye,
        action: action,
        session: session,
        savedAt: savedAt,
      ),
    );
    if (_markHold > Duration.zero) {
      await Future<void>.delayed(_markHold);
    }
    if (isClosed) return;
    try {
      await (action == PowerAction.restart ? _reboot() : _powerOff());
    } on UpdateInstallingException catch (error) {
      // An install started during the goodbye hold. Nothing was reset, so
      // the face must not stay on Restarting or Safe to switch off. The
      // pedal keeps its goodbye mark until the next restart.
      AppLog.warn('power: $error');
      _refuseForUpdate();
    } on Object catch (error, stack) {
      // The reset did not happen: freeze on the face, do not retry. A reset
      // the system accepted returns, or never returns at all.
      AppLog.error('power: helper failed', error: error, stack: stack);
    }
  }

  /// Whether the installer reports an update in progress. A question that
  /// fails reads as no: the helper asks again at the reset and refuses
  /// there, and the Saving face must not hang on the question.
  Future<bool> _installerBusy() async {
    try {
      return await _updateInstalling();
    } on Object catch (error, stack) {
      AppLog.error('power: installer check failed', error: error, stack: stack);
      return false;
    }
  }

  /// Leaves a committed restart or shutdown for the update refusal: the
  /// session is saved, the restart guard goes, and Segno stays on.
  void _refuseForUpdate() {
    _slowTimer?.cancel();
    _guard?.release();
    _guard = null;
    _save = null;
    _session = null;
    if (isClosed) return;
    emit(
      const PowerState(phase: PowerPhase.refuse, refusal: PowerRefusal.update),
    );
  }

  /// Moves to [phase] outside the save, keeping the commit's action and
  /// session once there is a commit.
  void _set(PowerPhase phase) {
    _slowTimer?.cancel();
    final committed = phase != PowerPhase.idle && phase != PowerPhase.options;
    emit(
      PowerState(
        phase: phase,
        action: committed ? state.action : null,
        session: committed ? _session : null,
      ),
    );
  }

  @override
  Future<void> close() {
    _slowTimer?.cancel();
    _guard?.release();
    return super.close();
  }
}
