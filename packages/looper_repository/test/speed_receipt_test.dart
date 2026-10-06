import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';

import 'helpers/fake_audio_engine.dart';

void main() {
  group('LooperRepository.setSpeed (#1179)', () {
    late FakeAudioEngine engine;
    late LooperRepository repository;
    late StreamController<void> ticks;

    setUp(() {
      engine = FakeAudioEngine();
      ticks = StreamController<void>.broadcast(sync: true);
      repository = LooperRepository(engine: engine, ticker: ticks.stream)
        ..startEngine(const EngineConfig());
    });
    tearDown(() async {
      await repository.dispose();
      await ticks.close();
    });

    test('admits the factor and completes with the callback receipt', () async {
      engine.speedResult = EngineResult.notReady; // the callback's refusal
      expect(
        await repository.setSpeed(SpeedFactor.fourfold),
        EngineResult.notReady,
      );
      expect(engine.lastSpeed, SpeedFactor.fourfold);
      engine.speedResult = EngineResult.ok;
      expect(await repository.setSpeed(SpeedFactor.half), EngineResult.ok);
      expect(engine.lastSpeed, SpeedFactor.half);
    });

    test('an admission refusal completes at once and posts nothing', () async {
      engine.speedAdmission = EngineResult.notReady;
      expect(
        await repository.setSpeed(SpeedFactor.twice),
        EngineResult.notReady,
      );
      expect(engine.lastSpeed, isNull);
    });

    test('projects the factor the engine published', () async {
      final subscription = repository.looperState.listen((_) {});
      addTearDown(subscription.cancel);
      expect(repository.state.speed, SpeedFactor.normal);
      engine.nextSnapshot = engine.nextSnapshot.copyWith(
        speed: SpeedFactor.eightfold,
      );
      ticks.add(null);
      expect(repository.state.speed, SpeedFactor.eightfold);
    });
  });
}
