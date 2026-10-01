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
import 'package:segno/theme/theme.dart';
import 'package:settings_repository/settings_repository.dart';

import '../helpers/fake_audio_engine.dart';
import '../helpers/fake_key_value_store.dart';

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
    control = ControlCubit(
      looper: looper,
      pedal: PedalRepository(NoopPedalLink()),
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
      // Current supported modes. Custom becomes the default
      // in its runtime slice.
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

  testWidgets('Custom editing is absent until Custom dispatch is available', (
    tester,
  ) async {
    await pump(tester);
    expect(find.byKey(const Key('pedal_setup_context_custom')), findsNothing);
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
