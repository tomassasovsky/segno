import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:controller_repository/controller_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:midi_device_repository/midi_device_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:performance_repository/performance_repository.dart';
import 'package:routing_graph/routing_graph.dart';
import 'package:segno/app/fx_chain_persistence.dart';
import 'package:segno/app/segno_navigator.dart';
import 'package:segno/audio_setup/cubit/midi_setup_cubit.dart';
import 'package:segno/control/binding/control_action.dart';
import 'package:segno/control/binding/control_value_target.dart';
import 'package:segno/control/binding/fx_binding_target.dart';
import 'package:segno/control/cubit/control_cubit.dart';
import 'package:segno/control/view/midi_controls/midi_controls_page.dart';
import 'package:segno/control/view/midi_controls/midi_segmented.dart';
import 'package:segno/control/view/pedal_setup/external_controls_editor.dart';
import 'package:segno/control/view/pedal_setup/pedal_choice_picker.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/cubit/settings_tray_cubit.dart';
import 'package:segno/looper/cubit/tracks_cubit.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/theme/theme.dart';
import 'package:settings_repository/settings_repository.dart';

import '../helpers/fake_audio_engine.dart';
import '../helpers/fake_key_value_store.dart';
import '../helpers/test_mix_settings.dart';

class _MockLooper extends Mock implements LooperRepository {}

class _MockMidiDevices extends Mock implements MidiDeviceRepository {}

class _Store extends FakeKeyValueStore {
  Completer<void>? gate;
  bool refuse = false;

  @override
  Future<void> setString(String key, String value) async {
    if (key == 'midi.configuration') {
      await gate?.future;
      if (refuse) throw const FileSystemException('disk full');
    }
    await super.setString(key, value);
  }
}

final _source = MidiSource(
  device: 'usb',
  kind: ControllerSourceKind.midiCc,
  number: 21,
  channel: 0,
);

MidiMapping _mapping() => MidiMapping(
  id: 'm1',
  source: _source,
  behavior: MidiBehavior.continuous,
  controls: [
    MidiParameterControl(
      key: const TrackVolumeTarget(0).canonicalString(),
      low: 0.2,
      high: 0.8,
    ),
  ],
);

const _connection = MidiConnection(
  devices: [MidiDevice(id: 'usb', name: 'USB controller')],
  selectedId: 'usb',
  selectedName: 'USB controller',
  status: MidiConnectionStatus.connected,
);

void main() {
  late _MockLooper looper;
  late _MockMidiDevices devices;
  late StreamController<LooperState> looperStates;
  late StreamController<MidiConnection> connections;
  late StreamController<MidiInputMessage> messages;
  late _Store store;
  late ControlCubit control;
  late SettingsTrayCubit tray;

  setUp(() {
    looper = _MockLooper();
    devices = _MockMidiDevices();
    looperStates = StreamController<LooperState>.broadcast();
    connections = StreamController<MidiConnection>.broadcast();
    messages = StreamController<MidiInputMessage>.broadcast();
    store = _Store();
    when(() => looper.looperState).thenAnswer((_) => looperStates.stream);
    when(() => looper.state).thenReturn(
      LooperState(
        tracks: [for (var i = 0; i < 8; i++) Track(channel: i)],
        status: const EngineStatus(sampleRate: 48000),
      ),
    );
    when(() => looper.sessionRevision).thenReturn(1);
    when(() => looper.trackEffects(any())).thenReturn(const []);
    when(() => looper.allTrackChains()).thenReturn(const {});
    when(() => looper.trackChainEnabled(any())).thenReturn(true);
    when(() => looper.setMasterGain(any())).thenReturn(EngineResult.ok);
    when(() => devices.connection).thenReturn(_connection);
    when(() => devices.session).thenReturn(const MidiInputSession('usb', 1));
    when(() => devices.connections).thenAnswer((_) => connections.stream);
    when(() => devices.messages).thenAnswer((_) => messages.stream);
    when(() => devices.activity).thenAnswer((_) => const Stream<void>.empty());
    when(() => devices.select(any())).thenAnswer((_) async {});
  });

  tearDown(() async {
    await looperStates.close();
    await connections.close();
    await messages.close();
  });

  Future<void> pump(
    WidgetTester tester, {
    bool seeded = false,
    bool malformed = false,
    bool routeEntry = false,
    MidiMapping? savedMapping,
  }) async {
    tester.view
      ..physicalSize = const Size(1920, 1080)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final settings = SettingsRepository(store: store);
    tray = SettingsTrayCubit(settings: settings);
    addTearDown(() => unawaited(tray.close()));
    if (malformed) {
      await store.setString('midi.configuration', '{bad json');
    }
    if (seeded || savedMapping != null) {
      await settings.saveMidiConfiguration(
        jsonEncode({
          'version': 1,
          'enabled': true,
          'mappings': [(savedMapping ?? _mapping()).toJson()],
        }),
      );
    }
    final performance = PerformanceRepository(
      engine: FakeAudioEngine(),
      exportsRoot: () async => '.',
    );
    addTearDown(performance.dispose);
    final pedal = PedalRepository(NoopPedalLink());
    addTearDown(() => unawaited(pedal.dispose()));
    final mix = testMixSettings(looper, settings: settings);
    addTearDown(() => unawaited(mix.close()));
    control = ControlCubit(
      looper: looper,
      pedal: pedal,
      settings: settings,
      performance: performance,
      mixSettings: mix,
      fxPersistence: FxChainPersistence(looper: looper),
      midiDevices: devices,
    );
    final tracks = TracksCubit(settings: settings);
    final midi = MidiSetupCubit(repository: devices);
    addTearDown(() => unawaited(control.close()));
    addTearDown(() => unawaited(tracks.close()));
    addTearDown(() => unawaited(midi.close()));
    await control.load();
    await tester.pumpWidget(
      RepositoryProvider<LooperRepository>.value(
        value: looper,
        child: MultiBlocProvider(
          providers: [
            BlocProvider.value(value: control),
            BlocProvider.value(value: tracks),
            BlocProvider.value(value: midi),
          ],
          child: MaterialApp(
            navigatorKey: routeEntry ? segnoNavigatorKey : null,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            theme: ThemeData(
              extensions: [
                SurfaceTheme.dark,
                routingGraphThemeFromSurface(SurfaceTheme.dark),
              ],
            ),
            home: routeEntry
                ? const Scaffold(body: Text('Stage root'))
                : const MidiControlsPage(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('Add chooses an explicit format before Learn begins', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.byKey(const Key('midi_add_mapping')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('midi_format_standard')), findsOneWidget);
    expect(control.state.midiEdit?.learn, isNull);
    await tester.tap(find.byKey(const Key('midi_format_standard')));
    await tester.pumpAndSettle();
    expect(control.state.midiEdit?.learn?.protocol, MidiProtocol.standard);
  });

  testWidgets('failed same-value Save keeps editor draft and warning', (
    tester,
  ) async {
    await pump(tester, seeded: true);
    await tester.tap(find.byKey(const Key('midi_row_edit_m1')));
    await tester.pumpAndSettle();
    store.refuse = true;
    await tester.tap(find.byKey(const Key('midi_save')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('midi_source_name')), findsOneWidget);
    expect(find.byKey(const Key('midi_editor_notice')), findsOneWidget);
    expect(control.state.midiMappings.byId('m1'), _mapping());
  });

  testWidgets('pending Save locks route and editing until receipt', (
    tester,
  ) async {
    await pump(tester, seeded: true);
    await tester.tap(find.byKey(const Key('midi_row_edit_m1')));
    await tester.pumpAndSettle();
    final gate = Completer<void>();
    store.gate = gate;
    await tester.tap(find.byKey(const Key('midi_save')));
    await tester.pump();
    expect(
      find.byWidgetPredicate((widget) => widget is PopScope && !widget.canPop),
      findsOneWidget,
    );
    expect(find.byType(AbsorbPointer), findsWidgets);
    gate.complete();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('midi_no_mappings')), findsNothing);
  });

  testWidgets('failed remote Off offers separate Retry Off and Resume On', (
    tester,
  ) async {
    await pump(tester);
    store.refuse = true;
    await tester.tap(find.byKey(const Key('midi_control_enabled')));
    await tester.pumpAndSettle();
    expect(control.state.midiControlEnabled, isTrue);
    expect(control.state.midiRemotePaused, isTrue);
    expect(find.byKey(const Key('midi_retry_off')), findsOneWidget);
    expect(find.byKey(const Key('midi_resume_on')), findsOneWidget);
    store.refuse = false;
    await tester.tap(find.byKey(const Key('midi_retry_off')));
    await tester.pumpAndSettle();
    expect(control.state.midiControlEnabled, isFalse);
    expect(control.state.midiRemotePaused, isTrue);
    expect(find.byKey(const Key('midi_retry_off')), findsNothing);
  });

  testWidgets('malformed saved payload needs deliberate confirmed reset', (
    tester,
  ) async {
    await pump(tester, malformed: true);
    expect(control.state.midiUnavailable, isTrue);
    expect(find.byKey(const Key('midi_add_mapping')), findsOneWidget);
    expect(find.byKey(const Key('midi_storage_notice')), findsNothing);
    expect(
      find.byKey(const Key('midi_configuration_unavailable')),
      findsOneWidget,
    );
    store.refuse = true;
    await tester.tap(find.byKey(const Key('midi_reset_configuration')));
    await tester.pumpAndSettle();
    expect(control.state.midiUnavailable, isTrue);
    expect(await store.getString('midi.configuration'), '{bad json');
    store.refuse = false;
    await tester.tap(find.byKey(const Key('midi_reset_configuration')));
    await tester.pumpAndSettle();
    expect(control.state.midiUnavailable, isFalse);
    expect(control.state.midiMappings.mappings, isEmpty);
    expect(find.byKey(const Key('midi_add_mapping')), findsOneWidget);
  });

  testWidgets('old route disposal cannot end a newer editor owner', (
    tester,
  ) async {
    await pump(tester, seeded: true);
    await tester.tap(find.byKey(const Key('midi_row_edit_m1')));
    await tester.pumpAndSettle();
    final newer = Object();
    control.beginMidiEdit(device: 'usb', owner: newer);
    await tester.pumpWidget(const SizedBox());
    expect(control.state.midiEdit?.owner, same(newer));
  });

  testWidgets('keyboard Enter opens the focused mapping row', (tester) async {
    await pump(tester, seeded: true);
    final row = find.byKey(const Key('midi_row_edit_m1'));
    Focus.of(tester.element(row)).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('midi_source_name')), findsOneWidget);
  });

  testWidgets('stale action picker result cannot retarget a newer owner', (
    tester,
  ) async {
    final missing = MidiMapping(
      id: 'm1',
      source: _source,
      behavior: MidiBehavior.momentary,
      controls: [
        MidiActionControl(key: 'retired:action', trigger: MidiEdge.release),
      ],
    );
    await pump(tester, savedMapping: missing);
    await tester.tap(find.byKey(const Key('midi_row_edit_m1')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('midi_control_change_retired:action')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const Key('midi_control_change_retired:action')),
    );
    await tester.pumpAndSettle();
    final newer = Object();
    control.beginMidiEdit(device: 'usb', owner: newer);
    Navigator.of(
      tester.element(find.byKey(const Key('pedal_choice_picker'))),
    ).pop(
      PedalChoiceResult<ControlAction?>(
        ControlAction.tryParse('command:undo'),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('midi_control_retired:action')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('midi_control_command:undo')), findsNothing);
  });

  testWidgets('repairing an unavailable action keeps its release edge', (
    tester,
  ) async {
    final missing = MidiMapping(
      id: 'm1',
      source: _source,
      behavior: MidiBehavior.momentary,
      controls: [
        MidiActionControl(key: 'retired:action', trigger: MidiEdge.release),
      ],
    );
    await pump(tester, savedMapping: missing);
    await tester.tap(find.byKey(const Key('midi_row_edit_m1')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('midi_control_change_retired:action')),
    );
    await tester.pumpAndSettle();
    Navigator.of(
      tester.element(find.byKey(const Key('pedal_choice_picker'))),
    ).pop(
      PedalChoiceResult<ControlAction?>(
        ControlAction.tryParse('command:undo'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('midi_control_command:undo')), findsOneWidget);
    expect(
      tester
          .widget<MidiSegmented<MidiEdge>>(
            find.byType(MidiSegmented<MidiEdge>),
          )
          .selected,
      MidiEdge.release,
    );
    await tester.tap(find.byKey(const Key('midi_save')));
    await tester.pumpAndSettle();
    final saved = control.state.midiMappings.byId('m1')!;
    expect((saved.controls.single as MidiActionControl).key, 'command:undo');
    expect(
      (saved.controls.single as MidiActionControl).trigger,
      MidiEdge.release,
    );
  });

  testWidgets('double tap resets both range endpoints in the draft only', (
    tester,
  ) async {
    await pump(tester, seeded: true);
    await tester.tap(find.byKey(const Key('midi_row_edit_m1')));
    await tester.pumpAndSettle();
    final key = const TrackVolumeTarget(0).canonicalString();
    final low = find.descendant(
      of: find.byKey(Key('midi_range_low_$key')),
      matching: find.byType(LoopSlider),
    );
    final high = find.descendant(
      of: find.byKey(Key('midi_range_high_$key')),
      matching: find.byType(LoopSlider),
    );
    await tester.tap(low);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(low);
    await tester.pumpAndSettle();
    expect(tester.widget<LoopSlider>(low).value, 0);
    expect(
      (control.state.midiMappings.byId('m1')!.controls.single
              as MidiParameterControl)
          .low,
      0.2,
    );
    await tester.tap(high);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(high);
    await tester.pumpAndSettle();
    expect(tester.widget<LoopSlider>(high).value, 1);
    expect(
      (control.state.midiMappings.byId('m1')!.controls.single
              as MidiParameterControl)
          .high,
      0.8,
    );
    await tester.tap(find.byKey(const Key('midi_save')));
    await tester.pumpAndSettle();
    final saved =
        control.state.midiMappings.byId('m1')!.controls.single
            as MidiParameterControl;
    expect((saved.low, saved.high), (0, 1));
  });

  testWidgets('Escape and focus loss restore unfinished range preview', (
    tester,
  ) async {
    await pump(tester, seeded: true);
    await tester.tap(find.byKey(const Key('midi_row_edit_m1')));
    await tester.pumpAndSettle();
    final key = const TrackVolumeTarget(0).canonicalString();
    final low = find.descendant(
      of: find.byKey(Key('midi_range_low_$key')),
      matching: find.byType(LoopSlider),
    );
    final high = find.descendant(
      of: find.byKey(Key('midi_range_high_$key')),
      matching: find.byType(LoopSlider),
    );
    Focus.of(
      tester.element(
        find
            .descendant(
              of: low,
              matching: find.byType(GestureDetector),
            )
            .first,
      ),
    ).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(tester.widget<LoopSlider>(low).value, closeTo(0.21, 0.0001));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(tester.widget<LoopSlider>(low).value, 0.2);

    Focus.of(
      tester.element(
        find
            .descendant(
              of: high,
              matching: find.byType(GestureDetector),
            )
            .first,
      ),
    ).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(tester.widget<LoopSlider>(high).value, closeTo(0.79, 0.0001));
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    expect(tester.widget<LoopSlider>(high).value, 0.8);
    final confirmed =
        control.state.midiMappings.byId('m1')!.controls.single
            as MidiParameterControl;
    expect((confirmed.low, confirmed.high), (0.2, 0.8));
  });

  testWidgets('Settings entry Stage pops MIDI route and ends edit owner', (
    tester,
  ) async {
    await pump(tester, seeded: true, routeEntry: true);
    unawaited(openMidiControls());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('midi_row_edit_m1')));
    await tester.pumpAndSettle();
    expect(control.state.midiEdit, isNotNull);
    await tester.tap(find.byKey(const Key('loop_settings_stage')));
    await tester.pumpAndSettle();
    expect(find.text('Stage root'), findsOneWidget);
    expect(find.byKey(const Key('midi_controls_page')), findsNothing);
    expect(control.state.midiEdit, isNull);
  });

  testWidgets('Control tray entry Stage closes tray and MIDI route', (
    tester,
  ) async {
    await pump(tester, seeded: true, routeEntry: true);
    tray.open();
    expect(tray.state.dragProgress, 1);
    unawaited(openMidiControls(onStage: tray.closeTray));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('midi_row_edit_m1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('loop_settings_stage')));
    await tester.pumpAndSettle();
    expect(tray.state.dragProgress, 0);
    expect(find.text('Stage root'), findsOneWidget);
    expect(find.byKey(const Key('midi_controls_page')), findsNothing);
    expect(control.state.midiEdit, isNull);
  });

  testWidgets('activation endpoints are binary and remain a draft until Save', (
    tester,
  ) async {
    const activation = FxChainTarget(FxAddress(stage: FxStage.allTracks));
    when(() => looper.allTracksEffects).thenReturn(const []);
    when(() => looper.allTracksChainEnabled).thenReturn(true);
    final saved = MidiMapping(
      id: 'm1',
      source: _source,
      behavior: MidiBehavior.momentary,
      controls: [
        MidiParameterControl(
          key: activation.canonicalString(),
          low: 0,
          high: 1,
        ),
      ],
    );
    await pump(tester, savedMapping: saved);
    await tester.tap(find.byKey(const Key('midi_row_edit_m1')));
    await tester.pumpAndSettle();
    final key = activation.canonicalString();
    expect(find.byKey(Key('midi_range_low_$key')), findsNothing);
    await tester.tap(find.byKey(Key('midi_activation_low_${key}_true')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('midi_activation_high_${key}_false')));
    await tester.pumpAndSettle();
    expect(control.state.midiMappings.byId('m1'), saved);
    await tester.tap(find.byKey(const Key('midi_save')));
    await tester.pumpAndSettle();
    final persisted =
        control.state.midiMappings.byId('m1')!.controls.single
            as MidiParameterControl;
    expect(persisted.low, 1);
    expect(persisted.high, 0);
  });

  testWidgets('saved FX activation stays available and can be authored', (
    tester,
  ) async {
    const activation = FxChainTarget(FxAddress(stage: FxStage.allTracks));
    when(() => looper.allMonitors()).thenReturn(const {});
    when(() => looper.allLaneChains()).thenReturn(const {});
    when(() => looper.allTracksEffects).thenReturn(const []);
    when(() => looper.allTracksChainEnabled).thenReturn(true);
    final saved = MidiMapping(
      id: 'm1',
      source: _source,
      behavior: MidiBehavior.toggle,
      controls: [
        MidiParameterControl(
          key: activation.canonicalString(),
          low: 0,
          high: 1,
        ),
      ],
    );
    await pump(tester, savedMapping: saved);
    expect(find.byKey(const Key('midi_row_warning_m1')), findsNothing);
    await tester.tap(find.byKey(const Key('midi_row_edit_m1')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(Key('midi_control_${activation.canonicalString()}')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(Key('midi_control_remove_${activation.canonicalString()}')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('midi_add_control')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('expression_kind_recordedTrack')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('expression_destination_allTracks')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(Key('external_pick_${externalControlKey(activation)}')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(Key('external_pick_${externalControlKey(activation)}')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('midi_save')));
    await tester.pumpAndSettle();
    expect(
      (control.state.midiMappings.byId('m1')!.controls.single
              as MidiParameterControl)
          .key,
      activation.canonicalString(),
    );
  });
}
