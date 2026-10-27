import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:operation_guards/operation_guards.dart';
import 'package:segno/appliance/power_off/power_gate.dart';
import 'package:segno/logging/app_log.dart';

part 'power_state.dart';

/// Drives Power options → save → Safe to switch off / Restarting for the
/// rear power button, Settings' Power row and the update's Install and
/// restart.
///
/// Restart and Shut down share one guarded path: refused while a take, an
/// update install or a transfer is in flight; otherwise stop the transport,
/// flush settings, save the session, hold [GuardKind.restart], wait for
/// storage leases, then reboot or halt. A failed save keeps Segno on (Stay
/// on / Retry); there is no way to halt without saving. An unnamed session with nothing to lose
/// ([PowerSnapshot.sessionHasContent] false) skips only the session write:
/// there is nothing to name and nothing to write.
///
/// Never calls another cubit. Every step is an injected closure, and the
/// save is handed in at each commit by the host that owns the session.
/// Take-start is suppressed via [PowerState.isUiUp] — ControlCubit reads
/// that flag; there is no shared latch.
class PowerCubit extends Cubit<PowerState> {
  /// Creates a [PowerCubit].
  PowerCubit({
    required void Function() stopTransport,
    required FutureOr<void> Function({required bool retry}) flush,
    required Future<void> Function() storageSettled,
    required GuardRegistry guards,
    required void Function() pedalGoodbye,
    required Future<void> Function() powerOff,
    required Future<void> Function() reboot,
    Duration markHold = const Duration(seconds: 2),
  }) : _stopTransport = stopTransport,
       _flush = flush,
       _storageSettled = storageSettled,
       _guards = guards,
       _pedalGoodbye = pedalGoodbye,
       _powerOff = powerOff,
       _reboot = reboot,
       _markHold = markHold,
       super(const PowerState());

  final void Function() _stopTransport;
  final FutureOr<void> Function({required bool retry}) _flush;
  final Future<void> Function() _storageSettled;
  final GuardRegistry _guards;
  final void Function() _pedalGoodbye;
  final Future<void> Function() _powerOff;
  final Future<void> Function() _reboot;
  final Duration _markHold;

  /// The save of the commit in progress, kept for Retry.
  Future<void> Function()? _save;

  /// A Retry sent this Save As: its save repairs, as the Retry would have.
  bool _repairOnSaveAs = false;
  OperationGuard? _guard;

  /// How long a halt waits for storage writes and ejects to finish.
  static const Duration storageSettleLimit = Duration(seconds: 30);

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

  /// The host named an unnamed session; [save] writes it under that name.
  void commitSaveAs(
    PowerSnapshot snapshot, {
    required Future<void> Function() save,
  }) {
    if (state.phase != PowerPhase.saveAs) return;
    if (_refused(snapshot)) return;
    _save = save;
    unawaited(_run(state.action!, retry: _repairOnSaveAs));
  }

  /// Retry after a failed save: the same steps, with the settings flush in
  /// its repairing mode. A commit that chose to write nothing decides again
  /// from [snapshot], so a session that gained content or a name since then
  /// is saved: Save As when unnamed, [save] when named. A session write
  /// already chosen (named, or the Save As name) is kept.
  void retry(
    PowerSnapshot snapshot, {
    required Future<void> Function() save,
  }) {
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
    if (snapshot.currentSessionName != null) {
      _save = save;
      return true;
    }
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
    emit(PowerState(phase: PowerPhase.refuse, refusal: refusal));
    return true;
  }

  Future<void> _run(PowerAction action, {required bool retry}) async {
    emit(PowerState(phase: PowerPhase.saving, action: action));
    try {
      _stopTransport();
      await _flush(retry: retry);
      await _save!();
    } on Object catch (error, stack) {
      AppLog.error('power: save failed', error: error, stack: stack);
      if (!isClosed) _set(PowerPhase.saveFailed);
      return;
    }
    if (isClosed) return;
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
    _pedalGoodbye();
    _set(PowerPhase.goodbye);
    if (_markHold > Duration.zero) {
      await Future<void>.delayed(_markHold);
    }
    if (isClosed) return;
    try {
      await (action == PowerAction.restart ? _reboot() : _powerOff());
    } on Object catch (error, stack) {
      // Freeze on the face. Do not retry.
      AppLog.error('power: helper failed', error: error, stack: stack);
    }
  }

  void _set(PowerPhase phase) {
    emit(
      PowerState(
        phase: phase,
        action: phase == PowerPhase.idle || phase == PowerPhase.options
            ? null
            : state.action,
      ),
    );
  }

  @override
  Future<void> close() {
    _guard?.release();
    return super.close();
  }
}
