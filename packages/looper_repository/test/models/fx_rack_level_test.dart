import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';

void main() {
  group('the rack level', () {
    test('is unity at 0 dB and at setting 0.5', () {
      expect(fxRackLevelGain(0), 1);
      expect(fxRackLevelDb(1), 0);
      expect(fxRackLevelSetting(1), 0.5);
      expect(fxRackLevelGainAt(0.5), 1);
    });

    test('runs from -12 to +12 dB and clamps outside it', () {
      expect(fxRackLevelGain(-12), closeTo(0.2512, 1e-4));
      expect(fxRackLevelGain(12), closeTo(3.9811, 1e-4));
      expect(fxRackLevelGain(-30), fxRackLevelGain(-12));
      expect(fxRackLevelGain(30), fxRackLevelGain(12));
      // Below the range, silence included, reads as the bottom.
      expect(fxRackLevelDb(0), -12);
      expect(fxRackLevelDb(0.1), -12);
      expect(fxRackLevelSetting(0), 0);
    });

    test('snaps to the 0.1 dB step', () {
      expect(fxRackLevelDb(fxRackLevelGain(-1.34)), -1.3);
      expect(fxRackLevelDb(fxRackLevelGain(10.56)), 10.6);
      // Dub Rack / Big Clouds 1 stores 0.1875: -7.5 dB.
      expect(fxRackLevelDb(fxRackLevelGainAt(0.1875)), -7.5);
    });

    test('reads back the setting it was stored from, to the step', () {
      for (final setting in [0.0, 0.1875, 0.4458, 0.5, 0.7083, 1.0]) {
        expect(
          fxRackLevelSetting(fxRackLevelGainAt(setting)),
          closeTo(setting, 0.05 / 24 + 1e-9),
        );
      }
    });

    test('stays inside the engine ceiling', () {
      expect(fxRackLevelGain(12), lessThan(4));
    });
  });
}
