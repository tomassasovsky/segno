import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:segno/app/fx_chain_persistence.dart';
import 'package:segno/audio_setup/audio_setup.dart';
import 'package:segno/control/control.dart';
import 'package:segno/looper/application/record_settings.dart';
import 'package:segno/looper/application/record_timing_settings.dart';
import 'package:segno/looper/application/tempo_settings.dart';
import 'package:segno/looper/looper.dart';
import 'package:segno/pedal/pedal.dart';
import 'package:segno/setup/setup_surface.dart';
import 'package:settings_repository/settings_repository.dart' hide AudioBackend;

import '../../helpers/helpers.dart';

class _MockAudioSetupCubit extends MockCubit<AudioSetupState>
    implements AudioSetupCubit {}

class _MockMidiSetupCubit extends MockCubit<MidiSetupState>
    implements MidiSetupCubit {}

class _MockPedalCubit extends MockCubit<PedalState> implements PedalCubit {}

class _MockLooperRepository extends Mock implements LooperRepository {}

class _MockControlCubit extends MockCubit<ControlState>
    implements ControlCubit {}

void main() {
  late TempoSettings tempoOwner;
  setUpAll(() => registerFallbackValue(RecordTiming.immediately));

  late AudioSetupCubit cubit;
  late MidiSetupCubit midi;
  late PedalCubit pedal;
  late MonitorCubit monitor;
  late RecordTimingCubit quantize;
  late RecordSettings recordOptions;
  // The MIDI-learn section (part 7) reads the mapping set off ControlCubit and
  // enumerates its targets from the looper repository.
  late ControlCubit control;
  late TracksCubit tracks;
  late TempoCubit tempo;
  late LooperRepository looper;
  late RecordTiming confirmedTiming;
  late GridDivision rememberedDivision;
  var confirmedCountIn = 1;
  var confirmedSoundStart = false;
  var startRecovering = false;
  var startCaptureLocked = false;
  late StreamController<LooperState> stateChanges;

  setUpAll(() {
    registerFallbackValue(MonitorMode.off);
    registerFallbackValue(GridDivision.off);
    registerFallbackValue(<int, RecordTiming>{});
    registerFallbackValue(RecordStartEditKind.restore);
  });
  setUp(() {
    confirmedCountIn = 1;
    confirmedSoundStart = false;
    startRecovering = false;
    startCaptureLocked = false;
    stateChanges = StreamController<LooperState>.broadcast();
    addTearDown(stateChanges.close);
    confirmedTiming = RecordTiming.immediately;
    rememberedDivision = GridDivision.off;
    tracks = TracksCubit(
      settings: SettingsRepository(store: FakeKeyValueStore()),
    );
    cubit = _MockAudioSetupCubit();
    midi = _MockMidiSetupCubit();
    when(() => midi.state).thenReturn(const MidiSetupState());
    whenListen(
      midi,
      const Stream<MidiSetupState>.empty(),
      initialState: const MidiSetupState(),
    );
    pedal = _MockPedalCubit();
    when(() => pedal.state).thenReturn(const PedalState());
    whenListen(
      pedal,
      const Stream<PedalState>.empty(),
      initialState: const PedalState(),
    );
    final repository = _MockLooperRepository();
    when(() => repository.clickModeFailures).thenAnswer(
      (_) => const Stream<EngineResult>.empty(),
    );
    when(() => repository.clickVolumeFailures).thenAnswer(
      (_) => const Stream<EngineResult>.empty(),
    );
    when(() => repository.clickModeCaptureLocked).thenReturn(false);
    when(() => repository.clickModeSettled).thenReturn(true);
    when(() => repository.clickVolumeSettled).thenReturn(true);
    when(() => repository.clickVolumeRecoveryRequired).thenReturn(false);
    when(() => repository.recordStartSettingsFailures).thenAnswer(
      (_) => const Stream<EngineResult>.empty(),
    );
    when(() => repository.recordStartSettingsSettled).thenReturn(true);
    when(() => repository.recordStartRecoveryRequired).thenAnswer(
      (_) => startRecovering,
    );
    when(() => repository.recordStartCaptureLocked).thenAnswer(
      (_) => startCaptureLocked,
    );
    when(() => repository.recordLengthCaptureLocked).thenAnswer(
      (_) => startCaptureLocked,
    );
    when(() => repository.recordStartSettings).thenAnswer(
      (_) => (
        countInBars: confirmedCountIn,
        soundStart: confirmedSoundStart,
      ),
    );
    when(() => repository.recordStartRestartIntent).thenAnswer(
      (_) => (
        countInBars: confirmedCountIn,
        soundStart: confirmedSoundStart,
      ),
    );
    when(repository.settleRecordStartSettings).thenAnswer(
      (_) async => EngineResult.ok,
    );
    when(
      () => repository.setRecordStartSettings(
        countInBars: any(named: 'countInBars'),
        soundStart: any(named: 'soundStart'),
        editKind: any(named: 'editKind'),
        releasedSettings: any(named: 'releasedSettings'),
      ),
    ).thenAnswer((call) {
      confirmedCountIn = call.namedArguments[#countInBars] as int;
      confirmedSoundStart = call.namedArguments[#soundStart] as bool;
      return EngineResult.ok;
    });
    when(() => repository.sessionRevision).thenReturn(0);
    when(() => repository.mixGeneration).thenReturn(0);
    when(() => repository.inputSetup).thenReturn(const InputSetup.empty());
    when(() => repository.laneCount(any())).thenReturn(1);
    when(() => repository.fxReplayConfirmed).thenAnswer(
      (_) => const Stream<({int mixGeneration, int sessionRevision})>.empty(),
    );
    looper = repository;
    when(
      () => repository.setMonitorInputMode(
        input: any(named: 'input'),
        mode: any(named: 'mode'),
      ),
    ).thenReturn(EngineResult.ok);
    when(() => repository.recordTimingFailures).thenAnswer(
      (_) => const Stream<EngineResult>.empty(),
    );
    when(() => repository.recordTimingSettingsSettled).thenReturn(true);
    when(() => repository.recordTimingRecoveryRequired).thenReturn(false);
    when(() => repository.recordTimingCaptureLocked).thenReturn(false);
    when(
      () => repository.defaultRecordTiming,
    ).thenAnswer((_) => confirmedTiming);
    when(() => repository.trackRecordTimingOverrides).thenReturn(const {});
    when(() => repository.recordTimingRestartIntent).thenAnswer(
      (_) => (
        defaultTiming: confirmedTiming,
        rememberedDivision: rememberedDivision,
        trackOverrides: const <int, RecordTiming>{},
      ),
    );
    when(() => repository.sessionTransport).thenAnswer(
      (_) => TransportState(
        recordTiming: confirmedTiming,
        quantizeDiv: rememberedDivision,
        countInBars: confirmedCountIn,
        autoRecord: confirmedSoundStart,
      ),
    );
    when(repository.settleRecordTimingSettings).thenAnswer(
      (_) async => EngineResult.ok,
    );
    when(
      () => repository.setRecordTimingSettings(
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
    when(
      () => repository.setRecordTiming(
        any(),
        releasedTiming: any(named: 'releasedTiming'),
      ),
    ).thenAnswer((call) {
      confirmedTiming = call.positionalArguments.single as RecordTiming;
      if (confirmedTiming.quantize) {
        rememberedDivision = confirmedTiming.division;
      }
      return EngineResult.ok;
    });
    when(
      () => repository.setRecDub(enabled: any(named: 'enabled')),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.setDefaultMultiple(multiple: any(named: 'multiple')),
    ).thenReturn(EngineResult.ok);
    when(() => repository.setClickOutput(any())).thenReturn(EngineResult.ok);
    when(() => repository.setClickVolume(any())).thenReturn(EngineResult.ok);
    control = _MockControlCubit();
    when(() => control.state).thenReturn(const ControlState());
    whenListen(
      control,
      const Stream<ControlState>.empty(),
      initialState: const ControlState(),
    );
    when(() => repository.monitorChanges).thenAnswer(
      (_) => const Stream<int>.empty(),
    );
    when(() => repository.monitorParamChanges).thenAnswer(
      (_) => const Stream<int>.empty(),
    );
    when(repository.allMonitors).thenReturn(const {});
    when(repository.allLaneChains).thenReturn(const {});
    when(repository.allTrackChains).thenReturn(const {});
    when(() => repository.outputEffects(0)).thenReturn(const []);
    when(() => repository.allTracksEffects).thenReturn(const []);
    when(() => repository.state).thenReturn(const LooperState());
    when(() => repository.looperState).thenAnswer((_) => stateChanges.stream);
    when(() => repository.lengthSettingsFailures).thenAnswer(
      (_) => const Stream<EngineResult>.empty(),
    );
    when(repository.allOutputChains).thenReturn(const {});
    final settings = SettingsRepository(store: FakeKeyValueStore());
    monitor = MonitorCubit(
      fxPersistence: FxChainPersistence(looper: repository),
      mixSettings: testMixSettings(repository),
      repository: repository,
      settings: settings,
    );
    recordOptions = RecordSettings(
      repository: repository,
      settings: settings,
    );
  });

  void seed(AudioSetupState state) {
    when(() => cubit.state).thenReturn(state);
    whenListen(
      cubit,
      const Stream<AudioSetupState>.empty(),
      initialState: state,
    );
  }

  Future<void> pumpSection(
    WidgetTester tester, {
    bool loadRecordStart = true,
  }) async {
    final timingSettings = SettingsRepository(store: FakeKeyValueStore());
    tempoOwner = TempoSettings(
      repository: looper,
      settings: timingSettings,
    );
    final closeTempoOwner = tempoOwner.close;
    addTearDown(() => unawaited(closeTempoOwner()));
    tempo = TempoCubit(settings: tempoOwner);
    addTearDown(() => unawaited(tempo.close()));
    if (loadRecordStart) await tempoOwner.recordStartOwner.load();
    final quantizeOwner = RecordTimingSettings(
      repository: looper,
      settings: timingSettings,
    );
    addTearDown(() => unawaited(quantizeOwner.close()));
    quantize = RecordTimingCubit(settings: quantizeOwner);
    addTearDown(() => unawaited(quantize.close()));
    await quantizeOwner.load();
    await tester.pumpApp(
      MultiBlocProvider(
        providers: [
          BlocProvider<AudioSetupCubit>.value(value: cubit),
          BlocProvider<MidiSetupCubit>.value(value: midi),
          BlocProvider<PedalCubit>.value(value: pedal),
          BlocProvider<MonitorCubit>.value(value: monitor),
          BlocProvider<RecordTimingCubit>.value(value: quantize),
          BlocProvider<RecordOptionsCubit>(
            create: (_) => RecordOptionsCubit(settings: recordOptions),
          ),
          BlocProvider<ControlCubit>.value(value: control),
          BlocProvider<TracksCubit>.value(value: tracks),
          BlocProvider<TempoCubit>.value(value: tempo),
        ],
        child: RepositoryProvider<LooperRepository>.value(
          value: looper,
          child: const Material(
            child: SingleChildScrollView(child: AudioSettingsSection()),
          ),
        ),
      ),
    );
  }

  const runningState = AudioSetupState(
    status: AudioSetupStatus.running,
    devices: [
      AudioDevice(
        id: 'out-1',
        name: 'Scarlett 4i4',
        isDefault: true,
        isInput: false,
      ),
      AudioDevice(
        id: 'in-1',
        name: 'Scarlett Input 1',
        isDefault: true,
        isInput: true,
      ),
    ],
    engineStatus: EngineStatus(
      deviceName: 'Scarlett 4i4',
      sampleRate: 48000,
      bufferFrames: 128,
      isConnected: true,
      latencyState: LatencyState.done,
      measuredLatencyMs: 9.5,
      recordOffsetFrames: 456,
    ),
  );

  testWidgets('renders device pickers and the live status', (tester) async {
    seed(runningState);
    await pumpSection(tester);

    expect(
      find.byKey(const Key('audioSettings_playbackDevice_picker')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('audioSettings_captureDevice_picker')),
      findsOneWidget,
    );
    // Sample-rate and buffer selectors are editable in settings.
    expect(
      find.byKey(const Key('audioSettings_sampleRate_48000')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('audioSettings_bufferSize_128')),
      findsOneWidget,
    );
    // Live status reflects the running engine + restored/measured latency.
    // "48000 Hz" appears twice: the sample-rate selector option and the status.
    expect(find.text('48000 Hz'), findsNWidgets(2));
    expect(find.text('128 frames'), findsOneWidget);
    expect(find.text('9.50 ms'), findsOneWidget);
    expect(find.text('456 frames'), findsOneWidget);
  });

  testWidgets('the click level sits under the output device, and its routing '
      'is not here', (tester) async {
    // WHEN the click sounds is a Loop setting and WHERE it goes is Audio
    // routing's; how loud it is has nowhere else to live until the Mixer
    // holds it, so it stays beside the device.
    seed(runningState);
    await pumpSection(tester);

    final picker = find.byKey(const Key('audioSettings_playbackDevice_picker'));
    final section = find.byKey(const Key('audioSettings_clickVolume_section'));
    expect(section, findsOneWidget);
    expect(
      tester.getTopLeft(section).dy,
      greaterThan(tester.getBottomLeft(picker).dy),
    );
    expect(find.byKey(const Key('audioSettings_clickOutput_1')), findsNothing);
  });

  testWidgets('a setup option card is a focusable, selectable button (a11y)', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    seed(runningState);
    await pumpSection(tester);

    // The stepped option cards (sample rate, buffer, …) must be keyboard-
    // operable and expose their selected state, not bare GestureDetectors.
    expect(
      tester.getSemantics(
        find.byKey(const Key('audioSettings_sampleRate_48000')),
      ),
      isSemantics(isButton: true, hasTapAction: true, isSelected: true),
    );
    handle.dispose();
  });

  testWidgets('selecting a playback device forwards to the cubit', (
    tester,
  ) async {
    seed(runningState);
    await pumpSection(tester);

    await tester.tap(
      find.byKey(const Key('audioSettings_playbackDevice_picker')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Scarlett 4i4').last);
    await tester.pumpAndSettle();

    verify(() => cubit.setPlaybackDevice('out-1')).called(1);
  });

  testWidgets('selecting a capture device forwards to the cubit', (
    tester,
  ) async {
    seed(runningState);
    await pumpSection(tester);

    await tester.tap(
      find.byKey(const Key('audioSettings_captureDevice_picker')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Scarlett Input 1').last);
    await tester.pumpAndSettle();

    verify(() => cubit.setCaptureDevice('in-1')).called(1);
  });

  testWidgets('the measure button triggers a measurement', (tester) async {
    seed(runningState);
    await pumpSection(tester);

    final button = find.byKey(const Key('audioSettings_measure_button'));
    await tester.ensureVisible(button);
    await tester.tap(button);
    verify(cubit.measureLatency).called(1);
  });

  testWidgets('manual record offset applies to the cubit', (tester) async {
    seed(runningState);
    await pumpSection(tester);

    final field = find.byKey(const Key('audioSettings_recordOffset_field'));
    await tester.ensureVisible(field);
    await tester.enterText(field, '257');
    final apply = find.byKey(const Key('audioSettings_recordOffset_apply'));
    await tester.ensureVisible(apply);
    await tester.tap(apply);
    verify(() => cubit.setRecordOffset(257)).called(1);
  });

  testWidgets('no monitoring controls remain in Audio Setup', (tester) async {
    seed(
      const AudioSetupState(
        status: AudioSetupStatus.running,
        engineStatus: EngineStatus(
          deviceName: 'Scarlett 4i4',
          sampleRate: 48000,
          bufferFrames: 128,
          isConnected: true,
          inputChannels: 2,
          outputChannels: 2,
        ),
      ),
    );
    await pumpSection(tester);

    // Monitoring is now live performance on the Signal surface, so Audio Setup
    // keeps only device/SR/buffer/latency — no monitor toggle or graph entry.
    expect(
      find.byKey(const Key('audioSettings_monitor_switch')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('audioSettings_openMonitorGraph')),
      findsNothing,
    );
  });

  testWidgets('toggling quantize recording forwards to the quantize cubit', (
    tester,
  ) async {
    seed(runningState);
    await pumpSection(tester);
    expect(quantize.state.defaultTiming.quantize, isFalse);

    final toggle = find.byKey(const Key('audioSettings_quantize_switch'));
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();

    expect(quantize.state.defaultTiming.quantize, isTrue);
  });

  testWidgets('the rec/dub and sound-activated toggles forward to the cubit', (
    tester,
  ) async {
    seed(runningState);
    await pumpSection(tester);
    expect(recordOptions.state.recDub, isFalse);
    expect(tempo.state.confirmedRecordStart?.soundStart, isFalse);
    expect(tempo.state.recordStartSnapshot?.canEdit, isTrue);

    final recDub = find.byKey(const Key('audioSettings_recDub_switch'));
    await tester.ensureVisible(recDub);
    await tester.tap(recDub);
    await tester.pumpAndSettle();
    expect(recordOptions.state.recDub, isTrue);

    final autoRecord = find.byKey(
      const Key('audioSettings_autoRecord_switch'),
    );
    await tester.ensureVisible(autoRecord);
    await tester.tap(autoRecord);
    await tester.pumpAndSettle();
    await tester.runAsync(tempoOwner.recordStartOwner.flush);
    await tester.pump();
    expect(tempo.state.confirmedRecordStart?.soundStart, isTrue);
    expect(tempo.state.confirmedRecordStart?.countInBars, 0);
  });

  testWidgets('unconfirmed Sound shows an unavailable readout, not Off', (
    tester,
  ) async {
    seed(runningState);
    await pumpSection(tester, loadRecordStart: false);
    final control = find.byKey(const Key('audioSettings_autoRecord_switch'));
    await tester.ensureVisible(control);
    expect(control, findsOneWidget);
    expect(control.evaluate().single.widget, isNot(isA<Switch>()));
    expect(tempo.state.confirmedRecordStart, isNull);
    expect(find.text('—'), findsWidgets);
  });

  testWidgets('Sound retains its choice but refuses edits during recovery', (
    tester,
  ) async {
    seed(runningState);
    await pumpSection(tester);
    final control = find.byKey(const Key('audioSettings_autoRecord_switch'));
    await tester.ensureVisible(control);
    await tester.tap(control);
    await tester.pumpAndSettle();
    expect(tempo.state.confirmedRecordStart?.soundStart, isTrue);

    startRecovering = true;
    stateChanges.add(const LooperState());
    await tester.pumpAndSettle();
    expect(tempo.state.recordStartSnapshot, isNull);
    final toggle = tester.widget<SetupToggleRow>(
      find.ancestor(of: control, matching: find.byType(SetupToggleRow)),
    );
    expect(toggle.value, isTrue);
    expect(toggle.onChanged, isNull);
    expect(find.text('Recording start is unavailable.'), findsOneWidget);
    clearInteractions(looper);
    await tester.ensureVisible(control);
    await tester.tap(control);
    await tester.pumpAndSettle();
    verifyNever(
      () => looper.setRecordStartSettings(
        countInBars: any(named: 'countInBars'),
        soundStart: any(named: 'soundStart'),
        editKind: any(named: 'editKind'),
        releasedSettings: any(named: 'releasedSettings'),
      ),
    );
  });

  testWidgets('Sound is disabled during capture without changing the pair', (
    tester,
  ) async {
    seed(runningState);
    await pumpSection(tester);
    final control = find.byKey(const Key('audioSettings_autoRecord_switch'));
    startCaptureLocked = true;
    stateChanges.add(const LooperState());
    await tester.pumpAndSettle();
    final toggle = tester.widget<SetupToggleRow>(
      find.ancestor(of: control, matching: find.byType(SetupToggleRow)),
    );
    expect(toggle.value, isFalse);
    expect(toggle.onChanged, isNull);
    expect(tempo.state.recordStartSnapshot?.captureLocked, isTrue);
    clearInteractions(looper);
    await tester.ensureVisible(control);
    await tester.tap(control);
    await tester.pumpAndSettle();
    verifyNever(
      () => looper.setRecordStartSettings(
        countInBars: any(named: 'countInBars'),
        soundStart: any(named: 'soundStart'),
        editKind: any(named: 'editKind'),
        releasedSettings: any(named: 'releasedSettings'),
      ),
    );
  });

  testWidgets('choosing a default loop length forwards to the cubit', (
    tester,
  ) async {
    seed(runningState);
    await pumpSection(tester);
    expect(recordOptions.state.defaultMultiple, 0);

    final x2 = find.byKey(const Key('audioSettings_defaultMultiple_2'));
    await tester.ensureVisible(x2);
    await tester.tap(x2);
    await tester.pumpAndSettle();

    expect(recordOptions.state.defaultMultiple, 2);
  });

  testWidgets('choosing a max loop length forwards to the cubit', (
    tester,
  ) async {
    seed(runningState); // maxLoopMinutes defaults to 0 (engine default)
    await pumpSection(tester);

    final option = find.byKey(const Key('audioSettings_maxLoop_5'));
    await tester.ensureVisible(option);
    await tester.tap(option);
    verify(() => cubit.setMaxLoopMinutes(5)).called(1);
  });

  testWidgets('shows a measuring label while a measurement is in flight', (
    tester,
  ) async {
    seed(
      const AudioSetupState(
        status: AudioSetupStatus.running,
        engineStatus: EngineStatus(
          deviceName: 'Scarlett 4i4',
          sampleRate: 48000,
          bufferFrames: 128,
          isConnected: true,
          latencyState: LatencyState.measuring,
        ),
      ),
    );
    await pumpSection(tester);

    // Both the status row and the action button reflect the measuring state.
    expect(find.text('Measuring…'), findsWidgets);
  });

  testWidgets('shows the not-running status before the engine starts', (
    tester,
  ) async {
    seed(const AudioSetupState()); // stopped, empty engine status
    await pumpSection(tester);

    expect(find.text('Not running'), findsOneWidget);
    expect(find.text('Not measured'), findsOneWidget);
  });

  group('console mode', () {
    testWidgets('hides the MIDI input picker', (tester) async {
      // The pedal is the console board on its own link, so a chooser would
      // only ever offer the one answer.
      seed(runningState);
      await pumpSection(tester);

      expect(find.byKey(const Key('midiSettings_section')), findsNothing);
    });

    testWidgets('keeps the pedal section reachable', (tester) async {
      // Hiding the pedal CONFIG alongside the pedal PICKER left the console
      // with no route to the assignment surface at all — the build most
      // likely to need a footswitch remapped, and the only one with no
      // alternative way in. The section stays; it drops its own picker.
      seed(runningState);
      await pumpSection(tester);

      expect(find.byKey(const Key('pedalSettings_section')), findsOneWidget);
      expect(
        find.byKey(const Key('pedalSettings_openAssignments')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('pedalSettings_device_picker')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('audioSettings_playbackDevice_picker')),
        findsOneWidget,
      );
    });

    testWidgets('omits System default from audio device menus', (tester) async {
      seed(runningState);
      await pumpSection(tester);

      await tester.tap(
        find.byKey(const Key('audioSettings_playbackDevice_picker')),
      );
      await tester.pumpAndSettle();

      expect(find.text('System default'), findsNothing);
      expect(find.textContaining('System default ('), findsNothing);
      expect(find.text('Scarlett 4i4').hitTestable(), findsWidgets);
    });
  });

  group('error banner', () {
    testWidgets('renders the engine error and detail when status is error', (
      tester,
    ) async {
      seed(
        const AudioSetupState(
          status: AudioSetupStatus.error,
          error: AudioSetupError.openDeviceFailed,
          errorDetail: 'device',
        ),
      );
      await pumpSection(tester);

      expect(
        find.byKey(const Key('audioSettings_error_banner')),
        findsOneWidget,
      );
    });

    testWidgets('is absent when there is no error', (tester) async {
      seed(runningState);
      await pumpSection(tester);

      expect(
        find.byKey(const Key('audioSettings_error_banner')),
        findsNothing,
      );
    });
  });
}
