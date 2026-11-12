import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno_engine/segno_engine.dart'
    show FxDraining, FxOwner, MockAudioEngine;

BuiltInEffect _fx(TrackEffectType type) => BuiltInEffect(type: type);

int _cost(TrackEffectType type) => fxEntryCostNs(_fx(type));

void main() {
  group('the effects budget', () {
    test('every table has a figure for every setting and every kind', () {
      final n = kFxCostSettings.length;
      expect(n, 8);
      // Every kind has one figure, or one per setting, or PSOLA's.
      expect(
        {
          ...kFxKindCostNs.keys,
          ...kFxSettingCostNs.keys,
          TrackEffectType.smartTune,
        },
        unorderedEquals(TrackEffectType.values),
      );
      expect(
        kFxKindCostNs.keys.toSet().intersection(kFxSettingCostNs.keys.toSet()),
        isEmpty,
      );
      for (final MapEntry(key: type, value: ns) in kFxSettingCostNs.entries) {
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
      // A rate between two measured ones takes the nearer on its side of
      // 88.2 kHz, where the oversampled kinds change how much they run.
      expect(at(50000, 32), 48000032);
      expect(at(72000, 32), 48000032);
      expect(at(88200, 32), 88200032);
      expect(at(192000, 64), 96000064);
      // No rate reported: the bench's.
      expect(at(0, 0), 96000064);
      final overdrive = _fx(TrackEffectType.overdrive);
      final i = fxCostSetting(48000, 32);
      expect(
        fxEntryCostNs(overdrive, period: 32, sampleRate: 48000),
        kFxSettingCostNs[TrackEffectType.overdrive]![i],
      );
      // A kind whose work is the same a frame everywhere charges the same.
      final delay = _fx(TrackEffectType.delay);
      for (final (:rate, :period) in kFxCostSettings) {
        expect(
          fxEntryCostNs(delay, period: period, sampleRate: rate),
          kFxKindCostNs[TrackEffectType.delay],
        );
      }
    });

    test('an entry charges its kind, on or off; PSOLA its own', () {
      final i = fxCostSetting(48000, 32);
      final octaver = _fx(TrackEffectType.octaver);
      int at4832(TrackEffect fx) =>
          fxEntryCostNs(fx, period: 32, sampleRate: 48000);
      expect(at4832(octaver), kFxSettingCostNs[TrackEffectType.octaver]![i]);
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

    test('a kind on the hop at 44.1 kHz / 64 charges two quarters a block', () {
      for (final type in [
        TrackEffectType.octaver,
        TrackEffectType.whammy,
        TrackEffectType.dualOctaver,
      ]) {
        expect(
          fxEntryCostNs(_fx(type), sampleRate: 44100),
          greaterThanOrEqualTo(
            fxEntryCostNs(_fx(type), period: 32, sampleRate: 44100),
          ),
          reason: type.name,
        );
      }
    });

    test('a kind on the hop costs most a frame at 44.1 kHz', () {
      // Its frame's slots (#1755) fall two to a 32-frame block at 48 kHz,
      // one at 96 kHz, and up to three at 44.1 kHz.
      for (final type in [
        TrackEffectType.octaver,
        TrackEffectType.whammy,
        TrackEffectType.dualOctaver,
      ]) {
        for (final rate in [48000, 88200, 96000]) {
          expect(
            fxEntryCostNs(_fx(type), period: 32, sampleRate: 44100),
            greaterThan(fxEntryCostNs(_fx(type), period: 32, sampleRate: rate)),
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

    test('outside the measured settings a charge only grows', () {
      final octaver = _fx(TrackEffectType.octaver);
      final delay = _fx(TrackEffectType.delay);
      // A 16-frame block still takes a hop quarter, and a block's own work.
      expect(
        fxEntryCostNs(octaver, period: 16, sampleRate: 48000),
        2 * fxEntryCostNs(octaver, period: 32, sampleRate: 48000),
      );
      expect(
        fxEntryCostNs(delay, period: 16),
        2 * fxEntryCostNs(delay, period: 32),
      );
      // Under 44.1 kHz the 48 kHz kernel runs more samples a frame.
      expect(
        fxEntryCostNs(octaver, sampleRate: 22050),
        2 * fxEntryCostNs(octaver, sampleRate: 44100),
      );
      expect(
        fxEntryCostNs(delay, sampleRate: 22050),
        fxEntryCostNs(delay, sampleRate: 44100),
      );
      // Between 32 and 64 frames, the 32-frame figure, the larger.
      expect(
        fxEntryCostNs(octaver, period: 48, sampleRate: 48000),
        fxEntryCostNs(octaver, period: 32, sampleRate: 48000),
      );
    });

    test("the budget is the share of a frame less the engine's own cost", () {
      final i32 = fxCostSetting(48000, 32);
      final i64 = fxCostSetting(48000, 64);
      expect(fxBaseNs(48000, period: 32), (kFxBaseUs[i32] * 1000 / 32).ceil());
      expect(fxBaseNs(48000), (kFxBaseUs[i64] * 1000 / 64).ceil());
      // Between the two, the line through them: 48 frames take the base's
      // fixed part over fewer frames than 64 do.
      final perFrame = (kFxBaseUs[i64] - kFxBaseUs[i32]) / 32;
      final fixed = kFxBaseUs[i32] - 32 * perFrame;
      expect(
        fxBaseNs(48000, period: 48),
        ((fixed + 48 * perFrame) * 1000 / 48).ceil(),
      );
      expect(fxBaseNs(48000, period: 48), greaterThan(fxBaseNs(48000)));
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

  test("the draining kinds are the engine's (le_fx_type_drains)", () {
    // The effects table in engine_fx.c: each entry `[LE_FX_NAME] = {...}`,
    // the draining ones flagged LE_FX_F_DRAINS.
    final source = File(
      '../segno_engine/src/core/engine_fx.c',
    ).readAsStringSync();
    final table = source.substring(
      source.indexOf('static const le_fx_vtable LE_FX[] = {'),
    );
    final body = table.substring(0, table.indexOf('\n};'));
    final draining = <String>{};
    final entries = RegExp(r'\[LE_FX_([A-Z_]+)\]').allMatches(body).toList();
    for (final (i, entry) in entries.indexed) {
      final end = i + 1 < entries.length ? entries[i + 1].start : body.length;
      if (!body.substring(entry.start, end).contains('LE_FX_F_DRAINS')) {
        continue;
      }
      final words = entry.group(1)!.toLowerCase().split('_');
      draining.add(
        words.first +
            words
                .skip(1)
                .map((w) => w[0].toUpperCase() + w.substring(1))
                .join(),
      );
    }
    expect(draining, isNotEmpty);
    expect({for (final kind in kFxDrainingKinds) kind.name}, draining);
  });

  group('tails still draining (#1733)', () {
    late MockAudioEngine engine;
    late StreamController<void> ticks;
    late LooperRepository repo;

    const one = FxAddress(stage: FxStage.track, index: 1);
    const two = FxAddress(stage: FxStage.track, index: 2);
    final drive = _cost(TrackEffectType.overdrive);
    final room = _cost(TrackEffectType.roomVerb);

    setUp(() async {
      engine = MockAudioEngine();
      ticks = StreamController<void>.broadcast(sync: true);
      repo = LooperRepository(engine: engine, ticker: ticks.stream)
        ..startEngine(const EngineConfig(sampleRate: 96000));
      final polling = repo.looperState.listen((_) {});
      addTearDown(() async {
        unawaited(polling.cancel());
        await repo.dispose();
        await ticks.close();
      });
      await pumpEventQueue();
    });

    List<TrackEffect> drives(int count) => [
      for (var i = 0; i < count; i++)
        BuiltInEffect(type: TrackEffectType.overdrive, slotId: 'd$i'),
    ];

    void poll() => ticks
      ..add(null)
      ..add(null)
      ..add(null);

    test('a held chain still charges the tails it drains', () {
      // Track 1 fills the budget; track 2's Room reverb then does not fit
      // and is held off (R2).
      repo.setTrackEffects(channel: 0, effects: drives(repo.fxRoomNs ~/ drive));
      final full = repo.fxCostNs;
      repo.setTrackEffects(
        channel: 2,
        effects: [
          BuiltInEffect(type: TrackEffectType.roomVerb, slotId: 'r'),
        ],
      );
      expect(repo.fxChainHeld(two), isTrue);
      // Held, its reverb drains on: it is charged until it is quiet.
      engine.fxDraining = FxDraining(const {(FxOwner.track, 2, 0): 1});
      poll();
      expect(repo.fxCostNs, full + room);
      engine.fxDraining = FxDraining.none;
      poll();
      expect(repo.fxCostNs, full);
    });

    test('a running chain of reverbs can still be held: held, it stops '
        'once its tails drain', () {
      repo.setTrackEffects(
        channel: 2,
        effects: [
          BuiltInEffect(type: TrackEffectType.roomVerb, slotId: 'r'),
          BuiltInEffect(type: TrackEffectType.echo, slotId: 'e'),
        ],
      );
      poll();
      repo.setTrackEffects(
        channel: 0,
        effects: drives(repo.fxRoomNs ~/ drive + 1),
      );
      expect(repo.fxChainHeld(two), isTrue);
      expect(repo.fxChainHeld(one), isFalse);
    });

    test('a reverb added and switched off between two polls still counts '
        'as draining', () {
      // Room for the reverb, and less than an Overdrive more.
      repo.setTrackEffects(
        channel: 0,
        effects: drives((repo.fxRoomNs - room) ~/ drive),
      );
      final full = repo.fxCostNs;
      repo
        ..setTrackEffects(
          channel: 1,
          effects: [
            BuiltInEffect(
              type: TrackEffectType.roomVerb,
              slotId: 'r',
              enabled: false,
            ),
          ],
        )
        ..setTrackEffects(
          channel: 1,
          effects: [
            BuiltInEffect(type: TrackEffectType.roomVerb, slotId: 'r'),
          ],
        )
        ..setTrackEffectEnabled(channel: 1, index: 0, enabled: false);
      expect(repo.fxCostNs, full + room);
    });

    test('a chain whose hold frees nothing is never held: its draining '
        'tail runs either way', () {
      // Track 3: an Echo switched off, still draining.
      repo.setTrackEffects(
        channel: 2,
        effects: [
          BuiltInEffect(
            type: TrackEffectType.echo,
            slotId: 'e',
            enabled: false,
          ),
        ],
      );
      engine.fxDraining = FxDraining(const {(FxOwner.track, 2, 0): 1});
      poll();
      // Track 2 nearly fills the budget, then track 1 goes over.
      repo
        ..setTrackEffects(channel: 1, effects: drives(repo.fxRoomNs ~/ drive))
        ..setTrackEffects(channel: 0, effects: drives(2));
      expect(repo.fxChainHeld(two), isFalse);
      expect(repo.fxChainHeld(one), isTrue);
      expect(repo.state.fxHoldNotice, isNot(contains(two)));
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

    /// Rack A (a Overdrive) on, rack B (a Chorus and a Filter) off: the A/B
    /// pair of #1711 in one chain.
    List<TrackEffect> pair({bool aOn = true, bool bOn = false}) => [
      pedal(
        TrackEffectType.overdrive,
        'a1',
        rack: rackA.copyWith(bypassed: !aOn),
      ),
      pedal(TrackEffectType.chorus, 'b1', rack: rackB.copyWith(bypassed: !bOn)),
      pedal(TrackEffectType.filter, 'b2', rack: rackB.copyWith(bypassed: !bOn)),
    ];

    final a = _cost(TrackEffectType.overdrive);
    final b = _cost(TrackEffectType.chorus) + _cost(TrackEffectType.filter);

    setUp(() {
      engine = MockAudioEngine();
      repo = LooperRepository(engine: engine)
        ..startEngine(const EngineConfig(sampleRate: 96000, inputChannels: 2));
      addTearDown(repo.dispose);
    });

    test('an off effect no control reaches charges nothing', () {
      repo.setTrackEffects(
        channel: 0,
        effects: [pedal(TrackEffectType.overdrive, 'r', enabled: false)],
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
            pedal(TrackEffectType.overdrive, 'r', enabled: false),
            pedal(
              TrackEffectType.chorus,
              'e',
              rack: rackB.copyWith(bypassed: true),
            ),
            pedal(TrackEffectType.filter, 'd', rack: rackB, enabled: false),
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
        _cost(TrackEffectType.overdrive) + _cost(TrackEffectType.chorus),
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
          effects: [pedal(TrackEffectType.overdrive, 'a1', rack: rackA)],
        )
        ..setTrackEffects(
          channel: 1,
          effects: [
            pedal(
              TrackEffectType.chorus,
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

    test('an A/B press across two chains is weighed as one: the side it '
        'switches on lands beside the side it switches off', () {
      const other = FxAddress(stage: FxStage.track, index: 1);
      List<TrackEffect> sideA({required bool on}) => [
        pedal(
          TrackEffectType.overdrive,
          'a1',
          rack: rackA.copyWith(bypassed: !on),
        ),
      ];
      List<TrackEffect> sideB({required bool on}) => [
        pedal(
          TrackEffectType.overdrive,
          'b1',
          rack: rackB.copyWith(bypassed: !on),
        ),
      ];
      repo
        ..setTrackEffects(channel: 0, effects: sideA(on: true))
        ..setTrackEffects(channel: 1, effects: sideB(on: false))
        ..setFxReach([
          FxControlReach(
            whenOn: {const FxSwitchKey.rack(track, 'rack-a')},
            whenOff: {const FxSwitchKey.rack(other, 'rack-b')},
          ),
        ]);
      // Less than one more Overdrive fits.
      repo.setTrackEffects(
        channel: 2,
        effects: [
          for (var i = 0; i < repo.fxRoomNs ~/ a; i++)
            BuiltInEffect(type: TrackEffectType.overdrive),
        ],
      );
      expect(repo.state.fxHeld, isEmpty);

      repo.fxPress(
        {
          other: (entries: sideB(on: true), on: true),
          track: (entries: sideA(on: false), on: true),
        },
        () => repo
          ..setTrackEffects(channel: 1, effects: sideB(on: true))
          ..setTrackEffects(channel: 0, effects: sideA(on: false)),
      );

      expect(repo.state.fxHeld, isEmpty);
      expect(repo.fxRoomNs, greaterThanOrEqualTo(0));
      // Landed one chain at a time, the first write would not fit.
      repo
        ..setTrackEffects(channel: 0, effects: sideA(on: true))
        ..setTrackEffects(channel: 1, effects: sideB(on: false));
      expect(repo.state.fxHeld, isNotEmpty);
    });

    test('the side a press turns off keeps charging what drains its tail: '
        'the delay, the echo and the reverbs run on after the switch', () {
      repo
        ..setMonitorEffects(
          input: 0,
          effects: [
            pedal(TrackEffectType.overdrive, 'a1', rack: rackA),
            pedal(
              TrackEffectType.roomVerb,
              'a2',
              rack: rackA,
            ),
            pedal(
              TrackEffectType.chorus,
              'b1',
              rack: rackB.copyWith(bypassed: true),
            ),
            pedal(
              TrackEffectType.echo,
              'b2',
              rack: rackB.copyWith(bypassed: true),
            ),
          ],
        )
        ..setFxReach([
          FxControlReach(
            whenOn: {const FxSwitchKey.rack(input, 'rack-a')},
            whenOff: {const FxSwitchKey.rack(input, 'rack-b')},
          ),
        ]);
      final overdrive = _cost(TrackEffectType.overdrive);
      final room = _cost(TrackEffectType.roomVerb);
      final chorus = _cost(TrackEffectType.chorus);
      final echo = _cost(TrackEffectType.echo);
      // Rack A on with B's echo draining, or B on with A's reverb draining.
      final aSide = overdrive + room + echo;
      final bSide = chorus + echo + room;
      expect(repo.fxCostNs, aSide > bSide ? aSide : bSide);
      expect(repo.fxCostNs, lessThan(overdrive + room + chorus + echo));
      // Draining is charged only where an alternation could leave it so: an
      // effect off that no control reaches still charges nothing.
      expect(
        fxDrains(BuiltInEffect(type: TrackEffectType.roomVerb)),
        isTrue,
      );
      expect(fxDrains(BuiltInEffect(type: TrackEffectType.overdrive)), isFalse);
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
      final off = pedal(TrackEffectType.overdrive, 'r', enabled: false);
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
      // Overdrives on until one more fits and two do not. Two more, off,
      // cost nothing until a control can turn them on.
      final count = repo.fxRoomNs ~/ a - 1;
      repo
        ..setTrackEffects(
          channel: 0,
          effects: [
            for (var i = 0; i < count; i++)
              pedal(TrackEffectType.overdrive, 'on$i'),
          ],
        )
        ..setTrackEffects(
          channel: 1,
          effects: [
            pedal(TrackEffectType.overdrive, 'x', enabled: false),
            pedal(TrackEffectType.overdrive, 'y', enabled: false),
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
    // Ed's Rack, the plan's unit (section 7): 2,666 ns a frame at 96 kHz / 64
    // on the console's own table (#1508, #1724, #1755, #1761), 2,665 in the
    // plan.
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
      expect(rackNs, 2666);
      expect(fxBudgetNs(96000), 6834);
    });

    test("at the owner's 48 kHz / 32, four of Ed's Racks fit the callback "
        'alone and eleven fit the inputs with two workers (#1755: three and '
        'seven before it)', () {
      final ns = fxChainCostNs(rack, period: 32, sampleRate: 48000);
      final budget = fxBudgetNs(48000, period: 32);
      expect(ns, 3181);
      expect(budget, 14622);
      expect(4 * ns, lessThanOrEqualTo(budget));
      expect(5 * ns, greaterThan(budget));
      int load(int racks) => fxLoadNs(
        serial: 0,
        jobs: List.filled(racks, ns),
        workers: 2,
        period: 32,
      );
      expect(load(11), lessThanOrEqualTo(budget));
      expect(load(12), greaterThan(budget));
    });

    // Before #1755 the console ran 5 tracks and 4 inputs with 1 track with
    // no late period, 6 tracks and 4 inputs with 3 tracks with more than
    // #1724's limit run (#1729). With #1755's pitch kernels it ran 7 and 8
    // tracks with none (120 s each, the callback's worst service 441 and
    // 432 us of 666), so the rule admitting 7 stays on the safe side.
    test("at 48 kHz / 32 with two workers, seven of Ed's Racks fit on "
        'tracks and eight do not; four on inputs leave room for five on '
        'tracks, not six (#1729, #1755)', () {
      final ns = fxChainCostNs(rack, period: 32, sampleRate: 48000);
      final budget = fxBudgetNs(48000, period: 32);
      int load(int inputs, int tracks) => fxLoadNs(
        serial: 0,
        jobs: List.filled(inputs + tracks, ns),
        workers: 2,
        period: 32,
        trackJobs: tracks,
      );
      expect(load(0, 7), lessThanOrEqualTo(budget));
      expect(load(0, 8), greaterThan(budget));
      expect(load(4, 5), lessThanOrEqualTo(budget));
      expect(load(4, 6), greaterThan(budget));
      // On the callback alone, before #1729: four.
      expect(4 * ns, lessThanOrEqualTo(budget));
      expect(5 * ns, greaterThan(budget));
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

    // The plan's table admitted 2, 4, 6 and 7 at its 2,665 ns; the worst of
    // eight at 80 % admitted 2, 3, 4 and 5; #1724's table 2, 2, 3 and 4.
    test('admits 2, 4, 5 and 7 racks with 0 to 3 workers at 96 kHz', () {
      expect(racksAdmitted(0), 2);
      expect(racksAdmitted(1), 4);
      expect(racksAdmitted(2), 5);
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

      test('five racks on the inputs fit two workers, six do not', () {
        putRacks(5);
        expect(repo.fxRoomNs, greaterThanOrEqualTo(0));
        expect(repo.state.fxHeld, isEmpty);
        // A sixth is weighed by what it adds to the critical path.
        final sixth = repo.fxGrowthNs({
          const FxAddress(stage: FxStage.input, index: 5): rack,
        });
        expect(sixth, greaterThan(repo.fxRoomNs));
        // Restored anyway, it comes up switched off (the owner's R2).
        putRacks(6);
        expect(
          repo.fxChainHeld(const FxAddress(stage: FxStage.input, index: 5)),
          isTrue,
        );
        expect(repo.fxRoomNs, greaterThanOrEqualTo(0));
      });

      test("a rack on a track, or on a track's lane, is a job as one on an "
          'input is (#1729); on an output it runs on the callback', () {
        putRacks(2);
        final onInput = repo.fxGrowthNs({
          const FxAddress(stage: FxStage.input, index: 2): rack,
        });
        final onTrack = repo.fxGrowthNs({
          const FxAddress(stage: FxStage.track): rack,
        });
        final onLane = repo.fxGrowthNs({
          const FxAddress(stage: FxStage.loop, index: 1): rack,
        });
        final onOutput = repo.fxGrowthNs({
          const FxAddress(stage: FxStage.output): rack,
        });
        // The callback records and sums a track's job (kFxTrackJobNs).
        expect(onTrack, onInput + kFxTrackJobNs);
        expect(onLane, onInput + kFxTrackJobNs);
        expect(onOutput, rackNs);
        expect(onInput, lessThan(onOutput));
        // A track's lanes and its own chain are one job: a second rack on
        // the same track grows the job, not the number of jobs.
        expect(
          repo.setTrackEffects(channel: 0, effects: rack),
          EngineResult.ok,
        );
        final sameTrack = repo.fxGrowthNs({
          const FxAddress(stage: FxStage.loop): rack,
        });
        final otherTrack = repo.fxGrowthNs({
          const FxAddress(stage: FxStage.loop, index: 1): rack,
        });
        expect(sameTrack, greaterThan(otherTrack));
      });

      test('a rack on one track alone, with no input chain, is one job: it '
          'runs on the callback (#1729)', () {
        expect(
          repo.setTrackEffects(channel: 0, effects: rack),
          EngineResult.ok,
        );
        expect(repo.fxCostNs, rackNs);
        // A second track's rack makes two jobs, which the workers share.
        final second = repo.fxGrowthNs({
          const FxAddress(stage: FxStage.track, index: 1): rack,
        });
        expect(second, lessThan(rackNs));
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
