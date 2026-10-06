import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/appliance/power_off/power_off_cubit.dart';
import 'package:segno/appliance/power_off/power_off_dialog.dart';
import 'package:segno/appliance/power_off/power_off_gate.dart';
import 'package:segno/common/console_surface.dart';

import '../../helpers/helpers.dart';

PowerOffCubit _cubit() => PowerOffCubit(
  flush: ({required retry}) {},
  pedalGoodbye: () {},
  powerOff: () async {},
  markHold: Duration.zero,
);

Future<void> _pump(
  WidgetTester tester,
  PowerOffCubit cubit, {
  PowerOffSnapshot snapshot = const PowerOffSnapshot(anyHasContent: true),
}) {
  cubit.press(snapshot);
  return tester.pumpApp(
    BlocProvider.value(
      value: cubit,
      child: Scaffold(
        body: PowerOffDialog(snapshot: () => snapshot),
      ),
    ),
  );
}

void main() {
  group(PowerOffDialog, () {
    testWidgets('refuse has exactly one action (Keep playing)', (tester) async {
      final cubit = _cubit();
      addTearDown(cubit.close);
      await _pump(
        tester,
        cubit,
        snapshot: const PowerOffSnapshot(takeInFlight: true),
      );

      expect(find.byKey(const Key('power_off_keep_playing')), findsOneWidget);
      expect(find.byKey(const Key('power_off_save')), findsNothing);
      expect(find.byKey(const Key('power_off_discard')), findsNothing);
      expect(
        tester
            .widget<ConsoleDialogButton>(
              find.byKey(const Key('power_off_keep_playing')),
            )
            .tone,
        ConsoleDialogTone.warning,
      );
    });

    testWidgets(
      'three-choice has Keep playing, Save, and discard',
      (tester) async {
        final cubit = _cubit();
        addTearDown(cubit.close);
        await _pump(tester, cubit);

        expect(find.byKey(const Key('power_off_keep_playing')), findsOneWidget);
        expect(find.byKey(const Key('power_off_save')), findsOneWidget);
        expect(find.byKey(const Key('power_off_discard')), findsOneWidget);
      },
    );

    testWidgets('Keep playing returns the cubit to idle', (tester) async {
      final cubit = _cubit();
      addTearDown(cubit.close);
      await _pump(tester, cubit);
      await tester.tap(find.byKey(const Key('power_off_keep_playing')));
      await tester.pump();

      expect(cubit.state.phase, PowerOffPhase.idle);
    });

    testWidgets('discard control is absent on refuse', (tester) async {
      final cubit = _cubit();
      addTearDown(cubit.close);
      await _pump(
        tester,
        cubit,
        snapshot: const PowerOffSnapshot(takeInFlight: true),
      );
      expect(find.byKey(const Key('power_off_discard')), findsNothing);
    });

    testWidgets('save-failed face keeps Save and discard', (tester) async {
      final cubit = _cubit();
      addTearDown(cubit.close);
      const named = PowerOffSnapshot(
        anyHasContent: true,
        currentSessionName: 'set',
      );
      cubit
        ..press(named)
        ..saveAndPowerOff(
          named,
          save: () async => throw Exception('disk full'),
        );
      await tester.pump();
      await tester.pump();
      await tester.pumpApp(
        BlocProvider.value(
          value: cubit,
          child: Scaffold(
            body: PowerOffDialog(snapshot: () => named),
          ),
        ),
      );

      expect(find.text("Couldn't save"), findsOneWidget);
      expect(find.byKey(const Key('power_off_keep_playing')), findsOneWidget);
      expect(find.byKey(const Key('power_off_save')), findsOneWidget);
      expect(find.byKey(const Key('power_off_discard')), findsOneWidget);
    });

    testWidgets('Power off anyway appears only after a failed Retry, says '
        'the last change is lost, and fires the power-off', (tester) async {
      var halts = 0;
      final cubit = PowerOffCubit(
        flush: ({required retry}) => throw StateError('unconfirmed'),
        pedalGoodbye: () {},
        powerOff: () async => halts++,
        markHold: Duration.zero,
      );
      addTearDown(cubit.close);
      const snapshot = PowerOffSnapshot();
      cubit.press(snapshot);
      await tester.pumpApp(
        BlocProvider.value(
          value: cubit,
          child: Scaffold(body: PowerOffDialog(snapshot: () => snapshot)),
        ),
      );
      await tester.pump();
      expect(cubit.state.phase, PowerOffPhase.flushFailed);
      expect(find.byKey(const Key('power_off_anyway')), findsNothing);
      await tester.tap(find.byKey(const Key('power_off_retry')));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('power_off_anyway')), findsOneWidget);
      expect(
        find.textContaining('could not confirm your last change was saved'),
        findsOne,
      );
      await tester.tap(find.byKey(const Key('power_off_anyway')));
      await tester.pump();
      await tester.pump();
      expect(halts, 1);
    });

    testWidgets('scrim pop leaves the cubit on confirm until host maps it', (
      tester,
    ) async {
      final cubit = _cubit();
      addTearDown(cubit.close);
      cubit.press(const PowerOffSnapshot(anyHasContent: true));
      await tester.pumpApp(
        BlocProvider.value(
          value: cubit,
          child: Builder(
            builder: (context) => TextButton(
              onPressed: () => unawaited(
                showPowerOffDialog(
                  context,
                  snapshot: () => const PowerOffSnapshot(anyHasContent: true),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const Key('power_off_dialog')), findsOneWidget);

      await tester.tapAt(const Offset(4, 4));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const Key('power_off_dialog')), findsNothing);
      expect(cubit.state.phase, PowerOffPhase.confirm);
    });
  });
}
