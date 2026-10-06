import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:controller_repository/controller_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import 'package:segno/control/binding/control_action.dart';
import 'package:segno/control/binding/control_value_target.dart';
import 'package:segno/control/binding/fx_binding_target.dart';
import 'package:segno/control/cubit/control_cubit.dart';
import 'package:segno/control/view/midi_controls/midi_controls_page.dart';
import 'package:segno/control/view/midi_controls/midi_segmented.dart';
import 'package:segno/control/view/pedal_setup/external_controls_editor.dart';
import 'package:segno/control/view/pedal_setup/pedal_choice_picker.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/application/fade_settings.dart';
import 'package:segno/looper/application/record_settings.dart';
import 'package:segno/looper/application/record_timing_settings.dart';
import 'package:segno/looper/cubit/playback_options_cubit.dart';
import 'package:segno/looper/cubit/record_options_cubit.dart';
import 'package:segno/looper/cubit/record_timing_cubit.dart';
import 'package:segno/looper/cubit/settings_tray_cubit.dart';
import 'package:segno/looper/cubit/tempo_cubit.dart';
import 'package:segno/looper/cubit/tracks_cubit.dart';
import 'package:segno/looper/model/click_mode.dart';
import 'package:segno/looper/model/one_shot.dart';
import 'package:segno/looper/model/overdub_decay.dart';
import 'package:segno/looper/model/record_start.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/theme/theme.dart';
import 'package:settings_repository/settings_repository.dart';

import '../helpers/fake_audio_engine.dart';
import '../helpers/fake_key_value_store.dart';
import '../helpers/mock_click_tempo_settings.dart';
import '../helpers/mock_decay_playback_settings.dart';
import '../helpers/test_fade_settings.dart';
import '../helpers/test_mix_settings.dart';

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

void main() {
  late _MockLooper looper;
  late _MockMidiDevices devices;
  late StreamController<LooperState> looperStates;
  late StreamController<MidiConnection> connections;
  late StreamController<MidiInputMessage> messages;
  late _Store store;
  late ControlCubit control;
  late MockClickTempoSettings tempo;
  late RecordSettings record;
  late RecordTimingCubit timing;
  late RecordTiming confirmedTiming;
  late GridDivision rememberedDivision;
  var captureMicros = 0;
  late SettingsTrayCubit tray;

  setUp(() {
    captureMicros = 0;
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
    when(() => looper.mixGeneration).thenReturn(0);
    when(() => looper.mixSettingsSettled).thenReturn(true);
    when(() => looper.mixSettingsSnapshot).thenReturn(MixSettingsSnapshot());
    when(() => looper.laneCount(any())).thenReturn(1);
    when(() => looper.inputSetup).thenReturn(const InputSetup.empty());
    when(() => looper.trackEffects(any())).thenReturn(const []);
    when(() => looper.laneEffects(any(), any())).thenReturn(const []);
    when(() => looper.monitorEffects(any())).thenReturn(const []);
    when(() => looper.outputEffects(any())).thenReturn(const []);
    when(() => looper.allTrackChains()).thenReturn(const {});
    when(() => looper.allMonitors()).thenReturn(const {});
    when(() => looper.allLaneChains()).thenReturn(const {});
    when(() => looper.allTracksEffects).thenReturn(const []);
    when(() => looper.allTracksChainEnabled).thenReturn(true);
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
        released: any(named: 'released'),
        editMask: any(named: 'editMask'),
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
        released: any(named: 'released'),
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
    registerFallbackValue(RecordStartEditKind.countIn);
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
    double? clickVolume = 1,
    ClickModeSnapshot? clickModeSnapshot,
    RecordStartSnapshot? recordStartSnapshot,
    DecaySnapshot? decaySnapshot,
    OneShotSnapshot? oneShotSnapshot,
    RecordTiming currentTiming = RecordTiming.immediately,
  }) async {
    tester.view
      ..physicalSize = const Size(1920, 1080)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final settings = SettingsRepository(store: store);
    confirmedTiming = currentTiming;
    rememberedDivision = currentTiming.division;
    await settings.restoreRecordTimingCheckpoint((
      quantize: currentTiming.quantize,
      division: rememberedDivision.code,
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
    tempo = MockClickTempoSettings(clickVolume: clickVolume);
    final closeTempo = tempo.close;
    addTearDown(() => unawaited(closeTempo()));
    when(() => tempo.clickModeSnapshot).thenReturn(clickModeSnapshot);
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
    final playback = MockDecayPlaybackSettings(
      snapshot: decaySnapshot,
      oneShot: oneShotSnapshot,
    );
    addTearDown(playback.close);
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
    final fade = testFadeSettings();
    addTearDown(() => unawaited(fade.close()));
    control = ControlCubit(
      fadeSettings: fade,
      looper: looper,
      clickVolumeControl: tempo,
      clickModeControl: tempo,
      recordStartControl: tempo,
      decayControl: playback,
      oneShotControl: playback,
      recordLengthControl: record,
      recordTimingControl: timingOwner,
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
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<LooperRepository>.value(value: looper),
          RepositoryProvider<FadeSettings>.value(value: fade),
        ],
        child: MultiBlocProvider(
          providers: [
            BlocProvider.value(value: control),
            BlocProvider.value(value: tracks),
            BlocProvider.value(value: midi),
            BlocProvider<TempoCubit>(
              create: (_) => TempoCubit(settings: tempo),
            ),
            BlocProvider<PlaybackOptionsCubit>(
              create: (_) => PlaybackOptionsCubit(settings: playback),
            ),
            BlocProvider<RecordOptionsCubit>(
              create: (_) => RecordOptionsCubit(settings: record),
            ),
            BlocProvider<RecordTimingCubit>.value(value: timing),
          ],
          child: MaterialApp(
            navigatorKey: routeEntry ? segnoNavigatorKey : null,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            theme: ThemeData(
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
    final target = find.byKey(Key(key));
    await tester.ensureVisible(target);
    await tester.tap(target);
    await tester.pumpAndSettle();
  }

  Future<void> receive(
    WidgetTester tester,
    ControllerSourceKind kind,
    int number,
    int value, {
    int channel = 0,
    MidiInputSession session = const MidiInputSession('usb', 1),
  }) async {
    messages.add(
      MidiInputMessage(
        session,
        RawControllerInput(
          kind: kind,
          id: number,
          value: value,
          midiChannel: channel,
        ),
        timestampMicros: captureMicros += 1000,
      ),
    );
    // Capture time, not wall-clock test speed, defines compound freshness.
    await tester.pump(const Duration(milliseconds: 1));
  }

  Future<void> pickTrackVolume(WidgetTester tester, int channel) async {
    await tap(tester, 'expression_kind_recordedTrack');
    await tap(tester, 'expression_destination_track:$channel');
    await tap(
      tester,
      'external_pick_${externalControlKey(TrackVolumeTarget(channel))}',
    );
  }

  testWidgets('Click maps from Outputs with full range and no Save preview', (
    tester,
  ) async {
    await pump(tester, seeded: true);
    await tap(tester, 'midi_row_edit_m1');
    await tap(tester, 'midi_add_control');
    await tap(tester, 'expression_kind_output');
    await tap(tester, 'expression_destination_click');
    await tap(
      tester,
      'external_pick_${externalControlKey(const ClickVolumeTarget())}',
    );
    final clickKey = const ClickVolumeTarget().canonicalString();
    expect(find.byKey(Key('midi_range_low_$clickKey')), findsOneWidget);
    expect(find.byKey(Key('midi_range_high_$clickKey')), findsOneWidget);
    await tap(tester, 'midi_save');
    final click = control.state.midiMappings
        .byId('m1')!
        .controls
        .whereType<MidiParameterControl>()
        .singleWhere((control) => control.key == clickKey);
    expect((click.low, click.high), (0, 1));
    verifyNever(() => looper.setClickVolume(any()));
  });

  testWidgets('Decay maps from Loop controls with full range and no preview', (
    tester,
  ) async {
    await pump(
      tester,
      seeded: true,
      decaySnapshot: DecaySnapshot(
        defaultPercent: 50,
        trackOverrides: const {},
      ),
    );
    await tap(tester, 'midi_row_edit_m1');
    await tap(tester, 'midi_add_control');
    await tap(tester, 'expression_kind_loopControls');
    await tap(tester, 'expression_destination_loop:defaults');
    await tap(
      tester,
      'external_pick_${externalControlKey(const DefaultDecayTarget())}',
    );
    final key = const DefaultDecayTarget().canonicalString();
    expect(find.byKey(Key('midi_range_low_$key')), findsOneWidget);
    await tap(tester, 'midi_save');
    final saved = control.state.midiMappings
        .byId('m1')!
        .controls
        .whereType<MidiParameterControl>()
        .singleWhere((control) => control.key == key);
    expect((saved.low, saved.high), (0, 1));
    verifyNever(() => looper.setOverdubDecay(any()));
  });

  testWidgets('Hear click maps named Off to Play & record without Save audio', (
    tester,
  ) async {
    await pump(
      tester,
      seeded: true,
      clickModeSnapshot: const ClickModeSnapshot(
        mode: ClickMode.off,
        captureLocked: false,
      ),
    );
    await tap(tester, 'midi_row_edit_m1');
    await tap(tester, 'midi_add_control');
    await tap(tester, 'expression_kind_loopControls');
    await tap(tester, 'expression_destination_loop:defaults');
    await tap(
      tester,
      'external_pick_${externalControlKey(const ClickModeValueTarget())}',
    );
    final key = const ClickModeValueTarget().canonicalString();
    final low = find.byKey(Key('midi_range_low_$key'));
    final high = find.byKey(Key('midi_range_high_$key'));
    expect(
      find.descendant(of: low, matching: find.text('Off')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: high, matching: find.text('Play & record')),
      findsOneWidget,
    );
    await tap(tester, 'midi_save');
    final saved = control.state.midiMappings
        .byId('m1')!
        .controls
        .whereType<MidiParameterControl>()
        .singleWhere((control) => control.key == key);
    expect((saved.low, saved.high), (0, 1));
    verifyNever(() => tempo.setClickMode(ClickMode.off));
    verifyNever(() => looper.setClickMode(ClickMode.off));
  });

  testWidgets('Hear click MIDI repair Escape preserves raw range', (
    tester,
  ) async {
    final oldKey = const TrackVolumeTarget(0).canonicalString();
    final original = MidiMapping(
      id: 'm1',
      source: _source,
      behavior: MidiBehavior.continuous,
      controls: [MidiParameterControl(key: oldKey, low: 0.2, high: 0.8)],
    );
    await pump(
      tester,
      savedMapping: original,
      clickModeSnapshot: const ClickModeSnapshot(
        mode: ClickMode.recFirst,
        captureLocked: false,
      ),
    );
    await tap(tester, 'midi_row_edit_m1');
    await tap(tester, 'midi_control_change_$oldKey');
    await tap(tester, 'expression_kind_loopControls');
    await tap(tester, 'expression_destination_loop:defaults');
    await tap(
      tester,
      'external_pick_${externalControlKey(const ClickModeValueTarget())}',
    );
    final key = const ClickModeValueTarget().canonicalString();
    await tap(tester, 'midi_click_mode_low_${key}_playRec');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await tap(tester, 'midi_save');
    final repaired =
        control.state.midiMappings.byId('m1')!.controls.single
            as MidiParameterControl;
    expect(repaired.key, key);
    expect((repaired.low, repaired.high), (0.2, 0.8));
  });

  testWidgets('Count-in MIDI uses named Off to four-bar endpoints', (
    tester,
  ) async {
    await pump(
      tester,
      seeded: true,
      recordStartSnapshot: RecordStartSnapshot(
        settings: RecordStartSettings(countInBars: 0, soundStart: true),
        captureLocked: false,
      ),
    );
    await tap(tester, 'midi_row_edit_m1');
    await tap(tester, 'midi_add_control');
    await tap(tester, 'expression_kind_loopControls');
    await tap(tester, 'expression_destination_loop:defaults');
    await tap(
      tester,
      'external_pick_${externalControlKey(const CountInValueTarget())}',
    );
    final key = const CountInValueTarget().canonicalString();
    final low = find.byKey(Key('midi_range_low_$key'));
    final high = find.byKey(Key('midi_range_high_$key'));
    expect(
      find.descendant(of: low, matching: find.text('Off')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: high, matching: find.text('4 bars')),
      findsOneWidget,
    );
    await tap(tester, 'midi_save');
    final saved = control.state.midiMappings
        .byId('m1')!
        .controls
        .whereType<MidiParameterControl>()
        .singleWhere((control) => control.key == key);
    expect((saved.low, saved.high), (0, 1));
    verifyNever(
      () => looper.setRecordStartSettings(
        countInBars: any(named: 'countInBars'),
        soundStart: any(named: 'soundStart'),
        editKind: any(named: 'editKind'),
      ),
    );
  });

  testWidgets('Count-in MIDI repair Escape preserves raw range', (
    tester,
  ) async {
    final oldKey = const TrackVolumeTarget(0).canonicalString();
    final original = MidiMapping(
      id: 'm1',
      source: _source,
      behavior: MidiBehavior.continuous,
      controls: [MidiParameterControl(key: oldKey, low: 0.2, high: 0.8)],
    );
    await pump(
      tester,
      savedMapping: original,
      recordStartSnapshot: RecordStartSnapshot(
        settings: RecordStartSettings(countInBars: 1, soundStart: false),
        captureLocked: false,
      ),
    );
    await tap(tester, 'midi_row_edit_m1');
    await tap(tester, 'midi_control_change_$oldKey');
    await tap(tester, 'expression_kind_loopControls');
    await tap(tester, 'expression_destination_loop:defaults');
    await tap(
      tester,
      'external_pick_${externalControlKey(const CountInValueTarget())}',
    );
    final key = const CountInValueTarget().canonicalString();
    await tap(tester, 'midi_count_in_low_${key}_4');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await tap(tester, 'midi_save');
    final repaired =
        control.state.midiMappings.byId('m1')!.controls.single
            as MidiParameterControl;
    expect(repaired.key, key);
    expect((repaired.low, repaired.high), (0.2, 0.8));
  });

  testWidgets('Record length keeps Auto to 64 bars as a draft until Save', (
    tester,
  ) async {
    await pump(tester, seeded: true);
    clearInteractions(looper);
    await tap(tester, 'midi_row_edit_m1');
    await tap(tester, 'midi_add_control');
    await tap(tester, 'expression_kind_loopControls');
    await tap(tester, 'expression_destination_loop:defaults');
    await tap(
      tester,
      'external_pick_${externalControlKey(const DefaultRecordLengthTarget())}',
    );
    final key = const DefaultRecordLengthTarget().canonicalString();
    final low = find.byKey(Key('midi_range_low_$key'));
    final high = find.byKey(Key('midi_range_high_$key'));
    expect(low, findsOneWidget);
    expect(high, findsOneWidget);
    expect(
      find.descendant(of: low, matching: find.text('Auto')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: high, matching: find.text('64 bars')),
      findsOneWidget,
    );
    expect(control.state.midiMappings.byId('m1')!.controls, hasLength(1));
    await tap(tester, 'midi_save');
    final saved = control.state.midiMappings
        .byId('m1')!
        .controls
        .whereType<MidiParameterControl>()
        .singleWhere((control) => control.key == key);
    expect((saved.low, saved.high), (0, 1));
    verifyNever(
      () => looper.setLengthSettings(
        defaultBars: any(named: 'defaultBars'),
        overrides: any(named: 'overrides'),
        released: any(named: 'released'),
        mode: any(named: 'mode'),
      ),
    );
  });

  testWidgets('Record timing keeps Immediately to sixteenth draft-only', (
    tester,
  ) async {
    await pump(tester, seeded: true);
    expect(timing.state.recordTimingReady, isTrue);
    clearInteractions(looper);
    await tap(tester, 'midi_row_edit_m1');
    await tap(tester, 'midi_add_control');
    await tap(tester, 'expression_kind_loopControls');
    await tap(tester, 'expression_destination_loop:defaults');
    await tap(
      tester,
      'external_pick_${externalControlKey(const DefaultRecordTimingTarget())}',
    );
    final key = const DefaultRecordTimingTarget().canonicalString();
    final low = find.byKey(Key('midi_range_low_$key'));
    final high = find.byKey(Key('midi_range_high_$key'));
    expect(low, findsOneWidget);
    expect(high, findsOneWidget);
    expect(
      find.descendant(of: low, matching: find.text('Immediately')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: high, matching: find.text('1/16 note')),
      findsOneWidget,
    );
    expect(control.state.midiMappings.byId('m1')!.controls, hasLength(1));
    await tap(tester, 'midi_save');
    final saved = control.state.midiMappings
        .byId('m1')!
        .controls
        .whereType<MidiParameterControl>()
        .singleWhere((control) => control.key == key);
    expect((saved.low, saved.high), (0, 1));
    verifyNever(
      () => looper.setRecordTimingSettings(
        defaultTiming: any(named: 'defaultTiming'),
        rememberedDivision: any(named: 'rememberedDivision'),
        trackOverrides: any(named: 'trackOverrides'),
        released: any(named: 'released'),
        editMask: any(named: 'editMask'),
      ),
    );
  });

  testWidgets('Loop/Once range edits are draft-only and Escape restores low', (
    tester,
  ) async {
    await pump(
      tester,
      seeded: true,
      oneShotSnapshot: OneShotSnapshot(
        defaultOneShot: false,
        trackOverrides: const {},
      ),
    );
    await tap(tester, 'midi_row_edit_m1');
    await tap(tester, 'midi_add_control');
    await tap(tester, 'expression_kind_loopControls');
    await tap(tester, 'expression_destination_loop:defaults');
    await tap(
      tester,
      'external_pick_${externalControlKey(const DefaultOneShotTarget())}',
    );
    final key = const DefaultOneShotTarget().canonicalString();
    expect(find.byKey(Key('midi_range_low_$key')), findsOneWidget);
    expect(find.byKey(Key('midi_range_high_$key')), findsOneWidget);
    await tap(tester, 'midi_once_low_${key}_once');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<LoopChoiceButton>(
            find.byKey(Key('midi_once_low_${key}_loop')),
          )
          .selected,
      isTrue,
    );
    await tap(tester, 'midi_once_low_${key}_once');
    expect(control.state.midiMappings.byId('m1')!.controls, hasLength(1));
    await tap(tester, 'midi_save');
    final saved = control.state.midiMappings
        .byId('m1')!
        .controls
        .whereType<MidiParameterControl>()
        .singleWhere((control) => control.key == key);
    expect((saved.low, saved.high), (1, 1));
    verifyNever(
      () => looper.setOneShotSnapshot(
        defaultOneShot: any(named: 'defaultOneShot'),
        trackOverrides: any(named: 'trackOverrides'),
        released: any(named: 'released'),
      ),
    );
  });

  testWidgets('unavailable Click row can be repaired without changing range', (
    tester,
  ) async {
    final clickKey = const ClickVolumeTarget().canonicalString();
    final original = MidiMapping(
      id: 'm1',
      source: _source,
      behavior: MidiBehavior.continuous,
      controls: [MidiParameterControl(key: clickKey, low: 0.8, high: 0.2)],
    );
    await pump(tester, savedMapping: original, clickVolume: null);
    expect(find.byKey(const Key('midi_row_warning_m1')), findsOneWidget);
    await tap(tester, 'midi_row_edit_m1');
    await tap(tester, 'midi_control_change_$clickKey');
    await pickTrackVolume(tester, 2);
    expect(control.state.midiMappings.byId('m1'), original);
    await tap(tester, 'midi_save');
    final repaired =
        control.state.midiMappings.byId('m1')!.controls.single
            as MidiParameterControl;
    expect(repaired.key, const TrackVolumeTarget(2).canonicalString());
    expect((repaired.low, repaired.high), (0.8, 0.2));
  });

  testWidgets('unavailable Loop/Once row repairs a reversed authored range', (
    tester,
  ) async {
    final oldKey = const DefaultOneShotTarget().canonicalString();
    final original = MidiMapping(
      id: 'm1',
      source: _source,
      behavior: MidiBehavior.continuous,
      controls: [MidiParameterControl(key: oldKey, low: 1, high: 0)],
    );
    await pump(tester, savedMapping: original);
    expect(find.byKey(const Key('midi_row_warning_m1')), findsOneWidget);
    await tap(tester, 'midi_row_edit_m1');
    await tap(tester, 'midi_control_change_$oldKey');
    await pickTrackVolume(tester, 2);
    expect(control.state.midiMappings.byId('m1'), original);
    await tap(tester, 'midi_save');
    final repaired =
        control.state.midiMappings.byId('m1')!.controls.single
            as MidiParameterControl;
    expect(repaired.key, const TrackVolumeTarget(2).canonicalString());
    expect((repaired.low, repaired.high), (1, 0));
  });

  testWidgets('Add chooses an explicit format before Learn begins', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.byKey(const Key('midi_add_mapping')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('midi_format_standard')), findsOneWidget);
    expect(control.state.midiEdit?.learn, isNull);
    await tester.tap(find.byKey(const Key('midi_format_standard')));
    await tester.pumpAndSettle();
    expect(control.state.midiEdit?.learn?.protocol, MidiProtocol.standard);
  });

  testWidgets('failed same-value Save keeps editor draft and warning', (
    tester,
  ) async {
    await pump(tester, seeded: true);
    await tester.tap(find.byKey(const Key('midi_row_edit_m1')));
    await tester.pumpAndSettle();
    store.refuse = true;
    await tester.tap(find.byKey(const Key('midi_save')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('midi_source_name')), findsOneWidget);
    expect(find.byKey(const Key('midi_editor_notice')), findsOneWidget);
    expect(control.state.midiMappings.byId('m1'), _mapping());
  });

  for (final scenario in [
    (
      name: 'CC',
      protocol: MidiProtocol.standard,
      kind: ControllerSourceKind.midiCc,
      number: 23,
      parameter: null,
      bank: null,
      prefix: <(int, int)>[],
      value: 64,
    ),
    (
      name: 'Note',
      protocol: MidiProtocol.standard,
      kind: ControllerSourceKind.midiNote,
      number: 60,
      parameter: null,
      bank: null,
      prefix: <(int, int)>[],
      value: 100,
    ),
    (
      name: 'Program',
      protocol: MidiProtocol.standard,
      kind: ControllerSourceKind.midiProgram,
      number: 12,
      parameter: null,
      bank: null,
      prefix: <(int, int)>[],
      value: 0,
    ),
    (
      name: '14-bit CC',
      protocol: MidiProtocol.cc14,
      kind: ControllerSourceKind.midiCc,
      number: 1,
      parameter: null,
      bank: null,
      prefix: [(1, 64)],
      value: 7,
    ),
    (
      name: 'NRPN',
      protocol: MidiProtocol.nrpn,
      kind: ControllerSourceKind.midiCc,
      number: 6,
      parameter: 130,
      bank: null,
      prefix: [(99, 1), (98, 2), (6, 64)],
      value: 7,
    ),
    (
      name: 'Bank Program',
      protocol: MidiProtocol.bankProgram,
      kind: ControllerSourceKind.midiProgram,
      number: 12,
      parameter: null,
      bank: 130,
      prefix: [(0, 1), (32, 2)],
      value: 0,
    ),
    (
      name: 'Relative CC',
      protocol: MidiProtocol.relative,
      kind: ControllerSourceKind.midiCc,
      number: 23,
      parameter: null,
      bank: null,
      prefix: <(int, int)>[],
      value: 65,
    ),
  ]) {
    testWidgets('${scenario.name} learns, chooses a target and saves', (
      tester,
    ) async {
      await pump(tester);
      await tap(tester, 'midi_add_mapping');
      await tap(tester, 'midi_format_${scenario.protocol.name}');
      expect(find.byKey(const Key('midi_listening')), findsOneWidget);
      for (final (number, value) in scenario.prefix) {
        await receive(
          tester,
          ControllerSourceKind.midiCc,
          number,
          value,
          channel: 3,
        );
      }
      await receive(
        tester,
        scenario.kind,
        switch (scenario.protocol) {
          MidiProtocol.cc14 => 33,
          MidiProtocol.nrpn => 38,
          _ => scenario.number,
        },
        scenario.value,
        channel: 3,
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('midi_received')), findsOneWidget);
      expect(control.state.midiMappings.mappings, isEmpty);
      await tap(tester, 'midi_add_control');
      await pickTrackVolume(tester, 2);
      await tap(tester, 'midi_save');
      final saved = control.state.midiMappings.mappings.single;
      expect(
        saved.source,
        MidiSource(
          device: 'usb',
          kind: scenario.kind,
          number: scenario.number,
          channel: 3,
          protocol: scenario.protocol,
          parameter: scenario.parameter,
          bank: scenario.bank,
        ),
      );
      expect(
        saved.controls.single,
        MidiParameterControl(
          key: const TrackVolumeTarget(2).canonicalString(),
          low: 0,
          high: 1,
        ),
      );
      final persisted =
          jsonDecode(
                (await store.getString('midi.configuration'))!,
              )
              as Map<String, dynamic>;
      expect(persisted['mappings'], [saved.toJson()]);
      expect(control.state.midiEdit, isNull);
      expect(find.byKey(Key('midi_row_edit_${saved.id}')), findsOneWidget);
    });
  }

  testWidgets('Cancel discards a learned source and multiple targets', (
    tester,
  ) async {
    await pump(tester);
    await tap(tester, 'midi_add_mapping');
    await tap(tester, 'midi_format_standard');
    await receive(tester, ControllerSourceKind.midiCc, 23, 64);
    await tap(tester, 'midi_add_control');
    await pickTrackVolume(tester, 0);
    await tap(tester, 'midi_add_control');
    await pickTrackVolume(tester, 1);
    expect(find.byType(LoopSlider), findsNWidgets(4));
    await tap(tester, 'midi_cancel');
    expect(control.state.midiMappings.mappings, isEmpty);
    expect(control.state.midiEdit, isNull);
    expect(await store.getString('midi.configuration'), isNull);
  });

  testWidgets('channel edits can be cancelled then saved as All or exact', (
    tester,
  ) async {
    await pump(tester, seeded: true);
    await tap(tester, 'midi_row_edit_m1');
    await tap(tester, 'midi_channel');
    await tap(tester, 'midi_channel_omni');
    expect(control.state.midiMappings.byId('m1')!.source.channel, 0);
    await tap(tester, 'midi_cancel');
    await tap(tester, 'midi_row_edit_m1');
    await tap(tester, 'midi_channel');
    await tap(tester, 'midi_channel_omni');
    await tap(tester, 'midi_save');
    expect(control.state.midiMappings.byId('m1')!.source.channel, isNull);
    await tap(tester, 'midi_row_edit_m1');
    await tap(tester, 'midi_channel');
    await tap(tester, 'midi_channel_15');
    await tap(tester, 'midi_save');
    expect(control.state.midiMappings.byId('m1')!.source.channel, 15);
  });

  testWidgets('disabled source stays reserved and opens its existing mapping', (
    tester,
  ) async {
    await pump(tester, seeded: true);
    await tap(tester, 'midi_row_enable_m1');
    expect(control.state.midiMappings.byId('m1')!.enabled, isFalse);
    await tap(tester, 'midi_add_mapping');
    await tap(tester, 'midi_format_standard');
    await receive(tester, ControllerSourceKind.midiCc, 21, 90);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('midi_conflict')), findsOneWidget);
    await tap(tester, 'midi_edit_existing');
    expect(find.byKey(const Key('midi_delete')), findsOneWidget);
    await tap(tester, 'midi_save');
    expect(control.state.midiMappings.mappings, hasLength(1));
    expect(control.state.midiMappings.byId('m1')!.enabled, isFalse);
  });

  testWidgets('failed disable and delete preserve mapping until retry saves', (
    tester,
  ) async {
    await pump(tester, seeded: true);
    final original = await store.getString('midi.configuration');
    store.refuse = true;
    await tap(tester, 'midi_row_enable_m1');
    expect(control.state.midiMappings.byId('m1')!.enabled, isTrue);
    expect(await store.getString('midi.configuration'), original);
    store.refuse = false;
    await tap(tester, 'midi_row_enable_m1');
    expect(control.state.midiMappings.byId('m1')!.enabled, isFalse);
    await tap(tester, 'midi_row_edit_m1');
    store.refuse = true;
    await tap(tester, 'midi_delete');
    expect(control.state.midiMappings.byId('m1'), isNotNull);
    expect(find.byKey(const Key('midi_editor_notice')), findsOneWidget);
    store.refuse = false;
    await tap(tester, 'midi_delete');
    expect(control.state.midiMappings.byId('m1'), isNull);
    expect(find.byKey(const Key('midi_no_mappings')), findsOneWidget);
  });

  testWidgets('Resume On after refused Off keeps confirmed enabled state', (
    tester,
  ) async {
    await pump(tester, seeded: true);
    store.refuse = true;
    await tap(tester, 'midi_control_enabled');
    expect(control.state.midiRemotePaused, isTrue);
    store.refuse = false;
    await tap(tester, 'midi_resume_on');
    expect(control.state.midiControlEnabled, isTrue);
    expect(control.state.midiRemotePaused, isFalse);
    expect(control.state.midiMappings.byId('m1'), _mapping());
  });

  testWidgets('Learn ignores stale captures and cancel keeps original source', (
    tester,
  ) async {
    await pump(tester, seeded: true);
    await tap(tester, 'midi_row_edit_m1');
    await tap(tester, 'midi_learn');
    await receive(
      tester,
      ControllerSourceKind.midiCc,
      99,
      64,
      session: const MidiInputSession('usb', 0),
    );
    expect(control.state.midiEdit!.learn!.isListening, isTrue);
    await tap(tester, 'midi_cancel_learn');
    await receive(tester, ControllerSourceKind.midiCc, 22, 64);
    expect(find.byKey(const Key('midi_received')), findsNothing);
    await tap(tester, 'midi_save');
    expect(control.state.midiMappings.byId('m1')!.source, _source);
  });

  testWidgets('Learn timeout allows a fresh successful attempt', (
    tester,
  ) async {
    await pump(tester);
    await tap(tester, 'midi_add_mapping');
    await tap(tester, 'midi_format_standard');
    await tester.pump(const Duration(seconds: 16));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('midi_listening')), findsNothing);
    expect(find.byKey(const Key('midi_editor_notice')), findsOneWidget);
    await tap(tester, 'midi_learn');
    await receive(tester, ControllerSourceKind.midiNote, 61, 100);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('midi_received')), findsOneWidget);
    await tap(tester, 'midi_cancel');
    expect(control.state.midiEdit, isNull);
  });

  testWidgets('repair replaces a missing target only on Save, keeping range', (
    tester,
  ) async {
    final missing = MidiMapping(
      id: 'm1',
      source: _source,
      behavior: MidiBehavior.continuous,
      controls: [
        MidiParameterControl(key: 'retired:parameter', low: 0.3, high: 0.7),
      ],
    );
    await pump(tester, savedMapping: missing);
    expect(find.byKey(const Key('midi_row_warning_m1')), findsOneWidget);
    await tap(tester, 'midi_row_edit_m1');
    await tap(tester, 'midi_control_change_retired:parameter');
    await pickTrackVolume(tester, 3);
    expect(find.byKey(const Key('midi_editor_notice')), findsOneWidget);
    expect(control.state.midiMappings.byId('m1'), missing);
    await tap(tester, 'midi_save');
    expect(
      control.state.midiMappings.byId('m1')!.controls.single,
      MidiParameterControl(
        key: const TrackVolumeTarget(3).canonicalString(),
        low: 0.3,
        high: 0.7,
      ),
    );
    expect(find.byKey(const Key('midi_row_warning_m1')), findsNothing);
  });

  testWidgets('action mapping exposes button edges and refuses knob formats', (
    tester,
  ) async {
    await pump(tester, seeded: true);
    await tap(tester, 'midi_row_edit_m1');
    await tap(tester, 'midi_knob_false');
    await tap(tester, 'midi_behavior_toggle');
    await tap(tester, 'midi_add_control');
    await tap(tester, 'midi_performance_actions');
    await tap(tester, 'pedal_choice_group_transport');
    await tap(tester, 'pedal_choice_command:undo');
    await tap(tester, 'midi_trigger_command:undo_release');
    await tap(tester, 'midi_knob_true');
    expect(find.byKey(const Key('midi_editor_notice')), findsOneWidget);
    await tap(tester, 'midi_format');
    await tap(tester, 'midi_format_cc14');
    expect(control.state.midiEdit!.learn, isNull);
    expect(find.byKey(const Key('midi_editor_notice')), findsOneWidget);
    await tap(tester, 'midi_save');
    final saved = control.state.midiMappings.byId('m1')!;
    expect(saved.behavior, MidiBehavior.toggle);
    expect(saved.source, _source);
    expect(
      saved.controls.whereType<MidiActionControl>().single.trigger,
      MidiEdge.release,
    );
  });

  testWidgets('pending Save locks route and editing until receipt', (
    tester,
  ) async {
    await pump(tester, seeded: true);
    await tester.tap(find.byKey(const Key('midi_row_edit_m1')));
    await tester.pumpAndSettle();
    final gate = Completer<void>();
    store.gate = gate;
    await tester.tap(find.byKey(const Key('midi_save')));
    await tester.pump();
    expect(
      find.byWidgetPredicate((widget) => widget is PopScope && !widget.canPop),
      findsOneWidget,
    );
    expect(find.byType(AbsorbPointer), findsWidgets);
    gate.complete();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('midi_no_mappings')), findsNothing);
  });

  testWidgets('Back unwinds pickers without saving or learning out of sight', (
    tester,
  ) async {
    await pump(tester, seeded: true);
    await tap(tester, 'midi_add_mapping');
    await tap(tester, 'loop_settings_back');
    expect(control.state.midiEdit, isNull);
    await tap(tester, 'midi_row_edit_m1');
    await tap(tester, 'midi_channel');
    await tap(tester, 'loop_settings_back');
    await tap(tester, 'midi_format');
    await tap(tester, 'loop_settings_back');
    await tap(tester, 'midi_learn');
    await tap(tester, 'midi_add_control');
    expect(control.state.midiEdit!.learn, isNull);
    await receive(tester, ControllerSourceKind.midiCc, 29, 100);
    await tap(tester, 'expression_kind_recordedTrack');
    await tap(tester, 'expression_destination_track:1');
    await tap(tester, 'loop_settings_back');
    expect(
      find.byKey(const Key('expression_destination_track:1')),
      findsOneWidget,
    );
    await tap(tester, 'loop_settings_back');
    expect(find.byKey(const Key('midi_source_name')), findsOneWidget);
    await tap(tester, 'loop_settings_back');
    expect(control.state.midiEdit, isNull);
    expect(control.state.midiMappings.byId('m1'), _mapping());
  });

  testWidgets('closing action choices preserves the saved target and range', (
    tester,
  ) async {
    await pump(tester, seeded: true);
    await tap(tester, 'midi_row_edit_m1');
    await tap(tester, 'midi_add_control');
    await tap(tester, 'midi_performance_actions');
    await tap(tester, 'pedal_choice_close');
    await tap(tester, 'loop_settings_back');
    await tap(tester, 'midi_save');
    expect(control.state.midiMappings.byId('m1'), _mapping());
  });

  testWidgets('device selection discards only the unfinished mapping draft', (
    tester,
  ) async {
    const second = MidiConnection(
      devices: [
        MidiDevice(id: 'usb', name: 'USB controller'),
        MidiDevice(id: 'pads', name: 'Drum pads'),
      ],
      selectedId: 'usb',
      selectedName: 'USB controller',
      status: MidiConnectionStatus.connected,
    );
    when(() => devices.connection).thenReturn(second);
    await pump(tester, seeded: true);
    await tap(tester, 'midi_device_pads');
    verify(() => devices.select('pads')).called(1);
    await tap(tester, 'midi_row_edit_m1');
    await tap(tester, 'midi_channel');
    await tap(tester, 'midi_channel_omni');
    when(() => devices.session).thenReturn(const MidiInputSession('pads', 2));
    connections.add(
      second.copyWith(selectedId: 'pads', selectedName: 'Drum pads'),
    );
    await tester.pumpAndSettle();
    expect(control.state.midiEdit, isNull);
    expect(find.byKey(const Key('midi_no_mappings')), findsOneWidget);
    expect(control.state.midiMappings.byId('m1'), _mapping());
    expect(find.byKey(const Key('midi_source_name')), findsNothing);
  });

  for (final status in [
    MidiConnectionStatus.connecting,
    MidiConnectionStatus.error,
    MidiConnectionStatus.deviceGone,
  ]) {
    testWidgets(
      '$status retains missing controller mappings and disables Learn',
      (
        tester,
      ) async {
        final unavailable = MidiConnection(
          selectedId: 'usb',
          selectedName: 'USB controller',
          status: status,
        );
        when(() => devices.connection).thenReturn(unavailable);
        await pump(tester, seeded: true);
        expect(find.byKey(const Key('midi_device_usb')), findsOneWidget);
        expect(find.byKey(const Key('midi_row_warning_m1')), findsOneWidget);
        await tap(tester, 'midi_row_edit_m1');
        expect(
          tester
              .widget<LoopOutlinedButton>(find.byKey(const Key('midi_learn')))
              .onTap,
          isNull,
        );
        await tap(tester, 'midi_cancel');
        expect(control.state.midiMappings.byId('m1'), _mapping());
      },
    );
  }

  testWidgets('no controller prevents adding an unaddressable mapping', (
    tester,
  ) async {
    when(() => devices.connection).thenReturn(const MidiConnection());
    await pump(tester);
    expect(find.byKey(const Key('midi_no_devices')), findsOneWidget);
    expect(
      tester
          .widget<LoopOutlinedButton>(find.byKey(const Key('midi_add_mapping')))
          .onTap,
      isNull,
    );
    expect(control.state.midiEdit, isNull);
  });

  testWidgets('failed None remains visible and can be retried', (tester) async {
    const failed = MidiConnection(
      devices: [MidiDevice(id: 'usb', name: 'USB controller')],
      status: MidiConnectionStatus.error,
      errorDetail: 'storage refused',
      pinUncertain: true,
    );
    when(() => devices.select('')).thenAnswer((_) async {
      connections.add(failed);
      throw StateError('storage refused');
    });
    await pump(tester);

    await tap(tester, 'midi_select_none');
    verify(() => devices.select('')).called(1);
    expect(find.byKey(const Key('midi_device_save_failed')), findsOneWidget);
    expect(find.byKey(const Key('midi_notice')), findsNothing);
    expect(find.text('Could not save MIDI device setting'), findsOneWidget);
    expect(
      tester
          .widget<LoopOutlinedButton>(find.byKey(const Key('midi_select_none')))
          .onTap,
      isNotNull,
    );

    when(() => devices.select('')).thenAnswer((_) async {
      connections.add(
        const MidiConnection(
          devices: [MidiDevice(id: 'usb', name: 'USB controller')],
        ),
      );
    });
    await tap(tester, 'midi_select_none');
    verify(() => devices.select('')).called(1);
    expect(find.byKey(const Key('midi_notice')), findsNothing);
    expect(find.byKey(const Key('midi_device_save_failed')), findsNothing);
    expect(
      tester
          .widget<LoopOutlinedButton>(find.byKey(const Key('midi_select_none')))
          .onTap,
      isNull,
    );
  });

  testWidgets('reopened page shows unresolved None failure', (tester) async {
    when(() => devices.connection).thenReturn(
      const MidiConnection(
        status: MidiConnectionStatus.error,
        errorDetail: 'storage refused',
        pinUncertain: true,
      ),
    );
    await pump(tester);

    expect(find.byKey(const Key('midi_device_save_failed')), findsOneWidget);
    expect(find.text('Could not save MIDI device setting'), findsOneWidget);
    expect(
      tester
          .widget<LoopOutlinedButton>(find.byKey(const Key('midi_select_none')))
          .onTap,
      isNotNull,
    );
  });

  testWidgets('unrelated successful control change does not hide device '
      'save failure', (tester) async {
    when(() => devices.connection).thenReturn(
      const MidiConnection(pinUncertain: true),
    );
    await pump(tester);
    expect(find.byKey(const Key('midi_device_save_failed')), findsOneWidget);

    await tap(tester, 'midi_control_enabled');

    expect(find.byKey(const Key('midi_notice')), findsOneWidget);
    expect(find.byKey(const Key('midi_device_save_failed')), findsOneWidget);
    expect(find.text('Could not save MIDI device setting'), findsOneWidget);
  });

  testWidgets('failed device selection stays visible and has a retry action', (
    tester,
  ) async {
    const choice = MidiConnection(
      devices: [
        MidiDevice(id: 'usb', name: 'USB controller'),
        MidiDevice(id: 'pads', name: 'Drum pads'),
      ],
      selectedId: 'usb',
      selectedName: 'USB controller',
      status: MidiConnectionStatus.connected,
    );
    final failed = choice.copyWith(
      selectedId: 'pads',
      selectedName: 'Drum pads',
      status: MidiConnectionStatus.error,
      pinUncertain: true,
    );
    when(() => devices.connection).thenReturn(choice);
    when(() => devices.select('pads')).thenAnswer((_) async {
      connections.add(failed);
      throw StateError('storage refused');
    });
    await pump(tester);
    await tap(tester, 'midi_device_pads');

    expect(find.byKey(const Key('midi_device_save_failed')), findsOneWidget);
    expect(find.byKey(const Key('midi_controller_disconnected')), findsNothing);
    expect(find.byKey(const Key('midi_retry_device')), findsOneWidget);
    expect(find.text('Could not save MIDI device setting'), findsOneWidget);

    when(() => devices.select('pads')).thenAnswer((_) async {
      connections.add(
        failed.copyWith(
          status: MidiConnectionStatus.connected,
          pinUncertain: false,
          clearError: true,
        ),
      );
    });
    await tap(tester, 'midi_retry_device');
    verify(() => devices.select('pads')).called(2);
    expect(find.byKey(const Key('midi_device_save_failed')), findsNothing);
    expect(find.byKey(const Key('midi_retry_device')), findsNothing);
  });

  testWidgets('reopened selected-device failure keeps Retry visible', (
    tester,
  ) async {
    when(() => devices.connection).thenReturn(
      const MidiConnection(
        devices: [MidiDevice(id: 'usb', name: 'USB controller')],
        selectedId: 'usb',
        selectedName: 'USB controller',
        status: MidiConnectionStatus.error,
        pinUncertain: true,
      ),
    );
    await pump(tester);

    expect(find.byKey(const Key('midi_device_save_failed')), findsOneWidget);
    expect(find.byKey(const Key('midi_retry_device')), findsOneWidget);
  });

  testWidgets('failed remote Off offers separate Retry Off and Resume On', (
    tester,
  ) async {
    await pump(tester);
    store.refuse = true;
    await tester.tap(find.byKey(const Key('midi_control_enabled')));
    await tester.pumpAndSettle();
    expect(control.state.midiControlEnabled, isTrue);
    expect(control.state.midiRemotePaused, isTrue);
    expect(find.text('Could not save MIDI control setting'), findsOneWidget);
    expect(find.text('Could not save MIDI device setting'), findsNothing);
    expect(find.byKey(const Key('midi_retry_off')), findsOneWidget);
    expect(find.byKey(const Key('midi_resume_on')), findsOneWidget);
    store.refuse = false;
    await tester.tap(find.byKey(const Key('midi_retry_off')));
    await tester.pumpAndSettle();
    expect(control.state.midiControlEnabled, isFalse);
    expect(control.state.midiRemotePaused, isTrue);
    expect(find.byKey(const Key('midi_retry_off')), findsNothing);
  });

  testWidgets('malformed saved payload needs deliberate confirmed reset', (
    tester,
  ) async {
    await pump(tester, malformed: true);
    expect(control.state.midiUnavailable, isTrue);
    expect(find.byKey(const Key('midi_add_mapping')), findsOneWidget);
    expect(find.byKey(const Key('midi_storage_notice')), findsNothing);
    expect(
      find.byKey(const Key('midi_configuration_unavailable')),
      findsOneWidget,
    );
    store.refuse = true;
    await tester.tap(find.byKey(const Key('midi_reset_configuration')));
    await tester.pumpAndSettle();
    expect(control.state.midiUnavailable, isTrue);
    expect(await store.getString('midi.configuration'), '{bad json');
    store.refuse = false;
    await tester.tap(find.byKey(const Key('midi_reset_configuration')));
    await tester.pumpAndSettle();
    expect(control.state.midiUnavailable, isFalse);
    expect(control.state.midiMappings.mappings, isEmpty);
    expect(find.byKey(const Key('midi_add_mapping')), findsOneWidget);
  });

  testWidgets('old route disposal cannot end a newer editor owner', (
    tester,
  ) async {
    await pump(tester, seeded: true);
    await tester.tap(find.byKey(const Key('midi_row_edit_m1')));
    await tester.pumpAndSettle();
    final newer = Object();
    control.beginMidiEdit(device: 'usb', owner: newer);
    await tester.pumpWidget(const SizedBox());
    expect(control.state.midiEdit?.owner, same(newer));
  });

  testWidgets('keyboard Enter opens the focused mapping row', (tester) async {
    await pump(tester, seeded: true);
    final row = find.byKey(const Key('midi_row_edit_m1'));
    Focus.of(tester.element(row)).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('midi_source_name')), findsOneWidget);
  });

  testWidgets('stale action picker result cannot retarget a newer owner', (
    tester,
  ) async {
    final missing = MidiMapping(
      id: 'm1',
      source: _source,
      behavior: MidiBehavior.momentary,
      controls: [
        MidiActionControl(key: 'retired:action', trigger: MidiEdge.release),
      ],
    );
    await pump(tester, savedMapping: missing);
    await tester.tap(find.byKey(const Key('midi_row_edit_m1')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('midi_control_change_retired:action')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const Key('midi_control_change_retired:action')),
    );
    await tester.pumpAndSettle();
    final newer = Object();
    control.beginMidiEdit(device: 'usb', owner: newer);
    Navigator.of(
      tester.element(find.byKey(const Key('pedal_choice_picker'))),
    ).pop(
      PedalChoiceResult<ControlAction?>(
        ControlAction.tryParse('command:undo'),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('midi_control_retired:action')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('midi_control_command:undo')), findsNothing);
  });

  testWidgets('repairing an unavailable action keeps its release edge', (
    tester,
  ) async {
    final missing = MidiMapping(
      id: 'm1',
      source: _source,
      behavior: MidiBehavior.momentary,
      controls: [
        MidiActionControl(key: 'retired:action', trigger: MidiEdge.release),
      ],
    );
    await pump(tester, savedMapping: missing);
    await tester.tap(find.byKey(const Key('midi_row_edit_m1')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('midi_control_change_retired:action')),
    );
    await tester.pumpAndSettle();
    Navigator.of(
      tester.element(find.byKey(const Key('pedal_choice_picker'))),
    ).pop(
      PedalChoiceResult<ControlAction?>(
        ControlAction.tryParse('command:undo'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('midi_control_command:undo')), findsOneWidget);
    expect(
      tester
          .widget<MidiSegmented<MidiEdge>>(
            find.byType(MidiSegmented<MidiEdge>),
          )
          .selected,
      MidiEdge.release,
    );
    await tester.tap(find.byKey(const Key('midi_save')));
    await tester.pumpAndSettle();
    final saved = control.state.midiMappings.byId('m1')!;
    expect((saved.controls.single as MidiActionControl).key, 'command:undo');
    expect(
      (saved.controls.single as MidiActionControl).trigger,
      MidiEdge.release,
    );
  });

  testWidgets('double tap resets both range endpoints in the draft only', (
    tester,
  ) async {
    await pump(tester, seeded: true);
    await tester.tap(find.byKey(const Key('midi_row_edit_m1')));
    await tester.pumpAndSettle();
    final key = const TrackVolumeTarget(0).canonicalString();
    final low = find.descendant(
      of: find.byKey(Key('midi_range_low_$key')),
      matching: find.byType(LoopSlider),
    );
    final high = find.descendant(
      of: find.byKey(Key('midi_range_high_$key')),
      matching: find.byType(LoopSlider),
    );
    await tester.tap(low);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(low);
    await tester.pumpAndSettle();
    expect(tester.widget<LoopSlider>(low).value, 0);
    expect(
      (control.state.midiMappings.byId('m1')!.controls.single
              as MidiParameterControl)
          .low,
      0.2,
    );
    await tester.tap(high);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(high);
    await tester.pumpAndSettle();
    expect(tester.widget<LoopSlider>(high).value, 1);
    expect(
      (control.state.midiMappings.byId('m1')!.controls.single
              as MidiParameterControl)
          .high,
      0.8,
    );
    await tester.tap(find.byKey(const Key('midi_save')));
    await tester.pumpAndSettle();
    final saved =
        control.state.midiMappings.byId('m1')!.controls.single
            as MidiParameterControl;
    expect((saved.low, saved.high), (0, 1));
  });

  testWidgets('Escape and focus loss restore unfinished range preview', (
    tester,
  ) async {
    await pump(tester, seeded: true);
    await tester.tap(find.byKey(const Key('midi_row_edit_m1')));
    await tester.pumpAndSettle();
    final key = const TrackVolumeTarget(0).canonicalString();
    final low = find.descendant(
      of: find.byKey(Key('midi_range_low_$key')),
      matching: find.byType(LoopSlider),
    );
    final high = find.descendant(
      of: find.byKey(Key('midi_range_high_$key')),
      matching: find.byType(LoopSlider),
    );
    Focus.of(
      tester.element(
        find
            .descendant(
              of: low,
              matching: find.byType(GestureDetector),
            )
            .first,
      ),
    ).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(tester.widget<LoopSlider>(low).value, closeTo(0.21, 0.0001));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(tester.widget<LoopSlider>(low).value, 0.2);

    Focus.of(
      tester.element(
        find
            .descendant(
              of: high,
              matching: find.byType(GestureDetector),
            )
            .first,
      ),
    ).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(tester.widget<LoopSlider>(high).value, closeTo(0.79, 0.0001));
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    expect(tester.widget<LoopSlider>(high).value, 0.8);
    final confirmed =
        control.state.midiMappings.byId('m1')!.controls.single
            as MidiParameterControl;
    expect((confirmed.low, confirmed.high), (0.2, 0.8));

    Focus.of(
      tester.element(
        find.descendant(of: low, matching: find.byType(GestureDetector)).first,
      ),
    ).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(tester.widget<LoopSlider>(low).value, closeTo(0.21, 0.0001));
    await tester.tap(find.byKey(const Key('midi_save')));
    await tester.pumpAndSettle();
    final saved =
        control.state.midiMappings.byId('m1')!.controls.single
            as MidiParameterControl;
    expect(saved.low, closeTo(0.21, 0.0001));
    expect(saved.high, 0.8);
  });

  testWidgets('Settings entry Stage pops MIDI route and ends edit owner', (
    tester,
  ) async {
    await pump(tester, seeded: true, routeEntry: true);
    unawaited(openMidiControls());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('midi_row_edit_m1')));
    await tester.pumpAndSettle();
    expect(control.state.midiEdit, isNotNull);
    await tester.tap(find.byKey(const Key('loop_settings_stage')));
    await tester.pumpAndSettle();
    expect(find.text('Stage root'), findsOneWidget);
    expect(find.byKey(const Key('midi_controls_page')), findsNothing);
    expect(control.state.midiEdit, isNull);
  });

  testWidgets('Control tray entry Stage closes tray and MIDI route', (
    tester,
  ) async {
    await pump(tester, seeded: true, routeEntry: true);
    tray.open();
    expect(tray.state.dragProgress, 1);
    unawaited(openMidiControls(onStage: tray.closeTray));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('midi_row_edit_m1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('loop_settings_stage')));
    await tester.pumpAndSettle();
    expect(tray.state.dragProgress, 0);
    expect(find.text('Stage root'), findsOneWidget);
    expect(find.byKey(const Key('midi_controls_page')), findsNothing);
    expect(control.state.midiEdit, isNull);
  });

  testWidgets('activation endpoints are binary and remain a draft until Save', (
    tester,
  ) async {
    const activation = FxChainTarget(FxAddress(stage: FxStage.allTracks));
    when(() => looper.allTracksEffects).thenReturn(const []);
    when(() => looper.allTracksChainEnabled).thenReturn(true);
    final saved = MidiMapping(
      id: 'm1',
      source: _source,
      behavior: MidiBehavior.momentary,
      controls: [
        MidiParameterControl(
          key: activation.canonicalString(),
          low: 0,
          high: 1,
        ),
      ],
    );
    await pump(tester, savedMapping: saved);
    await tester.tap(find.byKey(const Key('midi_row_edit_m1')));
    await tester.pumpAndSettle();
    final key = activation.canonicalString();
    expect(find.byKey(Key('midi_range_low_$key')), findsNothing);
    await tester.tap(find.byKey(Key('midi_activation_low_${key}_true')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('midi_activation_high_${key}_false')));
    await tester.pumpAndSettle();
    expect(control.state.midiMappings.byId('m1'), saved);
    await tester.tap(find.byKey(const Key('midi_save')));
    await tester.pumpAndSettle();
    final persisted =
        control.state.midiMappings.byId('m1')!.controls.single
            as MidiParameterControl;
    expect(persisted.low, 1);
    expect(persisted.high, 0);
  });

  testWidgets('saved FX activation stays available and can be authored', (
    tester,
  ) async {
    const activation = FxChainTarget(FxAddress(stage: FxStage.allTracks));
    when(() => looper.allMonitors()).thenReturn(const {});
    when(() => looper.allLaneChains()).thenReturn(const {});
    when(() => looper.allTracksEffects).thenReturn(const []);
    when(() => looper.allTracksChainEnabled).thenReturn(true);
    final saved = MidiMapping(
      id: 'm1',
      source: _source,
      behavior: MidiBehavior.toggle,
      controls: [
        MidiParameterControl(
          key: activation.canonicalString(),
          low: 0,
          high: 1,
        ),
      ],
    );
    await pump(tester, savedMapping: saved);
    expect(find.byKey(const Key('midi_row_warning_m1')), findsNothing);
    await tester.tap(find.byKey(const Key('midi_row_edit_m1')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(Key('midi_control_${activation.canonicalString()}')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(Key('midi_control_remove_${activation.canonicalString()}')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('midi_add_control')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('expression_kind_recordedTrack')),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const Key('expression_destination_allTracks')),
      250,
      scrollable: find
          .descendant(
            of: find.byType(GridView),
            matching: find.byType(Scrollable),
          )
          .last,
    );
    await tester.ensureVisible(
      find.byKey(const Key('expression_destination_allTracks')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('expression_destination_allTracks')),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(Key('external_pick_${externalControlKey(activation)}')),
      150,
      scrollable: find.byType(Scrollable).last,
    );
    expect(
      find.byKey(Key('external_pick_${externalControlKey(activation)}')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(Key('external_pick_${externalControlKey(activation)}')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('midi_save')));
    await tester.pumpAndSettle();
    expect(
      (control.state.midiMappings.byId('m1')!.controls.single
              as MidiParameterControl)
          .key,
      activation.canonicalString(),
    );
  });
}
