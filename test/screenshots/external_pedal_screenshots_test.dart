@Tags(['screenshots'])
library;

import 'dart:async';
import 'dart:io';

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
import 'package:segno/control/view/pedal_setup/expression_position_panel.dart';
import 'package:segno/control/view/pedal_setup/external_pedal_art.dart';
import 'package:segno/control/view/pedal_setup/external_pedal_page.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/cubit/tracks_cubit.dart';
import 'package:segno/theme/theme.dart';
import 'package:settings_repository/settings_repository.dart';

import '../helpers/helpers.dart';
import '../pedal/helpers/fake_pedal_transport.dart';

class _MockLooperRepository extends Mock implements LooperRepository {}

/// The accepted External pedals screen, drawn at the console's own size.
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
  late SettingsRepository settings;

  setUp(() {
    looper = _MockLooperRepository();
    looperStates = StreamController<LooperState>.broadcast();
    settings = SettingsRepository(store: FakeKeyValueStore());
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

  late FakePedalTransport transport;
  late PedalRepository pedal;

  Future<void> pump(WidgetTester tester, {ExternalJackSetup? jack}) async {
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
    final control = ControlCubit(
      looper: looper,
      pedal: pedal,
      settings: settings,
      performance: performance,
      keepAliveInterval: Duration.zero,
    );
    final tracks = TracksCubit(settings: settings);
    addTearDown(() => unawaited(control.close()));
    addTearDown(() => unawaited(tracks.close()));
    await control.load();
    if (jack != null) {
      await control.setPedalSetup(
        control.state.pedalSetup.copyWith(
          external: const ExternalPedalSetup().withJack(
            ExternalJack.ctrl1,
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

  testWidgets('a single switch on CTRL 1', (tester) async {
    await pump(tester);
    await shot(tester, 'single');
  }, skip: !hasScreenshotFonts);

  testWidgets('a dual switch, editing its second button', (tester) async {
    await pump(tester);
    await tap(tester, 'external_type_dualSwitch');
    await tap(tester, 'external_switch_1');
    await shot(tester, 'dual');
  }, skip: !hasScreenshotFonts);

  testWidgets('a latching switch, which has one gesture', (tester) async {
    await pump(tester);
    await tap(tester, 'external_hardware_latching');
    await shot(tester, 'latching');
  }, skip: !hasScreenshotFonts);

  /// A jack taught its whole travel, sweeping one track's fader.
  const taught = ExternalJackSetup(
    type: ExternalJackType.expression,
    expression: ExternalExpressionSetup(
      calibration: ExpressionCalibration(heel: 0, toe: 1),
      mappings: [ExpressionMapping(target: TrackVolumeTarget(0))],
    ),
  );

  Future<void> sweep(WidgetTester tester, int raw) async {
    transport.emit(0xB0, PedalExpressionJack.ctrl1.cc, raw);
    await tester.pumpAndSettle();
  }

  testWidgets('an expression pedal with nothing plugged in', (tester) async {
    await pump(
      tester,
      jack: const ExternalJackSetup(type: ExternalJackType.expression),
    );
    await shot(tester, 'expression_empty');
  }, skip: !hasScreenshotFonts);

  testWidgets('an expression pedal sweeping one control', (tester) async {
    await pump(tester, jack: taught);
    await sweep(tester, 80);
    await shot(tester, 'expression');
  }, skip: !hasScreenshotFonts);

  testWidgets('teaching an expression pedal its travel', (tester) async {
    await pump(tester, jack: taught);
    await sweep(tester, 14);
    await tap(tester, 'expression_calibrate');
    await tap(tester, 'expression_capture_heel');
    await sweep(tester, 112);
    await shot(tester, 'expression_calibrate');
  }, skip: !hasScreenshotFonts);

  testWidgets('choosing where a control lives', (tester) async {
    await pump(tester, jack: taught);
    await tap(tester, 'expression_add');
    await tap(tester, 'expression_kind_recordedTrack');
    await shot(tester, 'expression_destinations');
  }, skip: !hasScreenshotFonts);

  testWidgets('choosing the control itself', (tester) async {
    await pump(tester, jack: taught);
    await tap(tester, 'expression_add');
    await tap(tester, 'expression_kind_recordedTrack');
    await tap(tester, 'expression_destination_track:1');
    await shot(tester, 'expression_controls');
  }, skip: !hasScreenshotFonts);
}
