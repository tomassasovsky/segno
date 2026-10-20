import 'package:segno/looper/model/overdub_decay.dart';

/// An unavailable Decay owner for tests of unrelated controls.
class FakeDecayControl implements DecayControl {
  @override
  DecaySnapshot? get decaySnapshot => null;

  @override
  DecaySnapshot get durableDecaySnapshot =>
      DecaySnapshot(defaultPercent: 0, trackOverrides: const {});

  @override
  DecayLifetime get decayLifetime => (sessionRevision: 0, mixGeneration: 0);

  @override
  int decayRevision(DecayAddress address) => 0;

  @override
  Stream<({DecayAddress address, int? percent})> get ordinaryDecayChanges =>
      const Stream.empty();

  @override
  Future<DecayOutcome> setControllerDecay(
    DecayAddress address,
    int percent, {
    required DecayLifetime lifetime,
    required int revision,
    int? releasedPercent,
  }) async => const DecayOutcome(DecayStatus.rejected);

  @override
  Future<DecayOutcome> setTrackOverdubDecay({
    required int channel,
    required int? percent,
  }) async => const DecayOutcome(DecayStatus.rejected);
}
