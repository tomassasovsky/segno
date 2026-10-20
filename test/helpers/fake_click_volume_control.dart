import 'package:segno/looper/model/click_volume.dart';

/// An explicitly unavailable Click owner for tests of unrelated controls.
/// Click transaction tests provide the real application owner instead.
class FakeClickVolumeControl implements ClickVolumeControl {
  @override
  double? get clickVolume => null;

  @override
  double get durableClickVolume => 1;

  @override
  ClickVolumeLifetime get clickVolumeLifetime =>
      (sessionRevision: 0, mixGeneration: 0);

  @override
  Stream<double> get ordinaryClickVolumeChanges => const Stream.empty();

  @override
  Future<ClickVolumeOutcome> setControllerClickVolume(
    double volume, {
    required ClickVolumeLifetime lifetime,
    double? releasedVolume,
  }) async => const ClickVolumeOutcome(ClickVolumeStatus.rejected);
}
