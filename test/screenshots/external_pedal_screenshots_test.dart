@Tags(['screenshots'])
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fx_catalogue/fx_catalogue.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:pedal_repository/testing.dart';
import 'package:performance_repository/performance_repository.dart';
import 'package:routing_graph/routing_graph.dart';
import 'package:segno/app/fx_chain_persistence.dart';
import 'package:segno/control/binding/external_controls.dart';
import 'package:segno/control/binding/external_expression.dart';
import 'package:segno/control/binding/external_pedal.dart';
import 'package:segno/control/control.dart';
import 'package:segno/control/view/pedal_setup/expression_position_panel.dart';
import 'package:segno/control/view/pedal_setup/external_controls_editor.dart';
import 'package:segno/control/view/pedal_setup/external_pedal_art.dart';
import 'package:segno/control/view/pedal_setup/external_pedal_page.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/cubit/playback_options_cubit.dart';
import 'package:segno/looper/cubit/record_options_cubit.dart';
import 'package:segno/looper/cubit/record_timing_cubit.dart';
import 'package:segno/looper/cubit/tempo_cubit.dart';
import 'package:segno/looper/cubit/tracks_cubit.dart';
import 'package:segno/looper/model/interaction_mode.dart';
import 'package:segno/looper/model/one_shot.dart';
import 'package:segno/looper/model/overdub_decay.dart';
import 'package:segno/pedal/cubit/pedal_cubit.dart';
import 'package:segno/theme/theme.dart';
import 'package:settings_repository/settings_repository.dart';

import '../helpers/helpers.dart';
import '../helpers/mock_click_tempo_cubit.dart';
import '../helpers/mock_decay_playback_cubit.dart';

class _MockLooperRepository extends Mock implements LooperRepository {}

/// The accepted External pedals screen, drawn at the console's own size.
void main() {
  final fontDir = Platform.environment['SEGNO_SCREENSHOT_FONT_DIR'];
  // Explicit author-side visual checks use the SDK's Material fonts.
  // Ordinary CI does not claim to have compared these machine-rendered images.
  final hasScreenshotFonts =
      fontDir != null && File('$fontDir/Roboto-Regular.ttf').existsSync();

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
  late SettingsRepository settings;
  late RecordOptionsCubit record;
  late RecordTimingCubit timing;
  late RecordTiming confirmedTiming;
  late GridDivision rememberedDivision;

  setUp(() {
    looper = _MockLooperRepository();
    confirmedTiming = RecordTiming.immediately;
    rememberedDivision = GridDivision.off;
    when(() => looper.sessionRevision).thenReturn(0);
    when(() => looper.mixGeneration).thenReturn(0);
    when(() => looper.laneCount(any())).thenReturn(1);
    when(() => looper.inputSetup).thenReturn(const InputSetup.empty());
    when(() => looper.mixSettingsSnapshot).thenReturn(MixSettingsSnapshot());
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
    when(() => looper.allTracksEffects).thenReturn(const []);
    when(() => looper.allMonitors()).thenReturn(const {});
    when(() => looper.allLaneChains()).thenReturn(const {});
    // One recorded track carries two effects, so the pickers have a chain
    // to offer and a parameter list to show.
    when(
      () => looper.allTrackChains(),
    ).thenReturn(const {0: FxChainEnvelope()});
    // One factory rack, so the rows draw the pictures the Effects page does:
    // each pedal's own, and the rack's for the chain as a whole.
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
      () => looper.setTrackEffectParam(
        channel: any(named: 'channel'),
        index: any(named: 'index'),
        param: any(named: 'param'),
        value: any(named: 'value'),
      ),
    ).thenReturn(EngineResult.ok);
    when(
      () => looper.setVolume(any(), channel: any(named: 'channel')),
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

  late FakePedalLink transport;
  late PedalRepository pedal;

  void screenshotTestWidgets(
    String description,
    WidgetTesterCallback callback, {
    bool skip = false,
  }) => testWidgets(description, (tester) async {
    try {
      await callback(tester);
    } finally {
      // End the live hello watchdog before Flutter checks for leaked timers.
      unawaited(pedal.dispose());
    }
  }, skip: skip);

  Future<void> pump(
    WidgetTester tester, {
    ExternalJackSetup? jack,
    OneShotSnapshot? oneShotSnapshot,
  }) async {
    settings = SettingsRepository(store: FakeKeyValueStore());
    await settings.saveQuantize(value: false);
    await settings.saveQuantizeDiv(GridDivision.off.code);
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
    transport = FakePedalLink();
    pedal = PedalRepository(transport);
    addTearDown(() => unawaited(pedal.dispose()));
    final pedalCubit = PedalCubit(pedal: pedal);
    addTearDown(() => unawaited(pedalCubit.close()));
    final mixSettings = testMixSettings(looper, settings: settings);
    addTearDown(() => unawaited(mixSettings.close()));
    final tempo = MockClickTempoCubit();
    final decay = MockDecayPlaybackCubit(
      snapshot: DecaySnapshot(defaultPercent: 25, trackOverrides: const {0: 0}),
      oneShot: oneShotSnapshot,
    );
    record = RecordOptionsCubit(repository: looper, settings: settings);
    addTearDown(() => unawaited(record.close()));
    await record.load();
    timing = RecordTimingCubit(repository: looper, settings: settings);
    addTearDown(() => unawaited(timing.close()));
    await timing.load();
    final control = ControlCubit(
      decayControl: decay,
      oneShotControl: decay,
      recordLengthControl: record,
      recordTimingControl: timing,
      clickVolumeControl: tempo,
      fxPersistence: FxChainPersistence(looper: looper),
      looper: looper,
      mixSettings: mixSettings,
      pedal: pedal,
      settings: settings,
      performance: performance,
    );
    final tracks = TracksCubit(settings: settings);
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
            // The map's indicators read the frame the app last handed the
            // pedal.
            RepositoryProvider<PedalRepository>.value(value: pedal),
          ],
          child: MultiBlocProvider(
            providers: [
              BlocProvider.value(value: control),
              BlocProvider.value(value: tracks),
              BlocProvider.value(value: pedalCubit),
              BlocProvider<TempoCubit>.value(value: tempo),
              BlocProvider<PlaybackOptionsCubit>.value(value: decay),
              BlocProvider<RecordOptionsCubit>.value(value: record),
              BlocProvider<RecordTimingCubit>.value(value: timing),
            ],
            child: const ExternalPedalPage(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // The artwork decodes off the test's fake clock, so a golden taken on the
    // pumped frame catches an empty picture. runAsync lets the real decode
    // finish before anything is captured.
    final context = tester.element(find.byType(ExternalPedalPage));
    await tester.runAsync(() async {
      for (final art in ExternalPedalArt.artwork.values) {
        await precacheImage(AssetImage(art.asset), context);
      }
      await precacheImage(
        const AssetImage(ExpressionPositionPanel.asset),
        context,
      );
      for (final art in [
        fxModuleArt('Overdrive')!,
        fxModuleArt('Reverb')!,
        fxFootswitchAsset('guitar'),
      ]) {
        await precacheImage(
          AssetImage(art, package: FxCatalogueLoader.package),
          context,
        );
      }
    });
    await tester.pumpAndSettle();
  }

  Future<void> shot(WidgetTester tester, String name) => expectLater(
    find.byType(ExternalPedalPage),
    matchesGoldenFile('goldens/external_pedals_$name.png'),
  );

  Future<void> tap(WidgetTester tester, String key) async {
    await tester.tap(find.byKey(Key(key)));
    await tester.pumpAndSettle();
  }

  screenshotTestWidgets('a single switch on CTRL 1', (tester) async {
    await pump(tester);
    await shot(tester, 'single');
  }, skip: !hasScreenshotFonts);

  screenshotTestWidgets('a dual switch, editing its second button', (
    tester,
  ) async {
    await pump(tester);
    await tap(tester, 'external_type_dualSwitch');
    await tap(tester, 'external_switch_1');
    await shot(tester, 'dual');
  }, skip: !hasScreenshotFonts);

  screenshotTestWidgets('a latching switch, which has one gesture', (
    tester,
  ) async {
    await pump(tester);
    await tap(tester, 'external_hardware_latching');
    await shot(tester, 'latching');
  }, skip: !hasScreenshotFonts);

  /// A jack taught its whole travel, sweeping a pedal's parameter and one
  /// track's fader.
  final taught = ExternalJackSetup(
    type: ExternalJackType.expression,
    expression: ExternalExpressionSetup(
      calibration: ExpressionCalibration(heel: 0, toe: 255),
      mappings: [
        ExpressionMapping(
          target: const FxParamTarget(
            address: FxAddress(stage: FxStage.track),
            slotId: 'drive-1',
            param: 1,
          ),
        ),
        ExpressionMapping(target: const TrackVolumeTarget(0)),
      ],
    ),
  );

  Future<void> sweep(WidgetTester tester, int raw) async {
    transport
      ..hello()
      ..emit(
        CtrlMessage(
          jack: PedalCtrlJack.ctrl1,
          kind: PedalCtrlKind.expression,
          value: raw,
        ),
      );
    await tester.pumpAndSettle();
  }

  screenshotTestWidgets('an expression pedal with nothing plugged in', (
    tester,
  ) async {
    await pump(
      tester,
      jack: const ExternalJackSetup(type: ExternalJackType.expression),
    );
    await shot(tester, 'expression_empty');
  }, skip: !hasScreenshotFonts);

  screenshotTestWidgets('an expression pedal sweeping one control', (
    tester,
  ) async {
    await pump(tester, jack: taught);
    await sweep(tester, 80);
    await shot(tester, 'expression');
  }, skip: !hasScreenshotFonts);

  screenshotTestWidgets('teaching an expression pedal its travel', (
    tester,
  ) async {
    await pump(tester, jack: taught);
    await sweep(tester, 14);
    await tap(tester, 'expression_calibrate');
    await tap(tester, 'expression_capture_heel');
    await sweep(tester, 112);
    await shot(tester, 'expression_calibrate');
  }, skip: !hasScreenshotFonts);

  screenshotTestWidgets('choosing where a control lives', (tester) async {
    await pump(tester, jack: taught);
    await tap(tester, 'expression_add');
    await tap(tester, 'expression_kind_recordedTrack');
    await shot(tester, 'expression_destinations');
  }, skip: !hasScreenshotFonts);

  screenshotTestWidgets('choosing the control itself', (tester) async {
    await pump(tester, jack: taught);
    await tap(tester, 'expression_add');
    await tap(tester, 'expression_kind_recordedTrack');
    await tap(tester, 'expression_destination_track:0');
    await shot(tester, 'expression_controls');
  }, skip: !hasScreenshotFonts);

  /// A dual pedal whose first button turns two effects on and off and sets
  /// one parameter.
  final controlled = ExternalJackSetup(
    type: ExternalJackType.dualSwitch,
    dualFirst: ExternalSwitchSetup(
      gestures: const ControlGesturePair(
        hold: ModeAction(InteractionMode.mute),
      ),
      controls: ExternalControls(
        activations: const [
          ExternalActivation(
            target: FxSlotTarget(
              address: FxAddress(stage: FxStage.track),
              slotId: 'drive-1',
            ),
          ),
          ExternalActivation(
            target: FxSlotTarget(
              address: FxAddress(stage: FxStage.track),
              slotId: 'reverb-1',
            ),
            condition: ExternalCondition.held,
          ),
        ],
        parameters: [
          ExternalParameter(
            target: const TrackVolumeTarget(0),
            active: 0.65,
            inactive: 0.2,
          ),
        ],
      ),
    ),
  );

  screenshotTestWidgets("a button's controls, with an effect's rule open", (
    tester,
  ) async {
    await pump(tester, jack: controlled);
    await tap(tester, 'external_panel_controls');
    await shot(tester, 'controls');
  }, skip: !hasScreenshotFonts);

  screenshotTestWidgets("a button's controls, with a parameter's values open", (
    tester,
  ) async {
    await pump(tester, jack: controlled);
    await tap(tester, 'external_panel_controls');
    await tester.tap(find.text('Volume'));
    await tester.pumpAndSettle();
    await shot(tester, 'controls_parameter');
  }, skip: !hasScreenshotFonts);

  screenshotTestWidgets('choosing a control for a button', (tester) async {
    await pump(tester, jack: controlled);
    await tap(tester, 'external_panel_controls');
    await tap(tester, 'external_add_control');
    await tap(tester, 'expression_kind_recordedTrack');
    await tap(tester, 'expression_destination_track:0');
    await shot(tester, 'controls_pick');
  }, skip: !hasScreenshotFonts);

  screenshotTestWidgets('a button sets track pan while held', (tester) async {
    await pump(
      tester,
      jack: ExternalJackSetup(
        type: ExternalJackType.dualSwitch,
        dualFirst: ExternalSwitchSetup(
          controls: ExternalControls(
            parameters: [
              ExternalParameter(
                target: const TrackPanTarget(0),
                condition: ExternalValueCondition.heldReleased,
                active: 1,
                inactive: 0.5,
              ),
            ],
          ),
        ),
      ),
    );
    await tap(tester, 'external_panel_controls');
    await shot(tester, 'mixer_pan');
  }, skip: !hasScreenshotFonts);

  screenshotTestWidgets('a button releases Click at unity after a 200% hold', (
    tester,
  ) async {
    await pump(
      tester,
      jack: ExternalJackSetup(
        single: ExternalSwitchSetup(
          controls: ExternalControls(
            parameters: [
              ExternalParameter(
                target: const ClickVolumeTarget(),
                condition: ExternalValueCondition.heldReleased,
                active: 1,
                inactive: 0.5,
              ),
            ],
          ),
        ),
      ),
    );
    await tap(tester, 'external_panel_controls');
    final clickRow = externalControlKey(const ClickVolumeTarget());
    await tester.tap(
      find.byKey(Key('external_control_value_$clickRow')),
    );
    await tester.pumpAndSettle();
    expect(find.text('100%'), findsWidgets);
    expect(find.text('200%'), findsWidgets);
    expect(
      find.byKey(const Key('external_value_inactive_label')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('external_value_active_label')),
      findsOneWidget,
    );
    await shot(tester, 'click_held_released');
  }, skip: !hasScreenshotFonts);

  screenshotTestWidgets('a button holds decay and releases to explicit zero', (
    tester,
  ) async {
    const target = TrackDecayTarget(0);
    await pump(
      tester,
      jack: ExternalJackSetup(
        single: ExternalSwitchSetup(
          controls: ExternalControls(
            parameters: [
              ExternalParameter(
                target: target,
                condition: ExternalValueCondition.heldReleased,
                active: .75,
                inactive: 0,
              ),
            ],
          ),
        ),
      ),
    );
    await tap(tester, 'external_panel_controls');
    await tester.tap(
      find.byKey(Key('external_control_value_${externalControlKey(target)}')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Off · Keep layers'), findsWidgets);
    expect(find.text('75%'), findsWidgets);
    await shot(tester, 'decay_held_released');
  }, skip: !hasScreenshotFonts);

  screenshotTestWidgets('a button holds 32 bars and releases to Auto', (
    tester,
  ) async {
    const target = DefaultRecordLengthTarget();
    await pump(
      tester,
      jack: ExternalJackSetup(
        single: ExternalSwitchSetup(
          controls: ExternalControls(
            parameters: [
              ExternalParameter(
                target: target,
                condition: ExternalValueCondition.heldReleased,
                active: 0.5,
                inactive: 0,
              ),
            ],
          ),
        ),
      ),
    );
    await tap(tester, 'external_panel_controls');
    await tester.tap(
      find.byKey(Key('external_control_value_${externalControlKey(target)}')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Auto'), findsWidgets);
    expect(find.text('32 bars'), findsWidgets);
    await shot(tester, 'record_length_held_released');
  }, skip: !hasScreenshotFonts);

  screenshotTestWidgets('a button holds quarter and releases Immediately', (
    tester,
  ) async {
    const target = DefaultRecordTimingTarget();
    await pump(
      tester,
      jack: ExternalJackSetup(
        single: ExternalSwitchSetup(
          controls: ExternalControls(
            parameters: [
              ExternalParameter(
                target: target,
                condition: ExternalValueCondition.heldReleased,
                active: 4 / 6,
                inactive: 0,
              ),
            ],
          ),
        ),
      ),
    );
    expect(timing.state.recordTimingReady, isTrue);
    await tap(tester, 'external_panel_controls');
    await tester.tap(
      find.byKey(Key('external_control_value_${externalControlKey(target)}')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Immediately'), findsWidgets);
    expect(find.text('1/4 note'), findsWidgets);
    expect(
      find.byKey(const Key('external_value_inactive_label')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('external_value_active_label')),
      findsOneWidget,
    );
    await shot(tester, 'record_timing_held_released');
  }, skip: !hasScreenshotFonts);

  screenshotTestWidgets('a button holds Once and releases to Loop', (
    tester,
  ) async {
    const target = TrackOneShotTarget(0);
    await pump(
      tester,
      oneShotSnapshot: OneShotSnapshot(
        defaultOneShot: false,
        trackOverrides: const {0: true},
      ),
      jack: ExternalJackSetup(
        single: ExternalSwitchSetup(
          controls: ExternalControls(
            parameters: [
              ExternalParameter(
                target: target,
                condition: ExternalValueCondition.heldReleased,
                active: 1,
                inactive: 0,
              ),
            ],
          ),
        ),
      ),
    );
    await tap(tester, 'external_panel_controls');
    await tester.tap(
      find.byKey(Key('external_control_value_${externalControlKey(target)}')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Loop'), findsWidgets);
    expect(find.text('Once'), findsWidgets);
    await shot(tester, 'playback_held_released');
  }, skip: !hasScreenshotFonts);

  screenshotTestWidgets('an expression pedal edits track gain in dB', (
    tester,
  ) async {
    await pump(
      tester,
      jack: ExternalJackSetup(
        type: ExternalJackType.expression,
        expression: ExternalExpressionSetup(
          calibration: ExpressionCalibration(heel: 0, toe: 255),
          mappings: [
            ExpressionMapping(
              target: const TrackVolumeTarget(0),
              heel: 0.5,
            ),
          ],
        ),
      ),
    );
    await shot(tester, 'mixer_expression');
  }, skip: !hasScreenshotFonts);
}
