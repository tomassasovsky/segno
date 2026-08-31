import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:segno/appliance/power_off/power_off_gate.dart';
import 'package:segno/logging/app_log.dart';

part 'power_off_state.dart';

/// Latch shared with ControlCubit: while the power-off route is up, Rec /
/// overdub / perf-arm are ignored so a take cannot start behind the dialog.
class PowerOffTakeLock {
  /// Whether take-start from the pedal (and the same intent methods) is
  /// suppressed.
  bool locked = false;
}

/// Drives confirm → optional save → goodbye → halt for the rear power button.
///
/// Never calls another cubit. Flush, pedal goodbye, halt, and save are
/// injected closures. Snapshot is passed in at each commit so the gate can
/// be re-checked without this cubit reading live feature state.
class PowerOffCubit extends Cubit<PowerOffState> {
  /// Creates a [PowerOffCubit].
  PowerOffCubit({
    required void Function() flush,
    required void Function() pedalGoodbye,
    required Future<void> Function() powerOff,
    PowerOffTakeLock? takeLock,
    Duration markHold = const Duration(seconds: 2),
  }) : _flush = flush,
       _pedalGoodbye = pedalGoodbye,
       _powerOff = powerOff,
       _takeLock = takeLock ?? PowerOffTakeLock(),
       _markHold = markHold,
       super(const PowerOffState());

  final void Function() _flush;
  final void Function() _pedalGoodbye;
  final Future<void> Function() _powerOff;
  final PowerOffTakeLock _takeLock;
  final Duration _markHold;

  /// A short press of `KEY_POWER`. No-op while any power-off UI is up.
  void press(PowerOffSnapshot snapshot) {
    if (state.isUiUp) return;
    switch (powerOffGate(snapshot)) {
      case PowerOffDisposition.refuse:
        _set(PowerOffPhase.refuse);
      case PowerOffDisposition.confirm:
        _set(PowerOffPhase.confirm);
      case PowerOffDisposition.skip:
        unawaited(_halt());
    }
  }

  /// Drops the power-off route. No-op once halt is committed.
  void keepPlaying() {
    if (!state.isDismissible) return;
    _set(PowerOffPhase.idle);
  }

  /// Save & power off. Unnamed sessions emit [PowerOffPhase.saveAs] for the
  /// host to prompt; named sessions run [save] under the Saving face.
  void saveAndPowerOff(
    PowerOffSnapshot snapshot, {
    Future<void> Function()? save,
  }) {
    if (!_prepareCommit(snapshot)) return;
    if (snapshot.currentSessionName == null) {
      _set(PowerOffPhase.saveAs);
      return;
    }
    unawaited(_saveThenHalt(save));
  }

  /// Discard loops in RAM and halt. Last on-disk save is left alone.
  void powerOffWithoutSaving(PowerOffSnapshot snapshot) {
    if (!_prepareCommit(snapshot)) return;
    unawaited(_halt());
  }

  /// Host is about to write a Save As bundle — show the Saving face.
  void beginSaving() {
    if (state.phase != PowerOffPhase.saveAs) return;
    _set(PowerOffPhase.saving);
  }

  /// The Save As sheet wrote the bundle. Proceed to goodbye.
  void saveCompleted() {
    if (state.phase != PowerOffPhase.saveAs &&
        state.phase != PowerOffPhase.saving) {
      return;
    }
    unawaited(_halt());
  }

  /// Save failed. Stay on the power-off surface; do not halt.
  void saveFailed() {
    if (state.phase != PowerOffPhase.saveAs &&
        state.phase != PowerOffPhase.saving) {
      return;
    }
    _set(PowerOffPhase.saveFailed);
  }

  bool _prepareCommit(PowerOffSnapshot snapshot) {
    if (!state.isDismissible) return false;
    if (powerOffGate(snapshot) == PowerOffDisposition.refuse) {
      _set(PowerOffPhase.refuse);
      return false;
    }
    return true;
  }

  Future<void> _saveThenHalt(Future<void> Function()? save) async {
    _set(PowerOffPhase.saving);
    if (save == null) {
      _set(PowerOffPhase.saveFailed);
      return;
    }
    try {
      await save();
    } on Object catch (error, stack) {
      AppLog.error('power-off save failed', error: error, stack: stack);
      if (isClosed) return;
      _set(PowerOffPhase.saveFailed);
      return;
    }
    if (isClosed) return;
    if (state.phase != PowerOffPhase.saving) return;
    await _halt();
  }

  Future<void> _halt() async {
    _flush();
    _pedalGoodbye();
    _set(PowerOffPhase.goodbye);
    if (_markHold > Duration.zero) {
      await Future<void>.delayed(_markHold);
    }
    if (isClosed) return;
    try {
      await _powerOff();
    } on Object catch (error, stack) {
      // Freeze on the mark. Do not retry.
      AppLog.error('power-off helper failed', error: error, stack: stack);
    }
  }

  void _set(PowerOffPhase phase) {
    _takeLock.locked = phase != PowerOffPhase.idle;
    emit(PowerOffState(phase: phase));
  }
}
