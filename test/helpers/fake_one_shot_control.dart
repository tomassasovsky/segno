import 'package:segno/looper/model/one_shot.dart';

/// An unavailable OneShot owner for tests of unrelated controls.
class FakeOneShotControl implements OneShotControl {
  @override
  OneShotSnapshot? get oneShotSnapshot => null;

  @override
  OneShotSnapshot get durableOneShotSnapshot =>
      OneShotSnapshot(defaultOneShot: false, trackOverrides: const {});

  @override
  OneShotLifetime get oneShotLifetime => (sessionRevision: 0, mixGeneration: 0);

  @override
  int oneShotRevision(OneShotAddress address) => 0;

  @override
  Stream<({OneShotAddress address, bool? oneShot})>
  get ordinaryOneShotChanges => const Stream.empty();

  @override
  Future<OneShotOutcome> setControllerOneShot(
    OneShotAddress address, {
    required bool oneShot,
    required OneShotLifetime lifetime,
    required int revision,
    bool? releasedOneShot,
  }) async => const OneShotOutcome(OneShotStatus.rejected);

  @override
  Future<OneShotOutcome> setTrackOneShot({
    required int channel,
    required bool? oneShot,
  }) async => const OneShotOutcome(OneShotStatus.rejected);
}
