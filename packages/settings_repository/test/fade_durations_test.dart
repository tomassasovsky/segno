import 'package:flutter_test/flutter_test.dart';
import 'package:settings_repository/settings_repository.dart';

void main() {
  group(FadeDurations, () {
    test('detaches Custom membership and round-trips exact boundaries', () {
      final overrides = {0: 4000, 7: 30000};
      final value = FadeDurations(overrides: overrides);
      overrides.clear();
      expect(value.overrides, {0: 4000, 7: 30000});
      expect(FadeDurations.fromJson(value.toJson()), value);
      expect(value.hashCode, FadeDurations.fromJson(value.toJson()).hashCode);
      expect(FadeDurations(defaultMs: 500).effectiveMs(1), 500);
      expect(() => value.overrides[1] = 500, throwsUnsupportedError);
    });

    test(
      'rejects malformed values and noncanonical channels without coercion',
      () {
        for (final invalid in [0, 499, 501, 30001, 500.0, '500', double.nan]) {
          expect(
            () => FadeDurations.fromJson({
              'defaultMs': invalid,
              'overrides': const <String, dynamic>{},
            }),
            throwsFormatException,
          );
          expect(
            () => FadeDurations.fromJson({
              'defaultMs': 4000,
              'overrides': {'0': invalid},
            }),
            throwsFormatException,
          );
        }
        for (final key in ['-1', '8', '00', ' 0', 'x']) {
          expect(
            () => FadeDurations.fromJson({
              'defaultMs': 4000,
              'overrides': {key: 4000},
            }),
            throwsFormatException,
          );
        }
        for (final invalid in [
          null,
          <String, dynamic>{},
          {'defaultMs': 4000},
        ]) {
          expect(() => FadeDurations.fromJson(invalid), throwsFormatException);
        }
        expect(
          () => FadeDurations.defaults.effectiveMs(8),
          throwsFormatException,
        );
      },
    );
  });
}
