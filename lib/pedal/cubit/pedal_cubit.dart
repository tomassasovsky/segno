import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:settings_repository/settings_repository.dart';

part 'pedal_state.dart';

/// The pedal LINK feature: whether the console board is talking, what
/// firmware it announced, and what its CTRL jacks are reporting — plus the
/// calibration of an expression pedal on one, which is the one thing about a
/// CTRL jack a user decides.
///
/// The pedal's BEHAVIOR — decoding footswitch events into intents and
/// pushing projected LED frames — is `ControlCubit`'s job: both cubits sit
/// on the shared [PedalRepository] (events in / frames out for control,
/// status for this one) and know nothing about each other.
class PedalCubit extends Cubit<PedalState> {
  /// Creates a [PedalCubit].
  ///
  /// [settings] keeps each jack's calibration across restarts; without it
  /// (tests, a desktop with no board) calibrations last the session.
  PedalCubit({required PedalRepository pedal, SettingsRepository? settings})
    : _pedal = pedal,
      _settings = settings,
      super(
        PedalState(
          status: pedal.status,
          firmwareVersion: pedal.firmwareVersion,
        ),
      ) {
    _statusSub = _pedal.statusChanges.listen(_onStatus);
    _eventsSub = _pedal.events.listen(_onEvent);
    _initialLoad = _loadCalibrations();
  }

  final PedalRepository _pedal;
  final SettingsRepository? _settings;
  late final StreamSubscription<PedalLinkStatus> _statusSub;
  late final StreamSubscription<PedalEvent> _eventsSub;
  late final Future<void> _initialLoad;
  Future<void>? _pendingWrite;
  bool _closing = false;

  bool get _inactive => _closing || isClosed;

  Future<void> _loadCalibrations() async {
    final settings = _settings;
    if (settings == null) return;
    final calibrated = <PedalCtrlJack>{};
    var failed = false;
    for (final jack in PedalCtrlJack.values) {
      if (_inactive) return;
      (int, int)? stored;
      try {
        stored = await settings.loadCtrlCalibration(jack.index);
      } on Object {
        failed = true;
        continue;
      }
      if (_inactive) return;
      if (stored == null) continue;
      final (min, max) = stored;
      if (min < 0 || max > 255 || min > max) continue;
      _pedal.setCtrlCalibration(
        jack,
        PedalCtrlCalibration(min: min, max: max),
      );
      calibrated.add(jack);
    }
    if (_inactive) return;
    emit(
      state.copyWith(
        calibrated: {...state.calibrated, ...calibrated},
        calibrationError: () => failed ? PedalCalibrationError.load : null,
      ),
    );
  }

  void _onStatus(PedalLinkStatus status) {
    if (_inactive) return;
    emit(
      state.copyWith(
        status: status,
        firmwareVersion: () => _pedal.firmwareVersion,
      ),
    );
  }

  /// Keeps the last reading from each CTRL control, so a pedal can be watched
  /// while it is bound — and, while one is being calibrated, the raw ends it
  /// has reached. Only CTRL events land here: the footswitches and the
  /// encoder are the control cubit's.
  void _onEvent(PedalEvent event) {
    if (_inactive || event is! CtrlChanged) return;
    if (event.kind == PedalCtrlKind.none) {
      // The plug came out: every row of the jack goes, and a calibration in
      // progress on it is abandoned — there is no pedal to sweep any more.
      final gone = state.calibrating == event.jack;
      emit(
        state.copyWith(
          ctrl: {...state.ctrl}
            ..removeWhere((input, _) => input.jack == event.jack),
          calibrating: gone ? () => null : null,
          calibrationSeen: gone ? () => null : null,
        ),
      );
      return;
    }
    final calibrating = state.calibrating;
    var seen = state.calibrationSeen;
    if (calibrating != null &&
        event.jack == calibrating &&
        event.contact == PedalCtrlContact.tip &&
        event.kind == PedalCtrlKind.expression) {
      seen = seen == null
          ? PedalCtrlCalibration(min: event.raw, max: event.raw)
          : seen.including(event.raw);
    }
    // A pot's ring is its supply, not a switch: a footswitch-B row on a jack
    // that turns out to hold an expression pedal was the plug brushing past.
    final ctrl = {...state.ctrl};
    if (event.contact == PedalCtrlContact.tip &&
        event.kind == PedalCtrlKind.expression) {
      ctrl.remove(PedalCtrlInput(event.jack, PedalCtrlContact.ring));
    }
    ctrl[event.input] = PedalCtrlReading(
      kind: event.kind,
      value: event.value,
      raw: event.raw,
    );
    emit(state.copyWith(ctrl: ctrl, calibrationSeen: () => seen));
  }

  /// Starts calibrating the expression pedal on [jack]: from here until
  /// [finishCtrlCalibration] the lowest and highest raw readings it reaches
  /// are collected as its ends. One jack at a time.
  void beginCtrlCalibration(PedalCtrlJack jack) {
    if (_inactive || state.calibrationBusy) return;
    emit(
      state.copyWith(
        calibrating: () => jack,
        calibrationSeen: () => null,
        calibrationError: () => null,
      ),
    );
  }

  /// Ends the calibration and keeps what was seen, if the pedal was swept
  /// far enough to trust ([PedalCtrlCalibration.isUsable]); otherwise the
  /// session simply ends and the jack stays as it was. Persisted.
  Future<void> finishCtrlCalibration() async {
    if (_inactive || state.calibrationBusy) return;
    final jack = state.calibrating;
    final seen = state.calibrationSeen;
    if (jack == null) return;
    if (seen == null || !seen.isUsable) {
      cancelCtrlCalibration();
      return;
    }
    emit(state.copyWith(calibrationBusy: true, calibrationError: () => null));
    try {
      // A late startup read must never replace the user's newer choice.
      await _initialLoad;
      if (_inactive) return;
      _pendingWrite = _settings?.saveCtrlCalibration(
        jack.index,
        min: seen.min,
        max: seen.max,
      );
      await _pendingWrite;
      if (_inactive) return;
      _pedal.setCtrlCalibration(jack, seen);
      emit(
        state.copyWith(
          calibrating: () => null,
          calibrationSeen: () => null,
          calibrated: {...state.calibrated, jack},
          calibrationError: () => null,
        ),
      );
    } on Object {
      if (!_inactive) {
        emit(
          state.copyWith(calibrationError: () => PedalCalibrationError.save),
        );
      }
    } finally {
      _pendingWrite = null;
      if (!_inactive) emit(state.copyWith(calibrationBusy: false));
    }
  }

  /// Abandons a calibration in progress; nothing changes.
  void cancelCtrlCalibration() {
    if (_inactive || state.calibrationBusy || state.calibrating == null) return;
    emit(
      state.copyWith(
        calibrating: () => null,
        calibrationSeen: () => null,
        calibrationError: () => null,
      ),
    );
  }

  /// Forgets [jack]'s calibration: its ends are learned from the pedal again.
  Future<void> resetCtrlCalibration(PedalCtrlJack jack) async {
    if (_inactive || state.calibrationBusy) return;
    emit(state.copyWith(calibrationBusy: true, calibrationError: () => null));
    try {
      await _initialLoad;
      if (_inactive) return;
      _pendingWrite = _settings?.clearCtrlCalibration(jack.index);
      await _pendingWrite;
      if (_inactive) return;
      _pedal.setCtrlCalibration(jack, null);
      emit(
        state.copyWith(
          calibrated: {...state.calibrated}..remove(jack),
          calibrationError: () => null,
        ),
      );
    } on Object {
      if (!_inactive) {
        emit(
          state.copyWith(calibrationError: () => PedalCalibrationError.reset),
        );
      }
    } finally {
      _pendingWrite = null;
      if (!_inactive) emit(state.copyWith(calibrationBusy: false));
    }
  }

  @override
  Future<void> close() async {
    _closing = true;
    // Storage has no cancellation API. Finish an already-started write before
    // releasing the repository; a mutation still waiting for load never starts.
    try {
      await _pendingWrite;
    } on Object {
      // The mutation handles failure; shutdown must still release the link.
    }
    await _statusSub.cancel();
    await _eventsSub.cancel();
    // Darken the console on shutdown, then release the link — this cubit is
    // the pedal repository's lifecycle owner.
    _pedal.goodbye();
    await _pedal.dispose();
    return super.close();
  }
}
