import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:routing_graph/routing_graph.dart';
import 'package:segno/app/segno_navigator.dart';
import 'package:segno/audio_setup/cubit/inputs_cubit.dart';
import 'package:segno/audio_setup/cubit/monitor_cubit.dart';
import 'package:segno/audio_setup/cubit/outputs_cubit.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/cubit/tempo_cubit.dart';
import 'package:segno/looper/cubit/tracks_cubit.dart';
import 'package:segno/looper/view/audio_routing/audio_routing_page.dart';
import 'package:segno/looper/view/audio_routing/audio_routing_widgets.dart';
import 'package:segno/looper/view/audio_routing/input_setup_tab.dart';
import 'package:segno/looper/view/audio_routing/output_routing_tab.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/theme/theme.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../../helpers/helpers.dart';

class _MockLooperBloc extends MockBloc<LooperEvent, LooperState>
    implements LooperBloc {}

class _MockLooperRepository extends Mock implements LooperRepository {}

/// A four-in, four-out rig with nothing recorded: the state the Input setup
/// tab draws from.
const _rig = LooperState(
  tracks: [Track(), Track(channel: 1)],
  status: EngineStatus(
    deviceName: 'Fake Device',
    inputChannels: 4,
    outputChannels: 4,
  ),
  inputPeaks: [0, 0, 0, 0],
  // Two destinations: outputs 1-2 and outputs 3-4.
  outputBusCount: 2,
);

void main() {
  late _MockLooperBloc bloc;
  late _MockLooperRepository repository;
  late SettingsRepository settings;
  late StreamController<LooperState> states;
  late InputsCubit inputs;
  late TracksCubit tracks;
  late OutputsCubit outputs;
  late MonitorCubit monitors;
  late TempoCubit tempo;
  late StreamController<int> monitorChanges;
  late StreamController<int> monitorParams;

  setUpAll(() {
    registerFallbackValue(const LooperInputPanChanged(0, pan: 0));
    registerFallbackValue(MonitorMode.off);
  });

  setUp(() {
    bloc = _MockLooperBloc();
    repository = _MockLooperRepository();
    settings = SettingsRepository(store: FakeKeyValueStore());
    states = StreamController<LooperState>.broadcast();
    monitorChanges = StreamController<int>.broadcast();
    monitorParams = StreamController<int>.broadcast();
    addTearDown(monitorChanges.close);
    addTearDown(monitorParams.close);
    when(() => repository.looperState).thenAnswer((_) => states.stream);
    when(() => repository.state).thenReturn(_rig);
    when(() => repository.monitorChanges).thenAnswer(
      (_) => monitorChanges.stream,
    );
    when(() => repository.monitorParamChanges).thenAnswer(
      (_) => monitorParams.stream,
    );
    when(() => repository.allMonitors()).thenReturn(const {});
    when(
      () => repository.setMonitorOutput(
        input: any(named: 'input'),
        mask: any(named: 'mask'),
      ),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.setMonitorInputMode(
        input: any(named: 'input'),
        mode: any(named: 'mode'),
      ),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.setMonitorMute(
        input: any(named: 'input'),
        muted: any(named: 'muted'),
      ),
    ).thenReturn(EngineResult.ok);
    when(() => repository.setClickOutput(any())).thenReturn(EngineResult.ok);
  });

  tearDown(() => states.close());

  Future<void> pump(
    WidgetTester tester, {
    LooperState state = _rig,
    Widget home = const AudioRoutingPage(),
  }) async {
    tester.view
      ..physicalSize = const Size(1920, 1080)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    when(() => bloc.state).thenReturn(state);
    whenListen(bloc, states.stream, initialState: state);
    inputs = InputsCubit(repository: repository, settings: settings);
    addTearDown(() => unawaited(inputs.close()));
    tracks = TracksCubit(settings: settings);
    addTearDown(() => unawaited(tracks.close()));
    outputs = OutputsCubit(repository: repository, settings: settings);
    addTearDown(() => unawaited(outputs.close()));
    monitors = MonitorCubit(repository: repository, settings: settings);
    addTearDown(() => unawaited(monitors.close()));
    tempo = TempoCubit(repository: repository, settings: settings);
    addTearDown(() => unawaited(tempo.close()));
    // Providers ABOVE the app, so a route pushed onto the root navigator can
    // read them: the navigator builds its routes outside `home`'s subtree.
    await tester.pumpWidget(
      RepositoryProvider<LooperRepository>.value(
        value: repository,
        child: MultiBlocProvider(
          providers: [
            BlocProvider<LooperBloc>.value(value: bloc),
            BlocProvider.value(value: inputs),
            BlocProvider.value(value: tracks),
            BlocProvider.value(value: outputs),
            BlocProvider.value(value: monitors),
            BlocProvider.value(value: tempo),
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
            home: home,
          ),
        ),
      ),
    );
    await tester.pump();
  }

  /// Moves the projection on without rebuilding the page from scratch.
  Future<void> push(WidgetTester tester, LooperState state) async {
    when(() => bloc.state).thenReturn(state);
    states.add(state);
    // Two frames: the first delivers the stream event to the providers, the
    // second builds what the new value changed.
    await tester.pump();
    await tester.pump();
  }

  AppLocalizations l10nOf(WidgetTester tester) =>
      AppLocalizations.of(tester.element(find.byType(AudioRoutingPage)));

  testWidgets('opens on Input setup with one card per hardware input', (
    tester,
  ) async {
    await pump(tester);
    final l10n = l10nOf(tester);

    expect(find.text(l10n.routingTitle), findsOneWidget);
    expect(find.byKey(const Key('routing_tab_setup')), findsOneWidget);
    // Four inputs on the device, so four cards and no fifth.
    expect(find.byKey(const Key('routing_input_card_0')), findsOneWidget);
    expect(find.byKey(const Key('routing_input_card_3')), findsOneWidget);
    expect(find.byKey(const Key('routing_input_card_4')), findsNothing);
    expect(find.text(l10n.routingRecordAs), findsOneWidget);
    expect(find.text(l10n.routingPan), findsOneWidget);
    expect(find.text(l10n.routingTrim), findsOneWidget);
  });

  testWidgets('a mono input shows Pan; a linked pair shows Balance and its '
      'two ordered members', (tester) async {
    await pump(tester);
    final l10n = l10nOf(tester);
    expect(find.text(l10n.routingPan), findsOneWidget);
    expect(find.text(l10n.routingFormatMonoNote), findsOneWidget);

    await pump(
      tester,
      state: _rig.copyWithInputSetup(const InputSetup(pairs: {0: 0})),
    );
    expect(find.text(l10n.routingBalance), findsOneWidget);
    expect(find.text(l10n.routingPan), findsNothing);
    expect(find.text(l10n.routingPairLeft), findsOneWidget);
    expect(find.text(l10n.routingPairRight), findsOneWidget);
  });

  testWidgets('the placement slider commits once, as a pan or as a balance', (
    tester,
  ) async {
    await pump(tester);
    final slider = find.byKey(const Key('routing_placement_slider'));
    await tester.tapAt(tester.getTopLeft(slider) + const Offset(700, 20));
    await tester.pump();
    final captured = verify(
      () => bloc.add(captureAny(that: isA<LooperInputPanChanged>())),
    ).captured.cast<LooperInputPanChanged>();
    expect(captured, hasLength(1));
    expect(captured.single.input, 0);
    expect(captured.single.pan, greaterThan(0));
  });

  testWidgets('the trim slider commits in half-decibel steps', (tester) async {
    await pump(tester);
    final slider = find.byKey(const Key('routing_trim_slider'));
    await tester.tapAt(tester.getTopLeft(slider) + const Offset(400, 20));
    await tester.pump();
    final captured = verify(
      () => bloc.add(captureAny(that: isA<LooperInputTrimChanged>())),
    ).captured.cast<LooperInputTrimChanged>();
    expect(captured, hasLength(1));
    expect(captured.single.db % kInputTrimStepDb, 0);
    expect(captured.single.db, inInclusiveRange(kMinInputTrimDb, 0));
  });

  testWidgets('a track capturing this input locks the format and says why', (
    tester,
  ) async {
    await pump(
      tester,
      state: _rig.copyWithCapturing(),
    );
    final l10n = l10nOf(tester);
    expect(find.text(l10n.routingLockedFormat), findsOneWidget);
    await tester.tap(find.byKey(const Key('routing_format_stereo')));
    await tester.pump();
    verifyNever(
      () => bloc.add(any(that: isA<LooperInputPairChanged>())),
    );
  });

  testWidgets('a clipping input says so beside the trim note, and the meter '
      'reads CLIP', (tester) async {
    await pump(tester);
    final l10n = l10nOf(tester);
    expect(find.text(l10n.routingClipNote), findsNothing);
    expect(find.text(l10n.routingClip), findsNothing);
    expect(find.text(l10n.routingTrimNote), findsOneWidget);

    await push(tester, _rig.copyWithClip(0));
    // The clip is a line of its own: the trim note says what the control
    // below does, which is still true while the jack is clipping.
    expect(find.text(l10n.routingClipNote), findsOneWidget);
    expect(find.text(l10n.routingTrimNote), findsOneWidget);
    expect(find.text(l10n.routingClip), findsOneWidget);
  });

  testWidgets('the four tasks are pills and switching keeps the route', (
    tester,
  ) async {
    await pump(tester);
    final l10n = l10nOf(tester);
    for (final tab in AudioRoutingTab.values) {
      expect(find.byKey(Key('routing_tab_${tab.name}')), findsOneWidget);
    }
    await tester.tap(find.byKey(const Key('routing_tab_record')));
    await tester.pump();
    // The Input setup controls are gone, the frame and the title stay.
    expect(find.text(l10n.routingRecordAs), findsNothing);
    expect(find.text(l10n.routingTitle), findsOneWidget);
    expect(find.byType(LoopSlider), findsNothing);
  });

  testWidgets('Recording inputs checks the jacks the scoped track records, '
      'and scoping to another track shows that track instead', (tester) async {
    await pump(
      tester,
      state: _rig.copyWithLanes(const [Lane(inputChannel: 1)]),
    );
    await openRecord(tester);

    // Four inputs on the device, so four cards and no fifth.
    expect(find.byKey(const Key('routing_record_card_0')), findsOneWidget);
    expect(find.byKey(const Key('routing_record_card_3')), findsOneWidget);
    expect(find.byKey(const Key('routing_record_card_4')), findsNothing);
    // Track 0 records input 1; track 1's input 3 is not this track's.
    expect(cardSelected(tester, 1), isTrue);
    expect(cardSelected(tester, 3), isFalse);

    await tester.tap(find.byKey(const Key('routing_track_1')));
    await tester.pump();
    expect(cardSelected(tester, 3), isTrue);
    expect(cardSelected(tester, 1), isFalse);
  });

  testWidgets('a free lane takes the new jack; the track does not grow', (
    tester,
  ) async {
    await pump(
      tester,
      state: _rig.copyWithLanes(
        const [Lane(inputChannel: 1), Lane()],
      ),
    );
    await openRecord(tester);
    await tester.tap(find.byKey(const Key('routing_record_card_2')));
    await tester.pump();

    verify(() => bloc.add(const LooperLaneInputChanged(0, 1, 2))).called(1);
    verifyNever(() => bloc.add(any(that: isA<LooperLaneCountChanged>())));
  });

  testWidgets('with every lane taken the track grows before it is routed', (
    tester,
  ) async {
    await pump(
      tester,
      state: _rig.copyWithLanes(const [Lane(inputChannel: 1)]),
    );
    await openRecord(tester);
    await tester.tap(find.byKey(const Key('routing_record_card_2')));
    await tester.pump();

    // Growing second would route a lane the track does not have yet.
    verifyInOrder([
      () => bloc.add(const LooperLaneCountChanged(0, 2)),
      () => bloc.add(const LooperLaneInputChanged(0, 1, 2)),
    ]);
  });

  testWidgets('unchecking a jack frees its own lane and leaves the rest where '
      'they are', (tester) async {
    await pump(
      tester,
      state: _rig.copyWithLanes(
        const [Lane(inputChannel: 1), Lane(inputChannel: 2)],
      ),
    );
    await openRecord(tester);
    await tester.tap(find.byKey(const Key('routing_record_card_1')));
    await tester.pump();

    // Lane 0 is freed in place. Compacting would move lane 1's recorded take
    // onto input 2's slot and renumber it.
    verify(() => bloc.add(const LooperLaneInputChanged(0, 0, -1))).called(1);
    verifyNever(() => bloc.add(const LooperLaneInputChanged(0, 0, 2)));
    verifyNever(() => bloc.add(any(that: isA<LooperLaneCountChanged>())));
  });

  testWidgets('a capturing track cannot change its jacks, and only that '
      'track is held', (tester) async {
    await pump(tester, state: _rig.copyWithCapturing());
    await openRecord(tester);
    final l10n = l10nOf(tester);

    expect(find.text(l10n.routingLockedInputs), findsOneWidget);
    await tester.tap(find.byKey(const Key('routing_record_card_2')));
    await tester.pump();
    verifyNever(() => bloc.add(any(that: isA<LooperLaneInputChanged>())));

    await tester.tap(find.byKey(const Key('routing_track_1')));
    await tester.pump();
    expect(find.text(l10n.routingLockedInputs), findsNothing);
    await tester.tap(find.byKey(const Key('routing_record_card_2')));
    await tester.pump();
    verify(() => bloc.add(const LooperLaneInputChanged(1, 0, 2))).called(1);
  });

  testWidgets('a track that records nothing says so', (tester) async {
    await pump(tester);
    await openRecord(tester);
    expect(find.text(l10nOf(tester).routingNoInputs), findsOneWidget);
  });

  testWidgets('Output routing offers three source kinds and one destination '
      'card per stereo pair', (tester) async {
    await pump(tester);
    await openOutputs(tester);
    final l10n = l10nOf(tester);

    for (final kind in RoutingSourceKind.values) {
      expect(find.byKey(Key('routing_kind_${kind.name}')), findsOneWidget);
    }
    // Four hardware outputs are two destinations, and no third.
    expect(find.byKey(const Key('routing_destination_0')), findsOneWidget);
    expect(find.byKey(const Key('routing_destination_1')), findsOneWidget);
    expect(find.byKey(const Key('routing_destination_2')), findsNothing);
    // A card names the jacks and the destination, not one or the other.
    expect(find.text(l10n.outputBusLabel(1, channels: 4)), findsOneWidget);
    expect(
      find.text(l10n.outputName(const {}, 1, channels: 4)),
      findsOneWidget,
    );
    expect(find.text(l10n.routingSendTo), findsOneWidget);
  });

  testWidgets('a live input reaches a destination through its own monitor', (
    tester,
  ) async {
    await pump(tester);
    await openOutputs(tester);

    // A monitor starts on outputs 1-2, so this ADDS outputs 3-4.
    await tester.tap(find.byKey(const Key('routing_destination_1')));
    await tester.pump();
    verify(() => repository.setMonitorOutput(input: 0, mask: 0xF)).called(1);

    // And tapping a destination that is already on takes it away again.
    await tester.tap(find.byKey(const Key('routing_destination_0')));
    await tester.pump();
    verify(() => repository.setMonitorOutput(input: 0, mask: 0xC)).called(1);
  });

  testWidgets('a source that reaches nothing says so', (tester) async {
    await pump(tester);
    await openOutputs(tester);
    final l10n = l10nOf(tester);
    expect(find.text(l10n.routingNoDestinations), findsNothing);

    await tester.tap(find.byKey(const Key('routing_destination_0')));
    await tester.pump();
    expect(find.text(l10n.routingNoDestinations), findsOneWidget);
  });

  testWidgets("a track's route is the whole track's: every lane is written", (
    tester,
  ) async {
    await pump(
      tester,
      state: _rig.copyWithLanes(
        const [Lane(inputChannel: 0), Lane(inputChannel: 1)],
      ),
    );
    await openOutputs(tester);
    await tester.tap(find.byKey(const Key('routing_kind_tracks')));
    await tester.pump();

    await tester.tap(find.byKey(const Key('routing_destination_1')));
    await tester.pump();
    // Writing lane 0 alone would leave the track's second lane going
    // somewhere else, and the card would claim a route half the track has.
    verify(() => bloc.add(const LooperLaneOutputChanged(0, 0, 0xF))).called(1);
    verify(() => bloc.add(const LooperLaneOutputChanged(0, 1, 0xF))).called(1);
  });

  testWidgets('each source kind carries its own destinations', (tester) async {
    // The accepted rule: a recording-only track route never implicitly
    // becomes a live input route.
    await pump(tester);
    await openOutputs(tester);

    expect(destinationSelected(tester, 0), isTrue, reason: 'the monitor');
    await tester.tap(find.byKey(const Key('routing_kind_players')));
    await tester.pump();
    // The click starts routed nowhere, and reading the monitor's mask here
    // would show it already on.
    expect(destinationSelected(tester, 0), isFalse);

    await tester.tap(find.byKey(const Key('routing_destination_0')));
    await tester.pump();
    verify(() => repository.setClickOutput(0x3)).called(1);
  });

  testWidgets('Hear live belongs to the live inputs and to no other kind', (
    tester,
  ) async {
    await pump(tester);
    await openOutputs(tester);
    final l10n = l10nOf(tester);
    expect(find.text(l10n.routingHearLive), findsOneWidget);

    await tester.tap(find.byKey(const Key('routing_kind_tracks')));
    await tester.pump();
    expect(find.text(l10n.routingHearLive), findsNothing);

    await tester.tap(find.byKey(const Key('routing_kind_players')));
    await tester.pump();
    expect(find.text(l10n.routingHearLive), findsNothing);
  });

  testWidgets('Auto says whether the input is live right now', (tester) async {
    await pump(tester);
    await openOutputs(tester);
    final l10n = l10nOf(tester);

    await tester.tap(find.byKey(const Key('routing_monitor_auto')));
    await tester.pump();
    verify(
      () => repository.setMonitorInputMode(input: 0, mode: MonitorMode.auto),
    ).called(1);
    // Nothing is armed, so Auto is not hearing anything yet.
    expect(find.text(l10n.routingHearAutoOff), findsOneWidget);

    // Track 0 records input 0 and starts capturing: the same choice is live.
    await push(tester, _rig.copyWithCapturing());
    expect(find.text(l10n.routingHearAutoOn), findsOneWidget);
    expect(find.text(l10n.routingHearAutoOff), findsNothing);
  });

  testWidgets('Output setup opens on the master destination and edits one '
      'card per stereo pair', (tester) async {
    await pump(tester);
    await openOutputSetup(tester);
    final l10n = l10nOf(tester);

    expect(find.byKey(const Key('output_card_0')), findsOneWidget);
    expect(find.byKey(const Key('output_card_1')), findsOneWidget);
    expect(find.byKey(const Key('output_card_2')), findsNothing);
    expect(find.text(l10n.routingOutputAppliesNote), findsOneWidget);
    expect(find.text(l10n.routingOutputLevel), findsOneWidget);
    expect(find.text(l10n.routingBalance), findsOneWidget);

    // The master is the destination a player meets first.
    await tester.tap(find.byKey(const Key('output_format_mono')));
    await tester.pump();
    verify(
      () =>
          bloc.add(const LooperOutputMonoChanged(kMasterOutputBus, mono: true)),
    ).called(1);
  });

  testWidgets("every fact is the chosen destination's own", (tester) async {
    await pump(tester);
    await openOutputSetup(tester);

    await tester.tap(find.byKey(const Key('output_card_1')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('output_format_mono')));
    await tester.tap(find.byKey(const Key('output_mute')));
    await tester.pump();

    verify(
      () => bloc.add(const LooperOutputMonoChanged(1, mono: true)),
    ).called(1);
    verify(
      () => bloc.add(const LooperOutputMuteChanged(1, muted: true)),
    ).called(1);
  });

  testWidgets('Mono says what it does, and Stereo says nothing', (
    tester,
  ) async {
    await pump(tester);
    await openOutputSetup(tester);
    final l10n = l10nOf(tester);
    expect(find.text(l10n.routingOutputMonoNote), findsNothing);

    await push(tester, _rig.copyWithOutput(const OutputBus(mono: true)));
    expect(find.text(l10n.routingOutputMonoNote), findsOneWidget);
  });

  testWidgets('the mute reads out its own state and switches back', (
    tester,
  ) async {
    await pump(
      tester,
      state: _rig.copyWithOutput(const OutputBus(muted: true)),
    );
    await openOutputSetup(tester);
    final l10n = l10nOf(tester);

    expect(find.text(l10n.routingOutputMuted), findsOneWidget);
    expect(find.text(l10n.routingOutputMute), findsNothing);
    await tester.tap(find.byKey(const Key('output_mute')));
    await tester.pump();
    verify(
      () => bloc.add(
        const LooperOutputMuteChanged(kMasterOutputBus, muted: false),
      ),
    ).called(1);
  });

  testWidgets('the level and balance sliders commit once each', (tester) async {
    await pump(tester);
    await openOutputSetup(tester);

    final level = find.byKey(const Key('output_level_slider'));
    await tester.tapAt(tester.getTopLeft(level) + const Offset(414, 20));
    await tester.pump();
    final levels = verify(
      () => bloc.add(captureAny(that: isA<LooperOutputLevelChanged>())),
    ).captured.cast<LooperOutputLevelChanged>();
    expect(levels, hasLength(1));
    expect(levels.single.level, closeTo(0.5, 0.02));

    final balance = find.byKey(const Key('output_balance_slider'));
    await tester.tapAt(tester.getTopLeft(balance) + const Offset(100, 20));
    await tester.pump();
    final balances = verify(
      () => bloc.add(captureAny(that: isA<LooperOutputBalanceChanged>())),
    ).captured.cast<LooperOutputBalanceChanged>();
    expect(balances, hasLength(1));
    // The slider's full width is left to right, so a tap near its left end is
    // a balance to the left rather than a level near zero.
    expect(balances.single.balance, lessThan(0));
    expect(balances.single.balance, greaterThanOrEqualTo(-1));
  });

  testWidgets("the meters read the destination's own jacks", (tester) async {
    // Outputs 1-4 at four different peaks: the master hears the first pair
    // and the second destination the second.
    await pump(
      tester,
      state: _rig.copyWithOutput(
        const OutputBus(),
        peaks: const [1, 0.5, 0.25, 0.125],
      ),
    );
    await openOutputSetup(tester);
    final l10n = l10nOf(tester);

    expect(find.text(l10n.routingOutputDbfs('0.0')), findsOneWidget);
    expect(find.text(l10n.routingOutputDbfs('-6.0')), findsOneWidget);

    await tester.tap(find.byKey(const Key('output_card_1')));
    await tester.pump();
    expect(find.text(l10n.routingOutputDbfs('-12.0')), findsOneWidget);
    expect(find.text(l10n.routingOutputDbfs('-18.1')), findsOneWidget);
  });

  testWidgets('a muted destination meters silence, whatever the engine last '
      'reported', (tester) async {
    await pump(
      tester,
      state: _rig.copyWithOutput(
        const OutputBus(muted: true),
        peaks: const [1, 1, 0, 0],
      ),
    );
    await openOutputSetup(tester);
    final l10n = l10nOf(tester);

    expect(find.text(l10n.routingOutputSilent), findsNWidgets(2));
    expect(find.text(l10n.routingOutputDbfs('0.0')), findsNothing);
  });

  testWidgets('the header action names the side of the rig the task is on', (
    tester,
  ) async {
    await pump(tester);
    final l10n = l10nOf(tester);
    expect(find.text(l10n.routingInputNames), findsOneWidget);
    expect(find.text(l10n.routingOutputNames), findsNothing);

    await openOutputs(tester);
    expect(find.text(l10n.routingOutputNames), findsOneWidget);
    expect(find.text(l10n.routingInputNames), findsNothing);
  });

  testWidgets('the names list gives every port a row, and Back returns to '
      'the task it was opened from', (tester) async {
    await pump(tester);
    final l10n = l10nOf(tester);
    await tester.tap(find.byKey(const Key('routing_names_action')));
    await tester.pump();

    // The title is the page, the pills are gone, and four jacks are four rows.
    expect(find.text(l10n.routingInputNames), findsOneWidget);
    expect(find.byKey(const Key('routing_tab_setup')), findsNothing);
    expect(find.byKey(const Key('routing_name_row_0')), findsOneWidget);
    expect(find.byKey(const Key('routing_name_row_3')), findsOneWidget);
    expect(find.byKey(const Key('routing_name_row_4')), findsNothing);

    await tester.tap(find.byKey(const Key('loop_settings_back')));
    await tester.pump();
    expect(find.byKey(const Key('routing_tab_setup')), findsOneWidget);
    expect(find.text(l10n.routingTitle), findsOneWidget);
  });

  testWidgets('the output names list is one row per destination, not per '
      'jack', (tester) async {
    await pump(tester);
    await openOutputs(tester);
    await tester.tap(find.byKey(const Key('routing_names_action')));
    await tester.pump();

    // Four hardware outputs are two destinations.
    expect(find.byKey(const Key('routing_name_row_1')), findsOneWidget);
    expect(find.byKey(const Key('routing_name_row_2')), findsNothing);
    expect(
      find.text(l10nOf(tester).outputBusLabel(1, channels: 4)),
      findsOneWidget,
    );
  });

  testWidgets('renaming a port persists the name against the open device', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.byKey(const Key('routing_names_action')));
    await tester.pump();

    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('routing_name_row_1')),
        matching: find.byKey(const Key('routing_rename')),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('console_rename_sheet')), findsOneWidget);
    for (final key in ['d', 'i']) {
      await tester.tap(find.text(key).first);
      await tester.pump();
    }
    await tester.tap(find.text(l10nOf(tester).save));
    await tester.pumpAndSettle();

    expect(inputs.state.nameOf(1), 'di');
    expect(
      await settings.loadInputName(device: 'Fake Device', input: 1),
      'di',
    );
  });

  testWidgets('the format lock covers BOTH members of a pair, not just the '
      'jack on screen', (tester) async {
    // The repository refuses the pair change while EITHER member feeds an
    // armed track. A lock that asked only about the shown jack would draw a
    // live control that is then silently refused.
    await pump(tester, state: _rig.copyWithCapturing());
    final l10n = l10nOf(tester);
    expect(find.text(l10n.routingLockedFormat), findsOneWidget);

    // Track 0 records input 0; input 1 is its pair partner and is held too.
    await tester.tap(find.byKey(const Key('routing_input_card_1')));
    await tester.pump();
    expect(find.text(l10n.routingLockedFormat), findsOneWidget);
    await tester.tap(find.byKey(const Key('routing_format_stereo')));
    await tester.pump();
    verifyNever(() => bloc.add(any(that: isA<LooperInputPairChanged>())));

    // Input 2 is nobody's partner here, so its format is free.
    await tester.tap(find.byKey(const Key('routing_input_card_2')));
    await tester.pump();
    expect(find.text(l10n.routingLockedFormat), findsNothing);
  });

  testWidgets('a narrower device does not leave the page editing a jack it '
      'no longer has', (tester) async {
    // Track 0 records input 0 and is capturing, so on the wide rig input 3 is
    // free and input 0 is held.
    await pump(tester, state: _rig.copyWithCapturing());
    await tester.tap(find.byKey(const Key('routing_input_card_3')));
    await tester.pump();
    final l10n = l10nOf(tester);
    expect(find.text(l10n.routingLockedFormat), findsNothing);

    // The interface is swapped for a two-in one. The page falls back to input
    // 0, and everything it draws has to describe THAT jack: a lock computed
    // for the jack the finger last touched would freeze a control that the
    // repository would happily accept, or free one it refuses.
    await push(tester, _rig.copyWithCapturingChannels(inputs: 2));
    expect(find.byKey(const Key('routing_input_card_3')), findsNothing);
    expect(find.text(l10n.routingLockedFormat), findsOneWidget);

    final slider = find.byKey(const Key('routing_trim_slider'));
    await tester.tapAt(tester.getTopLeft(slider) + const Offset(400, 20));
    await tester.pump();
    final captured = verify(
      () => bloc.add(captureAny(that: isA<LooperInputTrimChanged>())),
    ).captured.cast<LooperInputTrimChanged>();
    expect(captured.single.input, 0);
  });

  testWidgets('a narrower device does not leave Output setup editing a '
      'destination it no longer has', (tester) async {
    await pump(tester);
    await openOutputSetup(tester);
    await tester.tap(find.byKey(const Key('output_card_1')));
    await tester.pump();

    await push(tester, _rig.copyWithChannels(inputs: 2, outputs: 2));
    expect(find.byKey(const Key('output_card_1')), findsNothing);
    await tester.tap(find.byKey(const Key('output_mute')));
    await tester.pump();
    verify(
      () => bloc.add(
        const LooperOutputMuteChanged(kMasterOutputBus, muted: true),
      ),
    ).called(1);
  });

  testWidgets('a jack this track records that the rig has not got keeps its '
      'own card', (tester) async {
    // Reopen an eight-in session on a four-in rig: without a card, the lane
    // recording In 7 is invisible, unclearable, and survives every restart.
    await pump(
      tester,
      state: _rig.copyWithLanes(const [Lane(inputChannel: 6)]),
    );
    await openRecord(tester);

    expect(find.byKey(const Key('routing_record_card_6')), findsOneWidget);
    expect(cardSelected(tester, 6), isTrue);
    await tester.tap(find.byKey(const Key('routing_record_card_6')));
    await tester.pump();
    verify(() => bloc.add(const LooperLaneInputChanged(0, 0, -1))).called(1);
  });

  testWidgets('a full track says so and stops offering more jacks', (
    tester,
  ) async {
    await pump(
      tester,
      state: _rig.copyWithLanes([
        for (var lane = 0; lane < kMaxLanes; lane++)
          const Lane(inputChannel: 0),
      ], inputs: 18),
    );
    await openRecord(tester);
    final l10n = l10nOf(tester);

    expect(find.text(l10n.routingTrackFull(kMaxLanes)), findsOneWidget);
    // A card that cannot be taken is drawn inert, not left looking live with
    // a tap that quietly does nothing.
    expect(cardEnabled(tester, 3), isFalse);
    // The jack this track already records stays live, so it can be freed.
    expect(cardEnabled(tester, 0), isTrue);
    await tester.tap(find.byKey(const Key('routing_record_card_3')));
    await tester.pump();
    verifyNever(() => bloc.add(any(that: isA<LooperLaneCountChanged>())));
    verifyNever(() => bloc.add(any(that: isA<LooperLaneInputChanged>())));
  });

  testWidgets('a destination the rig has not got can still be switched off', (
    tester,
  ) async {
    // A session routed to Outputs 5-6 reopened on a four-out rig: the card is
    // drawn beyond the device so the route has somewhere to be cleared.
    await pump(
      tester,
      state: _rig.copyWithLanes(const [Lane(outputMask: 0x30)]),
    );
    await openOutputs(tester);
    await tester.tap(find.byKey(const Key('routing_kind_tracks')));
    await tester.pump();

    // The third card is past the pen's two, so the row scrolls to it.
    await tester.dragUntilVisible(
      find.byKey(const Key('routing_destination_2')),
      find.byKey(const Key('routing_destination_0')),
      const Offset(-300, 0),
    );
    await tester.pump();
    expect(find.byKey(const Key('routing_destination_2')), findsOneWidget);
    expect(destinationSelected(tester, 2), isTrue);
    // Both jacks are cleared, not only the ones this device has: clearing
    // half would leave the card lit and every later tap a no-op.
    await tester.tap(find.byKey(const Key('routing_destination_2')));
    await tester.pump();
    verify(() => bloc.add(const LooperLaneOutputChanged(0, 0, 0))).called(1);
  });

  testWidgets('a source that only reaches jacks the rig has not got says it '
      'reaches nothing', (tester) async {
    await pump(
      tester,
      state: _rig.copyWithLanes(const [Lane(outputMask: 0x30)]),
    );
    await openOutputs(tester);
    await tester.tap(find.byKey(const Key('routing_kind_tracks')));
    await tester.pump();

    // Outputs 5-6 on a four-out rig is silence, and the note says so rather
    // than leaving an inaudible source looking routed.
    expect(
      find.text(l10nOf(tester).routingNoDestinations),
      findsOneWidget,
    );
  });

  testWidgets('with no interface open every task says so instead of drawing '
      'controls for a rig that is not there', (tester) async {
    await pump(tester, state: const LooperState());
    final l10n = l10nOf(tester);

    await openOutputs(tester);
    expect(find.text(l10n.routingNoDestinationsYet), findsOneWidget);
    await openOutputSetup(tester);
    expect(find.text(l10n.routingNoDestinationsYet), findsOneWidget);
    expect(find.byKey(const Key('output_mute')), findsNothing);

    await tester.tap(find.byKey(const Key('routing_names_action')));
    await tester.pump();
    expect(find.text(l10n.routingNoPortsYet), findsOneWidget);
  });

  testWidgets('Hear live follows the jack that is picked', (tester) async {
    await pump(tester);
    await openOutputs(tester);

    await tester.tap(find.byKey(const Key('routing_source_input_2')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('routing_monitor_on')));
    await tester.pump();
    verify(
      () => repository.setMonitorInputMode(input: 2, mode: MonitorMode.on),
    ).called(1);

    // And Send to now writes that jack's monitor, not the first one's.
    await tester.tap(find.byKey(const Key('routing_destination_1')));
    await tester.pump();
    verify(() => repository.setMonitorOutput(input: 2, mask: 0xF)).called(1);
  });

  testWidgets('a monitor muted in Mixer says so rather than looking switched '
      'on', (tester) async {
    await pump(tester);
    await openOutputs(tester);
    final l10n = l10nOf(tester);
    expect(find.text(l10n.routingHearMuted), findsNothing);

    await monitors.setMute(0, muted: true);
    await tester.pump();
    expect(find.text(l10n.routingHearMuted), findsOneWidget);
  });

  testWidgets('a slider previews under the finger and commits once on '
      'release', (tester) async {
    await pump(tester);
    final l10n = l10nOf(tester);
    expect(find.text(l10n.routingTrimDb('0.0')), findsOneWidget);

    final slider = find.byKey(const Key('routing_trim_slider'));
    final start = tester.getTopLeft(slider) + const Offset(700, 20);
    final gesture = await tester.startGesture(start);
    await gesture.moveTo(tester.getTopLeft(slider) + const Offset(300, 20));
    await tester.pump();

    // The readout follows the finger; nothing is written yet.
    expect(find.text(l10n.routingTrimDb('0.0')), findsNothing);
    verifyNever(() => bloc.add(any(that: isA<LooperInputTrimChanged>())));

    await gesture.up();
    await tester.pump();
    verify(
      () => bloc.add(any(that: isA<LooperInputTrimChanged>())),
    ).called(1);
  });

  testWidgets('the route opens once, on the task it is asked for', (
    tester,
  ) async {
    // The console reaches Audio routing through a row that calls
    // `openAudioRouting`; a second call while it is open must not stack a
    // duplicate behind the first.
    resetSegnoNavigatorForTest();
    await pump(tester, home: const SizedBox.shrink());

    unawaited(openAudioRouting(initial: AudioRoutingTab.outputs));
    await tester.pumpAndSettle();
    expect(find.byType(AudioRoutingPage), findsOneWidget);
    expect(find.text(l10nOf(tester).routingSendTo), findsOneWidget);

    unawaited(openAudioRouting());
    await tester.pumpAndSettle();
    expect(find.byType(AudioRoutingPage), findsOneWidget);

    // And Back leaves it, so the guard is cleared rather than stuck on.
    await tester.tap(find.byKey(const Key('loop_settings_back')));
    await tester.pumpAndSettle();
    expect(find.byType(AudioRoutingPage), findsNothing);
    unawaited(openAudioRouting());
    await tester.pumpAndSettle();
    expect(find.byType(AudioRoutingPage), findsOneWidget);
  });

  group('routingPlacementLabel', () {
    late AppLocalizations l10n;

    setUpAll(() async {
      l10n = await AppLocalizations.delegate.load(const Locale('en'));
    });

    test('names the side and how far, and has a word for the middle', () {
      expect(routingPlacementLabel(l10n, 0), l10n.routingPanCenter);
      expect(routingPlacementLabel(l10n, -0.5), l10n.routingPanLeftAmount(50));
      expect(routingPlacementLabel(l10n, 1), l10n.routingPanRightAmount(100));
      // Rounding to nothing is the middle, not a 0% side.
      expect(routingPlacementLabel(l10n, 0.001), l10n.routingPanCenter);
    });
  });

  group('routingDbfsLabel', () {
    late AppLocalizations l10n;

    setUpAll(() async {
      l10n = await AppLocalizations.delegate.load(const Locale('en'));
    });

    test('reads the peak, and says nothing is coming out below the floor', () {
      expect(routingDbfsLabel(l10n, 1), l10n.routingOutputDbfs('0.0'));
      expect(routingDbfsLabel(l10n, 0.5), l10n.routingOutputDbfs('-6.0'));
      expect(routingDbfsLabel(l10n, 0), l10n.routingOutputSilent);
      expect(routingDbfsLabel(l10n, 0.0001), l10n.routingOutputSilent);
    });
  });

  group('routingMeterPosition', () {
    test('lights cells where the scale under them says they belong', () {
      // The scale prints -60, -24, -12 and 0 dBFS at four evenly spaced
      // ticks, so a meter filled linearly in decibels would disagree with it.
      expect(routingMeterPosition(1), 1);
      expect(routingMeterPosition(0), 0);
      // -24 dBFS is a third of the way along, -12 two thirds.
      expect(routingMeterPosition(0.0630957), closeTo(1 / 3, 0.001));
      expect(routingMeterPosition(0.2511886), closeTo(2 / 3, 0.001));
      // -6 dBFS sits halfway between -12 and full scale.
      expect(routingMeterPosition(0.5011872), closeTo(5 / 6, 0.001));
    });

    test('anything under the floor is off the bottom, not a small fill', () {
      // -60 dBFS is the floor itself, and lands on it to within rounding.
      expect(routingMeterPosition(0.001), closeTo(0, 1e-9));
      expect(routingMeterPosition(0.0001), 0);
      expect(routingMeterPosition(-1), 0);
    });
  });
}

/// Whether destination [bus] is drawn as reached.
bool destinationSelected(WidgetTester tester, int bus) => tester
    .widgetList<Semantics>(
      find.descendant(
        of: find.byKey(Key('routing_destination_$bus')),
        matching: find.byType(Semantics),
      ),
    )
    .first
    .properties
    .selected!;

/// Whether the Recording inputs card for [input] can be taken.
bool cardEnabled(WidgetTester tester, int input) => tester
    .widgetList<Semantics>(
      find.descendant(
        of: find.byKey(Key('routing_record_card_$input')),
        matching: find.byType(Semantics),
      ),
    )
    .first
    .properties
    .enabled!;

/// Switches to the Output setup task.
Future<void> openOutputSetup(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('routing_tab_outputSetup')));
  await tester.pump();
}

/// Switches to the Output routing task.
Future<void> openOutputs(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('routing_tab_outputs')));
  await tester.pump();
}

/// Whether the Recording inputs card for [input] is drawn as recorded.
bool cardSelected(WidgetTester tester, int input) => tester
    .widgetList<Semantics>(
      find.descendant(
        of: find.byKey(Key('routing_record_card_$input')),
        matching: find.byType(Semantics),
      ),
    )
    .first
    .properties
    .selected!;

/// Switches to the Recording inputs task.
Future<void> openRecord(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('routing_tab_record')));
  await tester.pump();
}

extension on LooperState {
  /// [_rig] with the master destination set to [bus] and the given jack
  /// [peaks].
  LooperState copyWithOutput(
    OutputBus bus, {
    List<double> peaks = const [0, 0, 0, 0],
  }) => LooperState(
    tracks: tracks,
    status: status,
    inputPeaks: inputPeaks,
    outputBusCount: outputBusCount,
    outputPeaks: peaks,
    outputSetup: OutputSetup(buses: {kMasterOutputBus: bus}),
  );

  /// [_rig] with track 0 holding [lanes] and track 1 recording input 3,
  /// optionally on a wider interface.
  LooperState copyWithLanes(List<Lane> lanes, {int? inputs}) => LooperState(
    tracks: [
      Track(lanes: lanes),
      const Track(channel: 1, lanes: [Lane(inputChannel: 3)]),
    ],
    status: inputs == null
        ? status
        : EngineStatus(
            deviceName: status.deviceName,
            inputChannels: inputs,
            outputChannels: status.outputChannels,
          ),
    inputPeaks: inputPeaks,
    outputBusCount: outputBusCount,
  );

  /// [_rig] on an interface with [inputs] in and [outputs] out.
  LooperState copyWithChannels({required int inputs, required int outputs}) =>
      LooperState(
        tracks: tracks,
        status: EngineStatus(
          deviceName: status.deviceName,
          inputChannels: inputs,
          outputChannels: outputs,
        ),
        inputPeaks: inputPeaks,
        outputBusCount: (outputs + 1) ~/ 2,
      );

  /// [_rig] with [setup] applied.
  LooperState copyWithInputSetup(InputSetup setup) => LooperState(
    tracks: tracks,
    status: status,
    inputPeaks: inputPeaks,
    outputBusCount: outputBusCount,
    inputSetup: setup,
  );

  /// [_rig] capturing input 0 on an interface with [inputs] in.
  LooperState copyWithCapturingChannels({required int inputs}) => LooperState(
    tracks: copyWithCapturing().tracks,
    status: EngineStatus(
      deviceName: status.deviceName,
      inputChannels: inputs,
      outputChannels: status.outputChannels,
    ),
    inputPeaks: inputPeaks,
    outputBusCount: outputBusCount,
  );

  /// [_rig] with track 0 capturing input 0.
  LooperState copyWithCapturing() => LooperState(
    tracks: const [
      Track(
        state: TrackState.recording,
        lanes: [Lane(inputChannel: 0)],
      ),
      Track(channel: 1),
    ],
    status: status,
    inputPeaks: inputPeaks,
    outputBusCount: outputBusCount,
  );

  /// [_rig] with input [input] held as clipping.
  LooperState copyWithClip(int input) => LooperState(
    tracks: tracks,
    status: EngineStatus(
      deviceName: status.deviceName,
      inputChannels: status.inputChannels,
      outputChannels: status.outputChannels,
      inputClipMask: 1 << input,
    ),
    inputPeaks: inputPeaks,
  );
}
