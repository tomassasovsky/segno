@Tags(['screenshots'])
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:performance_repository/performance_repository.dart';
import 'package:segno/app/application/owned_value_port.dart';
import 'package:segno/app/fx_chain_persistence.dart';
import 'package:segno/app/mix_settings_coordinator.dart';
import 'package:segno/audio_setup/audio_setup.dart';
import 'package:segno/control/control.dart';
import 'package:segno/control/model/foot_mixer.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/application/fade_settings.dart';
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

/// Manual generator for the console main-window decal (the artwork on the 16"
/// panel in the Fusion "Segno console (populated)" doc). Renders [TracksView]
/// exactly as the physical console shows it and captures a 1920x1080 golden.
///
/// It only produces the CONSOLE layout when compiled with the flag on, so it is
/// Regenerate on the author's machine with:
///
///   flutter test --tags screenshots \
///     --update-goldens test/screenshots/tracks_screenshots_test.dart
void main() {
  late MixSettingsCoordinator mixSettings;
  late FxChainPersistence fxPersistence;
  const fontDir =
      '/Users/Tomas/development/flutter/bin/cache/artifacts/material_fonts';
  // Golden generators load the local SDK's Material fonts and compare against
  // macOS-rendered goldens, so they only run where those fonts exist (the
  // author's machine); everywhere else they skip.
  final hasScreenshotFonts = File('$fontDir/Roboto-Regular.ttf').existsSync();

  setUpAll(() async {
    if (!hasScreenshotFonts) return;
    const robotoTtfs = [
      '$fontDir/Roboto-Regular.ttf',
      '$fontDir/Roboto-Medium.ttf',
      '$fontDir/Roboto-Bold.ttf',
    ];
    await loadScreenshotFont('Roboto', robotoTtfs);
    // Material icon glyphs (e.g. the FX entry-run's arrow_right_alt) — the app
    // bundles this font at runtime; the golden harness must load it too, or
    // every `Icon` renders as .notdef tofu.
    await loadScreenshotFont('MaterialIcons', [
      '$fontDir/MaterialIcons-Regular.otf',
    ]);
    // TracksView wraps itself in LooperScreenTheme, which renders text in the
    // legend font (Helvetica / Arial / sans-serif — macOS/Linux system fonts,
    // absent under `flutter test`). Register the loaded Roboto glyphs under
    // those family names so the labels render instead of Ahem tofu.
    for (final family in ['Helvetica', 'Arial', 'sans-serif']) {
      await loadScreenshotFont(family, robotoTtfs);
    }
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
    // The top bar's settings gear is a package font, which the harness does
    // not bundle: without this load it is a tofu box in every tracks golden.
    await loadScreenshotFont('packages/lucide_icons_flutter/Lucide', [
      packageAssetPath('lucide_icons_flutter', 'assets/lucide.ttf'),
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
  late FadeSettings fade;

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
    when(
      () => repository.cancelArm(channel: any(named: 'channel')),
    ).thenReturn(EngineResult.ok);
    when(() => repository.sessionRevision).thenReturn(0);
    when(() => repository.inputSetup).thenReturn(const InputSetup.empty());
    when(() => repository.laneCount(any())).thenAnswer((call) {
      final channel = call.positionalArguments.first as int;
      return repository.state.tracks
              .where((track) => track.channel == channel)
              .firstOrNull
              ?.lanes
              .length ??
          0;
    });
    when(() => repository.fxReplayConfirmed).thenAnswer(
      (_) => const Stream<({int mixGeneration, int sessionRevision})>.empty(),
    );
    when(() => repository.readTrackWaveform(any())).thenReturn(Float32List(0));
    when(() => repository.state).thenReturn(const LooperState());
    when(() => repository.mixGeneration).thenReturn(0);
    when(
      () => repository.looperState,
    ).thenAnswer((_) => const Stream<LooperState>.empty());
    when(
      () => repository.mixSettingsFailures,
    ).thenAnswer((_) => const Stream.empty());
    fade = FadeSettings(
      repository: repository,
      settings: settings,
      blocked: () => false,
      sessionBlocked: () => false,
    );
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
    when(
      () => repository.mixSettingsFailures,
    ).thenAnswer((_) => const Stream.empty());
    final pedalRepo = PedalRepository(NoopPedalLink());
    addTearDown(pedalRepo.dispose);
    performance = PerformanceRepository(
      engine: FakeAudioEngine(),
      exportsRoot: () async => '.',
    );
    fxPersistence = FxChainPersistence(looper: repository);
    mixSettings = testMixSettings(repository, settings: settings);
    addTearDown(() => unawaited(mixSettings.close()));
    control = ControlCubit(
      fxPersistence: fxPersistence,
      looper: repository,
      mixSettings: mixSettings,
      pedal: pedalRepo,
      settings: settings,
      performance: performance,
      fadeSettings: fade,
      ownedValues: OwnedValuePort(
        looper: repository,
        clickVolume: FakeClickVolumeControl(),
        clickMode: FakeClickModeControl(),
        recordStart: FakeRecordStartControl(),
        decay: FakeDecayControl(),
        oneShot: FakeOneShotControl(),
        recordLength: FakeRecordLengthControl(),
        recordTiming: FakeRecordTimingControl(),
        fade: fade,
      ),
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

  Future<void> pump(WidgetTester tester, {Locale? locale}) async {
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
        locale: locale,
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
            RepositoryProvider<FadeSettings>.value(value: fade),
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
              // which is how it rotted while it was console-gated.
              BlocProvider<InputsCubit>(
                create: (_) =>
                    InputsCubit(settings: settings, repository: repository),
              ),
              BlocProvider<MonitorCubit>(
                create: (_) => MonitorCubit(
                  fxPersistence: fxPersistence,
                  mixSettings: mixSettings,
                  repository: repository,
                  settings: settings,
                ),
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

  for (final scene in ['tracks', 'inputs', 'last_inputs', 'auto', 'spanish']) {
    testWidgets('Foot Mixer $scene accepted scene', (tester) async {
      seed(
        const LooperState(
          status: EngineStatus(
            isConnected: true,
            devicePresent: true,
            deviceName: 'Segno',
            inputChannels: 18,
            outputChannels: 2,
          ),
          tracks: [
            Track(state: TrackState.playing, lengthFrames: 48000, volume: .8),
            Track(
              channel: 1,
              state: TrackState.playing,
              lengthFrames: 48000,
              volume: .65,
              muted: true,
            ),
            Track(
              channel: 2,
              state: TrackState.playing,
              lengthFrames: 48000,
              volume: 1.1,
            ),
            Track(channel: 3),
          ],
        ),
      );
      when(repository.allMonitors).thenReturn({
        0: InputMonitor(
          input: 0,
          volume: scene == 'spanish' ? .98 : .75,
          mode: scene == 'auto' ? MonitorMode.auto : MonitorMode.on,
        ),
        1: InputMonitor(
          input: 1,
          volume: .85,
          mode: MonitorMode.on,
          muted: scene == 'spanish',
        ),
        for (var input = 2; input < 18; input++)
          input: InputMonitor(input: input, mode: MonitorMode.on),
      });
      control.setMode(InteractionMode.mixer);
      if (scene != 'tracks') {
        control.selectFootMixerDomain(FootMixerDomain.inputs);
      }
      if (scene == 'last_inputs') {
        for (var page = 0; page < 4; page++) {
          control.nextFootMixerPage();
        }
      }
      await pump(
        tester,
        locale: scene == 'spanish' ? const Locale('es') : null,
      );
      final context = tester.element(find.byType(TracksView));
      context.read<MonitorCubit>().projectFromRepository();
      await context.read<InputsCubit>().rename(0, 'Guitar');
      await context.read<InputsCubit>().rename(1, 'Vocal');
      await tester.pump();
      expect(tester.takeException(), isNull);
      if (scene == 'spanish') {
        final l10n = context.l10n;
        for (final hint in [
          l10n.footMixerLimitReset,
          l10n.footMixerHoldReset,
          l10n.footMixerHoldUnmute,
        ]) {
          final paragraph = tester.renderObject<RenderParagraph>(
            find.descendant(
              of: find.text(hint),
              matching: find.byType(RichText),
            ),
          );
          expect(paragraph.didExceedMaxLines, isFalse, reason: hint);
          final boxes = paragraph.getBoxesForSelection(
            TextSelection(baseOffset: 0, extentOffset: hint.length),
          );
          expect(
            boxes.last.bottom,
            lessThanOrEqualTo(paragraph.size.height),
            reason: hint,
          );
          expect(paragraph.size.height, lessThanOrEqualTo(56), reason: hint);
        }
      }
      await expectLater(
        find.byType(TracksView),
        matchesGoldenFile('goldens/foot_mixer_$scene.png'),
      );
    }, skip: !hasScreenshotFonts);
  }

  // The accepted Fade Pen frames (docs/design/fade-previews/pen): shared
  // Default, a track override, Bank B, and the Spanish strings.
  for (final scene in ['default', 'custom', 'bank', 'spanish']) {
    testWidgets('Foot Fade $scene accepted scene', (tester) async {
      Track track(int channel, {bool faded = false}) => Track(
        channel: channel,
        state: TrackState.playing,
        lengthFrames: 48000,
        fade: faded ? const FadeImage(amount: 0, target: 0) : const FadeImage(),
      );
      seed(
        LooperState(
          status: const EngineStatus(
            isConnected: true,
            devicePresent: true,
            deviceName: 'Segno',
            inputChannels: 2,
            outputChannels: 2,
          ),
          tracks: [
            track(0),
            track(1, faded: true),
            track(2),
            const Track(channel: 3),
            track(4, faded: true),
            track(5),
            track(6),
            const Track(channel: 7),
          ],
        ),
      );
      await tester.runAsync(() async {
        await settings.saveFadeDurations(
          FadeDurations(overrides: const {1: 8000, 4: 2000}),
        );
        await fade.load();
      });
      control.setMode(InteractionMode.fade);
      if (scene == 'custom') control.selectFootFadeTrackTime(1);
      if (scene == 'bank') control.browseBank(1);
      await pump(
        tester,
        locale: scene == 'spanish' ? const Locale('es') : null,
      );
      expect(tester.takeException(), isNull);
      await expectLater(
        find.byType(TracksView),
        matchesGoldenFile('goldens/foot_fade_$scene.png'),
      );
    }, skip: !hasScreenshotFonts);
  }

  // The accepted Reverse Pen frames (segno-ui.pen 13 Performance · Reverse):
  // playback direction, Bank B, an empty loop, and the Spanish strings.
  for (final scene in ['default', 'bank', 'empty', 'spanish']) {
    testWidgets('Foot Reverse $scene accepted scene', (tester) async {
      Track track(int channel, {bool reversed = false}) => Track(
        channel: channel,
        state: TrackState.playing,
        lengthFrames: 48000,
        reversed: reversed,
      );
      seed(
        LooperState(
          status: const EngineStatus(
            isConnected: true,
            devicePresent: true,
            deviceName: 'Segno',
            inputChannels: 2,
            outputChannels: 2,
          ),
          tracks: scene == 'empty'
              ? [
                  for (var channel = 0; channel < 8; channel++)
                    Track(channel: channel),
                ]
              : [
                  track(0),
                  track(1, reversed: true),
                  track(2),
                  const Track(channel: 3),
                  track(4, reversed: true),
                  track(5),
                  track(6),
                  const Track(channel: 7),
                ],
        ),
      );
      control.setMode(InteractionMode.reverse);
      if (scene == 'bank') control.browseBank(1);
      await pump(
        tester,
        locale: scene == 'spanish' ? const Locale('es') : null,
      );
      expect(tester.takeException(), isNull);
      await expectLater(
        find.byType(TracksView),
        matchesGoldenFile('goldens/foot_reverse_$scene.png'),
      );
    }, skip: !hasScreenshotFonts);
  }

  // Foot Peel (the pen lists the mode, "Remove an overdub layer", but has no
  // screen of its own; it follows the Fade and Mixer layout): layer counts
  // with an overdubbing track, Bank B, an empty loop, and the Spanish
  // strings.
  for (final scene in ['default', 'bank', 'empty', 'spanish']) {
    testWidgets('Foot Peel $scene scene', (tester) async {
      Track track(
        int channel, {
        int layers = 0,
        TrackState state = TrackState.playing,
      }) => Track(
        channel: channel,
        state: state,
        lengthFrames: 48000,
        peelDepth: layers,
      );
      seed(
        LooperState(
          status: const EngineStatus(
            isConnected: true,
            devicePresent: true,
            deviceName: 'Segno',
            inputChannels: 2,
            outputChannels: 2,
          ),
          tracks: scene == 'empty'
              ? [
                  for (var channel = 0; channel < 8; channel++)
                    Track(channel: channel),
                ]
              : [
                  track(0, layers: 3),
                  track(1),
                  track(2, layers: 1, state: TrackState.overdubbing),
                  const Track(channel: 3),
                  track(4, layers: 2),
                  track(5),
                  track(6, layers: 1),
                  const Track(channel: 7),
                ],
        ),
      );
      control.setMode(InteractionMode.peel);
      if (scene == 'bank') control.browseBank(1);
      await pump(
        tester,
        locale: scene == 'spanish' ? const Locale('es') : null,
      );
      expect(tester.takeException(), isNull);
      await expectLater(
        find.byType(TracksView),
        matchesGoldenFile('goldens/foot_peel_$scene.png'),
      );
    }, skip: !hasScreenshotFonts);
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
              peak: 0.9,
              lengthFrames: 96000,
            ),
            Track(
              channel: 1,
              state: TrackState.playing,
              peak: 0.68,
              lengthFrames: 96000,
            ),
            // RC20: loaded (has content) but muted.
            Track(
              channel: 2,
              state: TrackState.playing,
              muted: true,
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
    skip: !hasScreenshotFonts,
  );

  testWidgets(
    'console main window with a reversed track: REV in the meta row gap',
    (tester) async {
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
            Track(state: TrackState.playing, peak: 0.9, lengthFrames: 96000),
            Track(
              channel: 1,
              state: TrackState.playing,
              peak: 0.68,
              lengthFrames: 96000,
              reversed: true,
            ),
            Track(
              channel: 2,
              state: TrackState.playing,
              muted: true,
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
        matchesGoldenFile('goldens/tracks_reverse_marker.png'),
      );
    },
    skip: !hasScreenshotFonts,
  );

  // Real fonts: REV sits clear of the layers figure and FX in English and
  // Spanish, with long counts.
  for (final locale in const [Locale('en'), Locale('es')]) {
    for (final bars in [16, 128]) {
      testWidgets(
        'REV clears its neighbours (${locale.languageCode}, $bars bars, '
        '12 layers)',
        (tester) async {
          Track track(int channel) => Track(
            channel: channel,
            state: TrackState.playing,
            lengthFrames: 1000 * bars,
            peelDepth: 11,
            reversed: channel == 1,
          );
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
              transport: const TransportState(
                masterLengthFrames: 1000,
                loopBars: 1,
              ),
              tracks: [
                for (var channel = 0; channel < 4; channel++) track(channel),
              ],
            ),
          );
          await pump(tester, locale: locale);
          Rect box(String part) =>
              tester.getRect(find.byKey(Key('tracks_${part}_1')));
          expect(box('reverse').left, greaterThan(box('layers').right + 4));
          expect(box('reverse').right, lessThan(box('fx').left));
          expect(box('layers').left, greaterThan(box('bars').right));
        },
        skip: !hasScreenshotFonts,
      );
    }
  }

  testWidgets(
    'the Mixer view (MAIN VIEWS / Mixer)',
    (tester) async {
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
            // Panned left, a touch under unity, both sides metering.
            Track(
              state: TrackState.playing,
              lengthFrames: 96000,
              volume: 0.8,
              pan: -0.4,
              solo: true,
              peakL: 0.9,
              peakR: 0.55,
            ),
            // Soloed, above unity.
            Track(
              channel: 1,
              state: TrackState.playing,
              lengthFrames: 96000,
              volume: 1.4,
              solo: true,
              peakL: 0.62,
              peakR: 0.68,
            ),
            // Muted playback keeps its fader level but meters no signal.
            Track(
              channel: 2,
              state: TrackState.playing,
              lengthFrames: 96000,
              muted: true,
            ),
            Track(channel: 3),
          ],
        ),
      );
      await pump(tester);
      await tester.tap(find.byKey(const Key('stage_view_menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('stage_view_mixer')));
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(TracksView),
        matchesGoldenFile('goldens/tracks_mixer_window.png'),
      );
      // The same scene must keep the shared meter scale aligned when the
      // desktop window is smaller than the appliance panel.
      tester.view.physicalSize = const Size(800, 600);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await expectLater(
        find.byType(TracksView),
        matchesGoldenFile('goldens/tracks_mixer_compact_window.png'),
      );
    },
    skip: !hasScreenshotFonts,
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
    skip: !hasScreenshotFonts,
  );

  // #692: the FX-mode stage transform — the whole stage takes the FX purple,
  // meters recede to 40%, and each tile re-dresses with a power pill and its
  // chain's entries (or NO CHAIN). Same seed as the nominal decal, in FX mode
  // and with two real chains, so the decal shows the transform end to end.
  testWidgets(
    'console main window — FX mode transform (#692)',
    (tester) async {
      const names = ['GUITAR', 'BOOM', 'RC20', 'VOX'];
      for (var i = 0; i < names.length; i++) {
        await tracks.rename(i, names[i]);
      }
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
              peak: 0.68,
              lengthFrames: 96000,
              chainEnabled: false,
              effects: [BuiltInEffect(type: TrackEffectType.filter)],
            ),
            // A single-entry engaged chain.
            Track(
              channel: 2,
              state: TrackState.playing,
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
    skip: !hasScreenshotFonts,
  );
}
