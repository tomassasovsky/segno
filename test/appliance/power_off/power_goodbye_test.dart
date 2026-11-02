import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/appliance/power_off/power_cubit.dart';
import 'package:segno/appliance/power_off/power_gate.dart';
import 'package:segno/appliance/power_off/power_goodbye.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/theme/theme.dart';
import 'package:segno/visualizer/performance_readout.dart';

import '../../helpers/helpers.dart';

void main() {
  final savedAt = DateTime(2026, 11, 2, 21, 47);

  PowerState saving(PowerStep step, {String? session = 'friday-set'}) =>
      PowerState(
        phase: PowerPhase.saving,
        action: PowerAction.shutDown,
        step: step,
        session: session,
      );

  PowerState goodbye(PowerAction action, {String? session = 'friday-set'}) =>
      PowerState(
        phase: PowerPhase.goodbye,
        action: action,
        session: session,
        savedAt: session == null ? null : savedAt,
      );

  Finder marker(String key) => find.byKey(Key('power_step_$key'));

  group(PowerGoodbye, () {
    group('Saving', () {
      testWidgets('names the session and ticks off the steps reached', (
        tester,
      ) async {
        await tester.pumpApp(
          PowerGoodbye(state: saving(PowerStep.writeSession)),
        );

        expect(find.byKey(const Key('power_saving')), findsOneWidget);
        expect(find.text('Saving friday-set'), findsOneWidget);
        expect(find.text('Playback stopped'), findsOneWidget);
        expect(find.text('Settings saved'), findsOneWidget);
        expect(find.text('Writing the session'), findsOneWidget);
        expect(find.text('Finishing on disk'), findsOneWidget);
        expect(marker('done'), findsNWidgets(2));
        expect(marker('current'), findsOneWidget);
        expect(marker('pending'), findsOneWidget);
        expect(
          find.descendant(
            of: marker('current'),
            matching: find.byType(CircularProgressIndicator),
          ),
          findsOneWidget,
        );
        final bar = tester.widget<LinearProgressIndicator>(
          find.byKey(const Key('power_progress')),
        );
        expect(bar.value, 0.5);
        final box = tester.widget<ColoredBox>(
          find.byKey(const Key('power_goodbye')),
        );
        expect(box.color, kPowerGoodbyeFill);
      });

      testWidgets('starts with every step ahead', (tester) async {
        await tester.pumpApp(
          PowerGoodbye(state: saving(PowerStep.stopPlayback)),
        );
        expect(marker('done'), findsNothing);
        expect(marker('current'), findsOneWidget);
        expect(marker('pending'), findsNWidgets(3));
      });

      testWidgets('ends on the disk step with the rest done', (tester) async {
        await tester.pumpApp(
          PowerGoodbye(state: saving(PowerStep.finishOnDisk)),
        );
        expect(marker('done'), findsNWidgets(3));
        expect(marker('current'), findsOneWidget);
        expect(marker('pending'), findsNothing);
      });

      testWidgets('an empty unnamed session has no session step or name', (
        tester,
      ) async {
        await tester.pumpApp(
          PowerGoodbye(state: saving(PowerStep.saveSettings, session: null)),
        );
        expect(find.text('Saving'), findsOneWidget);
        expect(find.text('Writing the session'), findsNothing);
        expect(marker('done'), findsOneWidget);
        expect(marker('pending'), findsOneWidget);
      });
    });

    group('Safe to switch off', () {
      testWidgets('the check ring, the headline and when the session saved', (
        tester,
      ) async {
        await tester.pumpApp(
          PowerGoodbye(state: goodbye(PowerAction.shutDown)),
        );
        expect(
          find.byKey(const Key('power_safe_to_switch_off')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('power_check_ring')), findsOneWidget);
        expect(find.text('Safe to switch off'), findsOneWidget);
        expect(find.text('friday-set saved at 21:47'), findsOneWidget);
        expect(find.byType(Image), findsNothing);
      });

      testWidgets('no saved line when nothing was saved', (tester) async {
        await tester.pumpApp(
          PowerGoodbye(state: goodbye(PowerAction.shutDown, session: null)),
        );
        expect(find.text('Safe to switch off'), findsOneWidget);
        expect(find.byKey(const Key('power_saved_at')), findsNothing);
      });

      testWidgets('says to unplug when a power cycle would raise the '
          'contract (#1352)', (tester) async {
        await tester.pumpApp(
          PowerGoodbye(
            state: goodbye(PowerAction.shutDown),
            unplugToApply: true,
          ),
        );
        expect(find.byKey(const Key('power_unplug_to_apply')), findsOne);
      });

      testWidgets('not without one', (tester) async {
        await tester.pumpApp(
          PowerGoodbye(state: goodbye(PowerAction.shutDown)),
        );
        expect(find.byKey(const Key('power_unplug_to_apply')), findsNothing);
      });

      testWidgets('the time follows the locale', (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.neon,
            locale: const Locale('es'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: PowerGoodbye(state: goodbye(PowerAction.shutDown)),
          ),
        );
        expect(find.text('friday-set guardada a las 21:47'), findsOneWidget);
      });
    });

    group('Restarting', () {
      testWidgets('no icon, the saved line and the update it installs', (
        tester,
      ) async {
        await tester.pumpApp(
          PowerGoodbye(
            state: goodbye(PowerAction.restart),
            stagedUpdate: '1.4.0',
            unplugToApply: true,
          ),
        );
        expect(find.byKey(const Key('power_restarting')), findsOneWidget);
        expect(find.text('Restarting'), findsOneWidget);
        expect(find.byType(Icon), findsNothing);
        expect(find.text('friday-set saved at 21:47'), findsOneWidget);
        expect(find.text('Installing Segno 1.4.0'), findsOneWidget);
        expect(find.byKey(const Key('power_unplug_to_apply')), findsNothing);
      });

      testWidgets('no installing line without a staged update', (
        tester,
      ) async {
        await tester.pumpApp(
          PowerGoodbye(state: goodbye(PowerAction.restart)),
        );
        expect(
          find.byKey(const Key('power_installing_update')),
          findsNothing,
        );
      });
    });

    testWidgets('draws nothing outside the save and the goodbye', (
      tester,
    ) async {
      for (final state in const [
        PowerState(),
        PowerState(phase: PowerPhase.options),
        PowerState(phase: PowerPhase.saveAs, action: PowerAction.shutDown),
        PowerState(phase: PowerPhase.saveFailed, action: PowerAction.restart),
        PowerState(phase: PowerPhase.refuse, refusal: PowerRefusal.take),
      ]) {
        await tester.pumpApp(PowerGoodbye(state: state));
        expect(find.byKey(const Key('power_goodbye')), findsNothing);
      }
    });
  });

  group(ReadoutGoodbyeFace, () {
    Future<void> pumpFace(WidgetTester tester, PerformanceReadout readout) =>
        tester.pumpApp(
          Center(
            // The 7" panel's logical size on the console.
            child: SizedBox(
              width: 640,
              height: 375,
              child: ReadoutGoodbyeFace(readout: readout),
            ),
          ),
        );

    testWidgets('points to the main screen while the panel is up', (
      tester,
    ) async {
      await pumpFace(
        tester,
        const PerformanceReadout(goodbye: ReadoutGoodbye.options),
      );
      expect(find.byKey(const Key('readout_goodbye_options')), findsOneWidget);
      expect(find.byIcon(Icons.power_settings_new), findsOneWidget);
      expect(find.text('Power options on the main screen'), findsOneWidget);
    });

    testWidgets('Saving shows the current step and the bar', (tester) async {
      await pumpFace(
        tester,
        const PerformanceReadout(
          goodbye: ReadoutGoodbye.saving,
          savingStep: PowerStep.writeSession,
          savingProgress: 0.5,
        ),
      );
      expect(find.text('Saving'), findsOneWidget);
      expect(find.text('Writing the session'), findsOneWidget);
      final bar = tester.widget<LinearProgressIndicator>(
        find.byKey(const Key('power_progress')),
      );
      expect(bar.value, 0.5);
    });

    testWidgets('Safe to switch off: the check ring, no logo', (
      tester,
    ) async {
      await pumpFace(
        tester,
        const PerformanceReadout(goodbye: ReadoutGoodbye.safeToSwitchOff),
      );
      expect(find.byKey(const Key('power_check_ring')), findsOneWidget);
      expect(find.text('Safe to switch off'), findsOneWidget);
      expect(find.byType(Image), findsNothing);
    });

    testWidgets('Restarting: the restart icon, no logo', (tester) async {
      await pumpFace(
        tester,
        const PerformanceReadout(goodbye: ReadoutGoodbye.restarting),
      );
      expect(find.byIcon(Icons.restart_alt), findsOneWidget);
      expect(find.text('Restarting'), findsOneWidget);
      expect(find.byType(Image), findsNothing);
    });

    testWidgets('none draws nothing', (tester) async {
      await pumpFace(tester, const PerformanceReadout());
      expect(find.byKey(const Key('readout_goodbye')), findsNothing);
    });
  });

  group('readoutGoodbyeOf', () {
    test('the panel and Save As point to the main screen', () {
      for (final phase in [
        PowerPhase.options,
        PowerPhase.saveAs,
        PowerPhase.saveFailed,
      ]) {
        expect(
          readoutGoodbyeOf(
            PowerState(phase: phase, action: PowerAction.shutDown),
          ),
          ReadoutGoodbye.options,
        );
      }
    });

    test('the save and the goodbye map to their faces', () {
      expect(
        readoutGoodbyeOf(saving(PowerStep.saveSettings)),
        ReadoutGoodbye.saving,
      );
      expect(
        readoutGoodbyeOf(goodbye(PowerAction.shutDown)),
        ReadoutGoodbye.safeToSwitchOff,
      );
      expect(
        readoutGoodbyeOf(goodbye(PowerAction.restart)),
        ReadoutGoodbye.restarting,
      );
    });

    test('idle and a refusal leave the readout alone', () {
      expect(readoutGoodbyeOf(const PowerState()), ReadoutGoodbye.none);
      expect(
        readoutGoodbyeOf(
          const PowerState(
            phase: PowerPhase.refuse,
            refusal: PowerRefusal.take,
          ),
        ),
        ReadoutGoodbye.none,
      );
    });
  });
}
