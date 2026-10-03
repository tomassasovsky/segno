import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:segno/control/binding/binding_labels.dart';
import 'package:segno/control/binding/control_value_target.dart';
import 'package:segno/control/binding/fx_binding_target.dart';
import 'package:segno/l10n/l10n.dart';

class _MockLooperRepository extends Mock implements LooperRepository {}

BuiltInEffect _drive(String slotId) =>
    BuiltInEffect(type: TrackEffectType.drive, slotId: slotId);

void main() {
  /// A rig whose tracks are NAMED — the point of #526. Track 3 has no name of
  /// its own, so it still falls back to the ordinal, which is how a partly
  /// named rig reads.
  const names = ['drums', 'bass', 'rhythm', 'TRACK 4'];

  late AppLocalizations l10n;
  late _MockLooperRepository looper;
  late Map<int, List<TrackEffect>> trackChains;
  late Map<(int, int), List<TrackEffect>> laneChains;

  setUpAll(() async {
    l10n = await AppLocalizations.delegate.load(const Locale('en'));
  });

  setUp(() {
    looper = _MockLooperRepository();
    trackChains = {
      3: [
        _drive('t-1'),
        const PluginEffect(
          ref: PluginRef(format: PluginFormat.vst3, id: 'p'),
          slotId: 'plug-1',
        ),
      ],
    };
    laneChains = {
      (1, 0): [_drive('l-1')],
    };
    when(looper.allMonitors).thenReturn(const {});
    when(looper.allLaneChains).thenAnswer(
      (_) => {for (final key in laneChains.keys) key: const FxChainEnvelope()},
    );
    when(looper.allTrackChains).thenAnswer(
      (_) => {
        for (final channel in trackChains.keys)
          channel: const FxChainEnvelope(),
      },
    );
    when(() => looper.monitorEffects(any())).thenReturn(const []);
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
    when(() => looper.outputEffects(0)).thenReturn(const []);
    when(() => looper.allTracksEffects).thenReturn(const []);
    when(() => looper.outputChainEnabled(any())).thenReturn(true);
    when(() => looper.allTracksChainEnabled).thenReturn(true);
    when(() => looper.state).thenReturn(const LooperState(outputBusCount: 1));
  });

  group('fxStageLabel', () {
    test('names every stage', () {
      expect(
        fxStageLabel(
          l10n,
          names,
          const FxAddress(stage: FxStage.input, index: 2),
        ),
        l10n.pedalAssignStageInput(3),
      );
      expect(
        fxStageLabel(
          l10n,
          names,
          const FxAddress(stage: FxStage.loop, index: 1, lane: 0),
        ),
        'bass lane 1',
      );
      expect(
        fxStageLabel(
          l10n,
          names,
          const FxAddress(stage: FxStage.track, index: 3),
        ),
        l10n.pedalAssignStageTrack('TRACK 4'),
      );
      expect(
        fxStageLabel(l10n, names, const FxAddress(stage: FxStage.output)),
        l10n.pedalAssignStageOutput(1),
      );
    });
  });

  group('bindingTargetLabel', () {
    test('names a chain by its stage and a slot by its stable id', () {
      const address = FxAddress(stage: FxStage.track, index: 3);

      expect(
        bindingTargetLabel(l10n, names, const FxChainTarget(address)),
        l10n.pedalAssignChainTarget(l10n.pedalAssignStageTrack('TRACK 4')),
      );
      expect(
        bindingTargetLabel(
          l10n,
          names,
          const FxSlotTarget(address: address, slotId: 't-1'),
        ),
        contains('t-1'),
      );
    });
  });

  group('valueTargetLabel', () {
    test('names the rig-level controls', () {
      expect(
        valueTargetLabel(l10n, names, looper, const TrackVolumeTarget(2)),
        l10n.midiLearnTargetVolume('rhythm'),
      );
      expect(
        valueTargetLabel(l10n, names, looper, const MasterGainTarget()),
        l10n.midiLearnTargetMaster,
      );
      expect(
        valueTargetLabel(l10n, names, looper, const ClickVolumeTarget()),
        l10n.clickVolumeLabel,
      );
      expect(
        valueTargetLabel(l10n, names, looper, const ClickModeValueTarget()),
        '${l10n.expressionDestinationLoopDefaults} · '
        '${l10n.loopTempoHearClick}',
      );
      expect(
        valueTargetLabel(l10n, names, looper, const DefaultOneShotTarget()),
        '${l10n.expressionDestinationLoopDefaults} · ${l10n.loopPlaybackLabel}',
      );
      expect(
        valueTargetLabel(l10n, names, looper, const TrackOneShotTarget(1)),
        '${l10n.trackName(names, 1)} · ${l10n.loopPlaybackLabel}',
      );
      expect(
        valueTargetLabel(
          l10n,
          names,
          looper,
          const DefaultRecordTimingTarget(),
        ),
        '${l10n.expressionDestinationLoopDefaults} · ${l10n.loopTimingLabel}',
      );
      expect(
        valueTargetLabel(
          l10n,
          names,
          looper,
          const TrackRecordTimingTarget(1),
        ),
        '${l10n.trackName(names, 1)} · ${l10n.loopTimingLabel}',
      );
    });

    test('names every Mixer coordinate without using a mutable alias', () {
      const targets = <MixValueTarget>[
        TrackVolumeTarget(1),
        LaneVolumeTarget(1, 0),
        MonitorVolumeTarget(2),
        TrackPanTarget(1),
        InputPanTarget(2),
        PairBalanceTarget(2),
        OutputLevelTarget(0),
        OutputBalanceTarget(0),
      ];
      final labels = [
        for (final target in targets)
          valueTargetLabel(l10n, names, looper, target),
      ];

      expect(labels, everyElement(isNotEmpty));
      expect(labels.toSet(), hasLength(targets.length));
      expect(labels[1], 'bass lane 1 · Volume');
      expect(labels[2], 'Input 3 · Volume');
      expect(labels[5], contains('4'));
      expect(labels[6], contains('1'));
    });

    test(
      "names a live FX param with the effect type's own parameter name",
      () {
        const target = FxParamTarget(
          address: FxAddress(stage: FxStage.track, index: 3),
          slotId: 't-1',
          param: 1,
        );

        expect(
          valueTargetLabel(l10n, names, looper, target),
          l10n.midiLearnTargetParam(
            l10n.pedalAssignStageTrack('TRACK 4'),
            't-1',
            TrackEffectType.drive.params[1].label,
          ),
        );
      },
    );

    test('falls back to the bare index when the slot is gone', () {
      // A stale row still has to say what it used to drive, so the label never
      // vanishes with the slot.
      const target = FxParamTarget(
        address: FxAddress(stage: FxStage.track, index: 3),
        slotId: 'gone',
        param: 2,
      );

      expect(valueTargetLabel(l10n, names, looper, target), contains('#2'));
    });

    test('falls back for a plugin slot and an out-of-range param', () {
      const plugin = FxParamTarget(
        address: FxAddress(stage: FxStage.track, index: 3),
        slotId: 'plug-1',
        param: 0,
      );
      const past = FxParamTarget(
        address: FxAddress(stage: FxStage.track, index: 3),
        slotId: 't-1',
        param: 99,
      );

      expect(valueTargetLabel(l10n, names, looper, plugin), contains('#0'));
      expect(valueTargetLabel(l10n, names, looper, past), contains('#99'));
    });

    test(
      'a lane-less Loop address names no parameter, like the resolver',
      () {
        // The resolvers refuse to coerce it onto lane 0 (A9); a label naming
        // lane 0's effect would describe a chain nothing ever writes to.
        const laneless = FxParamTarget(
          address: FxAddress(stage: FxStage.loop, index: 1),
          slotId: 'l-1',
          param: 0,
        );

        expect(valueTargetLabel(l10n, names, looper, laneless), contains('#0'));
      },
    );
  });
}
