@Tags(['screenshots'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:controller_repository/controller_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:midi_device_repository/midi_device_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:performance_repository/performance_repository.dart';
import 'package:routing_graph/routing_graph.dart';
import 'package:segno/app/fx_chain_persistence.dart';
import 'package:segno/app/segno_navigator.dart';
import 'package:segno/audio_setup/cubit/midi_setup_cubit.dart';
import 'package:segno/control/binding/control_value_target.dart';
import 'package:segno/control/binding/fx_binding_target.dart';
import 'package:segno/control/cubit/control_cubit.dart';
import 'package:segno/control/view/midi_controls/midi_controls_page.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/cubit/settings_tray_cubit.dart';
import 'package:segno/looper/cubit/tracks_cubit.dart';
import 'package:segno/theme/theme.dart';
import 'package:settings_repository/settings_repository.dart';

import '../helpers/helpers.dart';

class _MockLooper extends Mock implements LooperRepository {}

class _MockMidiDevices extends Mock implements MidiDeviceRepository {}

class _Store extends FakeKeyValueStore {
  Completer<void>? gate;
  bool refuse = false;

  @override
  Future<void> setString(String key, String value) async {
    if (key == 'midi.configuration') {
      await gate?.future;
      if (refuse) throw const FileSystemException('disk full');
    }
    await super.setString(key, value);
  }
}

final _source = MidiSource(
  device: 'usb',
  kind: ControllerSourceKind.midiCc,
  number: 21,
  channel: 0,
);

MidiMapping _mapping() => MidiMapping(
  id: 'm1',
  source: _source,
  behavior: MidiBehavior.continuous,
  controls: [
    MidiParameterControl(
      key: const TrackVolumeTarget(0).canonicalString(),
      low: 0.2,
      high: 0.8,
    ),
  ],
);

const _connection = MidiConnection(
  devices: [MidiDevice(id: 'usb', name: 'USB controller')],
  selectedId: 'usb',
  selectedName: 'USB controller',
  status: MidiConnectionStatus.connected,
);

/// Author-side images of the real MIDI screens; CI does not claim visual proof.
void main() {
  final fontDir = Platform.environment['SEGNO_SCREENSHOT_FONT_DIR'];
  final hasFonts =
      fontDir != null && File('$fontDir/Roboto-Regular.ttf').existsSync();
  setUpAll(() async {
    if (!hasFonts) return;
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
  late _MockLooper looper;
  late _MockMidiDevices devices;
  late StreamController<LooperState> looperStates;
  late StreamController<MidiConnection> connections;
  late StreamController<MidiInputMessage> messages;
  late _Store store;
  late ControlCubit control;
  late SettingsTrayCubit tray;

  setUp(() {
    looper = _MockLooper();
    devices = _MockMidiDevices();
    looperStates = StreamController<LooperState>.broadcast();
    connections = StreamController<MidiConnection>.broadcast();
    messages = StreamController<MidiInputMessage>.broadcast();
    store = _Store();
    when(() => looper.looperState).thenAnswer((_) => looperStates.stream);
    when(() => looper.state).thenReturn(
      LooperState(
        tracks: [for (var i = 0; i < 8; i++) Track(channel: i)],
        status: const EngineStatus(sampleRate: 48000),
      ),
    );
    when(() => looper.sessionRevision).thenReturn(1);
    when(() => looper.mixGeneration).thenReturn(1);
    when(() => looper.laneCount(any())).thenReturn(1);
    when(() => looper.inputSetup).thenReturn(const InputSetup.empty());
    when(() => looper.mixSettingsSnapshot).thenReturn(MixSettingsSnapshot());
    when(() => looper.fxRecipesSettled).thenReturn(true);
    when(() => looper.mixSettingsSettled).thenReturn(true);
    when(() => looper.allMonitors()).thenReturn(const {});
    when(() => looper.allLaneChains()).thenReturn(const {});
    when(() => looper.allTracksEffects).thenReturn(const []);
    when(() => looper.outputEffects(any())).thenReturn(const []);
    when(() => looper.trackEffects(any())).thenReturn(const []);
    when(
      () => looper.allTrackChains(),
    ).thenReturn(const {0: FxChainEnvelope()});
    when(() => looper.trackChainEnabled(any())).thenReturn(true);
    when(() => looper.setMasterGain(any())).thenReturn(EngineResult.ok);
    when(() => devices.connection).thenReturn(_connection);
    when(() => devices.session).thenReturn(const MidiInputSession('usb', 1));
    when(() => devices.connections).thenAnswer((_) => connections.stream);
    when(() => devices.messages).thenAnswer((_) => messages.stream);
    when(() => devices.activity).thenAnswer((_) => const Stream<void>.empty());
    when(() => devices.select(any())).thenAnswer((_) async {});
  });

  tearDown(() async {
    await looperStates.close();
    await connections.close();
    await messages.close();
  });

  Future<void> pump(
    WidgetTester tester, {
    bool seeded = false,
    bool malformed = false,
    bool routeEntry = false,
    MidiMapping? savedMapping,
  }) async {
    tester.view
      ..physicalSize = const Size(1920, 1080)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final settings = SettingsRepository(store: store);
    tray = SettingsTrayCubit(settings: settings);
    addTearDown(() => unawaited(tray.close()));
    if (malformed) {
      await store.setString('midi.configuration', '{bad json');
    }
    if (seeded || savedMapping != null) {
      await settings.saveMidiConfiguration(
        jsonEncode({
          'version': 1,
          'enabled': true,
          'mappings': [(savedMapping ?? _mapping()).toJson()],
        }),
      );
    }
    final performance = PerformanceRepository(
      engine: FakeAudioEngine(),
      exportsRoot: () async => '.',
    );
    addTearDown(performance.dispose);
    final pedal = PedalRepository(NoopPedalLink());
    addTearDown(() => unawaited(pedal.dispose()));
    final mix = testMixSettings(looper, settings: settings);
    addTearDown(() => unawaited(mix.close()));
    control = ControlCubit(
      looper: looper,
      pedal: pedal,
      settings: settings,
      performance: performance,
      mixSettings: mix,
      fxPersistence: FxChainPersistence(looper: looper),
      midiDevices: devices,
    );
    final tracks = TracksCubit(settings: settings);
    final midi = MidiSetupCubit(repository: devices);
    addTearDown(() => unawaited(control.close()));
    addTearDown(() => unawaited(tracks.close()));
    addTearDown(() => unawaited(midi.close()));
    await control.load();
    await tester.pumpWidget(
      RepositoryProvider<LooperRepository>.value(
        value: looper,
        child: MultiBlocProvider(
          providers: [
            BlocProvider.value(value: control),
            BlocProvider.value(value: tracks),
            BlocProvider.value(value: midi),
          ],
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            navigatorKey: routeEntry ? segnoNavigatorKey : null,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            theme: ThemeData(
              fontFamily: SurfaceTheme.displayFont,
              brightness: Brightness.dark,
              extensions: [
                SurfaceTheme.dark,
                routingGraphThemeFromSurface(SurfaceTheme.dark),
              ],
            ),
            home: routeEntry
                ? const Scaffold(body: Text('Stage root'))
                : const MidiControlsPage(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester, String key) async {
    await tester.tap(find.byKey(Key(key)));
    await tester.pumpAndSettle();
  }

  Future<void> shot(WidgetTester tester, String name) async {
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MidiControlsPage),
      matchesGoldenFile('goldens/midi_controls_$name.png'),
    );
  }

  group('native MIDI references', () {
    testWidgets('connected controls', (tester) async {
      await pump(tester, seeded: true);
      await shot(tester, 'connected');
    });
    testWidgets('continuous range editor', (tester) async {
      await pump(tester, seeded: true);
      await tap(tester, 'midi_row_edit_m1');
      await shot(tester, 'continuous');
    });
    testWidgets('activation and parameter button', (tester) async {
      final target = const FxChainTarget(
        FxAddress(stage: FxStage.track),
      ).canonicalString();
      await pump(
        tester,
        savedMapping: MidiMapping(
          id: 'm1',
          source: _source,
          behavior: MidiBehavior.momentary,
          controls: [
            MidiParameterControl(key: target, low: 0, high: 1),
            MidiParameterControl(
              key: const TrackVolumeTarget(0).canonicalString(),
              low: 0.3,
              high: 0.8,
            ),
          ],
        ),
      );
      await tap(tester, 'midi_row_edit_m1');
      await shot(tester, 'momentary');
    });
    testWidgets('Mixer gain mappings use physical units', (tester) async {
      when(() => looper.state).thenReturn(
        LooperState(
          tracks: [for (var i = 0; i < 8; i++) Track(channel: i)],
          status: const EngineStatus(
            sampleRate: 48000,
            inputChannels: 2,
            outputChannels: 2,
          ),
          outputBusCount: 1,
        ),
      );
      await pump(
        tester,
        savedMapping: MidiMapping(
          id: 'm1',
          source: _source,
          behavior: MidiBehavior.continuous,
          controls: [
            for (final target in const [
              TrackVolumeTarget(0),
              LaneVolumeTarget(1, 0),
              MonitorVolumeTarget(0),
            ])
              MidiParameterControl(
                key: target.canonicalString(),
                low: 0.5,
                high: 1,
              ),
          ],
        ),
      );
      await tap(tester, 'midi_row_edit_m1');
      await shot(tester, 'mixer_gains');
    });
    testWidgets('Mixer pan and output mappings use physical units', (
      tester,
    ) async {
      when(() => looper.state).thenReturn(
        LooperState(
          tracks: [for (var i = 0; i < 8; i++) Track(channel: i)],
          status: const EngineStatus(sampleRate: 48000, outputChannels: 2),
          outputBusCount: 1,
        ),
      );
      await pump(
        tester,
        savedMapping: MidiMapping(
          id: 'm1',
          source: _source,
          behavior: MidiBehavior.continuous,
          controls: [
            for (final target in const [
              TrackPanTarget(0),
              OutputBalanceTarget(0),
              OutputLevelTarget(0),
            ])
              MidiParameterControl(
                key: target.canonicalString(),
                low: 0.5,
                high: 1,
              ),
          ],
        ),
      );
      await tap(tester, 'midi_row_edit_m1');
      await shot(tester, 'mixer_placement');
    });
    testWidgets('explicit format before learning', (tester) async {
      await pump(tester);
      await tap(tester, 'midi_add_mapping');
      await shot(tester, 'formats');
    });
    testWidgets('waiting for the learned source', (tester) async {
      await pump(tester);
      await tap(tester, 'midi_add_mapping');
      await tap(tester, 'midi_format_standard');
      await shot(tester, 'listening');
    });
    testWidgets('unavailable target stays repairable', (tester) async {
      await pump(
        tester,
        savedMapping: MidiMapping(
          id: 'm1',
          source: _source,
          behavior: MidiBehavior.continuous,
          controls: [
            MidiParameterControl(
              key: const FxParamTarget(
                address: FxAddress(stage: FxStage.track),
                slotId: 'missing-delay',
                param: 0,
              ).canonicalString(),
              low: 0.2,
              high: 0.7,
            ),
          ],
        ),
      );
      await tap(tester, 'midi_row_edit_m1');
      await shot(tester, 'missing');
    });
    testWidgets('failed off stays paused with recovery choices', (
      tester,
    ) async {
      await pump(tester, seeded: true);
      store.refuse = true;
      await tap(tester, 'midi_control_enabled');
      expect(control.state.midiRemotePaused, isTrue);
      expect(find.byKey(const Key('midi_retry_off')), findsOneWidget);
      expect(find.byKey(const Key('midi_resume_on')), findsOneWidget);
      await shot(tester, 'paused');
    });
    testWidgets('damaged configuration remains recoverable', (tester) async {
      await pump(tester, malformed: true);
      await shot(tester, 'unavailable');
    });
    testWidgets('disconnection retains saved assignments', (tester) async {
      await pump(tester, seeded: true);
      const gone = MidiConnection(
        selectedId: 'usb',
        selectedName: 'USB controller',
        status: MidiConnectionStatus.deviceGone,
      );
      when(() => devices.connection).thenReturn(gone);
      connections.add(gone);
      await tester.pump();
      await tester.pumpAndSettle();
      await shot(tester, 'disconnected');
    });
  }, skip: !hasFonts);
}
