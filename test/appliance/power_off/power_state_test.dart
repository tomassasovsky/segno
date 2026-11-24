import 'package:flutter_test/flutter_test.dart';
import 'package:segno/appliance/power_off/power_cubit.dart';
import 'package:segno/appliance/power_off/power_gate.dart';

void main() {
  group(PowerState, () {
    test('a saved session runs every step', () {
      const state = PowerState(
        phase: PowerPhase.saving,
        step: PowerStep.stopPlayback,
        session: 'set',
      );
      expect(state.steps, PowerStep.values);
    });

    test('nothing to write skips the session step', () {
      const state = PowerState(
        phase: PowerPhase.saving,
        step: PowerStep.stopPlayback,
      );
      expect(state.steps, [
        PowerStep.stopPlayback,
        PowerStep.saveSettings,
        PowerStep.finishOnDisk,
      ]);
    });

    test('the panel shows the refusal, Power options and the failed save '
        'only', () {
      const states = [
        PowerState(),
        PowerState(phase: PowerPhase.refuse, refusal: PowerRefusal.update),
        PowerState(phase: PowerPhase.options),
        PowerState(phase: PowerPhase.saveAs),
        PowerState(phase: PowerPhase.saving, step: PowerStep.stopPlayback),
        PowerState(phase: PowerPhase.saveFailed),
        PowerState(phase: PowerPhase.goodbye),
      ];
      expect(
        [
          for (final state in states)
            if (state.shownInPanel) state.phase,
        ],
        [PowerPhase.refuse, PowerPhase.options, PowerPhase.saveFailed],
      );
    });

    test('progress is the share of steps finished', () {
      expect(
        const PowerState(
          phase: PowerPhase.saving,
          step: PowerStep.writeSession,
          session: 'set',
        ).progress,
        0.5,
      );
      expect(
        const PowerState(
          phase: PowerPhase.saving,
          step: PowerStep.finishOnDisk,
        ).progress,
        closeTo(2 / 3, 1e-9),
      );
      expect(const PowerState(phase: PowerPhase.goodbye).progress, 0);
    });
  });
}
