import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:segno/control/binding/control_value_target.dart';
import 'package:segno/control/binding/expression_catalogue.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/model/fx_destination.dart';

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

  setUpAll(() async {
    l10n = await AppLocalizations.delegate.load(const Locale('en'));
  });

  setUp(() {
    looper = _MockLooperRepository();
    monitorChains = {};
    laneChains = {};
    trackChains = {};
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
      (_) => const LooperState(
        tracks: [Track(), Track(channel: 1)],
        outputBusCount: 1,
      ),
    );
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

  group('the catalogue', () {
    test('offers every track fader and the master, with nothing else', () {
      final destinations = build();
      expect(
        destinations.map((d) => d.id),
        ['track:0', 'track:1', 'master'],
      );
      expect(
        destinations.last.kind,
        FxDestinationKind.output,
        reason: 'the master output is an output, not a track',
      );
      expect(destinations.first.controls.single.label, 'Volume');
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
      expect(track.controls.length, TrackEffectType.drive.params.length + 1);
    });

    test('a lane sorts straight after the track it is part of', () {
      laneChains = {
        (1, 0): [_drive('l-1')],
      };
      expect(
        build().map((d) => d.id),
        ['track:0', 'track:1', 'loop:1:0', 'master'],
        reason: 'the rig reports every lane before any fader',
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
        FxDestinationKind.liveInput,
      );
    });

    test('every kind has the same name the Effects page gives it', () {
      expect(
        expressionKindLabel(l10n, FxDestinationKind.liveInput),
        l10n.fxKindLiveInputs,
      );
      expect(
        expressionKindLabel(l10n, FxDestinationKind.recordedTrack),
        l10n.fxKindRecordedTracks,
      );
      expect(
        expressionKindLabel(l10n, FxDestinationKind.output),
        l10n.fxKindOutputs,
      );
    });
  });
}
