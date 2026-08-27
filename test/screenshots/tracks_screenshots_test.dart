@Tags(['screenshots'])
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:performance_repository/performance_repository.dart';
import 'package:segno/audio_setup/audio_setup.dart';
import 'package:segno/common/console_mode.dart';
import 'package:segno/control/control.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/looper.dart';
import 'package:segno/performance/performance.dart';
import 'package:segno/session/session.dart';
import 'package:segno/theme/theme.dart';
import 'package:settings_repository/settings_repository.dart';

import '../helpers/helpers.dart';

class _MockLooperBloc extends MockBloc<LooperEvent, LooperState>
    implements LooperBloc {}

class _MockLooperRepository extends Mock implements LooperRepository {}

class _MockSessionCubit extends MockCubit<SessionState>
    implements SessionCubit {}

class _MockPerformanceRecorderCubit extends MockCubit<PerformanceRecorderState>
    implements PerformanceRecorderCubit {}

class _MockTransportClockCubit extends MockCubit<TransportClockState>
    implements TransportClockCubit {}

class _MockAudioSetupCubit extends MockCubit<AudioSetupState>
    implements AudioSetupCubit {}

Future<void> _loadFont(String family, List<String> paths) async {
  final loader = FontLoader(family);
  for (final p in paths) {
    loader.addFont(File(p).readAsBytes().then((b) => ByteData.view(b.buffer)));
  }
  await loader.load();
}

/// Manual generator for the console main-window decal (the artwork on the 16"
/// panel in the Fusion "Segno console (populated)" doc). Renders [TracksView]
/// exactly as the physical console shows it and captures a 1920x1080 golden.
///
/// It only produces the CONSOLE layout when compiled with the flag on, so it is
/// gated on [kConsoleMode]. Regenerate on the author's machine with:
///
///   flutter test --tags screenshots --dart-define=SEGNO_CONSOLE=true \
///     --update-goldens test/screenshots/tracks_screenshots_test.dart
void main() {
  const fontDir =
      '/Users/Tomas/development/flutter/bin/cache/artifacts/material_fonts';
  // Golden generators load the local SDK's Material fonts and compare against
  // macOS-rendered goldens, so they only run where those fonts exist (the
  // author's machine); everywhere else they skip. Additionally gated on
  // console mode: without --dart-define=SEGNO_CONSOLE=true the layout would
  // carry the desktop toolbar and not match the console decal.
  final hasScreenshotFonts = File('$fontDir/Roboto-Regular.ttf').existsSync();

  setUpAll(() async {
    if (!hasScreenshotFonts) return;
    const robotoTtfs = [
      '$fontDir/Roboto-Regular.ttf',
      '$fontDir/Roboto-Medium.ttf',
      '$fontDir/Roboto-Bold.ttf',
    ];
    await _loadFont('Roboto', robotoTtfs);
    // Material icon glyphs (e.g. the FX entry-run's arrow_right_alt) — the app
    // bundles this font at runtime; the golden harness must load it too, or
    // every `Icon` renders as .notdef tofu.
    await _loadFont('MaterialIcons', [
      '$fontDir/MaterialIcons-Regular.otf',
    ]);
    // TracksView wraps itself in LooperScreenTheme, which renders text in the
    // legend font (Helvetica / Arial / sans-serif — macOS/Linux system fonts,
    // absent under `flutter test`). Register the loaded Roboto glyphs under
    // those family names so the labels render instead of Ahem tofu.
    for (final family in ['Helvetica', 'Arial', 'sans-serif']) {
      await _loadFont(family, robotoTtfs);
    }
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

  late LooperBloc bloc;
  late TracksCubit tracks;
  late ControlCubit control;
  late LooperRepository repository;
  late SettingsRepository settings;
  late SessionCubit session;
  late PerformanceRepository performance;
  late PerformanceRecorderCubit performanceRecorder;
  late TransportClockCubit transportClock;
  late AudioSetupCubit audioSetup;

  setUp(() {
    settings = SettingsRepository(store: FakeKeyValueStore());
    bloc = _MockLooperBloc();
    // Nothing lost by default; the device-lost scene below re-stubs audio.
    audioSetup = _MockAudioSetupCubit();
    whenListen(
      audioSetup,
      const Stream<AudioSetupState>.empty(),
      initialState: const AudioSetupState(),
    );
    tracks = TracksCubit(settings: settings);
    repository = _MockLooperRepository();
    when(() => repository.readTrackWaveform(any())).thenReturn(Float32List(0));
    when(() => repository.state).thenReturn(const LooperState());
    // The tray's Signal face reads these through `MonitorCubit`. A bare mock
    // returns null for each and the cubit dies in its constructor.
    when(() => repository.monitorChanges).thenAnswer(
      (_) => const Stream<int>.empty(),
    );
    when(() => repository.monitorParamChanges).thenAnswer(
      (_) => const Stream<int>.empty(),
    );
    when(() => repository.allMonitors()).thenReturn(const {});
    when(() => repository.monitorEffects(any())).thenReturn(const []);
    when(
      () => repository.looperState,
    ).thenAnswer((_) => const Stream<LooperState>.empty());
    final pedalRepo = PedalRepository(const NoopPedalTransport());
    addTearDown(pedalRepo.dispose);
    performance = PerformanceRepository(
      engine: FakeAudioEngine(),
      exportsRoot: () async => '.',
    );
    control = ControlCubit(
      looper: repository,
      pedal: pedalRepo,
      settings: settings,
      performance: performance,
      keepAliveInterval: Duration.zero,
    );
    addTearDown(control.close);
    session = _MockSessionCubit();
    when(() => session.state).thenReturn(const SessionState());
    performanceRecorder = _MockPerformanceRecorderCubit();
    when(
      () => performanceRecorder.state,
    ).thenReturn(const PerformanceRecorderIdle());
    // The status bar's clock reads elapsed transport time (#678); the pen's
    // own 0:00:11 figure, so the decal matches the design literally.
    transportClock = _MockTransportClockCubit();
    whenListen(
      transportClock,
      const Stream<TransportClockState>.empty(),
      initialState: const TransportClockState(
        elapsed: Duration(seconds: 11),
        running: true,
      ),
    );
  });

  void seed(LooperState state) {
    when(() => bloc.state).thenReturn(state);
    when(() => repository.state).thenReturn(state);
    whenListen(bloc, const Stream<LooperState>.empty(), initialState: state);
  }

  Future<void> pump(WidgetTester tester) async {
    // 16:9 at the panel's native 1920x1080 so the captured decal matches the
    // 344x194 (16:9) active area 1:1.
    tester.view
      ..physicalSize = const Size(1920, 1080)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.neon,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: MultiRepositoryProvider(
          providers: [
            RepositoryProvider<LooperRepository>.value(value: repository),
            RepositoryProvider<PerformanceRepository>.value(value: performance),
            // TracksView builds a SettingsTrayCubit that requires a
            // SettingsRepository; share the fixture the cubits already use so
            // the tray reads the same store.
            RepositoryProvider<SettingsRepository>.value(value: settings),
          ],
          child: MultiBlocProvider(
            providers: [
              BlocProvider<LooperBloc>.value(value: bloc),
              BlocProvider<TracksCubit>.value(value: tracks),
              BlocProvider<ControlCubit>.value(value: control),
              BlocProvider<SessionCubit>.value(value: session),
              BlocProvider<PerformanceRecorderCubit>.value(
                value: performanceRecorder,
              ),
              BlocProvider<TransportClockCubit>.value(value: transportClock),
              // Console mode mounts the tray in the main window, and the tray
              // opens on Signal — whose input cards read both of these. Absent,
              // this whole test throws `ProviderNotFound` before it can draw,
              // which is how it rotted: it only runs under
              // `--dart-define=SEGNO_CONSOLE=true`, so nothing was running it.
              BlocProvider<InputsCubit>(
                create: (_) =>
                    InputsCubit(settings: settings, repository: repository),
              ),
              BlocProvider<MonitorCubit>(
                create: (_) =>
                    MonitorCubit(repository: repository, settings: settings),
              ),
              // The device-lost banner and the not-running gate read the
              // audio setup cubit (#453).
              BlocProvider<AudioSetupCubit>.value(value: audioSetup),
            ],
            child: const TracksView(),
          ),
        ),
      ),
    );
    // Advance implicit animations to a steady state without pumpAndSettle
    // (the record/level meters may run a repeating ticker that never settles).
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets(
    'console main window (16" panel decal)',
    (tester) async {
      // The real per-track names shown on the console.
      const names = ['GUITAR', 'BOOM', 'RC20', 'VOX'];
      for (var i = 0; i < names.length; i++) {
        await tracks.rename(i, names[i]);
      }
      seed(
        const LooperState(
          status: EngineStatus(
            isConnected: true,
            devicePresent: true,
            deviceName: 'Segno',
            sampleRate: 48000,
            inputChannels: 2,
            outputChannels: 2,
          ),
          tracks: [
            Track(
              state: TrackState.playing,
              rms: 0.72,
              peak: 0.9,
              lengthFrames: 96000,
            ),
            Track(
              channel: 1,
              state: TrackState.playing,
              rms: 0.5,
              peak: 0.68,
              lengthFrames: 96000,
            ),
            // RC20: loaded (has content) but muted.
            Track(
              channel: 2,
              state: TrackState.playing,
              muted: true,
              rms: 0.4,
              peak: 0.55,
              lengthFrames: 96000,
            ),
            Track(channel: 3),
          ],
        ),
      );
      await pump(tester);
      await expectLater(
        find.byType(TracksView),
        matchesGoldenFile('goldens/tracks_main_window.png'),
      );
    },
    skip: !hasScreenshotFonts || !kConsoleMode,
  );

  testWidgets(
    'console main window with the device-lost banner (STAGE / device-lost)',
    (tester) async {
      // The one standing loss condition: the pinned interface is gone, so the
      // red banner holds the stage above the track run. It STANDS IN for the
      // "engine stopped" bar (#453) — the two never stack — so a device-gone
      // engine shows this banner alone, not both. MIDI loss is a transient
      // toast, never a banner here.
      whenListen(
        audioSetup,
        const Stream<AudioSetupState>.empty(),
        initialState: const AudioSetupState(
          deviceConnectivity: DeviceConnectivity.lost,
          connectivityDeviceName: 'Scarlett 2i2',
        ),
      );
      seed(
        const LooperState(
          // The engine reports the device gone, so the generic "not running"
          // affordance is suppressed and only the device-lost banner shows.
          tracks: [
            Track(state: TrackState.playing, lengthFrames: 96000),
            Track(channel: 1),
            Track(channel: 2),
            Track(channel: 3),
          ],
        ),
      );
      await pump(tester);
      await expectLater(
        find.byType(TracksView),
        matchesGoldenFile('goldens/tracks_device_lost.png'),
      );
    },
    skip: !hasScreenshotFonts || !kConsoleMode,
  );

  // #692 (owner pivot 2026-08-27): FX mode is an OVERLAY, not the in-place
  // tile transform. The four columns render EXACTLY as normal under a dim
  // scrim, and each footswitch's bound chain floats as a per-pedal ON/OFF
  // control (default style C, the slim per-column footer). Each track switch is
  // bound to its own Track-stage chain here, so the decal shows a bound chain
  // per column — ON, an OFF (bypassed) chain, and an empty NO-CHAIN column —
  // the overlay end to end (#884: the bound chain is what the stage names).
  testWidgets(
    'console main window — FX mode overlay (#692)',
    (tester) async {
      const names = ['GUITAR', 'BOOM', 'RC20', 'VOX'];
      for (var i = 0; i < names.length; i++) {
        await tracks.rename(i, names[i]);
      }
      // The overlay resolves each footswitch's bound chain from the live rig,
      // so the repository's chain lookups mirror the seeded tracks.
      final ch0 = [
        BuiltInEffect(type: TrackEffectType.drive),
        BuiltInEffect(type: TrackEffectType.reverb),
      ];
      final ch1 = [BuiltInEffect(type: TrackEffectType.filter)];
      final ch2 = [BuiltInEffect(type: TrackEffectType.tremolo)];
      when(() => repository.allTrackChains()).thenReturn({
        0: FxChainEnvelope(entries: ch0),
        1: FxChainEnvelope(chainEnabled: false, entries: ch1),
        2: FxChainEnvelope(entries: ch2),
        3: const FxChainEnvelope(),
      });
      when(() => repository.trackEffects(0)).thenReturn(ch0);
      when(() => repository.trackEffects(1)).thenReturn(ch1);
      when(() => repository.trackEffects(2)).thenReturn(ch2);
      when(() => repository.trackEffects(3)).thenReturn(const []);
      when(() => repository.trackChainEnabled(0)).thenReturn(true);
      when(() => repository.trackChainEnabled(1)).thenReturn(false);
      when(() => repository.trackChainEnabled(2)).thenReturn(true);
      when(() => repository.trackChainEnabled(3)).thenReturn(true);
      const trackButtons = [
        PedalButton.track1,
        PedalButton.track2,
        PedalButton.track3,
        PedalButton.track4,
      ];
      await control.setGlobalBindings(
        PedalBindingSet([
          for (var i = 0; i < trackButtons.length; i++)
            PedalBinding(
              key: PedalBindingKey(button: trackButtons[i], bank: 0),
              target: FxChainTarget(
                FxAddress(stage: FxStage.track, index: i),
              ).canonicalString(),
            ),
        ]),
      );
      control.setMode(InteractionMode.fx);
      seed(
        LooperState(
          status: const EngineStatus(
            isConnected: true,
            devicePresent: true,
            deviceName: 'Segno',
            sampleRate: 48000,
            inputChannels: 2,
            outputChannels: 2,
          ),
          tracks: [
            // An engaged two-entry chain.
            Track(
              state: TrackState.playing,
              rms: 0.72,
              peak: 0.9,
              lengthFrames: 96000,
              effects: [
                BuiltInEffect(type: TrackEffectType.drive),
                BuiltInEffect(type: TrackEffectType.reverb),
              ],
            ),
            // A bypassed chain.
            Track(
              channel: 1,
              state: TrackState.playing,
              rms: 0.5,
              peak: 0.68,
              lengthFrames: 96000,
              chainEnabled: false,
              effects: [BuiltInEffect(type: TrackEffectType.filter)],
            ),
            // A single-entry engaged chain.
            Track(
              channel: 2,
              state: TrackState.playing,
              rms: 0.4,
              peak: 0.55,
              lengthFrames: 96000,
              effects: [BuiltInEffect(type: TrackEffectType.tremolo)],
            ),
            // Empty: NO CHAIN.
            const Track(channel: 3),
          ],
        ),
      );
      await pump(tester);
      await expectLater(
        find.byType(TracksView),
        matchesGoldenFile('goldens/tracks_fx_window.png'),
      );
    },
    skip: !hasScreenshotFonts || !kConsoleMode,
  );
}
