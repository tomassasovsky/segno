@Tags(['screenshots'])
library;

import 'dart:async';
import 'dart:io';

import 'package:bloc_test/bloc_test.dart';
import 'package:brightness_client/brightness_client.dart';
import 'package:console_facts_client/console_facts_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:midi_device_repository/midi_device_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:operation_guards/operation_guards.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:performance_repository/performance_repository.dart';
import 'package:routing_graph/routing_graph.dart';
import 'package:segno/app/application/owned_value_port.dart';
import 'package:segno/app/fx_chain_persistence.dart';
import 'package:segno/appliance/display_brightness_cubit.dart';
import 'package:segno/appliance/idle_dim_cubit.dart';
import 'package:segno/audio_setup/cubit/audio_setup_cubit.dart';
import 'package:segno/audio_setup/cubit/inputs_cubit.dart';
import 'package:segno/audio_setup/cubit/midi_setup_cubit.dart';
import 'package:segno/audio_setup/cubit/monitor_cubit.dart';
import 'package:segno/control/control.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/application/record_settings.dart';
import 'package:segno/looper/application/record_timing_settings.dart';
import 'package:segno/looper/application/tempo_settings.dart';
import 'package:segno/looper/looper.dart';
import 'package:segno/looper/view/fx/fx_pedal_assignments_page.dart';
import 'package:segno/pedal/cubit/pedal_cubit.dart';
import 'package:segno/settings/settings.dart';
import 'package:segno/system/cubit/console_facts_cubit.dart';
import 'package:segno/theme/theme.dart';
import 'package:segno/tuner/application/tuner_settings.dart';
import 'package:segno/tuner/cubit/tuner_cubit.dart';
import 'package:segno/update/cubit/update_cubit.dart';
import 'package:segno/visualizer/cubit/waveform_window_cubit.dart';
import 'package:settings_repository/settings_repository.dart';
import 'package:update_repository/update_repository.dart';
import 'package:wifi_repository/wifi_repository.dart';

import '../helpers/helpers.dart';
import 'screenshot_settings.dart';

class _MockLooperRepository extends Mock implements LooperRepository {}

class _MockLooperBloc extends MockBloc<LooperEvent, LooperState>
    implements LooperBloc {}

class _MockMidiDevices extends Mock implements MidiDeviceRepository {}

class _MockUpdateCubit extends MockCubit<UpdateState> implements UpdateCubit {}

/// What the appliance reports about its own build. A real [UpdateCubit] over
/// the unsupported backend knows neither its version nor its channel, and the
/// About face correctly drops the row that would have said so — which makes
/// for a golden of the empty case rather than of the face.
final _consoleBuild = UpdateState(
  supported: true,
  channel: 'experimental',
  currentVersion: Version.parse('0.1.0'),
);

/// What the host reports for `AUDIO / settings-device`: an 18-in interface
/// listed in both directions, and the built-in pair. Both sides carry their
/// real channel counts, which is the fact the engine was never asking
/// miniaudio for.
const _previewDevices = <AudioDevice>[
  AudioDevice(
    id: 'scarlett-out',
    name: 'Scarlett 18i20',
    isDefault: false,
    isInput: false,
    outputChannels: 20,
  ),
  AudioDevice(
    id: 'scarlett-in',
    name: 'Scarlett 18i20',
    isDefault: false,
    isInput: true,
    inputChannels: 18,
  ),
  AudioDevice(
    id: 'builtin-out',
    name: 'Built-in audio',
    isDefault: true,
    isInput: false,
    outputChannels: 2,
  ),
  AudioDevice(
    id: 'builtin-in',
    name: 'Built-in audio',
    isDefault: true,
    isInput: true,
    inputChannels: 2,
  ),
];

/// What the engine reports while the Scarlett is open — the figures the Status
/// tab reads, and the device name the Device row falls back to.
const _previewStatus = EngineStatus(
  isConnected: true,
  deviceName: 'Scarlett 18i20',
  sampleRate: 48000,
  bufferFrames: 128,
  inputChannels: 18,
  outputChannels: 20,
  devicePresent: true,
  latencyState: LatencyState.done,
  measuredLatencyMs: 7.42,
  recordOffsetFrames: 64,
);

/// A rig with a Master insert carrying two effects — enough for the assign
/// list to have chains, slots and a bound target to draw.
const _master = FxAddress(stage: FxStage.output);

final _masterChain = <TrackEffect>[
  BuiltInEffect(type: TrackEffectType.drive, slotId: 'slot-drive'),
  BuiltInEffect(type: TrackEffectType.reverb, slotId: 'slot-reverb'),
];

/// The preview's theme — the app's own surface tokens over the app's own
/// display face.
///
/// The face was `Roboto` until #533: the harness loads Flutter's cached Roboto
/// for `MaterialIcons`' sake, and naming it here meant every console preview
/// was drawn in a typeface the product does not ship. That cost more than
/// letterforms — Roboto's cache subset has no `→`, so the Signal cards' routing
/// lines came out as tofu boxes in a golden whose entire job is to be
/// eyeballed against the mockups.
ThemeData _theme() => ThemeData(
  fontFamily: SurfaceTheme.displayFont,
  brightness: Brightness.dark,
  extensions: [
    SurfaceTheme.dark,
    routingGraphThemeFromSurface(SurfaceTheme.dark),
  ],
);

/// The pen 29 study's radio: The Studio up, a saved network out of range, and
/// four others. Each switch reaches one of the eight accepted screens.
class _PreviewWifiClient implements WifiClient {
  _PreviewWifiClient({
    this.enabled = true,
    this.connected = true,
    this.internet = true,
    this.holdJoins = false,
    this.refuseKey = false,
  });

  final bool enabled;
  final bool connected;
  final bool internet;

  /// A join never ends, so the Connecting dialog stays up.
  final bool holdJoins;

  /// A join is refused as a wrong password.
  final bool refuseKey;

  @override
  bool get isSupported => true;

  @override
  Future<WifiStatus> status() async {
    final up = enabled && connected;
    return WifiStatus(
      supported: true,
      enabled: enabled,
      connected: up,
      ssid: up ? 'The Studio' : '',
      ip: up ? '192.168.1.42' : '',
      signal: -42,
      autoConnect: const {'The Studio': true, 'Venue backstage': false},
      lastSsid: 'The Studio',
    );
  }

  @override
  Future<List<WifiNetwork>> scan() async => const [
    WifiNetwork(ssid: 'The Studio', signal: -42, secured: true, saved: true),
    WifiNetwork(ssid: 'Rehearsal Room', signal: -50, secured: true),
    WifiNetwork(ssid: 'Guest Wi-Fi', signal: -64, secured: false),
    WifiNetwork(
      ssid: 'Venue backstage',
      signal: 0,
      secured: true,
      saved: true,
      inRange: false,
    ),
    WifiNetwork(ssid: 'Phone hotspot', signal: -78, secured: true),
  ];

  @override
  Future<void> connect(String ssid, {String? psk}) async {
    if (holdJoins) await Completer<void>().future;
    if (refuseKey) throw StateError('segno-wifi-ctl: authentication failed');
  }

  @override
  Future<void> disconnect() async {}

  @override
  Future<void> forget(String ssid) async {}

  @override
  Future<void> setEnabled({required bool enabled}) async {}

  @override
  Future<void> setAutoConnect(String ssid, {required bool enabled}) async {}

  @override
  Future<void> changePassword(String ssid, String psk) async {}

  @override
  Future<bool> checkConnectivity() async => internet;
}

/// The Settings pages and the FX pedal assignments in the states worth
/// checking by eye (a list open, a refusal, an update in each phase).
/// Author-machine goldens, like the other suites here;
/// each page's resting state is in `settings_destinations_screenshots_test`.
void main() {
  late TempoSettings tempoOwner;
  setUpAll(() {
    registerFallbackValue(const EngineConfig());
    registerFallbackValue(MonitorMode.off);
  });
  const fontDir =
      '/Users/Tomas/development/flutter/bin/cache/artifacts/material_fonts';
  final hasFonts = File('$fontDir/Roboto-Regular.ttf').existsSync();

  setUpAll(() async {
    if (!hasFonts) return;
    await loadScreenshotFont('Roboto', [
      '$fontDir/Roboto-Regular.ttf',
      '$fontDir/Roboto-Medium.ttf',
      '$fontDir/Roboto-Bold.ttf',
    ]);
    await loadScreenshotFont('MaterialIcons', [
      '$fontDir/MaterialIcons-Regular.otf',
    ]);
    // The console's own faces set state words and disclosure markers in the
    // bundled mono face. Without it they render as tofu and the golden is
    // useless for the eyeballing it exists to support.
    await loadScreenshotFont(SurfaceTheme.monoFont, [
      'assets/fonts/JetBrainsMono-Regular.ttf',
      'assets/fonts/JetBrainsMono-Medium.ttf',
    ]);
    // The same argument for the PROPORTIONAL face, which these previews had
    // been rendering in Roboto — the harness fallback — rather than in the
    // Inter the app actually ships. Two costs, and the second is the one that
    // matters: every letterform in every console golden was the wrong one, and
    // Roboto's cache subset has no `→`, so Signal's routing lines came out as
    // tofu boxes. A preview that draws a different typeface than the product
    // cannot be eyeballed against the mockups, which is its whole job.
    await loadScreenshotFont(SurfaceTheme.displayFont, [
      'assets/fonts/Inter-Regular.ttf',
      'assets/fonts/Inter-Medium.ttf',
      'assets/fonts/Inter-SemiBold.ttf',
      'assets/fonts/Inter-Bold.ttf',
    ]);
    await loadScreenshotFont('Arimo', ['assets/fonts/Arimo-Regular.ttf']);
    // And the rail's own glyphs. A package font is bundled from the package's
    // pubspec at run time but not by the test harness, so every rail icon and
    // the brightness sun rendered as a tofu box in these previews — the same
    // failure the mono and Inter loads above exist to prevent, and the one
    // that makes an icon golden worthless.
    //
    // Registered under the name Flutter resolves a package font by, since
    // that is what `IconData(fontPackage:)` asks the engine for.
    await loadScreenshotFont('packages/lucide_icons_flutter/Lucide', [
      packageAssetPath('lucide_icons_flutter', 'assets/lucide.ttf'),
    ]);
  });

  Future<void> size(WidgetTester tester) async {
    tester.view
      ..physicalSize = const Size(1920, 1080)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  /// The providers the app gives every page from `App`, which a preview has
  /// to stand up itself.
  ({
    ControlCubit control,
    PedalCubit pedal,
    MidiSetupCubit midi,
    LooperRepository looper,
    LooperBloc bloc,
    TracksCubit tracks,
    RecordTimingCubit quantize,
    InputsCubit inputs,
    AudioSetupCubit audio,
    TempoCubit tempo,
    RecordSettings options,
    MonitorCubit monitor,
  })
  controlProviders(
    WidgetTester tester, {
    MidiConnection connection = const MidiConnection(),
    LooperState looperState = const LooperState(),
  }) {
    final looper = _MockLooperRepository();
    when(() => looper.sessionRevision).thenReturn(0);
    stubScreenshotSettings(looper);
    when(() => looper.recordStartSettingsFailures).thenAnswer(
      (_) => const Stream<EngineResult>.empty(),
    );
    when(() => looper.clickModeFailures).thenAnswer(
      (_) => const Stream<EngineResult>.empty(),
    );
    when(() => looper.clickVolumeFailures).thenAnswer(
      (_) => const Stream<EngineResult>.empty(),
    );
    when(() => looper.recordTimingFailures).thenAnswer(
      (_) => const Stream<EngineResult>.empty(),
    );
    when(() => looper.lengthSettingsFailures).thenAnswer(
      (_) => const Stream<EngineResult>.empty(),
    );
    when(() => looper.inputSetup).thenReturn(const InputSetup.empty());
    when(() => looper.laneCount(any())).thenAnswer((call) {
      final channel = call.positionalArguments.first as int;
      return looper.state.tracks
              .where((track) => track.channel == channel)
              .firstOrNull
              ?.lanes
              .length ??
          0;
    });
    when(() => looper.fxReplayConfirmed).thenAnswer(
      (_) => const Stream<({int mixGeneration, int sessionRevision})>.empty(),
    );
    final looperStates = StreamController<LooperState>.broadcast();
    addTearDown(looperStates.close);
    when(() => looper.monitorChanges).thenAnswer(
      (_) => const Stream<int>.empty(),
    );
    when(() => looper.monitorParamChanges).thenAnswer(
      (_) => const Stream<int>.empty(),
    );
    when(() => looper.looperState).thenAnswer((_) => looperStates.stream);
    when(
      () => looper.mixSettingsFailures,
    ).thenAnswer((_) => const Stream.empty());
    when(() => looper.mixGeneration).thenReturn(0);
    when(() => looper.state).thenReturn(
      LooperState(
        tracks: [for (var i = 0; i < 8; i++) Track(channel: i)],
        outputBusCount: 1,
        status: _previewStatus,
      ),
    );
    when(looper.allMonitors).thenReturn(const {});
    when(
      () => looper.setMonitorInputMode(
        input: any(named: 'input'),
        mode: any(named: 'mode'),
      ),
    ).thenReturn(EngineResult.ok);
    when(looper.allLaneChains).thenReturn(const {});
    when(looper.allTrackChains).thenReturn(const {});
    when(() => looper.trackEffects(any())).thenReturn(const []);
    when(() => looper.outputEffects(0)).thenAnswer((_) => _masterChain);
    when(() => looper.allTracksEffects).thenReturn(const []);
    when(() => looper.outputChainEnabled(any())).thenReturn(true);
    when(() => looper.allTracksChainEnabled).thenReturn(true);
    when(looper.allOutputChains).thenReturn(const {});
    // What `AUDIO / settings-device` draws: an interface the host reports in
    // both directions with its real channel counts, and the built-in pair.
    when(looper.devices).thenReturn(_previewDevices);
    when(looper.asioDrivers).thenReturn(const <AudioDevice>[]);
    when(looper.detectLoopback).thenReturn(
      const LoopbackInfo(
        available: true,
        kind: LoopbackKind.virtualDevice,
        deviceName: 'Scarlett 18i20',
      ),
    );
    // The saved config the cubit hydrates from — this is how the Scarlett is
    // the PINNED device without the preview having to open one.
    when(looper.stopEngine).thenReturn(EngineResult.ok);
    when(() => looper.startEngine(any())).thenReturn(EngineResult.ok);
    when(looper.measureLatency).thenReturn(EngineResult.ok);
    when(() => looper.lastEngineConfig).thenReturn(
      const EngineConfig(
        sampleRate: 48000,
        bufferFrames: 128,
        playbackDeviceId: 'scarlett-out',
        captureDeviceId: 'scarlett-in',
      ),
    );

    final devices = _MockMidiDevices();
    final connections = StreamController<MidiConnection>.broadcast();
    final activity = StreamController<void>.broadcast();
    addTearDown(connections.close);
    addTearDown(activity.close);
    when(() => devices.connections).thenAnswer((_) => connections.stream);
    when(() => devices.activity).thenAnswer((_) => activity.stream);
    when(() => devices.connection).thenReturn(connection);

    final settings = SettingsRepository(store: FakeKeyValueStore());
    final performance = PerformanceRepository(
      guards: GuardRegistry(),
      engine: FakeAudioEngine(),
      exportsRoot: () async => '.',
    );
    addTearDown(performance.dispose);
    final pedalRepository = PedalRepository(NoopPedalLink());
    final pedal = PedalCubit(pedal: pedalRepository);
    addTearDown(pedal.close);
    final fxPersistence = FxChainPersistence(looper: looper);
    final mixSettings = testMixSettings(looper, settings: settings);
    addTearDown(() => unawaited(mixSettings.close()));
    final ownedFade = testFadeSettings();
    final control = ControlCubit(
      fxPersistence: fxPersistence,
      looper: looper,
      mixSettings: mixSettings,
      pedal: pedalRepository,
      settings: settings,
      performance: performance,
      fadeSettings: ownedFade,
      ownedValues: OwnedValuePort(
        looper: looper,
        clickVolume: FakeClickVolumeControl(),
        clickMode: FakeClickModeControl(),
        recordStart: FakeRecordStartControl(),
        decay: FakeDecayControl(),
        oneShot: FakeOneShotControl(),
        recordLength: FakeRecordLengthControl(),
        recordTiming: FakeRecordTimingControl(),
        fade: ownedFade,
      ),
    );
    final midi = MidiSetupCubit(repository: devices);
    // The Loop settings providers. A mock bloc rather than a real one over
    // the mock repository: these previews exist to pin a specific transport,
    // and a real bloc would only ever show the repository's defaults.
    final bloc = _MockLooperBloc();
    whenListen(
      bloc,
      const Stream<LooperState>.empty(),
      initialState: looperState,
    );
    when(() => bloc.state).thenReturn(looperState);
    tempoOwner = TempoSettings(repository: looper, settings: settings);
    final closeTempoOwner = tempoOwner.close;
    addTearDown(() => unawaited(closeTempoOwner()));
    unawaited(tempoOwner.recordStartOwner.load());
    final tempo = TempoCubit(settings: tempoOwner);
    final options = RecordSettings(repository: looper, settings: settings);
    final tracks = TracksCubit(settings: settings);
    final inputs = InputsCubit(settings: settings, repository: looper);
    final quantizeOwner = RecordTimingSettings(
      repository: looper,
      settings: settings,
    );
    addTearDown(() => unawaited(quantizeOwner.close()));
    unawaited(quantizeOwner.load());
    final quantize = RecordTimingCubit(settings: quantizeOwner);
    final monitor = MonitorCubit(
      fxPersistence: fxPersistence,
      mixSettings: mixSettings,
      repository: looper,
      settings: settings,
    );
    final audio = AudioSetupCubit(
      repository: looper,
      settings: settings,
      // No re-enumeration: the preview's device list never changes, and a
      // periodic timer live for the length of the test body fails the
      // binding's own invariant check before any tearDown can cancel it.
      deviceRefreshInterval: Duration.zero,
    );
    addTearDown(() => unawaited(tracks.close()));
    addTearDown(() => unawaited(inputs.close()));
    addTearDown(() => unawaited(quantize.close()));
    addTearDown(() => unawaited(monitor.close()));
    addTearDown(() => unawaited(audio.close()));
    addTearDown(() => unawaited(control.close()));
    addTearDown(() => unawaited(midi.close()));
    addTearDown(() => unawaited(tempo.close()));
    addTearDown(() => unawaited(options.close()));
    return (
      control: control,
      pedal: pedal,
      midi: midi,
      looper: looper,
      bloc: bloc,
      tempo: tempo,
      options: options,
      tracks: tracks,
      quantize: quantize,
      inputs: inputs,
      audio: audio,
      monitor: monitor,
    );
  }

  /// The System pages' own providers. The app provides these from `App`; a
  /// preview has to stand them up too.
  ///
  /// The facts client is the FAKE at zero latency — that is the whole point of
  /// the seam: Storage and About are drivable, and photographable, from a
  /// desktop. Zero rather than the fake's own pretend latency because even a
  /// zero-duration delay schedules a timer a `testWidgets` body would wait on
  /// forever.
  ({
    WaveformWindowCubit waveform,
    HighContrastCubit contrast,
    RefreshRateCubit refresh,
    ConsoleFactsCubit facts,
    PedalCubit pedal,
    UpdateCubit update,
    DisplayBrightnessCubit brightness,
    IdleDimCubit idle,
  })
  systemProviders(
    WidgetTester tester, {
    required LooperRepository looper,
    required SettingsRepository settings,
    ConsoleFactsClient? client,
    UpdateState? updateState,
  }) {
    final waveform = WaveformWindowCubit(settings: settings);
    final contrast = HighContrastCubit(settings: settings);
    final refresh = RefreshRateCubit(repository: looper, settings: settings);
    final facts = ConsoleFactsCubit(
      client: client ?? FakeConsoleFactsClient(latency: Duration.zero),
      settings: settings,
    );
    final pedal = PedalCubit(
      pedal: PedalRepository(NoopPedalLink()),
    );
    final update = _MockUpdateCubit();
    whenListen(
      update,
      const Stream<UpdateState>.empty(),
      initialState: updateState ?? _consoleBuild,
    );
    addTearDown(() => unawaited(waveform.close()));
    addTearDown(() => unawaited(contrast.close()));
    addTearDown(() => unawaited(refresh.close()));
    addTearDown(() => unawaited(facts.close()));
    addTearDown(() => unawaited(pedal.close()));
    final brightness = DisplayBrightnessCubit(settings: settings);
    addTearDown(() => unawaited(brightness.close()));
    final idle = IdleDimCubit(settings: settings);
    addTearDown(() => unawaited(idle.close()));
    return (
      brightness: brightness,
      idle: idle,
      waveform: waveform,
      contrast: contrast,
      refresh: refresh,
      facts: facts,
      pedal: pedal,
      update: update,
    );
  }

  Future<void> pumpPage(
    WidgetTester tester, {
    required Widget page,
    WifiRepository? wifi,
    ({
      WaveformWindowCubit waveform,
      HighContrastCubit contrast,
      RefreshRateCubit refresh,
      ConsoleFactsCubit facts,
      PedalCubit pedal,
      UpdateCubit update,
      DisplayBrightnessCubit brightness,
      IdleDimCubit idle,
    })?
    system,
    ({
      ControlCubit control,
      PedalCubit pedal,
      MidiSetupCubit midi,
      LooperRepository looper,
      LooperBloc bloc,
      TracksCubit tracks,
      RecordTimingCubit quantize,
      InputsCubit inputs,
      AudioSetupCubit audio,
      TempoCubit tempo,
      RecordSettings options,
      MonitorCubit monitor,
    })?
    control,
  }) {
    final rig = control ?? controlProviders(tester);
    final tuner = TunerCubit(
      repository: rig.looper,
      settings: TunerSettings(
        settings: SettingsRepository(store: FakeKeyValueStore()),
      ),
    );
    addTearDown(() => unawaited(tuner.close()));
    return tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: _theme(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: MultiRepositoryProvider(
          providers: [
            RepositoryProvider.value(
              value:
                  wifi ?? const WifiRepository(client: UnsupportedWifiClient()),
            ),
            RepositoryProvider<LooperRepository>.value(value: rig.looper),
            RepositoryProvider<DisplayOutputs>.value(
              value: const UnknownDisplayOutputs(),
            ),
          ],
          child: MultiBlocProvider(
            providers: [
              BlocProvider.value(value: tuner),
              BlocProvider.value(value: rig.control),
              if (system == null) BlocProvider.value(value: rig.pedal),
              BlocProvider.value(value: rig.midi),
              BlocProvider<LooperBloc>.value(value: rig.bloc),
              BlocProvider.value(value: rig.tempo),
              BlocProvider(
                create: (_) => RecordOptionsCubit(settings: rig.options),
              ),
              BlocProvider.value(value: rig.tracks),
              BlocProvider.value(value: rig.quantize),
              BlocProvider.value(value: rig.inputs),
              BlocProvider.value(value: rig.audio),
              BlocProvider.value(value: rig.monitor),
              if (system case final s?) ...[
                BlocProvider.value(value: s.waveform),
                BlocProvider.value(value: s.contrast),
                BlocProvider.value(value: s.refresh),
                BlocProvider.value(value: s.facts),
                BlocProvider.value(value: s.pedal),
                BlocProvider.value(value: s.update),
                BlocProvider.value(value: s.brightness),
                BlocProvider.value(value: s.idle),
              ],
            ],
            child: page,
          ),
        ),
      ),
    );
  }

  /// Opens the Network page over [client] (pen 29), settled.
  Future<void> pumpNetwork(
    WidgetTester tester,
    _PreviewWifiClient client,
  ) async {
    await size(tester);
    await pumpPage(
      tester,
      page: const NetworkSettingsPage(),
      wifi: WifiRepository(client: client),
    );
    await tester.pumpAndSettle();
  }

  /// Types [text] on the password sheet's keyboard.
  Future<void> typePassword(WidgetTester tester, String text) async {
    for (final key in text.split('')) {
      await tester.tap(find.widgetWithText(InkWell, key).first);
      await tester.pump();
    }
  }

  testWidgets('Network page, 29/01 connected', (tester) async {
    await pumpNetwork(tester, _PreviewWifiClient());
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/settings_network_wifi.png'),
    );
  }, skip: !hasFonts);

  testWidgets('Network page, 29/02 join a network', (tester) async {
    await pumpNetwork(tester, _PreviewWifiClient());
    await tester.tap(find.byKey(const Key('network_row_Rehearsal Room')));
    await tester.pumpAndSettle();
    await typePassword(tester, 'rehearse');
    expect(find.byKey(const Key('network_password_sheet')), findsOneWidget);
    // The sheet rides in the route overlay, above the Scaffold.
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/settings_network_wifi_join.png'),
    );
  }, skip: !hasFonts);

  testWidgets('Network page, 29/03 connecting', (tester) async {
    await pumpNetwork(tester, _PreviewWifiClient(holdJoins: true));
    await tester.tap(find.byKey(const Key('network_row_Rehearsal Room')));
    await tester.pumpAndSettle();
    await typePassword(tester, 'rehearse');
    await tester.tap(find.widgetWithText(InkWell, 'Connect').last);
    // The progress bar sweeps for as long as the join runs: no settling.
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byKey(const Key('network_connecting_dialog')), findsOneWidget);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/settings_network_wifi_connecting.png'),
    );
  }, skip: !hasFonts);

  testWidgets('Network page, 29/04 incorrect password', (tester) async {
    await pumpNetwork(tester, _PreviewWifiClient(refuseKey: true));
    await tester.tap(find.byKey(const Key('network_row_Rehearsal Room')));
    await tester.pumpAndSettle();
    await typePassword(tester, 'wrongkey');
    await tester.tap(find.widgetWithText(InkWell, 'Connect').last);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('network_password_message')), findsOneWidget);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/settings_network_wifi_incorrect.png'),
    );
  }, skip: !hasFonts);

  testWidgets('Network page, 29/05 saved network controls', (tester) async {
    await pumpNetwork(tester, _PreviewWifiClient());
    await tester.tap(find.byKey(const Key('network_manage')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('network_details_dialog')), findsOneWidget);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/settings_network_wifi_details.png'),
    );
  }, skip: !hasFonts);

  testWidgets('Network page, 29/06 connection lost', (tester) async {
    await pumpNetwork(tester, _PreviewWifiClient(connected: false));
    expect(find.byKey(const Key('network_reconnect')), findsOneWidget);
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/settings_network_wifi_lost.png'),
    );
  }, skip: !hasFonts);

  testWidgets('Network page, 29/07 Wi-Fi off', (tester) async {
    await pumpNetwork(tester, _PreviewWifiClient(enabled: false));
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/settings_network_wifi_off.png'),
    );
  }, skip: !hasFonts);

  testWidgets('Network page, 29/08 connected without internet', (
    tester,
  ) async {
    await pumpNetwork(tester, _PreviewWifiClient(internet: false));
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/settings_network_wifi_no_internet.png'),
    );
  }, skip: !hasFonts);

  testWidgets('Network page, forget confirm', (tester) async {
    await pumpNetwork(tester, _PreviewWifiClient());
    await tester.tap(find.byKey(const Key('network_manage')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('network_forget')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('network_forget_dialog')), findsOneWidget);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/settings_network_wifi_forget.png'),
    );
  }, skip: !hasFonts);

  testWidgets('FX pedal assignments with a switch selected', (
    tester,
  ) async {
    await size(tester);
    final rig = controlProviders(tester);
    await rig.control.setGlobalBindings(
      PedalBindingSet([
        PedalBinding(
          key: const PedalBindingKey(button: PedalButton.recPlay),
          target: const FxChainTarget(_master).canonicalString(),
        ),
      ]),
    );
    await pumpPage(
      tester,
      page: const FxPedalAssignmentsPage(),
      control: rig,
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.byKey(const Key('pedal_switch_track1')));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/fx_pedal_assignments.png'),
    );

    // And again on bank B, where the same four caps drive tracks 5-8.
    await tester.tap(find.text('B'));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/fx_pedal_assignments_bank_b.png'),
    );
  }, skip: !hasFonts);

  /// The rig the Audio previews draw: an open device on a 48k/128 clock, with
  /// the latency measured and a record offset applied.
  const audioRig = LooperState(tracks: [Track()], status: _previewStatus);

  Future<
    ({
      ControlCubit control,
      PedalCubit pedal,
      MidiSetupCubit midi,
      LooperRepository looper,
      LooperBloc bloc,
      TracksCubit tracks,
      RecordTimingCubit quantize,
      InputsCubit inputs,
      AudioSetupCubit audio,
      TempoCubit tempo,
      RecordSettings options,
      MonitorCubit monitor,
    })
  >
  pumpAudio(WidgetTester tester) async {
    await size(tester);
    final providers = controlProviders(tester, looperState: audioRig);
    // Two of the eighteen sockets have been given names, which is what the
    // Device row's `2 named` counts.
    await providers.inputs.rename(0, 'guitar');
    await providers.inputs.rename(1, 'mic');
    await pumpPage(
      tester,
      page: const DeviceSettingsPage(),
      control: providers,
    );
    await tester.pumpAndSettle();
    return providers;
  }

  testWidgets('Device page, the device list open', (
    tester,
  ) async {
    await pumpAudio(tester);
    // Opened, because the per-device channel counts are the part worth
    // pinning: they read 0 in / 0 out until the engine started asking.
    await tester.tap(find.byKey(const Key('audio_device_row')));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/settings_device_device_list.png'),
    );
  }, skip: !hasFonts);

  testWidgets('Device page, the rate and buffer grids', (
    tester,
  ) async {
    await pumpAudio(tester);
    await tester.tap(find.byKey(const Key('audio_rate_row')));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/settings_device_rate.png'),
    );
  }, skip: !hasFonts);

  testWidgets('Device page, the named inputs', (tester) async {
    await pumpAudio(tester);
    await tester.tap(find.byKey(const Key('audio_inputs_row')));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/settings_device_inputs.png'),
    );
  }, skip: !hasFonts);

  testWidgets('Device page, the loop cap open', (
    tester,
  ) async {
    await pumpAudio(tester);
    await tester.tap(find.byKey(const Key('audio_max_loop_row')));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/settings_device_max_loop.png'),
    );
  }, skip: !hasFonts);

  testWidgets('Device page, a config the device refused', (tester) async {
    // The open SUCCEEDS and the device runs 48 anyway — the negotiation this
    // banner is for. (A device that will not open at all is a different state
    // and a different banner: `audio_open_failed_banner`, which names the
    // engine's error rather than a rate nothing asked to change.) The
    // selection has snapped back to what the device gave, so the banner is the
    // only place the request is still named.
    await pumpAudio(tester);
    await tester.tap(find.byKey(const Key('audio_rate_row')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('audio_sample_rate_96000')));
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/settings_device_refused.png'),
    );
  }, skip: !hasFonts);

  /// Mounts [page], one of the pages that show the System bodies.
  Future<ConsoleFactsCubit> pumpSystem(
    WidgetTester tester,
    Widget page, {
    ConsoleFactsClient? client,
    UpdateState? updateState,
  }) async {
    await size(tester);
    final settings = SettingsRepository(store: FakeKeyValueStore());
    final rig = controlProviders(tester, looperState: audioRig);
    final system = systemProviders(
      tester,
      looper: rig.looper,
      settings: settings,
      client: client,
      updateState: updateState,
    );
    await pumpPage(tester, page: page, control: rig, system: system);
    await tester.pumpAndSettle();
    return system.facts;
  }

  testWidgets('Displays page, the second window did not open', (tester) async {
    await pumpSystem(tester, const DisplaysSettingsPage());
    // The failure the app shell reports, beside the setting it is about —
    // never a toast once this page is open.
    tester
        .element(find.byType(DisplaysSettingsPage))
        .read<WaveformWindowCubit>()
        .reportOpenFailed();
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/settings_displays_waveform_failed.png'),
    );
  }, skip: !hasFonts);

  testWidgets('Updates page, software updates', (tester) async {
    await pumpSystem(
      tester,
      const UpdatesSettingsPage(),
      updateState: _consoleBuild.copyWith(phase: UpdatePhase.upToDate),
    );
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/settings_updates_idle.png'),
    );
  }, skip: !hasFonts);

  testWidgets('Updates page, an install that was cut off', (tester) async {
    await pumpSystem(
      tester,
      const UpdatesSettingsPage(),
      updateState: _consoleBuild.copyWith(
        phase: UpdatePhase.interrupted,
        interrupted: Version.parse('0.1.1'),
        rollback: (
          attempted: Version.parse('0.1.1'),
          restored: Version.parse('0.1.0'),
        ),
      ),
    );
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/settings_updates_paused.png'),
    );
  }, skip: !hasFonts);

  testWidgets('Updates page, an update on offer', (tester) async {
    await pumpSystem(
      tester,
      const UpdatesSettingsPage(),
      updateState: _consoleBuild.copyWith(
        phase: UpdatePhase.available,
        available: UpdateManifest(
          version: Version.parse('0.1.1'),
          bundle: 'b',
          channel: 'experimental',
        ),
      ),
    );
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/settings_updates_available.png'),
    );
  }, skip: !hasFonts);

  testWidgets('Updates page, staging to the standby system', (tester) async {
    await pumpSystem(
      tester,
      const UpdatesSettingsPage(),
      updateState: _consoleBuild.copyWith(
        phase: UpdatePhase.downloading,
        progress: 0.42,
        available: UpdateManifest(
          version: Version.parse('0.1.1'),
          bundle: 'b',
          channel: 'experimental',
        ),
      ),
    );
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/settings_updates_downloading.png'),
    );
  }, skip: !hasFonts);

  testWidgets('Updates page, staged and waiting for a restart', (
    tester,
  ) async {
    await pumpSystem(
      tester,
      const UpdatesSettingsPage(),
      updateState: _consoleBuild.copyWith(
        phase: UpdatePhase.staged,
        available: UpdateManifest(
          version: Version.parse('0.1.1'),
          bundle: 'b',
          channel: 'experimental',
        ),
      ),
    );
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/settings_updates_staged.png'),
    );
  }, skip: !hasFonts);

  testWidgets('Updates page, the check failed', (tester) async {
    await pumpSystem(
      tester,
      const UpdatesSettingsPage(),
      updateState: _consoleBuild.copyWith(
        phase: UpdatePhase.error,
        errorMessage: 'could not reach the update server.',
      ),
    );
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/settings_updates_error.png'),
    );
  }, skip: !hasFonts);

  /// Puts the licence registry in the state both LEGAL goldens are drawn
  /// against: exactly these three packages, and nothing an earlier test left.
  ///
  /// Called by BOTH of them rather than once by whichever runs first. The
  /// registry is process-global and accumulates, so a golden that inherits its
  /// predecessor's registration passes in file order and fails the moment it
  /// runs alone, under `--plain-name`, or with a randomised ordering seed —
  /// and the About row draws the COUNT, so an inherited registry is an
  /// inherited pixel.
  void seedLicences() {
    LicenseRegistry.reset();
    LicenseRegistry.addLicense(
      () => Stream.fromIterable([
        const LicenseEntryWithLineBreaks(
          ['segno'],
          'GNU GENERAL PUBLIC LICENSE\n\nVersion 3, 29 June 2007\n\nThis '
          'program is free software: you can redistribute it and/or modify '
          'it under the terms of the GNU General Public License as '
          'published by the Free Software Foundation, either version 3 of '
          'the License, or (at your option) any later version.',
        ),
        const LicenseEntryWithLineBreaks(['miniaudio'], 'Public domain.'),
        const LicenseEntryWithLineBreaks(['vst3sdk'], 'MIT License'),
      ]),
    );
  }

  testWidgets('About page, the open-source notices panel', (tester) async {
    seedLicences();
    await pumpSystem(tester, const AboutSettingsPage());
    await tester.tap(find.byKey(const Key('system_about_notices')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('console_licence_segno')));
    await tester.pumpAndSettle();

    await expectLater(
      // MaterialApp, not Scaffold: the panel is a route in the navigator's
      // overlay, which sits ABOVE the Scaffold rather than inside it.
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/settings_about_licences.png'),
    );
  }, skip: !hasFonts);

  testWidgets('About page', (tester) async {
    seedLicences();
    await pumpSystem(tester, const AboutSettingsPage());
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/settings_about.png'),
    );
  }, skip: !hasFonts);
}
