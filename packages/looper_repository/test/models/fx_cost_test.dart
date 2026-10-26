import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno_engine/segno_engine.dart' show MockAudioEngine;

BuiltInEffect _fx(TrackEffectType type) => BuiltInEffect(type: type);

int _cost(TrackEffectType type) => fxEntryCostNs(_fx(type));

void main() {
  group('the effects budget', () {
    test('every kind has a charge above nothing', () {
      // A kind added without one would cost nothing and never be refused.
      for (final type in TrackEffectType.values) {
        if (type == TrackEffectType.none) continue;
        expect(_cost(type), greaterThan(0), reason: type.name);
      }
      expect(_cost(TrackEffectType.none), 0);
    });

    test('an entry charges its kind, on or off; PSOLA its own', () {
      final octaver = _fx(TrackEffectType.octaver);
      expect(fxEntryCostNs(octaver), (69 * 1000 / 64).ceil());
      expect(
        fxEntryCostNs(octaver.copyWith(enabled: false)),
        fxEntryCostNs(octaver),
      );
      final psola = octaver.copyWith(params: [...octaver.params]..[3] = 1);
      expect(fxEntryCostNs(psola), (kFxPsolaCostUs * 1000 / 64).ceil());
      expect(
        fxEntryCostNs(
          const PluginEffect(
            ref: PluginRef(format: PluginFormat.vst3, id: 'x'),
          ),
        ),
        0,
      );
    });

    test('a kind on the hop and the engine cost per block up to 64 frames, '
        'the rest per frame', () {
      final octaver = _fx(TrackEffectType.octaver);
      final delay = _fx(TrackEffectType.delay);
      // Half the block: the octaver's quarter-frame lands in half the time.
      expect(fxEntryCostNs(octaver, period: 32), (69 * 1000 / 32).ceil());
      // A longer block runs several hop stages: no cheaper per frame.
      expect(fxEntryCostNs(octaver, period: 256), fxEntryCostNs(octaver));
      expect(fxEntryCostNs(delay, period: 32), fxEntryCostNs(delay));
      expect(
        fxBudgetNs(96000, period: 32),
        8333 - (kFxBaseCostUs * 1000 / 32).ceil(),
      );
    });

    test("the budget is 80 % of a frame less the engine's own cost", () {
      final base = (kFxBaseCostUs * 1000 / 64).ceil();
      // 96 kHz: 10417 ns a frame, 8333 of them for the worst block.
      expect(fxBudgetNs(96000), 8333 - base);
      // Half the rate, twice the time a frame.
      expect(fxBudgetNs(48000), 16666 - base);
      // One octaver, the heaviest kind, fits with room to spare.
      expect(_cost(TrackEffectType.octaver) < fxBudgetNs(96000), isTrue);
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

    test('sums the chains, and the room is what is left', () {
      final room = repo.fxRoomNs;
      expect(repo.fxCostNs, 0);
      expect(
        repo.setTrackEffects(
          channel: 0,
          effects: [
            _fx(TrackEffectType.octaver),
            BuiltInEffect(type: TrackEffectType.reverb, enabled: false),
          ],
        ),
        EngineResult.ok,
      );
      // The mock reports no block length: the bench's stands in.
      final frames = engine.snapshot().bufferFrames;
      final period = frames > 0 ? frames : kFxBenchPeriod;
      final cost = fxChainCostNs([
        _fx(TrackEffectType.octaver),
        _fx(TrackEffectType.reverb),
      ], period: period);
      expect(repo.fxCostNs, cost);
      expect(repo.fxRoomNs, room - cost);
      expect(
        repo.fxCostOf([_fx(TrackEffectType.reverb)]),
        _cost(TrackEffectType.reverb),
      );
    });
  });
}
