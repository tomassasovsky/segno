import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:performance_repository/performance_repository.dart';
import 'package:routing_graph/routing_graph.dart';
import 'package:segno/app/fx_chain_persistence.dart';
import 'package:segno/control/binding/external_pedal.dart';
import 'package:segno/control/control.dart';
import 'package:segno/control/view/pedal_setup/external_controls_editor.dart';
import 'package:segno/control/view/pedal_setup/external_pedal_page.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/application/record_settings.dart';
import 'package:segno/looper/application/record_timing_settings.dart';
import 'package:segno/looper/cubit/playback_options_cubit.dart';
import 'package:segno/looper/cubit/record_options_cubit.dart';
import 'package:segno/looper/cubit/record_timing_cubit.dart';
import 'package:segno/looper/cubit/tempo_cubit.dart';
import 'package:segno/looper/cubit/tracks_cubit.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/pedal/cubit/pedal_cubit.dart';
import 'package:segno/theme/theme.dart';
import 'package:settings_repository/settings_repository.dart';

import '../helpers/fake_audio_engine.dart';
import '../helpers/fake_click_mode_control.dart';
import '../helpers/fake_click_volume_control.dart';
import '../helpers/fake_key_value_store.dart';
import '../helpers/fake_record_start_control.dart';
import '../helpers/mock_click_tempo_settings.dart';
import '../helpers/mock_decay_playback_settings.dart';
import '../helpers/test_fade_settings.dart';
import '../helpers/test_mix_settings.dart';

class _MockLooperRepository extends Mock implements LooperRepository {}

class _ControlledStore extends FakeKeyValueStore {
  Completer<void>? pending;

  @override
  Future<void> setString(String key, String value) async {
    if (key == 'pedal.setup') await pending?.future;
    await super.setString(key, value);
  }
}

/// The accepted External pedals screen: two jacks, one draft, one Save.
void main() {
  late _MockLooperRepository looper;
  late StreamController<LooperState> looperStates;
  late SettingsRepository settings;
  late _ControlledStore store;
  late ControlCubit control;
  late RecordSettings record;
  late RecordTimingCubit timing;
  late int confirmedLength;
  late RecordTiming confirmedTiming;
  late GridDivision rememberedDivision;
  late TracksCubit tracks;

  setUp(() {
    looper = _MockLooperRepository();
    confirmedLength = 0;
    confirmedTiming = RecordTiming.immediately;
    rememberedDivision = GridDivision.off;
    when(() => looper.sessionRevision).thenReturn(0);
    when(() => looper.mixGeneration).thenReturn(0);
    when(() => looper.inputSetup).thenReturn(const InputSetup.empty());
    when(() => looper.laneCount(any())).thenReturn(1);
    looperStates = StreamController<LooperState>.broadcast();
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
    when(() => looper.allMonitors()).thenReturn(const {});
    when(() => looper.allLaneChains()).thenReturn(const {});
    when(() => looper.allTrackChains()).thenReturn(const {});
    when(() => looper.allTracksEffects).thenReturn(const []);
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
        defaultLengthPresetBars: confirmedLength,
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
    ).thenAnswer((call) {
      confirmedLength = call.namedArguments[#defaultBars] as int;
      return EngineResult.ok;
    });
    when(
      () => looper.setDefaultLengthPreset(
        any(),
        releasedBars: any(named: 'releasedBars'),
      ),
    ).thenAnswer((call) {
      confirmedLength = call.positionalArguments.single as int;
      return EngineResult.ok;
    });
    when(
      () => looper.setRecDub(enabled: any(named: 'enabled')),
    ).thenReturn(EngineResult.ok);
    when(
      () => looper.setDefaultMultiple(multiple: any(named: 'multiple')),
    ).thenReturn(EngineResult.ok);
  });

  setUpAll(() {
    registerFallbackValue(LooperMode.multi);
    registerFallbackValue(RecordTiming.immediately);
    registerFallbackValue(GridDivision.off);
    registerFallbackValue(<int, RecordTiming>{});
  });

  tearDown(() async {
    await looperStates.close();
  });

  Future<void> pump(
    WidgetTester tester, {
    int currentBars = 0,
    RecordTiming currentTiming = RecordTiming.immediately,
  }) async {
    store = _ControlledStore();
    settings = SettingsRepository(store: store);
    confirmedTiming = currentTiming;
    rememberedDivision = currentTiming.division;
    await settings.restoreRecordTimingCheckpoint((
      quantize: currentTiming.quantize,
      division: rememberedDivision.code,
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
    final playback = MockDecayPlaybackSettings();
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
    if (currentBars != 0) {
      expect((await record.setDefaultLengthBars(currentBars)).isOk, isTrue);
    }
    control = ControlCubit(
      fadeSettings: testFadeSettings(),
      clickVolumeControl: FakeClickVolumeControl(),
      clickModeControl: FakeClickModeControl(),
      recordStartControl: FakeRecordStartControl(),
      decayControl: playback,
      oneShotControl: playback,
      recordLengthControl: record,
      recordTimingControl: timingOwner,
      fxPersistence: FxChainPersistence(looper: looper),
      looper: looper,
      mixSettings: mixSettings,
      pedal: pedal,
      settings: settings,
      performance: performance,
    );
    tracks = TracksCubit(settings: settings);
    // unawaited: awaiting a cubit close inside a testWidgets body deadlocks
    // on the binding's stream cancellation (flutter/flutter#139870).
    addTearDown(() => unawaited(control.close()));
    addTearDown(() => unawaited(tracks.close()));
    await control.load();

    final tempoOwner = MockClickTempoSettings();
    addTearDown(() => unawaited(tempoOwner.close()));
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
            // The map's indicators read the frame the app last handed the
            // pedal.
            RepositoryProvider<PedalRepository>.value(value: pedal),
          ],
          child: MultiBlocProvider(
            providers: [
              BlocProvider.value(value: control),
              BlocProvider.value(value: tracks),
              BlocProvider.value(value: pedalCubit),
              BlocProvider<TempoCubit>(
                create: (_) => TempoCubit(settings: tempoOwner),
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
    await tester.tap(find.byKey(Key(key)));
    await tester.pumpAndSettle();
  }

  Future<void> choose(
    WidgetTester tester, {
    required String field,
    required String group,
    required String choice,
  }) async {
    await tap(tester, field);
    final tab = find.byKey(Key('pedal_choice_group_$group'));
    if (tab.evaluate().isNotEmpty) {
      await tester.tap(tab);
      await tester.pumpAndSettle();
    }
    await tester.tap(find.byKey(Key('pedal_choice_$choice')));
    await tester.pumpAndSettle();
  }

  String? selectedButton(WidgetTester tester) =>
      tester.widget<AppText>(find.byKey(const Key('external_selected'))).data;

  ExternalJackSetup saved(PedalCtrlJack jack) =>
      control.state.pedalSetup.external.forJack(jack);

  group('External pedals', () {
    testWidgets('new timing button keeps the accepted choice on both ends', (
      tester,
    ) async {
      await pump(tester, currentTiming: RecordTiming.bar);
      expect(timing.state.recordTimingReady, isTrue);
      clearInteractions(looper);
      await tap(tester, 'external_panel_controls');
      await tap(tester, 'external_add_control');
      await tap(tester, 'expression_kind_loopControls');
      await tap(tester, 'expression_destination_loop:defaults');
      final key = externalControlKey(const DefaultRecordTimingTarget());
      await tap(tester, 'external_pick_$key');
      expect(saved(PedalCtrlJack.ctrl1).single.controls.parameters, isEmpty);
      await tap(tester, 'external_save');
      final parameter = saved(
        PedalCtrlJack.ctrl1,
      ).single.controls.parameters.single;
      expect(parameter.target, const DefaultRecordTimingTarget());
      expect((parameter.active, parameter.inactive), (2 / 6, 2 / 6));
      expect(timing.state.defaultTiming, RecordTiming.bar);
      verifyNever(
        () => looper.setRecordTimingSettings(
          defaultTiming: any(named: 'defaultTiming'),
          rememberedDivision: any(named: 'rememberedDivision'),
          trackOverrides: any(named: 'trackOverrides'),
        ),
      );
    });

    testWidgets('new button length holds accepted bars on both ends', (
      tester,
    ) async {
      await pump(tester, currentBars: 4);
      clearInteractions(looper);
      await tap(tester, 'external_panel_controls');
      await tap(tester, 'external_add_control');
      await tap(tester, 'expression_kind_loopControls');
      await tap(tester, 'expression_destination_loop:defaults');
      final key = externalControlKey(const DefaultRecordLengthTarget());
      await tap(
        tester,
        'external_pick_$key',
      );
      expect(saved(PedalCtrlJack.ctrl1).single.controls.parameters, isEmpty);
      await tap(tester, 'external_save');
      final parameter = saved(
        PedalCtrlJack.ctrl1,
      ).single.controls.parameters.single;
      expect(parameter.target, const DefaultRecordLengthTarget());
      expect((parameter.active, parameter.inactive), (4 / 64, 4 / 64));
      verifyNever(
        () => looper.setLengthSettings(
          defaultBars: any(named: 'defaultBars'),
          overrides: any(named: 'overrides'),
          mode: any(named: 'mode'),
        ),
      );
    });
    testWidgets('opens on CTRL 1 as a single switch, editing Button 1', (
      tester,
    ) async {
      await pump(tester);
      final l10n = AppLocalizations.of(
        tester.element(find.byType(ExternalPedalPage)),
      );
      expect(selectedButton(tester), l10n.externalButton(1));
      expect(find.byKey(const Key('external_switch_0')), findsOneWidget);
      // A single switch has exactly one.
      expect(find.byKey(const Key('external_switch_1')), findsNothing);
      expect(find.byKey(const Key('external_press')), findsOneWidget);
      expect(find.byKey(const Key('external_hold')), findsOneWidget);
    });

    testWidgets('a dual switch puts a second button under the foot', (
      tester,
    ) async {
      await pump(tester);
      final l10n = AppLocalizations.of(
        tester.element(find.byType(ExternalPedalPage)),
      );
      await tap(tester, 'external_type_dualSwitch');
      expect(find.byKey(const Key('external_switch_1')), findsOneWidget);

      await tap(tester, 'external_switch_1');
      expect(selectedButton(tester), l10n.externalButton(2));
    });

    testWidgets('keyboard activation selects Dual Button 2', (tester) async {
      await pump(tester);
      await tap(tester, 'external_type_dualSwitch');
      final target = find.descendant(
        of: find.byKey(const Key('external_switch_1')),
        matching: find.byType(GestureDetector),
      );
      Focus.of(tester.element(target)).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      final l10n = AppLocalizations.of(
        tester.element(find.byType(ExternalPedalPage)),
      );
      expect(selectedButton(tester), l10n.externalButton(2));
    });

    testWidgets('going back to a single switch cannot leave the second '
        'button selected', (tester) async {
      await pump(tester);
      final l10n = AppLocalizations.of(
        tester.element(find.byType(ExternalPedalPage)),
      );
      await tap(tester, 'external_type_dualSwitch');
      await tap(tester, 'external_switch_1');
      await tap(tester, 'external_type_singleSwitch');
      expect(selectedButton(tester), l10n.externalButton(1));
      expect(find.byKey(const Key('external_press')), findsOneWidget);
    });

    testWidgets('a latching switch has one gesture, and says why', (
      tester,
    ) async {
      await pump(tester);
      final l10n = AppLocalizations.of(
        tester.element(find.byType(ExternalPedalPage)),
      );
      expect(
        tester.widget<AppText>(find.byKey(const Key('external_note'))).data,
        l10n.externalPressNote,
      );

      await tap(tester, 'external_hardware_latching');
      expect(find.byKey(const Key('external_change')), findsOneWidget);
      expect(find.byKey(const Key('external_press')), findsNothing);
      expect(find.byKey(const Key('external_hold')), findsNothing);
      expect(
        tester.widget<AppText>(find.byKey(const Key('external_note'))).data,
        l10n.externalChangeNote,
      );
    });

    testWidgets('the note changes once a hold is assigned', (tester) async {
      await pump(tester);
      final l10n = AppLocalizations.of(
        tester.element(find.byType(ExternalPedalPage)),
      );
      await choose(
        tester,
        field: 'external_hold',
        group: 'transport',
        choice: 'command:stop',
      );
      expect(
        tester.widget<AppText>(find.byKey(const Key('external_note'))).data,
        l10n.externalHoldNote,
      );
    });

    testWidgets('an assignment is a draft until Save, and persists with it', (
      tester,
    ) async {
      await pump(tester);
      expect(
        tester
            .widget<LoopOutlinedButton>(
              find.byKey(const Key('external_save')),
            )
            .onTap,
        isNull,
        reason: 'nothing to save yet',
      );

      await choose(
        tester,
        field: 'external_press',
        group: 'transport',
        choice: 'command:stop',
      );
      expect(saved(PedalCtrlJack.ctrl1).single.gestures.press, isNull);

      await tap(tester, 'external_save');
      expect(
        saved(PedalCtrlJack.ctrl1).single.gestures.press,
        const CommandAction(ControlCommand.stop),
      );
      expect(
        await settings.loadPedalSetup(),
        control.state.pedalSetup.encode(),
      );
    });

    testWidgets('Cancel drops the draft', (tester) async {
      await pump(tester);
      await choose(
        tester,
        field: 'external_press',
        group: 'transport',
        choice: 'command:stop',
      );
      await tap(tester, 'external_cancel');
      expect(saved(PedalCtrlJack.ctrl1).single.isEmpty, isTrue);
      expect(find.text('Stop'), findsNothing);
    });

    testWidgets('each jack keeps its own type and its own assignments', (
      tester,
    ) async {
      await pump(tester);
      await tap(tester, 'external_type_dualSwitch');
      await choose(
        tester,
        field: 'external_press',
        group: 'transport',
        choice: 'command:stop',
      );

      await tap(tester, 'external_jack_ctrl2');
      // CTRL 2 is untouched: its own type, its own switch.
      expect(find.byKey(const Key('external_switch_1')), findsNothing);
      expect(find.text('Stop'), findsNothing);

      await tap(tester, 'external_jack_ctrl1');
      expect(find.byKey(const Key('external_switch_1')), findsOneWidget);
      expect(find.text('Stop'), findsOneWidget);
    });

    testWidgets('changing the type keeps what the other type carried', (
      tester,
    ) async {
      await pump(tester);
      await choose(
        tester,
        field: 'external_press',
        group: 'transport',
        choice: 'command:stop',
      );
      await tap(tester, 'external_type_dualSwitch');
      // The dual pedal's first button is its own switch, not the single one.
      expect(find.text('Stop'), findsNothing);

      await tap(tester, 'external_type_singleSwitch');
      expect(find.text('Stop'), findsOneWidget);
    });

    testWidgets('a latching action is kept when the switch is retyped', (
      tester,
    ) async {
      await pump(tester);
      await tap(tester, 'external_hardware_latching');
      await choose(
        tester,
        field: 'external_change',
        group: 'transport',
        choice: 'command:stop',
      );
      await tap(tester, 'external_hardware_momentary');
      expect(find.byKey(const Key('external_press')), findsOneWidget);

      await tap(tester, 'external_hardware_latching');
      expect(find.text('Stop'), findsOneWidget);
    });

    testWidgets('pending Save holds the page and commits once', (tester) async {
      await pump(tester);
      await choose(
        tester,
        field: 'external_press',
        group: 'transport',
        choice: 'command:stop',
      );
      store.pending = Completer<void>();
      await tester.tap(find.byKey(const Key('external_save')));
      await tester.pump();
      expect(tester.widget<PopScope>(find.byType(PopScope)).canPop, isFalse);
      expect(
        tester
            .widget<LoopOutlinedButton>(
              find.byKey(const Key('external_save')),
            )
            .onTap,
        isNull,
      );
      await tester.tap(
        find.byKey(const Key('loop_settings_back')),
        warnIfMissed: false,
      );
      await tester.pump();
      expect(find.byType(ExternalPedalPage), findsOneWidget);
      expect(saved(PedalCtrlJack.ctrl1).single.gestures.press, isNull);
      store.pending!.complete();
      await tester.pumpAndSettle();
      expect(
        saved(PedalCtrlJack.ctrl1).single.gestures.press,
        const CommandAction(ControlCommand.stop),
      );
      expect(tester.widget<PopScope>(find.byType(PopScope)).canPop, isTrue);
    });

    testWidgets('runtime-unsaved intent offers a no-draft retry', (
      tester,
    ) async {
      await pump(tester);
      control.emit(control.state.copyWith(pedalSetupRuntimeUnsaved: true));
      expect(control.state.pedalSetupRuntimeUnsaved, isTrue);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('external_save_failed')), findsOneWidget);
      expect(
        tester
            .widget<LoopOutlinedButton>(
              find.byKey(const Key('external_save')),
            )
            .onTap,
        isNotNull,
      );
      await tap(tester, 'external_save');
      expect(control.state.pedalSetupRuntimeUnsaved, isFalse);
      expect(find.byKey(const Key('external_saved')), findsOneWidget);
    });

    testWidgets('picker return rebases on latest sibling setup', (
      tester,
    ) async {
      await pump(tester);
      await tap(tester, 'external_press');
      final sibling = control.state.pedalSetup.external.withJack(
        PedalCtrlJack.ctrl2,
        const ExternalJackSetup(type: ExternalJackType.dualSwitch),
      );
      await control.setPedalSetup(
        control.state.pedalSetup.copyWith(external: sibling),
      );
      await tester.pumpAndSettle();
      await tap(tester, 'pedal_choice_group_transport');
      await tap(tester, 'pedal_choice_command:stop');
      await tap(tester, 'external_save');
      expect(saved(PedalCtrlJack.ctrl2).type, ExternalJackType.dualSwitch);
      expect(
        saved(PedalCtrlJack.ctrl1).single.gestures.press,
        const CommandAction(ControlCommand.stop),
      );
    });

    testWidgets('picker return rejects changed button configuration', (
      tester,
    ) async {
      await pump(tester);
      await tap(tester, 'external_press');
      final changed = control.state.pedalSetup.external.withJack(
        PedalCtrlJack.ctrl1,
        const ExternalJackSetup(
          single: ExternalSwitchSetup(
            hardware: ExternalSwitchHardware.latching,
          ),
        ),
      );
      await control.setPedalSetup(
        control.state.pedalSetup.copyWith(external: changed),
      );
      await tester.pumpAndSettle();
      await tap(tester, 'pedal_choice_group_transport');
      await tap(tester, 'pedal_choice_command:stop');
      expect(saved(PedalCtrlJack.ctrl1).single.gestures.press, isNull);
      expect(
        saved(PedalCtrlJack.ctrl1).single.hardware,
        ExternalSwitchHardware.latching,
      );
      expect(
        tester
            .widget<LoopOutlinedButton>(
              find.byKey(const Key('external_save')),
            )
            .onTap,
        isNull,
      );
    });
  });
}
