import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:midi_device_repository/midi_device_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:performance_repository/performance_repository.dart';
import 'package:routing_graph/routing_graph.dart';
import 'package:segno/app/fx_chain_persistence.dart';
import 'package:segno/audio_setup/cubit/midi_setup_cubit.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/control/control.dart';
import 'package:segno/control/control_tab.dart';
import 'package:segno/control/view/control_tray_panel.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/cubit/settings_tray_cubit.dart';
import 'package:segno/looper/cubit/tracks_cubit.dart';
import 'package:segno/pedal/cubit/pedal_cubit.dart';
import 'package:segno/theme/theme.dart';
import 'package:settings_repository/settings_repository.dart';

import '../helpers/fake_audio_engine.dart';
import '../helpers/fake_click_mode_control.dart';
import '../helpers/fake_click_volume_control.dart';
import '../helpers/fake_decay_control.dart';
import '../helpers/fake_key_value_store.dart';
import '../helpers/fake_one_shot_control.dart';
import '../helpers/fake_record_length_control.dart';
import '../helpers/fake_record_timing_control.dart';
import '../helpers/test_mix_settings.dart';

class _MockLooperRepository extends Mock implements LooperRepository {}

class _MockMidiDevices extends Mock implements MidiDeviceRepository {}

TrackEffect _fx(String slotId, TrackEffectType type) =>
    BuiltInEffect(type: type, slotId: slotId);

/// The Master chain, which every rig has — the one target that is always
/// offerable, so a test never depends on a configured stage existing.
const _master = FxAddress(stage: FxStage.output);

void main() {
  late _MockLooperRepository looper;
  late TracksCubit tracks;
  late StreamController<LooperState> looperStates;
  late _MockMidiDevices midiDevices;
  late StreamController<MidiConnection> connections;
  late StreamController<void> activity;
  late ControlCubit control;
  late PedalRepository pedal;
  late MidiSetupCubit midi;
  late SettingsTrayCubit tray;
  late SettingsRepository settings;
  late List<TrackEffect> masterChain;

  setUp(() {
    tracks = TracksCubit(
      settings: SettingsRepository(store: FakeKeyValueStore()),
    );
    looper = _MockLooperRepository();
    when(() => looper.sessionRevision).thenReturn(0);
    when(() => looper.mixGeneration).thenReturn(0);
    when(() => looper.inputSetup).thenReturn(const InputSetup.empty());
    when(() => looper.laneCount(any())).thenReturn(1);
    looperStates = StreamController<LooperState>.broadcast();
    masterChain = [
      _fx('slot-drive', TrackEffectType.drive),
      _fx('slot-reverb', TrackEffectType.reverb),
    ];
    when(() => looper.looperState).thenAnswer((_) => looperStates.stream);
    when(() => looper.state).thenReturn(
      LooperState(
        tracks: [for (var i = 0; i < 8; i++) Track(channel: i)],
        outputBusCount: 1,
        status: const EngineStatus(sampleRate: 48000),
      ),
    );
    when(() => looper.allMonitors()).thenReturn(const {});
    when(() => looper.allLaneChains()).thenReturn(const {});
    when(() => looper.allTrackChains()).thenReturn(const {});
    when(() => looper.trackEffects(any())).thenReturn(const []);
    when(() => looper.outputEffects(0)).thenAnswer((_) => masterChain);
    when(() => looper.allTracksEffects).thenReturn(const []);
    when(() => looper.outputChainEnabled(any())).thenReturn(true);
    when(() => looper.allTracksChainEnabled).thenReturn(true);
    when(
      () => looper.outputChainEnvelope(0),
    ).thenReturn(const FxChainEnvelope());
    when(() => looper.outputChainEnabled(any())).thenReturn(true);
    when(() => looper.setMasterGain(any())).thenReturn(EngineResult.ok);

    midiDevices = _MockMidiDevices();
    connections = StreamController<MidiConnection>.broadcast();
    activity = StreamController<void>.broadcast();
    when(() => midiDevices.connections).thenAnswer((_) => connections.stream);
    when(() => midiDevices.messages).thenAnswer((_) => const Stream.empty());
    when(() => midiDevices.activity).thenAnswer((_) => activity.stream);
    when(() => midiDevices.connection).thenReturn(const MidiConnection());
    when(() => midiDevices.select(any())).thenAnswer((_) async {});
  });

  tearDown(() async {
    await looperStates.close();
    await connections.close();
    await activity.close();
  });

  /// Mounts the Control face with the providers the real tray inherits.
  Future<void> pump(
    WidgetTester tester, {
    MidiConnection connection = const MidiConnection(),
    Size size = const Size(1600, 1400),
    PedalLink? pedalLink,
    SettingsRepository? pedalSettings,
    Locale? locale,
  }) async {
    tester.view
      ..physicalSize = size
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    when(() => midiDevices.connection).thenReturn(connection);

    settings = SettingsRepository(store: FakeKeyValueStore());
    final performance = PerformanceRepository(
      engine: FakeAudioEngine(),
      exportsRoot: () async => '.',
    );
    addTearDown(performance.dispose);
    pedal = PedalRepository(pedalLink ?? NoopPedalLink());
    addTearDown(pedal.dispose);
    final mixSettings = testMixSettings(looper, settings: settings);
    addTearDown(() => unawaited(mixSettings.close()));
    control = ControlCubit(
      decayControl: FakeDecayControl(),
      oneShotControl: FakeOneShotControl(),
      recordLengthControl: FakeRecordLengthControl(),
      recordTimingControl: FakeRecordTimingControl(),
      clickVolumeControl: FakeClickVolumeControl(),
      clickModeControl: FakeClickModeControl(),
      fxPersistence: FxChainPersistence(looper: looper),
      looper: looper,
      mixSettings: mixSettings,
      pedal: pedal,
      settings: settings,
      performance: performance,
      midiDevices: midiDevices,
    );
    midi = MidiSetupCubit(repository: midiDevices);
    tray = SettingsTrayCubit(settings: settings);
    // unawaited: awaiting a cubit close inside a testWidgets body deadlocks on
    // the binding's stream cancellation (flutter/flutter#139870).
    addTearDown(() => unawaited(control.close()));
    addTearDown(() => unawaited(midi.close()));
    addTearDown(() => unawaited(tray.close()));

    await tester.pumpWidget(
      MaterialApp(
        locale: locale,
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
              BlocProvider.value(value: midi),
              BlocProvider.value(value: tray),
              BlocProvider.value(value: tracks),
              // The tray asks the link whether a CTRL pedal could deliver: a
              // rig with no MIDI is still bindable from the console.
              BlocProvider(
                create: (_) => PedalCubit(
                  pedal: pedal,
                ),
              ),
            ],
            child: const Scaffold(
              body: Padding(
                padding: EdgeInsets.all(19),
                child: ControlTrayPanel(),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  AppLocalizations l10nOf(WidgetTester tester) =>
      AppLocalizations.of(tester.element(find.byType(ControlTrayPanel)));

  Future<void> showMidi(WidgetTester tester) async {
    tray.showControlTab(ControlTab.controllers);
    await tester.pumpAndSettle();
  }

  group('Control face', () {
    testWidgets('the tab strip swaps the body', (tester) async {
      await pump(tester);
      expect(find.byKey(const Key('pedal_tray_body')), findsOneWidget);
      expect(find.byKey(const Key('controllers_tray_body')), findsNothing);

      await tester.tap(find.text(l10nOf(tester).controlControllersTab));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('pedal_tray_body')), findsNothing);
      expect(find.byKey(const Key('controllers_tray_body')), findsOneWidget);
    });

    testWidgets('the domain names itself once, above the strip', (
      tester,
    ) async {
      await pump(tester);
      expect(find.text(l10nOf(tester).trayControlLabel), findsOneWidget);
    });
  });

  group('Pedal tab', () {
    testWidgets('draws four transport switches and four track switches', (
      tester,
    ) async {
      await pump(tester);
      for (final button in [
        PedalButton.recPlay,
        PedalButton.stop,
        PedalButton.undo,
        PedalButton.clear,
        PedalButton.track1,
        PedalButton.track2,
        PedalButton.track3,
        PedalButton.track4,
      ]) {
        expect(
          find.byKey(Key('pedal_switch_${button.name}')),
          findsOneWidget,
          reason: '${button.name} should be assignable',
        );
      }
    });

    testWidgets('offers MODE and Bank nowhere — they can never hold one', (
      tester,
    ) async {
      await pump(tester);
      expect(find.byKey(const Key('pedal_switch_mode')), findsNothing);
      expect(find.byKey(const Key('pedal_switch_bank')), findsNothing);
    });

    testWidgets('selecting a switch lists what it can drive', (tester) async {
      await pump(tester);
      final chain = const FxChainTarget(_master).canonicalString();
      expect(find.byKey(Key('pedal_target_$chain')), findsNothing);

      await tester.tap(find.byKey(const Key('pedal_switch_recPlay')));
      await tester.pumpAndSettle();

      expect(find.byKey(Key('pedal_target_$chain')), findsOneWidget);
    });

    testWidgets('chains come first; individual effects are one tap down', (
      tester,
    ) async {
      await pump(tester);
      await tester.tap(find.byKey(const Key('pedal_switch_recPlay')));
      await tester.pumpAndSettle();

      final slot = const FxSlotTarget(
        address: _master,
        slotId: 'slot-drive',
      ).canonicalString();
      expect(find.byKey(Key('pedal_target_$slot')), findsNothing);

      await tester.tap(find.byKey(const Key('pedal_show_effects')));
      await tester.pumpAndSettle();

      expect(find.byKey(Key('pedal_target_$slot')), findsOneWidget);
      expect(find.text('Drive'), findsOneWidget);
    });

    testWidgets('choosing a target assigns it, and choosing it again clears', (
      tester,
    ) async {
      await pump(tester);
      await tester.tap(find.byKey(const Key('pedal_switch_recPlay')));
      await tester.pumpAndSettle();

      final chain = const FxChainTarget(_master).canonicalString();
      await tester.tap(find.byKey(Key('pedal_target_$chain')));
      await tester.pumpAndSettle();

      const key = PedalBindingKey(button: PedalButton.recPlay);
      expect(
        control.state.globalBindings.bindings
            .where((b) => b.key == key)
            .map((b) => b.target),
        [chain],
      );
      // The check IS the row's on-state, so tapping it again turns it off.
      await tester.tap(find.byKey(Key('pedal_target_$chain')));
      await tester.pumpAndSettle();
      expect(
        control.state.globalBindings.bindings.where((b) => b.key == key),
        isEmpty,
      );
    });

    testWidgets('bank B stays put once picked, so its switches are usable', (
      tester,
    ) async {
      await pump(tester);
      await tester.tap(find.text('B'));
      await tester.pumpAndSettle();

      // Regression: selecting a switch used to re-seed the bank from the
      // pedal's own, which snapped the list back to A on the tap and left
      // bank B's four switches impossible to reach.
      await tester.tap(find.byKey(const Key('pedal_switch_track2')));
      await tester.pumpAndSettle();

      // Bank B's caps drive tracks 5-8 — that is what Bank is FOR — so the
      // second cap is Track 6 here, not a second Track 2.
      expect(
        find.text(l10nOf(tester).controlAssignGroup('TRACK 6', 'B')),
        findsOneWidget,
      );

      final chain = const FxChainTarget(_master).canonicalString();
      await tester.tap(find.byKey(Key('pedal_target_$chain')));
      await tester.pumpAndSettle();

      expect(
        control.state.globalBindings.bindings.single.key,
        const PedalBindingKey(button: PedalButton.track2, bank: 1),
      );
    });

    testWidgets('the track rows name the channel their bank drives', (
      tester,
    ) async {
      await pump(tester);
      final l10n = l10nOf(tester);
      for (var n = 1; n <= 4; n++) {
        expect(find.text(l10n.controlTrackSwitchName(n)), findsOneWidget);
      }
      expect(find.text(l10n.controlTrackSwitchName(5)), findsNothing);

      await tester.tap(find.text('B'));
      await tester.pumpAndSettle();

      for (var n = 5; n <= 8; n++) {
        expect(
          find.text(l10n.controlTrackSwitchName(n)),
          findsOneWidget,
          reason: 'bank B drives tracks 5-8, not a second copy of 1-4',
        );
      }
      expect(find.text(l10n.controlTrackSwitchName(1)), findsNothing);
    });

    testWidgets('a track switch holds a binding per bank', (tester) async {
      await pump(tester);
      await tester.tap(find.byKey(const Key('pedal_switch_track1')));
      await tester.pumpAndSettle();

      final chain = const FxChainTarget(_master).canonicalString();
      await tester.tap(find.byKey(Key('pedal_target_$chain')));
      await tester.pumpAndSettle();

      expect(
        control.state.globalBindings.bindings.single.key,
        const PedalBindingKey(button: PedalButton.track1, bank: 0),
      );

      // Bank B is a different key on the same cap, so its row reads back as
      // unassigned rather than inheriting bank A's binding.
      await tester.tap(find.text('B'));
      await tester.pumpAndSettle();
      expect(
        find.text(l10nOf(tester).controlUnassigned),
        findsWidgets,
      );
    });

    testWidgets('a binding whose target is gone takes the warning tone', (
      tester,
    ) async {
      await pump(tester);
      final gone = const FxSlotTarget(
        address: _master,
        slotId: 'slot-deleted',
      ).canonicalString();
      await control.setGlobalBindings(
        PedalBindingSet([
          PedalBinding(
            key: const PedalBindingKey(button: PedalButton.track1, bank: 0),
            target: gone,
          ),
        ]),
      );
      await tester.pumpAndSettle();

      final l10n = l10nOf(tester);
      final row = tester.widget<ConsoleRow>(
        find.byKey(const Key('pedal_switch_track1')),
      );
      expect(row.value, l10n.controlTargetMissing);
      expect(
        row.valueColor,
        SurfaceTheme.dark.warning,
        reason: 'a missing target is not the grey of "nobody asked it to"',
      );
    });

    testWidgets('the assign list animates open and holds while it closes', (
      tester,
    ) async {
      await pump(tester);
      final chain = const FxChainTarget(_master).canonicalString();

      await tester.tap(find.byKey(const Key('pedal_switch_recPlay')));
      // Three frames in, the strip is on screen but still growing — goldens
      // only ever photograph settled states, so the motion needs its own
      // assertion.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));
      // The strip itself is measured, not a row inside it: the row keeps its
      // own 70px whatever the clip is doing, so only the expansion's own box
      // reports the growth.
      final growing = tester.getSize(
        find.byKey(const Key('pedal_assign_slot')),
      );
      expect(find.byKey(Key('pedal_target_$chain')), findsOneWidget);
      await tester.pumpAndSettle();
      final settled = tester.getSize(
        find.byKey(const Key('pedal_assign_slot')),
      );
      expect(growing.height, lessThan(settled.height));

      await tester.tap(find.byKey(const Key('pedal_switch_recPlay')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));
      // Still drawn mid-close: the expansion holds the outgoing child, so the
      // list travels back up instead of the rows vanishing and a gap
      // collapsing behind them.
      expect(find.byKey(Key('pedal_target_$chain')), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.byKey(Key('pedal_target_$chain')), findsNothing);
    });
  });

  group('Controllers tab', () {
    testWidgets('offers the shared editor without a second mapping list', (
      tester,
    ) async {
      await pump(tester);
      await showMidi(tester);
      final l10n = l10nOf(tester);
      expect(find.byKey(const Key('midi_open_controls')), findsOneWidget);
      expect(find.text(l10n.midiControlsTitle), findsOneWidget);
      expect(find.text(l10n.midiControlsEntryDetail), findsOneWidget);
      expect(find.byKey(const Key('midi_add_sweep')), findsNothing);
      expect(find.byKey(const Key('midi_fixed_transport')), findsNothing);
    });
  });
}
