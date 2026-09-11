import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:performance_repository/performance_repository.dart';
import 'package:routing_graph/routing_graph.dart';
import 'package:segno/control/control.dart';
import 'package:segno/control/view/pedal_setup/pedal_setup_page.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/cubit/tracks_cubit.dart';
import 'package:segno/looper/model/interaction_mode.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/theme/theme.dart';
import 'package:settings_repository/settings_repository.dart';

import '../helpers/fake_audio_engine.dart';
import '../helpers/fake_key_value_store.dart';

class _MockLooperRepository extends Mock implements LooperRepository {}

/// The accepted Pedals setup (Layout A): one draft, two contexts, one Save.
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
    control = ControlCubit(
      looper: looper,
      pedal: PedalRepository(const NoopPedalTransport()),
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
        home: RepositoryProvider<LooperRepository>.value(
          value: looper,
          child: MultiBlocProvider(
            providers: [
              BlocProvider.value(value: control),
              BlocProvider.value(value: tracks),
            ],
            child: const PedalSetupPage(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openCustom(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('pedal_setup_context_custom')));
    await tester.pumpAndSettle();
  }

  Future<void> choose(
    WidgetTester tester, {
    required Key field,
    required String group,
    required String choice,
  }) async {
    await tester.tap(find.byKey(field));
    await tester.pumpAndSettle();
    final tab = find.byKey(Key('pedal_choice_group_$group'));
    if (tab.evaluate().isNotEmpty) {
      await tester.tap(tab);
      await tester.pumpAndSettle();
    }
    await tester.tap(find.byKey(Key('pedal_choice_$choice')));
    await tester.pumpAndSettle();
  }

  const press = Key('pedal_setup_press');
  const hold = Key('pedal_setup_hold');
  const save = Key('pedal_setup_save');
  const cancel = Key('pedal_setup_cancel');

  group('Track controls', () {
    testWidgets('opens on MODE, the one switch with both gestures free', (
      tester,
    ) async {
      await pump(tester);
      final l10n = AppLocalizations.of(
        tester.element(find.byType(PedalSetupPage)),
      );
      expect(
        tester
            .widget<AppText>(find.byKey(const Key('pedal_setup_selected')))
            .data,
        'MODE',
      );
      // The accepted defaults, on the accepted gestures.
      expect(find.text(l10n.actionModeMute), findsOneWidget);
      expect(find.text(l10n.actionModeFx), findsOneWidget);
    });

    testWidgets('the fixed switches are dimmed and refuse the tap', (
      tester,
    ) async {
      await pump(tester);
      for (final button in [
        PedalButton.stop,
        PedalButton.undo,
        PedalButton.clear,
        PedalButton.bank,
      ]) {
        await tester.tap(
          find.byKey(Key('pedal_setup_cap_${button.name}')),
          warnIfMissed: false,
        );
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<AppText>(find.byKey(const Key('pedal_setup_selected')))
              .data,
          'MODE',
          reason: button.name,
        );
      }
    });

    testWidgets('the four track caps are edited as one group', (tester) async {
      await pump(tester);
      final l10n = AppLocalizations.of(
        tester.element(find.byType(PedalSetupPage)),
      );
      await tester.tap(find.byKey(const Key('pedal_setup_cap_track3')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<AppText>(find.byKey(const Key('pedal_setup_selected')))
            .data,
        l10n.pedalSetupTrackGroup,
      );
      expect(find.text(l10n.actionArmOverdub), findsOneWidget);
    });

    testWidgets('Save applies the draft through the cubit and persists it', (
      tester,
    ) async {
      await pump(tester);
      expect(control.state.pedalSetup.modePress, InteractionMode.mute);

      await choose(
        tester,
        field: press,
        group: 'modes',
        choice: 'mode_fx',
      );
      // Nothing has reached the rig yet: the edit is a draft.
      expect(control.state.pedalSetup.modePress, InteractionMode.mute);

      await tester.tap(find.byKey(save));
      await tester.pumpAndSettle();
      expect(control.state.pedalSetup.modePress, InteractionMode.fx);
      expect(
        await settings.loadPedalSetup(),
        control.state.pedalSetup.encode(),
      );
    });

    testWidgets('Cancel discards the draft', (tester) async {
      await pump(tester);
      await choose(
        tester,
        field: hold,
        group: 'modes',
        choice: 'none',
      );
      await tester.tap(find.byKey(cancel));
      await tester.pumpAndSettle();
      expect(control.state.pedalSetup.modeHold, InteractionMode.fx);
      final l10n = AppLocalizations.of(
        tester.element(find.byType(PedalSetupPage)),
      );
      expect(find.text(l10n.actionModeFx), findsOneWidget);
    });

    testWidgets('Save and Cancel are inert until something is edited', (
      tester,
    ) async {
      await pump(tester);
      expect(tester.widget<LoopOutlinedButton>(find.byKey(save)).onTap, isNull);
      expect(
        tester.widget<LoopOutlinedButton>(find.byKey(cancel)).onTap,
        isNull,
      );
    });
  });

  group('Custom controls', () {
    testWidgets('assigns a press from the shared catalogue', (tester) async {
      await pump(tester);
      await openCustom(tester);
      await choose(
        tester,
        field: press,
        group: 'selected',
        choice: 'direct:mute:selected',
      );
      await tester.tap(find.byKey(save));
      await tester.pumpAndSettle();
      expect(
        control.state.pedalSetup.customFor(PedalButton.track1, bank: 0).press,
        const TrackOperationAction(
          operation: TrackOperation.mute,
          scope: SelectedTrackScope(),
        ),
      );
    });

    testWidgets('a track switch carries a pair per bank', (tester) async {
      await pump(tester);
      await openCustom(tester);
      await choose(
        tester,
        field: press,
        group: 'transport',
        choice: 'command:stop',
      );
      await tester.tap(find.byKey(const Key('pedal_setup_cap_bank')));
      await tester.pumpAndSettle();
      await choose(
        tester,
        field: press,
        group: 'transport',
        choice: 'command:undo',
      );
      await tester.tap(find.byKey(save));
      await tester.pumpAndSettle();

      final setup = control.state.pedalSetup;
      expect(
        setup.customFor(PedalButton.track1, bank: 0).press,
        const CommandAction(ControlCommand.stop),
      );
      expect(
        setup.customFor(PedalButton.track1, bank: 1).press,
        const CommandAction(ControlCommand.undo),
      );
    });

    testWidgets('MODE and BANK cannot be selected for a custom assignment', (
      tester,
    ) async {
      await pump(tester);
      await openCustom(tester);
      await tester.tap(
        find.byKey(const Key('pedal_setup_cap_mode')),
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<AppText>(find.byKey(const Key('pedal_setup_selected')))
            .data,
        'Track 1',
      );
    });
  });

  group('Clear custom assignments', () {
    testWidgets('is offered only when something is assigned, clears both '
        'banks, and Restore brings them back', (tester) async {
      await pump(tester);
      await openCustom(tester);
      const clear = Key('pedal_setup_clear_custom');
      expect(
        tester.widget<LoopOutlinedButton>(find.byKey(clear)).onTap,
        isNull,
      );

      await choose(
        tester,
        field: press,
        group: 'transport',
        choice: 'command:stop',
      );
      await tester.tap(find.byKey(const Key('pedal_setup_cap_bank')));
      await tester.pumpAndSettle();
      await choose(
        tester,
        field: hold,
        group: 'transport',
        choice: 'command:undo',
      );

      await tester.tap(find.byKey(clear));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('pedal_setup_clear_dialog')), findsOneWidget);
      await tester.tap(find.byKey(const Key('pedal_setup_clear_confirm')));
      await tester.pumpAndSettle();

      // The draft is empty on BOTH banks and BOTH gestures.
      await tester.tap(find.byKey(save));
      await tester.pumpAndSettle();
      expect(control.state.pedalSetup.hasCustomAssignments, isFalse);
      // The fixed Track controls are untouched by it.
      expect(control.state.pedalSetup.modePress, InteractionMode.mute);
      expect(control.state.pedalSetup.trackHold, TrackHold.armOverdub);
    });

    testWidgets('Restore puts the cleared assignments back into the draft', (
      tester,
    ) async {
      await pump(tester);
      await openCustom(tester);
      await choose(
        tester,
        field: press,
        group: 'transport',
        choice: 'command:stop',
      );
      await tester.tap(find.byKey(const Key('pedal_setup_clear_custom')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('pedal_setup_clear_confirm')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('pedal_setup_restore_custom')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(save));
      await tester.pumpAndSettle();
      expect(
        control.state.pedalSetup.customFor(PedalButton.track1, bank: 0).press,
        const CommandAction(ControlCommand.stop),
      );
    });

    testWidgets('Cancel in the confirmation changes nothing', (tester) async {
      await pump(tester);
      await openCustom(tester);
      await choose(
        tester,
        field: press,
        group: 'transport',
        choice: 'command:stop',
      );
      await tester.tap(find.byKey(const Key('pedal_setup_clear_custom')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('pedal_setup_clear_cancel')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(save));
      await tester.pumpAndSettle();
      expect(control.state.pedalSetup.hasCustomAssignments, isTrue);
    });
  });

  group('the picker', () {
    testWidgets('backing out changes nothing — None is a choice, and a '
        'dismissal is not it', (tester) async {
      await pump(tester);
      await openCustom(tester);
      await choose(
        tester,
        field: press,
        group: 'transport',
        choice: 'command:stop',
      );
      await tester.tap(find.byKey(press));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('pedal_choice_close')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(save));
      await tester.pumpAndSettle();
      expect(
        control.state.pedalSetup.customFor(PedalButton.track1, bank: 0).press,
        const CommandAction(ControlCommand.stop),
      );
    });

    testWidgets('None clears the gesture', (tester) async {
      await pump(tester);
      await openCustom(tester);
      await choose(
        tester,
        field: press,
        group: 'transport',
        choice: 'command:stop',
      );
      await choose(tester, field: press, group: 'functions', choice: 'none');
      await tester.tap(find.byKey(save));
      await tester.pumpAndSettle();
      expect(control.state.pedalSetup.hasCustomAssignments, isFalse);
    });
  });
}
