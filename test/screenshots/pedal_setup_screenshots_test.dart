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
import 'package:segno/app/fx_chain_persistence.dart';
import 'package:segno/control/control.dart';
import 'package:segno/control/view/pedal_setup/pedal_setup_page.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/cubit/tracks_cubit.dart';
import 'package:segno/pedal/cubit/pedal_cubit.dart';
import 'package:segno/theme/theme.dart';
import 'package:settings_repository/settings_repository.dart';

import '../helpers/helpers.dart';

class _MockLooperRepository extends Mock implements LooperRepository {}

/// The accepted Pedals setup, drawn at the console's own size.
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
    when(() => looper.sessionRevision).thenReturn(0);
    when(() => looper.fxReplayConfirmed).thenAnswer(
      (_) => const Stream<({int mixGeneration, int sessionRevision})>.empty(),
    );
    when(() => looper.mixGeneration).thenReturn(0);
    when(() => looper.inputSetup).thenReturn(const InputSetup.empty());
    when(() => looper.laneCount(any())).thenAnswer((call) {
      final channel = call.positionalArguments.first as int;
      return looper.state.tracks
              .where((track) => track.channel == channel)
              .firstOrNull
              ?.lanes
              .length ??
          0;
    });
    looperStates = StreamController<LooperState>.broadcast();
    when(() => looper.looperState).thenAnswer((_) => looperStates.stream);
    when(() => looper.state).thenReturn(
      LooperState(
        tracks: [for (var i = 0; i < 8; i++) Track(channel: i)],
        status: const EngineStatus(sampleRate: 48000),
      ),
    );
    when(() => looper.trackEffects(any())).thenReturn(const []);
    when(() => looper.allTrackChains()).thenReturn(const {});
    when(() => looper.trackChainEnabled(any())).thenReturn(true);
    when(() => looper.setMasterGain(any())).thenReturn(EngineResult.ok);
  });

  tearDown(() async {
    await looperStates.close();
  });

  Future<void> pump(WidgetTester tester, {bool unreadable = false}) async {
    final store = FakeKeyValueStore();
    if (unreadable) {
      store.values['pedal.setup'] = '{"trackHold":"unknown-hold"}';
    }
    settings = SettingsRepository(store: store);
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
    final mixSettings = testMixSettings(looper, settings: settings);
    addTearDown(() => unawaited(mixSettings.close()));
    final pedal = PedalRepository(NoopPedalLink());
    final pedalCubit = PedalCubit(pedal: pedal);
    addTearDown(() => unawaited(pedalCubit.close()));
    final control = ControlCubit(
      decayControl: FakeDecayControl(),
      oneShotControl: FakeOneShotControl(),
      recordLengthControl: FakeRecordLengthControl(),
      recordTimingControl: FakeRecordTimingControl(),
      clickVolumeControl: FakeClickVolumeControl(),
      clickModeControl: FakeClickModeControl(),
      recordStartControl: FakeRecordStartControl(),
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
        home: RepositoryProvider<LooperRepository>.value(
          value: looper,
          child: MultiBlocProvider(
            providers: [
              BlocProvider.value(value: control),
              BlocProvider.value(value: pedalCubit),
              BlocProvider.value(value: tracks),
            ],
            child: const PedalSetupPage(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> shot(WidgetTester tester, String name) => expectLater(
    find.byType(PedalSetupPage),
    matchesGoldenFile('goldens/pedal_setup_$name.png'),
  );

  testWidgets('Track controls, the fixed plate with MODE selected', (
    tester,
  ) async {
    await pump(tester);
    await shot(tester, 'tracks');
  }, skip: !hasScreenshotFonts);

  testWidgets('Track controls, the four track caps as one group', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.byKey(const Key('pedal_setup_cap_track2')));
    await tester.pumpAndSettle();
    await shot(tester, 'tracks_group');
  }, skip: !hasScreenshotFonts);

  testWidgets('Mode choices', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const Key('pedal_setup_hold')));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/pedal_setup_picker.png'),
    );
  }, skip: !hasScreenshotFonts);

  testWidgets('Unreadable assignments require a replacement Save', (
    tester,
  ) async {
    await pump(tester, unreadable: true);
    await shot(tester, 'unavailable');
  }, skip: !hasScreenshotFonts);

  testWidgets('Custom controls on bank B', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const Key('pedal_setup_context_custom')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('pedal_setup_cap_bank')));
    await tester.pumpAndSettle();
    await shot(tester, 'custom_bank_b');
  }, skip: !hasScreenshotFonts);

  testWidgets('Clear custom assignments asks before it empties the draft', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.byKey(const Key('pedal_setup_context_custom')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('pedal_setup_press')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('pedal_choice_group_transport')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('pedal_choice_command:stop')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('pedal_setup_clear_custom')));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/pedal_setup_clear.png'),
    );
  }, skip: !hasScreenshotFonts);
  testWidgets('All ten LED colors share the physical map', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const Key('pedal_setup_context_leds')));
    await tester.pumpAndSettle();
    await shot(tester, 'leds');
  }, skip: !hasScreenshotFonts);

  testWidgets('Custom color editor', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const Key('pedal_setup_context_leds')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('pedal_setup_swatch_add')));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/pedal_setup_color_editor.png'),
    );
  }, skip: !hasScreenshotFonts);

  testWidgets('Custom color selection remains named', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const Key('pedal_setup_context_leds')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('pedal_setup_swatch_add')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('pedal_color_done')));
    await tester.pumpAndSettle();
    await shot(tester, 'leds_custom');
  }, skip: !hasScreenshotFonts);
}
