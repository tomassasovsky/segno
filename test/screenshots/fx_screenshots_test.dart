@Tags(['screenshots'])
library;

import 'dart:async';
import 'dart:io';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fx_catalogue/fx_catalogue.dart';
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
import 'package:segno/looper/view/fx/fx_library_page.dart';
import 'package:segno/looper/view/fx/fx_page.dart';
import 'package:segno/theme/theme.dart';
import 'package:settings_repository/settings_repository.dart';

import '../helpers/helpers.dart';

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

/// A stand-in catalogue: the wide family, two ordinary ones, real slugs.
const _library = FxCatalogue(
  families: [
    FxFamily(name: "Ed's Rack", slug: 'edsguitar', presets: []),
    FxFamily(name: 'Guitar Rack', slug: 'guitar', presets: []),
    FxFamily(name: 'Vocal Rack', slug: 'vocal', presets: []),
  ],
);

void main() {
  const fontDir =
      '/Users/Tomas/development/flutter/bin/cache/artifacts/material_fonts';
  // Author-machine goldens, like the other screenshot suites here.
  final hasScreenshotFonts = File('$fontDir/Roboto-Regular.ttf').existsSync();

  setUpAll(() async {
    registerFallbackValue(const LooperInputPanChanged(0, pan: 0));
    registerFallbackValue(MonitorMode.off);
    if (!hasScreenshotFonts) return;
    await loadScreenshotFont('Roboto', [
      '$fontDir/Roboto-Regular.ttf',
      '$fontDir/Roboto-Medium.ttf',
      '$fontDir/Roboto-Bold.ttf',
    ]);
    await loadScreenshotFont('Inter', [
      'assets/fonts/Inter-Regular.ttf',
      'assets/fonts/Inter-Medium.ttf',
      'assets/fonts/Inter-SemiBold.ttf',
      'assets/fonts/Inter-Bold.ttf',
    ]);
    await loadScreenshotFont('JetBrains Mono', [
      'assets/fonts/JetBrainsMono-Regular.ttf',
      'assets/fonts/JetBrainsMono-Medium.ttf',
      'assets/fonts/JetBrainsMono-SemiBold.ttf',
    ]);
    await loadScreenshotFont('packages/lucide_icons_flutter/Lucide', [
      packageAssetPath('lucide_icons_flutter', 'assets/lucide.ttf'),
    ]);
  });

  late _MockLooperBloc bloc;
  late _MockLooperRepository repository;
  late SettingsRepository settings;
  late StreamController<int> monitorChanges;
  late StreamController<int> monitorParams;

  setUp(() {
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
    when(() => repository.allMonitors()).thenReturn(const {});
  });

  Future<void> pump(
    WidgetTester tester, {
    required FxDestination destination,
    LooperState? state,
    FxCatalogue catalogue = FxCatalogue.empty,
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
            child: FxPage(initial: destination, catalogue: catalogue),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> shoot(WidgetTester tester, String name) async {
    await expectLater(
      find.byType(FxPage),
      matchesGoldenFile('goldens/fx_$name.png'),
    );
  }

  testWidgets('Live inputs', (tester) async {
    await pump(tester, destination: const FxDestination.liveInput(0));
    await shoot(tester, 'live_inputs');
  }, skip: !hasScreenshotFonts);

  testWidgets('Recorded track, whole track', (tester) async {
    await pump(tester, destination: const FxDestination.recordedTrack(0));
    await shoot(tester, 'recorded_track');
  }, skip: !hasScreenshotFonts);

  testWidgets('All tracks', (tester) async {
    await pump(tester, destination: const FxDestination.allTracks());
    await shoot(tester, 'all_tracks');
  }, skip: !hasScreenshotFonts);

  testWidgets('Outputs', (tester) async {
    await pump(tester, destination: const FxDestination.output(0));
    await shoot(tester, 'outputs');
  }, skip: !hasScreenshotFonts);

  testWidgets('Add effects, the library grid', (tester) async {
    // A stand-in catalogue of the real shape rather than the bundled one: a
    // widget test has no app asset bundle, so `rootBundle` resolves nothing
    // here and the artwork cannot be part of this golden. What it does show
    // is the grid — the wide banner's place, the card sizes and the order.
    await pump(
      tester,
      destination: const FxDestination.liveInput(0),
      catalogue: _library,
    );
    await tester.tap(find.byKey(const Key('fx_add_effects')));
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(FxLibraryPage),
      matchesGoldenFile('goldens/fx_library.png'),
    );
  }, skip: !hasScreenshotFonts);
}
