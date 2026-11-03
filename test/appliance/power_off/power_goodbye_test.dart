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

  PowerState saving(
    PowerStep step, {
    String? session = 'friday-set',
    bool slow = true,
  }) => PowerState(
    phase: PowerPhase.saving,
    action: PowerAction.shutDown,
    step: step,
    session: session,
    slow: slow,
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
      testWidgets('a fast save shows no face (#1553)', (tester) async {
        await tester.pumpApp(
          PowerGoodbye(state: saving(PowerStep.writeSession, slow: false)),
        );
        expect(find.byKey(const Key('power_goodbye')), findsNothing);
        expect(find.byKey(const Key('power_saving')), findsNothing);
        // Nothing shows, and still nothing under it takes a touch.
        expect(
          tester.getSize(find.byKey(const Key('power_saving_quiet'))),
          tester.view.physicalSize / tester.view.devicePixelRatio,
        );
        expect(
          tester
              .widget<AbsorbPointer>(
                find.byKey(const Key('power_saving_quiet')),
              )
              .absorbing,
          isTrue,
        );
      });

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
        expect(find.text('Stopping playback'), findsOneWidget);
        expect(find.text('Saving settings'), findsOneWidget);
        expect(find.text('Settings saved'), findsNothing);
      });

      testWidgets('ends on the disk step with the rest done', (tester) async {
        await tester.pumpApp(
          PowerGoodbye(state: saving(PowerStep.finishOnDisk)),
        );
        expect(marker('done'), findsNWidgets(3));
        expect(marker('current'), findsOneWidget);
        expect(marker('pending'), findsNothing);
        // A step names what it did once done, what it does until then.
        expect(find.text('Session written'), findsOneWidget);
        expect(find.text('Writing the session'), findsNothing);
        expect(find.text('Finishing on disk'), findsOneWidget);
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

      testWidgets('a plain restart is the bare field, no Restarting face '
          '(#1553)', (tester) async {
        await tester.pumpApp(
          PowerGoodbye(state: goodbye(PowerAction.restart)),
        );
        final box = tester.widget<ColoredBox>(
          find.byKey(const Key('power_goodbye')),
        );
        expect(box.color, kPowerGoodbyeFill);
        expect(find.byKey(const Key('power_restarting')), findsNothing);
        expect(find.byType(Text), findsNothing);
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

    testWidgets('a plain restart is the bare field', (tester) async {
      await pumpFace(
        tester,
        const PerformanceReadout(goodbye: ReadoutGoodbye.blank),
      );
      final box = tester.widget<ColoredBox>(
        find.byKey(const Key('readout_goodbye')),
      );
      expect(box.color, kPowerGoodbyeFill);
      expect(find.byType(Text), findsNothing);
      expect(find.byType(Icon), findsNothing);
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
    ReadoutGoodbye of(PowerState state, {bool installsUpdate = false}) =>
        readoutGoodbyeOf(state, installsUpdate: installsUpdate);

    test('the track display stays through the panel, Save As, a refusal '
        'and a fast save (#1553)', () {
      for (final state in [
        const PowerState(),
        const PowerState(phase: PowerPhase.options),
        const PowerState(
          phase: PowerPhase.saveAs,
          action: PowerAction.shutDown,
        ),
        const PowerState(
          phase: PowerPhase.saveFailed,
          action: PowerAction.shutDown,
        ),
        const PowerState(phase: PowerPhase.refuse, refusal: PowerRefusal.take),
        saving(PowerStep.saveSettings, slow: false),
      ]) {
        expect(of(state), ReadoutGoodbye.none, reason: '$state');
      }
    });

    test('a slow save and the goodbye take over', () {
      expect(of(saving(PowerStep.saveSettings)), ReadoutGoodbye.saving);
      expect(
        of(goodbye(PowerAction.shutDown)),
        ReadoutGoodbye.safeToSwitchOff,
      );
    });

    test('Restarting only while an update installs', () {
      expect(
        of(goodbye(PowerAction.restart), installsUpdate: true),
        ReadoutGoodbye.restarting,
      );
      expect(of(goodbye(PowerAction.restart)), ReadoutGoodbye.blank);
    });
  });
}
