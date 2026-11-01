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
      // The Dual Octaver adds its low band to the octaver's vocoder.
      expect(_cost(TrackEffectType.dualOctaver), (79 * 1000 / 64).ceil());
      expect(
        _cost(TrackEffectType.dualOctaver),
        greaterThan(fxEntryCostNs(octaver)),
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
      // One instance of the heaviest kind fits with room to spare.
      final heaviest = TrackEffectType.values
          .map(_cost)
          .reduce(
            (a, b) => a > b ? a : b,
          );
      expect(heaviest < fxBudgetNs(96000), isTrue);
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
      // An edit is weighed by what it adds.
      expect(
        repo.fxGrowthNs({
          const FxAddress(stage: FxStage.output): [_fx(TrackEffectType.reverb)],
        }),
        _cost(TrackEffectType.reverb),
      );
      expect(
        repo.fxGrowthNs({const FxAddress(stage: FxStage.track): const []}),
        -cost,
      );
    });
  });

  group('effects on more than one core (#1515)', () {
    // Ed's Rack, the plan's unit (section 7): 2,665 ns a frame.
    final rack = [
      for (final type in [
        TrackEffectType.dualOctaver,
        TrackEffectType.wah,
        TrackEffectType.compressor,
        TrackEffectType.overdrive,
        TrackEffectType.ampCab,
        TrackEffectType.chorus,
        TrackEffectType.roomVerb,
        TrackEffectType.modeDelay,
        TrackEffectType.eq,
      ])
        _fx(type),
    ];
    final rackNs = fxChainCostNs(rack);

    /// The racks, one per monitor input, that fit beside the callback with
    /// [workers] workers.
    int racksAdmitted(int workers) {
      var racks = 0;
      while (fxLoadNs(
            serial: 0,
            jobs: List.filled(racks + 1, rackNs),
            workers: workers,
          ) <=
          fxBudgetNs(96000)) {
        racks++;
      }
      return racks;
    }

    test("Ed's Rack charges what the plan's table assumes", () {
      expect(rackNs, 2665);
      expect(fxBudgetNs(96000), 7192);
    });

    test('with no workers the load is every chain summed', () {
      expect(fxLoadNs(serial: 500, jobs: [rackNs, rackNs]), 500 + 2 * rackNs);
      // One job is run on the callback, workers or not: no handoff.
      expect(fxLoadNs(serial: 500, jobs: [rackNs], workers: 2), 500 + rackNs);
      // A chain that charges nothing is still a job the engine releases a
      // round for: the handoff is paid.
      expect(
        fxLoadNs(serial: 0, jobs: [0, rackNs], workers: 2),
        81 + ((rackNs + 2 * rackNs) / 3).ceil(),
      );
    });

    test('with workers, the critical path and the handoff', () {
      // Two workers, three cores: (J + 2p) / 3 plus 81 ns of handoff.
      expect(
        fxLoadNs(serial: 1000, jobs: [rackNs, rackNs, rackNs], workers: 2),
        1000 + 81 + ((3 * rackNs + 2 * rackNs) / 3).ceil(),
      );
      // The largest job never splits: one big chain costs nearly all of it.
      final big = fxLoadNs(serial: 0, jobs: [6000, 100], workers: 2);
      expect(big, greaterThan(6000));
      // The handoff per worker count, at 64-frame blocks, over two jobs of
      // 12 ns: (24 + (C - 1) 12) / C on C cores.
      expect(fxLoadNs(serial: 0, jobs: [12, 12], workers: 1), 70 + 18);
      expect(fxLoadNs(serial: 0, jobs: [12, 12], workers: 2), 81 + 16);
      expect(fxLoadNs(serial: 0, jobs: [12, 12], workers: 3), 97 + 15);
    });

    test("admits the racks of the plan's table: 2, 4, 6 and 7", () {
      expect(racksAdmitted(0), 2);
      expect(racksAdmitted(1), 4);
      expect(racksAdmitted(2), 6);
      expect(racksAdmitted(3), 7);
    });

    group('LooperRepository', () {
      late MockAudioEngine engine;
      late LooperRepository repo;

      void putRacks(int count) {
        for (var input = 0; input < count; input++) {
          expect(
            repo.setMonitorEffects(input: input, effects: rack),
            EngineResult.ok,
          );
        }
      }

      setUp(() {
        engine = MockAudioEngine()..setFxWorkers(count: 2);
        repo = LooperRepository(
          engine: engine,
        )..startEngine(const EngineConfig(sampleRate: 96000, inputChannels: 8));
        addTearDown(repo.dispose);
      });

      test('six racks on the inputs fit two workers, seven do not', () {
        putRacks(6);
        expect(repo.fxRoomNs, greaterThanOrEqualTo(0));
        // A seventh is weighed by what it adds to the critical path.
        final seventh = repo.fxGrowthNs({
          const FxAddress(stage: FxStage.input, index: 6): rack,
        });
        expect(seventh, greaterThan(repo.fxRoomNs));
        // Restored anyway, it comes up switched off (the owner's R2).
        putRacks(7);
        expect(
          repo.fxChainHeld(const FxAddress(stage: FxStage.input, index: 6)),
          isTrue,
        );
        expect(repo.fxRoomNs, greaterThanOrEqualTo(0));
      });

      test('a rack on a track runs on the callback: it charges in full', () {
        putRacks(2);
        final onInput = repo.fxGrowthNs({
          const FxAddress(stage: FxStage.input, index: 2): rack,
        });
        final onTrack = repo.fxGrowthNs({
          const FxAddress(stage: FxStage.track): rack,
        });
        expect(onTrack, rackNs);
        expect(onInput, lessThan(onTrack));
      });

      test('a pedal switched on is never refused: on or off it is charged', () {
        putRacks(6);
        final off = [for (final fx in rack) fx.copyWith(enabled: false)];
        expect(
          repo.fxGrowthNs({const FxAddress(stage: FxStage.input): off}),
          0,
        );
      });

      test('without its workers the same rig comes up with what does not fit '
          'switched off', () {
        putRacks(6);
        repo.stopEngine();
        engine.setFxWorkers(count: 0);
        repo.startEngine(
          const EngineConfig(sampleRate: 96000, inputChannels: 8),
        );
        // Nothing is dropped: the chains stay, the ones the callback alone
        // cannot run are switched off, and the rest fit.
        expect(
          [
            for (final fx in repo.monitorEffects(5)) (fx as BuiltInEffect).type,
          ],
          [for (final fx in rack) fx.type],
        );
        expect(repo.state.fxHeld, hasLength(4));
        expect(repo.fxRoomNs, greaterThanOrEqualTo(0));
      });
    });
  });
}
