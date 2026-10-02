import 'dart:async';

import 'package:controller_repository/controller_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:pedal_repository/testing.dart';
import 'package:performance_repository/performance_repository.dart';
import 'package:routing_graph/routing_graph.dart';
import 'package:segno/app/fx_chain_persistence.dart';
import 'package:segno/control/binding/external_expression.dart';
import 'package:segno/control/binding/external_pedal.dart';
import 'package:segno/control/binding/mix_value_scale.dart';
import 'package:segno/control/control.dart';
import 'package:segno/control/view/pedal_setup/external_pedal_page.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/cubit/playback_options_cubit.dart';
import 'package:segno/looper/cubit/tempo_cubit.dart';
import 'package:segno/looper/cubit/tracks_cubit.dart';
import 'package:segno/looper/model/one_shot.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/pedal/console_ctrl_source.dart';
import 'package:segno/pedal/cubit/pedal_cubit.dart';
import 'package:segno/theme/theme.dart';
import 'package:settings_repository/settings_repository.dart';

import '../helpers/fake_audio_engine.dart';
import '../helpers/fake_key_value_store.dart';
import '../helpers/mock_click_tempo_cubit.dart';
import '../helpers/mock_decay_playback_cubit.dart';
import '../helpers/test_mix_settings.dart';

class _MockLooperRepository extends Mock implements LooperRepository {}

/// The accepted expression half of External pedals: what the pedal is doing,
/// what it was taught, and what it sweeps.
void main() {
  setUpAll(() => registerFallbackValue(MixSettingsSnapshot()));
  late _MockLooperRepository looper;
  late StreamController<LooperState> looperStates;
  late SettingsRepository settings;
  late ControlCubit control;
  late TracksCubit tracks;
  late FakePedalLink transport;
  late PedalRepository pedal;
  late MixSettingsSnapshot currentMix;
  MixSettingsSnapshot? pendingMix;

  void expressionTestWidgets(
    String description,
    WidgetTesterCallback callback,
  ) => testWidgets(description, (tester) async {
    try {
      await callback(tester);
    } finally {
      // The hello watchdog is a live timer until the transport is released;
      // close it before Flutter verifies that this test left no timers.
      unawaited(pedal.dispose());
    }
  });

  setUp(() {
    looper = _MockLooperRepository();
    looperStates = StreamController<LooperState>.broadcast();
    currentMix = MixSettingsSnapshot(trackLevels: const {0: 1, 1: 1});
    pendingMix = null;
    when(() => looper.looperState).thenAnswer((_) => looperStates.stream);
    when(() => looper.state).thenReturn(
      LooperState(
        tracks: [for (var i = 0; i < 2; i++) Track(channel: i)],
        status: const EngineStatus(sampleRate: 48000),
      ),
    );
    when(() => looper.sessionRevision).thenReturn(0);
    when(() => looper.mixGeneration).thenReturn(0);
    when(() => looper.mixSettingsSettled).thenReturn(true);
    when(() => looper.mixSettingsSnapshot).thenAnswer((_) => currentMix);
    when(() => looper.laneCount(any())).thenReturn(1);
    when(() => looper.inputSetup).thenReturn(const InputSetup.empty());
    when(() => looper.validateMixSettings(any())).thenReturn(EngineResult.ok);
    when(() => looper.applyMixSettings(any())).thenAnswer((call) {
      pendingMix = call.positionalArguments.first as MixSettingsSnapshot;
      return EngineResult.ok;
    });
    when(() => looper.settleMixSettings()).thenAnswer((_) async {
      if (pendingMix case final accepted?) currentMix = accepted;
      pendingMix = null;
      return EngineResult.ok;
    });
    when(() => looper.trackEffects(any())).thenReturn(const []);
    when(() => looper.monitorEffects(any())).thenReturn(const []);
    when(() => looper.laneEffects(any(), any())).thenReturn(const []);
    when(() => looper.outputEffects(any())).thenReturn(const []);
    when(() => looper.allTracksEffects).thenReturn(const []);
    when(() => looper.allMonitors()).thenReturn(const {});
    when(() => looper.allLaneChains()).thenReturn(const {});
    when(() => looper.allTrackChains()).thenReturn(const {});
    when(() => looper.trackChainEnabled(any())).thenReturn(true);
    when(() => looper.setMasterGain(any())).thenReturn(EngineResult.ok);
    when(
      () => looper.setVolume(any(), channel: any(named: 'channel')),
    ).thenReturn(EngineResult.ok);
  });

  tearDown(() async {
    await looperStates.close();
  });

  /// Opens the page with [jack] already saved on CTRL 1.
  Future<void> pump(
    WidgetTester tester, {
    ExternalJackSetup? jack,
    double? clickVolume = 1,
    OneShotSnapshot? oneShotSnapshot,
  }) async {
    settings = SettingsRepository(store: FakeKeyValueStore());
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
    addTearDown(pedal.dispose);
    final mixSettings = testMixSettings(looper, settings: settings);
    addTearDown(() => unawaited(mixSettings.close()));
    final pedalCubit = PedalCubit(pedal: pedal);
    addTearDown(() => unawaited(pedalCubit.close()));
    final tempo = MockClickTempoCubit(clickVolume: clickVolume);
    final playback = MockDecayPlaybackCubit(oneShot: oneShotSnapshot);
    final controller = ControllerRepository(
      sources: [ConsoleCtrlSource(pedal)],
    );
    addTearDown(() => unawaited(controller.dispose()));
    control = ControlCubit(
      decayControl: playback,
      oneShotControl: playback,
      fxPersistence: FxChainPersistence(looper: looper),
      looper: looper,
      clickVolumeControl: tempo,
      mixSettings: mixSettings,
      controller: controller,
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
    await control.setPedalSetup(
      control.state.pedalSetup.copyWith(
        external: ExternalPedalSetup().withJack(
          PedalCtrlJack.ctrl1,
          jack ?? const ExternalJackSetup(type: ExternalJackType.expression),
        ),
      ),
    );

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
            RepositoryProvider<PedalRepository>.value(value: pedal),
          ],
          child: MultiBlocProvider(
            providers: [
              BlocProvider.value(value: control),
              BlocProvider.value(value: tracks),
              BlocProvider.value(value: pedalCubit),
              BlocProvider<TempoCubit>.value(value: tempo),
              BlocProvider<PlaybackOptionsCubit>.value(value: playback),
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

  /// The picker's key for one control, which is keyed by its canonical form.
  String targetKey(ControlValueTarget target) =>
      'expression_target_${target.canonicalString()}';

  /// Moves CTRL 1's pedal from legacy test position 0..127 onto UART bytes.
  Future<void> sweep(WidgetTester tester, int raw) async {
    if (pedal.status != PedalLinkStatus.connected) transport.hello();
    transport.emit(
      CtrlMessage(
        jack: PedalCtrlJack.ctrl1,
        kind: PedalCtrlKind.expression,
        value: (raw * 255 / 127).round(),
      ),
    );
    await tester.pumpAndSettle();
  }

  String textOf(String key) =>
      (find.byKey(Key(key)).evaluate().single.widget as dynamic).data as String;

  /// The label a keyed button is showing.
  String labelOf(WidgetTester tester, String key) => tester
      .widgetList<Text>(
        find.descendant(of: find.byKey(Key(key)), matching: find.byType(Text)),
      )
      .map((text) => text.data ?? '')
      .join();

  /// A jack taught its whole travel, sweeping track 1's fader.
  final taught = ExternalJackSetup(
    type: ExternalJackType.expression,
    expression: ExternalExpressionSetup(
      calibration: ExpressionCalibration(heel: 0, toe: 255),
      mappings: [ExpressionMapping(target: const TrackVolumeTarget(0))],
    ),
  );

  group('what the pedal is doing', () {
    expressionTestWidgets('a jack that has reported nothing says so', (
      tester,
    ) async {
      await pump(tester);
      expect(
        textOf('expression_status'),
        'Not connected',
        reason: 'the board reports every jack at link-up, so silence is empty',
      );
      expect(textOf('expression_position'), '—');
      // Nothing to capture: the ends of a travel are readings, and there are
      // none.
      final button = tester.widget<GestureDetector>(
        find.descendant(
          of: find.byKey(const Key('expression_calibrate')),
          matching: find.byType(GestureDetector),
        ),
      );
      expect(button.onTap, isNull);
    });

    expressionTestWidgets(
      'a pedal that has moved but not been taught says so',
      (
        tester,
      ) async {
        await pump(tester);
        await sweep(tester, 64);
        expect(textOf('expression_status'), 'Calibration needed');
        expect(
          textOf('expression_position'),
          '—',
          reason: 'a percentage of an unknown range would mean nothing',
        );
      },
    );

    expressionTestWidgets('a taught pedal reads its position', (tester) async {
      await pump(tester, jack: taught);
      await sweep(tester, 127);
      expect(textOf('expression_position'), '100%');
      await sweep(tester, 0);
      expect(textOf('expression_position'), '0%');
      expect(find.byKey(const Key('expression_status')), findsNothing);
    });
  });

  group('teaching the travel', () {
    Future<void> openCalibrate(WidgetTester tester) async {
      await sweep(tester, 10);
      await tap(tester, 'expression_calibrate');
    }

    expressionTestWidgets('both ends are captured, then staged', (
      tester,
    ) async {
      await pump(tester);
      await openCalibrate(tester);
      await tap(tester, 'expression_capture_heel');
      await sweep(tester, 120);
      await tap(tester, 'expression_capture_toe');
      await tap(tester, 'expression_calibrate_use');

      // Staged into the draft, not saved: Save is what commits it.
      expect(find.byKey(const Key('expression_status')), findsNothing);
      await tap(tester, 'external_save');
      final saved = control.state.pedalSetup.external
          .forJack(PedalCtrlJack.ctrl1)
          .expression
          .calibration;
      expect(saved, isNotNull);
      expect(saved!.heel, 20);
      expect(saved.toe, 241);
    });

    expressionTestWidgets('a pedal wired backwards is taken as it is', (
      tester,
    ) async {
      await pump(tester);
      await sweep(tester, 120);
      await tap(tester, 'expression_calibrate');
      await tap(tester, 'expression_capture_heel');
      await sweep(tester, 10);
      await tap(tester, 'expression_capture_toe');
      await tap(tester, 'expression_calibrate_use');
      await tap(tester, 'external_save');

      final saved = control.state.pedalSetup.external
          .forJack(PedalCtrlJack.ctrl1)
          .expression
          .calibration!;
      expect(saved.heel, greaterThan(saved.toe));
      // And the readout runs the right way round.
      await sweep(tester, 120);
      expect(textOf('expression_position'), '0%');
    });

    expressionTestWidgets('two ends too close together are refused', (
      tester,
    ) async {
      await pump(tester);
      await openCalibrate(tester);
      await tap(tester, 'expression_capture_heel');
      await sweep(tester, 15);
      await tap(tester, 'expression_capture_toe');
      expect(
        textOf('expression_calibrate_hint'),
        "Move through more of the pedal's travel.",
      );
      final use = tester.widget<GestureDetector>(
        find.descendant(
          of: find.byKey(const Key('expression_calibrate_use')),
          matching: find.byType(GestureDetector),
        ),
      );
      expect(use.onTap, isNull);
    });

    expressionTestWidgets('sweeping to teach the ends writes nothing', (
      tester,
    ) async {
      await pump(tester, jack: taught);
      await openCalibrate(tester);
      // The sweep that opened the view was an ordinary one and did write.
      clearInteractions(looper);
      await sweep(tester, 127);
      verifyNever(
        () => looper.applyMixSettings(any()),
      );

      // And dispatch comes back when the view closes.
      await tap(tester, 'expression_calibrate_cancel');
      await sweep(tester, 100);
      await sweep(tester, 101);
      verify(
        () => looper.applyMixSettings(any()),
      ).called(1);
    });

    expressionTestWidgets('cancelling leaves the taught travel alone', (
      tester,
    ) async {
      await pump(tester, jack: taught);
      await openCalibrate(tester);
      await tap(tester, 'expression_capture_heel');
      await tap(tester, 'expression_calibrate_cancel');
      await sweep(tester, 127);
      expect(
        textOf('expression_position'),
        '100%',
        reason: 'a half-taught travel must never replace a working one',
      );
    });

    expressionTestWidgets('the cable dropping discards a half-taught travel', (
      tester,
    ) async {
      await pump(tester);
      await openCalibrate(tester);
      await tap(tester, 'expression_capture_heel');
      expect(
        labelOf(tester, 'expression_capture_heel'),
        'Set again',
        reason: 'the first end is captured',
      );

      // The board goes away. Its readings were about hardware that is no
      // longer there.
      transport.emit(
        const CtrlMessage(
          jack: PedalCtrlJack.ctrl1,
          kind: PedalCtrlKind.none,
          value: 0,
        ),
      );
      await tester.pumpAndSettle();
      expect(labelOf(tester, 'expression_capture_heel'), 'Set heel');
    });
  });

  group('what it sweeps', () {
    expressionTestWidgets('a control is added through its destination', (
      tester,
    ) async {
      await pump(tester);
      expect(
        textOf('expression_empty'),
        'Give this pedal something to control.',
      );

      await tap(tester, 'expression_add');
      await tap(tester, 'expression_kind_recordedTrack');
      await tap(tester, 'expression_destination_track:1');
      await tap(tester, targetKey(const TrackVolumeTarget(1)));
      await tap(tester, 'external_save');

      expect(
        control.state.pedalSetup.external
            .forJack(PedalCtrlJack.ctrl1)
            .expression
            .mappings
            .single
            .target,
        const TrackVolumeTarget(1),
      );
    });

    expressionTestWidgets(
      'Click appears under Outputs and keeps the normal full range on Save',
      (tester) async {
        await pump(tester);
        await tap(tester, 'expression_add');
        await tap(tester, 'expression_kind_output');
        await tap(tester, 'expression_destination_click');
        await tap(tester, targetKey(const ClickVolumeTarget()));
        expect(textOf('expression_endpoint_heel_value'), '0%');
        expect(textOf('expression_endpoint_toe_value'), '200%');
        await tap(tester, 'external_save');
        final mapping = control.state.pedalSetup.external
            .forJack(PedalCtrlJack.ctrl1)
            .expression
            .mappings
            .single;
        expect(mapping.target, const ClickVolumeTarget());
        expect((mapping.heel, mapping.toe), (0, 1));
        verifyNever(() => looper.setClickVolume(any()));
      },
    );

    expressionTestWidgets(
      'Loop/Once keeps full range, Escape, Save and Cancel in the draft',
      (tester) async {
        await pump(
          tester,
          oneShotSnapshot: OneShotSnapshot(
            defaultOneShot: false,
            trackOverrides: const {},
          ),
        );
        await tap(tester, 'expression_add');
        await tap(tester, 'expression_kind_loopControls');
        await tap(tester, 'expression_destination_loop:defaults');
        await tap(tester, targetKey(const DefaultOneShotTarget()));
        expect(textOf('expression_endpoint_heel_value'), 'Loop');
        expect(textOf('expression_endpoint_toe_value'), 'Once');
        await tap(tester, 'expression_endpoint_heel_once');
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(textOf('expression_endpoint_heel_value'), 'Loop');
        await tap(tester, 'expression_endpoint_heel_once');
        await tap(tester, 'external_save');
        final saved = control.state.pedalSetup.external
            .forJack(PedalCtrlJack.ctrl1)
            .expression
            .mappings
            .single;
        expect(saved.target, const DefaultOneShotTarget());
        expect((saved.heel, saved.toe), (1, 1));
        await tap(tester, 'expression_endpoint_heel_loop');
        await tap(tester, 'external_cancel');
        final afterCancel = control.state.pedalSetup.external
            .forJack(PedalCtrlJack.ctrl1)
            .expression
            .mappings
            .single;
        expect((afterCancel.heel, afterCancel.toe), (1, 1));
        verifyNever(
          () => looper.setDefaultOneShot(oneShot: any(named: 'oneShot')),
        );
      },
    );

    expressionTestWidgets('an endpoint moves, and the pedal writes it', (
      tester,
    ) async {
      await pump(tester, jack: taught);
      // Drag the heel slider to its middle.
      final slider = find.byKey(const Key('expression_endpoint_heel'));
      await tester.tapAt(tester.getCenter(slider));
      await tester.pumpAndSettle();
      expect(textOf('expression_endpoint_heel_value'), '−27.0 dB');

      await tap(tester, 'external_save');
      await sweep(tester, 0);
      await sweep(tester, 1);
      final written =
          (verify(
                    () => looper.applyMixSettings(captureAny()),
                  ).captured.last
                  as MixSettingsSnapshot)
              .trackLevels[0]!;
      expect(written, closeTo(mixerGainAt(0.5), 0.002));
    });

    expressionTestWidgets(
      'Escape cancels a heel edit and Enter keeps the next',
      (
        tester,
      ) async {
        await pump(tester, jack: taught);
        final slider = find.byKey(const Key('expression_endpoint_heel'));
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
        expect(tester.widget<LoopSlider>(slider).value, closeTo(0.01, 1e-9));
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump();
        expect(tester.widget<LoopSlider>(slider).value, 0);

        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        expect(tester.widget<LoopSlider>(slider).value, closeTo(0.01, 1e-9));
        await tap(tester, 'external_save');
        expect(
          control.state.pedalSetup.external
              .forJack(PedalCtrlJack.ctrl1)
              .expression
              .mappings
              .single
              .heel,
          closeTo(0.01, 1e-9),
        );
      },
    );

    expressionTestWidgets('Escape leaves the saved heel endpoint unchanged', (
      tester,
    ) async {
      await pump(tester, jack: taught);
      final slider = find.byKey(const Key('expression_endpoint_heel'));
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
      expect(tester.widget<LoopSlider>(slider).value, closeTo(0.01, 1e-9));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(tester.widget<LoopSlider>(slider).value, 0);
      await tap(tester, 'external_save');
      expect(
        control.state.pedalSetup.external
            .forJack(PedalCtrlJack.ctrl1)
            .expression
            .mappings
            .single
            .heel,
        0,
      );
    });

    expressionTestWidgets(
      'a performer scrolling the list is not snapped back',
      (
        tester,
      ) async {
        // Four sweeps: more than the list shows, with the first one open.
        await pump(
          tester,
          jack: ExternalJackSetup(
            type: ExternalJackType.expression,
            expression: ExternalExpressionSetup(
              calibration: ExpressionCalibration(heel: 0, toe: 255),
              mappings: [
                ExpressionMapping(target: const TrackVolumeTarget(0)),
                ExpressionMapping(target: const TrackVolumeTarget(1)),
                ExpressionMapping(target: const MasterGainTarget()),
                ExpressionMapping(
                  target: const FxParamTarget(
                    address: FxAddress(stage: FxStage.track),
                    slotId: 'vanished',
                    param: 0,
                  ),
                ),
              ],
            ),
          ),
        );
        final last = find.text('vanished · #0');
        expect(last.hitTestable(), findsNothing, reason: 'below the fold');
        await tester.drag(find.text('Gain'), const Offset(0, -300));
        await tester.pumpAndSettle();
        expect(last.hitTestable(), findsOne);

        // The pedal moving rebuilds the list. The first row is still the open
        // one; the performer's scroll stays where they put it.
        await sweep(tester, 100);
        expect(last.hitTestable(), findsOne);
      },
    );

    expressionTestWidgets('a row shows what it is writing right now', (
      tester,
    ) async {
      await pump(tester, jack: taught);
      final key =
          'expression_value_'
          '${const TrackVolumeTarget(0).canonicalString()}';
      expect(textOf(key), '—', reason: 'nothing has reported a position');
      await sweep(tester, 127);
      expect(textOf(key), '+6.0 dB');
    });

    expressionTestWidgets(
      'a control the rig has lost keeps its row and says so',
      (
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
                  target: const FxParamTarget(
                    address: FxAddress(stage: FxStage.track),
                    slotId: 'vanished',
                    param: 0,
                  ),
                ),
              ],
            ),
          ),
        );
        await sweep(tester, 127);
        expect(
          textOf('expression_range_title'),
          contains('no longer available'),
        );
        // Shown, never repointed at whatever replaced it.
        expect(find.text('Unavailable'), findsOneWidget);
      },
    );

    expressionTestWidgets('removing a control drops it', (tester) async {
      await pump(tester, jack: taught);
      await tap(tester, 'expression_remove');
      await tap(tester, 'external_save');
      expect(
        control.state.pedalSetup.external
            .forJack(PedalCtrlJack.ctrl1)
            .expression
            .mappings,
        isEmpty,
      );
    });

    expressionTestWidgets(
      'changing a control to the one it has moves nothing',
      (
        tester,
      ) async {
        await pump(
          tester,
          jack: ExternalJackSetup(
            type: ExternalJackType.expression,
            expression: ExternalExpressionSetup(
              mappings: [
                ExpressionMapping(target: const TrackVolumeTarget(0)),
                ExpressionMapping(target: const TrackVolumeTarget(1)),
              ],
            ),
          ),
        );
        await tap(tester, 'expression_change');
        await tap(tester, 'expression_kind_recordedTrack');
        await tap(tester, 'expression_destination_track:0');
        await tap(tester, targetKey(const TrackVolumeTarget(0)));
        await tap(tester, 'external_save');

        expect(
          control.state.pedalSetup.external
              .forJack(PedalCtrlJack.ctrl1)
              .expression
              .mappings
              .map((m) => m.target),
          [const TrackVolumeTarget(0), const TrackVolumeTarget(1)],
          reason: 'a choice that changed nothing must not reorder the list',
        );
      },
    );

    expressionTestWidgets('changing a control keeps the endpoints', (
      tester,
    ) async {
      await pump(
        tester,
        jack: ExternalJackSetup(
          type: ExternalJackType.expression,
          expression: ExternalExpressionSetup(
            mappings: [
              ExpressionMapping(
                target: const TrackVolumeTarget(0),
                heel: 0.25,
                toe: 0.75,
              ),
            ],
          ),
        ),
      );
      await tap(tester, 'expression_change');
      await tap(tester, 'expression_kind_recordedTrack');
      await tap(tester, 'expression_destination_track:1');
      await tap(tester, targetKey(const TrackVolumeTarget(1)));
      await tap(tester, 'external_save');

      final mapping = control.state.pedalSetup.external
          .forJack(PedalCtrlJack.ctrl1)
          .expression
          .mappings
          .single;
      expect(mapping.target, const TrackVolumeTarget(1));
      expect(mapping.heel, 0.25);
      expect(mapping.toe, 0.75);
    });
  });
}
