part of 'pedal_cubit.dart';

/// The pedal LINK state: whether the console board is on the other end of the
/// link, the firmware it announced, and what its CTRL jacks report.
/// Everything else about the pedal — mode, cursor, bank, LEDs — is control
/// state, projected elsewhere.
class PedalState extends Equatable {
  /// Creates a [PedalState].
  const PedalState({
    this.status = PedalLinkStatus.disconnected,
    this.firmwareVersion,
    this.ctrl = const {},
    this.calibrating,
    this.calibrationSeen,
    this.calibrated = const {},
  });

  /// Whether the board is talking.
  final PedalLinkStatus status;

  /// The firmware version the board announced (`major.minor`) while it is
  /// talking, or `null` while it is not.
  final String? firmwareVersion;

  /// The last reading from each CTRL control that has reported, so a pedal
  /// can be watched while it is bound. Absent until it sends something: the
  /// board only reports a jack once it has decided what is plugged into it.
  final Map<PedalCtrlInput, PedalCtrlReading> ctrl;

  /// The jack whose expression pedal is being calibrated, or `null`.
  final PedalCtrlJack? calibrating;

  /// The raw ends the pedal has reached so far in that calibration, or
  /// `null` before it has moved.
  final PedalCtrlCalibration? calibrationSeen;

  /// The jacks with a calibration the user made, as opposed to ends learned
  /// from the pedal.
  final Set<PedalCtrlJack> calibrated;

  /// A copy with the given fields replaced. Nullable fields take a thunk so
  /// that "set to null" and "leave alone" are different calls.
  PedalState copyWith({
    PedalLinkStatus? status,
    String? Function()? firmwareVersion,
    Map<PedalCtrlInput, PedalCtrlReading>? ctrl,
    PedalCtrlJack? Function()? calibrating,
    PedalCtrlCalibration? Function()? calibrationSeen,
    Set<PedalCtrlJack>? calibrated,
  }) => PedalState(
    status: status ?? this.status,
    firmwareVersion: firmwareVersion != null
        ? firmwareVersion()
        : this.firmwareVersion,
    ctrl: ctrl ?? this.ctrl,
    calibrating: calibrating != null ? calibrating() : this.calibrating,
    calibrationSeen: calibrationSeen != null
        ? calibrationSeen()
        : this.calibrationSeen,
    calibrated: calibrated ?? this.calibrated,
  );

  @override
  List<Object?> get props => [
    status,
    firmwareVersion,
    ctrl,
    calibrating,
    calibrationSeen,
    calibrated,
  ];
}

/// What a CTRL control last reported.
class PedalCtrlReading extends Equatable {
  /// Creates a [PedalCtrlReading].
  const PedalCtrlReading({required this.kind, required this.value, int? raw})
    : raw = raw ?? value;

  /// What the board decided is plugged into the jack.
  final PedalCtrlKind kind;

  /// `0`..`255`: a switch reports the ends, an expression pedal its travel
  /// between the ends known for it.
  final int value;

  /// What the board read, before calibration. Equal to [value] for a switch.
  final int raw;

  /// The travel as a percentage, for display.
  int get percent => (value * 100 / 255).round();

  /// The raw position as a percentage of the whole scale, for calibrating.
  int get rawPercent => (raw * 100 / 255).round();

  @override
  List<Object?> get props => [kind, value, raw];
}
