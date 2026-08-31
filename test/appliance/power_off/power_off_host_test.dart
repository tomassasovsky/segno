import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/appliance/power_off/power_key_source.dart';
import 'package:segno/appliance/power_off/power_off_cubit.dart';
import 'package:segno/appliance/power_off/power_off_host.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/performance/cubit/performance_recorder_cubit.dart';
import 'package:segno/session/cubit/session_cubit.dart';
import 'package:session_repository/session_repository.dart';

import '../../helpers/helpers.dart';
import 'fake_power_key_source.dart';

class _MockLooperBloc extends MockBloc<LooperEvent, LooperState>
    implements LooperBloc {}

class _MockSessionCubit extends MockCubit<SessionState>
    implements SessionCubit {}

class _MockRecorder extends MockCubit<PerformanceRecorderState>
    implements PerformanceRecorderCubit {}

class _MockPedalRepository extends Mock implements PedalRepository {}

const _loops = LooperState(
  tracks: [Track(state: TrackState.playing, lengthFrames: 48000)],
);

void main() {
  group(PowerOffHost, () {
    late FakePowerKeySource keys;
    late PowerOffCubit cubit;
    late _MockLooperBloc looper;
    late _MockSessionCubit session;
    late _MockRecorder recorder;
    late _MockPedalRepository pedal;
    late StreamController<PedalEvent> pedalEvents;
    late List<String> log;

    setUpAll(() {
      registerFallbackValue(const LooperPersistFlush());
    });

    setUp(() {
      log = <String>[];
      keys = FakePowerKeySource();
      cubit = PowerOffCubit(
        flush: () => log.add('flush'),
        pedalGoodbye: () => log.add('pedal'),
        powerOff: () async => log.add('powerOff'),
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

    Future<void> pumpHost(WidgetTester tester) async {
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
              BlocProvider<PowerOffCubit>.value(value: cubit),
              BlocProvider<LooperBloc>.value(value: looper),
              BlocProvider<PerformanceRecorderCubit>.value(value: recorder),
              BlocProvider<SessionCubit>.value(value: session),
            ],
            child: const PowerOffHost(
              child: Scaffold(
                body: SizedBox(key: Key('power_off_host_child')),
              ),
            ),
          ),
        ),
      );
    }

    Future<void> openConfirm(WidgetTester tester) async {
      await pumpHost(tester);
      await tester.pump();
      keys.emitPress();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    testWidgets('press with loops opens the three-choice dialog', (
      tester,
    ) async {
      await openConfirm(tester);

      expect(find.byKey(const Key('power_off_dialog')), findsOneWidget);
      expect(find.byKey(const Key('power_off_save')), findsOneWidget);
      expect(cubit.state.phase, PowerOffPhase.confirm);
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
      await pumpHost(tester);
      await tester.pump();
      keys.emitPress();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(cubit.state.phase, PowerOffPhase.refuse);
      expect(find.text('Stop the take first'), findsOneWidget);
      expect(find.byKey(const Key('power_off_save')), findsNothing);

      await tester.tap(find.byKey(const Key('power_off_keep_playing')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(cubit.state.phase, PowerOffPhase.idle);
      expect(find.byKey(const Key('power_off_dialog')), findsNothing);
      expect(find.byKey(const Key('power_off_host_child')), findsOneWidget);
      expect(log, isEmpty);
    });

    testWidgets('Keep playing pops only the power-off dialog', (tester) async {
      await openConfirm(tester);

      await tester.tap(find.byKey(const Key('power_off_keep_playing')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byKey(const Key('power_off_dialog')), findsNothing);
      expect(find.byKey(const Key('power_off_host_child')), findsOneWidget);
      expect(cubit.state.phase, PowerOffPhase.idle);
      expect(log, isEmpty);

      keys.emitPress();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const Key('power_off_dialog')), findsOneWidget);
      expect(cubit.state.phase, PowerOffPhase.confirm);
    });

    testWidgets('scrim and pedal map to Keep playing', (tester) async {
      await openConfirm(tester);

      await tester.tapAt(const Offset(4, 4));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(cubit.state.phase, PowerOffPhase.idle);
      expect(find.byKey(const Key('power_off_dialog')), findsNothing);

      keys.emitPress();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      pedalEvents.add(const ButtonPressed(PedalButton.recPlay));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(cubit.state.phase, PowerOffPhase.idle);
      expect(log, isEmpty);
    });

    testWidgets('Save As cancel aborts halt and does not save', (tester) async {
      await openConfirm(tester);

      await tester.tap(find.byKey(const Key('power_off_save')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const Key('console_rename_sheet')), findsOneWidget);
      expect(cubit.state.phase, PowerOffPhase.saveAs);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(cubit.state.phase, PowerOffPhase.idle);
      expect(find.byKey(const Key('console_rename_sheet')), findsNothing);
      expect(log, isEmpty);
      verifyNever(() => session.saveAs(any()));
    });

    testWidgets(
      'Save As invalid name shows a snackbar and stays on the sheet',
      (
        tester,
      ) async {
        await openConfirm(tester);
        await tester.tap(find.byKey(const Key('power_off_save')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));

        await tester.sendKeyEvent(
          LogicalKeyboardKey.digit1,
          character: '!',
        );
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));

        expect(cubit.state.phase, PowerOffPhase.saveAs);
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
          sessions: [SessionSummary(name: 'jam')],
        ),
      );
      await openConfirm(tester);
      await tester.tap(find.byKey(const Key('power_off_save')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      for (final ch in 'jam'.split('')) {
        await tester.sendKeyEvent(LogicalKeyboardKey.keyA, character: ch);
      }
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(cubit.state.phase, PowerOffPhase.saveAs);
      expect(
        find.text('A session named “jam” already exists.'),
        findsOneWidget,
      );
      expect(log, isEmpty);
      verifyNever(() => session.saveAs(any()));
    });

    testWidgets('pedal Keep playing pops Save As and does not save afterward', (
      tester,
    ) async {
      await openConfirm(tester);
      await tester.tap(find.byKey(const Key('power_off_save')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      pedalEvents.add(const ButtonPressed(PedalButton.recPlay));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(cubit.state.phase, PowerOffPhase.idle);
      expect(find.byKey(const Key('console_rename_sheet')), findsNothing);
      expect(find.byKey(const Key('power_off_dialog')), findsNothing);
      verifyNever(() => session.saveAs(any()));
    });

    testWidgets('empty console skips confirm and flushes the page bloc', (
      tester,
    ) async {
      whenListen(
        looper,
        const Stream<LooperState>.empty(),
        initialState: const LooperState(),
      );
      await pumpHost(tester);
      await tester.pump();
      keys.emitPress();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byKey(const Key('power_off_dialog')), findsNothing);
      expect(cubit.state.phase, PowerOffPhase.goodbye);
      expect(log, ['flush', 'pedal', 'powerOff']);
      verify(() => looper.add(const LooperPersistFlush())).called(1);
    });

    testWidgets('named Save success halts and does not open Save As', (
      tester,
    ) async {
      whenListen(
        session,
        const Stream<SessionState>.empty(),
        initialState: const SessionState(currentSessionName: 'set'),
      );
      await openConfirm(tester);

      await tester.tap(find.byKey(const Key('power_off_save')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byKey(const Key('console_rename_sheet')), findsNothing);
      expect(cubit.state.phase, PowerOffPhase.goodbye);
      expect(log, ['flush', 'pedal', 'powerOff']);
      verify(() => session.save()).called(1);
      verifyNever(() => session.saveAs(any()));
    });

    testWidgets(
      'named Save failure reopens save-failed and does not halt',
      (tester) async {
        whenListen(
          session,
          const Stream<SessionState>.empty(),
          initialState: const SessionState(currentSessionName: 'set'),
        );
        when(() => session.save()).thenAnswer((_) async {
          when(() => session.state).thenReturn(
            const SessionState(
              currentSessionName: 'set',
              status: SessionStatus.failure,
              errorMessage: 'disk full',
            ),
          );
        });
        await openConfirm(tester);

        await tester.tap(find.byKey(const Key('power_off_save')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));

        expect(cubit.state.phase, PowerOffPhase.saveFailed);
        expect(find.text("Couldn't save"), findsOneWidget);
        expect(find.byKey(const Key('power_off_save')), findsOneWidget);
        expect(log, isEmpty);
        verifyNever(() => session.saveAs(any()));

        await tester.tap(find.byKey(const Key('power_off_keep_playing')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(cubit.state.phase, PowerOffPhase.idle);
        expect(find.byKey(const Key('power_off_dialog')), findsNothing);
        expect(log, isEmpty);
      },
    );

    testWidgets('discard flushes then pedal goodbye then powerOff', (
      tester,
    ) async {
      await openConfirm(tester);

      await tester.tap(find.byKey(const Key('power_off_discard')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byKey(const Key('power_off_dialog')), findsNothing);
      expect(cubit.state.phase, PowerOffPhase.goodbye);
      expect(log, ['flush', 'pedal', 'powerOff']);
    });

    testWidgets('Save As success halts and does not pop a route underneath', (
      tester,
    ) async {
      await pumpHost(tester);
      await tester.pump();
      Navigator.of(
        tester.element(find.byKey(const Key('power_off_host_child'))),
        rootNavigator: true,
      ).push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(
            body: SizedBox(key: Key('power_off_underlay')),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      keys.emitPress();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byKey(const Key('power_off_save')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      for (final ch in 'jam'.split('')) {
        await tester.sendKeyEvent(LogicalKeyboardKey.keyA, character: ch);
      }
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(cubit.state.phase, PowerOffPhase.goodbye);
      expect(log, ['flush', 'pedal', 'powerOff']);
      verify(() => session.saveAs('jam')).called(1);
      expect(find.byKey(const Key('power_off_underlay')), findsOneWidget);
    });

    testWidgets('Save As failure reopens save-failed and does not halt', (
      tester,
    ) async {
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
      Navigator.of(
        tester.element(find.byKey(const Key('power_off_host_child'))),
        rootNavigator: true,
      ).push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(
            body: SizedBox(key: Key('power_off_underlay')),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      keys.emitPress();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byKey(const Key('power_off_save')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      for (final ch in 'jam'.split('')) {
        await tester.sendKeyEvent(LogicalKeyboardKey.keyA, character: ch);
      }
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(cubit.state.phase, PowerOffPhase.saveFailed);
      expect(find.byKey(const Key('power_off_dialog')), findsOneWidget);
      expect(find.text("Couldn't save"), findsOneWidget);
      expect(find.byKey(const Key('power_off_underlay')), findsOneWidget);
      expect(log, isEmpty);
    });

    testWidgets(
      'pedal during Save As pops only the sheet, not a route underneath',
      (tester) async {
        await pumpHost(tester);
        await tester.pump();
        Navigator.of(
          tester.element(find.byKey(const Key('power_off_host_child'))),
          rootNavigator: true,
        ).push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(
              body: SizedBox(key: Key('power_off_underlay')),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));

        keys.emitPress();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.tap(find.byKey(const Key('power_off_save')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        pedalEvents.add(const ButtonPressed(PedalButton.recPlay));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));

        expect(cubit.state.phase, PowerOffPhase.idle);
        expect(find.byKey(const Key('power_off_dialog')), findsNothing);
        expect(find.byKey(const Key('power_off_underlay')), findsOneWidget);
        expect(log, isEmpty);
        verifyNever(() => session.saveAs(any()));
      },
    );
  });
}
