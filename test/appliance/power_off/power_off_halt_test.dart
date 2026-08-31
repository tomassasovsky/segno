import 'package:flutter_test/flutter_test.dart';
import 'package:segno/appliance/power_off/power_off_cubit.dart';
import 'package:segno/appliance/power_off/power_off_gate.dart';

void main() {
  group('power-off halt order', () {
    test('flush then pedal goodbye then powerOff', () async {
      final log = <String>[];
      final cubit = PowerOffCubit(
        flush: () => log.add('flush'),
        pedalGoodbye: () => log.add('pedal'),
        powerOff: () async => log.add('powerOff'),
        markHold: Duration.zero,
      );
      addTearDown(cubit.close);

      cubit.press(const PowerOffSnapshot());
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(log, ['flush', 'pedal', 'powerOff']);
    });

    test('discard uses the same halt order', () async {
      final log = <String>[];
      final cubit = PowerOffCubit(
        flush: () => log.add('flush'),
        pedalGoodbye: () => log.add('pedal'),
        powerOff: () async => log.add('powerOff'),
        markHold: Duration.zero,
      );
      addTearDown(cubit.close);

      cubit.press(const PowerOffSnapshot(anyHasContent: true));
      cubit.powerOffWithoutSaving(const PowerOffSnapshot(anyHasContent: true));
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(log, ['flush', 'pedal', 'powerOff']);
    });
  });
}
