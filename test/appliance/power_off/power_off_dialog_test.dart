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
  flush: () {},
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
        snapshot: const PowerOffSnapshot(anyCapturingOrPending: true),
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

    testWidgets('Keep playing pops the route', (tester) async {
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
        snapshot: const PowerOffSnapshot(countingIn: true),
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
      cubit.press(named);
      cubit.saveAndPowerOff(
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
