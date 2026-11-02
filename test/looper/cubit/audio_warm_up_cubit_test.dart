import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:operation_guards/operation_guards.dart';
import 'package:segno/looper/looper.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

class _MockLooperRepository extends Mock implements LooperRepository {}

const _target = EngineConfig(
  sampleRate: 48000,
  bufferFrames: 32,
  playbackDeviceId: 'scarlett',
);

LooperState _state({
  bool warmingUp = true,
  bool present = true,
}) => LooperState(
  status: EngineStatus(
    deviceName: 'Scarlett 4i4',
    sampleRate: 48000,
    bufferFrames: warmingUp ? kWarmUpBufferFrames : 32,
    isConnected: true,
    devicePresent: present,
    warmingUp: warmingUp,
  ),
);

CallbackTelemetry _telemetry({int late = 0, int gaps = 0, int xruns = 0}) =>
    CallbackTelemetry(
      session: CallbackWindowStats(
        latePeriods: late,
        gapEvents: gaps,
        xruns: [xruns, 0, 0, 0],
      ),
    );

/// The warm-up's settle rule (#1533): it watches from `ready` on, switches
/// once the callback has run a quiet window with no new fault, switches
/// anyway at the cap, and sets the player's record offset before the switch.
void main() {
  group('AudioWarmUpCubit', () {
    late _MockLooperRepository looper;
    late SettingsRepository settings;
    late GuardRegistry guards;
    late StreamController<void> ticker;
    late StreamController<LooperState> states;
    late LooperState state;
    late CallbackTelemetry telemetry;
    late List<String> calls;
    late AudioApplyResult finishResult;

    setUp(() async {
      looper = _MockLooperRepository();
      settings = SettingsRepository(store: FakeKeyValueStore());
      guards = GuardRegistry();
      ticker = StreamController<void>.broadcast();
      states = StreamController<LooperState>.broadcast();
      state = _state();
      telemetry = _telemetry();
      calls = [];
      finishResult = const AudioApplyResult(
        status: AudioApplyStatus.applied,
        result: EngineResult.ok,
      );
      when(() => looper.state).thenAnswer((_) => state);
      when(() => looper.looperState).thenAnswer((_) => states.stream);
      when(() => looper.lastEngineConfig).thenReturn(_target);
      when(looper.readCallbackTelemetry).thenAnswer((_) => telemetry);
      when(() => looper.setRecordOffset(any())).thenAnswer((invocation) {
        calls.add('offset ${invocation.positionalArguments.single}');
        return EngineResult.ok;
      });
      when(looper.finishWarmUp).thenAnswer((_) {
        calls.add('finish');
        if (finishResult.result != EngineResult.notReady) {
          state = _state(warmingUp: false);
          states.add(state);
        }
        return finishResult;
      });
    });

    tearDown(() async {
      await ticker.close();
      await states.close();
    });

    Future<void> publish(LooperState next) async {
      state = next;
      states.add(next);
      await pumpEventQueue();
    }

    Future<AudioWarmUpCubit> build({Future<void> Function()? ready}) async {
      final cubit = AudioWarmUpCubit(
        looper: looper,
        settings: settings,
        guards: guards,
        ready: ready,
        ticker: ticker.stream,
        // Three quiet ticks settle; the sixth tick is the cap.
        interval: const Duration(seconds: 1),
        cap: const Duration(seconds: 6),
      );
      addTearDown(cubit.close);
      await cubit.load();
      return cubit;
    }

    Future<void> tick([int count = 1]) async {
      for (var i = 0; i < count; i++) {
        ticker.add(null);
        await pumpEventQueue();
      }
    }

    test('does nothing while no warm-up runs', () async {
      state = _state(warmingUp: false);
      final cubit = await build();

      await tick(10);

      expect(cubit.state.status, AudioWarmUpStatus.idle);
      verifyNever(looper.finishWarmUp);
      verifyNever(looper.readCallbackTelemetry);
    });

    test('ticks only while a warm-up runs', () async {
      state = _state(warmingUp: false);
      final cubit = AudioWarmUpCubit(
        looper: looper,
        settings: settings,
        guards: guards,
        interval: const Duration(milliseconds: 10),
      );
      await cubit.load();

      // No periodic timer runs while nothing warms up: the test would fail
      // on a pending timer otherwise.
      await publish(_state());
      expect(cubit.state.status, AudioWarmUpStatus.settling);
      await publish(_state(warmingUp: false));
      expect(cubit.state.status, AudioWarmUpStatus.idle);
      await cubit.close();
    });

    test('watches only once the startup work is done', () async {
      final ready = Completer<void>();
      final cubit = AudioWarmUpCubit(
        looper: looper,
        settings: settings,
        guards: guards,
        ready: () => ready.future,
        ticker: ticker.stream,
        interval: const Duration(seconds: 1),
        cap: const Duration(seconds: 30),
      );
      addTearDown(cubit.close);
      await cubit.load();

      // Quiet ticks before the first frame do not count.
      await tick(10);
      verifyNever(looper.finishWarmUp);
      verifyNever(looper.readCallbackTelemetry);

      ready.complete();
      await pumpEventQueue();
      await tick(3);
      verifyNever(looper.finishWarmUp);
      expect(cubit.state.status, AudioWarmUpStatus.settling);
      await tick();
      verify(looper.finishWarmUp).called(1);
    });

    test('switches after a quiet window, setting the offset saved for the '
        "player's buffer first", () async {
      await settings.saveLatencyOffsetFrames(
        device: 'Scarlett 4i4',
        sampleRate: 48000,
        bufferFrames: 32,
        frames: 300,
      );
      // The warm-up buffer's own profile is not the one restored.
      await settings.saveLatencyOffsetFrames(
        device: 'Scarlett 4i4',
        sampleRate: 48000,
        bufferFrames: kWarmUpBufferFrames,
        frames: 900,
      );
      final cubit = await build();

      // The first tick takes the baseline; three more without a new fault
      // settle it.
      await tick(3);
      verifyNever(looper.finishWarmUp);
      await tick();

      expect(calls, ['offset 300', 'finish']);
      await tick();
      expect(cubit.state.status, AudioWarmUpStatus.idle);
    });

    test('a refused switch sets the offset of the config that runs', () async {
      await settings.saveLatencyOffsetFrames(
        device: 'Scarlett 4i4',
        sampleRate: 48000,
        bufferFrames: 32,
        frames: 300,
      );
      await settings.saveLatencyOffsetFrames(
        device: 'Scarlett 4i4',
        sampleRate: 48000,
        bufferFrames: kWarmUpBufferFrames,
        frames: 900,
      );
      finishResult = const AudioApplyResult(
        status: AudioApplyStatus.refused,
        result: EngineResult.device,
      );
      await build();

      await tick(4);

      expect(calls, ['offset 300', 'finish', 'offset 900']);
    });

    test('a screen that never draws still lets the switch happen', () async {
      final cubit = AudioWarmUpCubit(
        looper: looper,
        settings: settings,
        guards: guards,
        ready: () => Completer<void>().future,
        ticker: ticker.stream,
        interval: const Duration(seconds: 1),
        cap: const Duration(seconds: 6),
      );
      addTearDown(cubit.close);

      await cubit.load();
      await tick(5);
      verifyNever(looper.finishWarmUp);
      await tick();

      verify(looper.finishWarmUp).called(1);
    });

    test('a buffer the device rounded gets the offset of the buffer it '
        'opened', () async {
      await settings.saveLatencyOffsetFrames(
        device: 'Scarlett 4i4',
        sampleRate: 48000,
        bufferFrames: 32,
        frames: 300,
      );
      await settings.saveLatencyOffsetFrames(
        device: 'Scarlett 4i4',
        sampleRate: 48000,
        bufferFrames: 48,
        frames: 420,
      );
      when(looper.finishWarmUp).thenAnswer((_) {
        calls.add('finish');
        // Asked 32, opened 48: the transport waits for 48's offset.
        state = LooperState(
          status: EngineStatus(
            deviceName: 'Scarlett 4i4',
            sampleRate: 48000,
            bufferFrames: 48,
            isConnected: true,
            devicePresent: true,
            warmingUp: true,
          ),
        );
        return finishResult;
      });
      final cubit = await build();

      await tick(4);

      expect(calls, ['offset 300', 'finish', 'offset 420']);
      verify(looper.finishWarmUp).called(1);
      expect(cubit.state.status, AudioWarmUpStatus.settling);
    });

    test('an unmeasured profile switches with no offset', () async {
      await build();

      await tick(4);

      expect(calls, ['offset 0', 'finish']);
    });

    test('a new fault restarts the quiet window', () async {
      await build();

      await tick(3);
      telemetry = _telemetry(gaps: 1);
      await tick();
      verifyNever(looper.finishWarmUp);
      // The cap is two ticks away, the quiet window three: the cap wins.
      await tick();
      verifyNever(looper.finishWarmUp);
      await tick();
      verify(looper.finishWarmUp).called(1);
    });

    test('the cap switches while faults keep coming', () async {
      await build();

      for (var i = 1; i <= 5; i++) {
        telemetry = _telemetry(late: i, xruns: i);
        await tick();
      }
      verifyNever(looper.finishWarmUp);
      telemetry = _telemetry(late: 6, xruns: 6);
      await tick();

      verify(looper.finishWarmUp).called(1);
    });

    test('a missing device restarts the count', () async {
      await build();

      await tick(3);
      await publish(_state(present: false));
      await tick();
      await publish(_state());
      await tick(3);
      verifyNever(looper.finishWarmUp);
      await tick();

      verify(looper.finishWarmUp).called(1);
    });

    test('an operation holding the device defers the switch', () async {
      final capture = guards.enter(
        GuardKind.capture,
        const GuardScope.internal(),
        purpose: 'test',
      );
      await build();

      await tick(6);
      verifyNever(looper.finishWarmUp);

      capture.release();
      await tick();

      verify(looper.finishWarmUp).called(1);
    });

    test('a refused admission is tried again on the next tick', () async {
      finishResult = const AudioApplyResult(
        status: AudioApplyStatus.refused,
        result: EngineResult.notReady,
      );
      await build();

      await tick(4);
      verify(looper.finishWarmUp).called(1);

      finishResult = const AudioApplyResult(
        status: AudioApplyStatus.applied,
        result: EngineResult.ok,
      );
      await tick();

      verify(looper.finishWarmUp).called(1);
      await tick(5);
      verifyNever(looper.finishWarmUp);
    });

    test('a warm-up after a reconnect is followed the same way', () async {
      await build();

      await tick(4);
      verify(looper.finishWarmUp).called(1);
      await tick(3);

      // The interface came back: the supervisor opened a warm-up again.
      await publish(_state());
      await tick(3);
      verifyNever(looper.finishWarmUp);
      await tick();

      verify(looper.finishWarmUp).called(1);
    });
  });
}
