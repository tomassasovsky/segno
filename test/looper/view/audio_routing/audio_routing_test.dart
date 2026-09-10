import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:segno/audio_setup/cubit/inputs_cubit.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/view/audio_routing/audio_routing_page.dart';
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
);

void main() {
  late _MockLooperBloc bloc;
  late _MockLooperRepository repository;
  late SettingsRepository settings;
  late StreamController<LooperState> states;
  late InputsCubit inputs;

  setUpAll(() {
    registerFallbackValue(const LooperInputPanChanged(0, pan: 0));
  });

  setUp(() {
    bloc = _MockLooperBloc();
    repository = _MockLooperRepository();
    settings = SettingsRepository(store: FakeKeyValueStore());
    states = StreamController<LooperState>.broadcast();
    when(() => repository.looperState).thenAnswer((_) => states.stream);
    when(() => repository.state).thenReturn(_rig);
  });

  tearDown(() => states.close());

  Future<void> pump(WidgetTester tester, {LooperState state = _rig}) async {
    tester.view
      ..physicalSize = const Size(1920, 1080)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    when(() => bloc.state).thenReturn(state);
    whenListen(bloc, states.stream, initialState: state);
    inputs = InputsCubit(repository: repository, settings: settings);
    addTearDown(() => unawaited(inputs.close()));
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: ThemeData(extensions: const [SurfaceTheme.dark]),
        home: RepositoryProvider<LooperRepository>.value(
          value: repository,
          child: MultiBlocProvider(
            providers: [
              BlocProvider<LooperBloc>.value(value: bloc),
              BlocProvider.value(value: inputs),
            ],
            child: const AudioRoutingPage(),
          ),
        ),
      ),
    );
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

  testWidgets('a clipping input says so instead of the trim note', (
    tester,
  ) async {
    await pump(tester, state: _rig.copyWithClip(0));
    final l10n = l10nOf(tester);
    expect(find.text(l10n.routingClipNote), findsOneWidget);
    expect(find.text(l10n.routingTrimNote), findsNothing);
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
}

extension on LooperState {
  /// [_rig] with [setup] applied.
  LooperState copyWithInputSetup(InputSetup setup) => LooperState(
    tracks: tracks,
    status: status,
    inputPeaks: inputPeaks,
    inputSetup: setup,
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
