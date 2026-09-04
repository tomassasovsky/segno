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
    unawaited(_loadCalibrations());
  }

  final PedalRepository _pedal;
  final SettingsRepository? _settings;
  late final StreamSubscription<PedalLinkStatus> _statusSub;
  late final StreamSubscription<PedalEvent> _eventsSub;

  Future<void> _loadCalibrations() async {
    final settings = _settings;
    if (settings == null) return;
    final calibrated = <PedalCtrlJack>{};
    for (final jack in PedalCtrlJack.values) {
      final stored = await settings.loadCtrlCalibration(jack.index);
      if (stored == null) continue;
      final (min, max) = stored;
      if (min < 0 || max > 255 || min > max) continue;
      _pedal.setCtrlCalibration(
        jack,
        PedalCtrlCalibration(min: min, max: max),
      );
      calibrated.add(jack);
    }
    if (isClosed || calibrated.isEmpty) return;
    emit(state.copyWith(calibrated: {...state.calibrated, ...calibrated}));
  }

  void _onStatus(PedalLinkStatus status) {
    if (isClosed) return;
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
    if (isClosed || event is! CtrlChanged) return;
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
    emit(
      state.copyWith(
        ctrl: {
          ...state.ctrl,
          event.input: PedalCtrlReading(
            kind: event.kind,
            value: event.value,
            raw: event.raw,
          ),
        },
        calibrationSeen: () => seen,
      ),
    );
  }

  /// Starts calibrating the expression pedal on [jack]: from here until
  /// [finishCtrlCalibration] the lowest and highest raw readings it reaches
  /// are collected as its ends. One jack at a time.
  void beginCtrlCalibration(PedalCtrlJack jack) {
    if (isClosed) return;
    emit(state.copyWith(calibrating: () => jack, calibrationSeen: () => null));
  }

  /// Ends the calibration and keeps what was seen, if the pedal was swept
  /// far enough to trust ([PedalCtrlCalibration.isUsable]); otherwise the
  /// session simply ends and the jack stays as it was. Persisted.
  Future<void> finishCtrlCalibration() async {
    final jack = state.calibrating;
    final seen = state.calibrationSeen;
    if (jack == null) return;
    if (seen == null || !seen.isUsable) {
      cancelCtrlCalibration();
      return;
    }
    _pedal.setCtrlCalibration(jack, seen);
    if (isClosed) return;
    emit(
      state.copyWith(
        calibrating: () => null,
        calibrationSeen: () => null,
        calibrated: {...state.calibrated, jack},
      ),
    );
    await _settings?.saveCtrlCalibration(
      jack.index,
      min: seen.min,
      max: seen.max,
    );
  }

  /// Abandons a calibration in progress; nothing changes.
  void cancelCtrlCalibration() {
    if (isClosed || state.calibrating == null) return;
    emit(state.copyWith(calibrating: () => null, calibrationSeen: () => null));
  }

  /// Forgets [jack]'s calibration: its ends are learned from the pedal again.
  Future<void> resetCtrlCalibration(PedalCtrlJack jack) async {
    _pedal.setCtrlCalibration(jack, null);
    if (isClosed) return;
    emit(state.copyWith(calibrated: {...state.calibrated}..remove(jack)));
    await _settings?.clearCtrlCalibration(jack.index);
  }

  @override
  Future<void> close() async {
    await _statusSub.cancel();
    await _eventsSub.cancel();
    // Darken the console on shutdown, then release the link — this cubit is
    // the pedal repository's lifecycle owner.
    _pedal.goodbye();
    await _pedal.dispose();
    return super.close();
  }
}
