import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';

import 'helpers/fake_audio_engine.dart';

void main() {
  group('Fade, Reverse and length edits complete with their receipt', () {
    late FakeAudioEngine engine;
    late LooperRepository repository;
    late StreamController<void> ticks;

    setUp(() {
      engine = FakeAudioEngine()..editAdmission = EngineResult.ok;
      ticks = StreamController<void>.broadcast(sync: true);
      repository = LooperRepository(engine: engine, ticker: ticks.stream)
        ..startEngine(const EngineConfig());
    });
    tearDown(() async {
      await repository.dispose();
      await ticks.close();
    });

    test(
      'toggleFade posts the fade time and returns the callback outcome',
      () async {
        expect(
          await repository.toggleFade(channel: 2, seconds: 1.5),
          EngineResult.ok,
        );
        expect(engine.editCalls.single, (kind: 'fade', channel: 2, value: 1.5));
      },
    );

    test(
      'toggleReverse returns the callback refusal, not the admission',
      () async {
        engine.editResult = EngineResult.invalid; // an empty track, say
        expect(
          await repository.toggleReverse(channel: 1),
          EngineResult.invalid,
        );
        expect(
          engine.editCalls.single,
          (kind: 'reverse', channel: 1, value: null),
        );
      },
    );

    test(
      'editLength posts the edit and returns the callback outcome',
      () async {
        expect(
          await repository.editLength(channel: 0, edit: LengthEdit.doubled),
          EngineResult.ok,
        );
        engine.editResult = EngineResult.capacity;
        expect(
          await repository.editLength(channel: 0, edit: LengthEdit.lastHalf),
          EngineResult.capacity,
        );
        expect(engine.editCalls.map((c) => c.value), [
          LengthEdit.doubled,
          LengthEdit.lastHalf,
        ]);
      },
    );

    test('an admission refusal completes at once and posts nothing', () async {
      engine.editAdmission = EngineResult.modeMismatch;
      expect(
        await repository.editLength(channel: 0, edit: LengthEdit.firstHalf),
        EngineResult.modeMismatch,
      );
      expect(
        await repository.toggleReverse(channel: 0),
        EngineResult.modeMismatch,
      );
      expect(engine.editCalls, isEmpty);
    });

    test(
      'editLength is not ready while a Session owns the engine audio',
      () async {
        repository.blockStartForSessionBoot();
        expect(
          await repository.editLength(channel: 0, edit: LengthEdit.doubled),
          EngineResult.notReady,
        );
        expect(engine.editCalls, isEmpty);
      },
    );

    test(
      'an unanswered receipt expires as not ready and drains later',
      () async {
        engine.withholdReceipts = true;
        expect(
          await repository.toggleFade(channel: 3, seconds: 0.5),
          EngineResult.notReady,
        );
        // The callback answers late: the stale claim drains at the next
        // admission without completing anyone, and the new request still gets
        // its own outcome.
        engine
          ..withholdReceipts = false
          ..answerWithheld();
        expect(await repository.toggleReverse(channel: 3), EngineResult.ok);
        expect(engine.editCalls.map((c) => c.kind), ['fade', 'reverse']);
      },
    );
  });
}
