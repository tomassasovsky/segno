import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:operation_guards/operation_guards.dart';
import 'package:segno/appliance/power_off/power_cubit.dart';
import 'package:segno/appliance/power_off/power_dialog.dart';
import 'package:segno/appliance/power_off/power_gate.dart';
import 'package:segno/common/console_surface.dart';

import '../../helpers/helpers.dart';

const _named = PowerSnapshot(currentSessionName: 'friday-set');

PowerCubit _cubit({List<String>? log}) => PowerCubit(
  stopTransport: () {},
  flush: ({required retry}) {},
  storageSettled: () async {},
  guards: GuardRegistry(),
  pedalGoodbye: () {},
  powerOff: () async => log?.add('powerOff'),
  reboot: () async => log?.add('reboot'),
  markHold: Duration.zero,
);

Future<void> _pump(
  WidgetTester tester,
  PowerCubit cubit, {
  PowerSnapshot snapshot = _named,
  Future<void> Function()? save,
  String? stagedUpdate,
}) {
  cubit.press(snapshot);
  return tester.pumpApp(
    BlocProvider.value(
      value: cubit,
      child: Scaffold(
        body: PowerDialog(
          snapshot: () => snapshot,
          save: save ?? () async {},
          stagedUpdate: stagedUpdate,
        ),
      ),
    ),
  );
}

void main() {
  group(PowerDialog, () {
    testWidgets('refuse has exactly one action (Keep playing)', (tester) async {
      final cubit = _cubit();
      addTearDown(cubit.close);
      await _pump(
        tester,
        cubit,
        snapshot: const PowerSnapshot(takeInFlight: true),
      );

      expect(find.text('Stop the take first'), findsOneWidget);
      expect(find.byKey(const Key('power_keep_playing')), findsOneWidget);
      expect(find.byKey(const Key('power_restart')), findsNothing);
      expect(find.byKey(const Key('power_shut_down')), findsNothing);
      expect(
        tester
            .widget<ConsoleDialogButton>(
              find.byKey(const Key('power_keep_playing')),
            )
            .tone,
        ConsoleDialogTone.warning,
      );
    });

    testWidgets('Power options: the save promise, the session name, and '
        'Cancel / Restart / Shut down', (tester) async {
      final cubit = _cubit();
      addTearDown(cubit.close);
      await _pump(tester, cubit);

      expect(find.text('Power options'), findsOneWidget);
      expect(
        find.text('Playback will stop and your session will be saved.'),
        findsOneWidget,
      );
      expect(find.text('friday-set'), findsOneWidget);
      expect(find.byKey(const Key('power_cancel')), findsOneWidget);
      expect(find.byKey(const Key('power_restart')), findsOneWidget);
      expect(find.byKey(const Key('power_shut_down')), findsOneWidget);
      expect(find.textContaining('without saving'), findsNothing);
      expect(find.textContaining('installs during the restart'), findsNothing);
    });

    testWidgets('an unnamed session says it will be named first', (
      tester,
    ) async {
      final cubit = _cubit();
      addTearDown(cubit.close);
      await _pump(tester, cubit, snapshot: const PowerSnapshot());
      expect(
        find.text(
          "This session has no name yet. You'll name it before it saves.",
        ),
        findsOneWidget,
      );
    });

    testWidgets('a staged update adds the install line', (tester) async {
      final cubit = _cubit();
      addTearDown(cubit.close);
      await _pump(tester, cubit, stagedUpdate: '1.1.0');
      expect(
        find.text('Segno 1.1.0 installs during the restart.'),
        findsOneWidget,
      );
    });

    testWidgets('Cancel returns the cubit to idle', (tester) async {
      final cubit = _cubit();
      addTearDown(cubit.close);
      await _pump(tester, cubit);
      await tester.tap(find.byKey(const Key('power_cancel')));
      await tester.pump();

      expect(cubit.state.phase, PowerPhase.idle);
    });

    testWidgets('Restart saves, then reboots', (tester) async {
      final log = <String>[];
      final cubit = _cubit(log: log);
      addTearDown(cubit.close);
      await _pump(tester, cubit, save: () async => log.add('save'));
      await tester.tap(find.byKey(const Key('power_restart')));
      await tester.pump();
      await tester.pump();

      expect(log, ['save', 'reboot']);
      expect(cubit.state.action, PowerAction.restart);
    });

    testWidgets('Shut down saves, then powers off', (tester) async {
      final log = <String>[];
      final cubit = _cubit(log: log);
      addTearDown(cubit.close);
      await _pump(tester, cubit, save: () async => log.add('save'));
      await tester.tap(find.byKey(const Key('power_shut_down')));
      await tester.pump();
      await tester.pump();

      expect(log, ['save', 'powerOff']);
    });

    testWidgets('save failure: Segno is staying on, with Stay on and Retry '
        'only', (tester) async {
      final log = <String>[];
      final cubit = _cubit(log: log);
      addTearDown(cubit.close);
      var fail = true;
      await _pump(
        tester,
        cubit,
        save: () async {
          log.add('save');
          if (fail) throw Exception('disk full');
        },
      );
      await tester.tap(find.byKey(const Key('power_shut_down')));
      await tester.pump();
      await tester.pump();

      expect(cubit.state.phase, PowerPhase.saveFailed);
      expect(find.text('Segno is staying on'), findsOneWidget);
      expect(find.byKey(const Key('power_stay_on')), findsOneWidget);
      expect(find.byKey(const Key('power_retry')), findsOneWidget);
      expect(find.byKey(const Key('power_shut_down')), findsNothing);
      expect(find.textContaining('anyway'), findsNothing);
      expect(log, ['save']);

      fail = false;
      await tester.tap(find.byKey(const Key('power_retry')));
      await tester.pump();
      await tester.pump();
      expect(log, ['save', 'save', 'powerOff']);
    });

    testWidgets('Stay on after a failed save returns to idle', (tester) async {
      final cubit = _cubit();
      addTearDown(cubit.close);
      await _pump(
        tester,
        cubit,
        save: () async => throw Exception('disk full'),
      );
      await tester.tap(find.byKey(const Key('power_restart')));
      await tester.pump();
      await tester.pump();
      await tester.tap(find.byKey(const Key('power_stay_on')));
      await tester.pump();

      expect(cubit.state.phase, PowerPhase.idle);
    });

    testWidgets('scrim pop leaves the cubit on options until host maps it', (
      tester,
    ) async {
      final cubit = _cubit();
      addTearDown(cubit.close);
      cubit.press(_named);
      await tester.pumpApp(
        BlocProvider.value(
          value: cubit,
          child: Builder(
            builder: (context) => TextButton(
              onPressed: () => unawaited(
                showPowerDialog(
                  context,
                  snapshot: () => _named,
                  save: () async {},
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
      expect(find.byKey(const Key('power_dialog')), findsOneWidget);

      await tester.tapAt(const Offset(4, 4));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const Key('power_dialog')), findsNothing);
      expect(cubit.state.phase, PowerPhase.options);
    });
  });
}
