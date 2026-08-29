import 'package:bloc_test/bloc_test.dart';
import 'package:controller_repository/controller_repository.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:performance_repository/performance_repository.dart';
import 'package:segno/audio_setup/audio_setup.dart';
import 'package:segno/control/control.dart';
import 'package:segno/looper/looper.dart';
import 'package:segno/pedal/pedal.dart';
import 'package:segno/performance/performance.dart';
import 'package:session_repository/session_repository.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

class _MockPedalCubit extends MockCubit<PedalState> implements PedalCubit {}

class _MockAudioSetupCubit extends MockCubit<AudioSetupState>
    implements AudioSetupCubit {}

void main() {
  group('LooperPage', () {
    testWidgets('wires its blocs and renders the Tracks view', (
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
      final sim = SimulatorPedalTransport(inner: const NoopPedalTransport());
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
            RepositoryProvider.value(value: controllerRepository),
            RepositoryProvider.value(value: sessionRepository),
            RepositoryProvider.value(value: performanceRepository),
            RepositoryProvider.value(value: settings),
            RepositoryProvider<SimulatorPedalTransport>.value(value: sim),
          ],
          child: MultiBlocProvider(
            providers: [
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
                  looper: repository,
                  pedal: PedalRepository(const NoopPedalTransport()),
                  settings: settings,
                  performance: performanceRepository,
                  keepAliveInterval: Duration.zero,
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
                create: (_) =>
                    MonitorCubit(repository: repository, settings: settings),
              ),
              BlocProvider<PerformanceRecorderCubit>(
                create: (_) => PerformanceRecorderCubit(
                  performance: performanceRepository,
                ),
              ),
              BlocProvider<AudioSetupCubit>.value(value: audioSetup),
            ],
            child: LooperPage(exportDirectory: () async => '.'),
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(TracksView), findsOneWidget);
    });
  });
}
