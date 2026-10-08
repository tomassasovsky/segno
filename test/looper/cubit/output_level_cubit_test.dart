import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:segno/looper/cubit/output_level_cubit.dart';

class _MockLooperRepository extends Mock implements LooperRepository {}

/// -6.0 dBFS and -12.0 dBFS as absolute sample peaks.
const _minus6 = 0.501187;
const _minus12 = 0.251189;

LooperState _withPeak(double peak) =>
    LooperState(transport: TransportState(outputPeak: peak));

void main() {
  late _MockLooperRepository repository;
  late StreamController<LooperState> states;

  setUp(() {
    repository = _MockLooperRepository();
    states = StreamController<LooperState>.broadcast(sync: true);
    when(() => repository.looperState).thenAnswer((_) => states.stream);
    when(() => repository.state).thenReturn(const LooperState());
  });

  tearDown(() => unawaited(states.close()));

  // The cubit's default refresh interval.
  const refresh = Duration(milliseconds: 250);

  OutputLevelCubit build() => OutputLevelCubit(repository: repository);

  group('OutputLevelState.of', () {
    test('reads silence as no figure', () {
      expect(OutputLevelState.of(0), const OutputLevelState());
    });

    test('reads full scale as a clip', () {
      expect(
        OutputLevelState.of(1),
        const OutputLevelState(tenths: 0, clip: true),
      );
    });

    test('reads a peak in tenths of a dBFS', () {
      expect(OutputLevelState.of(_minus6), const OutputLevelState(tenths: -60));
    });
  });

  group(OutputLevelCubit, () {
    test('starts from the live peak', () {
      when(() => repository.state).thenReturn(_withPeak(_minus6));
      final cubit = build();
      addTearDown(cubit.close);

      expect(cubit.state, const OutputLevelState(tenths: -60));
    });

    test('does not follow every poll between refreshes', () {
      fakeAsync((async) {
        final cubit = build();
        final emitted = <OutputLevelState>[];
        final sub = cubit.stream.listen(emitted.add);

        for (var i = 0; i < 10; i++) {
          states.add(_withPeak(i.isEven ? _minus6 : _minus12));
          async.elapse(const Duration(milliseconds: 16));
        }
        // 160 ms in: no refresh yet.
        expect(emitted, isEmpty);

        unawaited(sub.cancel());
        unawaited(cubit.close());
      });
    });

    test('publishes the highest peak since the last refresh', () {
      fakeAsync((async) {
        final cubit = build();
        final emitted = <OutputLevelState>[];
        final sub = cubit.stream.listen(emitted.add);

        states
          ..add(_withPeak(_minus12))
          ..add(_withPeak(_minus6))
          ..add(_withPeak(_minus12));
        async.elapse(refresh);

        expect(emitted, [const OutputLevelState(tenths: -60)]);

        unawaited(sub.cancel());
        unawaited(cubit.close());
      });
    });

    test('keeps showing a steady level the repository stops repeating', () {
      fakeAsync((async) {
        final cubit = build();
        final emitted = <OutputLevelState>[];
        final sub = cubit.stream.listen(emitted.add);

        states.add(_withPeak(_minus6));
        // The repository drops identical states, so nothing arrives for a
        // whole second while the level holds.
        async.elapse(refresh * 4);

        expect(emitted, [const OutputLevelState(tenths: -60)]);
        expect(cubit.state, const OutputLevelState(tenths: -60));

        unawaited(sub.cancel());
        unawaited(cubit.close());
      });
    });

    test('rebuilds nothing while the figure holds', () {
      fakeAsync((async) {
        final cubit = build();
        final emitted = <OutputLevelState>[];
        final sub = cubit.stream.listen(emitted.add);

        states.add(_withPeak(_minus6));
        async.elapse(refresh);
        states.add(_withPeak(_minus6 * 1.0001));
        async.elapse(refresh * 3);

        expect(emitted, [const OutputLevelState(tenths: -60)]);

        unawaited(sub.cancel());
        unawaited(cubit.close());
      });
    });

    test('returns to silence once the level drops away', () {
      fakeAsync((async) {
        final cubit = build();
        final emitted = <OutputLevelState>[];
        final sub = cubit.stream.listen(emitted.add);

        states.add(_withPeak(_minus6));
        async.elapse(refresh);
        states.add(_withPeak(0));
        async.elapse(refresh * 2);

        expect(emitted, [
          const OutputLevelState(tenths: -60),
          const OutputLevelState(),
        ]);

        unawaited(sub.cancel());
        unawaited(cubit.close());
      });
    });

    test('publishes a clip at once', () {
      fakeAsync((async) {
        final cubit = build();
        final emitted = <OutputLevelState>[];
        final sub = cubit.stream.listen(emitted.add);

        states.add(_withPeak(1));
        async.flushMicrotasks();

        expect(emitted, [const OutputLevelState(tenths: 0, clip: true)]);

        unawaited(sub.cancel());
        unawaited(cubit.close());
      });
    });

    test('stops refreshing once closed', () {
      fakeAsync((async) {
        final cubit = build();
        unawaited(cubit.close());
        async.flushMicrotasks();

        states.add(_withPeak(_minus6));
        async.elapse(refresh * 2);

        expect(cubit.state, const OutputLevelState());
      });
    });
  });
}
