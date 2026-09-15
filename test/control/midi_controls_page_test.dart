import 'dart:async';
import 'dart:io';

import 'package:controller_repository/controller_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:midi_device_repository/midi_device_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:performance_repository/performance_repository.dart';
import 'package:routing_graph/routing_graph.dart';
import 'package:segno/app/segno_navigator.dart';
import 'package:segno/audio_setup/cubit/midi_setup_cubit.dart';
import 'package:segno/control/control.dart';
import 'package:segno/control/view/midi_controls/midi_controls_page.dart';
import 'package:segno/control/view/pedal_tray_body.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/cubit/tracks_cubit.dart';
import 'package:segno/looper/model/interaction_mode.dart';
import 'package:segno/theme/theme.dart';
import 'package:settings_repository/settings_repository.dart';

import '../helpers/fake_audio_engine.dart';
import '../helpers/fake_key_value_store.dart';

class _MockLooperRepository extends Mock implements LooperRepository {}

class _MockMidiDevices extends Mock implements MidiDeviceRepository {}

/// A settings store whose writes fail while [failing] is set, and wait for
/// [gate] while one is set.
class _FailingStore extends FakeKeyValueStore {
  bool failing = false;
  Completer<void>? gate;
  Completer<void>? boolGate;

  @override
  Future<void> setString(String key, String value) async {
    final pending = gate;
    if (pending != null) await pending.future;
    if (failing) throw const FileSystemException('disk full');
    return super.setString(key, value);
  }

  @override
  Future<void> setBool(String key, {required bool value}) async {
    final pending = boolGate;
    if (pending != null) await pending.future;
    if (failing) throw const FileSystemException('disk full');
    return super.setBool(key, value: value);
  }
}

const _usb = 'usb:controller';
const _din = 'din:in';

const _connected = MidiConnection(
  devices: [
    MidiDevice(id: _usb, name: 'USB controller'),
    MidiDevice(id: _din, name: 'MIDI In'),
  ],
  selectedId: _usb,
  selectedName: 'USB controller',
  status: MidiConnectionStatus.connected,
);

RawControllerInput _cc(int number, int value) => RawControllerInput(
  kind: ControllerSourceKind.midiCc,
  id: number,
  value: value,
);

MidiSource _source({
  int number = 21,
  ControllerSourceKind kind = ControllerSourceKind.midiCc,
  String device = _usb,
}) => MidiSource(device: device, kind: kind, number: number, channel: 0);

/// The accepted MIDI controls page: the list, the editor and its pickers.
void main() {
  late _MockLooperRepository looper;
  late StreamController<LooperState> looperStates;
  late StreamController<MidiConnection> connections;
  late StreamController<RawControllerInput> messages;
  late _MockMidiDevices devices;
  late _FailingStore store;
  late ControlCubit control;

  const volume = TrackVolumeTarget(0);
  const mix = FxParamTarget(
    address: FxAddress(stage: FxStage.track),
    slotId: 'reverb-1',
    param: 0,
  );
  const gone = FxParamTarget(
    address: FxAddress(stage: FxStage.track),
    slotId: 'gone-1',
    param: 0,
  );

  MidiMapping knob({
    String id = 'm1',
    MidiSource? source,
    ControlValueTarget target = volume,
    bool enabled = true,
  }) => MidiMapping(
    id: id,
    source: source ?? _source(),
    behavior: MidiBehavior.continuous,
    controls: [
      MidiParameterControl(key: target.canonicalString(), low: 0, high: 1),
    ],
    enabled: enabled,
  );

  setUp(() {
    resetSegnoNavigatorForTest();
    looper = _MockLooperRepository();
    looperStates = StreamController<LooperState>.broadcast();
    connections = StreamController<MidiConnection>.broadcast();
    messages = StreamController<RawControllerInput>.broadcast();
    devices = _MockMidiDevices();
    store = _FailingStore();
    when(() => devices.connections).thenAnswer((_) => connections.stream);
    when(() => devices.messages).thenAnswer((_) => messages.stream);
    when(
      () => devices.activity,
    ).thenAnswer((_) => const Stream<RawControllerInput>.empty());
    when(() => devices.select(any())).thenAnswer((_) async {});
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
    when(
      () => looper.allTrackChains(),
    ).thenReturn(const {0: FxChainEnvelope()});
    when(() => looper.trackEffects(0)).thenReturn([
      BuiltInEffect(
        type: TrackEffectType.reverb,
        slotId: 'reverb-1',
        module: 'Reverb',
      ),
    ]);
    when(() => looper.trackChainEnabled(any())).thenReturn(true);
    when(() => looper.masterGain).thenReturn(1);
    when(() => looper.setMasterGain(any())).thenReturn(EngineResult.ok);
    when(
      () => looper.setVolume(any(), channel: any(named: 'channel')),
    ).thenReturn(EngineResult.ok);
  });

  tearDown(() {
    // Not awaited: the page's subscriptions end when the tree is torn down,
    // after this, and a close awaited with a listener attached never
    // completes under the fake clock.
    unawaited(looperStates.close());
    unawaited(connections.close());
    unawaited(messages.close());
  });

  Future<void> pump(
    WidgetTester tester, {
    MidiConnection connection = _connected,
    List<MidiMapping> mappings = const [],
    Duration learnTimeout = const Duration(seconds: 15),
    Widget? home,
    bool open = true,
  }) async {
    tester.view
      ..physicalSize = const Size(1920, 1080)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    when(() => devices.connection).thenReturn(connection);

    final settings = SettingsRepository(store: store);
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
      midiDevices: devices,
      keepAliveInterval: Duration.zero,
      midiLearnTimeout: learnTimeout,
    );
    final tracks = TracksCubit(settings: settings);
    final midi = MidiSetupCubit(repository: devices);
    // unawaited: awaiting a cubit close inside a testWidgets body deadlocks
    // on the binding's stream cancellation (flutter/flutter#139870).
    addTearDown(() => unawaited(control.close()));
    addTearDown(() => unawaited(tracks.close()));
    addTearDown(() => unawaited(midi.close()));
    await control.load();
    for (final mapping in mappings) {
      await control.saveMidiMapping(mapping);
    }
    connections.add(connection);

    // The providers sit above the app, as they do in the real one: the page
    // is pushed as a route of its own.
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<LooperRepository>.value(value: looper),
          RepositoryProvider<MidiDeviceRepository>.value(value: devices),
        ],
        child: MultiBlocProvider(
          providers: [
            BlocProvider.value(value: control),
            BlocProvider.value(value: tracks),
            BlocProvider.value(value: midi),
          ],
          child: MaterialApp(
            navigatorKey: segnoNavigatorKey,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            theme: ThemeData(
              extensions: [
                SurfaceTheme.dark,
                routingGraphThemeFromSurface(SurfaceTheme.dark),
              ],
            ),
            home:
                home ??
                Builder(
                  builder: (context) => Scaffold(
                    body: Center(
                      child: TextButton(
                        key: const Key('open'),
                        onPressed: () => unawaited(openMidiControls()),
                        child: const Text('open'),
                      ),
                    ),
                  ),
                ),
          ),
        ),
      ),
    );
    if (!open) {
      await tester.pumpAndSettle();
      return;
    }
    await tester.tap(find.byKey(const Key('open')));
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester, String key) async {
    await tester.tap(find.byKey(Key(key)));
    await tester.pumpAndSettle();
  }

  Future<void> send(WidgetTester tester, List<RawControllerInput> sent) async {
    sent.forEach(messages.add);
    await tester.pumpAndSettle();
  }

  String text(String key) {
    final keyed = find.byKey(Key(key));
    final widget = keyed.evaluate().single.widget;
    if (widget is AppText) return widget.data ?? '';
    return (find
                    .descendant(of: keyed, matching: find.byType(AppText))
                    .evaluate()
                    .first
                    .widget
                as AppText)
            .data ??
        '';
  }

  bool enabled(WidgetTester tester, String key) {
    final button = find.descendant(
      of: find.byKey(Key(key)),
      matching: find.byType(InkWell),
    );
    return tester.widget<InkWell>(button.first).onTap != null;
  }

  Future<void> addVolume(WidgetTester tester) async {
    await tap(tester, 'midi_add_control');
    await tap(tester, 'expression_kind_recordedTrack');
    await tap(tester, 'expression_destination_track:0');
    await tap(tester, 'expression_target_${volume.canonicalString()}');
  }

  group('the list', () {
    testWidgets('shows the mappings of the controller in use only', (
      tester,
    ) async {
      await pump(
        tester,
        mappings: [
          knob(),
          knob(
            id: 'm2',
            source: _source(device: _din),
          ),
        ],
      );
      expect(find.byKey(const Key('midi_row_m1')), findsOneWidget);
      expect(find.byKey(const Key('midi_row_m2')), findsNothing);
      expect(find.text('CC 21 · Ch 1'), findsOneWidget);
      expect(find.text('TRACK 1 · Volume'), findsOneWidget);
    });

    testWidgets('says when there are no mappings', (tester) async {
      await pump(tester);
      expect(find.byKey(const Key('midi_no_mappings')), findsOneWidget);
    });

    testWidgets('with no controller there are no cards and nothing to add', (
      tester,
    ) async {
      await pump(tester, connection: const MidiConnection());
      expect(find.byKey(const Key('midi_no_devices')), findsOneWidget);
      expect(enabled(tester, 'midi_add_mapping'), isFalse);
    });

    testWidgets('choosing a card makes that controller the one in use', (
      tester,
    ) async {
      await pump(tester);
      await tap(tester, 'midi_device_$_din');
      verify(() => devices.select(_din)).called(1);
    });

    testWidgets('an unplugged controller keeps its card and says so', (
      tester,
    ) async {
      await pump(
        tester,
        mappings: [knob()],
        connection: _connected.copyWith(
          devices: const [MidiDevice(id: _din, name: 'MIDI In')],
          status: MidiConnectionStatus.deviceGone,
        ),
      );
      expect(find.byKey(const Key('midi_device_$_usb')), findsOneWidget);
      expect(text('midi_row_warning_m1'), 'Disconnected');
      expect(
        find.byKey(const Key('midi_controller_disconnected')),
        findsOneWidget,
      );
    });

    testWidgets('a mapping whose parameter is gone says so', (tester) async {
      await pump(tester, mappings: [knob(target: gone)]);
      expect(text('midi_row_warning_m1'), 'Missing control');
    });

    testWidgets('the meter reads what the control last sent', (tester) async {
      await pump(tester, mappings: [knob()]);
      expect(find.bySemanticsLabel('Last received value 0'), findsOneWidget);
      await send(tester, [_cc(21, 127)]);
      expect(find.bySemanticsLabel('Last received value 127'), findsOneWidget);
    });

    testWidgets('the meter keeps its reading through a visit to the editor', (
      tester,
    ) async {
      await pump(tester, mappings: [knob()]);
      await send(tester, [_cc(21, 100)]);
      await tap(tester, 'midi_row_edit_m1');
      await tap(tester, 'midi_cancel');
      expect(find.bySemanticsLabel('Last received value 100'), findsOneWidget);
    });

    testWidgets('a controller that goes away drops the half it sent', (
      tester,
    ) async {
      await pump(
        tester,
        mappings: [
          MidiMapping(
            id: 'm1',
            source: const MidiSource(
              device: _usb,
              kind: ControllerSourceKind.midiCc,
              number: 22,
              channel: 0,
              protocol: MidiProtocol.cc14,
            ),
            behavior: MidiBehavior.continuous,
            controls: [
              MidiParameterControl(
                key: volume.canonicalString(),
                low: 0,
                high: 1,
              ),
            ],
          ),
        ],
      );
      await send(tester, [_cc(22, 64)]);
      final gone = _connected.copyWith(status: MidiConnectionStatus.deviceGone);
      connections.add(gone);
      await tester.pumpAndSettle();
      connections.add(_connected);
      await tester.pumpAndSettle();
      await send(tester, [_cc(54, 1)]);
      expect(find.bySemanticsLabel('Last received value 0'), findsOneWidget);
    });

    testWidgets('a screen reader can press every control on the page', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await pump(tester, mappings: [knob()]);
      for (final label in [
        'USB controller',
        'CC 21 · Ch 1',
        'Disable CC 21 · Ch 1',
      ]) {
        final node = tester.getSemantics(find.bySemanticsLabel(label));
        expect(
          node.getSemanticsData().hasAction(SemanticsAction.tap),
          isTrue,
          reason: label,
        );
      }
      await tap(tester, 'midi_row_edit_m1');
      final segment = tester.getSemantics(
        find.bySemanticsLabel('Knob / fader'),
      );
      expect(
        segment.getSemanticsData().hasAction(SemanticsAction.tap),
        isTrue,
      );
      semantics.dispose();
    });

    testWidgets('the power button turns a mapping off and on', (tester) async {
      await pump(tester, mappings: [knob()]);
      await tap(tester, 'midi_row_enable_m1');
      expect(control.state.midiMappings.byId('m1')?.enabled, isFalse);
      await tap(tester, 'midi_row_enable_m1');
      expect(control.state.midiMappings.byId('m1')?.enabled, isTrue);

      store.failing = true;
      await tap(tester, 'midi_row_enable_m1');
      expect(control.state.midiMappings.byId('m1')?.enabled, isTrue);
      expect(
        text('midi_notice'),
        'Could not save. Your changes are still here.',
      );
    });

    testWidgets('MIDI control pauses every mapping, and says so', (
      tester,
    ) async {
      await pump(tester);
      await tap(tester, 'midi_control_enabled');
      expect(control.state.midiControlEnabled, isFalse);
      expect(find.text('MIDI control Off'), findsOneWidget);
      expect(text('midi_notice'), 'MIDI controls paused');

      store.failing = true;
      await tap(tester, 'midi_control_enabled');
      expect(control.state.midiControlEnabled, isFalse);
      expect(text('midi_notice'), 'Could not save MIDI control setting');
    });
  });

  group('adding a mapping', () {
    testWidgets('listens at once, with the controller paused', (tester) async {
      await pump(tester);
      await tap(tester, 'midi_add_mapping');
      expect(control.state.midiEdit?.device, _usb);
      expect(control.state.midiEdit?.learn?.isListening, isTrue);
      expect(find.byKey(const Key('midi_listening')), findsOneWidget);
      expect(enabled(tester, 'midi_save'), isFalse);
    });

    testWidgets('learns a control, drives a parameter and saves', (
      tester,
    ) async {
      await pump(tester);
      await tap(tester, 'midi_add_mapping');
      await send(tester, [_cc(30, 64)]);
      expect(text('midi_source_name'), 'CC 30 · Ch 1');
      expect(text('midi_received'), 'Received 64 / 127');
      expect(enabled(tester, 'midi_save'), isFalse, reason: 'drives nothing');

      await addVolume(tester);
      expect(
        find.byKey(Key('midi_control_${volume.canonicalString()}')),
        findsOneWidget,
      );
      expect(enabled(tester, 'midi_save'), isTrue);

      await tap(tester, 'midi_save');
      final saved = control.state.midiMappings.byId('m1');
      expect(saved?.source.number, 30);
      expect(saved?.behavior, MidiBehavior.continuous);
      expect(saved?.controls.single.key, volume.canonicalString());
      expect(control.state.midiEdit, isNull, reason: 'the controller resumed');
      expect(text('midi_notice'), 'Saved');
      expect(find.byKey(const Key('midi_row_m1')), findsOneWidget);
    });

    testWidgets('a failed save keeps the draft open', (tester) async {
      await pump(tester);
      await tap(tester, 'midi_add_mapping');
      await send(tester, [_cc(30, 64)]);
      await addVolume(tester);
      store.failing = true;
      await tap(tester, 'midi_save');
      expect(control.state.midiMappings.mappings, isEmpty);
      expect(control.state.midiEdit, isNotNull);
      expect(
        text('midi_editor_notice'),
        'Could not save. Your changes are still here.',
      );
      expect(text('midi_source_name'), 'CC 30 · Ch 1');
    });

    testWidgets('Cancel discards the draft and resumes the controller', (
      tester,
    ) async {
      await pump(tester);
      await tap(tester, 'midi_add_mapping');
      await send(tester, [_cc(30, 64)]);
      await tap(tester, 'midi_cancel');
      expect(control.state.midiEdit, isNull);
      expect(control.state.midiMappings.mappings, isEmpty);
      expect(find.byKey(const Key('midi_no_mappings')), findsOneWidget);
    });

    testWidgets('a Learn that hears nothing says to try again', (
      tester,
    ) async {
      await pump(tester, learnTimeout: const Duration(seconds: 1));
      await tap(tester, 'midi_add_mapping');
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('midi_listening')), findsNothing);
      expect(
        text('midi_editor_notice'),
        'No message received. Try Learn again.',
      );
    });

    testWidgets('a Learn on an unplugged controller says to reconnect', (
      tester,
    ) async {
      await pump(tester, learnTimeout: const Duration(seconds: 1));
      await tap(tester, 'midi_add_mapping');
      final gone = _connected.copyWith(status: MidiConnectionStatus.deviceGone);
      when(() => devices.connection).thenReturn(gone);
      connections.add(gone);
      await tester.pumpAndSettle();
      expect(find.text('Reconnect controller'), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(
        text('midi_editor_notice'),
        'Reconnect the controller to continue.',
      );
      expect(enabled(tester, 'midi_learn'), isFalse);
    });

    testWidgets('Cancel Learn stops listening and keeps the editor', (
      tester,
    ) async {
      await pump(tester);
      await tap(tester, 'midi_add_mapping');
      await tap(tester, 'midi_cancel_learn');
      expect(control.state.midiEdit?.learn, isNull);
      expect(control.state.midiEdit?.device, _usb);
      expect(find.byKey(const Key('midi_learn')), findsOneWidget);
    });
  });

  group('a learned control that is already mapped', () {
    testWidgets('cannot be saved, and opens the one it overlaps', (
      tester,
    ) async {
      await pump(tester, mappings: [knob()]);
      await tap(tester, 'midi_add_mapping');
      await send(tester, [_cc(21, 64)]);
      await addVolume(tester);
      expect(find.byKey(const Key('midi_conflict')), findsOneWidget);
      expect(enabled(tester, 'midi_save'), isFalse);

      await tap(tester, 'midi_edit_existing');
      expect(text('midi_source_name'), 'CC 21 · Ch 1');
      expect(find.byKey(const Key('midi_delete')), findsOneWidget);
      expect(
        find.byKey(Key('midi_control_${volume.canonicalString()}')),
        findsOneWidget,
        reason: 'the saved mapping, with its own controls',
      );
      expect(find.byKey(const Key('midi_conflict')), findsNothing);
      expect(find.byKey(const Key('midi_received')), findsNothing);
    });

    testWidgets('moving it to another channel clears the overlap', (
      tester,
    ) async {
      await pump(tester, mappings: [knob()]);
      await tap(tester, 'midi_add_mapping');
      await send(tester, [_cc(21, 64)]);
      await addVolume(tester);
      await tap(tester, 'midi_channel');
      await tap(tester, 'midi_channel_omni');
      expect(text('midi_source_name'), 'CC 21 · Omni');
      expect(find.byKey(const Key('midi_conflict')), findsOneWidget);

      await tap(tester, 'midi_channel');
      await tap(tester, 'midi_channel_3');
      expect(text('midi_source_name'), 'CC 21 · Ch 4');
      expect(find.byKey(const Key('midi_conflict')), findsNothing);
      expect(enabled(tester, 'midi_save'), isTrue);
    });
  });

  group('editing a saved mapping', () {
    testWidgets('opens it with the controller paused', (tester) async {
      await pump(tester, mappings: [knob()]);
      await tap(tester, 'midi_row_edit_m1');
      expect(control.state.midiEdit?.device, _usb);
      expect(control.state.midiEdit?.learn, isNull);
      expect(text('midi_source_name'), 'CC 21 · Ch 1');
      expect(enabled(tester, 'midi_save'), isTrue);
    });

    testWidgets('Save waits while Learn listens for another control', (
      tester,
    ) async {
      await pump(tester, mappings: [knob()]);
      await tap(tester, 'midi_row_edit_m1');
      expect(enabled(tester, 'midi_save'), isTrue);
      await tap(tester, 'midi_learn');
      expect(enabled(tester, 'midi_save'), isFalse);
      await send(tester, [_cc(40, 10)]);
      expect(text('midi_source_name'), 'CC 40 · Ch 1');
      expect(enabled(tester, 'midi_save'), isTrue);
    });

    testWidgets('Delete removes it', (tester) async {
      await pump(tester, mappings: [knob()]);
      await tap(tester, 'midi_row_edit_m1');
      await tap(tester, 'midi_delete');
      expect(control.state.midiMappings.mappings, isEmpty);
      expect(control.state.midiEdit, isNull);
      expect(text('midi_notice'), 'Mapping removed');
    });

    testWidgets('a failed Delete keeps the mapping and the editor', (
      tester,
    ) async {
      await pump(tester, mappings: [knob()]);
      await tap(tester, 'midi_row_edit_m1');
      store.failing = true;
      await tap(tester, 'midi_delete');
      expect(control.state.midiMappings.byId('m1'), isNotNull);
      expect(find.byKey(const Key('midi_delete')), findsOneWidget);
      expect(
        text('midi_editor_notice'),
        'Could not save. Your changes are still here.',
      );
    });

    testWidgets('a range edit is saved with it', (tester) async {
      await pump(tester, mappings: [knob()]);
      await tap(tester, 'midi_row_edit_m1');
      final key = volume.canonicalString();
      final slider = find.descendant(
        of: find.byKey(Key('midi_range_high_$key')),
        matching: find.byType(GestureDetector),
      );
      await tester.tapAt(tester.getTopLeft(slider.first) + const Offset(1, 20));
      await tester.pumpAndSettle();
      await tap(tester, 'midi_save');
      final control0 =
          control.state.midiMappings.byId('m1')!.controls.single
              as MidiParameterControl;
      expect(control0.high, lessThan(0.05));
    });

    testWidgets('a knob that drives an action stays a button', (tester) async {
      await pump(tester, mappings: [knob()]);
      await tap(tester, 'midi_row_edit_m1');
      await tap(tester, 'midi_add_control');
      await tap(tester, 'midi_performance_actions');
      final mute = const ModeAction(InteractionMode.mute).key;
      final tab = find.byKey(const Key('pedal_choice_group_functions'));
      if (tab.evaluate().isNotEmpty) {
        await tester.tap(tab);
        await tester.pumpAndSettle();
      }
      await tap(tester, 'pedal_choice_$mute');
      expect(find.byKey(Key('midi_control_$mute')), findsOneWidget);
      expect(
        find.byKey(const Key('midi_behavior_momentary')),
        findsOneWidget,
        reason: 'only a button offers Momentary or Toggle',
      );

      await tap(tester, 'midi_knob_true');
      expect(text('midi_editor_notice'), 'Actions need a button.');
      await tap(tester, 'midi_format');
      await tap(tester, 'midi_format_cc14');
      expect(
        text('midi_editor_notice'),
        'Remove action targets before learning a high-resolution or relative '
        'control.',
      );
      expect(control.state.midiEdit?.learn, isNull);
    });

    testWidgets('a high-resolution control offers no actions', (tester) async {
      await pump(tester, mappings: [knob()]);
      await tap(tester, 'midi_row_edit_m1');
      await tap(tester, 'midi_format');
      await tap(tester, 'midi_format_nrpn');
      expect(control.state.midiEdit?.learn?.protocol, MidiProtocol.nrpn);
      await send(tester, [_cc(99, 2), _cc(98, 3), _cc(6, 64), _cc(38, 7)]);
      expect(text('midi_source_name'), 'NRPN 259 · Ch 1');
      await tap(tester, 'midi_add_control');
      expect(enabled(tester, 'midi_performance_actions'), isFalse);
      expect(find.text('Performance actions · use a button'), findsOneWidget);
    });

    testWidgets('Repair control repoints a parameter in place, and says '
        'Save keeps it', (tester) async {
      await pump(
        tester,
        mappings: [
          MidiMapping(
            id: 'm1',
            source: _source(),
            behavior: MidiBehavior.continuous,
            controls: [
              MidiParameterControl(
                key: gone.canonicalString(),
                low: 0.2,
                high: 0.8,
              ),
              MidiParameterControl(
                key: volume.canonicalString(),
                low: 0,
                high: 1,
              ),
            ],
          ),
        ],
      );
      await tap(tester, 'midi_row_edit_m1');
      final key = gone.canonicalString();
      expect(find.text('Repair control'), findsOneWidget);
      await tap(tester, 'midi_control_change_$key');
      expect(find.byKey(const Key('midi_performance_actions')), findsNothing);
      await tap(tester, 'expression_kind_recordedTrack');
      await tap(tester, 'expression_destination_track:0');
      await tap(tester, 'expression_target_${mix.canonicalString()}');
      expect(text('midi_editor_notice'), 'Repair ready · Save to keep');
      await tap(tester, 'midi_save');
      final controls = control.state.midiMappings.byId('m1')!.controls;
      final first = controls.first as MidiParameterControl;
      expect(
        (first.key, first.low, first.high),
        (mix.canonicalString(), 0.2, 0.8),
        reason: 'the same place and the same range',
      );
      expect(controls.last.key, volume.canonicalString());
    });

    testWidgets('a failed Save of an edited mapping keeps the edit', (
      tester,
    ) async {
      await pump(tester, mappings: [knob()]);
      await tap(tester, 'midi_row_edit_m1');
      await tap(tester, 'midi_channel');
      await tap(tester, 'midi_channel_3');
      store.failing = true;
      await tap(tester, 'midi_save');
      expect(control.state.midiMappings.byId('m1')?.source.channel, 0);
      expect(text('midi_source_name'), 'CC 21 · Ch 4');
      expect(
        text('midi_editor_notice'),
        'Could not save. Your changes are still here.',
      );
    });

    testWidgets('Button chosen again leaves a Toggle a Toggle', (tester) async {
      await pump(
        tester,
        mappings: [
          MidiMapping(
            id: 'm1',
            source: _source(),
            behavior: MidiBehavior.toggle,
            controls: [
              MidiParameterControl(
                key: volume.canonicalString(),
                low: 0,
                high: 1,
              ),
            ],
          ),
        ],
      );
      await tap(tester, 'midi_row_edit_m1');
      await tap(tester, 'midi_knob_false');
      await tap(tester, 'midi_save');
      expect(
        control.state.midiMappings.byId('m1')?.behavior,
        MidiBehavior.toggle,
      );
    });

    testWidgets('no path learns a relative control for a mapping with '
        'actions', (tester) async {
      await pump(tester, mappings: [knob()]);
      await tap(tester, 'midi_row_edit_m1');
      await tap(tester, 'midi_format');
      await tap(tester, 'midi_format_relative');
      await tap(tester, 'midi_cancel_learn');
      // The control is still a plain CC, so an action can be added...
      await tap(tester, 'midi_add_control');
      await tap(tester, 'midi_performance_actions');
      await tap(tester, 'pedal_choice_none');
      expect(find.text('Mapping'), findsOneWidget, reason: 'None ends it');
      await tap(tester, 'midi_add_control');
      await tap(tester, 'midi_performance_actions');
      final mute = const ModeAction(InteractionMode.mute).key;
      final tab = find.byKey(const Key('pedal_choice_group_functions'));
      if (tab.evaluate().isNotEmpty) {
        await tester.tap(tab);
        await tester.pumpAndSettle();
      }
      await tap(tester, 'pedal_choice_$mute');
      // ...and Learn another control, still set to Relative, is refused.
      await tap(tester, 'midi_learn');
      expect(control.state.midiEdit?.learn, isNull);
      expect(
        text('midi_editor_notice'),
        'Remove action targets before learning a high-resolution or relative '
        'control.',
      );
    });

    testWidgets('choosing what to add stops Learn, and keeps what it heard', (
      tester,
    ) async {
      await pump(tester);
      await tap(tester, 'midi_add_mapping');
      await tap(tester, 'midi_add_control');
      expect(control.state.midiEdit?.learn, isNull);
      await send(tester, [_cc(22, 64)]);
      await tap(tester, 'loop_settings_back');
      expect(text('midi_source_name'), 'No control selected');

      await tap(tester, 'midi_learn');
      await send(tester, [_cc(23, 90)]);
      await tap(tester, 'midi_add_control');
      await tap(tester, 'loop_settings_back');
      expect(text('midi_received'), 'Received 90 / 127');
    });

    testWidgets('a Delete or a MIDI control switch that lands after the '
        'editor moved on leaves the new editor alone', (tester) async {
      await pump(tester, mappings: [knob()]);
      await tap(tester, 'midi_row_edit_m1');
      var gate = store.gate = Completer<void>();
      await tester.tap(find.byKey(const Key('midi_delete')));
      await tester.pump();
      await tap(tester, 'midi_cancel');
      await tap(tester, 'midi_add_mapping');
      gate.complete();
      store.gate = null;
      await tester.pumpAndSettle();
      expect(control.state.midiMappings.byId('m1'), isNull);
      expect(control.state.midiEdit?.learn?.isListening, isTrue);
      expect(find.byKey(const Key('midi_editor_notice')), findsNothing);

      await tap(tester, 'midi_cancel');
      store.boolGate = gate = Completer<void>();
      await tester.tap(find.byKey(const Key('midi_control_enabled')));
      await tester.pump();
      await tap(tester, 'midi_add_mapping');
      gate.complete();
      store.boolGate = null;
      await tester.pumpAndSettle();
      expect(control.state.midiControlEnabled, isFalse);
      expect(find.byKey(const Key('midi_editor_notice')), findsNothing);
    });

    testWidgets('a Save that lands after the editor moved on leaves the new '
        'editor alone', (tester) async {
      await pump(tester, mappings: [knob()]);
      await tap(tester, 'midi_row_edit_m1');
      await tap(tester, 'midi_channel');
      await tap(tester, 'midi_channel_3');
      final gate = store.gate = Completer<void>();
      await tester.tap(find.byKey(const Key('midi_save')));
      await tester.pump();
      await tap(tester, 'midi_cancel');
      await tap(tester, 'midi_add_mapping');
      gate.complete();
      store.gate = null;
      await tester.pumpAndSettle();
      expect(control.state.midiMappings.byId('m1')?.source.channel, 3);
      expect(text('midi_source_name'), 'No control selected');
      expect(control.state.midiEdit?.learn?.isListening, isTrue);
    });

    testWidgets('removing its last control leaves nothing to save', (
      tester,
    ) async {
      await pump(tester, mappings: [knob()]);
      await tap(tester, 'midi_row_edit_m1');
      await tap(tester, 'midi_control_remove_${volume.canonicalString()}');
      expect(find.byKey(const Key('midi_controls_empty')), findsOneWidget);
      expect(enabled(tester, 'midi_save'), isFalse);
    });
  });

  group('leaving', () {
    testWidgets('the Control face row opens it', (tester) async {
      await pump(
        tester,
        open: false,
        home: const Scaffold(body: PedalTrayBody()),
      );
      await tap(tester, 'control_open_midi');
      expect(find.byType(MidiControlsPage), findsOneWidget);
    });

    testWidgets('opening it again while it is open stacks nothing', (
      tester,
    ) async {
      await pump(tester);
      unawaited(openMidiControls());
      await tester.pumpAndSettle();
      expect(find.byType(MidiControlsPage), findsOneWidget);
      await tap(tester, 'loop_settings_back');
      expect(find.byType(MidiControlsPage), findsNothing);
      unawaited(openMidiControls());
      await tester.pumpAndSettle();
      expect(find.byType(MidiControlsPage), findsOneWidget);
    });

    testWidgets('Back steps out of each picker before the editor', (
      tester,
    ) async {
      await pump(tester, mappings: [knob()]);
      await tap(tester, 'midi_row_edit_m1');
      await tap(tester, 'midi_add_control');
      await tap(tester, 'expression_kind_recordedTrack');
      await tap(tester, 'expression_destination_track:0');
      await tap(tester, 'loop_settings_back');
      expect(find.text('Choose a destination'), findsOneWidget);
      await tap(tester, 'loop_settings_back');
      expect(find.text('Mapping'), findsOneWidget);
      await tap(tester, 'loop_settings_back');
      expect(find.text('MIDI controls'), findsOneWidget);
      expect(control.state.midiEdit, isNull);
      await tap(tester, 'loop_settings_back');
      expect(find.byType(MidiControlsPage), findsNothing);
    });

    testWidgets('leaving the page with the editor open resumes the '
        'controller', (tester) async {
      await pump(tester, mappings: [knob()]);
      await tap(tester, 'midi_row_edit_m1');
      expect(control.state.midiEdit, isNotNull);
      await tap(tester, 'loop_settings_stage');
      expect(find.byType(MidiControlsPage), findsNothing);
      expect(control.state.midiEdit, isNull);
    });
  });
}
