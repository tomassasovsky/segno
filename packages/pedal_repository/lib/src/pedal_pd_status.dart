import 'package:equatable/equatable.dart';

/// What the console can currently establish about its USB-C power inlet.
/// Declaration order is the protocol value; keep it aligned with pedal_link.h.
enum PedalPdState {
  /// No observation has completed yet.
  unknown,

  /// The trigger reports no attached source.
  unattached,

  /// Attached, but no stable explicit PD contract has been observed.
  negotiating,

  /// A stable explicit contract was read while VBUS and the policy were ready.
  contract,

  /// The trigger could not be read or returned an incoherent snapshot.
  readError,

  /// The last observation or board message is too old to trust.
  stale,
}

/// A fresh negotiated request, or an explicit reason it is unavailable.
///
/// This is not measured power consumption. An unknown voltage stays `null`;
/// programmed sink profiles do not establish the accepted source voltage.
final class PedalPdStatus extends Equatable {
  /// A state without a trustworthy contract. No electrical values are retained.
  const PedalPdStatus.unavailable(this.state)
    : assert(state != PedalPdState.contract, 'a contract requires current'),
      currentMilliamps = null,
      voltageMillivolts = null,
      capabilityMismatch = false;

  /// A fixed-supply contract. Voltage may be unobservable on the trigger.
  const PedalPdStatus.contract({
    required int this.currentMilliamps,
    this.voltageMillivolts,
    this.capabilityMismatch = false,
  }) : assert(
         currentMilliamps >= 10 &&
             currentMilliamps <= 5000 &&
             currentMilliamps % 10 == 0,
         'operating current must be 10..5000 mA in 10 mA steps',
       ),
       assert(
         voltageMillivolts == null ||
             (voltageMillivolts >= 5000 &&
                 voltageMillivolts <= 20000 &&
                 voltageMillivolts % 50 == 0),
         'voltage must be unknown or 5000..20000 mV in 50 mV steps',
       ),
       state = PedalPdState.contract;

  /// The observation state.
  final PedalPdState state;

  /// Requested operating current, not the current being consumed.
  final int? currentMilliamps;

  /// Accepted fixed voltage when observable, otherwise `null`.
  final int? voltageMillivolts;

  /// The trigger's request says the source did not meet its capabilities.
  final bool capabilityMismatch;

  /// Checks the wire invariants even in release builds without assertions.
  bool get isValid {
    final current = currentMilliamps;
    final voltage = voltageMillivolts;
    if (state != PedalPdState.contract) {
      return current == null && voltage == null && !capabilityMismatch;
    }
    return current != null &&
        current >= 10 &&
        current <= 5000 &&
        current % 10 == 0 &&
        (voltage == null ||
            (voltage >= 5000 && voltage <= 20000 && voltage % 50 == 0));
  }

  @override
  List<Object?> get props => [
    state,
    currentMilliamps,
    voltageMillivolts,
    capabilityMismatch,
  ];
}
