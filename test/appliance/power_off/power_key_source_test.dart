import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:segno/appliance/power_off/power_key_source.dart';

void main() {
  group('openAppliancePowerKeySource', () {
    test('is not constructed on non-Linux', () {
      expect(
        openAppliancePowerKeySource(isLinux: false, helperExists: true),
        isNull,
      );
    });

    test('is not constructed when the helper is absent', () {
      expect(
        openAppliancePowerKeySource(isLinux: true, helperExists: false),
        isNull,
      );
    });
  });

  group(FakePowerKeySource, () {
    test('forwards emitPress to listeners', () async {
      final source = FakePowerKeySource();
      addTearDown(source.close);
      final presses = <void>[];
      source.presses.listen(presses.add);
      source.emitPress();
      await Future<void>.delayed(Duration.zero);
      expect(presses, hasLength(1));
    });
  });

  group('waveform isolate is not a listener', () {
    test('waveform_window.dart does not open evdev', () {
      final source = File(
        'lib/visualizer/waveform_window.dart',
      ).readAsStringSync();
      expect(source.contains('PowerKeySource'), isFalse);
      expect(source.contains('pwr_button'), isFalse);
      expect(source.contains('evdev'), isFalse);
    });
  });
}
