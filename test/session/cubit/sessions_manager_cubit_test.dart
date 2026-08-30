import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/session/session.dart';

class _MockPedalRepository extends Mock implements PedalRepository {}

void main() {
  group(SessionsManagerCubit, () {
    late StreamController<PedalEvent> events;
    late PedalRepository pedal;

    setUp(() {
      events = StreamController<PedalEvent>.broadcast();
      pedal = _MockPedalRepository();
      when(() => pedal.events).thenAnswer((_) => events.stream);
    });

    tearDown(() => events.close());

    test('starts active', () async {
      final cubit = SessionsManagerCubit(pedal: pedal);
      addTearDown(cubit.close);

      expect(cubit.state, SessionsManagerStatus.active);
    });

    blocTest<SessionsManagerCubit, SessionsManagerStatus>(
      'requests dismissal once when repeated footswitch presses arrive',
      build: () => SessionsManagerCubit(pedal: pedal),
      act: (cubit) {
        events
          ..add(const ButtonPressed(PedalButton.clear))
          ..add(const ButtonPressed(PedalButton.recPlay));
      },
      expect: () => [SessionsManagerStatus.dismissalRequested],
    );

    blocTest<SessionsManagerCubit, SessionsManagerStatus>(
      'stays active when the encoder turns',
      build: () => SessionsManagerCubit(pedal: pedal),
      act: (_) => events.add(const EncoderDelta(1)),
      expect: () => <SessionsManagerStatus>[],
    );

    test('cancels the pedal subscription when closed', () async {
      final cubit = SessionsManagerCubit(pedal: pedal);
      expect(events.hasListener, isTrue);

      await cubit.close();

      expect(events.hasListener, isFalse);
    });
  });
}
