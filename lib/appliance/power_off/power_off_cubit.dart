import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:segno/appliance/power_off/power_off_gate.dart';
import 'package:segno/logging/app_log.dart';

part 'power_off_state.dart';

/// Drives confirm → optional save → goodbye → halt for the rear power button.
///
/// Never calls another cubit. Flush, pedal goodbye, halt, and save are
/// injected closures. Snapshot is passed in at each commit so the gate can
/// be re-checked without this cubit reading live feature state.
///
/// Take-start is suppressed via [PowerOffState.isUiUp] — ControlCubit reads
/// that flag; there is no shared latch.
class PowerOffCubit extends Cubit<PowerOffState> {
  /// Creates a [PowerOffCubit].
  PowerOffCubit({
    required void Function() flush,
    required void Function() pedalGoodbye,
    required Future<void> Function() powerOff,
    Duration markHold = const Duration(seconds: 2),
  }) : _flush = flush,
       _pedalGoodbye = pedalGoodbye,
       _powerOff = powerOff,
       _markHold = markHold,
       super(const PowerOffState());

  final void Function() _flush;
  final void Function() _pedalGoodbye;
  final Future<void> Function() _powerOff;
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
    if (save == null) {
      _set(PowerOffPhase.saveFailed);
      return;
    }
    unawaited(_saveThenHalt(save));
  }

  /// Discard loops in RAM and halt. Last on-disk save is left alone.
  void powerOffWithoutSaving(PowerOffSnapshot snapshot) {
    if (!_prepareCommit(snapshot)) return;
    unawaited(_halt());
  }

  /// Host finished naming an unnamed session. Runs [save] under Saving.
  void commitSave(
    PowerOffSnapshot snapshot,
    Future<void> Function() save,
  ) {
    if (state.phase != PowerOffPhase.saveAs) return;
    if (!_prepareCommit(snapshot)) return;
    unawaited(_saveThenHalt(save));
  }

  bool _prepareCommit(PowerOffSnapshot snapshot) {
    if (!state.isDismissible) return false;
    if (powerOffGate(snapshot) == PowerOffDisposition.refuse) {
      _set(PowerOffPhase.refuse);
      return false;
    }
    return true;
  }

  Future<void> _saveThenHalt(Future<void> Function() save) async {
    _set(PowerOffPhase.saving);
    try {
      await save();
    } on Object catch (error, stack) {
      AppLog.error('power-off save failed', error: error, stack: stack);
      if (isClosed) return;
      _set(PowerOffPhase.saveFailed);
      return;
    }
    if (isClosed) return;
    await _halt();
  }

  Future<void> _halt() async {
    try {
      _flush();
    } on Object catch (error, stack) {
      AppLog.error('power-off flush failed', error: error, stack: stack);
    }
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
    emit(PowerOffState(phase: phase));
  }
}
