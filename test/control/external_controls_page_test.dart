import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:performance_repository/performance_repository.dart';
import 'package:routing_graph/routing_graph.dart';
import 'package:segno/control/binding/external_controls.dart';
import 'package:segno/control/binding/external_pedal.dart';
import 'package:segno/control/control.dart';
import 'package:segno/control/view/pedal_setup/external_controls_editor.dart';
import 'package:segno/control/view/pedal_setup/external_pedal_page.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/cubit/tracks_cubit.dart';
import 'package:segno/theme/theme.dart';
import 'package:settings_repository/settings_repository.dart';

import '../helpers/fake_audio_engine.dart';
import '../helpers/fake_key_value_store.dart';
import '../pedal/helpers/fake_pedal_transport.dart';

class _MockLooperRepository extends Mock implements LooperRepository {}

/// A button's Controls panel: the effects and parameters it drives beside its
/// actions.
void main() {
  late _MockLooperRepository looper;
  late StreamController<LooperState> looperStates;
  late SettingsRepository settings;
  late ControlCubit control;

  const drive = FxSlotTarget(
    address: FxAddress(stage: FxStage.track),
    slotId: 'drive-1',
  );

  setUp(() {
    looper = _MockLooperRepository();
    looperStates = StreamController<LooperState>.broadcast();
    settings = SettingsRepository(store: FakeKeyValueStore());
    when(() => looper.looperState).thenAnswer((_) => looperStates.stream);
    when(() => looper.state).thenReturn(
      const LooperState(
        tracks: [Track(volume: 0.4), Track(channel: 1)],
        status: EngineStatus(sampleRate: 48000),
      ),
    );
    when(() => looper.masterGain).thenReturn(1);
    when(
      () => looper.allTrackChains(),
    ).thenReturn(const {0: FxChainEnvelope()});
    when(() => looper.trackEffects(0)).thenReturn([
      BuiltInEffect(type: TrackEffectType.drive, slotId: 'drive-1'),
    ]);
    when(() => looper.trackEffects(1)).thenReturn(const []);
    when(() => looper.monitorEffects(any())).thenReturn(const []);
    when(() => looper.laneEffects(any(), any())).thenReturn(const []);
    when(() => looper.outputEffects(any())).thenReturn(const []);
    when(() => looper.allTracksEffects).thenReturn(const []);
    when(() => looper.allMonitors()).thenReturn(const {});
    when(() => looper.allLaneChains()).thenReturn(const {});
    when(() => looper.trackChainEnabled(any())).thenReturn(true);
    when(() => looper.setMasterGain(any())).thenReturn(EngineResult.ok);
    when(
      () => looper.setVolume(any(), channel: any(named: 'channel')),
    ).thenReturn(EngineResult.ok);
  });

  tearDown(() async {
    await looperStates.close();
  });

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
    final pedal = PedalRepository(FakePedalTransport());
    addTearDown(() => unawaited(pedal.dispose()));
    control = ControlCubit(
      looper: looper,
      pedal: pedal,
      settings: settings,
      performance: performance,
      keepAliveInterval: Duration.zero,
    );
    final tracks = TracksCubit(settings: settings);
    // unawaited: awaiting a cubit close inside a testWidgets body deadlocks
    // on the binding's stream cancellation (flutter/flutter#139870).
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

  ExternalControls saved() => control.state.pedalSetup.external
      .forJack(ExternalJack.ctrl1)
      .single
      .controls;

  Future<void> openPicker(WidgetTester tester) async {
    await tap(tester, 'external_panel_controls');
    await tap(tester, 'external_add_control');
    await tap(tester, 'expression_kind_recordedTrack');
    await tap(tester, 'expression_destination_track:0');
  }

  testWidgets('the tab switches between actions and controls', (tester) async {
    await pump(tester);
    expect(find.byKey(const Key('external_press')), findsOneWidget);
    await tap(tester, 'external_panel_controls');
    expect(find.byKey(const Key('external_press')), findsNothing);
    expect(
      find.byKey(const Key('external_controls_empty')),
      findsOneWidget,
      reason: 'a button that drives nothing says so',
    );
    await tap(tester, 'external_panel_actions');
    expect(find.byKey(const Key('external_press')), findsOneWidget);
  });

  testWidgets('an effect is added through its destination, On', (
    tester,
  ) async {
    await pump(tester);
    await openPicker(tester);
    await tap(tester, 'external_pick_${externalControlKey(drive)}');
    await tap(tester, 'external_save');
    expect(
      saved().activations.single,
      const ExternalActivation(target: drive),
    );
  });

  testWidgets('its condition changes', (tester) async {
    await pump(
      tester,
      jack: const ExternalJackSetup(
        single: ExternalSwitchSetup(
          controls: ExternalControls(
            activations: [ExternalActivation(target: drive)],
          ),
        ),
      ),
    );
    await tap(tester, 'external_panel_controls');
    await tap(tester, 'external_condition_released');
    await tap(tester, 'external_save');
    expect(saved().activations.single.condition, ExternalCondition.released);
  });

  testWidgets('a latching switch refuses Held and Released', (tester) async {
    await pump(
      tester,
      jack: const ExternalJackSetup(
        single: ExternalSwitchSetup(
          hardware: ExternalSwitchHardware.latching,
          controls: ExternalControls(
            activations: [ExternalActivation(target: drive)],
          ),
        ),
      ),
    );
    await tap(tester, 'external_panel_controls');
    await tap(tester, 'external_condition_held');
    // Refused, so there is no edit to save: Save stays inert and the stored
    // condition is still On.
    await tap(tester, 'external_save');
    expect(saved().activations.single.condition, ExternalCondition.on);
    final note = tester.widget<Text>(
      find.descendant(
        of: find.byKey(const Key('external_condition_note')),
        matching: find.byType(Text),
      ),
    );
    expect(note.data, 'Held and Released need a momentary switch.');
  });

  testWidgets('a parameter starts at the value it has now, on both sides', (
    tester,
  ) async {
    await pump(tester);
    await openPicker(tester);
    // Track 1's fader, which the rig reports at 40%.
    await tap(
      tester,
      'external_pick_${externalControlKey(const TrackVolumeTarget(0))}',
    );
    await tap(tester, 'external_save');
    final parameter = saved().parameters.single;
    expect(parameter.active, 0.4);
    expect(parameter.inactive, 0.4);
    verifyNever(
      () => looper.setVolume(any(), channel: any(named: 'channel')),
    );
  });

  testWidgets('a control added past the bottom of the list is in view', (
    tester,
  ) async {
    await pump(
      tester,
      jack: const ExternalJackSetup(
        single: ExternalSwitchSetup(
          controls: ExternalControls(
            activations: [
              ExternalActivation(target: drive),
              ExternalActivation(
                target: FxChainTarget(FxAddress(stage: FxStage.track)),
              ),
              ExternalActivation(
                target: FxSlotTarget(
                  address: FxAddress(stage: FxStage.track),
                  slotId: 'gone-1',
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await openPicker(tester);
    await tap(
      tester,
      'external_pick_${externalControlKey(const TrackVolumeTarget(0))}',
    );
    // Its two values opened below a list that shrank to make room; the row
    // they belong to must not be left scrolled out of sight.
    expect(find.byKey(const Key('external_value_active')), findsOne);
    expect(find.text('Volume').hitTestable(), findsOne);
  });

  testWidgets('moving a value edits the mapping and writes nothing', (
    tester,
  ) async {
    await pump(
      tester,
      jack: const ExternalJackSetup(
        single: ExternalSwitchSetup(
          controls: ExternalControls(
            parameters: [
              ExternalParameter(
                target: TrackVolumeTarget(0),
                active: 0.4,
                inactive: 0.4,
              ),
            ],
          ),
        ),
      ),
    );
    await tap(tester, 'external_panel_controls');
    final slider = find.byKey(const Key('external_value_active'));
    await tester.tapAt(tester.getCenter(slider));
    await tester.pumpAndSettle();
    await tap(tester, 'external_save');
    expect(saved().parameters.single.active, closeTo(0.5, 0.02));
    verifyNever(
      () => looper.setVolume(any(), channel: any(named: 'channel')),
    );
  });

  testWidgets('removing a control drops it', (tester) async {
    await pump(
      tester,
      jack: const ExternalJackSetup(
        single: ExternalSwitchSetup(
          controls: ExternalControls(
            activations: [ExternalActivation(target: drive)],
          ),
        ),
      ),
    );
    await tap(tester, 'external_panel_controls');
    await tap(tester, 'external_remove_control');
    await tap(tester, 'external_save');
    expect(saved().isEmpty, isTrue);
  });

  testWidgets('an effect the rig has lost keeps its row and says so', (
    tester,
  ) async {
    await pump(
      tester,
      jack: const ExternalJackSetup(
        single: ExternalSwitchSetup(
          controls: ExternalControls(
            activations: [
              ExternalActivation(
                target: FxSlotTarget(
                  address: FxAddress(stage: FxStage.track),
                  slotId: 'vanished',
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tap(tester, 'external_panel_controls');
    expect(find.text('Unavailable'), findsOneWidget);
  });

  testWidgets('opening the other jack closes the picker', (tester) async {
    await pump(tester);
    await openPicker(tester);
    expect(find.byKey(const Key('external_pick_title')), findsOne);
    await tap(tester, 'external_jack_ctrl2');
    expect(
      find.byKey(const Key('external_pick_title')),
      findsNothing,
      reason: 'a control chosen for a button on CTRL 1 is not for CTRL 2',
    );
  });

  testWidgets('Cancel in the picker adds nothing', (tester) async {
    await pump(tester);
    await openPicker(tester);
    await tap(tester, 'external_pick_cancel');
    expect(find.byKey(const Key('external_controls_empty')), findsOneWidget);
    expect(
      find.byKey(const Key('external_cancel')),
      findsOneWidget,
    );
  });

  testWidgets('Back steps out of the picker before leaving', (tester) async {
    await pump(tester);
    await openPicker(tester);
    // From one destination's controls, Back returns to the destinations...
    await tap(tester, 'loop_settings_back');
    expect(find.byKey(const Key('expression_kind_recordedTrack')), findsOne);
    // ...then out of the picker, still on the page and its draft.
    await tap(tester, 'loop_settings_back');
    expect(find.byKey(const Key('external_add_control')), findsOne);
    expect(find.byKey(const Key('external_pedal_page')), findsOne);
  });
}
