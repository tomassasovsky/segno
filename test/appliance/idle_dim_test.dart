import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:midi_device_repository/midi_device_repository.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:pedal_repository/testing.dart';
import 'package:segno/appliance/display_brightness_cubit.dart';
import 'package:segno/appliance/idle_dim_cubit.dart';
import 'package:segno/appliance/idle_dim_host.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/performance/performance.dart';
import 'package:settings_repository/settings_repository.dart';

import '../helpers/helpers.dart';

class _MockLooperBloc extends MockBloc<LooperEvent, LooperState>
    implements LooperBloc {}

class _MockPerformanceRecorderCubit extends MockCubit<PerformanceRecorderState>
    implements PerformanceRecorderCubit {}

const _playing = LooperState(
  transport: TransportState(isRunning: true),
);

void main() {
  late SettingsRepository settings;

  setUp(() => settings = SettingsRepository(store: FakeKeyValueStore()));

  group('IdleDimCubit', () {
    /// A cubit on a 120 s idle period, loaded inside [async].
    IdleDimCubit loaded(FakeAsync async) {
      unawaited(settings.saveIdleDimSeconds(120));
      async.flushMicrotasks();
      final cubit = IdleDimCubit(settings: settings);
      unawaited(cubit.load());
      async.flushMicrotasks();
      return cubit;
    }

    test('never is the default, and never dims', () {
      fakeAsync((async) {
        final cubit = IdleDimCubit(settings: settings);
        unawaited(cubit.load());
        async
          ..flushMicrotasks()
          ..elapse(const Duration(hours: 1));
        expect(cubit.state, const IdleDimState());
        unawaited(cubit.close());
      });
    });

    test('dims after 120 s of no activity, not before', () {
      fakeAsync((async) {
        final cubit = loaded(async);
        async.elapse(const Duration(seconds: 119));
        expect(cubit.state.dimmed, isFalse);
        async.elapse(const Duration(seconds: 1));
        expect(cubit.state.dimmed, isTrue);
        unawaited(cubit.close());
      });
    });

    test('activity wakes it and starts the period over', () {
      fakeAsync((async) {
        final cubit = loaded(async);
        async.elapse(const Duration(seconds: 100));
        cubit.activity();
        async.elapse(const Duration(seconds: 100));
        expect(cubit.state.dimmed, isFalse);
        async.elapse(const Duration(seconds: 20));
        expect(cubit.state.dimmed, isTrue);

        cubit.activity();
        expect(cubit.state.dimmed, isFalse);
        unawaited(cubit.close());
      });
    });

    test('never dims while the music plays; the period restarts when it '
        'stops', () {
      fakeAsync((async) {
        final cubit = loaded(async)..setBusy(busy: true);
        async.elapse(const Duration(minutes: 30));
        expect(cubit.state.dimmed, isFalse);

        cubit.setBusy(busy: false);
        async.elapse(const Duration(seconds: 119));
        expect(cubit.state.dimmed, isFalse);
        async.elapse(const Duration(seconds: 1));
        expect(cubit.state.dimmed, isTrue);
        unawaited(cubit.close());
      });
    });

    test('music starting wakes a dimmed console', () {
      fakeAsync((async) {
        final cubit = loaded(async);
        async.elapse(const Duration(seconds: 120));
        expect(cubit.state.dimmed, isTrue);
        cubit.setBusy(busy: true);
        expect(cubit.state.dimmed, isFalse);
        unawaited(cubit.close());
      });
    });

    test('a new period applies at once and is saved', () {
      fakeAsync((async) {
        final cubit = IdleDimCubit(settings: settings);
        unawaited(cubit.setSeconds(300));
        async.flushMicrotasks();
        expect(cubit.state.seconds, 300);
        async.elapse(const Duration(seconds: 300));
        expect(cubit.state.dimmed, isTrue);
        int? saved;
        unawaited(settings.loadIdleDimSeconds().then((s) => saved = s));
        async.flushMicrotasks();
        expect(saved, 300);
        unawaited(cubit.close());
      });
    });
  });

  group('idleKeepsAwake', () {
    const idle = PerformanceRecorderIdle();

    test('a stopped rig does not', () {
      expect(idleKeepsAwake(const LooperState(), idle), isFalse);
      expect(
        idleKeepsAwake(
          const LooperState(tracks: [Track(state: TrackState.stopped)]),
          idle,
        ),
        isFalse,
      );
    });

    test('the transport or a track playing does', () {
      expect(idleKeepsAwake(_playing, idle), isTrue);
      expect(
        idleKeepsAwake(
          const LooperState(tracks: [Track(state: TrackState.playing)]),
          idle,
        ),
        isTrue,
      );
    });

    test('a capture does', () {
      for (final state in [TrackState.recording, TrackState.overdubbing]) {
        expect(
          idleKeepsAwake(LooperState(tracks: [Track(state: state)]), idle),
          isTrue,
          reason: state.name,
        );
      }
    });

    test('a performance recording does', () {
      expect(
        idleKeepsAwake(
          const LooperState(),
          const PerformanceRecorderArmed(
            elapsed: Duration.zero,
            overrun: false,
          ),
        ),
        isTrue,
      );
    });
  });

  group('IdleDimHost', () {
    late IdleDimCubit idle;
    late DisplayBrightnessCubit brightness;
    late _MockLooperBloc looper;
    late StreamController<LooperState> looperStates;
    late _MockPerformanceRecorderCubit performance;
    late FakePedalLink link;
    late PedalRepository pedal;
    late int presses;

    Future<void> pump(WidgetTester tester) async {
      idle = IdleDimCubit(settings: settings);
      brightness = DisplayBrightnessCubit(settings: settings);
      looper = _MockLooperBloc();
      looperStates = StreamController<LooperState>.broadcast();
      whenListen(
        looper,
        looperStates.stream,
        initialState: const LooperState(),
      );
      performance = _MockPerformanceRecorderCubit();
      whenListen(
        performance,
        const Stream<PerformanceRecorderState>.empty(),
        initialState: const PerformanceRecorderIdle(),
      );
      link = FakePedalLink();
      pedal = PedalRepository(link);
      presses = 0;
      addTearDown(() => unawaited(idle.close()));
      addTearDown(() => unawaited(brightness.close()));
      addTearDown(looperStates.close);

      await tester.pumpWidget(
        MultiRepositoryProvider(
          providers: [
            RepositoryProvider.value(value: pedal),
            RepositoryProvider.value(
              value: MidiDeviceRepository(source: null, settings: settings),
            ),
          ],
          child: MultiBlocProvider(
            providers: [
              BlocProvider.value(value: idle),
              BlocProvider.value(value: brightness),
              BlocProvider<LooperBloc>.value(value: looper),
              BlocProvider<PerformanceRecorderCubit>.value(value: performance),
            ],
            child: MaterialApp(
              builder: (context, child) => IdleDimHost(child: child!),
              home: Scaffold(
                body: Center(
                  child: ElevatedButton(
                    key: const Key('control'),
                    onPressed: () => presses++,
                    child: const Text('Play'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await idle.setSeconds(120);
      await tester.pump();
    }

    testWidgets('the touch that wakes it does not reach the control under '
        'it', (tester) async {
      await pump(tester);
      await tester.pump(const Duration(seconds: 120));
      expect(idle.state.dimmed, isTrue);
      expect(brightness.state.dimmed, isTrue);

      await tester.tap(find.byKey(const Key('control')), warnIfMissed: false);
      await tester.pump();
      expect(presses, 0);
      expect(idle.state.dimmed, isFalse);
      expect(brightness.state.dimmed, isFalse);
      expect(brightness.state.shownOf(DisplayRole.main), 0.8);

      // Awake, the next touch is a press, and it starts the period over.
      await tester.tap(find.byKey(const Key('control')));
      await tester.pump(const Duration(seconds: 119));
      expect(presses, 1);
      expect(idle.state.dimmed, isFalse);
      unawaited(idle.close());
    });

    testWidgets('the encoder wakes it', (tester) async {
      await pump(tester);
      await tester.pump(const Duration(seconds: 120));
      expect(idle.state.dimmed, isTrue);

      link
        ..hello()
        ..turn(1);
      await tester.pump();
      expect(idle.state.dimmed, isFalse);
      unawaited(idle.close());
      unawaited(pedal.dispose());
    });

    testWidgets('playback keeps it awake', (tester) async {
      await pump(tester);
      looperStates.add(_playing);
      await tester.pump();
      await tester.pump(const Duration(minutes: 10));
      expect(idle.state.dimmed, isFalse);

      looperStates.add(const LooperState());
      await tester.pump();
      await tester.pump(const Duration(seconds: 120));
      expect(idle.state.dimmed, isTrue);
      unawaited(idle.close());
    });
  });
}
