part of 'power_off_cubit.dart';

/// Where the power-off flow is.
enum PowerOffPhase {
  /// No power-off UI.
  idle,

  /// Take in flight — Keep playing only.
  refuse,

  /// Loops in RAM — three choices.
  confirm,

  /// Host should open Save As.
  saveAs,

  /// Session bundle is writing. Non-cancellable.
  saving,

  /// Pending control/settings writes are settling. Non-cancellable.
  flushing,

  /// Settings could not be confirmed. Retry or keep the appliance on.
  flushFailed,

  /// Plymouth mark on every display. Non-cancellable.
  goodbye,

  /// Save failed. Loops stay in RAM; Keep playing (and retry) stay available.
  saveFailed,
}

/// State of [PowerOffCubit].
class PowerOffState extends Equatable {
  /// Creates a [PowerOffState].
  const PowerOffState({this.phase = PowerOffPhase.idle});

  /// Current phase.
  final PowerOffPhase phase;

  /// Any power-off UI is up — extra `KEY_POWER` is ignored.
  bool get isUiUp => phase != PowerOffPhase.idle;

  /// Scrim / pedal / Keep playing may abort.
  bool get isDismissible =>
      phase == PowerOffPhase.refuse ||
      phase == PowerOffPhase.confirm ||
      phase == PowerOffPhase.saveAs ||
      phase == PowerOffPhase.flushFailed ||
      phase == PowerOffPhase.saveFailed;

  @override
  List<Object?> get props => [phase];
}
