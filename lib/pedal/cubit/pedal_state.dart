part of 'pedal_cubit.dart';

/// Link status, raw physical readings and the canonical LED frame.
class PedalState extends Equatable {
  const PedalState({
    this.status = PedalLinkStatus.disconnected,
    this.firmwareVersion,
    this.protocolVersion,
    this.frame,
    this.ctrl = const {},
  });
  final PedalLinkStatus status;
  final String? firmwareVersion;

  /// The link protocol the board's hello names, or null while it is quiet.
  final int? protocolVersion;
  final PedalStateFrame? frame;
  final Map<PedalCtrlInput, PedalCtrlReading> ctrl;
  PedalState copyWith({
    PedalLinkStatus? status,
    PedalStateFrame? frame,
    String? Function()? firmwareVersion,
    int? Function()? protocolVersion,
    Map<PedalCtrlInput, PedalCtrlReading>? ctrl,
  }) => PedalState(
    status: status ?? this.status,
    frame: frame ?? this.frame,
    firmwareVersion: firmwareVersion != null
        ? firmwareVersion()
        : this.firmwareVersion,
    protocolVersion: protocolVersion != null
        ? protocolVersion()
        : this.protocolVersion,
    ctrl: ctrl ?? this.ctrl,
  );
  @override
  List<Object?> get props => [
    status,
    firmwareVersion,
    protocolVersion,
    frame,
    ctrl,
  ];
}

/// What a CTRL control last reported.
class PedalCtrlReading extends Equatable {
  /// Creates a [PedalCtrlReading].
  const PedalCtrlReading({required this.kind, required this.value});

  /// What the board decided is plugged into the jack.
  final PedalCtrlKind kind;

  /// The exact `0..255` physical sample; no calibration is applied here.
  final int value;

  /// What the board read, before application calibration.
  int get raw => value;

  /// The travel as a percentage, for display.
  int get percent => (value * 100 / 255).round();

  /// The raw position as a percentage of the whole scale, for calibrating.
  int get rawPercent => (raw * 100 / 255).round();

  @override
  List<Object?> get props => [kind, value];
}
