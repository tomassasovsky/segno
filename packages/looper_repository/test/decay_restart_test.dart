import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';

import 'helpers/fake_audio_engine.dart';

class _Engine extends FakeAudioEngine {
  bool refuseDecay = false;
  @override
  EngineResult setOverdubFeedback(double feedback) =>
      refuseDecay ? EngineResult.notReady : super.setOverdubFeedback(feedback);
}

void main() {
  group('Decay restart intent', () {
    late _Engine engine;
    late LooperRepository repository;
    setUp(() {
      engine = _Engine();
      repository = LooperRepository(
        engine: engine,
        ticker: const Stream.empty(),
      );
    });
    tearDown(() => repository.dispose());
    test(
      'held live defaults and track values replay only durable Released',
      () {
        repository
          ..setOverdubDecay(80)
          ..setTrackOverdubDecay(channel: 0, percent: 75)
          ..setDecayRestartIntent(
            defaultPercent: 20,
            trackOverrides: {0: 0, 7: 100},
          );
        expect(repository.defaultOverdubDecay, 80);
        expect(repository.trackOverdubDecayOverrides, {0: 75});
        expect(repository.startEngine(const EngineConfig()), EngineResult.ok);
        expect(repository.defaultOverdubDecay, 20);
        expect(repository.trackOverdubDecayOverrides, {0: 0, 7: 100});
        expect(engine.lastOverdubFeedback, .8);
        expect(engine.trackOverdubFeedback[0], 1);
        expect(engine.trackOverdubFeedback[7], 0);
      },
    );
    test('atomic replay refusal fails start instead of advertising replay', () {
      repository.setOverdubDecay(40);
      engine.refuseDecay = true;
      expect(
        repository.startEngine(const EngineConfig()),
        EngineResult.notReady,
      );
      expect(repository.state.status.isConnected, isFalse);
      engine.refuseDecay = false;
      expect(repository.startEngine(const EngineConfig()), EngineResult.ok);
      expect(engine.lastOverdubFeedback, .6);
    });
    test('ordinary Use default removes only its durable override', () {
      repository
        ..setTrackOverdubDecay(channel: 0, percent: 0)
        ..setTrackOverdubDecay(channel: 1, percent: 30)
        ..setTrackOverdubDecay(channel: 0, percent: null);
      expect(repository.decayRestartIntent.trackOverrides, {1: 30});
      expect(repository.startEngine(const EngineConfig()), EngineResult.ok);
      expect(repository.trackOverdubDecayOverrides, {1: 30});
    });
  });
}
