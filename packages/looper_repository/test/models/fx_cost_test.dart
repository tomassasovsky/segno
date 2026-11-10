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
      final octaverUs = kFxHopCostUs[TrackEffectType.octaver]!;
      expect(fxEntryCostNs(octaver), (octaverUs * 1000 / 64).ceil());
      expect(
        fxEntryCostNs(octaver.copyWith(enabled: false)),
        fxEntryCostNs(octaver),
      );
      // The Dual Octaver adds its low band to the octaver's vocoder.
      expect(
        _cost(TrackEffectType.dualOctaver),
        (kFxHopCostUs[TrackEffectType.dualOctaver]! * 1000 / 64).ceil(),
      );
      expect(
        _cost(TrackEffectType.dualOctaver),
        greaterThan(fxEntryCostNs(octaver)),
      );
      // PSOLA, in the octaver or the Smart Tune, charges per frame by the
      // rate.
      final psola = octaver.copyWith(params: [...octaver.params]..[3] = 1);
      expect(fxEntryCostNs(psola), kFxPsolaCostNs.high);
      expect(fxEntryCostNs(psola, sampleRate: 48000), kFxPsolaCostNs.low);
      expect(fxEntryCostNs(psola, period: 32), kFxPsolaCostNs.high);
      expect(_cost(TrackEffectType.smartTune), kFxPsolaCostNs.high);
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
      final octaverUs = kFxHopCostUs[TrackEffectType.octaver]!;
      expect(
        fxEntryCostNs(octaver, period: 32),
        (octaverUs * 1000 / 32).ceil(),
      );
      // A longer block runs several hop stages: no cheaper per frame.
      expect(fxEntryCostNs(octaver, period: 256), fxEntryCostNs(octaver));
      // At 44.1 kHz a 64-frame block carries 69.7 of the kernel's 48 kHz
      // samples, so it can take two quarters; a 32-frame block only one.
      expect(
        fxEntryCostNs(octaver, sampleRate: 44100),
        (2 * octaverUs * 1000 / 64).ceil(),
      );
      expect(
        fxEntryCostNs(octaver, period: 32, sampleRate: 44100),
        (octaverUs * 1000 / 32).ceil(),
      );
      expect(fxEntryCostNs(octaver, sampleRate: 48000), fxEntryCostNs(octaver));
      expect(fxEntryCostNs(delay, period: 32), fxEntryCostNs(delay));
      expect(
        fxBudgetNs(96000, period: 32),
        8333 - fxBaseNs(32),
      );
    });

    test('an oversampled kind charges by the rate (#1547)', () {
      for (final MapEntry(key: type, value: ns)
          in kFxOversampledCostNs.entries) {
        final fx = _fx(type);
        // 44.1 and 48 kHz run the most times over, 88.2 kHz and up fewer.
        expect(fxEntryCostNs(fx, sampleRate: 44100), ns.low, reason: '$type');
        expect(fxEntryCostNs(fx, sampleRate: 48000), ns.low, reason: '$type');
        expect(fxEntryCostNs(fx, sampleRate: 88200), ns.high, reason: '$type');
        expect(fxEntryCostNs(fx), ns.high, reason: '$type'); // 96 kHz
        expect(kFxKindCostNs.containsKey(type), isFalse, reason: '$type');
      }
      // A kind that does not oversample charges the same at every rate.
      final delay = _fx(TrackEffectType.delay);
      expect(fxEntryCostNs(delay, sampleRate: 48000), fxEntryCostNs(delay));
    });

    test("the budget is 80 % of a frame less the engine's own cost", () {
      // The engine's own block: 76 us over 64 frames, 44 over 32.
      expect(fxBaseNs(64), 1188);
      expect(fxBaseNs(32), 1375);
      expect(fxBaseNs(256), fxBaseNs(64));
      final base = fxBaseNs(64);
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
      // The reverb is off and no control reaches it: it charges nothing
      // (#1723).
      final octaver = fxChainCostNs([
        _fx(TrackEffectType.octaver),
      ], period: period);
      expect(repo.fxCostNs, octaver);
      // A control that can switch it on reserves room for it.
      repo.setFxReach([
        FxControlReach(
          whenOn: {const FxSwitchKey.chain(FxAddress(stage: FxStage.track))},
        ),
      ]);
      expect(repo.fxCostNs, octaver);
      final reverb = BuiltInEffect(
        type: TrackEffectType.reverb,
        enabled: false,
        slotId: 'reverb',
      );
      repo
        ..setTrackEffects(
          channel: 0,
          effects: [_fx(TrackEffectType.octaver), reverb],
        )
        ..setFxReach([
          FxControlReach(
            whenOn: {
              const FxSwitchKey.slot(FxAddress(stage: FxStage.track), 'reverb'),
            },
          ),
        ]);
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

  group('what a control can turn on (#1723)', () {
    late MockAudioEngine engine;
    late LooperRepository repo;

    const track = FxAddress(stage: FxStage.track);
    const input = FxAddress(stage: FxStage.input);
    const rackA = FxRack(id: 'rack-a', name: 'A');
    const rackB = FxRack(id: 'rack-b', name: 'B');

    BuiltInEffect pedal(
      TrackEffectType type,
      String slotId, {
      FxRack? rack,
      bool enabled = true,
    }) => BuiltInEffect(
      type: type,
      slotId: slotId,
      rack: rack,
      enabled: enabled,
    );

    /// Rack A (a Room reverb) on, rack B (an Echo and a Delay) off: the A/B
    /// pair of #1711 in one chain.
    List<TrackEffect> pair({bool aOn = true, bool bOn = false}) => [
      pedal(
        TrackEffectType.roomVerb,
        'a1',
        rack: rackA.copyWith(bypassed: !aOn),
      ),
      pedal(TrackEffectType.echo, 'b1', rack: rackB.copyWith(bypassed: !bOn)),
      pedal(TrackEffectType.delay, 'b2', rack: rackB.copyWith(bypassed: !bOn)),
    ];

    final a = _cost(TrackEffectType.roomVerb);
    final b = _cost(TrackEffectType.echo) + _cost(TrackEffectType.delay);

    setUp(() {
      engine = MockAudioEngine();
      repo = LooperRepository(engine: engine)
        ..startEngine(const EngineConfig(sampleRate: 96000, inputChannels: 2));
      addTearDown(repo.dispose);
    });

    test('an off effect no control reaches charges nothing', () {
      repo.setTrackEffects(
        channel: 0,
        effects: [pedal(TrackEffectType.roomVerb, 'r', enabled: false)],
      );
      expect(repo.fxCostNs, 0);
      // Neither does an on effect in a rack, or a chain, that is off.
      repo.setTrackEffects(channel: 0, effects: pair(aOn: false));
      expect(repo.fxCostNs, 0);
      repo
        ..setTrackEffects(channel: 0, effects: pair(bOn: true))
        ..setTrackChainEnabled(channel: 0, enabled: false);
      expect(repo.fxCostNs, 0);
    });

    test('a control charges what it can make run, and nothing more', () {
      repo
        ..setTrackEffects(
          channel: 0,
          effects: [
            pedal(TrackEffectType.roomVerb, 'r', enabled: false),
            pedal(
              TrackEffectType.echo,
              'e',
              rack: rackB.copyWith(bypassed: true),
            ),
            pedal(TrackEffectType.delay, 'd', rack: rackB, enabled: false),
          ],
        )
        ..setFxReach([
          FxControlReach(whenOn: {const FxSwitchKey.slot(track, 'r')}),
          FxControlReach(whenOn: {const FxSwitchKey.rack(track, 'rack-b')}),
        ]);
      // The reverb's own switch and rack B are reached; the delay's own
      // switch is off and nothing reaches it, so its rack's control cannot
      // make it run.
      expect(
        repo.fxCostNs,
        _cost(TrackEffectType.roomVerb) + _cost(TrackEffectType.echo),
      );
      // A chain switched off charges what a control reaching it can bring
      // back.
      repo
        ..setTrackChainEnabled(channel: 0, enabled: false)
        ..setFxReach([
          FxControlReach(whenOn: {const FxSwitchKey.chain(track)}),
        ]);
      expect(repo.fxCostNs, 0);
      repo.setTrackEffects(channel: 0, effects: pair());
      expect(repo.fxCostNs, a);
    });

    test('the A/B pair one switch alternates charges its larger side, not '
        'the sum', () {
      repo.setMonitorEffects(input: 0, effects: pair());
      final alternates = FxControlReach(
        whenOn: {const FxSwitchKey.rack(input, 'rack-a')},
        whenOff: {const FxSwitchKey.rack(input, 'rack-b')},
      );
      repo.setFxReach([alternates]);
      expect(repo.fxCostNs, a > b ? a : b);
      // Bound to two switches instead, both can be on: the sum.
      repo.setFxReach([
        FxControlReach(whenOn: {const FxSwitchKey.rack(input, 'rack-a')}),
        FxControlReach(whenOn: {const FxSwitchKey.rack(input, 'rack-b')}),
      ]);
      expect(repo.fxCostNs, a + b);
      // A rack another control also reaches is not alternated either.
      repo.setFxReach([
        alternates,
        FxControlReach(whenOn: {const FxSwitchKey.rack(input, 'rack-b')}),
      ]);
      expect(repo.fxCostNs, a + b);
    });

    test('the A/B pair across two chains charges the larger side', () {
      repo
        ..setTrackEffects(
          channel: 0,
          effects: [pedal(TrackEffectType.roomVerb, 'a1', rack: rackA)],
        )
        ..setTrackEffects(
          channel: 1,
          effects: [
            pedal(
              TrackEffectType.echo,
              'b1',
              rack: rackB.copyWith(bypassed: true),
            ),
          ],
        )
        ..setFxReach([
          FxControlReach(
            whenOn: {const FxSwitchKey.rack(track, 'rack-a')},
            whenOff: {
              const FxSwitchKey.rack(
                FxAddress(stage: FxStage.track, index: 1),
                'rack-b',
              ),
            },
          ),
        ]);
      expect(repo.fxCostNs, a);
    });

    test('both sides on from the screen charge both until the next press', () {
      repo
        ..setMonitorEffects(input: 0, effects: pair(bOn: true))
        ..setFxReach([
          FxControlReach(
            whenOn: {const FxSwitchKey.rack(input, 'rack-a')},
            whenOff: {const FxSwitchKey.rack(input, 'rack-b')},
          ),
        ]);
      expect(repo.fxCostNs, a + b);
    });

    test('switching an unreached effect on is weighed by what it adds', () {
      final off = pedal(TrackEffectType.roomVerb, 'r', enabled: false);
      repo.setTrackEffects(channel: 0, effects: [off]);
      expect(
        repo.fxGrowthNs({
          track: [off.copyWith(enabled: true)],
        }),
        a,
      );
      repo
        ..setTrackEffects(channel: 0, effects: [off.copyWith(enabled: true)])
        ..setTrackChainEnabled(channel: 0, enabled: false);
      expect(repo.fxGrowthNs(const {}, chainSwitches: {track: true}), a);
    });

    test('a binding that would not fit is refused; one that fits, or adds '
        'nothing, is not', () {
      // Nine Room reverbs on: 6,165 of the 7,145 ns. Two more, off, cost
      // nothing until a control can turn them on.
      repo
        ..setTrackEffects(
          channel: 0,
          effects: [
            for (var i = 0; i < 9; i++) pedal(TrackEffectType.roomVerb, 'on$i'),
          ],
        )
        ..setTrackEffects(
          channel: 1,
          effects: [
            pedal(TrackEffectType.roomVerb, 'x', enabled: false),
            pedal(TrackEffectType.roomVerb, 'y', enabled: false),
          ],
        );
      const one = FxAddress(stage: FxStage.track, index: 1);
      final x = FxControlReach(whenOn: {const FxSwitchKey.slot(one, 'x')});
      final both = FxControlReach(
        whenOn: {
          const FxSwitchKey.slot(one, 'x'),
          const FxSwitchKey.slot(one, 'y'),
        },
      );
      expect(repo.fxRoomNs, lessThan(2 * a));
      expect(repo.fxRoomNs, greaterThanOrEqualTo(a));
      expect(repo.fxReachFits([x]), isTrue);
      expect(repo.fxReachFits([both]), isFalse);
      // Alternated, only one of them is ever on: it fits.
      expect(
        repo.fxReachFits([
          FxControlReach(
            whenOn: {const FxSwitchKey.slot(one, 'x')},
            whenOff: {const FxSwitchKey.slot(one, 'y')},
          ),
        ]),
        isTrue,
      );
      // A control that reaches what is on already adds nothing.
      expect(
        repo.fxReachFits([
          FxControlReach(whenOn: {const FxSwitchKey.slot(track, 'on0')}),
        ]),
        isTrue,
      );
    });
  });

  group('effects on more than one core (#1515)', () {
    // Ed's Rack, the plan's unit (section 7): 3,362 ns a frame at 96 kHz
    // on the console's own table (#1508, the overdrive's scaled for #1663),
    // 2,665 in the plan.
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
      expect(rackNs, 3362);
      expect(fxBudgetNs(96000), 7145);
    });

    test("three of Ed's Racks fit the callback alone at the owner's 48 kHz "
        '/ 32', () {
      final ns = fxChainCostNs(rack, period: 32, sampleRate: 48000);
      final budget = fxBudgetNs(48000, period: 32);
      expect(3 * ns, lessThanOrEqualTo(budget));
      expect(4 * ns, greaterThan(budget));
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

      test('a pedal a control reaches is never refused: on or off it is '
          'charged', () {
        putRacks(4);
        // A control reaches every pedal of input 1's rack.
        final ids = [for (final fx in repo.monitorEffects(0)) fx.slotId!];
        repo.setFxReach([
          FxControlReach(
            whenOn: {
              for (final id in ids)
                FxSwitchKey.slot(const FxAddress(stage: FxStage.input), id),
            },
          ),
        ]);
        final on = repo.monitorEffects(0);
        final off = [
          for (final fx in on) (fx as BuiltInEffect).copyWith(enabled: false),
        ];
        expect(
          repo.fxGrowthNs({const FxAddress(stage: FxStage.input): off}),
          0,
        );
        // Switched off, switching it back on grows nothing either.
        repo.setMonitorEffects(input: 0, effects: off);
        expect(
          repo.fxGrowthNs({const FxAddress(stage: FxStage.input): on}),
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
