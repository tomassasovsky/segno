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
    this.step,
    this.session,
    this.savedAt,
    this.slow = false,
  }) : assert(
         (phase == PowerPhase.refuse) == (refusal != null),
         'a refusal names its reason, and only a refusal has one',
       ),
       assert(
         (phase == PowerPhase.saving) == (step != null),
         'the save names its current step, and only the save has one',
       ),
       assert(!slow || phase == PowerPhase.saving, 'only a save is slow');

  /// Current phase.
  final PowerPhase phase;

  /// The committed action, from Save As onwards; null before a choice.
  final PowerAction? action;

  /// What refused, in [PowerPhase.refuse]; null in every other phase. Kept
  /// from the press, so the refusal does not change its words when what
  /// refused ends while it is up.
  final PowerRefusal? refusal;

  /// The stage the save is in, in [PowerPhase.saving]; null in every other
  /// phase.
  final PowerStep? step;

  /// The name the commit saves the session under, from the commit onwards;
  /// null when nothing is written (an empty unnamed session) and before a
  /// commit.
  final String? session;

  /// When the session write landed, from then on; null until it has, and
  /// when nothing was written.
  final DateTime? savedAt;

  /// The save has run longer than `PowerCubit.slowSave`, so its face shows.
  /// A faster save shows no face before the goodbye.
  final bool slow;

  /// Any power UI is up — extra `KEY_POWER` is ignored.
  bool get isUiUp => phase != PowerPhase.idle;

  /// Scrim / pedal / Cancel / Stay on may abort.
  bool get isDismissible =>
      phase == PowerPhase.refuse ||
      phase == PowerPhase.options ||
      phase == PowerPhase.saveAs ||
      phase == PowerPhase.saveFailed;

  /// The stages this save runs, in order: the session write only when there
  /// is a session to write.
  List<PowerStep> get steps => [
    PowerStep.stopPlayback,
    PowerStep.saveSettings,
    if (session != null) PowerStep.writeSession,
    PowerStep.finishOnDisk,
  ];

  /// The share of [steps] finished, `0..1`; 0 outside [PowerPhase.saving].
  double get progress {
    final current = step;
    if (current == null) return 0;
    final all = steps;
    return all.indexOf(current) / all.length;
  }

  @override
  List<Object?> get props => [
    phase,
    action,
    refusal,
    step,
    session,
    savedAt,
    slow,
  ];
}
