import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:performance_repository/performance_repository.dart';
import 'package:routing_graph/routing_graph.dart';
import 'package:segno/control/binding/external_pedal.dart';
import 'package:segno/control/control.dart';
import 'package:segno/control/view/pedal_setup/external_pedal_page.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/cubit/tracks_cubit.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/theme/theme.dart';
import 'package:settings_repository/settings_repository.dart';

import '../helpers/fake_audio_engine.dart';
import '../helpers/fake_key_value_store.dart';

class _MockLooperRepository extends Mock implements LooperRepository {}

/// The accepted External pedals screen: two jacks, one draft, one Save.
void main() {
  late _MockLooperRepository looper;
  late StreamController<LooperState> looperStates;
  late SettingsRepository settings;
  late ControlCubit control;
  late TracksCubit tracks;

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
    when(() => looper.allTrackChains()).thenReturn(const {});
    when(() => looper.trackChainEnabled(any())).thenReturn(true);
    when(() => looper.setMasterGain(any())).thenReturn(EngineResult.ok);
  });

  tearDown(() async {
    await looperStates.close();
  });

  Future<void> pump(WidgetTester tester) async {
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
    final pedal = PedalRepository(const NoopPedalTransport());
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

  ExternalJackSetup saved(ExternalJack jack) =>
      control.state.pedalSetup.external.forJack(jack);

  group('External pedals', () {
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
      expect(saved(ExternalJack.ctrl1).single.gestures.press, isNull);

      await tap(tester, 'external_save');
      expect(
        saved(ExternalJack.ctrl1).single.gestures.press,
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
      expect(saved(ExternalJack.ctrl1).single.isEmpty, isTrue);
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
  });
}
