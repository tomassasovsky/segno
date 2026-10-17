import 'package:equatable/equatable.dart';

/// Whether the USB-C PD trigger's NVM holds the console profile, as the
/// console board found it at boot (`PEDAL_PD_PROFILE_*`). Declaration order is
/// the wire value.
enum PedalPowerProfile {
  /// The trigger did not answer on the board's I2C connector.
  notRead,

  /// The NVM already held the console profile.
  matches,

  /// It did not; the board wrote the profile and read it back. It governs the
  /// next negotiation, after the console is unplugged and plugged back in.
  written,

  /// The board tried to write the profile and the read-back did not match.
  writeFailed,
}

/// What the console's USB-C supply negotiated, as the console board reports
/// it once a second (`PdStatusMessage`).
class PedalPowerSupply extends Equatable {
  /// Creates a [PedalPowerSupply].
  const PedalPowerSupply({
    required this.profile,
    this.millivolts = 0,
    this.milliamps = 0,
    this.maxMilliamps = 0,
    this.mismatch = false,
  });

  /// Whether the trigger holds the console profile.
  final PedalPowerProfile profile;

  /// The negotiated voltage; 0 without a PD contract.
  final int millivolts;

  /// The current the console requested and the source granted; 0 without a
  /// PD contract.
  final int milliamps;

  /// The most the source offers at [millivolts].
  final int maxMilliamps;

  /// The source could not meet any of the console's PDOs.
  final bool mismatch;

  /// Whether there is a PD contract at all.
  bool get contracted => milliamps > 0 && millivolts > 0;

  /// The contract's power in watts.
  double get watts => millivolts * milliamps / 1e6;

  /// What the source offers at [millivolts], in watts: the most a fresh
  /// contract can take.
  double get offeredWatts => millivolts * maxMilliamps / 1e6;

  /// The trigger holds the profile that takes all the current the source
  /// offers, but the contract in force predates it: the source offers more
  /// than was requested. Only a new negotiation, at the trigger's next
  /// power-up, takes the rest.
  bool get needsPowerCycle =>
      contracted &&
      milliamps < maxMilliamps &&
      (profile == PedalPowerProfile.matches ||
          profile == PedalPowerProfile.written);

  @override
  List<Object?> get props => [
    profile,
    millivolts,
    milliamps,
    maxMilliamps,
    mismatch,
  ];

  @override
  String toString() =>
      'PedalPowerSupply(${profile.name}, $millivolts mV, $milliamps of '
      '$maxMilliamps mA${mismatch ? ', mismatch' : ''})';
}
