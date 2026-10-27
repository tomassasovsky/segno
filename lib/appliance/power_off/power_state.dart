part of 'power_cubit.dart';

/// What the person chose on Power options.
enum PowerAction {
  /// Save, then reboot (into a staged update when one is staged).
  restart,

  /// Save, then halt.
  shutDown,
}

/// Where the power flow is.
enum PowerPhase {
  /// No power UI.
  idle,

  /// A take, an update or a transfer in flight ([PowerState.refusal]) —
  /// Keep playing only.
  refuse,

  /// Power options: Cancel / Restart / Shut down.
  options,

  /// Host should open Save As for an unnamed session.
  saveAs,

  /// Transport stopping, settings flushing, session writing, storage
  /// settling. Non-cancellable.
  saving,

  /// The save did not complete. Segno stays on; Stay on or Retry.
  saveFailed,

  /// Safe to switch off, or Restarting. Non-cancellable.
  goodbye,
}

/// State of [PowerCubit].
class PowerState extends Equatable {
  /// Creates a [PowerState].
  const PowerState({
    this.phase = PowerPhase.idle,
    this.action,
    this.refusal,
  });

  /// Current phase.
  final PowerPhase phase;

  /// The committed action, from Save As onwards; null before a choice.
  final PowerAction? action;

  /// What refused, in [PowerPhase.refuse]; null in every other phase. Kept
  /// from the press, so the refusal does not change its words when what
  /// refused ends while it is up.
  final PowerRefusal? refusal;

  /// Any power UI is up — extra `KEY_POWER` is ignored.
  bool get isUiUp => phase != PowerPhase.idle;

  /// Scrim / pedal / Cancel / Stay on may abort.
  bool get isDismissible =>
      phase == PowerPhase.refuse ||
      phase == PowerPhase.options ||
      phase == PowerPhase.saveAs ||
      phase == PowerPhase.saveFailed;

  @override
  List<Object?> get props => [phase, action, refusal];
}
