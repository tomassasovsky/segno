import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:controller_repository/controller_repository.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:performance_repository/performance_repository.dart';
import 'package:segno/app/fx_chain_persistence.dart';
import 'package:segno/app/mix_settings_coordinator.dart';
import 'package:segno/app/settings_mix_persistence.dart';
import 'package:segno/audio_setup/audio_setup.dart';
import 'package:segno/control/control.dart';
import 'package:segno/looper/application/fade_settings.dart';
import 'package:segno/looper/application/playback_settings.dart';
import 'package:segno/looper/application/record_settings.dart';
import 'package:segno/looper/application/record_timing_settings.dart';
import 'package:segno/looper/application/settings_owners.dart';
import 'package:segno/looper/application/tempo_settings.dart';
import 'package:segno/looper/looper.dart';
import 'package:segno/pedal/pedal.dart';
import 'package:segno/performance/performance.dart';
import 'package:segno/session/application/session_settings_coordinator.dart';
import 'package:segno/session/session.dart';
import 'package:session_repository/session_repository.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

class _MockPedalCubit extends MockCubit<PedalState> implements PedalCubit {}

class _MockAudioSetupCubit extends MockCubit<AudioSetupState>
    implements AudioSetupCubit {}

void main() {
  group('LooperPage', () {
    testWidgets('uses the shared track owner and renders the Tracks view', (
      tester,
    ) async {
      final repository = LooperRepository(
        engine: FakeAudioEngine(),
        ticker: const Stream<void>.empty(),
      );
      final controllerRepository = ControllerRepository(sources: const []);
      final sessionRepository = SessionRepository(engine: FakeAudioEngine());
      final performanceRepository = PerformanceRepository(
        engine: FakeAudioEngine(),
        exportsRoot: () async => '.',
      );
      final settings = SettingsRepository(store: FakeKeyValueStore());
      final fxPersistence = FxChainPersistence(looper: repository);
      final mixSettings = testMixSettings(repository, settings: settings);
      final mixPersistence = SettingsMixPersistence(settings);
      final tempo = TempoSettings(repository: repository, settings: settings);
      await tempo.load();
      addTearDown(() => unawaited(tempo.close()));
      final playback = PlaybackSettings(
        repository: repository,
        settings: settings,
      );
      await playback.load();
      addTearDown(() => unawaited(playback.close()));
      final recordOptions = RecordSettings(
        repository: repository,
        settings: settings,
      );
      await recordOptions.load();
      addTearDown(() => unawaited(recordOptions.close()));
      final timing = RecordTimingSettings(
        repository: repository,
        settings: settings,
      );
      await timing.load();
      final fade = FadeSettings(
        settings: settings,
        blocked: () => false,
        sessionBlocked: () => false,
      );
      await fade.load();
      addTearDown(() async {
        // Complete the fake-clock stream before awaiting the real close.
        final closed = fade.close();
        await tester.pump();
        await closed;
      });
      addTearDown(() => unawaited(timing.close()));
      final pedal = _MockPedalCubit();
      when(() => pedal.state).thenReturn(const PedalState());
      whenListen(
        pedal,
        const Stream<PedalState>.empty(),
        initialState: const PedalState(),
      );
      // The device-lost banner inside the Tracks view reads the audio
      // setup cubit (#453); app-wide in the real shell, above this page.
      final audioSetup = _MockAudioSetupCubit();
      whenListen(
        audioSetup,
        const Stream<AudioSetupState>.empty(),
        initialState: const AudioSetupState(),
      );
      addTearDown(repository.dispose);
      addTearDown(controllerRepository.dispose);

      await tester.pumpApp(
        MultiRepositoryProvider(
          providers: [
            RepositoryProvider.value(value: repository),
            RepositoryProvider.value(value: timing),
            RepositoryProvider.value(value: recordOptions),
            RepositoryProvider.value(value: tempo),
            RepositoryProvider.value(value: playback),
            RepositoryProvider.value(value: controllerRepository),
            RepositoryProvider.value(value: sessionRepository),
            RepositoryProvider.value(value: performanceRepository),
            RepositoryProvider.value(value: settings),
            RepositoryProvider.value(value: mixSettings),
            RepositoryProvider.value(value: fxPersistence),
            RepositoryProvider<MixSettingsPersistence>.value(
              value: mixPersistence,
            ),
          ],
          child: MultiBlocProvider(
            providers: [
              BlocProvider<LooperBloc>(
                create: (_) => LooperBloc(
                  repository: repository,
                  settings: settings,
                  mixSettings: mixSettings,
                  fxPersistence: fxPersistence,
                  recordLengthControl: recordOptions,
                  recordTimingControl: timing,
                ),
              ),
              BlocProvider<TempoCubit>(
                create: (_) => TempoCubit(settings: tempo),
              ),
              BlocProvider<PlaybackOptionsCubit>(
                create: (_) => PlaybackOptionsCubit(settings: playback),
              ),
              BlocProvider<RecordOptionsCubit>(
                create: (_) => RecordOptionsCubit(settings: recordOptions),
              ),
              BlocProvider<RecordTimingCubit>(
                create: (_) => RecordTimingCubit(settings: timing),
              ),
              // The stage status bar is now unconditional, and its clock
              // readout selects a TransportClockCubit.
              BlocProvider<TransportClockCubit>(
                create: (_) => TransportClockCubit(repository: repository),
              ),
              BlocProvider<TracksCubit>(
                create: (_) => TracksCubit(settings: settings),
              ),
              // The Tracks view reads the shared control overlay + intents —
              // created by the providers (as in the app wiring) so disposal
              // happens with the tree, not in an awaited teardown.
              BlocProvider<ControlCubit>(
                create: (_) => ControlCubit(
                  fadeSettings: testFadeSettings(),
                  decayControl: playback.decayControl,
                  oneShotControl: playback.oneShotControl,
                  recordLengthControl: recordOptions,
                  recordTimingControl: timing,
                  clickVolumeControl: tempo.clickVolumeControl,
                  clickModeControl: tempo.clickModeControl,
                  recordStartControl: tempo.recordStartControl,
                  fxPersistence: fxPersistence,
                  looper: repository,
                  mixSettings: mixSettings,
                  pedal: PedalRepository(NoopPedalLink()),
                  settings: settings,
                  performance: performanceRepository,
                ),
              ),
              BlocProvider(
                create: (context) => SessionCubit(
                  settings: context.read<SettingsRepository>(),
                  repository: sessionRepository,
                  looper: repository,
                  performance: performanceRepository,
                  mixSettings: mixSettings,
                  fxPersistence: fxPersistence,
                  mixPersistence: mixPersistence,
                  captureSettings: SessionSettingsCoordinator(
                    fade: fade,
                    looper: repository,
                    mix: mixSettings,
                    fx: fxPersistence,
                    owners: SettingsOwners([
                      ...tempo.owners,
                      ...playback.owners,
                    ]),
                    tempo: tempo,
                    playback: playback,
                    record: recordOptions,
                    timing: timing,
                  ),
                  exportDirectory: () async => '.',
                  currentPedalBindings: () =>
                      context.read<ControlCubit>().state.bindings.encode(),
                  onPedalBindings: (encoded) => context
                      .read<ControlCubit>()
                      .applySessionBindings(PedalBindingSet.decode(encoded)),
                  releaseHeldBindings: () =>
                      context.read<ControlCubit>().releaseAllMomentary(),
                ),
              ),
              BlocProvider<PedalCubit>.value(value: pedal),
              // App-wide in the real shell, above this page. The tray now
              // opens on Signal — the pen's rail has no "Controls" landing
              // face — and the tray builds its face whether or not it is
              // open, so the page's own test carries them too.
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
              BlocProvider<PerformanceRecorderCubit>(
                create: (_) => PerformanceRecorderCubit(
                  performance: performanceRepository,
                ),
              ),
              BlocProvider<AudioSetupCubit>.value(value: audioSetup),
            ],
            child: const LooperPage(),
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(TracksView), findsOneWidget);
    });
  });
}
