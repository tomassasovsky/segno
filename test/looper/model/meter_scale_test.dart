import 'dart:math' show ln10, log;

import 'package:flutter_test/flutter_test.dart';
import 'package:segno/looper/model/meter_scale.dart';

double _db(double peak) => 20 * log(peak) / ln10;

void main() {
  group('meterPeak', () {
    test('reads silence and full scale as they are', () {
      expect(meterPeak(0), 0);
      expect(meterPeak(1), 1);
      expect(meterPeak(kClipPeak), 1);
    });

    test('reads anything under the meter floor as silence', () {
      // -70 dBFS: an input's noise floor.
      expect(meterPeak(0.000316), 0);
      // The floor itself draws nothing either.
      expect(meterPeak(0.001), 0);
    });

    test('rounds to a tenth of a dB', () {
      expect(_db(meterPeak(0.5)), closeTo(-6.0, 1e-9));
      expect(_db(meterPeak(0.125)), closeTo(-18.1, 1e-9));
    });

    test('peaks that differ by less than the rounding read the same', () {
      expect(meterPeak(0.5), meterPeak(0.50001));
    });

    test('rounding up to 0.0 dBFS does not invent a clip', () {
      // -0.013 dBFS rounds to 0.0 but is under the clip threshold.
      expect(meterPeak(0.9985), lessThan(kClipPeak));
    });
  });
}
