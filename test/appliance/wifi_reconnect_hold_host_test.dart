import 'dart:async';

import 'package:backing_repository/backing_repository.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:segno/appliance/wifi_reconnect_hold_host.dart';
import 'package:segno/backing/cubit/backing_cubit.dart';
import 'package:segno/backing/model/backing_state.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/performance/performance.dart';
import 'package:wifi_repository/wifi_repository.dart';

class _MockLooperBloc extends MockBloc<LooperEvent, LooperState>
    implements LooperBloc {}

class _MockPerformanceRecorderCubit extends MockCubit<PerformanceRecorderState>
    implements PerformanceRecorderCubit {}

class _MockBackingCubit extends MockCubit<BackingCubitState>
    implements BackingCubit {}

class _MockWifiRepository extends Mock implements WifiRepository {}

const _open = LooperState(transport: TransportState(isRunning: true));
const _playing = LooperState(
  transport: TransportState(isRunning: true),
  tracks: [Track(state: TrackState.playing)],
);

void main() {
  group('WifiReconnectHoldHost', () {
    late _MockLooperBloc looper;
    late StreamController<LooperState> looperStates;
    late _MockPerformanceRecorderCubit performance;
    late StreamController<PerformanceRecorderState> performanceStates;
    late _MockBackingCubit backing;
    late StreamController<BackingCubitState> backingStates;
    late _MockWifiRepository wifi;
    late List<bool> holds;

    Future<void> pump(WidgetTester tester) async {
      looper = _MockLooperBloc();
      looperStates = StreamController<LooperState>.broadcast();
      whenListen(
        looper,
        looperStates.stream,
        initialState: const LooperState(),
      );
      performance = _MockPerformanceRecorderCubit();
      performanceStates =
          StreamController<PerformanceRecorderState>.broadcast();
      whenListen(
        performance,
        performanceStates.stream,
        initialState: const PerformanceRecorderIdle(),
      );
      backing = _MockBackingCubit();
      backingStates = StreamController<BackingCubitState>.broadcast();
      whenListen(
        backing,
        backingStates.stream,
        initialState: const BackingCubitState(backing: BackingState()),
      );
      wifi = _MockWifiRepository();
      holds = [];
      when(
        () => wifi.holdReconnects(hold: any(named: 'hold')),
      ).thenAnswer((invocation) async {
        holds.add(invocation.namedArguments[#hold] as bool);
      });
      addTearDown(looperStates.close);
      addTearDown(performanceStates.close);
      addTearDown(backingStates.close);

      await tester.pumpWidget(
        RepositoryProvider<WifiRepository>.value(
          value: wifi,
          child: MultiBlocProvider(
            providers: [
              BlocProvider<LooperBloc>.value(value: looper),
              BlocProvider<PerformanceRecorderCubit>.value(value: performance),
              BlocProvider<BackingCubit>.value(value: backing),
            ],
            child: const WifiReconnectHoldHost(child: SizedBox()),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('releases at startup, clearing a hold a previous run left', (
      tester,
    ) async {
      await pump(tester);
      expect(holds, [false]);
    });

    testWidgets('holds while the music plays, writing only the change', (
      tester,
    ) async {
      await pump(tester);
      looperStates
        ..add(_playing)
        ..add(_playing)
        ..add(_playing);
      await tester.pump();
      expect(holds, [false, true]);

      looperStates.add(const LooperState());
      await tester.pump();
      expect(holds, [false, true, false]);
    });

    testWidgets('an open audio device alone does not hold', (tester) async {
      await pump(tester);
      looperStates.add(_open);
      await tester.pump();
      expect(holds, [false]);
    });

    testWidgets('holds while a backing track plays on its own', (
      tester,
    ) async {
      await pump(tester);
      backingStates.add(
        const BackingCubitState(
          backing: BackingState(
            player: BackingPlayerState(transport: BackingTransport.playing),
          ),
        ),
      );
      await tester.pump();
      expect(holds, [false, true]);
    });

    testWidgets('holds while a performance recording is armed', (
      tester,
    ) async {
      await pump(tester);
      performanceStates.add(
        const PerformanceRecorderArmed(elapsed: Duration.zero, overrun: false),
      );
      await tester.pump();
      expect(holds, [false, true]);
    });

    testWidgets('a write that fails does not stop the ones after it', (
      tester,
    ) async {
      await pump(tester);
      var calls = 0;
      when(
        () => wifi.holdReconnects(hold: any(named: 'hold')),
      ).thenAnswer((invocation) async {
        calls++;
        if (calls == 1) throw StateError('no /run/segno');
        holds.add(invocation.namedArguments[#hold] as bool);
      });
      looperStates.add(_playing);
      await tester.pump();
      looperStates.add(const LooperState());
      await tester.pump();
      expect(calls, 2);
      expect(holds, [false, false]);
    });

    testWidgets('releases a hold when it goes away', (tester) async {
      await pump(tester);
      looperStates.add(_playing);
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(holds, [false, true, false]);
    });
  });
}
