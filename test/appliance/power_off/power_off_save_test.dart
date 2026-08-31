import 'package:flutter_test/flutter_test.dart';
import 'package:segno/appliance/power_off/power_off_cubit.dart';
import 'package:segno/appliance/power_off/power_off_gate.dart';

void main() {
  group('PowerOffCubit save', () {
    test('Save & power off with no currentSessionName emits saveAs', () async {
      var halted = false;
      final cubit = PowerOffCubit(
        flush: () {},
        pedalGoodbye: () {},
        powerOff: () async => halted = true,
        markHold: Duration.zero,
      );
      addTearDown(cubit.close);

      cubit.press(const PowerOffSnapshot(anyHasContent: true));
      cubit.saveAndPowerOff(const PowerOffSnapshot(anyHasContent: true));
      await Future<void>.delayed(Duration.zero);

      expect(cubit.state.phase, PowerOffPhase.saveAs);
      expect(halted, isFalse);

      cubit.keepPlaying();
      expect(cubit.state.phase, PowerOffPhase.idle);
      expect(halted, isFalse);
    });

    test('save failure does not call powerOff', () async {
      var halted = false;
      final cubit = PowerOffCubit(
        flush: () {},
        pedalGoodbye: () {},
        powerOff: () async => halted = true,
        markHold: Duration.zero,
      );
      addTearDown(cubit.close);

      const named = PowerOffSnapshot(
        anyHasContent: true,
        currentSessionName: 'set',
      );
      cubit.press(named);
      cubit.saveAndPowerOff(
        named,
        save: () async => throw Exception('disk full'),
      );
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(cubit.state.phase, PowerOffPhase.saveFailed);
      expect(halted, isFalse);
    });

    test('cancel Save As via keepPlaying aborts halt', () async {
      var halted = false;
      final cubit = PowerOffCubit(
        flush: () {},
        pedalGoodbye: () {},
        powerOff: () async => halted = true,
        markHold: Duration.zero,
      );
      addTearDown(cubit.close);

      cubit.press(const PowerOffSnapshot(anyHasContent: true));
      cubit.saveAndPowerOff(const PowerOffSnapshot(anyHasContent: true));
      cubit.keepPlaying();
      await Future<void>.delayed(Duration.zero);

      expect(cubit.state.phase, PowerOffPhase.idle);
      expect(halted, isFalse);
    });
  });
}
