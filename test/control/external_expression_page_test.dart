import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:performance_repository/performance_repository.dart';
import 'package:routing_graph/routing_graph.dart';
import 'package:segno/control/binding/external_expression.dart';
import 'package:segno/control/binding/external_pedal.dart';
import 'package:segno/control/control.dart';
import 'package:segno/control/view/pedal_setup/external_pedal_page.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/cubit/tracks_cubit.dart';
import 'package:segno/theme/theme.dart';
import 'package:settings_repository/settings_repository.dart';

import '../helpers/fake_audio_engine.dart';
import '../helpers/fake_key_value_store.dart';
import '../pedal/helpers/fake_pedal_transport.dart';

class _MockLooperRepository extends Mock implements LooperRepository {}

/// The accepted expression half of External pedals: what the pedal is doing,
/// what it was taught, and what it sweeps.
void main() {
  late _MockLooperRepository looper;
  late StreamController<LooperState> looperStates;
  late SettingsRepository settings;
  late ControlCubit control;
  late TracksCubit tracks;
  late FakePedalTransport transport;
  late PedalRepository pedal;

  setUp(() {
    looper = _MockLooperRepository();
    looperStates = StreamController<LooperState>.broadcast();
    settings = SettingsRepository(store: FakeKeyValueStore());
    when(() => looper.looperState).thenAnswer((_) => looperStates.stream);
    when(() => looper.state).thenReturn(
      LooperState(
        tracks: [for (var i = 0; i < 2; i++) Track(channel: i)],
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
    ExternalJackSetup jack = const ExternalJackSetup(
      type: ExternalJackType.expression,
    ),
  }) async {
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
    transport = FakePedalTransport();
    pedal = PedalRepository(transport);
    addTearDown(() => unawaited(pedal.dispose()));
    control = ControlCubit(
      looper: looper,
      pedal: pedal,
      settings: settings,
      performance: performance,
      keepAliveInterval: Duration.zero,
    );
    tracks = TracksCubit(settings: settings);
    // unawaited: awaiting a cubit close inside a testWidgets body deadlocks
    // on the binding's stream cancellation (flutter/flutter#139870).
    addTearDown(() => unawaited(control.close()));
    addTearDown(() => unawaited(tracks.close()));
    await control.load();
    await control.setPedalSetup(
      control.state.pedalSetup.copyWith(
        external: const ExternalPedalSetup().withJack(ExternalJack.ctrl1, jack),
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

  /// Moves CTRL 1's pedal to [raw] out of 127.
  Future<void> sweep(WidgetTester tester, int raw) async {
    transport.emit(0xB0, PedalExpressionJack.ctrl1.cc, raw);
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
  const taught = ExternalJackSetup(
    type: ExternalJackType.expression,
    expression: ExternalExpressionSetup(
      calibration: ExpressionCalibration(heel: 0, toe: 1),
      mappings: [ExpressionMapping(target: TrackVolumeTarget(0))],
    ),
  );

  group('what the pedal is doing', () {
    testWidgets('a jack that has reported nothing says so', (tester) async {
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

    testWidgets('a pedal that has moved but not been taught says so', (
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
    });

    testWidgets('a taught pedal reads its position', (tester) async {
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

    testWidgets('both ends are captured, then staged', (tester) async {
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
          .forJack(ExternalJack.ctrl1)
          .expression
          .calibration;
      expect(saved, isNotNull);
      expect(saved!.heel, closeTo(10 / 127, 0.001));
      expect(saved.toe, closeTo(120 / 127, 0.001));
    });

    testWidgets('a pedal wired backwards is taken as it is', (tester) async {
      await pump(tester);
      await sweep(tester, 120);
      await tap(tester, 'expression_calibrate');
      await tap(tester, 'expression_capture_heel');
      await sweep(tester, 10);
      await tap(tester, 'expression_capture_toe');
      await tap(tester, 'expression_calibrate_use');
      await tap(tester, 'external_save');

      final saved = control.state.pedalSetup.external
          .forJack(ExternalJack.ctrl1)
          .expression
          .calibration!;
      expect(saved.heel, greaterThan(saved.toe));
      // And the readout runs the right way round.
      await sweep(tester, 120);
      expect(textOf('expression_position'), '0%');
    });

    testWidgets('two ends too close together are refused', (tester) async {
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

    testWidgets('sweeping to teach the ends writes nothing', (tester) async {
      await pump(tester, jack: taught);
      await openCalibrate(tester);
      // The sweep that opened the view was an ordinary one and did write.
      clearInteractions(looper);
      await sweep(tester, 127);
      verifyNever(
        () => looper.setVolume(any(), channel: any(named: 'channel')),
      );

      // And dispatch comes back when the view closes.
      await tap(tester, 'expression_calibrate_cancel');
      await sweep(tester, 100);
      verify(
        () => looper.setVolume(any(), channel: any(named: 'channel')),
      ).called(1);
    });

    testWidgets('cancelling leaves the taught travel alone', (tester) async {
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

    testWidgets('the cable dropping discards a half-taught travel', (
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
      pedal.unbind();
      await tester.pumpAndSettle();
      expect(labelOf(tester, 'expression_capture_heel'), 'Set heel');
    });
  });

  group('what it sweeps', () {
    testWidgets('a control is added through its destination', (tester) async {
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
            .forJack(ExternalJack.ctrl1)
            .expression
            .mappings
            .single
            .target,
        const TrackVolumeTarget(1),
      );
    });

    testWidgets('an endpoint moves, and the pedal writes it', (tester) async {
      await pump(tester, jack: taught);
      // Drag the heel slider to its middle.
      final slider = find.byKey(const Key('expression_endpoint_heel'));
      await tester.tapAt(tester.getCenter(slider));
      await tester.pumpAndSettle();
      expect(textOf('expression_endpoint_heel_value'), '50%');

      await tap(tester, 'external_save');
      await sweep(tester, 0);
      final written =
          verify(() => looper.setVolume(captureAny())).captured.last as double;
      expect(written, closeTo(0.5, 0.02));
    });

    testWidgets('a row shows what it is writing right now', (tester) async {
      await pump(tester, jack: taught);
      final key =
          'expression_value_'
          '${const TrackVolumeTarget(0).canonicalString()}';
      expect(textOf(key), '—', reason: 'nothing has reported a position');
      await sweep(tester, 127);
      expect(textOf(key), '100%');
    });

    testWidgets('a control the rig has lost keeps its row and says so', (
      tester,
    ) async {
      await pump(
        tester,
        jack: const ExternalJackSetup(
          type: ExternalJackType.expression,
          expression: ExternalExpressionSetup(
            calibration: ExpressionCalibration(heel: 0, toe: 1),
            mappings: [
              ExpressionMapping(
                target: FxParamTarget(
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
      expect(textOf('expression_range_title'), contains('no longer available'));
      // Shown, never repointed at whatever replaced it.
      expect(find.text('Unavailable'), findsOneWidget);
    });

    testWidgets('removing a control drops it', (tester) async {
      await pump(tester, jack: taught);
      await tap(tester, 'expression_remove');
      await tap(tester, 'external_save');
      expect(
        control.state.pedalSetup.external
            .forJack(ExternalJack.ctrl1)
            .expression
            .mappings,
        isEmpty,
      );
    });

    testWidgets('changing a control to the one it has moves nothing', (
      tester,
    ) async {
      await pump(
        tester,
        jack: const ExternalJackSetup(
          type: ExternalJackType.expression,
          expression: ExternalExpressionSetup(
            mappings: [
              ExpressionMapping(target: TrackVolumeTarget(0)),
              ExpressionMapping(target: TrackVolumeTarget(1)),
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
            .forJack(ExternalJack.ctrl1)
            .expression
            .mappings
            .map((m) => m.target),
        [const TrackVolumeTarget(0), const TrackVolumeTarget(1)],
        reason: 'a choice that changed nothing must not reorder the list',
      );
    });

    testWidgets('changing a control keeps the endpoints', (tester) async {
      await pump(
        tester,
        jack: const ExternalJackSetup(
          type: ExternalJackType.expression,
          expression: ExternalExpressionSetup(
            mappings: [
              ExpressionMapping(
                target: TrackVolumeTarget(0),
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
          .forJack(ExternalJack.ctrl1)
          .expression
          .mappings
          .single;
      expect(mapping.target, const TrackVolumeTarget(1));
      expect(mapping.heel, 0.25);
      expect(mapping.toe, 0.75);
    });
  });
}
