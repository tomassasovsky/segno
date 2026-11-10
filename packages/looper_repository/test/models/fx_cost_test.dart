import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno_engine/segno_engine.dart' show MockAudioEngine;

BuiltInEffect _fx(TrackEffectType type) => BuiltInEffect(type: type);

int _cost(TrackEffectType type) => fxEntryCostNs(_fx(type));

void main() {
  group('the effects budget', () {
    test('every table has a figure for every setting and every kind', () {
      final n = kFxCostSettings.length;
      expect(n, 8);
      expect(kFxKindCostNs.keys, unorderedEquals(TrackEffectType.values));
      for (final MapEntry(key: type, value: ns) in kFxKindCostNs.entries) {
        expect(ns, hasLength(n), reason: type.name);
      }
      expect(kFxPsolaCostNs, hasLength(n));
      expect(kFxBaseUs, hasLength(n));
    });

    test('every kind charges above nothing at every setting', () {
      // A kind added without one would cost nothing and never be refused.
      for (final (:rate, :period) in kFxCostSettings) {
        for (final type in TrackEffectType.values) {
          final ns = fxEntryCostNs(_fx(type), period: period, sampleRate: rate);
          if (type == TrackEffectType.none) {
            expect(ns, 0);
          } else {
            expect(ns, greaterThan(0), reason: '${type.name} $rate/$period');
          }
        }
      }
    });

    test('a device is charged at its own setting, not the worst of eight', () {
      int at(int rate, int period) {
        final s = kFxCostSettings[fxCostSetting(rate, period)];
        return s.rate * 1000 + s.period;
      }

      expect(at(48000, 32), 48000032);
      expect(at(44100, 64), 44100064);
      expect(at(96000, 32), 96000032);
      // A longer block costs no more a frame than 64 frames do.
      expect(at(48000, 128), 48000064);
      expect(at(96000, 512), 96000064);
      // A rate between two measured ones takes the nearer.
      expect(at(50000, 32), 48000032);
      expect(at(192000, 64), 96000064);
      // No rate reported: the bench's.
      expect(at(0, 0), 96000064);
      final delay = _fx(TrackEffectType.delay);
      final i = fxCostSetting(48000, 32);
      expect(
        fxEntryCostNs(delay, period: 32, sampleRate: 48000),
        kFxKindCostNs[TrackEffectType.delay]![i],
      );
    });

    test('an entry charges its kind, on or off; PSOLA its own', () {
      final i = fxCostSetting(48000, 32);
      final octaver = _fx(TrackEffectType.octaver);
      int at4832(TrackEffect fx) =>
          fxEntryCostNs(fx, period: 32, sampleRate: 48000);
      expect(at4832(octaver), kFxKindCostNs[TrackEffectType.octaver]![i]);
      expect(at4832(octaver.copyWith(enabled: false)), at4832(octaver));
      // PSOLA, in the octaver or the Smart Tune.
      final psola = octaver.copyWith(params: [...octaver.params]..[3] = 1);
      expect(at4832(psola), kFxPsolaCostNs[i]);
      expect(at4832(_fx(TrackEffectType.smartTune)), kFxPsolaCostNs[i]);
      expect(
        fxEntryCostNs(
          const PluginEffect(
            ref: PluginRef(format: PluginFormat.vst3, id: 'x'),
          ),
        ),
        0,
      );
    });

    test('a kind on the hop costs more a frame at 32 frames than at 64', () {
      // A quarter of its hop lands in every block up to 64 frames.
      for (final type in [
        TrackEffectType.octaver,
        TrackEffectType.whammy,
        TrackEffectType.dualOctaver,
      ]) {
        for (final rate in [44100, 48000, 88200, 96000]) {
          expect(
            fxEntryCostNs(_fx(type), period: 32, sampleRate: rate),
            greaterThan(fxEntryCostNs(_fx(type), sampleRate: rate)),
            reason: '${type.name} $rate',
          );
        }
      }
    });

    test('an oversampled kind costs less a frame at 88.2 kHz and up', () {
      // It runs fewer times over there (#1547).
      for (final type in [
        TrackEffectType.overdrive,
        TrackEffectType.distortion,
        TrackEffectType.vinyl,
      ]) {
        for (final period in [32, 64]) {
          expect(
            fxEntryCostNs(_fx(type), period: period),
            lessThan(
              fxEntryCostNs(_fx(type), period: period, sampleRate: 48000),
            ),
            reason: '${type.name} $period',
          );
        }
      }
    });

    test("the budget is the share of a frame less the engine's own cost", () {
      final i = fxCostSetting(48000, 32);
      expect(fxBaseNs(48000, period: 32), (kFxBaseUs[i] * 1000 / 32).ceil());
      // Per frame of a 64-frame block from 64 frames up.
      expect(fxBaseNs(96000, period: 256), fxBaseNs(96000));
      expect(
        fxBudgetNs(48000, period: 32),
        (kFxBudgetShare * 1e9 / 48000).floor() - fxBaseNs(48000, period: 32),
      );
      // One instance of the heaviest kind fits with room to spare.
      for (final (:rate, :period) in kFxCostSettings) {
        final heaviest = TrackEffectType.values
            .map((t) => fxEntryCostNs(_fx(t), period: period, sampleRate: rate))
            .reduce((a, b) => a > b ? a : b);
        expect(heaviest, lessThan(fxBudgetNs(rate, period: period)));
      }
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
    // Ed's Rack, the plan's unit (section 7): 3,256 ns a frame at 96 kHz / 64
    // on the console's own table (#1508, #1724), 2,665 in the plan.
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

    test("Ed's Rack charges what the console's table makes it", () {
      expect(rackNs, 3256);
      expect(fxBudgetNs(96000), 6626);
    });

    test("at the owner's 48 kHz / 32, three of Ed's Racks fit the callback "
        'alone and seven fit the inputs with two workers (#1724: as many as '
        'the worst of eight at 80 % admitted)', () {
      final ns = fxChainCostNs(rack, period: 32, sampleRate: 48000);
      final budget = fxBudgetNs(48000, period: 32);
      expect(ns, 4592);
      expect(budget, 14206);
      expect(3 * ns, lessThanOrEqualTo(budget));
      expect(4 * ns, greaterThan(budget));
      int load(int racks) => fxLoadNs(
        serial: 0,
        jobs: List.filled(racks, ns),
        workers: 2,
        period: 32,
      );
      expect(load(7), lessThanOrEqualTo(budget));
      expect(load(8), greaterThan(budget));
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

    // The plan's table admitted 2, 4, 6 and 7 at its 2,665 ns.
    test('admits 2, 3, 4 and 5 racks with 0 to 3 workers', () {
      expect(racksAdmitted(0), 2);
      expect(racksAdmitted(1), 3);
      expect(racksAdmitted(2), 4);
      expect(racksAdmitted(3), 5);
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

      test('four racks on the inputs fit two workers, five do not', () {
        putRacks(4);
        expect(repo.fxRoomNs, greaterThanOrEqualTo(0));
        expect(repo.state.fxHeld, isEmpty);
        // A fifth is weighed by what it adds to the critical path.
        final fifth = repo.fxGrowthNs({
          const FxAddress(stage: FxStage.input, index: 4): rack,
        });
        expect(fifth, greaterThan(repo.fxRoomNs));
        // Restored anyway, it comes up switched off (the owner's R2).
        putRacks(5);
        expect(
          repo.fxChainHeld(const FxAddress(stage: FxStage.input, index: 4)),
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
