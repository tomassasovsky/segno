import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:routing_graph/routing_graph.dart';
import 'package:segno/audio_setup/cubit/inputs_cubit.dart';
import 'package:segno/audio_setup/cubit/monitor_cubit.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/cubit/settings_tray_cubit.dart';
import 'package:segno/looper/cubit/tracks_cubit.dart';
import 'package:segno/looper/view/signal/signal_card.dart';
import 'package:segno/looper/view/signal/signal_tray_panel.dart';
import 'package:segno/theme/theme.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../../helpers/helpers.dart';

class _MockLooperBloc extends MockBloc<LooperEvent, LooperState>
    implements LooperBloc {}

class _MockLooperRepository extends Mock implements LooperRepository {}

/// A rig with a chain on every stage, so each panel has something to draw.
final _rig = LooperState(
  tracks: [
    Track(
      volume: 0.5,
      lanes: const [
        Lane(inputChannel: 0, volume: 0.5),
      ],
      effects: [BuiltInEffect(type: TrackEffectType.reverb)],
    ),
    const Track(channel: 1, lanes: [Lane(inputChannel: 1)]),
  ],
  masterEffects: [BuiltInEffect(type: TrackEffectType.drive)],
  status: const EngineStatus(
    deviceName: 'Scarlett 18i20',
    inputChannels: 2,
    outputChannels: 2,
  ),
);

void main() {
  late _MockLooperBloc bloc;
  late _MockLooperRepository repository;
  late SettingsRepository settings;
  late TracksCubit tracks;
  late InputsCubit inputs;
  late MonitorCubit monitor;
  late SettingsTrayCubit tray;

  setUpAll(() => registerFallbackValue(MonitorMode.off));

  setUp(() {
    bloc = _MockLooperBloc();
    repository = _MockLooperRepository();
    when(
      () => repository.looperState,
    ).thenAnswer((_) => const Stream<LooperState>.empty());
    when(() => repository.state).thenReturn(_rig);
    when(repository.allMonitors).thenReturn(const {});
    for (final stub in [
      () => when(
        () => repository.setMonitorInputMode(
          input: any(named: 'input'),
          mode: any(named: 'mode'),
        ),
      ).thenReturn(EngineResult.ok),
      () => when(
        () => repository.setMonitorMute(
          input: any(named: 'input'),
          muted: any(named: 'muted'),
        ),
      ).thenReturn(EngineResult.ok),
      () => when(
        () => repository.setMonitorVolume(
          input: any(named: 'input'),
          volume: any(named: 'volume'),
        ),
      ).thenReturn(EngineResult.ok),
      () => when(
        () => repository.setMonitorOutput(
          input: any(named: 'input'),
          mask: any(named: 'mask'),
        ),
      ).thenReturn(EngineResult.ok),
    ]) {
      stub();
    }
  });

  Future<void> pump(
    WidgetTester tester, {
    FxStage stage = FxStage.input,
    LooperState? state,
  }) async {
    final rig = state ?? _rig;
    tester.view
      ..physicalSize = const Size(1920, 1080)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    when(() => bloc.state).thenReturn(rig);
    whenListen(bloc, const Stream<LooperState>.empty(), initialState: rig);

    settings = SettingsRepository(store: FakeKeyValueStore());
    tracks = TracksCubit(settings: settings);
    inputs = InputsCubit(settings: settings, repository: repository);
    monitor = MonitorCubit(repository: repository, settings: settings);
    tray = SettingsTrayCubit(settings: settings)..showSignalTab(stage);
    addTearDown(() => unawaited(tracks.close()));
    addTearDown(() => unawaited(inputs.close()));
    addTearDown(() => unawaited(monitor.close()));
    addTearDown(() => unawaited(tray.close()));

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
          value: repository,
          child: MultiBlocProvider(
            providers: [
              BlocProvider<LooperBloc>.value(value: bloc),
              BlocProvider.value(value: tracks),
              BlocProvider.value(value: inputs),
              BlocProvider.value(value: monitor),
              BlocProvider.value(value: tray),
            ],
            child: const Scaffold(
              body: Padding(
                padding: EdgeInsets.all(19),
                child: SignalTrayPanel(),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  AppLocalizations l10nOf(WidgetTester tester) =>
      AppLocalizations.of(tester.element(find.byType(SignalTrayPanel)));

  Finder panel() => find.byKey(const Key('signal_detail_panel'));

  // ------------------------------------------- SIGNAL / signal-detail

  group('opening and closing', () {
    testWidgets('a card opens its panel and takes the accent', (tester) async {
      await pump(tester);
      expect(panel(), findsNothing);

      await tester.tap(find.byKey(const Key('signal_card_input_0')));
      await tester.pumpAndSettle();

      expect(panel(), findsOneWidget);
      expect(
        tray.state.signalSelection,
        const FxAddress(stage: FxStage.input),
      );
      expect(
        tester
            .widget<SignalCard>(find.byKey(const Key('signal_card_input_0')))
            .selected,
        isTrue,
      );
    });

    testWidgets('tapping the open card closes it again', (tester) async {
      await pump(tester);
      await tester.tap(find.byKey(const Key('signal_card_input_0')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('signal_card_input_0')));
      await tester.pumpAndSettle();

      // A disclosure that cannot be shut leaves no way back to the plain run.
      expect(panel(), findsNothing);
      expect(tray.state.signalSelection, isNull);
    });

    testWidgets('one at a time — a second card replaces the first', (
      tester,
    ) async {
      await pump(tester);
      await tester.tap(find.byKey(const Key('signal_card_input_0')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('signal_card_input_1')));
      await tester.pumpAndSettle();

      expect(panel(), findsOneWidget);
      expect(
        tray.state.signalSelection,
        const FxAddress(stage: FxStage.input, index: 1),
      );
    });

    testWidgets('changing stage clears the selection', (tester) async {
      await pump(tester);
      final l10n = l10nOf(tester);
      await tester.tap(find.byKey(const Key('signal_card_input_0')));
      await tester.pumpAndSettle();

      await tester.tap(find.text(l10n.signalStageLoop));
      await tester.pumpAndSettle();

      // A panel hanging under a run that no longer holds its card would be a
      // selection the face cannot draw.
      expect(tray.state.signalSelection, isNull);
      expect(panel(), findsNothing);
    });
  });

  // ------------------------------------------- the rows each stage owns

  group('the rows a stage can answer', () {
    testWidgets('an input answers all four', (tester) async {
      await pump(tester);
      await tester.tap(find.byKey(const Key('signal_card_input_0')));
      await tester.pumpAndSettle();
      final l10n = l10nOf(tester);

      expect(find.text(l10n.signalPanelChain), findsOneWidget);
      expect(find.text(l10n.signalPanelLevel), findsOneWidget);
      expect(find.text(l10n.signalPanelInMix), findsOneWidget);
      // The one stage that can be armed, so the one stage AUTO means anything
      // on.
      expect(find.text(l10n.signalPanelHearWhilePlaying), findsOneWidget);
      expect(find.byKey(const Key('signal_panel_monitor')), findsOneWidget);
    });

    testWidgets('a lane answers three — no monitor gate exists for it', (
      tester,
    ) async {
      await pump(tester, stage: FxStage.loop);
      await tester.tap(find.byKey(const Key('signal_card_loop_0_0')));
      await tester.pumpAndSettle();
      final l10n = l10nOf(tester);

      expect(find.text(l10n.signalPanelChain), findsOneWidget);
      expect(find.text(l10n.signalPanelLevel), findsOneWidget);
      expect(find.text(l10n.signalPanelInMix), findsOneWidget);
      // `Lane` has no MonitorMode: the mockup drew this row on a loop card and
      // the rig has no such gate, so the drawing is what is wrong.
      expect(find.text(l10n.signalPanelHearWhilePlaying), findsNothing);
      expect(find.byKey(const Key('signal_panel_monitor')), findsNothing);
    });

    testWidgets('a track bus answers three', (tester) async {
      await pump(tester, stage: FxStage.track);
      await tester.tap(find.byKey(const Key('signal_card_track_0')));
      await tester.pumpAndSettle();
      final l10n = l10nOf(tester);

      expect(find.text(l10n.signalPanelLevel), findsOneWidget);
      expect(find.text(l10n.signalPanelInMix), findsOneWidget);
      expect(find.text(l10n.signalPanelHearWhilePlaying), findsNothing);
    });

    testWidgets('the master answers one — the sum has no fader or mute', (
      tester,
    ) async {
      await pump(tester, stage: FxStage.master);
      await tester.tap(find.byKey(const Key('signal_card_master')));
      await tester.pumpAndSettle();
      final l10n = l10nOf(tester);

      expect(find.text(l10n.signalPanelChain), findsOneWidget);
      // Where the sum goes is the OUTPUTS group already under the card.
      expect(find.text(l10n.signalPanelLevel), findsNothing);
      expect(find.text(l10n.signalPanelInMix), findsNothing);
      expect(find.text(l10n.signalPanelHearWhilePlaying), findsNothing);
    });
  });

  // ------------------------------------------- what the controls drive

  group('the controls reach their carriers', () {
    testWidgets('in the mix mutes and unmutes the input monitor', (
      tester,
    ) async {
      await pump(tester);
      await tester.tap(find.byKey(const Key('signal_card_input_0')));
      await tester.pumpAndSettle();
      final l10n = l10nOf(tester);

      await tester.tap(find.text(l10n.signalMixMuted));
      await tester.pumpAndSettle();

      expect(monitor.state.forInput(0).muted, isTrue);
      verify(
        () => repository.setMonitorMute(input: 0, muted: true),
      ).called(1);
    });

    testWidgets('the monitor segment writes the mode', (tester) async {
      await pump(tester);
      await tester.tap(find.byKey(const Key('signal_card_input_0')));
      await tester.pumpAndSettle();
      final l10n = l10nOf(tester);

      await tester.tap(find.text(l10n.signalMonitorSegOn));
      await tester.pumpAndSettle();

      expect(monitor.state.forInput(0).mode, MonitorMode.on);
    });

    testWidgets('the level fader writes the input monitor volume', (
      tester,
    ) async {
      await pump(tester);
      await tester.tap(find.byKey(const Key('signal_card_input_0')));
      await tester.pumpAndSettle();

      await tester.drag(
        find.byKey(const Key('signal_panel_level')),
        const Offset(-200, 0),
      );
      await tester.pumpAndSettle();

      expect(monitor.state.forInput(0).volume, lessThan(1.0));
      verify(
        () => repository.setMonitorVolume(
          input: 0,
          volume: any(named: 'volume'),
        ),
      ).called(greaterThan(0));
    });

    testWidgets("a lane's mix control raises the lane's own event", (
      tester,
    ) async {
      await pump(tester, stage: FxStage.loop);
      await tester.tap(find.byKey(const Key('signal_card_loop_0_0')));
      await tester.pumpAndSettle();
      final l10n = l10nOf(tester);

      await tester.tap(find.text(l10n.signalMixMuted));
      await tester.pumpAndSettle();

      verify(() => bloc.add(const LooperLaneMuteToggled(0, 0))).called(1);
    });

    testWidgets("a track's mix control raises the channel event", (
      tester,
    ) async {
      await pump(tester, stage: FxStage.track);
      await tester.tap(find.byKey(const Key('signal_card_track_0')));
      await tester.pumpAndSettle();
      final l10n = l10nOf(tester);

      await tester.tap(find.text(l10n.signalMixMuted));
      await tester.pumpAndSettle();

      verify(() => bloc.add(const LooperMuteToggled(0))).called(1);
    });
  });

  // ------------------------------------------- the chain strip

  group('the chain strip', () {
    testWidgets('draws the chain in processing order', (tester) async {
      await pump(tester, stage: FxStage.track);
      await tester.tap(find.byKey(const Key('signal_card_track_0')));
      await tester.pumpAndSettle();
      final l10n = l10nOf(tester);

      expect(find.byKey(const Key('signal_panel_chip_0')), findsOneWidget);
      expect(find.text(l10n.effectReverb), findsOneWidget);
    });

    testWidgets('an empty chain says so rather than drawing nothing', (
      tester,
    ) async {
      await pump(tester, stage: FxStage.track);
      // Track 1 carries no effects.
      await tester.tap(find.byKey(const Key('signal_card_track_1')));
      await tester.pumpAndSettle();
      final l10n = l10nOf(tester);

      expect(
        find.byKey(const Key('signal_panel_chain_empty')),
        findsOneWidget,
      );
      expect(find.text(l10n.signalPanelChainEmpty), findsOneWidget);
    });

    testWidgets('the master draws its own insert chain', (tester) async {
      await pump(tester, stage: FxStage.master);
      await tester.tap(find.byKey(const Key('signal_card_master')));
      await tester.pumpAndSettle();
      final l10n = l10nOf(tester);

      expect(find.text(l10n.effectDrive), findsOneWidget);
    });
  });

  testWidgets('every tap target is labeled (labeledTapTargetGuideline)', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await pump(tester);
    await tester.tap(find.byKey(const Key('signal_card_input_0')));
    await tester.pumpAndSettle();
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    handle.dispose();
  });
}
