import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fx_catalogue/fx_catalogue.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:segno/control/binding/control_value_resolver.dart';
import 'package:segno/control/binding/control_value_target.dart';
import 'package:segno/control/binding/expression_catalogue.dart';
import 'package:segno/control/binding/fx_binding_target.dart';
import 'package:segno/control/binding/owned_value_control.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/model/click_mode.dart';
import 'package:segno/looper/model/one_shot.dart';
import 'package:segno/looper/model/overdub_decay.dart';
import 'package:segno/looper/model/record_start.dart';
import 'package:segno/looper/model/record_timing.dart';
import 'package:settings_repository/settings_repository.dart';

class _MockLooperRepository extends Mock implements LooperRepository {}

BuiltInEffect _drive(String slotId) =>
    BuiltInEffect(type: TrackEffectType.drive, slotId: slotId);

void main() {
  const names = ['drums', 'bass'];

  late AppLocalizations l10n;
  late _MockLooperRepository looper;
  late Map<int, List<TrackEffect>> monitorChains;
  late Map<(int, int), List<TrackEffect>> laneChains;
  late Map<int, List<TrackEffect>> trackChains;
  late EngineStatus status;
  late InputSetup inputs;

  setUpAll(() async {
    l10n = await AppLocalizations.delegate.load(const Locale('en'));
  });

  setUp(() {
    looper = _MockLooperRepository();
    monitorChains = {};
    laneChains = {};
    trackChains = {};
    status = const EngineStatus();
    inputs = const InputSetup.empty();
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
    when(() => looper.outputEffects(any())).thenAnswer((_) => const []);
    when(() => looper.allTracksEffects).thenReturn(const []);
    when(() => looper.state).thenAnswer(
      (_) => LooperState(
        tracks: const [Track(), Track(channel: 1)],
        status: status,
        outputBusCount: 1,
      ),
    );
    when(() => looper.inputSetup).thenAnswer((_) => inputs);
    when(() => looper.laneCount(any())).thenReturn(1);
  });

  List<ExpressionDestination> build() =>
      expressionDestinations(l10n, names, looper);

  group('naming a target', () {
    test('a track fader is named by the track, not by a chain', () {
      final name = expressionTargetName(
        l10n,
        names,
        looper,
        const TrackVolumeTarget(1),
      );
      expect(name.destination, 'bass');
      expect(name.control, 'Volume');
      expect(
        expressionRowName(l10n, names, looper, const TrackVolumeTarget(1)),
        'Volume',
        reason: 'a row under "bass" does not repeat the track',
      );
    });

    test('an effect parameter is named by its effect', () {
      trackChains = {
        0: [_drive('t-1')],
      };
      const target = FxParamTarget(
        address: FxAddress(stage: FxStage.track),
        slotId: 't-1',
        param: 0,
      );
      final name = expressionTargetName(l10n, names, looper, target);
      expect(name.destination, 'drums');
      expect(name.group, TrackEffectType.drive.label);
      expect(name.control, isNotEmpty);
      expect(
        expressionRowName(l10n, names, looper, target),
        '${name.group} · ${name.control}',
      );
    });

    test('an effect that is gone still says what the mapping holds', () {
      // The row exists so a performer can repair it. A row that went blank
      // would name nothing they could act on.
      const target = FxParamTarget(
        address: FxAddress(stage: FxStage.track),
        slotId: 'vanished',
        param: 3,
      );
      final name = expressionTargetName(l10n, names, looper, target);
      expect(name.destination, 'drums');
      expect(name.group, 'vanished');
      expect(name.control, '#3');
    });
  });

  group('row pictures', () {
    const rack = FxRack(id: 'rack-1', name: 'Clean Rhythm', art: 'guitar');
    const address = FxAddress(stage: FxStage.track);

    BuiltInEffect pedal(String slotId, String? module, {FxRack? on = rack}) =>
        BuiltInEffect(
          type: TrackEffectType.drive,
          slotId: slotId,
          rack: on,
          module: module,
        );

    test("an effect's parameter and the effect draw its pedal", () {
      trackChains = {
        0: [pedal('d-1', 'Overdrive')],
      };
      final stomp = fxModuleArt('Overdrive');
      expect(stomp, isNotNull);
      expect(
        expressionTargetArt(
          looper,
          const FxParamTarget(address: address, slotId: 'd-1', param: 0),
        ),
        stomp,
      );
      expect(
        expressionTargetArt(
          looper,
          const FxSlotTarget(address: address, slotId: 'd-1'),
        ),
        stomp,
      );
    });

    test('a chain that is one rack draws the rack', () {
      trackChains = {
        0: [pedal('d-1', 'Overdrive'), pedal('r-1', 'Reverb')],
      };
      expect(
        expressionTargetArt(looper, const FxChainTarget(address)),
        fxFootswitchAsset('guitar'),
      );
    });

    test('a chain that is not one rack draws nothing', () {
      // Two racks, or a rack beside a lone effect: no single picture names it.
      trackChains = {
        0: [
          pedal('d-1', 'Overdrive'),
          pedal(
            'r-1',
            'Reverb',
            on: const FxRack(id: 'rack-2', name: 'Other', art: 'dub'),
          ),
        ],
      };
      expect(expressionTargetArt(looper, const FxChainTarget(address)), isNull);
      trackChains = {
        0: [pedal('d-1', 'Overdrive'), pedal('r-1', 'Reverb', on: null)],
      };
      expect(expressionTargetArt(looper, const FxChainTarget(address)), isNull);
    });

    test('a fader, a module-less effect and a gone one draw nothing', () {
      trackChains = {
        0: [pedal('d-1', null)],
      };
      expect(expressionTargetArt(looper, const TrackVolumeTarget(0)), isNull);
      expect(
        expressionTargetArt(
          looper,
          const FxSlotTarget(address: address, slotId: 'd-1'),
        ),
        isNull,
      );
      expect(
        expressionTargetArt(
          looper,
          const FxSlotTarget(address: address, slotId: 'gone'),
        ),
        isNull,
      );
    });

    test('the catalogue carries each control its picture', () {
      trackChains = {
        0: [pedal('d-1', 'Overdrive')],
      };
      final track = expressionDestinations(
        l10n,
        names,
        looper,
        withActivations: true,
      ).firstWhere((d) => d.id == 'track:0');
      expect(track.activations.first.art, fxFootswitchAsset('guitar'));
      expect(
        track.controls.firstWhere((c) => c.target is FxParamTarget).art,
        fxModuleArt('Overdrive'),
      );
      expect(
        track.controls.firstWhere((c) => c.target is TrackVolumeTarget).art,
        isNull,
      );
    });
  });

  group('the catalogue', () {
    test('Click is a separate Outputs destination even with no output bus', () {
      when(() => looper.state).thenAnswer(
        (_) => const LooperState(),
      );
      final absent = expressionDestinations(l10n, names, looper);
      expect(absent.where((destination) => destination.id == 'click'), isEmpty);

      final present = expressionDestinations(
        l10n,
        names,
        looper,
        owned: const OwnedValueSnapshots(
          clickVolume: 0,
        ),
      );
      final click = present.singleWhere(
        (destination) => destination.id == 'click',
      );
      expect(click.kind, ExpressionDestinationKind.output);
      expect(click.label, 'Click');
      expect(click.controls.single.target, const ClickVolumeTarget());
      expect(click.controls.single.label, 'Volume');
      expect(present.map((destination) => destination.id), ['click', 'master']);
    });

    test('Hear click is one Loop control, retained but locked in capture', () {
      const ready = ClickModeSnapshot(
        mode: ClickMode.off,
        captureLocked: false,
      );
      const locked = ClickModeSnapshot(
        mode: ClickMode.recFirst,
        captureLocked: true,
      );
      expect(
        expressionDestinations(l10n, names, looper)
            .expand((place) => place.controls)
            .where((control) => control.target is ClickModeValueTarget),
        isEmpty,
      );
      final places = expressionDestinations(
        l10n,
        names,
        looper,
        owned: const OwnedValueSnapshots(
          clickModeSnapshot: ready,
        ),
      );
      final loop = places.singleWhere((place) => place.id == 'loop:defaults');
      expect(loop.kind, ExpressionDestinationKind.loopControls);
      expect(loop.controls.single.target, const ClickModeValueTarget());
      expect(loop.controls.single.disabledReason, isNull);
      expect(
        expressionRowName(l10n, names, looper, const ClickModeValueTarget()),
        l10n.loopTempoHearClick,
      );
      final lockedLoop = expressionDestinations(
        l10n,
        names,
        looper,
        owned: const OwnedValueSnapshots(
          clickModeSnapshot: locked,
        ),
      ).singleWhere((place) => place.id == 'loop:defaults');
      expect(lockedLoop.controls.single.target, const ClickModeValueTarget());
      expect(
        lockedLoop.controls.single.disabledReason,
        l10n.clickModeCaptureLocked,
      );
    });

    test('Count-in is one Loop control with a capture lock', () {
      final off = RecordStartSnapshot(
        settings: RecordStartSettings(countInBars: 0, soundStart: true),
        captureLocked: false,
      );
      final locked = RecordStartSnapshot(
        settings: RecordStartSettings(countInBars: 2, soundStart: false),
        captureLocked: true,
      );
      expect(
        expressionDestinations(l10n, names, looper)
            .expand((place) => place.controls)
            .where((control) => control.target is CountInValueTarget),
        isEmpty,
      );
      final ready = expressionDestinations(
        l10n,
        names,
        looper,
        owned: OwnedValueSnapshots(
          recordStartSnapshot: off,
        ),
      ).singleWhere((place) => place.id == 'loop:defaults');
      expect(ready.kind, ExpressionDestinationKind.loopControls);
      expect(ready.controls.single.target, const CountInValueTarget());
      expect(ready.controls.single.disabledReason, isNull);
      expect(
        expressionRowName(l10n, names, looper, const CountInValueTarget()),
        l10n.loopTempoCountIn,
      );
      final lockedRow = expressionDestinations(
        l10n,
        names,
        looper,
        owned: OwnedValueSnapshots(
          recordStartSnapshot: locked,
        ),
      ).singleWhere((place) => place.id == 'loop:defaults');
      expect(lockedRow.controls.single.target, const CountInValueTarget());
      expect(
        lockedRow.controls.single.disabledReason,
        l10n.recordStartCaptureLocked,
      );
    });

    test(
      'decay keeps all eight fixed tracks and a distinct Loop destination',
      () {
        final snapshot = DecaySnapshot(
          defaultPercent: 0,
          trackOverrides: const {0: 75},
        );
        final destinations = expressionDestinations(
          l10n,
          names,
          looper,
          owned: OwnedValueSnapshots(
            decaySnapshot: snapshot,
          ),
        );
        final loop = destinations.singleWhere((d) => d.id == 'loop:defaults');
        expect(loop.kind, ExpressionDestinationKind.loopControls);
        expect(loop.label, l10n.expressionDestinationLoopDefaults);
        expect(loop.controls.single.target, const DefaultDecayTarget());
        for (var channel = 0; channel < 8; channel++) {
          final track = destinations.singleWhere(
            (d) => d.id == 'track:$channel',
          );
          expect(track.kind, ExpressionDestinationKind.recordedTrack);
          expect(
            track.controls.any((c) => c.target == TrackDecayTarget(channel)),
            isTrue,
          );
        }
        expect(
          expressionKindLabel(l10n, ExpressionDestinationKind.loopControls),
          l10n.expressionKindLoopControls,
        );
        expect(
          expressionDestinations(
            l10n,
            names,
            looper,
          ).where((d) => d.id == 'loop:defaults'),
          isEmpty,
        );
      },
    );

    test('Fade duration sits in Loop defaults and on all eight tracks', () {
      final destinations = expressionDestinations(
        l10n,
        names,
        looper,
        owned: const OwnedValueSnapshots(
          fadeDurations: FadeDurations.defaults,
        ),
      );
      final loop = destinations.singleWhere((d) => d.id == 'loop:defaults');
      expect(loop.controls.single.target, const DefaultFadeTarget());
      expect(loop.controls.single.label, l10n.fadeDurationLabel);
      for (var channel = 0; channel < 8; channel++) {
        final track = destinations.singleWhere((d) => d.id == 'track:$channel');
        final row = track.controls.singleWhere(
          (c) => c.target == TrackFadeTarget(channel),
        );
        expect(row.label, l10n.fadeDurationLabel);
        expect(
          expressionRowName(l10n, names, looper, row.target),
          l10n.fadeDurationLabel,
        );
      }
      expect(
        expressionDestinations(
          l10n,
          names,
          looper,
        ).expand((d) => d.controls).map((c) => c.target),
        isNot(contains(isA<FadeValueTarget>())),
      );
    });

    test('Loop/Once shares one Playback group after decay', () {
      final destinations = expressionDestinations(
        l10n,
        names,
        looper,
        owned: OwnedValueSnapshots(
          decaySnapshot: DecaySnapshot(
            defaultPercent: 75,
            trackOverrides: const {},
          ),
          oneShotSnapshot: OneShotSnapshot(
            defaultOneShot: false,
            trackOverrides: const {0: true},
          ),
        ),
      );
      final defaults = destinations.singleWhere(
        (destination) => destination.id == 'loop:defaults',
      );
      expect(defaults.groups, hasLength(1));
      expect(defaults.groups.single.label, l10n.loopPlaybackLabel);
      expect(
        defaults.controls.map((row) => row.target),
        [const DefaultDecayTarget(), const DefaultOneShotTarget()],
      );
      for (var channel = 0; channel < 8; channel++) {
        final track = destinations.singleWhere(
          (destination) => destination.id == 'track:$channel',
        );
        expect(
          track.controls.whereType<ExpressionControl>().map((c) => c.target),
          contains(TrackOneShotTarget(channel)),
        );
      }
    });

    test('timing keeps nine fixed choices visible and locks only capture', () {
      final ready = RecordTimingSnapshot(
        defaultTiming: RecordTiming.bar,
        rememberedDivision: GridDivision.bar,
        trackOverrides: const {7: RecordTiming.immediately},
        captureLocked: false,
      );
      final choices = expressionDestinations(
        l10n,
        names,
        looper,
        owned: OwnedValueSnapshots(
          recordTimingSnapshot: ready,
        ),
      );
      final timing = choices
          .expand((place) => place.controls)
          .where((control) => control.target is RecordTimingValueTarget)
          .toList();
      expect(timing, hasLength(9));
      expect(timing.every((control) => control.disabledReason == null), isTrue);
      final defaults = choices.singleWhere(
        (place) => place.id == 'loop:defaults',
      );
      expect(defaults.groups.single.label, l10n.loopTimingLabel);
      expect(
        expressionRowName(
          l10n,
          names,
          looper,
          const DefaultRecordTimingTarget(),
        ),
        l10n.loopTimingLabel,
      );
      expect(
        defaults.controls.single.target,
        const DefaultRecordTimingTarget(),
      );
      expect(
        choices
            .singleWhere((place) => place.id == 'track:7')
            .controls
            .single
            .target,
        const TrackRecordTimingTarget(7),
      );

      final locked = expressionDestinations(
        l10n,
        names,
        looper,
        owned: OwnedValueSnapshots(
          recordTimingSnapshot: RecordTimingSnapshot(
            defaultTiming: RecordTiming.bar,
            rememberedDivision: GridDivision.bar,
            trackOverrides: const {},
            captureLocked: true,
          ),
        ),
      );
      final lockedTiming = locked
          .expand((place) => place.controls)
          .where((control) => control.target is RecordTimingValueTarget);
      expect(
        lockedTiming.every(
          (control) => control.disabledReason == l10n.recordTimingCaptureLocked,
        ),
        isTrue,
      );
    });

    test('the Mixer-only catalogue avoids FX enumeration and keeps order', () {
      status = const EngineStatus(inputChannels: 2, outputChannels: 2);
      inputs = InputSetup(pairs: const {0: 0});
      trackChains = {
        0: [_drive('t-1')],
      };

      final mix = looper.availableMixValueTargets();
      expect(mix, isNotEmpty);
      verify(() => looper.state).called(1);
      verifyNever(() => looper.allMonitors());
      verifyNever(() => looper.allLaneChains());
      verifyNever(() => looper.allTrackChains());
      expect(
        looper.availableValueTargets().whereType<MixValueTarget>().toList(),
        mix,
      );
    });

    test('offers track and lane controls, one output, and the master', () {
      final destinations = build();
      expect(
        destinations.map((d) => d.id),
        [
          'track:0',
          'loop:0:0',
          'track:1',
          'loop:1:0',
          'output:0',
          'master',
        ],
      );
      expect(
        destinations.last.kind,
        ExpressionDestinationKind.output,
        reason: 'the master output is an output, not a track',
      );
      expect(destinations.first.controls.map((control) => control.label), [
        'Volume',
        'Pan',
      ]);
    });

    test("a track's fader and its own effects are ONE destination", () {
      trackChains = {
        0: [_drive('t-1')],
      };
      final track = build().firstWhere((d) => d.id == 'track:0');
      expect(
        track.groups.map((g) => g.label),
        [TrackEffectType.drive.label, 'drums'],
        reason: 'the rig reports the chain first and the fader later',
      );
      expect(track.controls.length, TrackEffectType.drive.params.length + 2);
    });

    test('a lane sorts straight after the track it is part of', () {
      laneChains = {
        (1, 0): [_drive('l-1')],
      };
      expect(
        build().map((d) => d.id),
        [
          'track:0',
          'loop:0:0',
          'track:1',
          'loop:1:0',
          'output:0',
          'master',
        ],
        reason: 'the rig reports every lane before any fader',
      );
    });

    test('groups all eight Mixer controls at stable destinations', () {
      status = const EngineStatus(inputChannels: 3, outputChannels: 2);
      inputs = InputSetup(pairs: const {0: 0});

      final destinations = build();
      final controls = destinations.expand((place) => place.controls).toList();
      expect(
        controls.where((row) => row.target is TrackVolumeTarget),
        hasLength(2),
      );
      expect(
        controls.where((row) => row.target is LaneVolumeTarget),
        hasLength(2),
      );
      expect(
        controls.where((row) => row.target is MonitorVolumeTarget),
        hasLength(3),
      );
      expect(
        controls.where((row) => row.target is TrackPanTarget),
        hasLength(2),
      );
      expect(
        controls.where((row) => row.target is InputPanTarget),
        hasLength(1),
      );
      expect(
        controls.where((row) => row.target is PairBalanceTarget),
        hasLength(1),
      );
      expect(
        controls.where((row) => row.target is OutputLevelTarget),
        hasLength(1),
      );
      expect(
        controls.where((row) => row.target is OutputBalanceTarget),
        hasLength(1),
      );
      expect(destinations.first.id, 'input:0');
      expect(destinations.last.id, 'master');
    });

    test('a retained pair with an excluded right jack is not offered', () {
      // A saved pair can outlive the device that created it. The new device
      // may expose that right jack as loopback, so the mapping stays stored
      // but cannot become a live selectable control.
      status = const EngineStatus(inputChannels: 2, excludedInputMask: 2);
      inputs = InputSetup(pairs: const {0: 0});

      final offered = build().expand((destination) => destination.controls);
      expect(
        offered.where((control) => control.target is PairBalanceTarget),
        isEmpty,
      );
      expect(
        offered.where((control) => control.target is MonitorVolumeTarget),
        hasLength(1),
      );
    });

    test('inputs come first and the master last', () {
      monitorChains = {
        1: [_drive('m-1')],
      };
      final ids = build().map((d) => d.id).toList();
      expect(ids.first, 'input:1');
      expect(ids.last, 'master');
      expect(
        build().first.kind,
        ExpressionDestinationKind.liveInput,
      );
    });

    test('every kind has the same name the Effects page gives it', () {
      expect(
        expressionKindLabel(l10n, ExpressionDestinationKind.liveInput),
        l10n.fxKindLiveInputs,
      );
      expect(
        expressionKindLabel(l10n, ExpressionDestinationKind.recordedTrack),
        l10n.fxKindRecordedTracks,
      );
      expect(
        expressionKindLabel(l10n, ExpressionDestinationKind.output),
        l10n.fxKindOutputs,
      );
    });
  });
}
