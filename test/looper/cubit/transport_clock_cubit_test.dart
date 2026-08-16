import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:segno/looper/cubit/transport_clock_cubit.dart';
import 'package:segno_engine/segno_engine.dart' as engine;

import '../../helpers/helpers.dart';

class _MockLooperRepository extends Mock implements LooperRepository {}

/// A hand-driven [Stopwatch]: `fake_async` fakes `Timer`, not the monotonic
/// tick source, so the cubit's watch is injected and advanced in lockstep
/// with the fake clock. Mirrors the real semantics — [advance] accumulates
/// only while running, [reset] keeps a running watch running.
class _FakeStopwatch implements Stopwatch {
  Duration _elapsed = Duration.zero;
  bool _running = false;

  void advance(Duration duration) {
    if (_running) _elapsed += duration;
  }

  @override
  void start() => _running = true;

  @override
  void stop() => _running = false;

  @override
  void reset() => _elapsed = Duration.zero;

  @override
  bool get isRunning => _running;

  @override
  Duration get elapsed => _elapsed;

  @override
  int get elapsedMicroseconds => _elapsed.inMicroseconds;

  @override
  int get elapsedMilliseconds => _elapsed.inMilliseconds;

  @override
  int get elapsedTicks => _elapsed.inMicroseconds;

  @override
  int get frequency => 1000000;
}

void main() {
  late _MockLooperRepository repository;
  late StreamController<LooperState> states;
  late StreamController<void> rigReplaced;
  late _FakeStopwatch watch;

  setUp(() {
    repository = _MockLooperRepository();
    states = StreamController<LooperState>.broadcast();
    rigReplaced = StreamController<void>.broadcast();
    watch = _FakeStopwatch();
    when(() => repository.looperState).thenAnswer((_) => states.stream);
    when(() => repository.rigReplaced).thenAnswer((_) => rigReplaced.stream);
    when(() => repository.state).thenReturn(const LooperState());
  });

  tearDown(() {
    unawaited(states.close());
    unawaited(rigReplaced.close());
  });

  TransportClockCubit build() =>
      TransportClockCubit(repository: repository, stopwatch: watch);

  void elapse(FakeAsync async, Duration duration) {
    watch.advance(duration);
    async.elapse(duration);
  }

  const playing = LooperState(
    tracks: [Track(state: TrackState.playing, lengthFrames: 48000)],
  );
  const stoppedWithContent = LooperState(
    tracks: [Track(state: TrackState.stopped, lengthFrames: 48000)],
  );
  const cleared = LooperState(tracks: [Track()]);
  const recordingFirstTake = LooperState(
    tracks: [Track(state: TrackState.recording)],
  );
  const countingIn = LooperState(
    transport: TransportState(countingIn: true),
  );

  group('TransportClockCubit', () {
    test('reads zero, stopped, on an idle rig', () {
      fakeAsync((async) {
        final cubit = build();
        expect(cubit.state.elapsed, Duration.zero);
        expect(cubit.state.running, isFalse);
        unawaited(cubit.close());
        async.flushMicrotasks();
      });
    });

    test('counts monotonic time while a track plays', () {
      fakeAsync((async) {
        final cubit = build();
        states.add(playing);
        async.flushMicrotasks();
        expect(cubit.state.running, isTrue);

        elapse(async, const Duration(seconds: 3));
        expect(cubit.state.elapsed, const Duration(seconds: 3));

        unawaited(cubit.close());
        async.flushMicrotasks();
      });
    });

    test('truncates to whole seconds — the displayed granularity', () {
      fakeAsync((async) {
        final cubit = build();
        states.add(playing);
        async.flushMicrotasks();

        elapse(async, const Duration(milliseconds: 1500));
        expect(cubit.state.elapsed, const Duration(seconds: 1));

        unawaited(cubit.close());
        async.flushMicrotasks();
      });
    });

    test('holds (does not reset) across a stop', () {
      fakeAsync((async) {
        final cubit = build();
        states.add(playing);
        async.flushMicrotasks();
        elapse(async, const Duration(seconds: 3));

        states.add(stoppedWithContent);
        async.flushMicrotasks();
        expect(cubit.state.running, isFalse);
        expect(cubit.state.elapsed, const Duration(seconds: 3));

        // A stopped clock does not creep: a minute of silence adds nothing.
        elapse(async, const Duration(minutes: 1));
        expect(cubit.state.elapsed, const Duration(seconds: 3));

        unawaited(cubit.close());
        async.flushMicrotasks();
      });
    });

    test('resumes on top of the held time when the transport runs again', () {
      fakeAsync((async) {
        final cubit = build();
        states.add(playing);
        async.flushMicrotasks();
        elapse(async, const Duration(seconds: 3));
        states.add(stoppedWithContent);
        async.flushMicrotasks();
        elapse(async, const Duration(seconds: 30));

        states.add(playing);
        async.flushMicrotasks();
        elapse(async, const Duration(seconds: 2));
        expect(cubit.state.elapsed, const Duration(seconds: 5));

        unawaited(cubit.close());
        async.flushMicrotasks();
      });
    });

    test('resets when the repository announces a rig replacement', () {
      fakeAsync((async) {
        final cubit = build();
        states.add(playing);
        async.flushMicrotasks();
        elapse(async, const Duration(seconds: 3));
        states.add(stoppedWithContent);
        async.flushMicrotasks();
        expect(cubit.state.elapsed, const Duration(seconds: 3));

        // The load-bearing session-load reset: the explicit event, with NO
        // cleared state ever crossing the projection stream (the load's
        // cleared window is transient and the poller frequently misses it).
        rigReplaced.add(null);
        async.flushMicrotasks();
        expect(cubit.state.elapsed, Duration.zero);

        unawaited(cubit.close());
        async.flushMicrotasks();
      });
    });

    test('a replacement landing mid-run restarts the count from zero', () {
      fakeAsync((async) {
        final cubit = build();
        states.add(playing);
        async.flushMicrotasks();
        elapse(async, const Duration(seconds: 3));

        rigReplaced.add(null);
        async.flushMicrotasks();
        expect(cubit.state.elapsed, Duration.zero);

        // Stopwatch.reset keeps a running watch running: still counting.
        elapse(async, const Duration(seconds: 2));
        expect(cubit.state.elapsed, const Duration(seconds: 2));

        unawaited(cubit.close());
        async.flushMicrotasks();
      });
    });

    test('resets when the rig empties in place — the projection fallback', () {
      fakeAsync((async) {
        final cubit = build();
        states.add(playing);
        async.flushMicrotasks();
        elapse(async, const Duration(seconds: 3));

        // The user's clear-all: emptied IN PLACE, so unlike a session load
        // the empty state is stable and the stream does carry it.
        states.add(cleared);
        async.flushMicrotasks();
        expect(cubit.state.elapsed, Duration.zero);
        expect(cubit.state.running, isFalse);

        unawaited(cubit.close());
        async.flushMicrotasks();
      });
    });

    test('does not reset while the FIRST take is still capturing', () {
      fakeAsync((async) {
        // A recording track has no content until the loop closes; the reset
        // must never zero a clock that is counting that very take.
        final cubit = build();
        states.add(recordingFirstTake);
        async.flushMicrotasks();
        expect(cubit.state.running, isTrue);

        elapse(async, const Duration(seconds: 2));
        states.add(recordingFirstTake);
        async.flushMicrotasks();
        expect(cubit.state.elapsed, const Duration(seconds: 2));

        unawaited(cubit.close());
        async.flushMicrotasks();
      });
    });

    test('a count-in counts as running — the click is already sounding', () {
      fakeAsync((async) {
        final cubit = build();
        states.add(countingIn);
        async.flushMicrotasks();
        expect(cubit.state.running, isTrue);

        elapse(async, const Duration(seconds: 2));
        expect(cubit.state.elapsed, const Duration(seconds: 2));

        unawaited(cubit.close());
        async.flushMicrotasks();
      });
    });

    test('seeds from the live snapshot: created mid-run, it counts NOW', () {
      fakeAsync((async) {
        when(() => repository.state).thenReturn(playing);
        final cubit = build();
        expect(cubit.state.running, isTrue);

        elapse(async, const Duration(seconds: 2));
        expect(cubit.state.elapsed, const Duration(seconds: 2));

        unawaited(cubit.close());
        async.flushMicrotasks();
      });
    });

    test('close cancels the ticker mid-run', () {
      fakeAsync((async) {
        final cubit = build();
        states.add(playing);
        async.flushMicrotasks();
        unawaited(cubit.close());
        async.flushMicrotasks();

        // A live ticker would throw emitting on a closed cubit.
        expect(
          () => elapse(async, const Duration(seconds: 2)),
          returnsNormally,
        );
      });
    });
  });

  group('TransportClockCubit over the real repository', () {
    test('a REAL applySession resets the clock even though the projection '
        'never emits the transient cleared window', () async {
      // The real pipeline end to end: LooperRepository.applySession →
      // rigReplaced → the cubit's reset. The poll ticker is never fired
      // after the load, so the projection stream NEVER carries the cleared
      // rig — exactly the race on the appliance, where the load's cleared
      // window is a few ms of synchronous FFI import between polls. Only the
      // explicit seam can reset the clock here.
      final fakeEngine = FakeAudioEngine()
        ..nextSnapshot = const engine.EngineSnapshot(
          isRunning: true,
          sampleRate: 48000,
          bufferFrames: 128,
          framesProcessed: 0,
          xrunCount: 0,
          inputRms: 0,
          inputPeak: 0,
          outputRms: 0,
          latencyState: engine.LatencyState.idle,
          measuredLatencyMs: -1,
          masterLengthFrames: 96000,
          masterPositionFrames: 24000,
          tracks: [
            engine.TrackSnapshot(
              state: TrackState.playing,
              volume: 1,
              muted: false,
              lengthFrames: 96000,
              undoDepth: 0,
              rms: 0,
              peak: 0,
            ),
          ],
        );
      final ticker = StreamController<void>.broadcast();
      addTearDown(ticker.close);
      final repo = LooperRepository(
        engine: fakeEngine,
        ticker: ticker.stream,
      )..startEngine(const EngineConfig());
      addTearDown(repo.dispose);

      final clockWatch = _FakeStopwatch();
      final cubit = TransportClockCubit(
        repository: repo,
        stopwatch: clockWatch,
      );
      addTearDown(cubit.close);

      // Seeded from the playing snapshot: counting.
      expect(cubit.state.running, isTrue);
      clockWatch.advance(const Duration(seconds: 3));
      ticker.add(null); // one poll while still playing
      await Future<void>.delayed(Duration.zero);
      expect(cubit.state.elapsed, const Duration(seconds: 3));

      // The engine settles empty for the load itself (applySession reads
      // snapshots directly) — but no poll tick ever projects it.
      fakeEngine.nextSnapshot = const engine.EngineSnapshot.initial();
      await repo.applySession(
        const SessionRig(),
        clearPollInterval: Duration.zero,
      );
      await Future<void>.delayed(Duration.zero);

      expect(cubit.state.elapsed, Duration.zero);
    });
  });
}
