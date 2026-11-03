import 'package:flutter_test/flutter_test.dart';
import 'package:segno/console_leds/ambient_brightness.dart';

void main() {
  group('consoleLedCurve', () {
    double at(int reading, {double offset = 0}) => consoleLedCurve.brightnessAt(
      reading,
      dark: 40,
      bright: 160,
      offset: offset,
    );

    test('is the floor at and below the dark point', () {
      expect(at(40), consoleLedCurve.floor);
      expect(at(0), consoleLedCurve.floor);
    });

    test('is full at and above the bright point', () {
      expect(at(160), 1);
      expect(at(190), 1);
    });

    test('rises evenly in the reading, which is log of the light', () {
      // Each doubling of the light adds the same brightness.
      final steps = [for (var r = 40; r <= 160; r += 16) at(r)];
      for (var i = 1; i < steps.length; i++) {
        expect(steps[i], greaterThan(steps[i - 1]));
        expect(
          steps[i] - steps[i - 1],
          closeTo(steps[1] - steps[0], 1e-9),
        );
      }
      expect(at(100), closeTo((consoleLedCurve.floor + 1) / 2, 1e-9));
    });

    test('the offset shifts it, inside the minimum and full', () {
      expect(at(100, offset: 0.5), closeTo(at(100) + 0.15, 1e-9));
      expect(at(100, offset: -0.5), closeTo(at(100) - 0.15, 1e-9));
      expect(at(160, offset: 1), 1);
      expect(at(0, offset: -1), consoleLedCurve.minimum);
    });
  });

  group('ledLevelOf', () {
    test('full is 255, the level the board shows untold', () {
      expect(ledLevelOf(1), 255);
    });

    test('follows the eye: half the brightness is about a fifth', () {
      expect(ledLevelOf(0.5), 55);
      expect(ledLevelOf(0.2), 7);
    });

    test('never asks for dark', () {
      expect(ledLevelOf(0), 1);
      expect(ledLevelOf(-1), 1);
      expect(ledLevelOf(2), 255);
    });
  });
}
