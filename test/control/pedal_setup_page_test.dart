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
import 'package:segno/control/view/pedal_setup/pedal_setup_map.dart';
import 'package:segno/control/view/pedal_setup/pedal_setup_page.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/cubit/tracks_cubit.dart';
import 'package:segno/looper/model/interaction_mode.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/pedal/cubit/pedal_cubit.dart';
import 'package:segno/theme/theme.dart';
import 'package:settings_repository/settings_repository.dart';

import '../helpers/fake_audio_engine.dart';
import '../helpers/fake_key_value_store.dart';
import '../helpers/test_mix_settings.dart';

class _MockLooperRepository extends Mock implements LooperRepository {}

class _ControlledStore extends FakeKeyValueStore {
  Completer<void>? pending;
  bool refuse = false;
  bool failRestore = false;
  int failedWrites = 0;
  Completer<void>? loading;

  @override
  Future<String?> getString(String key) async {
    if (key == 'pedal.setup') await loading?.future;
    return super.getString(key);
  }

  @override
  Future<void> setString(String key, String value) async {
    if (key == 'pedal.setup') {
      if (failRestore) {
        if (failedWrites++ == 0) await super.setString(key, value);
        throw StateError('storage refuses checkpoint restore');
      }
      await pending?.future;
      if (refuse) throw Exception('storage unavailable');
    }
    await super.setString(key, value);
  }
}

/// Track setup keeps changes local until storage confirms Save.
void main() {
  late _MockLooperRepository looper;
  late StreamController<LooperState> looperStates;
  late SettingsRepository settings;
  late _ControlledStore store;
  late ControlCubit control;
  late TracksCubit tracks;
  late PedalRepository pedal;

  setUp(() {
    looper = _MockLooperRepository();
    looperStates = StreamController<LooperState>.broadcast();
    store = _ControlledStore();
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

  Future<void> pump(
    WidgetTester tester, {
    bool preload = true,
    VoidCallback? onStage,
  }) async {
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
    pedal = PedalRepository(NoopPedalLink());
    final pedalCubit = PedalCubit(pedal: pedal);
    addTearDown(() => unawaited(pedalCubit.close()));
    control = ControlCubit(
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
    if (preload) await control.load();

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
              BlocProvider.value(value: pedalCubit),
              BlocProvider.value(value: tracks),
            ],
            child: PedalSetupPage(onStage: onStage),
          ),
        ),
      ),
    );
    if (preload) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
    }
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
      // The accepted default keeps short Mute and held Custom separate.
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

  Future<void> openCustom(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('pedal_setup_context_custom')));
    await tester.pumpAndSettle();
  }

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
    testWidgets(
      'is offered only when something is assigned and clears both banks',
      (tester) async {
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

        await tester.tap(find.byKey(save));
        await tester.pumpAndSettle();
        expect(control.state.pedalSetup.custom, hasLength(2));

        await tester.tap(find.byKey(clear));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('pedal_setup_clear_dialog')),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const Key('pedal_setup_clear_confirm')));
        await tester.pumpAndSettle();
        expect(control.state.pedalSetup.custom, hasLength(2));

        // Only Save publishes the cleared draft across both banks.
        await tester.tap(find.byKey(save));
        await tester.pumpAndSettle();
        expect(control.state.pedalSetup.hasCustomAssignments, isFalse);
        // The fixed Track controls are untouched by it.
        expect(control.state.pedalSetup.modePress, InteractionMode.mute);
        expect(control.state.pedalSetup.trackHold, TrackHold.armOverdub);
      },
    );

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

    testWidgets('Restore Custom preserves later Track controls edits', (
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
      await tester.tap(find.byKey(const Key('pedal_setup_context_tracks')));
      await tester.pumpAndSettle();
      await choose(tester, field: press, group: 'modes', choice: 'mode_fx');
      await openCustom(tester);
      await tester.tap(find.byKey(const Key('pedal_setup_restore_custom')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(save));
      await tester.pumpAndSettle();

      expect(control.state.pedalSetup.modePress, InteractionMode.fx);
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
      await tester.tap(find.byKey(save));
      await tester.pumpAndSettle();
      expect(control.state.pedalSetup.hasCustomAssignments, isTrue);
      await choose(tester, field: press, group: 'functions', choice: 'none');
      expect(control.state.pedalSetup.hasCustomAssignments, isTrue);
      await tester.tap(find.byKey(save));
      await tester.pumpAndSettle();
      expect(control.state.pedalSetup.hasCustomAssignments, isFalse);
    });
  });

  testWidgets('map follows published LEDs independently of edit selection', (
    tester,
  ) async {
    await pump(tester);
    final colors = List<PedalColor>.filled(10, const PedalColor(40, 160, 220));
    for (final button in PedalButton.values) {
      pedal.pushState(
        PedalStateFrame.blank().copyWith(
          pedalColors: colors,
          activeButtonMask: 1 << button.index,
        ),
      );
      await tester.pumpAndSettle();
      for (final other in PedalButton.values) {
        final cap = tester.widget<PedalSetupCap>(
          find.byKey(Key('pedal_setup_cap_${other.name}')),
        );
        expect(
          cap.ledActive,
          other == button,
          reason: '${button.name} -> ${other.name}',
        );
        expect(cap.ledColor, colors[other.index]);
      }
    }
    // Editing another pedal does not publish a command or light its LED.
    await tester.tap(find.byKey(const Key('pedal_setup_cap_track2')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<PedalSetupCap>(
            find.byKey(const Key('pedal_setup_cap_track2')),
          )
          .ledActive,
      isFalse,
    );
    expect(
      tester
          .widget<PedalSetupCap>(
            find.byKey(const Key('pedal_setup_cap_track2')),
          )
          .selected,
      isTrue,
    );

    await tester.tap(find.byKey(const Key('pedal_setup_context_custom')));
    await tester.pumpAndSettle();
    pedal.pushState(PedalStateFrame.blank().copyWith(activeButtonMask: 0x3ff));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('pedal_setup_cap_bank')));
    await tester.pumpAndSettle();
    for (var i = 1; i <= 4; i++) {
      expect(
        tester
            .widget<PedalSetupCap>(
              find.byKey(Key('pedal_setup_cap_track$i')),
            )
            .ledActive,
        isFalse,
        reason: 'Draft bank B is not live bank A',
      );
    }
    expect(
      tester
          .widget<PedalSetupCap>(
            find.byKey(const Key('pedal_setup_cap_stop')),
          )
          .ledActive,
      isTrue,
    );
    pedal.goodbye();
    await tester.pumpAndSettle();
    for (final button in PedalButton.values) {
      expect(
        tester
            .widget<PedalSetupCap>(
              find.byKey(Key('pedal_setup_cap_${button.name}')),
            )
            .ledActive,
        isFalse,
      );
    }
  });

  testWidgets('one track selects all four hardware pedals', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const Key('pedal_setup_cap_track2')));
    await tester.pumpAndSettle();
    for (var i = 1; i <= 4; i++) {
      expect(
        tester
            .widget<PedalSetupCap>(find.byKey(Key('pedal_setup_cap_track$i')))
            .selected,
        isTrue,
      );
    }
  });

  testWidgets('the raised Bank cap accepts taps near its upper edge', (
    tester,
  ) async {
    var pages = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          extensions: [
            SurfaceTheme.dark,
            routingGraphThemeFromSurface(SurfaceTheme.dark),
          ],
        ),
        home: Scaffold(
          body: FittedBox(
            child: PedalSetupMap(
              frame: null,
              selected: const {},
              editable: const {},
              onSelect: (_) {},
              bank: 0,
              bankSelectable: true,
              onToggleBank: () => pages++,
            ),
          ),
        ),
      ),
    );
    final cap = find.byKey(const Key('pedal_setup_cap_bank'));
    final rect = tester.getRect(cap);
    await tester.tapAt(Offset(rect.center.dx, rect.top + 8));
    await tester.pump();
    expect(pages, 1);
  });

  testWidgets(
    'desktop picker attaches its visible scrollbar',
    (tester) async {
      await pump(tester);
      await tester.tap(find.byKey(hold));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('pedal_choice_picker')), findsOneWidget);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets('Stage closes the calling tray without saving the draft', (
    tester,
  ) async {
    var trayOpen = true;
    await pump(tester, onStage: () => trayOpen = false);
    await choose(tester, field: press, group: 'modes', choice: 'mode_fx');
    await tester.tap(find.byKey(const Key('loop_settings_stage')));
    await tester.pumpAndSettle();
    expect(trayOpen, isFalse);
    expect(control.state.pedalSetup.modePress, InteractionMode.mute);
    expect(await settings.loadPedalSetup(), isNull);
  });

  testWidgets('startup waits for the saved setup before the first edit', (
    tester,
  ) async {
    store.values['pedal.setup'] = const PedalSetup()
        .copyWith(
          recordHold: RecordHold.none,
          trackHold: TrackHold.clearTrack,
        )
        .encode();
    store.loading = Completer<void>();
    await pump(tester, preload: false);
    expect(find.byKey(press), findsNothing);
    expect(find.byKey(save), findsNothing);
    store.loading!.complete();
    await tester.pumpAndSettle();
    await choose(tester, field: press, group: 'modes', choice: 'mode_fx');
    await tester.tap(find.byKey(save));
    await tester.pumpAndSettle();
    expect(control.state.pedalSetup.modePress, InteractionMode.fx);
    expect(control.state.pedalSetup.recordHold, RecordHold.none);
    expect(control.state.pedalSetup.trackHold, TrackHold.clearTrack);
    final stored = PedalSetup.decode((await settings.loadPedalSetup())!);
    expect(stored.recordHold, RecordHold.none);
    expect(stored.trackHold, TrackHold.clearTrack);
  });

  testWidgets('Save waits for storage and prevents duplicate editing', (
    tester,
  ) async {
    await pump(tester);
    await choose(tester, field: press, group: 'modes', choice: 'mode_fx');
    store.pending = Completer<void>();
    await tester.tap(find.byKey(save));
    await tester.pump();
    expect(control.state.pedalSetup.modePress, InteractionMode.mute);
    expect(find.byKey(const Key('pedal_setup_saved')), findsNothing);
    expect(tester.widget<LoopOutlinedButton>(find.byKey(save)).onTap, isNull);
    expect(tester.widget<LoopOutlinedButton>(find.byKey(cancel)).onTap, isNull);
    await tester.tap(
      find.byKey(const Key('pedal_setup_cap_track1')),
      warnIfMissed: false,
    );
    await tester.pump();
    expect(
      tester
          .widget<AppText>(find.byKey(const Key('pedal_setup_selected')))
          .data,
      'MODE',
    );
    store.pending!.complete();
    await tester.pumpAndSettle();
    expect(control.state.pedalSetup.modePress, InteractionMode.fx);
    expect(find.byKey(const Key('pedal_setup_saved')), findsOneWidget);
  });

  testWidgets('uncertain saved setup survives Cancel and can be confirmed', (
    tester,
  ) async {
    store.values['pedal.setup'] = const PedalSetup().encode();
    await pump(tester);
    await choose(tester, field: press, group: 'modes', choice: 'mode_fx');
    store.failRestore = true;
    await tester.tap(find.byKey(save));
    await tester.pumpAndSettle();
    expect(control.state.pedalSetup.modePress, InteractionMode.mute);
    expect(find.byKey(const Key('pedal_setup_save_uncertain')), findsOneWidget);
    await tester.tap(find.byKey(cancel));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('pedal_setup_save_uncertain')), findsOneWidget);
    expect(
      tester.widget<LoopOutlinedButton>(find.byKey(save)).onTap,
      isNotNull,
    );
    store.failRestore = false;
    await tester.tap(find.byKey(save));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('pedal_setup_save_uncertain')), findsNothing);
    expect(find.byKey(const Key('pedal_setup_saved')), findsOneWidget);
    expect(
      PedalSetup.decode((await settings.loadPedalSetup())!).modePress,
      InteractionMode.mute,
    );
  });

  testWidgets(
    'unreadable assignments need a deliberate confirmed replacement',
    (
      tester,
    ) async {
      const damaged = '{"trackHold":"unknown-hold"}';
      store.values['pedal.setup'] = damaged;
      await pump(tester);
      expect(control.state.pedalSetupUnavailable, isTrue);
      expect(find.byKey(const Key('pedal_setup_unavailable')), findsOneWidget);
      expect(await settings.loadPedalSetup(), damaged);

      await choose(tester, field: press, group: 'modes', choice: 'mode_fx');
      await tester.tap(find.byKey(cancel));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('pedal_setup_unavailable')), findsOneWidget);
      expect(await settings.loadPedalSetup(), damaged);
      expect(
        tester.widget<LoopOutlinedButton>(find.byKey(save)).onTap,
        isNotNull,
      );

      store.refuse = true;
      await tester.tap(find.byKey(save));
      await tester.pumpAndSettle();
      expect(control.state.pedalSetupUnavailable, isTrue);
      expect(await settings.loadPedalSetup(), damaged);
      expect(find.byKey(const Key('pedal_setup_unavailable')), findsOneWidget);
      expect(find.byKey(const Key('pedal_setup_saved')), findsNothing);

      store.refuse = false;
      await tester.tap(find.byKey(save));
      await tester.pumpAndSettle();
      expect(control.state.pedalSetupUnavailable, isFalse);
      expect(find.byKey(const Key('pedal_setup_unavailable')), findsNothing);
      expect(find.byKey(const Key('pedal_setup_saved')), findsOneWidget);
      expect(await settings.loadPedalSetup(), const PedalSetup().encode());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Custom recovery warning leaves header actions reachable', (
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
    await tester.tap(find.byKey(save));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('pedal_setup_clear_custom')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('pedal_setup_clear_confirm')));
    await tester.pumpAndSettle();
    store.failRestore = true;
    await tester.tap(find.byKey(save));
    await tester.pumpAndSettle();

    final warning = tester.getRect(
      find.byKey(const Key('pedal_setup_save_uncertain')),
    );
    final actions = [
      const Key('pedal_setup_clear_custom'),
      const Key('pedal_setup_restore_custom'),
      cancel,
      save,
    ];
    for (final key in actions) {
      final button = find.byKey(key);
      final rect = tester.getRect(button);
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.right, lessThanOrEqualTo(1920));
      expect(rect.bottom, lessThan(warning.top));
      expect(button.hitTestable(), findsOneWidget);
    }
    for (final button in PedalButton.values) {
      final cap = find.byKey(Key('pedal_setup_cap_${button.name}'));
      if (cap.evaluate().isNotEmpty) {
        expect(warning.overlaps(tester.getRect(cap)), isFalse);
      }
    }
    expect(tester.takeException(), isNull);
    expect(control.state.pedalSetup.hasCustomAssignments, isTrue);

    store.failRestore = false;
    await tester.tap(find.byKey(const Key('pedal_setup_restore_custom')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(save));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('pedal_setup_save_uncertain')), findsNothing);
    expect(control.state.pedalSetup.hasCustomAssignments, isTrue);
  });

  testWidgets('failed Save retains live setup and draft for retry', (
    tester,
  ) async {
    await pump(tester);
    await choose(tester, field: press, group: 'modes', choice: 'mode_fx');
    store.refuse = true;
    await tester.tap(find.byKey(save));
    await tester.pumpAndSettle();
    expect(control.state.pedalSetup.modePress, InteractionMode.mute);
    expect(await settings.loadPedalSetup(), isNull);
    expect(find.byKey(const Key('pedal_setup_saved')), findsNothing);
    expect(find.byKey(const Key('pedal_setup_save_failed')), findsOneWidget);
    expect(
      tester.widget<LoopOutlinedButton>(find.byKey(save)).onTap,
      isNotNull,
    );
    store.refuse = false;
    await tester.tap(find.byKey(save));
    await tester.pumpAndSettle();
    expect(control.state.pedalSetup.modePress, InteractionMode.fx);
    expect(find.byKey(const Key('pedal_setup_save_failed')), findsNothing);
    expect(find.byKey(const Key('pedal_setup_saved')), findsOneWidget);
  });
}
