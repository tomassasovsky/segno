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
import 'package:segno/looper/application/record_settings.dart';
import 'package:segno/looper/application/record_timing_settings.dart';
import 'package:segno/looper/cubit/playback_options_cubit.dart';
import 'package:segno/looper/cubit/record_options_cubit.dart';
import 'package:segno/looper/cubit/record_timing_cubit.dart';
import 'package:segno/looper/cubit/settings_tray_cubit.dart';
import 'package:segno/looper/cubit/tempo_cubit.dart';
import 'package:segno/looper/cubit/tracks_cubit.dart';
import 'package:segno/looper/model/one_shot.dart';
import 'package:segno/looper/model/overdub_decay.dart';
import 'package:segno/looper/model/record_start.dart';
import 'package:segno/theme/theme.dart';
import 'package:settings_repository/settings_repository.dart';

import '../helpers/helpers.dart';
import '../helpers/mock_click_tempo_settings.dart';
import '../helpers/mock_decay_playback_settings.dart';

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
  late RecordSettings record;
  late RecordTimingCubit timing;
  late RecordTiming confirmedTiming;
  late GridDivision rememberedDivision;
  late SettingsTrayCubit tray;

  setUp(() {
    looper = _MockLooper();
    devices = _MockMidiDevices();
    looperStates = StreamController<LooperState>.broadcast();
    connections = StreamController<MidiConnection>.broadcast();
    messages = StreamController<MidiInputMessage>.broadcast();
    store = _Store();
    confirmedTiming = RecordTiming.immediately;
    rememberedDivision = GridDivision.off;
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
    when(() => looper.lengthSettingsFailures).thenAnswer(
      (_) => const Stream<EngineResult>.empty(),
    );
    when(() => looper.recordLengthCaptureLocked).thenReturn(false);
    when(() => looper.recordTimingFailures).thenAnswer(
      (_) => const Stream<EngineResult>.empty(),
    );
    when(() => looper.recordTimingCaptureLocked).thenReturn(false);
    when(() => looper.recordTimingSettingsSettled).thenReturn(true);
    when(() => looper.recordTimingRecoveryRequired).thenReturn(false);
    when(() => looper.defaultRecordTiming).thenAnswer((_) => confirmedTiming);
    when(() => looper.trackRecordTimingOverrides).thenReturn(const {});
    when(() => looper.recordTimingRestartIntent).thenAnswer(
      (_) => (
        defaultTiming: confirmedTiming,
        rememberedDivision: rememberedDivision,
        trackOverrides: const <int, RecordTiming>{},
      ),
    );
    when(() => looper.settleRecordTimingSettings()).thenAnswer(
      (_) async => EngineResult.ok,
    );
    when(
      () => looper.setRecordTimingSettings(
        defaultTiming: any(named: 'defaultTiming'),
        rememberedDivision: any(named: 'rememberedDivision'),
        trackOverrides: any(named: 'trackOverrides'),
      ),
    ).thenAnswer((call) {
      confirmedTiming = call.namedArguments[#defaultTiming] as RecordTiming;
      rememberedDivision =
          call.namedArguments[#rememberedDivision] as GridDivision;
      return EngineResult.ok;
    });
    when(() => looper.lengthSettingsSettled).thenReturn(true);
    when(() => looper.lengthRecoveryRequired).thenReturn(false);
    when(() => looper.trackLengthPresetOverrides).thenReturn(const {});
    when(() => looper.sessionTransport).thenAnswer(
      (_) => TransportState(
        recordTiming: confirmedTiming,
        quantizeDiv: rememberedDivision,
      ),
    );
    when(() => looper.settleLengthSettings()).thenAnswer(
      (_) async => EngineResult.ok,
    );
    when(
      () => looper.setLengthSettings(
        defaultBars: any(named: 'defaultBars'),
        overrides: any(named: 'overrides'),
        mode: any(named: 'mode'),
      ),
    ).thenReturn(EngineResult.ok);
    when(
      () => looper.setRecDub(enabled: any(named: 'enabled')),
    ).thenReturn(EngineResult.ok);
    when(
      () => looper.setDefaultMultiple(multiple: any(named: 'multiple')),
    ).thenReturn(EngineResult.ok);
    when(() => devices.connection).thenReturn(_connection);
    when(() => devices.session).thenReturn(const MidiInputSession('usb', 1));
    when(() => devices.connections).thenAnswer((_) => connections.stream);
    when(() => devices.messages).thenAnswer((_) => messages.stream);
    when(() => devices.activity).thenAnswer((_) => const Stream<void>.empty());
    when(() => devices.select(any())).thenAnswer((_) async {});
  });

  setUpAll(() {
    registerFallbackValue(LooperMode.multi);
    registerFallbackValue(RecordTiming.immediately);
    registerFallbackValue(GridDivision.off);
    registerFallbackValue(<int, RecordTiming>{});
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
    OneShotSnapshot? oneShotSnapshot,
    RecordStartSnapshot? recordStartSnapshot,
  }) async {
    tester.view
      ..physicalSize = const Size(1920, 1080)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final settings = SettingsRepository(store: store);
    await settings.restoreRecordTimingCheckpoint((
      quantize: false,
      division: GridDivision.off.code,
      trackOverrides: {},
    ));
    tray = SettingsTrayCubit();
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
    final tempo = MockClickTempoSettings();
    when(() => tempo.recordStartSnapshot).thenReturn(recordStartSnapshot);
    if (recordStartSnapshot != null) {
      when(() => tempo.state).thenReturn(
        tempo.state.copyWith(
          countInBars: recordStartSnapshot.settings.countInBars,
          soundStart: recordStartSnapshot.settings.soundStart,
          recordStartReady: true,
          recordStartInitialized: true,
          recordStartCaptureLocked: recordStartSnapshot.captureLocked,
        ),
      );
    }
    final closeTempo = tempo.close;
    addTearDown(() => unawaited(closeTempo()));
    final decay = MockDecayPlaybackSettings(
      snapshot: DecaySnapshot(defaultPercent: 25, trackOverrides: const {0: 0}),
      oneShot: oneShotSnapshot,
    );
    addTearDown(decay.close);
    record = RecordSettings(repository: looper, settings: settings);
    addTearDown(() => unawaited(record.close()));
    await record.load();
    final timingOwner = RecordTimingSettings(
      repository: looper,
      settings: settings,
    );
    addTearDown(() => unawaited(timingOwner.close()));
    timing = RecordTimingCubit(settings: timingOwner);
    addTearDown(() => unawaited(timing.close()));
    await timingOwner.load();
    when(() => tempo.clickVolumeLifetime).thenReturn((
      sessionRevision: 1,
      mixGeneration: 1,
    ));
    control = ControlCubit(
      fadeSettings: testFadeSettings(),
      decayControl: decay,
      oneShotControl: decay,
      recordLengthControl: record,
      recordTimingControl: timingOwner,
      clickVolumeControl: tempo,
      clickModeControl: tempo,
      recordStartControl: tempo,
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
            BlocProvider<TempoCubit>(
              create: (_) => TempoCubit(settings: tempo),
            ),
            BlocProvider<PlaybackOptionsCubit>(
              create: (_) => PlaybackOptionsCubit(settings: decay),
            ),
            BlocProvider<RecordOptionsCubit>(
              create: (_) => RecordOptionsCubit(settings: record),
            ),
            BlocProvider<RecordTimingCubit>.value(value: timing),
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
    testWidgets('Click range reads 100 to 200 percent of unity', (
      tester,
    ) async {
      const target = ClickVolumeTarget();
      await pump(
        tester,
        savedMapping: MidiMapping(
          id: 'm1',
          source: _source,
          behavior: MidiBehavior.continuous,
          controls: [
            MidiParameterControl(
              key: target.canonicalString(),
              low: 0.5,
              high: 1,
            ),
          ],
        ),
      );
      await tap(tester, 'midi_row_edit_m1');
      expect(
        find.byKey(Key('midi_range_low_${target.canonicalString()}')),
        findsOneWidget,
      );
      expect(find.text('100%'), findsOneWidget);
      expect(find.text('200%'), findsOneWidget);
      await shot(tester, 'click_range');
    });
    testWidgets('Playback range offers Loop and Once endpoints', (
      tester,
    ) async {
      const target = DefaultOneShotTarget();
      await pump(
        tester,
        oneShotSnapshot: OneShotSnapshot(
          defaultOneShot: false,
          trackOverrides: const {},
        ),
        savedMapping: MidiMapping(
          id: 'm1',
          source: _source,
          behavior: MidiBehavior.continuous,
          controls: [
            MidiParameterControl(
              key: target.canonicalString(),
              low: 0,
              high: 1,
            ),
          ],
        ),
      );
      await tap(tester, 'midi_row_edit_m1');
      expect(
        find.byKey(Key('midi_range_low_${target.canonicalString()}')),
        findsOneWidget,
      );
      expect(find.text('Loop'), findsWidgets);
      expect(find.text('Once'), findsWidgets);
      await shot(tester, 'playback_range');
    });
    testWidgets('Outputs offers one Click destination', (
      tester,
    ) async {
      await pump(tester, seeded: true);
      await tap(tester, 'midi_row_edit_m1');
      await tap(tester, 'midi_add_control');
      await tap(tester, 'expression_kind_output');
      expect(
        find.byKey(const Key('expression_destination_click')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('expression_destination_output:0')),
        findsNothing,
      );
      await shot(tester, 'click_destination');
    });
    testWidgets('Decay endpoints distinguish default and fixed Track 8', (
      tester,
    ) async {
      await pump(
        tester,
        savedMapping: MidiMapping(
          id: 'm1',
          source: _source,
          behavior: MidiBehavior.continuous,
          controls: [
            for (final target in const [
              DefaultDecayTarget(),
              TrackDecayTarget(7),
            ])
              MidiParameterControl(
                key: target.canonicalString(),
                low: 0,
                high: 1,
              ),
          ],
        ),
      );
      await tap(tester, 'midi_row_edit_m1');
      expect(find.text('Off · Keep layers'), findsNWidgets(2));
      expect(find.text('100%'), findsNWidgets(2));
      await shot(tester, 'decay_ranges');
    });
    testWidgets('Record length range reads Auto to 64 bars', (tester) async {
      const target = DefaultRecordLengthTarget();
      await pump(
        tester,
        savedMapping: MidiMapping(
          id: 'm1',
          source: _source,
          behavior: MidiBehavior.continuous,
          controls: [
            MidiParameterControl(
              key: target.canonicalString(),
              low: 0,
              high: 1,
            ),
          ],
        ),
      );
      await tap(tester, 'midi_row_edit_m1');
      final key = target.canonicalString();
      expect(find.byKey(Key('midi_range_low_$key')), findsOneWidget);
      expect(find.text('Auto'), findsWidgets);
      expect(find.text('64 bars'), findsWidgets);
      await shot(tester, 'record_length_range');
    });
    testWidgets('Record timing range names both musical choices', (
      tester,
    ) async {
      const target = DefaultRecordTimingTarget();
      await pump(
        tester,
        savedMapping: MidiMapping(
          id: 'm1',
          source: _source,
          behavior: MidiBehavior.continuous,
          controls: [
            MidiParameterControl(
              key: target.canonicalString(),
              low: 0,
              high: 1,
            ),
          ],
        ),
      );
      expect(timing.state.recordTimingReady, isTrue);
      await tap(tester, 'midi_row_edit_m1');
      final key = target.canonicalString();
      expect(find.byKey(Key('midi_range_low_$key')), findsOneWidget);
      expect(find.text('Immediately'), findsWidgets);
      expect(find.text('1/16 note'), findsWidgets);
      await shot(tester, 'record_timing_range');
    });
    testWidgets('Count-in MIDI named endpoints at console size', (
      tester,
    ) async {
      const target = CountInValueTarget();
      await pump(
        tester,
        recordStartSnapshot: RecordStartSnapshot(
          settings: RecordStartSettings(countInBars: 2, soundStart: false),
          captureLocked: false,
        ),
        savedMapping: MidiMapping(
          id: 'm1',
          source: _source,
          behavior: MidiBehavior.continuous,
          controls: [
            MidiParameterControl(
              key: target.canonicalString(),
              low: 0,
              high: 1,
            ),
          ],
        ),
      );
      await tap(tester, 'midi_row_edit_m1');
      expect(find.text('4 bars'), findsWidgets);
      expect(find.text('Off'), findsWidgets);
      await shot(tester, 'count_in_range');
    });
    testWidgets('Loop controls offers the default decay', (tester) async {
      await pump(tester, seeded: true);
      await tap(tester, 'midi_row_edit_m1');
      await tap(tester, 'midi_add_control');
      await tap(tester, 'expression_kind_loopControls');
      expect(
        find.byKey(const Key('expression_destination_loop:defaults')),
        findsOneWidget,
      );
      await shot(tester, 'decay_destination');
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
