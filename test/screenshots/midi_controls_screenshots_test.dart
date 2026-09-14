@Tags(['screenshots'])
library;

import 'dart:async';
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
import 'package:segno/audio_setup/cubit/midi_setup_cubit.dart';
import 'package:segno/control/control.dart';
import 'package:segno/control/view/midi_controls/midi_controls_page.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/cubit/tracks_cubit.dart';
import 'package:segno/theme/theme.dart';
import 'package:settings_repository/settings_repository.dart';

import '../helpers/helpers.dart';
import '../pedal/helpers/fake_pedal_transport.dart';

class _MockLooperRepository extends Mock implements LooperRepository {}

class _MockMidiDevices extends Mock implements MidiDeviceRepository {}

const _usb = 'usb:controller';

const _connected = MidiConnection(
  devices: [
    MidiDevice(id: _usb, name: 'USB controller'),
    MidiDevice(id: 'din:in', name: 'MIDI In'),
  ],
  selectedId: _usb,
  selectedName: 'USB controller',
  status: MidiConnectionStatus.connected,
);

RawControllerInput _cc(int number, int value) => RawControllerInput(
  kind: ControllerSourceKind.midiCc,
  id: number,
  value: value,
);

/// The accepted MIDI controls page, drawn at the console's own size.
void main() {
  const fontDir =
      '/Users/Tomas/development/flutter/bin/cache/artifacts/material_fonts';
  // Author-machine goldens, like the other screenshot suites here: the
  // Material fonts come from the local SDK, so everywhere else this skips.
  final hasScreenshotFonts = File('$fontDir/Roboto-Regular.ttf').existsSync();

  setUpAll(() async {
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

  late _MockLooperRepository looper;
  late StreamController<LooperState> looperStates;
  late StreamController<MidiConnection> connections;
  late StreamController<RawControllerInput> messages;
  late _MockMidiDevices devices;
  late ControlCubit control;

  const delayMix = FxParamTarget(
    address: FxAddress(stage: FxStage.track),
    slotId: 'reverb-1',
    param: 0,
  );
  const volume = TrackVolumeTarget(0);

  setUp(() {
    looper = _MockLooperRepository();
    looperStates = StreamController<LooperState>.broadcast();
    connections = StreamController<MidiConnection>.broadcast();
    messages = StreamController<RawControllerInput>.broadcast();
    devices = _MockMidiDevices();
    when(() => devices.connections).thenAnswer((_) => connections.stream);
    when(() => devices.messages).thenAnswer((_) => messages.stream);
    when(
      () => devices.activity,
    ).thenAnswer((_) => const Stream<RawControllerInput>.empty());
    when(() => devices.select(any())).thenAnswer((_) async {});
    when(() => looper.looperState).thenAnswer((_) => looperStates.stream);
    when(() => looper.state).thenReturn(
      LooperState(
        tracks: [for (var i = 0; i < 8; i++) Track(channel: i)],
        status: const EngineStatus(sampleRate: 48000),
      ),
    );
    when(() => looper.trackEffects(any())).thenReturn(const []);
    when(() => looper.monitorEffects(any())).thenReturn(const []);
    when(() => looper.laneEffects(any(), any())).thenReturn(const []);
    when(() => looper.outputEffects(any())).thenReturn(const []);
    when(() => looper.allTracksEffects).thenReturn(const []);
    when(() => looper.allMonitors()).thenReturn(const {});
    when(() => looper.allLaneChains()).thenReturn(const {});
    when(
      () => looper.allTrackChains(),
    ).thenReturn(const {0: FxChainEnvelope()});
    const rack = FxRack(id: 'rack-1', name: 'Clean Rhythm', art: 'guitar');
    when(() => looper.trackEffects(0)).thenReturn([
      BuiltInEffect(
        type: TrackEffectType.drive,
        slotId: 'drive-1',
        rack: rack,
        module: 'Overdrive',
      ),
      BuiltInEffect(
        type: TrackEffectType.reverb,
        slotId: 'reverb-1',
        rack: rack,
        module: 'Reverb',
      ),
    ]);
    when(() => looper.trackChainEnabled(any())).thenReturn(true);
    when(() => looper.setMasterGain(any())).thenReturn(EngineResult.ok);
    when(
      () => looper.setVolume(any(), channel: any(named: 'channel')),
    ).thenReturn(EngineResult.ok);
  });

  tearDown(() {
    // Not awaited: the page's own subscriptions are cancelled when the tree
    // is torn down, after this runs, and awaiting a close with a listener
    // still attached never completes under the fake clock.
    unawaited(looperStates.close());
    unawaited(connections.close());
    unawaited(messages.close());
  });

  Future<void> pump(
    WidgetTester tester, {
    MidiConnection connection = _connected,
    List<MidiMapping> mappings = const [],
  }) async {
    tester.view
      ..physicalSize = const Size(1920, 1080)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    when(() => devices.connection).thenReturn(connection);

    final settings = SettingsRepository(store: FakeKeyValueStore());
    final performance = PerformanceRepository(
      engine: FakeAudioEngine(),
      exportsRoot: () async => '.',
    );
    addTearDown(performance.dispose);
    final pedal = PedalRepository(FakePedalTransport());
    addTearDown(() => unawaited(pedal.dispose()));
    control = ControlCubit(
      looper: looper,
      pedal: pedal,
      settings: settings,
      performance: performance,
      midiDevices: devices,
      keepAliveInterval: Duration.zero,
    );
    final tracks = TracksCubit(settings: settings);
    final midi = MidiSetupCubit(repository: devices);
    addTearDown(() => unawaited(control.close()));
    addTearDown(() => unawaited(tracks.close()));
    addTearDown(() => unawaited(midi.close()));
    await control.load();
    for (final mapping in mappings) {
      await control.saveMidiMapping(mapping);
    }
    connections.add(connection);

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: ThemeData(
          fontFamily: SurfaceTheme.displayFont,
          extensions: [
            SurfaceTheme.dark,
            routingGraphThemeFromSurface(SurfaceTheme.dark),
          ],
        ),
        home: MultiRepositoryProvider(
          providers: [
            RepositoryProvider<LooperRepository>.value(value: looper),
            RepositoryProvider<MidiDeviceRepository>.value(value: devices),
          ],
          child: MultiBlocProvider(
            providers: [
              BlocProvider.value(value: control),
              BlocProvider.value(value: tracks),
              BlocProvider.value(value: midi),
            ],
            child: const MidiControlsPage(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> shot(WidgetTester tester, String name) => expectLater(
    find.byType(MidiControlsPage),
    matchesGoldenFile('goldens/midi_controls_$name.png'),
  );

  Future<void> tap(WidgetTester tester, String key) async {
    await tester.tap(find.byKey(Key(key)));
    await tester.pumpAndSettle();
  }

  Future<void> send(WidgetTester tester, List<RawControllerInput> sent) async {
    sent.forEach(messages.add);
    await tester.pumpAndSettle();
  }

  final knob = MidiMapping(
    id: 'm1',
    source: const MidiSource(
      device: _usb,
      kind: ControllerSourceKind.midiCc,
      number: 21,
      channel: 0,
    ),
    behavior: MidiBehavior.continuous,
    controls: [
      MidiParameterControl(key: delayMix.canonicalString(), low: 0, high: 0.65),
    ],
  );

  final button = MidiMapping(
    id: 'm2',
    source: const MidiSource(
      device: _usb,
      kind: ControllerSourceKind.midiNote,
      number: 60,
      channel: 0,
    ),
    behavior: MidiBehavior.momentary,
    controls: [
      MidiParameterControl(
        key: delayMix.canonicalString(),
        low: 0.2,
        high: 0.65,
      ),
      const MidiActionControl(key: 'track:4'),
    ],
    enabled: false,
  );

  testWidgets('the mappings of the controller in use', (tester) async {
    await pump(tester, mappings: [knob, button]);
    await send(tester, [_cc(21, 90)]);
    await shot(tester, 'list');
  }, skip: !hasScreenshotFonts);

  testWidgets('a controller with no mappings', (tester) async {
    await pump(tester);
    await shot(tester, 'empty');
  }, skip: !hasScreenshotFonts);

  testWidgets('the controller in use is unplugged', (tester) async {
    await pump(
      tester,
      mappings: [knob],
      connection: _connected.copyWith(
        devices: const [MidiDevice(id: 'din:in', name: 'MIDI In')],
        status: MidiConnectionStatus.deviceGone,
      ),
    );
    await shot(tester, 'disconnected');
  }, skip: !hasScreenshotFonts);

  testWidgets('Add mapping listens for a control', (tester) async {
    await pump(tester);
    await tap(tester, 'midi_add_mapping');
    await shot(tester, 'learn');
  }, skip: !hasScreenshotFonts);

  testWidgets('a knob, opened from the list', (tester) async {
    await pump(tester, mappings: [knob]);
    await tap(tester, 'midi_row_edit_m1');
    await shot(tester, 'knob');
  }, skip: !hasScreenshotFonts);

  testWidgets('a button driving a parameter and an action', (tester) async {
    await pump(tester, mappings: [button.copyWith(enabled: true)]);
    await tap(tester, 'midi_row_edit_m2');
    await shot(tester, 'button');
  }, skip: !hasScreenshotFonts);

  testWidgets('a learned control that is already mapped', (tester) async {
    await pump(tester, mappings: [knob]);
    await tap(tester, 'midi_add_mapping');
    await send(tester, [_cc(21, 64)]);
    await shot(tester, 'conflict');
  }, skip: !hasScreenshotFonts);

  testWidgets('a 14-bit control learned onto track volume', (tester) async {
    await pump(tester);
    await tap(tester, 'midi_add_mapping');
    await tap(tester, 'midi_format');
    await tap(tester, 'midi_format_cc14');
    await send(tester, [_cc(22, 64), _cc(54, 1)]);
    await tap(tester, 'midi_add_control');
    await tap(tester, 'expression_kind_recordedTrack');
    await tap(tester, 'expression_destination_track:0');
    await tap(tester, 'expression_target_${volume.canonicalString()}');
    await shot(tester, 'cc14');
  }, skip: !hasScreenshotFonts);

  testWidgets('a relative control', (tester) async {
    await pump(tester);
    await tap(tester, 'midi_add_mapping');
    await tap(tester, 'midi_format');
    await tap(tester, 'midi_format_relative');
    await send(tester, [_cc(22, 127)]);
    await shot(tester, 'relative');
  }, skip: !hasScreenshotFonts);

  testWidgets('the message formats', (tester) async {
    await pump(tester);
    await tap(tester, 'midi_add_mapping');
    await tap(tester, 'midi_format');
    await shot(tester, 'formats');
  }, skip: !hasScreenshotFonts);

  testWidgets('the receive channels', (tester) async {
    await pump(tester, mappings: [knob]);
    await tap(tester, 'midi_row_edit_m1');
    await tap(tester, 'midi_channel');
    await shot(tester, 'channels');
  }, skip: !hasScreenshotFonts);

  testWidgets('choosing a destination', (tester) async {
    await pump(tester, mappings: [knob]);
    await tap(tester, 'midi_row_edit_m1');
    await tap(tester, 'midi_add_control');
    await tap(tester, 'expression_kind_recordedTrack');
    await shot(tester, 'destinations');
  }, skip: !hasScreenshotFonts);

  testWidgets('choosing a parameter', (tester) async {
    await pump(tester, mappings: [knob]);
    await tap(tester, 'midi_row_edit_m1');
    await tap(tester, 'midi_add_control');
    await tap(tester, 'expression_kind_recordedTrack');
    await tap(tester, 'expression_destination_track:0');
    await shot(tester, 'parameters');
  }, skip: !hasScreenshotFonts);
}
