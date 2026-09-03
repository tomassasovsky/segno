part of 'pedal_cubit.dart';

/// The pedal LINK state: whether the console board is on the other end of the
/// link, and the firmware it announced. Everything else about the pedal —
/// mode, cursor, bank, LEDs — is control state, projected elsewhere.
class PedalState extends Equatable {
  /// Creates a [PedalState].
  const PedalState({
    this.status = PedalLinkStatus.disconnected,
    this.firmwareVersion,
    this.ctrl = const {},
  });

  /// Whether the board is talking.
  final PedalLinkStatus status;

  /// The firmware version the board announced (`major.minor`) while it is
  /// talking, or `null` while it is not.
  final String? firmwareVersion;

  /// The last reading from each CTRL jack that has reported, so a pedal can
  /// be watched while it is bound. Absent until a jack sends something: the
  /// board only reports a jack once it has decided what is plugged into it.
  final Map<PedalCtrlJack, PedalCtrlReading> ctrl;

  @override
  List<Object?> get props => [status, firmwareVersion, ctrl];
}

/// What a CTRL jack last reported.
class PedalCtrlReading extends Equatable {
  /// Creates a [PedalCtrlReading].
  const PedalCtrlReading({required this.kind, required this.value});

  /// What the board decided is plugged into the jack.
  final PedalCtrlKind kind;

  /// `0`..`255`: a switch reports the ends, an expression pedal its travel.
  final int value;

  /// The travel as a percentage, for display.
  int get percent => (value * 100 / 255).round();

  @override
  List<Object?> get props => [kind, value];
}
