@Tags(['screenshots'])
library;

import 'dart:io';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:midi_device_repository/midi_device_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:performance_repository/performance_repository.dart';
import 'package:routing_graph/routing_graph.dart';
import 'package:segno/audio_setup/audio_setup.dart';
import 'package:segno/control/control.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/looper.dart';
import 'package:segno/pedal/pedal.dart';
import 'package:segno/theme/theme.dart';
import 'package:segno/update/cubit/update_cubit.dart';
import 'package:segno/visualizer/visualizer.dart';
import 'package:settings_repository/settings_repository.dart';
import 'package:update_repository/update_repository.dart';

import '../helpers/helpers.dart';

/// The deterministic golden theme: a bare dark [ThemeData] (fixed font, no
/// seeded colours) carrying the same surface + routing-graph extensions the
/// real app registers (via the shared [routingGraphThemeFromSurface] mapper),
/// so widgets resolving `context.surface` / `context.routingGraph` render
/// correctly under golden capture.
ThemeData _goldenTheme() => ThemeData(
  fontFamily: 'Roboto',
  brightness: Brightness.dark,
  extensions: [
    SurfaceTheme.dark,
    routingGraphThemeFromSurface(SurfaceTheme.dark),
  ],
);

class _MockLooperRepository extends Mock implements LooperRepository {}

class _MockAudioSetupCubit extends MockCubit<AudioSetupState>
    implements AudioSetupCubit {}

class _MockMidiDeviceRepository extends Mock implements MidiDeviceRepository {}

class _MockPedalCubit extends MockCubit<PedalState> implements PedalCubit {}

Future<void> _loadFont(String family, List<String> paths) async {
  final loader = FontLoader(family);
  for (final p in paths) {
    loader.addFont(
      File(p).readAsBytes().then((b) => ByteData.view(b.buffer)),
    );
  }
  await loader.load();
}

void main() {
  const fontDir =
      '/Users/Tomas/development/flutter/bin/cache/artifacts/material_fonts';
  // These golden generators load the local Flutter SDK's Material fonts and
  // compare against macOS-rendered goldens, so they only run where those fonts
  // exist — the author's machine. Everywhere else (CI, other contributors) they
  // skip: cross-platform golden rendering would not match the committed goldens
  // anyway. Run them with `flutter test --tags screenshots` on that setup.
  final hasScreenshotFonts = File('$fontDir/Roboto-Regular.ttf').existsSync();

  setUpAll(() async {
    if (!hasScreenshotFonts) return;
    await _loadFont('Roboto', [
      '$fontDir/Roboto-Regular.ttf',
      '$fontDir/Roboto-Medium.ttf',
      '$fontDir/Roboto-Bold.ttf',
    ]);
    // The Signal surface's bundled typefaces, so its mono readouts and grotesk
    // headings render as text (not Ahem boxes) under golden capture.
    await _loadFont('Inter', [
      'assets/fonts/Inter-Regular.ttf',
      'assets/fonts/Inter-Medium.ttf',
      'assets/fonts/Inter-SemiBold.ttf',
      'assets/fonts/Inter-Bold.ttf',
    ]);
    await _loadFont('JetBrains Mono', [
      'assets/fonts/JetBrainsMono-Regular.ttf',
      'assets/fonts/JetBrainsMono-Medium.ttf',
      'assets/fonts/JetBrainsMono-SemiBold.ttf',
    ]);
  });

  late SettingsRepository settings;
  late LooperRepository repository;
  late AudioSetupCubit audioSetup;
  late MidiDeviceRepository midi;
  late PedalCubit pedal;
  late ControlCubit control;
  late _ScreenshotLooperBloc looperBloc;

  const runningAudio = AudioSetupState(
    status: AudioSetupStatus.running,
    devices: [
      AudioDevice(
        id: 'out-1',
        name: 'Scarlett 4i4',
        isDefault: true,
        isInput: false,
      ),
      AudioDevice(
        id: 'in-1',
        name: 'Scarlett Input 1',
        isDefault: true,
        isInput: true,
      ),
    ],
    engineStatus: EngineStatus(
      deviceName: 'Scarlett 4i4',
      sampleRate: 48000,
      bufferFrames: 128,
      isConnected: true,
      inputChannels: 4,
      outputChannels: 4,
      latencyState: LatencyState.done,
      measuredLatencyMs: 9.5,
      recordOffsetFrames: 456,
    ),
  );

  setUp(() {
    settings = SettingsRepository(store: FakeKeyValueStore());
    repository = _MockLooperRepository();
    when(() => repository.state).thenReturn(
      const LooperState(
        tracks: [Track()],
        status: EngineStatus(inputChannels: 2, outputChannels: 2),
      ),
    );
    when(() => repository.monitorChanges).thenAnswer(
      (_) => const Stream<int>.empty(),
    );
    when(() => repository.monitorParamChanges).thenAnswer(
      (_) => const Stream<int>.empty(),
    );
    when(
      () => repository.looperState,
    ).thenAnswer((_) => const Stream<LooperState>.empty());
    // The Audio section's MIDI-learn block enumerates mappable targets from
    // the live rig; the goldens capture an empty one.
    when(() => repository.allMonitors()).thenAnswer((_) => const {});
    when(() => repository.allLaneChains()).thenAnswer((_) => const {});
    when(() => repository.allTrackChains()).thenAnswer((_) => const {});
    when(() => repository.masterEffects).thenAnswer((_) => const []);
    when(
      () => repository.masterChainEnvelope(),
    ).thenReturn(const FxChainEnvelope());
    audioSetup = _MockAudioSetupCubit();
    when(() => audioSetup.state).thenReturn(runningAudio);
    midi = _MockMidiDeviceRepository();
    when(() => midi.connection).thenReturn(const MidiConnection());
    when(
      () => midi.connections,
    ).thenAnswer((_) => const Stream<MidiConnection>.empty());
    when(() => midi.activity).thenAnswer((_) => const Stream<void>.empty());
    pedal = _MockPedalCubit();
    when(() => pedal.state).thenReturn(const PedalState());
    whenListen(
      pedal,
      const Stream<PedalState>.empty(),
      initialState: const PedalState(),
    );
    // The real control cubit: the View section reads the looper-wide default
    // mode from it. Its `const ControlState()` default (InteractionMode.record)
    // is what the golden captures, so no stubbing is needed — only the
    // keep-alive timer has to go, or it would pump frames under golden capture.
    final performance = PerformanceRepository(
      engine: FakeAudioEngine(),
      exportsRoot: () async => '.',
    );
    addTearDown(performance.dispose);
    // Disposed here rather than by PedalCubit (its lifecycle owner in the real
    // app, and in settings_page_test): the cubit above is a mock, so its close
    // is a no-op and would leave the transport and event streams open.
    final pedalRepo = PedalRepository(const NoopPedalTransport());
    addTearDown(pedalRepo.dispose);
    control = ControlCubit(
      looper: repository,
      pedal: pedalRepo,
      settings: settings,
      performance: performance,
      keepAliveInterval: Duration.zero,
    );
    addTearDown(control.close);
    // Backs the Tempo section (reads live values from LooperBloc's
    // TransportState, not a cached cubit copy — see
    // TempoSettingsSection's class doc): a representative grid-on state so
    // its golden shows real values rather than the tempo-free defaults.
    looperBloc = _ScreenshotLooperBloc();
    whenListen(
      looperBloc,
      const Stream<LooperState>.empty(),
      initialState: const LooperState(
        transport: TransportState(
          tempoBpm: 120,
          tempoSource: TempoSource.manual,
          currentBeat: 1,
          quantizeDiv: GridDivision.quarter,
          clickMode: ClickMode.rec,
          clickMask: 0x3,
          clickVolume: 0.8,
          countInBars: 1,
        ),
        status: EngineStatus(outputChannels: 4),
      ),
    );
  });

  Future<void> pump(WidgetTester tester) async {
    tester.view
      ..physicalSize = const Size(1980, 1480)
      ..devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: _goldenTheme(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: MultiRepositoryProvider(
          providers: [
            RepositoryProvider<LooperRepository>.value(value: repository),
            RepositoryProvider<SettingsRepository>.value(value: settings),
          ],
          child: MultiBlocProvider(
            providers: [
              BlocProvider<TracksCubit>.value(
                value: TracksCubit(settings: settings),
              ),
              BlocProvider<WaveformWindowCubit>.value(
                value: WaveformWindowCubit(settings: settings),
              ),
              BlocProvider<HighContrastCubit>.value(
                value: HighContrastCubit(settings: settings),
              ),
              BlocProvider<MidiSetupCubit>.value(
                value: MidiSetupCubit(repository: midi),
              ),
              BlocProvider<AudioSetupCubit>.value(value: audioSetup),
              BlocProvider<RefreshRateCubit>.value(
                value: RefreshRateCubit(
                  repository: repository,
                  settings: settings,
                ),
              ),
              BlocProvider<QuantizeCubit>.value(
                value: QuantizeCubit(
                  repository: repository,
                  settings: settings,
                ),
              ),
              BlocProvider<MonitorCubit>.value(
                value: MonitorCubit(
                  repository: repository,
                  settings: settings,
                ),
              ),
              BlocProvider<RecordOptionsCubit>.value(
                value: RecordOptionsCubit(
                  repository: repository,
                  settings: settings,
                ),
              ),
              BlocProvider<PedalCubit>.value(value: pedal),
              BlocProvider<ControlCubit>.value(value: control),
              BlocProvider<LooperBloc>.value(value: looperBloc),
              BlocProvider<TempoCubit>.value(
                value: TempoCubit(repository: repository, settings: settings),
              ),
              BlocProvider<UpdateCubit>.value(
                value: UpdateCubit(
                  updates: const UpdateRepository(
                    backend: UnsupportedPlatformBackend(),
                  ),
                  settings: settings,
                ),
              ),
            ],
            child: const SettingsPage(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('View section — tracks defaults', (tester) async {
    await pump(tester);
    // Reveal the PERFORMANCE group (default mode + refresh rate).
    await tester.scrollUntilVisible(
      find.byKey(const Key('settings_refreshRate_120')),
      200,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(SettingsPage),
      matchesGoldenFile('goldens/settings_view_tracks.png'),
    );
  }, skip: !hasScreenshotFonts);

  testWidgets('Audio section — recording', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const Key('settings_tab_audio')));
    await tester.pumpAndSettle();
    // Reveal the RECORDING controls (quantize, rec/dub, sound-activated, and
    // the global default loop length).
    await tester.scrollUntilVisible(
      find.byKey(const Key('audioSettings_defaultMultiple_0')),
      120,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(SettingsPage),
      matchesGoldenFile('goldens/settings_audio_recording.png'),
    );
  }, skip: !hasScreenshotFonts);

  testWidgets('Tempo section — grid, click, and count-in', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const Key('settings_tab_tempo')));
    await tester.pumpAndSettle();
    // Reveal the CLICK + COUNT-IN groups below the fold.
    await tester.scrollUntilVisible(
      find.byKey(const Key('tempoSettings_countIn_0')),
      200,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(SettingsPage),
      matchesGoldenFile('goldens/settings_tempo.png'),
    );
  }, skip: !hasScreenshotFonts);

  testWidgets('Mode section — the five-mode picker (B5c)', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const Key('settings_tab_mode')));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(SettingsPage),
      matchesGoldenFile('goldens/settings_mode.png'),
    );
  }, skip: !hasScreenshotFonts);
}

class _ScreenshotLooperBloc extends MockBloc<LooperEvent, LooperState>
    implements LooperBloc {}
