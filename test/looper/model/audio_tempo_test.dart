import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/looper/model/audio_tempo.dart';

void main() {
  group('InheritSnapshot (#1179)', () {
    final snapshot = InheritSnapshot(
      defaultValue: PitchMode.unchanged,
      trackOverrides: const {2: PitchMode.followsSpeed},
    );

    test('a track inherits the default unless it overrides it', () {
      expect(snapshot.effective(2), PitchMode.followsSpeed);
      expect(snapshot.effective(3), PitchMode.unchanged);
      expect(
        snapshot.at(const AudioTempoAddress.defaults()),
        PitchMode.unchanged,
      );
      expect(snapshot.at(const AudioTempoAddress.track(3)), isNull);
    });

    test('withValue sets the default, sets an override, and null removes '
        'only that override', () {
      final changed = snapshot
          .withValue(const AudioTempoAddress.defaults(), PitchMode.followsSpeed)
          .withValue(const AudioTempoAddress.track(5), PitchMode.unchanged)
          .withValue(const AudioTempoAddress.track(2), null);
      expect(changed.defaultValue, PitchMode.followsSpeed);
      expect(changed.trackOverrides, {5: PitchMode.unchanged});
      expect(snapshot.trackOverrides, {2: PitchMode.followsSpeed});
    });

    test('a null default or a track past the eighth is refused', () {
      expect(
        () => snapshot.withValue(const AudioTempoAddress.defaults(), null),
        throwsArgumentError,
      );
      expect(
        () => snapshot.withValue(
          const AudioTempoAddress.track(8),
          PitchMode.unchanged,
        ),
        throwsArgumentError,
      );
      expect(const AudioTempoAddress.track(-1).isValid, isFalse);
    });

    test('value equality covers the default and the overrides', () {
      expect(
        snapshot,
        InheritSnapshot(
          defaultValue: PitchMode.unchanged,
          trackOverrides: const {2: PitchMode.followsSpeed},
        ),
      );
      expect(
        snapshot,
        isNot(
          InheritSnapshot(
            defaultValue: PitchMode.unchanged,
            trackOverrides: const <int, PitchMode>{},
          ),
        ),
      );
    });
  });
}
