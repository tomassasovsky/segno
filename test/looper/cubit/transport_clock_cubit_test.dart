import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:segno/looper/cubit/transport_clock_cubit.dart';

class _MockLooperRepository extends Mock implements LooperRepository {}

void main() {
  late _MockLooperRepository repository;
  late StreamController<LooperState> states;

  /// The injectable wall clock, advanced in lockstep with FakeAsync's timers
  /// by [elapse] — fake_async fakes `Timer`, not `DateTime.now()`.
  late DateTime wall;

  setUp(() {
    repository = _MockLooperRepository();
    states = StreamController<LooperState>.broadcast();
    wall = DateTime(2026, 8, 14);
    when(() => repository.looperState).thenAnswer((_) => states.stream);
    when(() => repository.state).thenReturn(const LooperState());
  });

  tearDown(() => states.close());

  TransportClockCubit build() =>
      TransportClockCubit(repository: repository, now: () => wall);

  void elapse(FakeAsync async, Duration duration) {
    wall = wall.add(duration);
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

    test('counts wall time while a track plays', () {
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

    test('resets to zero when the rig empties', () {
      fakeAsync((async) {
        final cubit = build();
        states.add(playing);
        async.flushMicrotasks();
        elapse(async, const Duration(seconds: 3));

        // Clear-all (or a session load's clear-then-import): stopped AND no
        // content — the performance the clock was timing no longer exists.
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
}
