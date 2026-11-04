import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:operation_guards/operation_guards.dart';
import 'package:segno/appliance/power_off/power_cubit.dart';
import 'package:segno/appliance/power_off/power_dialog.dart';
import 'package:segno/appliance/power_off/power_gate.dart';
import 'package:segno/theme/theme.dart';

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
  updateInstalling: () async => false,
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
            .widget<PowerPanelButton>(
              find.byKey(const Key('power_keep_playing')),
            )
            .tone,
        PowerPanelTone.warning,
      );
    });

    testWidgets('a transfer refuses with its own words and only Keep '
        'playing; a take wins when both are in flight', (tester) async {
      final cubit = _cubit();
      addTearDown(cubit.close);
      await _pump(
        tester,
        cubit,
        snapshot: const PowerSnapshot(transferInFlight: true),
      );

      expect(find.text('Wait for the transfer'), findsOneWidget);
      expect(find.text('Stop the take first'), findsNothing);
      expect(find.byKey(const Key('power_keep_playing')), findsOneWidget);
      expect(find.byKey(const Key('power_restart')), findsNothing);
      expect(find.byKey(const Key('power_shut_down')), findsNothing);

      cubit.dismiss();
      await tester.pumpAndSettle();
      await _pump(
        tester,
        cubit,
        snapshot: const PowerSnapshot(
          takeInFlight: true,
          transferInFlight: true,
        ),
      );
      expect(find.text('Stop the take first'), findsOneWidget);
      expect(find.text('Wait for the transfer'), findsNothing);
    });

    testWidgets('an update install refuses with its own words and only Keep '
        'playing; a take wins over it, and it wins over a transfer', (
      tester,
    ) async {
      final cubit = _cubit();
      addTearDown(cubit.close);
      await _pump(
        tester,
        cubit,
        snapshot: const PowerSnapshot(
          updateInFlight: true,
          transferInFlight: true,
        ),
      );

      expect(find.text('Wait for the update'), findsOneWidget);
      expect(
        find.text(
          'An update is still being downloaded or installed. Segno cannot '
          'restart or power off until it finishes. To check, press the power '
          'button again later: when Power options open, it has finished. If '
          'it succeeded, the Updates page in Settings says Ready to install.',
        ),
        findsOneWidget,
      );
      expect(find.text('Wait for the transfer'), findsNothing);
      expect(find.byKey(const Key('power_keep_playing')), findsOneWidget);
      expect(find.byKey(const Key('power_restart')), findsNothing);
      expect(find.byKey(const Key('power_shut_down')), findsNothing);

      cubit.dismiss();
      await tester.pumpAndSettle();
      await _pump(
        tester,
        cubit,
        snapshot: const PowerSnapshot(takeInFlight: true, updateInFlight: true),
      );
      expect(find.text('Stop the take first'), findsOneWidget);
      expect(find.text('Wait for the update'), findsNothing);
    });

    testWidgets('the refusal keeps its words when the install ends while it '
        'is up', (tester) async {
      final cubit = _cubit();
      addTearDown(cubit.close);
      final changes = StreamController<Object?>();
      addTearDown(changes.close);
      var snapshot = const PowerSnapshot(updateInFlight: true);
      cubit.press(snapshot);
      await tester.pumpApp(
        BlocProvider.value(
          value: cubit,
          child: Scaffold(
            body: PowerDialog(
              snapshot: () => snapshot,
              save: () async {},
              changes: [changes.stream],
            ),
          ),
        ),
      );
      expect(find.text('Wait for the update'), findsOneWidget);

      snapshot = const PowerSnapshot();
      changes.add(null);
      await tester.pump();

      expect(find.text('Wait for the update'), findsOneWidget);
      expect(find.text('Stop the take first'), findsNothing);
    });

    testWidgets('Power options: the save promise, the session name, and '
        'Cancel / Restart / Shut down', (tester) async {
      final cubit = _cubit();
      addTearDown(cubit.close);
      await _pump(tester, cubit);

      expect(find.text('Power'), findsOneWidget);
      expect(
        find.text('Playback stops and friday-set is saved first.'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('power_cancel')), findsOneWidget);
      expect(find.byKey(const Key('power_restart')), findsOneWidget);
      expect(find.byKey(const Key('power_shut_down')), findsOneWidget);
      expect(find.textContaining('without saving'), findsNothing);
      expect(find.textContaining('installs during the restart'), findsNothing);
      // The buttons sit a spacing token apart (#1590 DLG-3).
      Rect rect(String key) => tester.getRect(find.byKey(Key(key)));
      expect(
        rect('power_restart').left - rect('power_cancel').right,
        moreOrLessEquals(SpacingTheme.standard.lg),
      );
      expect(
        rect('power_shut_down').left - rect('power_restart').right,
        moreOrLessEquals(SpacingTheme.standard.lg),
      );
    });

    testWidgets('an unnamed session says it will be named first', (
      tester,
    ) async {
      final cubit = _cubit();
      addTearDown(cubit.close);
      await _pump(tester, cubit, snapshot: const PowerSnapshot());
      expect(
        find.text(
          'Playback stops and this session is saved first. You name it '
          'before it saves.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('an empty unnamed session says nothing will be saved, and '
        'Restart reboots without saving', (tester) async {
      final log = <String>[];
      final cubit = _cubit(log: log);
      addTearDown(cubit.close);
      await _pump(
        tester,
        cubit,
        snapshot: const PowerSnapshot(sessionHasContent: false),
        save: () async => log.add('save'),
      );

      expect(
        find.text(
          'Playback stops. This session is empty, so there is nothing to '
          'save.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('saved first'), findsNothing);
      expect(find.textContaining('name it before it saves'), findsNothing);
      expect(find.byKey(const Key('power_restart')), findsOneWidget);
      expect(find.byKey(const Key('power_shut_down')), findsOneWidget);

      await tester.tap(find.byKey(const Key('power_restart')));
      await tester.pump();
      await tester.pump();
      expect(log, ['reboot']);
      expect(cubit.state.phase, PowerPhase.goodbye);
    });

    testWidgets('the lines follow the rig while the dialog is open', (
      tester,
    ) async {
      final cubit = _cubit();
      addTearDown(cubit.close);
      final changes = StreamController<Object?>();
      addTearDown(changes.close);
      var reading = const PowerSnapshot(sessionHasContent: false);
      cubit.press(reading);
      await tester.pumpApp(
        BlocProvider.value(
          value: cubit,
          child: Scaffold(
            body: PowerDialog(
              snapshot: () => reading,
              save: () async {},
              changes: [changes.stream],
            ),
          ),
        ),
      );
      const empty =
          'Playback stops. This session is empty, so there is nothing to '
          'save.';
      expect(find.text(empty), findsOneWidget);

      reading = const PowerSnapshot();
      changes.add(null);
      await tester.pump();

      expect(find.text(empty), findsNothing);
      expect(
        find.text(
          'Playback stops and this session is saved first. You name it '
          'before it saves.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('a named session that holds nothing keeps the save promise', (
      tester,
    ) async {
      final cubit = _cubit();
      addTearDown(cubit.close);
      await _pump(
        tester,
        cubit,
        snapshot: const PowerSnapshot(
          currentSessionName: 'friday-set',
          sessionHasContent: false,
        ),
      );
      expect(
        find.text('Playback stops and friday-set is saved first.'),
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
      // The same panel, its title in the warning colour behind an alert.
      expect(find.byKey(const Key('power_dialog')), findsOneWidget);
      expect(find.byIcon(Icons.error_outline), findsOneWidget);
      final title = tester.widget<Text>(find.text('Segno is staying on'));
      expect(
        title.style?.color,
        tester.element(find.text('Segno is staying on')).surface.warning,
      );
      expect(
        tester
            .widget<PowerPanelButton>(find.byKey(const Key('power_retry')))
            .tone,
        PowerPanelTone.accent,
      );

      fail = false;
      await tester.tap(find.byKey(const Key('power_retry')));
      await tester.pump();
      await tester.pump();
      expect(log, ['save', 'save', 'powerOff']);
    });

    testWidgets('the panel sits bottom-centre, 760 wide, 48 above the edge', (
      tester,
    ) async {
      tester.view
        ..physicalSize = const Size(1920, 1080)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final cubit = _cubit();
      addTearDown(cubit.close);
      await _pump(tester, cubit);

      final panel = tester.getRect(find.byKey(const Key('power_dialog')));
      expect(panel.width, 760);
      expect(panel.center.dx, 960);
      expect(panel.bottom, 1080 - 48);
      for (final key in ['power_cancel', 'power_restart', 'power_shut_down']) {
        expect(tester.getSize(find.byKey(Key(key))).height, 84);
      }
      // Shut down is the widest; Restart and Shut down carry their icons.
      expect(
        tester.getSize(find.byKey(const Key('power_shut_down'))).width,
        greaterThan(
          tester.getSize(find.byKey(const Key('power_restart'))).width,
        ),
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('power_restart')),
          matching: find.byIcon(Icons.restart_alt),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('power_shut_down')),
          matching: find.byIcon(Icons.power_settings_new),
        ),
        findsOneWidget,
      );
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
