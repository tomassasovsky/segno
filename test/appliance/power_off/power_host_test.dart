import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:operation_guards/operation_guards.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/appliance/power_off/power_cubit.dart';
import 'package:segno/appliance/power_off/power_host.dart';
import 'package:segno/appliance/power_off/power_key_source.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/performance/cubit/performance_recorder_cubit.dart';
import 'package:segno/session/cubit/session_cubit.dart';
import 'package:segno/update/cubit/update_cubit.dart';
import 'package:session_repository/session_repository.dart';
import 'package:update_repository/update_repository.dart';

import '../../helpers/helpers.dart';
import 'fake_power_key_source.dart';

class _MockLooperBloc extends MockBloc<LooperEvent, LooperState>
    implements LooperBloc {}

class _MockSessionCubit extends MockCubit<SessionState>
    implements SessionCubit {}

class _MockRecorder extends MockCubit<PerformanceRecorderState>
    implements PerformanceRecorderCubit {}

class _MockPedalRepository extends Mock implements PedalRepository {}

class _MockUpdateCubit extends MockCubit<UpdateState> implements UpdateCubit {}

const _loops = LooperState(
  tracks: [Track(state: TrackState.playing, lengthFrames: 48000)],
);

void main() {
  group(PowerHost, () {
    late FakePowerKeySource keys;
    late PowerCubit cubit;
    late _MockLooperBloc looper;
    late _MockSessionCubit session;
    late _MockRecorder recorder;
    late _MockPedalRepository pedal;
    late StreamController<PedalEvent> pedalEvents;
    late List<String> log;

    setUpAll(() {
      registerFallbackValue(const LooperCutSoundPressed());
    });

    setUp(() {
      log = <String>[];
      keys = FakePowerKeySource();
      cubit = PowerCubit(
        stopTransport: () => log.add('stop'),
        flush: ({required retry}) => log.add('flush'),
        storageSettled: () async {},
        guards: GuardRegistry(),
        pedalGoodbye: () => log.add('pedal'),
        powerOff: () async => log.add('powerOff'),
        reboot: () async => log.add('reboot'),
        markHold: Duration.zero,
      );
      looper = _MockLooperBloc();
      session = _MockSessionCubit();
      recorder = _MockRecorder();
      pedal = _MockPedalRepository();
      pedalEvents = StreamController<PedalEvent>.broadcast();
      whenListen(
        looper,
        const Stream<LooperState>.empty(),
        initialState: _loops,
      );
      when(() => looper.add(any())).thenReturn(null);
      whenListen(
        recorder,
        const Stream<PerformanceRecorderState>.empty(),
        initialState: const PerformanceRecorderIdle(),
      );
      whenListen(
        session,
        const Stream<SessionState>.empty(),
        initialState: const SessionState(),
      );
      when(() => session.save()).thenAnswer((_) async {});
      when(() => session.saveAs(any())).thenAnswer((_) async {});
      when(() => pedal.events).thenAnswer((_) => pedalEvents.stream);
    });

    tearDown(() async {
      await cubit.close();
      await keys.close();
      await pedalEvents.close();
    });

    Future<void> pumpHost(WidgetTester tester, {UpdateCubit? update}) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpApp(
        MultiRepositoryProvider(
          providers: [
            RepositoryProvider<PowerKeySource>.value(value: keys),
            RepositoryProvider<PedalRepository>.value(value: pedal),
          ],
          child: MultiBlocProvider(
            providers: [
              BlocProvider<PowerCubit>.value(value: cubit),
              if (update != null)
                BlocProvider<UpdateCubit>.value(value: update),
              BlocProvider<LooperBloc>.value(value: looper),
              BlocProvider<PerformanceRecorderCubit>.value(value: recorder),
              BlocProvider<SessionCubit>.value(value: session),
            ],
            child: const PowerHost(
              child: Scaffold(
                body: SizedBox(key: Key('power_host_child')),
              ),
            ),
          ),
        ),
      );
    }

    Future<void> settle(WidgetTester tester) async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    Future<void> openOptions(WidgetTester tester, {UpdateCubit? update}) async {
      await pumpHost(tester, update: update);
      await tester.pump();
      keys.emitPress();
      await settle(tester);
    }

    void named() => whenListen(
      session,
      const Stream<SessionState>.empty(),
      initialState: const SessionState(
        currentSessionId: 'set',
        currentSessionName: 'set',
      ),
    );

    Future<void> typeName(WidgetTester tester, String name) async {
      for (final ch in name.split('')) {
        await tester.sendKeyEvent(LogicalKeyboardKey.keyA, character: ch);
      }
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await settle(tester);
    }

    Future<void> pushUnderlay(WidgetTester tester) async {
      Navigator.of(
        tester.element(find.byKey(const Key('power_host_child'))),
        rootNavigator: true,
      ).push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(
            body: SizedBox(key: Key('power_underlay')),
          ),
        ),
      );
      await settle(tester);
    }

    testWidgets('every press opens Power options, loops or not', (
      tester,
    ) async {
      whenListen(
        looper,
        const Stream<LooperState>.empty(),
        initialState: const LooperState(),
      );
      await openOptions(tester);

      expect(find.byKey(const Key('power_dialog')), findsOneWidget);
      expect(find.text('Power options'), findsOneWidget);
      expect(find.byKey(const Key('power_restart')), findsOneWidget);
      expect(find.byKey(const Key('power_shut_down')), findsOneWidget);
      expect(cubit.state.phase, PowerPhase.options);
    });

    testWidgets('a staged update adds its line', (tester) async {
      final update = _MockUpdateCubit();
      whenListen(
        update,
        const Stream<UpdateState>.empty(),
        initialState: UpdateState(
          phase: UpdatePhase.staged,
          available: UpdateManifest(
            version: Version.parse('1.1.0'),
            bundle: '',
          ),
        ),
      );
      await openOptions(tester, update: update);
      expect(
        find.text('Segno 1.1.0 installs during the restart.'),
        findsOneWidget,
      );
    });

    testWidgets('no staged update, no install line', (tester) async {
      await openOptions(tester);
      expect(find.textContaining('installs during the restart'), findsNothing);
    });

    testWidgets('press while capturing opens refuse and Keep playing idles', (
      tester,
    ) async {
      whenListen(
        looper,
        const Stream<LooperState>.empty(),
        initialState: const LooperState(
          tracks: [Track(state: TrackState.recording, lengthFrames: 48000)],
        ),
      );
      await openOptions(tester);

      expect(cubit.state.phase, PowerPhase.refuse);
      expect(find.text('Stop the take first'), findsOneWidget);
      expect(find.byKey(const Key('power_restart')), findsNothing);

      await tester.tap(find.byKey(const Key('power_keep_playing')));
      await settle(tester);
      expect(cubit.state.phase, PowerPhase.idle);
      expect(find.byKey(const Key('power_dialog')), findsNothing);
      expect(find.byKey(const Key('power_host_child')), findsOneWidget);
      expect(log, isEmpty);
    });

    testWidgets('Cancel pops only the power dialog', (tester) async {
      await openOptions(tester);

      await tester.tap(find.byKey(const Key('power_cancel')));
      await settle(tester);

      expect(find.byKey(const Key('power_dialog')), findsNothing);
      expect(find.byKey(const Key('power_host_child')), findsOneWidget);
      expect(cubit.state.phase, PowerPhase.idle);
      expect(log, isEmpty);

      keys.emitPress();
      await settle(tester);
      expect(find.byKey(const Key('power_dialog')), findsOneWidget);
      expect(cubit.state.phase, PowerPhase.options);
    });

    testWidgets('scrim and pedal map to Cancel', (tester) async {
      await openOptions(tester);

      await tester.tapAt(const Offset(4, 4));
      await settle(tester);
      expect(cubit.state.phase, PowerPhase.idle);
      expect(find.byKey(const Key('power_dialog')), findsNothing);

      keys.emitPress();
      await settle(tester);
      pedalEvents.add(const ButtonPressed(PedalButton.recPlay));
      await settle(tester);
      expect(cubit.state.phase, PowerPhase.idle);
      expect(log, isEmpty);
    });

    testWidgets('named Shut down saves and halts without Save As', (
      tester,
    ) async {
      named();
      await openOptions(tester);

      await tester.tap(find.byKey(const Key('power_shut_down')));
      await settle(tester);

      expect(find.byKey(const Key('console_rename_sheet')), findsNothing);
      expect(find.byKey(const Key('power_dialog')), findsNothing);
      expect(cubit.state.phase, PowerPhase.goodbye);
      expect(log, ['stop', 'flush', 'pedal', 'powerOff']);
      verify(() => session.save()).called(1);
      verifyNever(() => session.saveAs(any()));
    });

    testWidgets('named Restart saves and reboots', (tester) async {
      named();
      await openOptions(tester);

      await tester.tap(find.byKey(const Key('power_restart')));
      await settle(tester);

      expect(cubit.state.phase, PowerPhase.goodbye);
      expect(log, ['stop', 'flush', 'pedal', 'reboot']);
      verify(() => session.save()).called(1);
    });

    testWidgets('requestRestart (Install and restart) needs no dialog', (
      tester,
    ) async {
      named();
      await pumpHost(tester);
      await tester.pump();
      requestRestart(tester.element(find.byKey(const Key('power_host_child'))));
      await settle(tester);

      expect(log, ['stop', 'flush', 'pedal', 'reboot']);
      verify(() => session.save()).called(1);
    });

    testWidgets('named save failure: Segno is staying on; Stay on idles', (
      tester,
    ) async {
      named();
      when(() => session.save()).thenAnswer((_) async {
        when(() => session.state).thenReturn(
          const SessionState(
            currentSessionName: 'set',
            status: SessionStatus.failure,
            errorMessage: 'disk full',
          ),
        );
      });
      await openOptions(tester);

      await tester.tap(find.byKey(const Key('power_shut_down')));
      await settle(tester);

      expect(cubit.state.phase, PowerPhase.saveFailed);
      expect(find.text('Segno is staying on'), findsOneWidget);
      expect(find.byKey(const Key('power_retry')), findsOneWidget);
      expect(log, ['stop', 'flush']);

      await tester.tap(find.byKey(const Key('power_stay_on')));
      await settle(tester);
      expect(cubit.state.phase, PowerPhase.idle);
      expect(find.byKey(const Key('power_dialog')), findsNothing);
      expect(log, ['stop', 'flush']);
    });

    testWidgets('Install and restart that fails to save opens Stay on / '
        'Retry', (tester) async {
      named();
      when(() => session.save()).thenAnswer((_) async {
        when(() => session.state).thenReturn(
          const SessionState(
            currentSessionName: 'set',
            status: SessionStatus.failure,
          ),
        );
      });
      await pumpHost(tester);
      await tester.pump();
      requestRestart(tester.element(find.byKey(const Key('power_host_child'))));
      await settle(tester);

      expect(find.byKey(const Key('power_dialog')), findsOneWidget);
      expect(find.text('Segno is staying on'), findsOneWidget);
      expect(log, ['stop', 'flush']);
    });

    testWidgets('unnamed: Save As cancel aborts and does not save', (
      tester,
    ) async {
      await openOptions(tester);

      await tester.tap(find.byKey(const Key('power_restart')));
      await settle(tester);
      expect(find.byKey(const Key('console_rename_sheet')), findsOneWidget);
      expect(cubit.state.phase, PowerPhase.saveAs);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);

      expect(cubit.state.phase, PowerPhase.idle);
      expect(find.byKey(const Key('console_rename_sheet')), findsNothing);
      expect(log, isEmpty);
      verifyNever(() => session.saveAs(any()));
    });

    testWidgets(
      'Save As invalid name shows a snackbar and stays on the sheet',
      (tester) async {
        await openOptions(tester);
        await tester.tap(find.byKey(const Key('power_shut_down')));
        await settle(tester);

        await tester.sendKeyEvent(LogicalKeyboardKey.digit1, character: '!');
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await settle(tester);

        expect(cubit.state.phase, PowerPhase.saveAs);
        expect(find.text('Enter a valid session name.'), findsOneWidget);
        expect(find.byKey(const Key('console_rename_sheet')), findsOneWidget);
        expect(log, isEmpty);
        verifyNever(() => session.saveAs(any()));
      },
    );

    testWidgets('Save As duplicate name shows a snackbar and does not save', (
      tester,
    ) async {
      whenListen(
        session,
        const Stream<SessionState>.empty(),
        initialState: const SessionState(
          sessions: [SessionSummary(id: 'jam', name: 'jam')],
        ),
      );
      await openOptions(tester);
      await tester.tap(find.byKey(const Key('power_shut_down')));
      await settle(tester);
      await typeName(tester, 'jam');

      expect(cubit.state.phase, PowerPhase.saveAs);
      expect(
        find.text('A session named “jam” already exists.'),
        findsOneWidget,
      );
      expect(log, isEmpty);
      verifyNever(() => session.saveAs(any()));
    });

    testWidgets('Save As success halts and does not pop a route underneath', (
      tester,
    ) async {
      await pumpHost(tester);
      await tester.pump();
      await pushUnderlay(tester);

      keys.emitPress();
      await settle(tester);
      await tester.tap(find.byKey(const Key('power_shut_down')));
      await settle(tester);
      await typeName(tester, 'jam');

      expect(cubit.state.phase, PowerPhase.goodbye);
      expect(log, ['stop', 'flush', 'pedal', 'powerOff']);
      verify(() => session.saveAs('jam')).called(1);
      expect(find.byKey(const Key('power_underlay')), findsOneWidget);
    });

    testWidgets('Save As failure opens Segno is staying on and does not '
        'halt', (tester) async {
      when(() => session.saveAs(any())).thenAnswer((_) async {
        when(() => session.state).thenReturn(
          const SessionState(
            status: SessionStatus.failure,
            errorMessage: 'disk full',
          ),
        );
      });
      await pumpHost(tester);
      await tester.pump();
      await pushUnderlay(tester);

      keys.emitPress();
      await settle(tester);
      await tester.tap(find.byKey(const Key('power_shut_down')));
      await settle(tester);
      await typeName(tester, 'jam');

      expect(cubit.state.phase, PowerPhase.saveFailed);
      expect(find.byKey(const Key('power_dialog')), findsOneWidget);
      expect(find.text('Segno is staying on'), findsOneWidget);
      expect(find.byKey(const Key('power_underlay')), findsOneWidget);
      expect(log, ['stop', 'flush']);
    });

    testWidgets(
      'pedal during Save As pops only the sheet, not a route underneath',
      (tester) async {
        await pumpHost(tester);
        await tester.pump();
        await pushUnderlay(tester);

        keys.emitPress();
        await settle(tester);
        await tester.tap(find.byKey(const Key('power_shut_down')));
        await settle(tester);
        pedalEvents.add(const ButtonPressed(PedalButton.recPlay));
        await settle(tester);

        expect(cubit.state.phase, PowerPhase.idle);
        expect(find.byKey(const Key('console_rename_sheet')), findsNothing);
        expect(find.byKey(const Key('power_dialog')), findsNothing);
        expect(find.byKey(const Key('power_underlay')), findsOneWidget);
        expect(log, isEmpty);
        verifyNever(() => session.saveAs(any()));
      },
    );
  });
}
