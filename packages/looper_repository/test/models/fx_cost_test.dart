import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno_engine/segno_engine.dart' show MockAudioEngine;

void main() {
  group('the effects budget', () {
    test('every kind has a charge', () {
      // A kind added without one would cost nothing and never be refused.
      for (final type in TrackEffectType.values) {
        expect(kFxKindCostNs.containsKey(type), isTrue, reason: type.name);
      }
      expect(kFxKindCostNs[TrackEffectType.none], 0);
    });

    test('an entry charges its kind, on or off; PSOLA its own', () {
      final octaver = BuiltInEffect(type: TrackEffectType.octaver);
      expect(fxEntryCostNs(octaver), kFxKindCostNs[TrackEffectType.octaver]);
      expect(
        fxEntryCostNs(octaver.copyWith(enabled: false)),
        fxEntryCostNs(octaver),
      );
      final psola = octaver.copyWith(
        params: [...octaver.params]..[3] = 1,
      );
      expect(fxEntryCostNs(psola), kFxPsolaCostNs);
      expect(
        fxEntryCostNs(
          const PluginEffect(
            ref: PluginRef(format: PluginFormat.vst3, id: 'x'),
          ),
        ),
        0,
      );
    });

    test('a lane charges its free-running kinds only', () {
      final chain = [
        BuiltInEffect(type: TrackEffectType.delay),
        BuiltInEffect(type: TrackEffectType.chorus),
        BuiltInEffect(type: TrackEffectType.octaver),
      ];
      expect(
        fxChainCostNs(chain),
        kFxKindCostNs[TrackEffectType.delay]! +
            kFxKindCostNs[TrackEffectType.chorus]! +
            kFxKindCostNs[TrackEffectType.octaver]!,
      );
      expect(fxLaneCostNs(chain), kFxKindCostNs[TrackEffectType.chorus]);
    });

    test("the budget is 80 % of a frame less the engine's own cost", () {
      // 96 kHz: 10417 ns a frame, 8333 of them for the worst block.
      expect(fxBudgetNs(96000), 8333 - kFxBaseCostNs);
      // Half the rate, twice the time a frame.
      expect(fxBudgetNs(48000), 16666 - kFxBaseCostNs);
      // One octaver, the heaviest kind, fits with room to spare.
      expect(
        kFxKindCostNs[TrackEffectType.octaver]! < fxBudgetNs(96000),
        isTrue,
      );
    });
  });

  group('LooperRepository.fxCostNs', () {
    late MockAudioEngine engine;
    late LooperRepository repo;

    setUp(() {
      engine = MockAudioEngine();
      repo = LooperRepository(engine: engine)
        ..startEngine(const EngineConfig());
      addTearDown(repo.dispose);
    });

    test('sums the live chains, and the room is what is left', () {
      final room = repo.fxRoomNs;
      expect(repo.fxCostNs, 0);
      expect(
        repo.setTrackEffects(
          channel: 0,
          effects: [
            BuiltInEffect(type: TrackEffectType.octaver),
            BuiltInEffect(type: TrackEffectType.reverb, enabled: false),
          ],
        ),
        EngineResult.ok,
      );
      final cost =
          kFxKindCostNs[TrackEffectType.octaver]! +
          kFxKindCostNs[TrackEffectType.reverb]!;
      expect(repo.fxCostNs, cost);
      expect(repo.fxRoomNs, room - cost);
    });
  });
}
