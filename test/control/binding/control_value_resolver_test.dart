import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:segno/control/binding/control_value_resolver.dart';
import 'package:segno/control/binding/control_value_target.dart';
import 'package:segno/control/binding/owned_value_control.dart';
import 'package:segno/looper/model/click_mode.dart';
import 'package:segno/looper/model/one_shot.dart';
import 'package:segno/looper/model/overdub_decay.dart';
import 'package:segno/looper/model/record_length.dart';
import 'package:segno/looper/model/record_start.dart';
import 'package:segno/looper/model/record_timing.dart';
import 'package:settings_repository/settings_repository.dart';

class _MockLooperRepository extends Mock implements LooperRepository {}

BuiltInEffect _drive(String slotId, {List<double>? params}) => BuiltInEffect(
  type: TrackEffectType.drive,
  slotId: slotId,
  params: params,
);

void main() {
  late _MockLooperRepository looper;
  late Map<int, List<TrackEffect>> monitorChains;
  late Map<(int, int), List<TrackEffect>> laneChains;
  late Map<int, List<TrackEffect>> trackChains;
  late List<TrackEffect> masterChain;
  late List<Track> tracks;
  late InputSetup inputs;
  late MixSettingsSnapshot mix;

  setUp(() {
    looper = _MockLooperRepository();
    monitorChains = {
      2: [_drive('m-1')],
    };
    laneChains = {
      (1, 0): [
        _drive('l-1', params: [0.1, 0.2, 0.3, 0.4]),
      ],
    };
    trackChains = {
      5: [
        // A hosted plugin offers no continuous targets in v1.
        const PluginEffect(
          ref: PluginRef(format: PluginFormat.vst3, id: 'p'),
          slotId: 'plug-1',
        ),
        _drive('t-1'),
      ],
    };
    masterChain = [_drive('mx-1')];
    tracks = [
      const Track(volume: 0.5),
      const Track(channel: 1),
    ];
    inputs = InputSetup(pairs: const {0: 0.2}, pan: const {2: -0.4});
    mix = MixSettingsSnapshot(
      trackLevels: const {0: 0.5},
      trackPans: const {1: 0.25},
      laneLevels: const {(1, 0): 1.25},
      monitorLevels: const {2: 1},
      inputSetup: inputs,
      outputSetup: const OutputSetup(
        buses: {0: OutputBus(level: 0.6, balance: -0.2)},
      ),
    );

    when(() => looper.allMonitors()).thenAnswer(
      (_) => {
        for (final input in monitorChains.keys)
          input: InputMonitor(input: input),
      },
    );
    when(() => looper.allLaneChains()).thenAnswer(
      (_) => {for (final key in laneChains.keys) key: const FxChainEnvelope()},
    );
    when(() => looper.allTrackChains()).thenAnswer(
      (_) => {
        for (final channel in trackChains.keys)
          channel: const FxChainEnvelope(),
      },
    );
    when(
      () => looper.monitorEffects(any()),
    ).thenAnswer((i) => monitorChains[i.positionalArguments[0]] ?? const []);
    when(() => looper.laneEffects(any(), any())).thenAnswer(
      (i) =>
          laneChains[(
            i.positionalArguments[0] as int,
            i.positionalArguments[1] as int,
          )] ??
          const [],
    );
    when(
      () => looper.trackEffects(any()),
    ).thenAnswer((i) => trackChains[i.positionalArguments[0]] ?? const []);
    when(() => looper.outputEffects(0)).thenAnswer((_) => masterChain);
    when(() => looper.allTracksEffects).thenReturn(const []);
    when(() => looper.outputChainEnabled(any())).thenReturn(true);
    when(() => looper.allTracksChainEnabled).thenReturn(true);
    when(() => looper.state).thenAnswer(
      (_) => LooperState(
        tracks: tracks,
        status: const EngineStatus(inputChannels: 3, outputChannels: 2),
        outputBusCount: 1,
      ),
    );
    when(() => looper.mixSettingsSnapshot).thenAnswer((_) => mix);
    when(() => looper.inputSetup).thenAnswer((_) => inputs);
    when(() => looper.laneCount(any())).thenReturn(1);
  });

  const laneParam = FxParamTarget(
    address: FxAddress(stage: FxStage.loop, index: 1, lane: 0),
    slotId: 'l-1',
    // Drive's second descriptor ("Level") — the effect type's OWN parameter
    // list is what bounds a target, not the raw value array.
    param: 1,
  );

  group('availableValueTargets', () {
    test('offers every built-in param, the track volumes, and master gain', () {
      final targets = looper.availableValueTargets();

      expect(
        targets.whereType<FxParamTarget>().where((t) => t.slotId == 'l-1'),
        hasLength(TrackEffectType.drive.params.length),
      );
      expect(targets.whereType<TrackVolumeTarget>().map((t) => t.channel), [
        0,
        1,
      ]);
      expect(targets.whereType<MasterGainTarget>(), hasLength(1));
      expect(targets.whereType<LaneVolumeTarget>(), hasLength(2));
      expect(targets.whereType<MonitorVolumeTarget>(), hasLength(3));
      expect(targets.whereType<TrackPanTarget>(), hasLength(2));
      expect(targets.whereType<InputPanTarget>().map((t) => t.input), [2]);
      expect(targets.whereType<PairBalanceTarget>().map((t) => t.input), [0]);
      expect(targets.whereType<OutputLevelTarget>(), hasLength(1));
      expect(targets.whereType<OutputBalanceTarget>(), hasLength(1));
    });

    test('never offers a hosted plugin slot', () {
      final targets = looper.availableValueTargets().whereType<FxParamTarget>();

      expect(targets.where((t) => t.slotId == 'plug-1'), isEmpty);
    });

    test('Click needs a confirmed owner, including silent zero, not a bus', () {
      when(() => looper.state).thenAnswer(
        (_) => const LooperState(),
      );
      const target = ClickVolumeTarget();
      expect(
        looper.availableValueTargets().whereType<ClickVolumeTarget>(),
        isEmpty,
      );
      expect(looper.valueTargetResolves(target), isFalse);
      expect(looper.readValueTarget(target), isNull);
      expect(
        looper
            .availableValueTargets(
              owned: const OwnedValueSnapshots(
                clickVolume: 0,
              ),
            )
            .whereType<ClickVolumeTarget>(),
        [target],
      );
      expect(
        looper.valueTargetResolves(
          target,
          owned: const OwnedValueSnapshots(
            clickVolume: 0,
          ),
        ),
        isTrue,
      );
      expect(
        looper.readValueTarget(
          target,
          owned: const OwnedValueSnapshots(
            clickVolume: 0,
          ),
        ),
        0,
      );
      expect(
        looper.readValueTarget(
          target,
          owned: const OwnedValueSnapshots(
            clickVolume: 1,
          ),
        ),
        0.5,
      );
      expect(
        looper.readValueTarget(
          target,
          owned: const OwnedValueSnapshots(
            clickVolume: 2,
          ),
        ),
        1,
      );
    });

    test('Hear click is absent until confirmed, including explicit Off', () {
      const target = ClickModeValueTarget();
      const off = ClickModeSnapshot(mode: ClickMode.off, captureLocked: false);
      const locked = ClickModeSnapshot(
        mode: ClickMode.recFirst,
        captureLocked: true,
      );
      expect(
        looper.availableValueTargets().whereType<ClickModeValueTarget>(),
        isEmpty,
      );
      expect(looper.valueTargetResolves(target), isFalse);
      expect(looper.readValueTarget(target), isNull);
      expect(
        looper
            .availableValueTargets(
              owned: const OwnedValueSnapshots(
                clickModeSnapshot: off,
              ),
            )
            .whereType<ClickModeValueTarget>(),
        [target],
      );
      expect(
        looper.valueTargetResolves(
          target,
          owned: const OwnedValueSnapshots(
            clickModeSnapshot: off,
          ),
        ),
        isTrue,
      );
      expect(
        looper.readValueTarget(
          target,
          owned: const OwnedValueSnapshots(
            clickModeSnapshot: off,
          ),
        ),
        0,
      );
      expect(
        looper.valueTargetResolves(
          target,
          owned: const OwnedValueSnapshots(
            clickModeSnapshot: locked,
          ),
        ),
        isTrue,
      );
      expect(
        looper.readValueTarget(
          target,
          owned: const OwnedValueSnapshots(
            clickModeSnapshot: locked,
          ),
        ),
        1 / 3,
      );
    });

    test('Count-in is absent until its pair is confirmed, including Off', () {
      const target = CountInValueTarget();
      final off = RecordStartSnapshot(
        settings: RecordStartSettings(countInBars: 0, soundStart: true),
        captureLocked: false,
      );
      final locked = RecordStartSnapshot(
        settings: RecordStartSettings(countInBars: 4, soundStart: false),
        captureLocked: true,
      );
      expect(
        looper.availableValueTargets().whereType<CountInValueTarget>(),
        isEmpty,
      );
      expect(looper.valueTargetResolves(target), isFalse);
      expect(looper.readValueTarget(target), isNull);
      expect(
        looper
            .availableValueTargets(
              owned: OwnedValueSnapshots(
                recordStartSnapshot: off,
              ),
            )
            .whereType<CountInValueTarget>(),
        [target],
      );
      expect(
        looper.valueTargetResolves(
          target,
          owned: OwnedValueSnapshots(
            recordStartSnapshot: off,
          ),
        ),
        isTrue,
      );
      expect(
        looper.readValueTarget(
          target,
          owned: OwnedValueSnapshots(
            recordStartSnapshot: off,
          ),
        ),
        0,
      );
      expect(
        looper.valueTargetResolves(
          target,
          owned: OwnedValueSnapshots(
            recordStartSnapshot: locked,
          ),
        ),
        isTrue,
      );
      expect(
        looper.readValueTarget(
          target,
          owned: OwnedValueSnapshots(
            recordStartSnapshot: locked,
          ),
        ),
        1,
      );
    });

    test('decay offers default and all fixed tracks only with an owner', () {
      final snapshot = DecaySnapshot(
        defaultPercent: 50,
        trackOverrides: const {0: 0, 7: 80},
      );
      expect(
        looper.availableValueTargets().whereType<DecayValueTarget>(),
        isEmpty,
      );
      expect(looper.valueTargetResolves(const DefaultDecayTarget()), isFalse);
      expect(looper.readValueTarget(const TrackDecayTarget(0)), isNull);
      final offered = looper
          .availableValueTargets(
            owned: OwnedValueSnapshots(
              decaySnapshot: snapshot,
            ),
          )
          .whereType<DecayValueTarget>()
          .toList();
      expect(offered.first, const DefaultDecayTarget());
      expect(
        offered.whereType<TrackDecayTarget>().map((t) => t.channel),
        List.generate(8, (index) => index),
      );
      expect(
        looper.valueTargetResolves(
          const TrackDecayTarget(7),
          owned: OwnedValueSnapshots(
            decaySnapshot: snapshot,
          ),
        ),
        isTrue,
      );
      expect(
        looper.valueTargetResolves(
          const TrackDecayTarget(8),
          owned: OwnedValueSnapshots(
            decaySnapshot: snapshot,
          ),
        ),
        isFalse,
      );
      expect(
        looper.readValueTarget(
          const DefaultDecayTarget(),
          owned: OwnedValueSnapshots(
            decaySnapshot: snapshot,
          ),
        ),
        0.5,
      );
      expect(
        looper.readValueTarget(
          const TrackDecayTarget(0),
          owned: OwnedValueSnapshots(
            decaySnapshot: snapshot,
          ),
        ),
        0,
      );
      expect(
        looper.readValueTarget(
          const TrackDecayTarget(1),
          owned: OwnedValueSnapshots(
            decaySnapshot: snapshot,
          ),
        ),
        0.5,
      );
      expect(
        looper.readValueTarget(
          const TrackDecayTarget(7),
          owned: OwnedValueSnapshots(
            decaySnapshot: snapshot,
          ),
        ),
        0.8,
      );
    });

    test('Fade offers Default and all fixed tracks only when loaded', () {
      final durations = FadeDurations(
        defaultMs: 8000,
        overrides: const {2: 500},
      );
      expect(
        looper.availableValueTargets().whereType<FadeValueTarget>(),
        isEmpty,
      );
      expect(looper.valueTargetResolves(const DefaultFadeTarget()), isFalse);
      expect(looper.readValueTarget(const TrackFadeTarget(0)), isNull);
      final offered = looper
          .availableValueTargets(
            owned: OwnedValueSnapshots(
              fadeDurations: durations,
            ),
          )
          .whereType<FadeValueTarget>()
          .toList();
      expect(offered, [
        const DefaultFadeTarget(),
        for (var channel = 0; channel < 8; channel++) TrackFadeTarget(channel),
      ]);
      expect(
        looper.valueTargetResolves(
          const TrackFadeTarget(8),
          owned: OwnedValueSnapshots(
            fadeDurations: durations,
          ),
        ),
        isFalse,
      );
      // 8 s is 15 half-second steps above 0.5 s; an inheriting track reads
      // the Default, an override its own time.
      for (final (target, travel) in <(FadeValueTarget, double)>[
        (const DefaultFadeTarget(), 15 / 59),
        (const TrackFadeTarget(0), 15 / 59),
        (const TrackFadeTarget(2), 0),
      ]) {
        expect(
          looper.readValueTarget(
            target,
            owned: OwnedValueSnapshots(
              fadeDurations: durations,
            ),
          ),
          travel,
        );
      }
    });

    test('Loop/Once distinguishes an unready owner from explicit Loop', () {
      final snapshot = OneShotSnapshot(
        defaultOneShot: true,
        trackOverrides: const {0: false, 7: true},
      );
      expect(
        looper.availableValueTargets().whereType<OneShotValueTarget>(),
        isEmpty,
      );
      expect(looper.valueTargetResolves(const DefaultOneShotTarget()), isFalse);
      expect(looper.readValueTarget(const TrackOneShotTarget(0)), isNull);
      final offered = looper
          .availableValueTargets(
            owned: OwnedValueSnapshots(
              oneShotSnapshot: snapshot,
            ),
          )
          .whereType<OneShotValueTarget>()
          .toList();
      expect(offered.first, const DefaultOneShotTarget());
      expect(
        offered.whereType<TrackOneShotTarget>().map((t) => t.channel),
        List.generate(8, (index) => index),
      );
      expect(
        looper.valueTargetResolves(
          const TrackOneShotTarget(8),
          owned: OwnedValueSnapshots(
            oneShotSnapshot: snapshot,
          ),
        ),
        isFalse,
      );
      expect(
        looper.readValueTarget(
          const DefaultOneShotTarget(),
          owned: OwnedValueSnapshots(
            oneShotSnapshot: snapshot,
          ),
        ),
        1,
      );
      expect(
        looper.readValueTarget(
          const TrackOneShotTarget(0),
          owned: OwnedValueSnapshots(
            oneShotSnapshot: snapshot,
          ),
        ),
        0,
      );
      expect(
        looper.readValueTarget(
          const TrackOneShotTarget(1),
          owned: OwnedValueSnapshots(
            oneShotSnapshot: snapshot,
          ),
        ),
        1,
      );
    });

    test('Record length keeps fixed slots and locked values readable', () {
      const defaults = DefaultRecordLengthTarget();
      const first = TrackRecordLengthTarget(0);
      const last = TrackRecordLengthTarget(7);
      expect(
        looper.availableValueTargets().whereType<RecordLengthValueTarget>(),
        isEmpty,
      );
      expect(looper.valueTargetResolves(defaults), isFalse);
      expect(looper.readValueTarget(first), isNull);
      final snapshot = RecordLengthSnapshot(
        defaultBars: 0,
        trackOverrides: const {0: 1, 7: 64},
        mode: LooperMode.song,
        captureLocked: true,
      );
      final offered = looper
          .availableValueTargets(
            owned: OwnedValueSnapshots(
              recordLengthSnapshot: snapshot,
            ),
          )
          .whereType<RecordLengthValueTarget>()
          .toList();
      expect(offered.first, defaults);
      expect(
        offered.whereType<TrackRecordLengthTarget>().map((t) => t.channel),
        List.generate(8, (index) => index),
      );
      expect(snapshot.canEdit(first.address), isFalse);
      expect(
        looper.valueTargetResolves(
          last,
          owned: OwnedValueSnapshots(
            recordLengthSnapshot: snapshot,
          ),
        ),
        isTrue,
      );
      expect(
        looper.valueTargetResolves(
          const TrackRecordLengthTarget(8),
          owned: OwnedValueSnapshots(
            recordLengthSnapshot: snapshot,
          ),
        ),
        isFalse,
      );
      expect(
        looper.readValueTarget(
          defaults,
          owned: OwnedValueSnapshots(
            recordLengthSnapshot: snapshot,
          ),
        ),
        0,
      );
      expect(
        looper.readValueTarget(
          first,
          owned: OwnedValueSnapshots(
            recordLengthSnapshot: snapshot,
          ),
        ),
        1 / 64,
      );
      expect(
        looper.readValueTarget(
          last,
          owned: OwnedValueSnapshots(
            recordLengthSnapshot: snapshot,
          ),
        ),
        1,
      );
      final multi = RecordLengthSnapshot(
        defaultBars: 4,
        trackOverrides: const {0: 1},
        mode: LooperMode.multi,
        captureLocked: false,
      );
      expect(multi.canEdit(defaults.address), isTrue);
      expect(multi.canEdit(first.address), isFalse);
      expect(
        looper.readValueTarget(
          first,
          owned: OwnedValueSnapshots(
            recordLengthSnapshot: multi,
          ),
        ),
        4 / 64,
      );
    });

    test('never offers a slot with no stable id (A9)', () {
      trackChains[5] = [BuiltInEffect(type: TrackEffectType.filter)];

      expect(
        looper.availableValueTargets().whereType<FxParamTarget>().where(
          (t) => t.address.stage == FxStage.track,
        ),
        isEmpty,
      );
    });
  });

  group('resolution', () {
    test('the rig-level targets always resolve', () {
      expect(looper.valueTargetResolves(const MasterGainTarget()), isTrue);
      expect(looper.valueTargetResolves(const TrackVolumeTarget(0)), isTrue);
      expect(looper.valueTargetResolves(const LaneVolumeTarget(1, 0)), isTrue);
      expect(looper.valueTargetResolves(const MonitorVolumeTarget(2)), isTrue);
      expect(looper.valueTargetResolves(const TrackPanTarget(1)), isTrue);
      expect(looper.valueTargetResolves(const InputPanTarget(2)), isTrue);
      expect(looper.valueTargetResolves(const PairBalanceTarget(0)), isTrue);
      expect(looper.valueTargetResolves(const OutputLevelTarget(0)), isTrue);
      expect(looper.valueTargetResolves(const OutputBalanceTarget(0)), isTrue);
    });

    test('missing lanes, jacks, pairs, and buses stay unavailable', () {
      expect(looper.valueTargetResolves(const LaneVolumeTarget(1, 1)), isFalse);
      expect(looper.valueTargetResolves(const InputPanTarget(0)), isFalse);
      expect(looper.valueTargetResolves(const PairBalanceTarget(2)), isFalse);
      expect(looper.valueTargetResolves(const MonitorVolumeTarget(3)), isFalse);
      expect(looper.valueTargetResolves(const OutputLevelTarget(1)), isFalse);
      expect(looper.readValueTarget(const OutputBalanceTarget(1)), isNull);
    });

    test('a live FX param resolves', () {
      expect(looper.valueTargetResolves(laneParam), isTrue);
    });

    test('a target whose slot is gone goes inert — it never retargets', () {
      laneChains[(1, 0)] = [_drive('l-9')];

      expect(looper.valueTargetResolves(laneParam), isFalse);
      expect(looper.readValueTarget(laneParam), isNull);
    });

    test('a lane-less Loop address never coerces onto lane 0', () {
      const laneless = FxParamTarget(
        address: FxAddress(stage: FxStage.loop, index: 1),
        slotId: 'l-1',
        param: 0,
      );

      expect(looper.valueTargetResolves(laneless), isFalse);
    });

    test('a param index past the effect type goes inert', () {
      const past = FxParamTarget(
        address: FxAddress(stage: FxStage.loop, index: 1, lane: 0),
        slotId: 'l-1',
        param: 99,
      );

      expect(looper.valueTargetResolves(past), isFalse);
    });

    test(
      'a plugin slot remains unavailable rather than aliasing its position',
      () {
        const plugin = FxParamTarget(
          address: FxAddress(stage: FxStage.track, index: 5),
          slotId: 'plug-1',
          param: 0,
        );

        expect(looper.valueTargetResolves(plugin), isFalse);
        expect(looper.readValueTarget(plugin), isNull);
      },
    );
  });

  group('reads', () {
    test(
      'timing is offered for all fixed tracks only after owner readiness',
      () {
        final timing = RecordTimingSnapshot(
          defaultTiming: RecordTiming.bar,
          rememberedDivision: GridDivision.bar,
          trackOverrides: const {7: RecordTiming.immediately},
          captureLocked: true,
        );
        const defaultTarget = DefaultRecordTimingTarget();
        const trackTarget = TrackRecordTimingTarget(7);
        expect(looper.availableValueTargets(), isNot(contains(defaultTarget)));
        expect(looper.valueTargetResolves(trackTarget), isFalse);
        final offered = looper.availableValueTargets(
          owned: OwnedValueSnapshots(
            recordTimingSnapshot: timing,
          ),
        );
        expect(offered.whereType<RecordTimingValueTarget>(), hasLength(9));
        expect(offered, contains(defaultTarget));
        expect(offered, contains(trackTarget));
        expect(
          looper.valueTargetResolves(
            trackTarget,
            owned: OwnedValueSnapshots(
              recordTimingSnapshot: timing,
            ),
          ),
          isTrue,
          reason:
              'capture locks edits but does not erase saved target identity',
        );
        expect(
          looper.readValueTarget(
            defaultTarget,
            owned: OwnedValueSnapshots(
              recordTimingSnapshot: timing,
            ),
          ),
          2 / 6,
        );
        expect(
          looper.readValueTarget(
            trackTarget,
            owned: OwnedValueSnapshots(
              recordTimingSnapshot: timing,
            ),
          ),
          0,
          reason: 'explicit Immediately is not inheritance',
        );
        expect(
          looper.readValueTarget(
            const TrackRecordTimingTarget(6),
            owned: OwnedValueSnapshots(
              recordTimingSnapshot: timing,
            ),
          ),
          2 / 6,
        );
        expect(
          looper.readValueTarget(
            const TrackRecordTimingTarget(8),
            owned: OwnedValueSnapshots(
              recordTimingSnapshot: timing,
            ),
          ),
          isNull,
        );
      },
    );
    test('an effect parameter reads its current value', () {
      expect(looper.readValueTarget(laneParam), 0.2);
    });

    test('a track fader and the master read theirs', () {
      when(() => looper.masterGain).thenReturn(0.8);
      expect(
        looper.readValueTarget(const TrackVolumeTarget(0)),
        closeTo(const TrackVolumeTarget(0).fromDomain(0.5), 1e-12),
      );
      expect(looper.readValueTarget(const MasterGainTarget()), 0.8);
    });

    test('new Mixer assignment reads the accepted sound without a jump', () {
      const targets = <MixValueTarget>[
        TrackVolumeTarget(0),
        LaneVolumeTarget(1, 0),
        MonitorVolumeTarget(2),
        TrackPanTarget(1),
        InputPanTarget(2),
        PairBalanceTarget(0),
        OutputLevelTarget(0),
        OutputBalanceTarget(0),
      ];
      const physical = <double>[0.5, 1.25, 1, 0.25, -0.4, 0.2, 0.6, -0.2];
      for (var i = 0; i < targets.length; i++) {
        final position = looper.readValueTarget(targets[i]);
        expect(position, isNotNull);
        expect(targets[i].toDomain(position!), closeTo(physical[i], 1e-10));
      }
    });

    test('a target that does not resolve reads nothing', () {
      expect(looper.readValueTarget(const TrackVolumeTarget(9)), isNull);
      expect(
        looper.readValueTarget(
          const FxParamTarget(
            address: FxAddress(stage: FxStage.loop, index: 1, lane: 0),
            slotId: 'gone',
            param: 0,
          ),
        ),
        isNull,
      );
    });
  });
}
