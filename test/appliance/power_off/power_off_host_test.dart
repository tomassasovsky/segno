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

import '../../helpers/helpers.dart';

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
  setUpAll(() {
    registerFallbackValue(const LooperPersistFlush());
  });

  late FakePowerKeySource keys;
  late PowerOffCubit cubit;
  late _MockLooperBloc looper;
  late _MockSessionCubit session;
  late _MockRecorder recorder;
  late _MockPedalRepository pedal;
  late StreamController<PedalEvent> pedalEvents;
  late List<String> log;

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
            child: SizedBox(key: Key('power_off_host_child')),
          ),
        ),
      ),
    );
  }

  group(PowerOffHost, () {
    testWidgets('press with loops opens the three-choice dialog', (
      tester,
    ) async {
      await pumpHost(tester);
      await tester.pump();
      keys.emitPress();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byKey(const Key('power_off_dialog')), findsOneWidget);
      expect(find.byKey(const Key('power_off_save')), findsOneWidget);
      expect(cubit.state.phase, PowerOffPhase.confirm);
    });

    testWidgets('Keep playing pops only the power-off dialog', (tester) async {
      await pumpHost(tester);
      await tester.pump();
      keys.emitPress();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      await tester.tap(find.byKey(const Key('power_off_keep_playing')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byKey(const Key('power_off_dialog')), findsNothing);
      expect(find.byKey(const Key('power_off_host_child')), findsOneWidget);
      expect(cubit.state.phase, PowerOffPhase.idle);
      expect(log, isEmpty);
    });

    testWidgets('scrim and pedal map to Keep playing', (tester) async {
      await pumpHost(tester);
      await tester.pump();
      keys.emitPress();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

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
      await pumpHost(tester);
      await tester.pump();
      keys.emitPress();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

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

    testWidgets('pedal Keep playing pops Save As and does not save afterward', (
      tester,
    ) async {
      await pumpHost(tester);
      await tester.pump();
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
      expect(find.byKey(const Key('console_rename_sheet')), findsNothing);
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
  });
}
