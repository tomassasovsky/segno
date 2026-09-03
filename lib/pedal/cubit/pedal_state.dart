part of 'pedal_cubit.dart';

/// The pedal LINK state: whether the console board is on the other end of the
/// link, and the firmware it announced. Everything else about the pedal —
/// mode, cursor, bank, LEDs — is control state, projected elsewhere.
class PedalState extends Equatable {
  /// Creates a [PedalState].
  const PedalState({
    this.status = PedalLinkStatus.disconnected,
    this.firmwareVersion,
  });

  /// Whether the board is talking.
  final PedalLinkStatus status;

  /// The firmware version the board announced (`major.minor`) while it is
  /// talking, or `null` while it is not.
  final String? firmwareVersion;

  @override
  List<Object?> get props => [status, firmwareVersion];
}
