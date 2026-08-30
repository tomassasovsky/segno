import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/performance/performance.dart';

class _MockPedalRepository extends Mock implements PedalRepository {}

void main() {
  group(PerformanceCompletionCubit, () {
    late StreamController<PedalEvent> events;
    late PedalRepository pedal;

    setUp(() {
      events = StreamController<PedalEvent>.broadcast();
      pedal = _MockPedalRepository();
      when(() => pedal.events).thenAnswer((_) => events.stream);
    });

    tearDown(() => events.close());

    test('initial state is $PerformanceCompletionStatus.active', () async {
      final cubit = PerformanceCompletionCubit(pedal: pedal);
      addTearDown(cubit.close);

      expect(cubit.state, equals(PerformanceCompletionStatus.active));
    });

    group('pedal events', () {
      blocTest<PerformanceCompletionCubit, PerformanceCompletionStatus>(
        'emits $PerformanceCompletionStatus.dismissalRequested once on '
        'repeated $ButtonPressed',
        build: () => PerformanceCompletionCubit(pedal: pedal),
        act: (cubit) {
          events
            ..add(const ButtonPressed(PedalButton.clear))
            ..add(const ButtonPressed(PedalButton.recPlay));
        },
        expect: () => [equals(PerformanceCompletionStatus.dismissalRequested)],
      );

      blocTest<PerformanceCompletionCubit, PerformanceCompletionStatus>(
        'emits nothing when the encoder turns',
        build: () => PerformanceCompletionCubit(pedal: pedal),
        act: (_) => events.add(const EncoderDelta(1)),
        expect: () => <PerformanceCompletionStatus>[],
      );

      blocTest<PerformanceCompletionCubit, PerformanceCompletionStatus>(
        'emits nothing when a footswitch is released',
        build: () => PerformanceCompletionCubit(pedal: pedal),
        act: (_) => events.add(const ButtonReleased(PedalButton.clear)),
        expect: () => <PerformanceCompletionStatus>[],
      );
    });

    group('close', () {
      test('cancels the pedal subscription', () async {
        final cubit = PerformanceCompletionCubit(pedal: pedal);
        expect(events.hasListener, isTrue);

        await cubit.close();

        expect(events.hasListener, isFalse);
      });
    });
  });
}
