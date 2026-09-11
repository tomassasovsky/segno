import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:routing_graph/routing_graph.dart';
import 'package:segno/audio_setup/cubit/inputs_cubit.dart';
import 'package:segno/audio_setup/cubit/monitor_cubit.dart';
import 'package:segno/audio_setup/cubit/outputs_cubit.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/cubit/tempo_cubit.dart';
import 'package:segno/looper/cubit/tracks_cubit.dart';
import 'package:segno/looper/model/fx_destination.dart';
import 'package:segno/looper/view/audio_routing/audio_routing_widgets.dart';
import 'package:segno/looper/view/fx/fx_page.dart';
import 'package:segno/theme/theme.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../../helpers/helpers.dart';

class _MockLooperBloc extends MockBloc<LooperEvent, LooperState>
    implements LooperBloc {}

class _MockLooperRepository extends Mock implements LooperRepository {}

BuiltInEffect _fx(
  String slot,
  TrackEffectType type, {
  bool enabled = true,
  FxPlacement placement = FxPlacement.post,
}) => BuiltInEffect(
  type: type,
  slotId: slot,
  enabled: enabled,
  placement: placement,
);

/// A four-in, four-out rig with two tracks recording, as the pen's examples
/// draw: track 0 takes inputs 1 and 2, track 1 takes input 3. Track 0 carries
/// a chain that straddles both stages, so the strip has a break to draw.
final _rig = LooperState(
  tracks: [
    Track(
      state: TrackState.playing,
      lanes: [
        Lane(
          inputChannel: 0,
          lengthFrames: 48000,
          effects: [_fx('l1', TrackEffectType.drive)],
        ),
        const Lane(inputChannel: 1, lengthFrames: 48000),
      ],
      effects: [
        _fx('t1', TrackEffectType.filter, placement: FxPlacement.pre),
        _fx(
          't2',
          TrackEffectType.drive,
          placement: FxPlacement.pre,
          enabled: false,
        ),
        _fx('t3', TrackEffectType.reverb),
      ],
    ),
    const Track(channel: 1, lanes: [Lane(inputChannel: 2, outputMask: 0xC)]),
  ],
  outputChains: {
    0: FxChainEnvelope(entries: [_fx('o1', TrackEffectType.reverb)]),
  },
  allTracksChain: FxChainEnvelope(
    entries: [
      _fx('a1', TrackEffectType.echo),
      _fx('a2', TrackEffectType.filter, enabled: false),
    ],
  ),
  status: const EngineStatus(
    isConnected: true,
    deviceName: 'Scarlett 18i20',
    inputChannels: 4,
    outputChannels: 4,
  ),
  inputPeaks: const [0.5, 0.12, 0, 0],
  outputPeaks: const [0.35, 0.28, 0, 0],
  outputBusCount: 2,
);

void main() {
  setUpAll(() {
    registerFallbackValue(const LooperInputPanChanged(0, pan: 0));
    registerFallbackValue(MonitorMode.off);
  });

  late _MockLooperBloc bloc;
  late _MockLooperRepository repository;
  late SettingsRepository settings;
  late StreamController<int> monitorChanges;
  late StreamController<int> monitorParams;
  late PluginCatalog catalog;

  setUp(() {
    catalog = PluginCatalog(
      engine: FakeAudioEngine(),
      appVersion: 'test',
      pollInterval: const Duration(milliseconds: 1),
      statFile: (path) => (mtimeMs: 1, sizeBytes: 1),
    );
    addTearDown(catalog.dispose);
    bloc = _MockLooperBloc();
    repository = _MockLooperRepository();
    settings = SettingsRepository(store: FakeKeyValueStore());
    monitorChanges = StreamController<int>.broadcast();
    monitorParams = StreamController<int>.broadcast();
    addTearDown(monitorChanges.close);
    addTearDown(monitorParams.close);
    when(
      () => repository.looperState,
    ).thenAnswer((_) => const Stream<LooperState>.empty());
    when(() => repository.state).thenReturn(_rig);
    when(() => repository.monitorEffects(any())).thenReturn([
      _fx('m1', TrackEffectType.delay, placement: FxPlacement.pre),
      _fx('m2', TrackEffectType.reverb),
    ]);
    when(() => repository.monitorChainEnabled(any())).thenReturn(true);
    when(
      () => repository.monitorChanges,
    ).thenAnswer((_) => monitorChanges.stream);
    when(
      () => repository.monitorParamChanges,
    ).thenAnswer((_) => monitorParams.stream);
    when(() => repository.pluginCatalog).thenReturn(catalog);
    when(() => repository.allMonitors()).thenReturn(const {});
    when(() => repository.monitorMode(any())).thenReturn(MonitorMode.off);
    when(() => repository.monitorOutput(any())).thenReturn(0x3);
    when(() => repository.monitorVolume(any())).thenReturn(1);
    when(() => repository.monitorMuted(any())).thenReturn(false);
    when(
      () => repository.setMonitorEffectEnabled(
        input: any(named: 'input'),
        index: any(named: 'index'),
        enabled: any(named: 'enabled'),
      ),
    ).thenReturn(EngineResult.ok);
  });

  Future<void> pump(
    WidgetTester tester, {
    required FxDestination destination,
    LooperState? state,
  }) async {
    tester.view
      ..physicalSize = const Size(1920, 1080)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final rig = state ?? _rig;
    when(() => bloc.state).thenReturn(rig);
    whenListen(
      bloc,
      const Stream<LooperState>.empty(),
      initialState: rig,
    );
    final inputs = InputsCubit(repository: repository, settings: settings);
    final outputs = OutputsCubit(repository: repository, settings: settings);
    final monitors = MonitorCubit(repository: repository, settings: settings);
    await monitors.load();
    final tempo = TempoCubit(repository: repository, settings: settings);
    final tracks = TracksCubit(settings: settings);
    for (final cubit in <BlocBase<Object?>>[
      inputs,
      outputs,
      monitors,
      tempo,
      tracks,
    ]) {
      addTearDown(() => unawaited(cubit.close()));
    }
    await inputs.rename(0, 'Acoustic guitar');
    await inputs.rename(1, 'Lead vocal microphone');
    await inputs.rename(2, 'Keyboard left');
    await outputs.rename(0, 'Main output');
    await outputs.rename(1, 'Monitor output');
    await tracks.rename(0, 'drums');

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: ThemeData(
          fontFamily: SurfaceTheme.displayFont,
          extensions: [
            SurfaceTheme.dark,
            routingGraphThemeFromSurface(SurfaceTheme.dark),
          ],
        ),
        home: RepositoryProvider<LooperRepository>.value(
          value: repository,
          child: MultiBlocProvider(
            providers: [
              BlocProvider<LooperBloc>.value(value: bloc),
              BlocProvider.value(value: inputs),
              BlocProvider.value(value: outputs),
              BlocProvider.value(value: monitors),
              BlocProvider.value(value: tempo),
              BlocProvider.value(value: tracks),
            ],
            child: FxPage(initial: destination),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // The real seeding path for a monitor chain: the repository announces the
    // input changed and the cubit re-reads it, which is how a chain reaches
    // the console when it did not come from this cubit's own write.
    monitorChanges.add(0);
    await tester.pumpAndSettle();
  }

  AppLocalizations l10nOf(WidgetTester tester) =>
      AppLocalizations.of(tester.element(find.byType(FxView)));

  Future<void> tapKey(WidgetTester tester, String key) async {
    await tester.tap(find.byKey(Key(key)));
    await tester.pumpAndSettle();
  }

  group('the Sound type row', () {
    testWidgets('picks which strip is showing', (tester) async {
      await pump(tester, destination: const FxDestination.liveInput(0));

      expect(find.byKey(const Key('fx_input_strip')), findsOneWidget);
      expect(find.byKey(const Key('fx_track_strip')), findsNothing);

      await tapKey(tester, 'fx_kind_recordedTrack');

      expect(find.byKey(const Key('fx_track_strip')), findsOneWidget);
      expect(find.byKey(const Key('fx_input_strip')), findsNothing);

      await tapKey(tester, 'fx_kind_output');

      expect(find.byKey(const Key('fx_output_strip')), findsOneWidget);
    });

    testWidgets('each strip keeps its own place across a switch', (
      tester,
    ) async {
      await pump(tester, destination: const FxDestination.liveInput(0));

      await tapKey(tester, 'fx_input_card_2');
      await tapKey(tester, 'fx_kind_output');
      await tapKey(tester, 'fx_kind_liveInput');

      // Not back to the first input: a context switch restores the strip,
      // it does not reset it.
      expect(
        tester
            .widget<RoutingSourceCard>(find.byKey(const Key('fx_input_card_2')))
            .selected,
        isTrue,
      );
    });
  });

  group('the Recorded tracks strip', () {
    testWidgets('lists the tracks and puts All tracks beside the last one', (
      tester,
    ) async {
      await pump(tester, destination: const FxDestination.recordedTrack(0));

      expect(find.byKey(const Key('fx_track_card_0')), findsOneWidget);
      expect(find.byKey(const Key('fx_track_card_1')), findsOneWidget);
      expect(find.byKey(const Key('fx_all_tracks')), findsOneWidget);
      // In the SAME strip, not a fourth Sound type of its own.
      expect(find.byKey(const Key('fx_track_strip')), findsOneWidget);
    });

    testWidgets('All tracks has no part picker and no placement tag — its '
        'stage is fixed after the recorded mix', (tester) async {
      await pump(tester, destination: const FxDestination.allTracks());

      expect(find.byKey(const Key('fx_part_picker')), findsNothing);
      expect(find.text(l10nOf(tester).fxPlacementPre), findsNothing);
      expect(find.text(l10nOf(tester).fxPlacementPost), findsNothing);
      // And it is the All tracks chain that is showing, not a track's.
      expect(find.text(l10nOf(tester).effectEcho), findsOneWidget);
    });

    testWidgets('switching tracks returns the part picker to Whole track', (
      tester,
    ) async {
      await pump(tester, destination: const FxDestination.recordedTrack(0));
      await tapKey(tester, 'fx_part_picker');
      await tester.tap(find.text('Acoustic guitar').last);
      await tester.pumpAndSettle();
      expect(find.text(l10nOf(tester).fxWholeTrack), findsNothing);

      await tapKey(tester, 'fx_track_card_1');

      // A part index names a lane of the track it was chosen on, so carrying
      // it across would open a stranger's part.
      expect(find.text(l10nOf(tester).fxWholeTrack), findsOneWidget);
    });
  });

  group('the chain', () {
    testWidgets('draws a cable between consecutive effects and a break where '
        'the Pre run ends', (tester) async {
      await pump(tester, destination: const FxDestination.recordedTrack(0));

      // Three entries: Pre, Pre, Post. One cable between the two Pre cards,
      // and NO cable across the stage break — the loop player is in there.
      expect(find.byKey(const Key('fx_cable_1')), findsOneWidget);
      expect(find.byKey(const Key('fx_cable_2')), findsNothing);
    });

    testWidgets('an output chain carries no placement tag, and a track chain '
        'does', (tester) async {
      await pump(tester, destination: const FxDestination.output(0));
      expect(find.text(l10nOf(tester).fxPlacementPost), findsNothing);

      await tapKey(tester, 'fx_kind_recordedTrack');
      expect(find.text(l10nOf(tester).fxPlacementPost), findsOneWidget);
      expect(find.text(l10nOf(tester).fxPlacementPre), findsNWidgets(2));
    });

    testWidgets('says so when the destination carries nothing', (tester) async {
      await pump(tester, destination: const FxDestination.recordedTrack(1));

      expect(find.byKey(const Key('fx_chain_empty')), findsOneWidget);
    });
  });

  group('power', () {
    testWidgets("writes to the stage's own owner, not one shared setter", (
      tester,
    ) async {
      await pump(tester, destination: const FxDestination.recordedTrack(0));
      await tapKey(tester, 'fx_power_t3');
      verify(
        () => bloc.add(
          const LooperTrackEffectEnabledToggled(0, 2, enabled: false),
        ),
      ).called(1);

      await tapKey(tester, 'fx_all_tracks');
      await tapKey(tester, 'fx_power_a1');
      verify(
        () => bloc.add(
          const LooperAllTracksEffectEnabledToggled(0, enabled: false),
        ),
      ).called(1);

      await tapKey(tester, 'fx_kind_output');
      await tapKey(tester, 'fx_power_o1');
      verify(
        () => bloc.add(
          const LooperOutputEffectEnabledToggled(0, 0, enabled: false),
        ),
      ).called(1);
    });

    testWidgets("a live input's chain is the monitor cubit's, both to read "
        'and to write', (tester) async {
      await pump(tester, destination: const FxDestination.liveInput(0));

      // Read: the two entries the monitor cubit carries, not the projection's.
      expect(find.text(l10nOf(tester).effectDelay), findsOneWidget);

      await tapKey(tester, 'fx_power_m1');

      // Write: through the repository the cubit owns, with no bloc event for
      // a stage the bloc does not own.
      verify(
        () => repository.setMonitorEffectEnabled(
          input: 0,
          index: 0,
          enabled: false,
        ),
      ).called(1);
    });
  });
}
