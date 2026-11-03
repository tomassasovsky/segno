import 'dart:async';
import 'dart:typed_data';

import 'package:bloc_test/bloc_test.dart';
import 'package:cpu_load_repository/cpu_load_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:operation_guards/operation_guards.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:performance_repository/performance_repository.dart';
import 'package:segno/app/application/owned_value_port.dart';
import 'package:segno/app/fx_chain_persistence.dart';
import 'package:segno/app/mix_settings_coordinator.dart';
import 'package:segno/audio_setup/audio_setup.dart';
import 'package:segno/control/control.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/application/fade_settings.dart';
import 'package:segno/looper/looper.dart';
import 'package:segno/performance/performance.dart';
import 'package:segno/session/session.dart';
import 'package:segno/theme/theme.dart';
import 'package:segno/tuner/cubit/tuner_cubit.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';
import '../../helpers/text_fit.dart';

class _MockLooperBloc extends MockBloc<LooperEvent, LooperState>
    implements LooperBloc {}

class _MockLooperRepository extends Mock implements LooperRepository {}

class _MockSessionCubit extends MockCubit<SessionState>
    implements SessionCubit {}

class _MockPerformanceRecorderCubit extends MockCubit<PerformanceRecorderState>
    implements PerformanceRecorderCubit {}

class _MockTransportClockCubit extends MockCubit<TransportClockState>
    implements TransportClockCubit {}

class _MockOutputLevelCubit extends MockCubit<OutputLevelState>
    implements OutputLevelCubit {}

class _MockAudioSetupCubit extends MockCubit<AudioSetupState>
    implements AudioSetupCubit {}

class _MockTunerCubit extends MockCubit<TunerState> implements TunerCubit {}

/// Every text on the stage shows in full on the console's main screen, in
/// the faces the app bundles (#1524). The test font's square glyphs would
/// measure nothing the console draws, so the bundled faces are loaded.
void main() {
  setUpAll(loadBundledFonts);

  late LooperBloc bloc;
  late TracksCubit tracks;
  late ControlCubit control;
  late LooperRepository repository;
  late SettingsRepository settings;
  late MixSettingsCoordinator mixSettings;

  setUp(() {
    settings = SettingsRepository(store: FakeKeyValueStore());
    bloc = _MockLooperBloc();
    tracks = TracksCubit(settings: settings);
    repository = _MockLooperRepository();
    when(() => repository.meters).thenReturn(const MeterLevels());
    when(
      () => repository.meterLevels,
    ).thenAnswer((_) => const Stream<MeterLevels>.empty());
    when(() => repository.playhead).thenReturn(const Playhead());
    when(
      () => repository.playheads,
    ).thenAnswer((_) => const Stream<Playhead>.empty());
    when(() => repository.sessionRevision).thenReturn(0);
    when(() => repository.inputSetup).thenReturn(const InputSetup.empty());
    when(() => repository.laneCount(any())).thenReturn(1);
    when(() => repository.fxReplayConfirmed).thenAnswer(
      (_) => const Stream<({int mixGeneration, int sessionRevision})>.empty(),
    );
    when(() => repository.readTrackWaveform(any())).thenReturn(Float32List(0));
    when(() => repository.mixGeneration).thenReturn(0);
    when(() => repository.state).thenReturn(const LooperState());
    when(
      () => repository.looperState,
    ).thenAnswer((_) => const Stream<LooperState>.empty());
    when(
      () => repository.mixSettingsFailures,
    ).thenAnswer((_) => const Stream.empty());
    when(
      () => repository.monitorChanges,
    ).thenAnswer((_) => const Stream<int>.empty());
    when(
      () => repository.monitorParamChanges,
    ).thenAnswer((_) => const Stream<int>.empty());
    when(() => repository.allMonitors()).thenReturn(const {});
    when(() => repository.monitorEffects(any())).thenReturn(const []);
    final pedal = PedalRepository(NoopPedalLink());
    addTearDown(pedal.dispose);
    final fade = FadeSettings(
      repository: repository,
      settings: settings,
      blocked: () => false,
      sessionBlocked: () => false,
    );
    mixSettings = testMixSettings(repository, settings: settings);
    addTearDown(() => unawaited(mixSettings.close()));
    control = ControlCubit(
      fxPersistence: FxChainPersistence(looper: repository),
      looper: repository,
      mixSettings: mixSettings,
      pedal: pedal,
      settings: settings,
      performance: PerformanceRepository(
        guards: GuardRegistry(),
        engine: FakeAudioEngine(),
        exportsRoot: () async => '.',
      ),
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
  });

  /// Four tracks with the longest texts the stage prints: one recording,
  /// so its count is the empty `—`; two 128-bar loops with twelve layers,
  /// one reversed and panned hard left, one muted and panned hard right; and
  /// a loop of seven beats (1.75 bars), which counts in beats.
  void seedLongCounts() {
    Track track(int channel) => Track(
      channel: channel,
      state: channel == 0 ? TrackState.recording : TrackState.playing,
      lengthFrames: channel == 3 ? 1750 : 128000,
      peelDepth: 11,
      reversed: channel == 1,
      muted: channel == 2,
      pan: switch (channel) {
        1 => -1,
        2 => 1,
        _ => 0,
      },
    );
    final state = LooperState(
      status: const EngineStatus(
        isConnected: true,
        devicePresent: true,
        sampleRate: 48000,
        inputChannels: 2,
        outputChannels: 2,
      ),
      transport: const TransportState(masterLengthFrames: 1000, loopBars: 1),
      tracks: [for (var channel = 0; channel < 4; channel++) track(channel)],
    );
    when(() => bloc.state).thenReturn(state);
    when(() => repository.state).thenReturn(state);
    whenListen(bloc, const Stream<LooperState>.empty(), initialState: state);
  }

  Future<void> pump(WidgetTester tester, Locale locale) async {
    // The console's main screen: 1920 x 1080 at a device pixel ratio of 1.
    tester.view
      ..physicalSize = const Size(1920, 1080)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final session = _MockSessionCubit();
    when(() => session.state).thenReturn(const SessionState());
    final recorder = _MockPerformanceRecorderCubit();
    when(() => recorder.state).thenReturn(const PerformanceRecorderIdle());
    final clock = _MockTransportClockCubit();
    whenListen(
      clock,
      const Stream<TransportClockState>.empty(),
      initialState: const TransportClockState(),
    );
    final output = _MockOutputLevelCubit();
    whenListen(
      output,
      const Stream<OutputLevelState>.empty(),
      initialState: const OutputLevelState(),
    );
    final audioSetup = _MockAudioSetupCubit();
    whenListen(
      audioSetup,
      const Stream<AudioSetupState>.empty(),
      initialState: const AudioSetupState(),
    );
    final tuner = _MockTunerCubit();
    whenListen(
      tuner,
      const Stream<TunerState>.empty(),
      initialState: const TunerState(),
    );
    await tester.pumpWidget(
      MaterialApp(
        locale: locale,
        theme: AppTheme.neon,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: MultiRepositoryProvider(
          providers: [
            RepositoryProvider<LooperRepository>.value(value: repository),
            RepositoryProvider<CpuLoadRepository>.value(
              value: const FixedCpuLoadRepository(23),
            ),
            RepositoryProvider<SettingsRepository>.value(value: settings),
          ],
          child: MultiBlocProvider(
            providers: [
              BlocProvider<LooperBloc>.value(value: bloc),
              BlocProvider<TracksCubit>.value(value: tracks),
              BlocProvider<ControlCubit>.value(value: control),
              BlocProvider<SessionCubit>.value(value: session),
              BlocProvider<PerformanceRecorderCubit>.value(value: recorder),
              BlocProvider<TransportClockCubit>.value(value: clock),
              BlocProvider<OutputLevelCubit>.value(value: output),
              BlocProvider<InputsCubit>(
                create: (_) =>
                    InputsCubit(settings: settings, repository: repository),
              ),
              BlocProvider<TunerCubit>.value(value: tuner),
              BlocProvider<MonitorCubit>(
                create: (_) => MonitorCubit(
                  fxPersistence: FxChainPersistence(looper: repository),
                  mixSettings: mixSettings,
                  repository: repository,
                  settings: settings,
                ),
              ),
              BlocProvider<AudioSetupCubit>.value(value: audioSetup),
            ],
            child: const TracksView(),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  for (final locale in AppLocalizations.supportedLocales) {
    final language = locale.languageCode;
    for (final view in StageView.values) {
      testWidgets(
        'the ${view.name} view shows every text in full ($language)',
        (
          tester,
        ) async {
          seedLongCounts();
          tracks.showView(view);
          await pump(tester, locale);
          // The seed's longest texts are on screen to be measured.
          final l10n = lookupAppLocalizations(locale);
          expect(find.text(l10n.stageBeatsUnit(7)), findsOneWidget);
          expect(find.text(l10n.stageBarsUnit(128)), findsWidgets);
          if (view == StageView.mixer) {
            expect(find.text(l10n.routingPanLeftAmount(100)), findsOneWidget);
          }
          expect(tester.takeException(), isNull);
          expect(clippedTexts(tester), isEmpty);
          expect(await unbundledTexts(tester), isEmpty);
        },
      );
    }

    testWidgets('the view menu names every view in a bundled face '
        '($language)', (tester) async {
      seedLongCounts();
      await pump(tester, locale);
      await tester.tap(find.byKey(const Key('stage_view_menu')));
      await tester.pumpAndSettle();
      final l10n = lookupAppLocalizations(locale);
      for (final label in [
        l10n.stageViewTrack,
        l10n.stageViewWave,
        l10n.stageViewMixer,
      ]) {
        expect(find.text(label), findsOneWidget);
      }
      expect(clippedTexts(tester), isEmpty);
      expect(await unbundledTexts(tester), isEmpty);
    });
  }
}
