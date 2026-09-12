import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:performance_repository/performance_repository.dart';
import 'package:routing_graph/routing_graph.dart';
import 'package:segno/control/binding/pedal_button_legend.dart';
import 'package:segno/control/binding/pedal_palette.dart';
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

  Future<void> openLeds(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('pedal_setup_context_leds')));
    await tester.pumpAndSettle();
  }

  Future<void> selectCap(WidgetTester tester, PedalButton button) async {
    await tester.tap(find.byKey(Key('pedal_setup_cap_${button.name}')));
    await tester.pumpAndSettle();
  }

  Future<void> pickSwatch(WidgetTester tester, String key) async {
    await tester.tap(find.byKey(Key('pedal_setup_swatch_$key')));
    await tester.pumpAndSettle();
  }

  /// What the map is drawing on [button]'s indicator.
  Color ledColor(WidgetTester tester, PedalButton button) {
    final box = tester.widget<DecoratedBox>(
      find.byKey(Key('pedal_setup_led_${button.name}')),
    );
    return (box.decoration as BoxDecoration).color!;
  }

  String? selectedName(WidgetTester tester) => tester
      .widget<AppText>(find.byKey(const Key('pedal_setup_selected')))
      .data;

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
      expect(find.text(l10n.actionModeCustom), findsOneWidget);
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
      expect(control.state.pedalSetup.modeHold, InteractionMode.custom);
      final l10n = AppLocalizations.of(
        tester.element(find.byType(PedalSetupPage)),
      );
      expect(find.text(l10n.actionModeCustom), findsOneWidget);
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
  group('LED colors', () {
    testWidgets('every switch has a colour here, including the ones whose '
        'action is fixed', (tester) async {
      await pump(tester);
      await openLeds(tester);
      for (final button in [
        PedalButton.stop,
        PedalButton.undo,
        PedalButton.clear,
        PedalButton.recPlay,
      ]) {
        await selectCap(tester, button);
        expect(
          selectedName(tester),
          pedalButtonLegend(button),
          reason: button.name,
        );
      }
    });

    testWidgets('BANK is a switch with a colour here, not the bank pager', (
      tester,
    ) async {
      await pump(tester);
      await openLeds(tester);
      await selectCap(tester, PedalButton.bank);
      expect(selectedName(tester), pedalButtonLegend(PedalButton.bank));
      // The track caps still name bank A's tracks: nothing paged.
      expect(find.text('TRACK 1'), findsOneWidget);
      expect(find.text('TRACK 5'), findsNothing);
    });

    testWidgets('the four track caps are each their own switch here', (
      tester,
    ) async {
      await pump(tester);
      await openLeds(tester);
      await selectCap(tester, PedalButton.track3);
      // Not the "Track pedals" group Track controls edits: a colour is per
      // switch.
      expect(selectedName(tester), 'Track 3');
    });

    testWidgets('a colour is a draft until Save, and persists with it', (
      tester,
    ) async {
      await pump(tester);
      await openLeds(tester);
      await pickSwatch(tester, 'blue');
      expect(
        control.state.pedalSetup.palette.colorFor(PedalButton.mode),
        PedalColor.white,
      );

      await tester.tap(find.byKey(save));
      await tester.pumpAndSettle();
      final palette = control.state.pedalSetup.palette;
      expect(palette.colorFor(PedalButton.mode), PedalColor.blue);
      // Only the switch that was selected.
      expect(palette.colorFor(PedalButton.track1), PedalColor.white);
      expect(
        await settings.loadPedalSetup(),
        control.state.pedalSetup.encode(),
      );
    });

    testWidgets('Cancel drops the colour', (tester) async {
      await pump(tester);
      await openLeds(tester);
      await pickSwatch(tester, 'red');
      await tester.tap(find.byKey(cancel));
      await tester.pumpAndSettle();
      expect(
        control.state.pedalSetup.palette.colorFor(PedalButton.mode),
        PedalColor.white,
      );
      expect(
        find.byKey(const Key('pedal_setup_swatch_custom:1')),
        findsNothing,
      );
    });

    testWidgets('Edit color is offered on a mixed colour and on none of the '
        'built-ins', (tester) async {
      await pump(tester);
      await openLeds(tester);
      const edit = Key('pedal_setup_led_edit');
      expect(find.byKey(edit), findsNothing);
      await pickSwatch(tester, 'violet');
      expect(find.byKey(edit), findsNothing);

      await pickSwatch(tester, 'add');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('pedal_color_done')));
      await tester.pumpAndSettle();
      expect(find.byKey(edit), findsOneWidget);
    });

    testWidgets('mixing a colour adds a swatch and puts it on the switch that '
        'asked for it', (tester) async {
      await pump(tester);
      await openLeds(tester);
      await pickSwatch(tester, 'add');
      expect(find.byKey(const Key('pedal_color_dialog')), findsOneWidget);
      // It opens mid-space rather than on white, so all three sliders move
      // something visible.
      expect(find.text('#82AAFF'), findsOneWidget);

      await tester.tap(find.byKey(const Key('pedal_color_done')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('pedal_setup_swatch_custom:1')),
        findsOneWidget,
      );
      expect(find.text('Custom 1'), findsOneWidget);

      await tester.tap(find.byKey(save));
      await tester.pumpAndSettle();
      expect(
        control.state.pedalSetup.palette.colorFor(PedalButton.mode),
        PedalColor.blue,
      );
    });

    testWidgets('the sliders drive the colour, and Cancel leaves the palette '
        'alone', (tester) async {
      await pump(tester);
      await openLeds(tester);
      await pickSwatch(tester, 'add');
      final rail = find.byKey(const Key('pedal_color_slider_brightness'));
      await tester.tapAt(tester.getTopLeft(rail) + const Offset(1, 32));
      await tester.pumpAndSettle();
      expect(find.text('0%'), findsOneWidget);
      // Brightness off is the LED off, whatever the hue says.
      expect(find.text('#000000'), findsOneWidget);

      await tester.tap(find.byKey(const Key('pedal_color_cancel')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('pedal_setup_swatch_custom:1')),
        findsNothing,
      );
      expect(
        tester
            .widget<LoopOutlinedButton>(
              find.byKey(
                const Key(
                  'pedal_setup_save',
                ),
              ),
            )
            .onTap,
        isNull,
      );
    });

    testWidgets('editing a mixed colour moves every switch using it', (
      tester,
    ) async {
      await pump(tester);
      await openLeds(tester);
      // Mix one and put it on MODE, then on CLEAR as well.
      await pickSwatch(tester, 'add');
      await tester.tap(find.byKey(const Key('pedal_color_done')));
      await tester.pumpAndSettle();
      await selectCap(tester, PedalButton.clear);
      await pickSwatch(tester, 'custom:1');
      await tester.tap(find.byKey(save));
      await tester.pumpAndSettle();
      var palette = control.state.pedalSetup.palette;
      expect(palette.colorFor(PedalButton.mode), PedalColor.blue);
      expect(palette.colorFor(PedalButton.clear), PedalColor.blue);

      await tester.tap(find.byKey(const Key('pedal_setup_led_edit')));
      await tester.pumpAndSettle();
      final rail = find.byKey(const Key('pedal_color_slider_saturation'));
      await tester.tapAt(tester.getTopLeft(rail) + const Offset(1, 32));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('pedal_color_done')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(save));
      await tester.pumpAndSettle();

      palette = control.state.pedalSetup.palette;
      // Saturation off is white at that brightness: both switches moved, and
      // neither assignment changed.
      expect(
        palette.colorFor(PedalButton.mode),
        const PedalColor(255, 255, 255),
      );
      expect(
        palette.colorFor(PedalButton.clear),
        palette.colorFor(PedalButton.mode),
      );
      expect(
        palette.entryFor(PedalButton.clear),
        const CustomPaletteEntry(1),
      );
    });

    testWidgets('the indicator is lit by the rig, never by the selection', (
      tester,
    ) async {
      await pump(tester);
      await openLeds(tester);
      await pickSwatch(tester, 'cyan');
      final off = ledColor(tester, PedalButton.stop);
      // MODE is the selected switch and the rig is in the normal mode: the
      // indicator stays dark, because a lit pill here would read as a saved
      // performance latch.
      expect(ledColor(tester, PedalButton.mode), off);

      control.setMode(InteractionMode.fx);
      await tester.pumpAndSettle();
      expect(
        ledColor(tester, PedalButton.mode),
        const Color(0xFF73CFDF),
        reason: 'the draft colour, lit by the mode the rig is in',
      );
    });

    testWidgets('Clear custom assignments keeps the colours', (tester) async {
      await pump(tester);
      await openLeds(tester);
      await pickSwatch(tester, 'green');
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
      await tester.tap(find.byKey(save));
      await tester.pumpAndSettle();

      expect(control.state.pedalSetup.hasCustomAssignments, isFalse);
      expect(
        control.state.pedalSetup.palette.colorFor(PedalButton.mode),
        PedalColor.green,
      );
    });

    testWidgets('Restore does not rewrite a colour picked after the clear', (
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

      // A colour chosen AFTER the clear must survive the recovery: the
      // recovery point is the assignments, not the whole draft.
      await openLeds(tester);
      await selectCap(tester, PedalButton.track2);
      await pickSwatch(tester, 'orange');
      await openCustom(tester);
      await tester.tap(find.byKey(const Key('pedal_setup_restore_custom')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(save));
      await tester.pumpAndSettle();

      final setup = control.state.pedalSetup;
      expect(
        setup.customFor(PedalButton.track1, bank: 0).press,
        const CommandAction(ControlCommand.stop),
      );
      expect(setup.palette.colorFor(PedalButton.track2), PedalColor.orange);
    });
  });
}
