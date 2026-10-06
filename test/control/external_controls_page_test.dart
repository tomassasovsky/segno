import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fx_catalogue/fx_catalogue.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:performance_repository/performance_repository.dart';
import 'package:routing_graph/routing_graph.dart';
import 'package:segno/app/fx_chain_persistence.dart';
import 'package:segno/control/binding/external_controls.dart';
import 'package:segno/control/binding/external_pedal.dart';
import 'package:segno/control/binding/mix_value_scale.dart';
import 'package:segno/control/control.dart';
import 'package:segno/control/view/pedal_setup/control_row_list.dart';
import 'package:segno/control/view/pedal_setup/external_controls_editor.dart';
import 'package:segno/control/view/pedal_setup/external_pedal_page.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/application/fade_settings.dart';
import 'package:segno/looper/application/record_settings.dart';
import 'package:segno/looper/application/record_timing_settings.dart';
import 'package:segno/looper/cubit/playback_options_cubit.dart';
import 'package:segno/looper/cubit/record_options_cubit.dart';
import 'package:segno/looper/cubit/record_timing_cubit.dart';
import 'package:segno/looper/cubit/tempo_cubit.dart';
import 'package:segno/looper/cubit/tracks_cubit.dart';
import 'package:segno/looper/model/click_mode.dart';
import 'package:segno/looper/model/one_shot.dart';
import 'package:segno/looper/model/overdub_decay.dart';
import 'package:segno/looper/model/record_start.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/pedal/cubit/pedal_cubit.dart';
import 'package:segno/theme/theme.dart';
import 'package:settings_repository/settings_repository.dart';

import '../helpers/fake_audio_engine.dart';
import '../helpers/fake_key_value_store.dart';
import '../helpers/mock_click_tempo_settings.dart';
import '../helpers/mock_decay_playback_settings.dart';
import '../helpers/test_fade_settings.dart';
import '../helpers/test_mix_settings.dart';

class _MockLooperRepository extends Mock implements LooperRepository {}

/// A button's Controls panel: the effects and parameters it drives beside its
/// actions.
void main() {
  late _MockLooperRepository looper;
  late StreamController<LooperState> looperStates;
  late SettingsRepository settings;
  late ControlCubit control;
  late RecordSettings record;
  late RecordTimingCubit timing;
  late RecordTiming confirmedTiming;
  late GridDivision rememberedDivision;
  late MockClickTempoSettings tempo;

  const drive = FxSlotTarget(
    address: FxAddress(stage: FxStage.track),
    slotId: 'drive-1',
  );

  setUp(() {
    looper = _MockLooperRepository();
    confirmedTiming = RecordTiming.immediately;
    rememberedDivision = GridDivision.off;
    when(() => looper.sessionRevision).thenReturn(0);
    when(() => looper.mixGeneration).thenReturn(0);
    when(() => looper.mixSettingsSettled).thenReturn(true);
    when(() => looper.mixSettingsSnapshot).thenReturn(
      MixSettingsSnapshot(trackLevels: const {0: 0.4, 1: 1}),
    );
    when(() => looper.laneCount(any())).thenReturn(1);
    when(() => looper.inputSetup).thenReturn(const InputSetup.empty());
    looperStates = StreamController<LooperState>.broadcast();
    when(() => looper.looperState).thenAnswer((_) => looperStates.stream);
    when(() => looper.state).thenReturn(
      const LooperState(
        tracks: [Track(volume: 0.4), Track(channel: 1)],
        status: EngineStatus(sampleRate: 48000),
      ),
    );
    when(
      () => looper.allTrackChains(),
    ).thenReturn(const {0: FxChainEnvelope()});
    when(() => looper.trackEffects(0)).thenReturn([
      BuiltInEffect(
        type: TrackEffectType.drive,
        slotId: 'drive-1',
        module: 'Overdrive',
      ),
    ]);
    when(() => looper.trackEffects(1)).thenReturn(const []);
    when(() => looper.monitorEffects(any())).thenReturn(const []);
    when(() => looper.laneEffects(any(), any())).thenReturn(const []);
    when(() => looper.outputEffects(any())).thenReturn(const []);
    when(() => looper.allTracksEffects).thenReturn(const []);
    when(() => looper.allMonitors()).thenReturn(const {});
    when(() => looper.allLaneChains()).thenReturn(const {});
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
    when(
      () => looper.setVolume(any(), channel: any(named: 'channel')),
    ).thenReturn(EngineResult.ok);
  });

  setUpAll(() {
    registerFallbackValue(LooperMode.multi);
    registerFallbackValue(RecordTiming.immediately);
    registerFallbackValue(GridDivision.off);
    registerFallbackValue(ClickMode.off);
    registerFallbackValue(RecordStartEditKind.countIn);
    registerFallbackValue(<int, RecordTiming>{});
  });

  tearDown(() async {
    await looperStates.close();
  });

  Future<void> pump(
    WidgetTester tester, {
    ExternalJackSetup? jack,
    double? clickVolume = 1,
    ClickModeSnapshot? clickModeSnapshot,
    RecordStartSnapshot? recordStartSnapshot,
    DecaySnapshot? decaySnapshot,
    OneShotSnapshot? oneShotSnapshot,
  }) async {
    settings = SettingsRepository(store: FakeKeyValueStore());
    await settings.restoreRecordTimingCheckpoint((
      quantize: false,
      division: GridDivision.off.code,
      trackOverrides: {},
    ));
    tester.view
      ..physicalSize = const Size(1920, 1080)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final performance = PerformanceRepository(
      engine: FakeAudioEngine(),
      exportsRoot: () async => '.',
    );
    addTearDown(performance.dispose);
    final pedal = PedalRepository(NoopPedalLink());
    addTearDown(() => unawaited(pedal.dispose()));
    final mixSettings = testMixSettings(looper, settings: settings);
    addTearDown(() => unawaited(mixSettings.close()));
    final pedalCubit = PedalCubit(pedal: pedal);
    addTearDown(() => unawaited(pedalCubit.close()));
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
      fxPersistence: FxChainPersistence(looper: looper),
      looper: looper,
      clickVolumeControl: tempo,
      clickModeControl: tempo,
      recordStartControl: tempo,
      decayControl: playback,
      oneShotControl: playback,
      recordLengthControl: record,
      recordTimingControl: timingOwner,
      mixSettings: mixSettings,
      pedal: pedal,
      settings: settings,
      performance: performance,
    );
    final tracks = TracksCubit(settings: settings);
    // unawaited: awaiting a cubit close inside a testWidgets body deadlocks
    // on the binding's stream cancellation (flutter/flutter#139870).
    addTearDown(() => unawaited(control.close()));
    addTearDown(() => unawaited(tracks.close()));
    await control.load();
    if (jack != null) {
      await control.setPedalSetup(
        control.state.pedalSetup.copyWith(
          external: ExternalPedalSetup().withJack(
            PedalCtrlJack.ctrl1,
            jack,
          ),
        ),
      );
    }

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: ThemeData(
          extensions: [
            SurfaceTheme.dark,
            routingGraphThemeFromSurface(SurfaceTheme.dark),
          ],
        ),
        home: MultiRepositoryProvider(
          providers: [
            RepositoryProvider<LooperRepository>.value(value: looper),
            RepositoryProvider<FadeSettings>.value(value: fade),
            RepositoryProvider<PedalRepository>.value(value: pedal),
          ],
          child: MultiBlocProvider(
            providers: [
              BlocProvider.value(value: control),
              BlocProvider.value(value: tracks),
              BlocProvider.value(value: pedalCubit),
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
            child: const ExternalPedalPage(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester, String key) async {
    await tester.tap(find.byKey(Key(key)), warnIfMissed: false);
    await tester.pumpAndSettle();
  }

  Future<void> activate(WidgetTester tester, String key) async {
    final anchor = find.byKey(Key(key));
    final gesture = find.descendant(
      of: anchor,
      matching: find.byType(GestureDetector),
    );
    Focus.of(
      tester.element(gesture.evaluate().isEmpty ? anchor : gesture),
    ).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
  }

  ExternalControls saved() => control.state.pedalSetup.external
      .forJack(PedalCtrlJack.ctrl1)
      .single
      .controls;

  Future<void> openPicker(WidgetTester tester) async {
    await tap(tester, 'external_panel_controls');
    await tap(tester, 'external_add_control');
    await tap(tester, 'expression_kind_recordedTrack');
    await tap(tester, 'expression_destination_track:0');
  }

  testWidgets('the tab switches between actions and controls', (tester) async {
    await pump(tester);
    expect(find.byKey(const Key('external_press')), findsOneWidget);
    await tap(tester, 'external_panel_controls');
    expect(find.byKey(const Key('external_press')), findsNothing);
    expect(
      find.byKey(const Key('external_controls_empty')),
      findsOneWidget,
      reason: 'a button that drives nothing says so',
    );
    await tap(tester, 'external_panel_actions');
    expect(find.byKey(const Key('external_press')), findsOneWidget);
  });

  testWidgets('an effect is added through its destination, On', (
    tester,
  ) async {
    await pump(tester);
    await openPicker(tester);
    await tap(tester, 'external_pick_${externalControlKey(drive)}');
    await tap(tester, 'external_save');
    expect(
      saved().activations.single,
      const ExternalActivation(target: drive),
    );
  });

  testWidgets('a removed effect cannot be added from an open picker', (
    tester,
  ) async {
    await pump(tester);
    await openPicker(tester);
    when(() => looper.trackEffects(0)).thenReturn(const []);
    await tap(tester, 'external_pick_${externalControlKey(drive)}');
    expect(find.byKey(const Key('external_condition_on')), findsNothing);
    expect(saved().activations, isEmpty);
  });

  testWidgets('keyboard opens destination, picks control, and selects row', (
    tester,
  ) async {
    await pump(tester);
    await tap(tester, 'external_panel_controls');
    await tap(tester, 'external_add_control');
    await tap(tester, 'expression_kind_recordedTrack');
    await activate(tester, 'expression_destination_track:0');
    await activate(tester, 'external_pick_${externalControlKey(drive)}');
    expect(find.byKey(const Key('external_condition_on')), findsOneWidget);
    final row = 'external_control_value_${externalControlKey(drive)}';
    final rowTile = find.ancestor(
      of: find.byKey(Key(row)),
      matching: find.byType(ControlRowTile),
    );
    Focus.of(
      tester.element(
        find.descendant(
          of: rowTile,
          matching: find.byType(GestureDetector),
        ),
      ),
    ).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('external_condition_on')), findsOneWidget);
  });

  testWidgets('its condition changes', (tester) async {
    await pump(
      tester,
      jack: ExternalJackSetup(
        single: ExternalSwitchSetup(
          controls: ExternalControls(
            activations: const [ExternalActivation(target: drive)],
          ),
        ),
      ),
    );
    await tap(tester, 'external_panel_controls');
    await tap(tester, 'external_condition_released');
    await tap(tester, 'external_save');
    expect(saved().activations.single.condition, ExternalCondition.released);
  });

  testWidgets('a latching switch refuses Held and Released', (tester) async {
    await pump(
      tester,
      jack: ExternalJackSetup(
        single: ExternalSwitchSetup(
          hardware: ExternalSwitchHardware.latching,
          controls: ExternalControls(
            activations: const [ExternalActivation(target: drive)],
          ),
        ),
      ),
    );
    await tap(tester, 'external_panel_controls');
    await tap(tester, 'external_condition_held');
    // Refused, so there is no edit to save: Save stays inert and the stored
    // condition is still On.
    await tap(tester, 'external_save');
    expect(saved().activations.single.condition, ExternalCondition.on);
    final note = tester.widget<Text>(
      find.descendant(
        of: find.byKey(const Key('external_condition_note')),
        matching: find.byType(Text),
      ),
    );
    expect(note.data, 'Held and Released need a momentary switch.');
  });

  testWidgets('a parameter starts at the value it has now, on both sides', (
    tester,
  ) async {
    await pump(tester);
    await openPicker(tester);
    // Track 1's fader, which the rig reports at 40%.
    await tap(
      tester,
      'external_pick_${externalControlKey(const TrackVolumeTarget(0))}',
    );
    await tap(tester, 'external_save');
    final parameter = saved().parameters.single;
    expect(parameter.active, closeTo(mixerTravelFor(0.4), 1e-9));
    expect(parameter.inactive, closeTo(mixerTravelFor(0.4), 1e-9));
    verifyNever(
      () => looper.setVolume(any(), channel: any(named: 'channel')),
    );
  });

  for (final (gain, endpoint) in <(double, double)>[(1, 0.5), (0, 0)]) {
    testWidgets('Click button starts at accepted gain $gain on both sides', (
      tester,
    ) async {
      await pump(tester, clickVolume: gain);
      await tap(tester, 'external_panel_controls');
      await tap(tester, 'external_add_control');
      await tap(tester, 'expression_kind_output');
      await tap(tester, 'expression_destination_click');
      await tap(
        tester,
        'external_pick_${externalControlKey(const ClickVolumeTarget())}',
      );
      await tap(tester, 'external_save');
      final parameter = saved().parameters.single;
      expect(parameter.target, const ClickVolumeTarget());
      expect(parameter.active, endpoint);
      expect(parameter.inactive, endpoint);
      verifyNever(() => looper.setClickVolume(any()));
    });
  }

  testWidgets('Decay button starts at accepted default with no audio preview', (
    tester,
  ) async {
    await pump(
      tester,
      decaySnapshot: DecaySnapshot(
        defaultPercent: 40,
        trackOverrides: const {0: 0},
      ),
    );
    await tap(tester, 'external_panel_controls');
    await tap(tester, 'external_add_control');
    await tap(tester, 'expression_kind_loopControls');
    await tap(tester, 'expression_destination_loop:defaults');
    await tap(
      tester,
      'external_pick_${externalControlKey(const DefaultDecayTarget())}',
    );
    await tap(tester, 'external_save');
    final parameter = saved().parameters.single;
    expect(parameter.target, const DefaultDecayTarget());
    expect((parameter.active, parameter.inactive), (0.4, 0.4));
    verifyNever(() => looper.setOverdubDecay(any()));
  });

  testWidgets('Hear click button starts at accepted choice on both sides', (
    tester,
  ) async {
    await pump(
      tester,
      clickModeSnapshot: const ClickModeSnapshot(
        mode: ClickMode.recFirst,
        captureLocked: false,
      ),
    );
    await tap(tester, 'external_panel_controls');
    await tap(tester, 'external_add_control');
    await tap(tester, 'expression_kind_loopControls');
    await tap(tester, 'expression_destination_loop:defaults');
    await tap(
      tester,
      'external_pick_${externalControlKey(const ClickModeValueTarget())}',
    );
    expect(
      find.byKey(const Key('external_value_active_recFirst')),
      findsOneWidget,
    );
    await tap(tester, 'external_value_active_playRec');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await tap(tester, 'external_save');
    var parameter = saved().parameters.single;
    expect(parameter.target, const ClickModeValueTarget());
    expect((parameter.active, parameter.inactive), (1 / 3, 1 / 3));
    await tap(tester, 'external_value_active_playRec');
    await tap(tester, 'external_save');
    parameter = saved().parameters.single;
    expect((parameter.active, parameter.inactive), (1.0, 1 / 3));
    verifyNever(() => tempo.setClickMode(any()));
    verifyNever(() => looper.setClickMode(any()));
  });

  testWidgets(
    'Count-in button starts at accepted 2 bars and edits draft only',
    (
      tester,
    ) async {
      await pump(
        tester,
        recordStartSnapshot: RecordStartSnapshot(
          settings: RecordStartSettings(countInBars: 2, soundStart: false),
          captureLocked: false,
        ),
      );
      await tap(tester, 'external_panel_controls');
      await tap(tester, 'external_add_control');
      await tap(tester, 'expression_kind_loopControls');
      await tap(tester, 'expression_destination_loop:defaults');
      await tap(
        tester,
        'external_pick_${externalControlKey(const CountInValueTarget())}',
      );
      await tap(tester, 'external_value_active_4');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await tap(tester, 'external_save');
      var parameter = saved().parameters.single;
      expect(parameter.target, const CountInValueTarget());
      expect((parameter.active, parameter.inactive), (2 / 3, 2 / 3));
      await tap(tester, 'external_value_active_4');
      await tap(tester, 'external_save');
      parameter = saved().parameters.single;
      expect((parameter.active, parameter.inactive), (1.0, 2 / 3));
      verifyNever(
        () => looper.setRecordStartSettings(
          countInBars: any(named: 'countInBars'),
          soundStart: any(named: 'soundStart'),
          editKind: any(named: 'editKind'),
        ),
      );
    },
  );

  testWidgets('capture keeps Count-in row but disables its endpoints', (
    tester,
  ) async {
    await pump(
      tester,
      recordStartSnapshot: RecordStartSnapshot(
        settings: RecordStartSettings(countInBars: 0, soundStart: true),
        captureLocked: true,
      ),
      jack: ExternalJackSetup(
        single: ExternalSwitchSetup(
          controls: ExternalControls(
            parameters: [
              ExternalParameter(
                target: const CountInValueTarget(),
                active: 0.8,
                inactive: 0.2,
              ),
            ],
          ),
        ),
      ),
    );
    await tap(tester, 'external_panel_controls');
    expect(saved().parameters.single.target, const CountInValueTarget());
    expect(
      find.text('Recording start cannot change during capture.'),
      findsWidgets,
    );
    expect(
      tester
          .widget<LoopChoiceButton>(
            find.byKey(const Key('external_value_active_4')),
          )
          .enabled,
      isFalse,
    );
  });

  testWidgets('capture retains Hear click row but disables both endpoints', (
    tester,
  ) async {
    await pump(
      tester,
      clickModeSnapshot: const ClickModeSnapshot(
        mode: ClickMode.off,
        captureLocked: true,
      ),
      jack: ExternalJackSetup(
        single: ExternalSwitchSetup(
          controls: ExternalControls(
            parameters: [
              ExternalParameter(
                target: const ClickModeValueTarget(),
                active: 0.8,
                inactive: 0.2,
              ),
            ],
          ),
        ),
      ),
    );
    await tap(tester, 'external_panel_controls');
    expect(saved().parameters.single.target, const ClickModeValueTarget());
    expect(find.text('Finish recording to change Hear click.'), findsWidgets);
    expect(
      tester
          .widget<LoopChoiceButton>(
            find.byKey(const Key('external_value_active_playRec')),
          )
          .enabled,
      isFalse,
    );
    expect(find.byKey(const Key('external_remove_control')), findsOneWidget);
  });

  for (final once in [false, true]) {
    testWidgets('Loop/Once button starts at accepted $once on both sides', (
      tester,
    ) async {
      await pump(
        tester,
        oneShotSnapshot: OneShotSnapshot(
          defaultOneShot: once,
          trackOverrides: const {},
        ),
      );
      await tap(tester, 'external_panel_controls');
      await tap(tester, 'external_add_control');
      await tap(tester, 'expression_kind_loopControls');
      await tap(tester, 'expression_destination_loop:defaults');
      await tap(
        tester,
        'external_pick_${externalControlKey(const DefaultOneShotTarget())}',
      );
      await tap(tester, 'external_save');
      final parameter = saved().parameters.single;
      expect(parameter.target, const DefaultOneShotTarget());
      expect((parameter.active, parameter.inactive), once ? (1, 1) : (0, 0));
      await tap(
        tester,
        once ? 'external_value_active_loop' : 'external_value_active_once',
      );
      expect(saved().parameters.single.active, once ? 1 : 0);
      await tap(tester, 'external_save');
      expect(saved().parameters.single.active, once ? 0 : 1);
      expect(saved().parameters.single.inactive, once ? 1 : 0);
      verifyNever(
        () => looper.setOneShotSnapshot(
          defaultOneShot: any(named: 'defaultOneShot'),
          trackOverrides: any(named: 'trackOverrides'),
          released: any(named: 'released'),
        ),
      );
    });
  }

  testWidgets('Loop/Once endpoint Escape and Cancel preserve saved choice', (
    tester,
  ) async {
    await pump(
      tester,
      oneShotSnapshot: OneShotSnapshot(
        defaultOneShot: false,
        trackOverrides: const {},
      ),
      jack: ExternalJackSetup(
        single: ExternalSwitchSetup(
          controls: ExternalControls(
            parameters: [
              ExternalParameter(
                target: const DefaultOneShotTarget(),
                active: 0,
                inactive: 0,
              ),
            ],
          ),
        ),
      ),
    );
    await tap(tester, 'external_panel_controls');
    await tap(tester, 'external_value_active_once');
    expect(saved().parameters.single.active, 0);
    expect(
      tester
          .widget<LoopChoiceButton>(
            find.byKey(const Key('external_value_active_once')),
          )
          .selected,
      isTrue,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<LoopChoiceButton>(
            find.byKey(const Key('external_value_active_loop')),
          )
          .selected,
      isTrue,
    );
    await tap(tester, 'external_value_active_once');
    await tap(tester, 'external_cancel');
    expect(saved().parameters.single.active, 0);
    verifyNever(
      () => looper.setOneShotSnapshot(
        defaultOneShot: any(named: 'defaultOneShot'),
        trackOverrides: any(named: 'trackOverrides'),
        released: any(named: 'released'),
      ),
    );
  });

  testWidgets('unavailable Loop/Once row repairs without changing endpoints', (
    tester,
  ) async {
    await pump(
      tester,
      jack: ExternalJackSetup(
        single: ExternalSwitchSetup(
          controls: ExternalControls(
            parameters: [
              ExternalParameter(
                target: const DefaultOneShotTarget(),
                active: 1,
                inactive: 0,
              ),
            ],
          ),
        ),
      ),
    );
    await tap(tester, 'external_panel_controls');
    expect(find.text('Unavailable'), findsOneWidget);
    await tap(tester, 'external_change_control');
    await tap(tester, 'expression_kind_recordedTrack');
    await tap(tester, 'expression_destination_track:0');
    await tap(
      tester,
      'external_pick_${externalControlKey(const TrackVolumeTarget(0))}',
    );
    expect(saved().parameters.single.target, const DefaultOneShotTarget());
    await tap(tester, 'external_save');
    final repaired = saved().parameters.single;
    expect(repaired.target, const TrackVolumeTarget(0));
    expect((repaired.active, repaired.inactive), (1, 0));
  });

  testWidgets('Cancel drops the new Click button without writing audio', (
    tester,
  ) async {
    await pump(tester);
    await tap(tester, 'external_panel_controls');
    await tap(tester, 'external_add_control');
    await tap(tester, 'expression_kind_output');
    await tap(tester, 'expression_destination_click');
    await tap(
      tester,
      'external_pick_${externalControlKey(const ClickVolumeTarget())}',
    );
    await tap(tester, 'external_cancel');
    expect(saved().parameters, isEmpty);
    verifyNever(() => looper.setClickVolume(any()));
  });

  testWidgets('Click owner disappearing during a picker adds no guessed zero', (
    tester,
  ) async {
    await pump(tester);
    await tap(tester, 'external_panel_controls');
    await tap(tester, 'external_add_control');
    await tap(tester, 'expression_kind_output');
    await tap(tester, 'expression_destination_click');
    when(() => tempo.clickVolume).thenReturn(null);
    tempo.publish();
    await tap(
      tester,
      'external_pick_${externalControlKey(const ClickVolumeTarget())}',
    );
    await tap(tester, 'external_save');
    expect(saved().parameters, isEmpty);
    verifyNever(() => looper.setClickVolume(any()));
  });

  testWidgets('retained Click button is unavailable without its owner', (
    tester,
  ) async {
    await pump(
      tester,
      clickVolume: null,
      jack: ExternalJackSetup(
        single: ExternalSwitchSetup(
          controls: ExternalControls(
            parameters: [
              ExternalParameter(
                target: const ClickVolumeTarget(),
                active: 0.8,
                inactive: 0.2,
              ),
            ],
          ),
        ),
      ),
    );
    await tap(tester, 'external_panel_controls');
    expect(find.text('Unavailable'), findsOneWidget);
    expect(find.byKey(const Key('external_change_control')), findsOneWidget);
    expect(saved().parameters.single.target, const ClickVolumeTarget());
    await tap(tester, 'external_change_control');
    await tap(tester, 'expression_kind_recordedTrack');
    await tap(tester, 'expression_destination_track:0');
    await tap(
      tester,
      'external_pick_${externalControlKey(const TrackVolumeTarget(0))}',
    );
    expect(saved().parameters.single.target, const ClickVolumeTarget());
    await tap(tester, 'external_save');
    final repaired = saved().parameters.single;
    expect(repaired.target, const TrackVolumeTarget(0));
    expect((repaired.active, repaired.inactive), (0.8, 0.2));
  });

  testWidgets('a control added past the bottom of the list is in view', (
    tester,
  ) async {
    await pump(
      tester,
      jack: ExternalJackSetup(
        single: ExternalSwitchSetup(
          controls: ExternalControls(
            activations: const [
              ExternalActivation(target: drive),
              ExternalActivation(
                target: FxChainTarget(FxAddress(stage: FxStage.track)),
              ),
              ExternalActivation(
                target: FxSlotTarget(
                  address: FxAddress(stage: FxStage.track),
                  slotId: 'gone-1',
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await openPicker(tester);
    await tap(
      tester,
      'external_pick_${externalControlKey(const TrackVolumeTarget(0))}',
    );
    // Its two values opened below a list that shrank to make room; the row
    // they belong to must not be left scrolled out of sight.
    expect(find.byKey(const Key('external_value_active')), findsOne);
    expect(find.text('Volume').hitTestable(), findsOne);
  });

  testWidgets('moving a value edits the mapping and writes nothing', (
    tester,
  ) async {
    await pump(
      tester,
      jack: ExternalJackSetup(
        single: ExternalSwitchSetup(
          controls: ExternalControls(
            parameters: [
              ExternalParameter(
                target: const TrackVolumeTarget(0),
                active: 0.4,
                inactive: 0.4,
              ),
            ],
          ),
        ),
      ),
    );
    await tap(tester, 'external_panel_controls');
    final slider = find.byKey(const Key('external_value_active'));
    await tester.tapAt(tester.getCenter(slider));
    await tester.pumpAndSettle();
    await tap(tester, 'external_save');
    expect(saved().parameters.single.active, closeTo(0.5, 0.02));
    verifyNever(
      () => looper.setVolume(any(), channel: any(named: 'channel')),
    );
  });

  testWidgets('Escape restores an unfinished button endpoint draft', (
    tester,
  ) async {
    await pump(
      tester,
      jack: ExternalJackSetup(
        single: ExternalSwitchSetup(
          controls: ExternalControls(
            parameters: [
              ExternalParameter(
                target: const TrackVolumeTarget(0),
                active: 0.4,
                inactive: 0.4,
              ),
            ],
          ),
        ),
      ),
    );
    await tap(tester, 'external_panel_controls');
    final slider = find.byKey(const Key('external_value_active'));
    Focus.of(
      tester.element(
        find
            .descendant(of: slider, matching: find.byType(GestureDetector))
            .first,
      ),
    ).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(tester.widget<LoopSlider>(slider).value, closeTo(0.41, 1e-9));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(tester.widget<LoopSlider>(slider).value, closeTo(0.4, 1e-9));
    await tap(tester, 'external_save');
    expect(saved().parameters.single.active, closeTo(0.4, 1e-9));
  });

  testWidgets('removing a control drops it', (tester) async {
    await pump(
      tester,
      jack: ExternalJackSetup(
        single: ExternalSwitchSetup(
          controls: ExternalControls(
            activations: const [ExternalActivation(target: drive)],
          ),
        ),
      ),
    );
    await tap(tester, 'external_panel_controls');
    await tap(tester, 'external_remove_control');
    await tap(tester, 'external_save');
    expect(saved().isEmpty, isTrue);
  });

  testWidgets('a row draws its pedal, and a fader row draws none', (
    tester,
  ) async {
    await pump(
      tester,
      jack: ExternalJackSetup(
        single: ExternalSwitchSetup(
          controls: ExternalControls(
            activations: const [ExternalActivation(target: drive)],
            parameters: [
              ExternalParameter(
                target: const TrackVolumeTarget(0),
                active: 1,
                inactive: 0,
              ),
            ],
          ),
        ),
      ),
    );
    await tap(tester, 'external_panel_controls');
    final art = find.byKey(const Key('control_row_art'));
    expect(art, findsOne, reason: 'the effect has a picture; the fader not');
    expect(
      (tester.widget<Image>(art).image as AssetImage).assetName,
      fxModuleArt('Overdrive'),
    );
  });

  testWidgets('an effect the rig has lost keeps its row and says so', (
    tester,
  ) async {
    await pump(
      tester,
      jack: ExternalJackSetup(
        single: ExternalSwitchSetup(
          controls: ExternalControls(
            activations: const [
              ExternalActivation(
                target: FxSlotTarget(
                  address: FxAddress(stage: FxStage.track),
                  slotId: 'vanished',
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tap(tester, 'external_panel_controls');
    expect(find.text('Unavailable'), findsOneWidget);
  });

  testWidgets('a missing effect can be repointed with its rule intact', (
    tester,
  ) async {
    await pump(
      tester,
      jack: ExternalJackSetup(
        single: ExternalSwitchSetup(
          controls: ExternalControls(
            activations: const [
              ExternalActivation(
                target: FxSlotTarget(
                  address: FxAddress(stage: FxStage.track),
                  slotId: 'vanished',
                ),
                condition: ExternalCondition.off,
              ),
            ],
          ),
        ),
      ),
    );
    await tap(tester, 'external_panel_controls');
    expect(find.byKey(const Key('external_change_control')), findsOneWidget);
    await tap(tester, 'external_change_control');
    await tap(tester, 'expression_kind_recordedTrack');
    await tap(tester, 'expression_destination_track:0');
    await tap(tester, 'external_pick_${externalControlKey(drive)}');
    await tap(tester, 'external_save');
    expect(saved().activations.single.target, drive);
    expect(saved().activations.single.condition, ExternalCondition.off);
  });

  testWidgets('a missing parameter can be repointed without resetting values', (
    tester,
  ) async {
    await pump(
      tester,
      jack: ExternalJackSetup(
        single: ExternalSwitchSetup(
          controls: ExternalControls(
            parameters: [
              ExternalParameter(
                target: const TrackVolumeTarget(9),
                active: 0.8,
                inactive: 0.2,
                condition: ExternalValueCondition.heldReleased,
              ),
            ],
          ),
        ),
      ),
    );
    await tap(tester, 'external_panel_controls');
    await tap(tester, 'external_change_control');
    await tap(tester, 'expression_kind_recordedTrack');
    await tap(tester, 'expression_destination_track:0');
    await tap(
      tester,
      'external_pick_${externalControlKey(const TrackVolumeTarget(0))}',
    );
    await tap(tester, 'external_save');
    final repaired = saved().parameters.single;
    expect(repaired.target, const TrackVolumeTarget(0));
    expect(repaired.active, 0.8);
    expect(repaired.inactive, 0.2);
    expect(repaired.condition, ExternalValueCondition.heldReleased);
  });

  testWidgets('opening the other jack closes the picker', (tester) async {
    await pump(tester);
    await openPicker(tester);
    expect(find.byKey(const Key('external_pick_title')), findsOne);
    await tap(tester, 'external_jack_ctrl2');
    expect(
      find.byKey(const Key('external_pick_title')),
      findsNothing,
      reason: 'a control chosen for a button on CTRL 1 is not for CTRL 2',
    );
  });

  testWidgets('Cancel in the picker adds nothing', (tester) async {
    await pump(tester);
    await openPicker(tester);
    await tap(tester, 'external_pick_cancel');
    expect(find.byKey(const Key('external_controls_empty')), findsOneWidget);
    expect(
      find.byKey(const Key('external_cancel')),
      findsOneWidget,
    );
  });

  testWidgets('Back steps out of the picker before leaving', (tester) async {
    await pump(tester);
    await openPicker(tester);
    // From one destination's controls, Back returns to the destinations...
    await tap(tester, 'loop_settings_back');
    expect(find.byKey(const Key('expression_kind_recordedTrack')), findsOne);
    // ...then out of the picker, still on the page and its draft.
    await tap(tester, 'loop_settings_back');
    expect(find.byKey(const Key('external_add_control')), findsOne);
    expect(find.byKey(const Key('external_pedal_page')), findsOne);
  });
}
