import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:segno/appliance/power_off/power_key_source.dart';

void main() {
  group('openAppliancePowerKeySource', () {
    test('is not constructed off the appliance', () {
      expect(openAppliancePowerKeySource(onAppliance: false), isNull);
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
