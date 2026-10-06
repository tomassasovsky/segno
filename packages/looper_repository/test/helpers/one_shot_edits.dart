import 'package:looper_repository/looper_repository.dart';

/// Single-address Loop/Once edits for repository tests, built on the one
/// whole-vector request the repository offers.
extension OneShotEdits on LooperRepository {
  /// Sets or removes ([oneShot] null) one track's override.
  EngineResult setOneShot({
    required int channel,
    required bool? oneShot,
    bool? releasedOneShot,
  }) {
    Map<int, bool> withTrack(Map<int, bool> overrides, {required bool? value}) {
      final next = Map<int, bool>.of(overrides);
      if (value == null) {
        next.remove(channel);
      } else {
        next[channel] = value;
      }
      return next;
    }

    final durable = oneShotRestartIntent;
    return setOneShotSnapshot(
      defaultOneShot: defaultOneShot,
      trackOverrides: withTrack(trackOneShotOverrides, value: oneShot),
      released: (
        defaultOneShot: durable.defaultOneShot,
        trackOverrides: withTrack(
          durable.trackOverrides,
          value: releasedOneShot ?? oneShot,
        ),
      ),
    );
  }

  /// Sets the default inherited by tracks without an override.
  EngineResult setDefaultOneShot({required bool oneShot}) => setOneShotSnapshot(
    defaultOneShot: oneShot,
    trackOverrides: trackOneShotOverrides,
    released: (
      defaultOneShot: oneShot,
      trackOverrides: oneShotRestartIntent.trackOverrides,
    ),
  );
}
