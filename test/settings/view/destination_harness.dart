import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:brightness_client/brightness_client.dart';
import 'package:console_facts_client/console_facts_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/app/segno_navigator.dart';
import 'package:segno/appliance/display_brightness_cubit.dart';
import 'package:segno/appliance/idle_dim_cubit.dart';
import 'package:segno/audio_setup/audio_setup.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/cubit/high_contrast_cubit.dart';
import 'package:segno/looper/cubit/record_options_cubit.dart';
import 'package:segno/looper/cubit/refresh_rate_cubit.dart';
import 'package:segno/looper/cubit/tempo_cubit.dart';
import 'package:segno/looper/cubit/tracks_cubit.dart';
import 'package:segno/looper/model/record_options.dart';
import 'package:segno/looper/model/record_options_view_state.dart';
import 'package:segno/looper/model/tempo_state.dart';
import 'package:segno/pedal/cubit/pedal_cubit.dart';
import 'package:segno/system/cubit/console_facts_cubit.dart';
import 'package:segno/theme/theme.dart';
import 'package:segno/update/cubit/update_cubit.dart';
import 'package:segno/visualizer/cubit/waveform_window_cubit.dart';
import 'package:settings_repository/settings_repository.dart';
import 'package:toastification/toastification.dart';
import 'package:wifi_repository/wifi_repository.dart';

import '../../helpers/helpers.dart';
import 'destination_extra_providers.dart';

/// A mock for the destination harness.
class MockAudioSetupCubit extends MockCubit<AudioSetupState>
    implements AudioSetupCubit {}

/// A mock for the destination harness.
class MockInputsCubit extends MockCubit<InputsState> implements InputsCubit {}

/// A mock for the destination harness.
class MockLooperBloc extends MockBloc<LooperEvent, LooperState>
    implements LooperBloc {}

/// A mock for the destination harness.
class MockRecordOptionsCubit extends MockCubit<RecordOptionsViewState>
    implements RecordOptionsCubit {}

/// A mock for the destination harness.
class MockTempoCubit extends MockCubit<TempoState> implements TempoCubit {}

/// A mock for the destination harness.
class MockUpdateCubit extends MockCubit<UpdateState> implements UpdateCubit {}

/// A mock for the destination harness.
class MockWaveformWindowCubit extends MockCubit<WaveformWindowState>
    implements WaveformWindowCubit {}

/// A mock for the destination harness.
class MockHighContrastCubit extends MockCubit<bool>
    implements HighContrastCubit {}

/// A mock for the destination harness.
class MockRefreshRateCubit extends MockCubit<int> implements RefreshRateCubit {}

/// Counts the radio reads, so a test can tell the page read the radio when it
/// opened and not before.
class CountingWifiClient extends UnsupportedWifiClient {
  int statusReads = 0;

  @override
  Future<WifiStatus> status() {
    statusReads++;
    return super.status();
  }
}

/// The console's two outputs, pinned as the appliance pins them, with a
/// presence a test can change.
class FakeDisplayOutputs implements DisplayOutputs {
  /// Each connector's presence; `null` is unknown.
  final status = <String, bool?>{'HDMI-A-1': true, 'HDMI-A-2': true};

  @override
  Future<Map<String, String>> appIdConnectors() async => const {
    'dev.aquiles.segno': 'HDMI-A-1',
    'dev.aquiles.segno.waveform': 'HDMI-A-2',
  };

  @override
  Future<bool?> isConnected(String connector) async => status[connector];
}

/// The providers the five destination pages read, mounted above a root
/// navigator the way the app mounts them, so a test can open a page through
/// the navigator functions and find it.
class DestinationHarness {
  /// Creates a harness with fresh settings (over [store], when a test needs
  /// writes to fail), a stubbed audio cubit and a counting Wi-Fi client.
  DestinationHarness({KeyValueStore? store})
    : settings = SettingsRepository(store: store ?? FakeKeyValueStore()) {
    when(audio.beginDeviceScan).thenReturn(null);
    when(audio.endDeviceScan).thenReturn(null);
  }

  /// The settings store behind the real cubits.
  final SettingsRepository settings;

  /// The audio setup the Device page reads.
  final MockAudioSetupCubit audio = MockAudioSetupCubit();

  /// The radio the Network page reads.
  final CountingWifiClient wifi = CountingWifiClient();

  /// The brightness owner, real so a test can read what was saved.
  late DisplayBrightnessCubit brightness;

  /// The idle dim owner, real so a test can read what was saved.
  late IdleDimCubit idle;

  /// The outputs the Displays page reads presence from.
  final FakeDisplayOutputs outputs = FakeDisplayOutputs();

  /// The waveform window preference the Displays page shows.
  late MockWaveformWindowCubit waveform;

  /// The high-contrast preference the Displays page shows.
  late MockHighContrastCubit contrast;

  /// The refresh rate the Displays page shows.
  late MockRefreshRateCubit refresh;

  /// Mounts [home] under a root navigator that carries every provider the
  /// five destination pages read, the way the app provides them above its
  /// navigator.
  Future<void> pump(
    WidgetTester tester, {
    Widget home = const SizedBox.shrink(),
    AudioSetupState audioState = const AudioSetupState(),
    UpdateState updateState = const UpdateState(),
    ConsoleFactsClient? factsClient,
    PedalLink? pedalLink,
    WaveformWindowState waveformState = const WaveformWindowState(),
  }) async {
    tester.view
      ..physicalSize = const Size(1920, 1080)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    whenListen(
      audio,
      const Stream<AudioSetupState>.empty(),
      initialState: audioState,
    );
    final inputs = MockInputsCubit();
    whenListen(
      inputs,
      const Stream<InputsState>.empty(),
      initialState: const InputsState(),
    );
    final looper = MockLooperBloc();
    whenListen(
      looper,
      const Stream<LooperState>.empty(),
      initialState: const LooperState(),
    );
    final options = MockRecordOptionsCubit();
    whenListen(
      options,
      const Stream<RecordOptionsViewState>.empty(),
      initialState: const RecordOptionsViewState(options: RecordOptions()),
    );
    final tempo = MockTempoCubit();
    whenListen(
      tempo,
      const Stream<TempoState>.empty(),
      initialState: const TempoState(),
    );
    final update = MockUpdateCubit();
    whenListen(
      update,
      const Stream<UpdateState>.empty(),
      initialState: updateState,
    );
    waveform = MockWaveformWindowCubit();
    whenListen(
      waveform,
      const Stream<WaveformWindowState>.empty(),
      initialState: waveformState,
    );
    contrast = MockHighContrastCubit();
    whenListen(contrast, const Stream<bool>.empty(), initialState: false);
    refresh = MockRefreshRateCubit();
    whenListen(refresh, const Stream<int>.empty(), initialState: 60);
    brightness = DisplayBrightnessCubit(settings: settings);
    idle = IdleDimCubit(settings: settings);
    final tracks = TracksCubit(settings: settings);
    final pedal = PedalCubit(
      pedal: PedalRepository(pedalLink ?? NoopPedalLink()),
    );
    final facts = ConsoleFactsCubit(
      client: factsClient ?? FakeConsoleFactsClient(latency: Duration.zero),
      settings: settings,
    );
    // unawaited: awaiting a cubit close inside a testWidgets body deadlocks on
    // the binding's stream cancellation (flutter/flutter#139870).
    addTearDown(() => unawaited(brightness.close()));
    addTearDown(() => unawaited(idle.close()));
    addTearDown(() => unawaited(tracks.close()));
    addTearDown(() => unawaited(pedal.close()));
    addTearDown(() => unawaited(facts.close()));

    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider.value(value: WifiRepository(client: wifi)),
          RepositoryProvider<DisplayOutputs>.value(value: outputs),
        ],
        child: MultiBlocProvider(
          providers: [
            BlocProvider<AudioSetupCubit>.value(value: audio),
            BlocProvider<InputsCubit>.value(value: inputs),
            BlocProvider<LooperBloc>.value(value: looper),
            BlocProvider<RecordOptionsCubit>.value(value: options),
            BlocProvider<TempoCubit>.value(value: tempo),
            BlocProvider<UpdateCubit>.value(value: update),
            BlocProvider<WaveformWindowCubit>.value(value: waveform),
            BlocProvider<HighContrastCubit>.value(value: contrast),
            BlocProvider<RefreshRateCubit>.value(value: refresh),
            BlocProvider.value(value: brightness),
            BlocProvider.value(value: idle),
            BlocProvider.value(value: tracks),
            BlocProvider.value(value: pedal),
            BlocProvider.value(value: facts),
            ...extraProviders(),
          ],
          // The app's own toast overlay, so a page's toasts can be shown
          // and dismissed here as they are on the console.
          child: ToastificationWrapper(
            child: MaterialApp(
              navigatorKey: segnoNavigatorKey,
              debugShowCheckedModeBanner: false,
              theme: AppTheme.neon,
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Scaffold(body: home),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }
}
