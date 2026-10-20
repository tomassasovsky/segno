import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno_engine/segno_engine.dart' as engine;

import 'helpers/fake_audio_engine.dart';

void main() {
  late FakeAudioEngine audio;
  late LooperRepository repo;
  setUp(() {
    audio = FakeAudioEngine();
    repo = LooperRepository(engine: audio)..startEngine(const EngineConfig());
  });
  tearDown(() => repo.dispose());

  test('invalid session destination cannot clear the current rig', () async {
    repo.setOutputEffects(
      bus: 1,
      effects: [BuiltInEffect(type: TrackEffectType.drive)],
    );
    final before = repo.allOutputChains();
    final calls = audio.calls.length;
    await expectLater(
      repo.applySession(
        const SessionRig(outputChains: {-1: FxChainEnvelope()}),
      ),
      throwsStateError,
    );
    expect(repo.allOutputChains(), before);
    expect(audio.calls.length, calls);
  });

  test(
    'destinations own separate pending recipes and acknowledgments',
    () async {
      audio.publishRecipes = false;
      final chain = [BuiltInEffect(type: TrackEffectType.drive)];
      expect(repo.setOutputEffects(bus: 0, effects: chain), EngineResult.ok);
      expect(
        repo.setOutputEffects(bus: 1, effects: chain, chainEnabled: false),
        EngineResult.ok,
      );
      expect(
        repo.setOutputEffects(bus: 1, effects: const []),
        EngineResult.notReady,
      );
      audio.publishRecipe((engine.FxOwner.output, 0, 0));
      expect(
        await repo.settleFxRecipes(attempts: 1, pollInterval: Duration.zero),
        EngineResult.notReady,
      );
      expect(repo.outputEffects(1), hasLength(1));
      expect(repo.outputChainEnabled(1), isFalse);
      audio.publishRecipe((engine.FxOwner.output, 1, 0));
      expect(
        await repo.settleFxRecipes(attempts: 1, pollInterval: Duration.zero),
        EngineResult.ok,
      );
    },
  );

  test('refused edits preserve entries, power and other outputs', () {
    final chain = [BuiltInEffect(type: TrackEffectType.drive)];
    repo.setOutputEffects(bus: 1, effects: chain, chainEnabled: false);
    final before = repo.allOutputChains();
    audio.nextRecipeResult = EngineResult.invalid;
    expect(
      repo.setOutputEffects(bus: 1, effects: const [], chainEnabled: true),
      EngineResult.invalid,
    );
    expect(repo.allOutputChains(), before);
    expect(
      repo.setOutputEffects(bus: -1, effects: chain),
      EngineResult.invalid,
    );
    expect(
      repo.setOutputEffects(bus: engine.kMaxOutputBuses, effects: chain),
      EngineResult.invalid,
    );
    expect(repo.allOutputChains(), before);
  });

  test('restart restores every destination through complete recipes', () {
    final chain = [
      BuiltInEffect(type: TrackEffectType.drive, placement: FxPlacement.pre),
    ];
    repo
      ..setOutputEffects(bus: 1, effects: chain, chainEnabled: false)
      ..setOutputChainEnabled(bus: 2, enabled: false)
      ..stopEngine()
      ..startEngine(const EngineConfig());
    expect(audio.recipes[(engine.FxOwner.output, 1, 0)]?.slots, hasLength(1));
    expect(audio.recipes[(engine.FxOwner.output, 1, 0)]?.enabled, isFalse);
    expect(audio.recipes[(engine.FxOwner.output, 1, 0)]?.preCount, 0);
    expect(audio.recipes[(engine.FxOwner.output, 2, 0)]?.slots, isEmpty);
    expect(audio.recipes[(engine.FxOwner.output, 2, 0)]?.enabled, isFalse);
    expect(repo.outputEffects(1).single.placement, FxPlacement.post);
  });

  test(
    'smaller session clears old destination entries and disabled flags',
    () async {
      repo
        ..setOutputEffects(
          bus: 1,
          effects: [BuiltInEffect(type: TrackEffectType.drive)],
        )
        ..setOutputChainEnabled(bus: 2, enabled: false);
      await repo.applySession(
        const SessionRig(),
        clearPollInterval: Duration.zero,
      );
      expect(repo.allOutputChains(), isEmpty);
      expect(audio.recipes[(engine.FxOwner.output, 1, 0)]?.slots, isEmpty);
      expect(audio.recipes[(engine.FxOwner.output, 2, 0)]?.enabled, isTrue);
    },
  );
}
