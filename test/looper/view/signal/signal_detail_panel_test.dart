import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
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
import 'package:segno/looper/view/signal/signal_detail_panel.dart';
import 'package:segno/looper/view/signal/signal_tray_panel.dart';
import 'package:segno/looper/view/signal_graph/signal_style.dart';
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
        Lane(inputChannel: 1),
      ],
      effects: [
        BuiltInEffect(type: TrackEffectType.reverb),
        BuiltInEffect(type: TrackEffectType.tremolo),
      ],
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

  setUpAll(() {
    registerFallbackValue(MonitorMode.off);
    registerFallbackValue(const LooperMuteToggled(0));
    registerFallbackValue(const <TrackEffect>[]);
  });

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
      () => when(
        () => repository.setMonitorEffects(
          input: any(named: 'input'),
          effects: any(named: 'effects'),
        ),
      ).thenReturn(EngineResult.ok),
      () => when(() => repository.monitorEffects(any())).thenReturn(const []),
    ]) {
      stub();
    }
  });

  Future<void> pump(
    WidgetTester tester, {
    FxStage stage = FxStage.input,
    LooperState? state,
    Stream<LooperState>? states,
  }) async {
    final rig = state ?? _rig;
    tester.view
      ..physicalSize = const Size(1920, 1080)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    when(() => bloc.state).thenReturn(rig);
    whenListen(
      bloc,
      states ?? const Stream<LooperState>.empty(),
      initialState: rig,
    );

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

  /// Whether the segment labelled [label] is the chosen one, read off the
  /// RENDERED fill rather than off any widget input — inverting the display
  /// while leaving the write path correct is exactly the mutation that would
  /// otherwise ship green.
  bool selectedLabel(WidgetTester tester, String label) {
    final box = tester.widget<AnimatedContainer>(
      find
          .ancestor(
            of: find.text(label),
            matching: find.byType(AnimatedContainer),
          )
          .first,
    );
    return (box.decoration! as BoxDecoration).color == SurfaceTheme.dark.accent;
  }

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
      // The RENDERED border, not the prop the tap just wrote: asserting
      // `SignalCard.selected` would pass with the accent deleted entirely.
      Color borderOf(String key) {
        final box = tester.widget<AnimatedContainer>(
          find
              .descendant(
                of: find.byKey(Key(key)),
                matching: find.byType(AnimatedContainer),
              )
              .first,
        );
        return ((box.decoration! as BoxDecoration).border! as Border).top.color;
      }

      expect(borderOf('signal_card_input_0'), SurfaceTheme.dark.accent);
      expect(borderOf('signal_card_input_1'), SurfaceTheme.dark.line);
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

      // Reads `heard` before the tap — the panel must SHOW what the rig is,
      // not merely write correctly when tapped. Inverting the display alone
      // would otherwise ship green.
      expect(selectedLabel(tester, l10n.signalMixHeard), isTrue);
      expect(selectedLabel(tester, l10n.signalMixMuted), isFalse);

      await tester.tap(find.text(l10n.signalMixMuted));
      await tester.pumpAndSettle();

      expect(monitor.state.forInput(0).muted, isTrue);
      verify(() => repository.setMonitorMute(input: 0, muted: true)).called(1);
      expect(selectedLabel(tester, l10n.signalMixMuted), isTrue);

      // And back — the unmute leg, which the write-path-only version never ran.
      await tester.tap(find.text(l10n.signalMixHeard));
      await tester.pumpAndSettle();

      expect(monitor.state.forInput(0).muted, isFalse);
      verify(() => repository.setMonitorMute(input: 0, muted: false)).called(1);
    });

    testWidgets('re-tapping the segment the rig is already on does nothing', (
      tester,
    ) async {
      await pump(tester, stage: FxStage.track);
      await tester.tap(find.byKey(const Key('signal_card_track_0')));
      await tester.pumpAndSettle();
      final l10n = l10nOf(tester);

      // The track is audible, so `heard` is the shown segment. A toggle event
      // raised from it would mute the very thing the segment says is heard.
      await tester.tap(find.text(l10n.signalMixHeard));
      await tester.pumpAndSettle();

      verifyNever(() => bloc.add(const LooperMuteToggled(0)));
    });

    testWidgets('the monitor segment writes the mode', (tester) async {
      await pump(tester);
      await tester.tap(find.byKey(const Key('signal_card_input_0')));
      await tester.pumpAndSettle();
      final l10n = l10nOf(tester);

      expect(selectedLabel(tester, l10n.signalMonitorSegOff), isTrue);

      await tester.tap(find.text(l10n.signalMonitorSegOn));
      await tester.pumpAndSettle();

      expect(monitor.state.forInput(0).mode, MonitorMode.on);
      expect(selectedLabel(tester, l10n.signalMonitorSegOn), isTrue);
      expect(selectedLabel(tester, l10n.signalMonitorSegOff), isFalse);
    });

    testWidgets('the readout says what the level is', (tester) async {
      await pump(tester);
      await tester.tap(find.byKey(const Key('signal_card_input_0')));
      await tester.pumpAndSettle();

      // Unity gain, which is 0.0 dB and not "1.0" or a raw fraction.
      expect(find.text('0.0 dB'), findsOneWidget);
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

      // Two effects, so the ORDER the test is named for can actually fail.
      String chipText(int index) => tester
          .widget<Text>(
            find.descendant(
              of: find.byKey(Key('signal_panel_chip_$index')),
              matching: find.byType(Text),
            ),
          )
          .data!;

      expect(chipText(0), l10n.effectReverb);
      expect(chipText(1), l10n.effectTremolo);
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

  group('a selection outliving its card', () {
    testWidgets('a lane that goes takes its panel with it', (tester) async {
      final states = StreamController<LooperState>.broadcast();
      addTearDown(states.close);
      await pump(tester, stage: FxStage.loop, states: states.stream);
      await tester.tap(find.byKey(const Key('signal_card_loop_0_1')));
      await tester.pumpAndSettle();
      expect(panel(), findsOneWidget);

      // The track drops to one lane while lane B's panel is open.
      states.add(
        LooperState(
          tracks: [
            Track(
              volume: 0.5,
              lanes: const [Lane(inputChannel: 0, volume: 0.5)],
              effects: _rig.tracks.first.effects,
            ),
            const Track(channel: 1, lanes: [Lane(inputChannel: 1)]),
          ],
          status: _rig.status,
        ),
      );
      await tester.pumpAndSettle();

      // Not a dangling gap under the run: no card, no panel.
      expect(panel(), findsNothing);
      expect(find.byKey(const Key('signal_card_loop_0_1')), findsNothing);
    });

    testWidgets('a socket that goes takes its panel with it', (tester) async {
      final states = StreamController<LooperState>.broadcast();
      addTearDown(states.close);
      await pump(tester, states: states.stream);
      await tester.tap(find.byKey(const Key('signal_card_input_1')));
      await tester.pumpAndSettle();
      expect(panel(), findsOneWidget);

      // A two-in interface becomes a one-in one. `forInput` would happily
      // synthesize a monitor for socket 1 and the panel would write it to disk.
      states.add(
        LooperState(
          tracks: _rig.tracks,
          status: const EngineStatus(
            deviceName: 'Built-in',
            inputChannels: 1,
            outputChannels: 2,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(panel(), findsNothing);
    });
  });

  group('what a panel redraws for', () {
    test('a meter tick is not a reason to redraw', () {
      // The whole point: `Lane == Lane` is false on every audio frame, so the
      // panel cannot key its rebuild off the object.
      const quiet = Lane(inputChannel: 0, volume: 0.5);
      const loud = Lane(inputChannel: 0, volume: 0.5, rms: 0.8, peak: 0.9);
      expect(quiet == loud, isFalse);
      expect(sameLaneFacts(quiet, loud), isTrue);

      const bus = Track(volume: 0.5);
      const busLoud = Track(volume: 0.5, rms: 0.8, peak: 0.9);
      expect(bus == busLoud, isFalse);
      expect(sameTrackFacts(bus, busLoud), isTrue);
    });

    test('the three facts it draws are', () {
      const base = Lane(inputChannel: 0, volume: 0.5);
      expect(
        sameLaneFacts(base, const Lane(inputChannel: 0, volume: 0.6)),
        isFalse,
      );
      expect(
        sameLaneFacts(
          base,
          const Lane(inputChannel: 0, volume: 0.5, muted: true),
        ),
        isFalse,
      );
      expect(
        sameLaneFacts(
          base,
          Lane(
            inputChannel: 0,
            volume: 0.5,
            effects: [BuiltInEffect(type: TrackEffectType.drive)],
          ),
        ),
        isFalse,
      );
      // A lane that went away, and one that came back.
      expect(sameLaneFacts(base, null), isFalse);
      expect(sameLaneFacts(null, null), isTrue);
      expect(sameTrackFacts(null, const Track()), isFalse);
    });
  });

  group('the fader tells the truth', () {
    testWidgets("it holds the finger's value until the rig answers", (
      tester,
    ) async {
      await pump(tester);
      await tester.tap(find.byKey(const Key('signal_card_input_0')));
      await tester.pumpAndSettle();

      // The input path writes through MonitorCubit, which answers
      // synchronously — so the bar keeps the dragged value rather than
      // rubber-banding to the gain the rig reported before the drag.
      await tester.drag(
        find.byKey(const Key('signal_panel_level')),
        const Offset(-300, 0),
      );
      await tester.pumpAndSettle();

      final after = monitor.state.forInput(0).volume;
      expect(after, lessThan(1.0));
      expect(find.text(signalGainReadout(after)), findsOneWidget);
    });

    testWidgets('a silent rig keeps the move rather than undoing it', (
      tester,
    ) async {
      // A lane's volume only reaches the snapshot once the audio callback
      // drains the command queue — with no device running that never happens,
      // while the repository has cached the write and will apply it at the
      // next start. Falling back would animate away a setting that was kept.
      await pump(tester, stage: FxStage.track);
      await tester.tap(find.byKey(const Key('signal_card_track_0')));
      await tester.pumpAndSettle();

      await tester.drag(
        find.byKey(const Key('signal_panel_level')),
        const Offset(-300, 0),
      );
      await tester.pumpAndSettle();

      // Track 0 sits at 0.5 gain (−6.0 dB); the drag moved it below that and
      // it stays moved.
      expect(find.text(signalGainReadout(0.5)), findsNothing);
    });

    testWidgets('a rig that answers differently wins', (tester) async {
      final states = StreamController<LooperState>.broadcast();
      addTearDown(states.close);
      await pump(tester, stage: FxStage.track, states: states.stream);
      await tester.tap(find.byKey(const Key('signal_card_track_0')));
      await tester.pumpAndSettle();

      await tester.drag(
        find.byKey(const Key('signal_panel_level')),
        const Offset(-300, 0),
      );
      await tester.pump();

      // The rig clamps it somewhere else entirely.
      states.add(
        LooperState(
          tracks: [
            Track(volume: 0.25, lanes: _rig.tracks.first.lanes),
            _rig.tracks[1],
          ],
          status: _rig.status,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text(signalGainReadout(0.25)), findsOneWidget);
    });

    testWidgets('a reader nudge does not freeze the fader', (tester) async {
      final states = StreamController<LooperState>.broadcast();
      addTearDown(states.close);
      await pump(tester, stage: FxStage.track, states: states.stream);
      await tester.tap(find.byKey(const Key('signal_card_track_0')));
      await tester.pumpAndSettle();

      // Invoked the way a reader would: the increase handler the slider
      // publishes, not a gesture.
      final slider = tester.widget<Semantics>(
        find
            .ancestor(
              of: find.byKey(const Key('signal_panel_level')),
              matching: find.byType(Semantics),
            )
            .first,
      );
      slider.properties.onIncrease!();
      await tester.pumpAndSettle();

      // A nudge is press-and-lift in one, so the rig's own answer still lands
      // — otherwise the bar keeps the nudged number for the life of the panel.
      states.add(
        LooperState(
          tracks: [
            Track(volume: 0.25, lanes: _rig.tracks.first.lanes),
            _rig.tracks[1],
          ],
          status: _rig.status,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text(signalGainReadout(0.25)), findsOneWidget);
    });

    testWidgets("one card's drag does not show on the next", (tester) async {
      await pump(tester);
      await tester.tap(find.byKey(const Key('signal_card_input_0')));
      await tester.pumpAndSettle();
      await tester.drag(
        find.byKey(const Key('signal_panel_level')),
        const Offset(-400, 0),
      );
      await tester.pumpAndSettle();
      final moved = signalGainReadout(monitor.state.forInput(0).volume);

      await tester.tap(find.byKey(const Key('signal_card_input_1')));
      await tester.pumpAndSettle();

      // Input 1 is untouched, so it reads unity — not input 0's number.
      expect(find.text(moved), findsNothing);
      expect(find.text('0.0 dB'), findsOneWidget);
    });
  });

  // ------------------------------------------------ SIGNAL / fx-edit

  group('the FX editor', () {
    Future<void> openEditor(WidgetTester tester) async {
      await pump(tester, stage: FxStage.track);
      await tester.tap(find.byKey(const Key('signal_card_track_0')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('signal_panel_chip_0')));
      await tester.pumpAndSettle();
    }

    testWidgets('a chip opens the editor in place of level and in the mix', (
      tester,
    ) async {
      await pump(tester, stage: FxStage.track);
      await tester.tap(find.byKey(const Key('signal_card_track_0')));
      await tester.pumpAndSettle();
      final l10n = l10nOf(tester);

      expect(find.text(l10n.signalPanelLevel), findsOneWidget);
      expect(find.byKey(const Key('signal_fx_editor')), findsNothing);

      await tester.tap(find.byKey(const Key('signal_panel_chip_0')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('signal_fx_editor')), findsOneWidget);
      // You are looking at ONE effect now — how loud the whole chain is is a
      // question about the chain.
      expect(find.text(l10n.signalPanelLevel), findsNothing);
      expect(find.text(l10n.signalPanelInMix), findsNothing);
    });

    testWidgets('the monitor segment survives, because it is still true', (
      tester,
    ) async {
      await pump(tester);
      // An input's monitor chain is empty by default; give it something to
      // open.
      monitor.addEffect(0);
      await tester.tap(find.byKey(const Key('signal_card_input_0')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('signal_panel_chip_0')));
      await tester.pumpAndSettle();
      final l10n = l10nOf(tester);

      // Whether you hear the jack is still a fact while you edit its tone.
      expect(find.text(l10n.signalPanelHearWhilePlaying), findsOneWidget);
      expect(find.byKey(const Key('signal_panel_monitor')), findsOneWidget);
    });

    testWidgets('re-tapping the open chip hands back the chain', (
      tester,
    ) async {
      await openEditor(tester);
      await tester.tap(find.byKey(const Key('signal_panel_chip_0')));
      await tester.pumpAndSettle();
      final l10n = l10nOf(tester);

      // Shuts the editor, NOT the card — the editor is a link of the chain.
      expect(find.byKey(const Key('signal_fx_editor')), findsNothing);
      expect(panel(), findsOneWidget);
      expect(find.text(l10n.signalPanelLevel), findsOneWidget);
    });

    testWidgets('a param row per parameter, driving the chain', (tester) async {
      await openEditor(tester);

      // Reverb's own parameters, from the engine's metadata.
      expect(find.byKey(const Key('signal_fx_param_0')), findsOneWidget);

      await tester.tap(find.byKey(const Key('signal_fx_param_0')));
      await tester.pumpAndSettle();

      verify(
        () => bloc.add(any(that: isA<LooperBusEffectParamChanged>())),
      ).called(greaterThan(0));
    });

    testWidgets('bypass leaves the entry in the chain', (tester) async {
      await openEditor(tester);

      await tester.tap(find.byKey(const Key('signal_fx_bypass')));
      await tester.pumpAndSettle();

      // Power, not removal: the chip is still there.
      expect(find.byKey(const Key('signal_panel_chip_0')), findsOneWidget);
      verify(
        () => bloc.add(any(that: isA<LooperTrackEffectEnabledToggled>())),
      ).called(1);
    });

    testWidgets('the ends of the chain cannot be moved past', (tester) async {
      await openEditor(tester);

      // Chip 0 of a two-effect chain: nothing earlier to move to, but a
      // later slot exists.
      InkWell button(String key) =>
          tester.widget<InkWell>(find.byKey(Key(key)));

      expect(button('signal_fx_move_up').onTap, isNull);
      expect(button('signal_fx_move_down').onTap, isNotNull);

      await tester.tap(find.byKey(const Key('signal_fx_move_down')));
      await tester.pumpAndSettle();
      verify(
        () => bloc.add(any(that: isA<LooperBusEffectMoved>())),
      ).called(1);
    });

    testWidgets('removing closes the editor it was opened from', (
      tester,
    ) async {
      await openEditor(tester);

      await tester.tap(find.byKey(const Key('signal_fx_remove')));
      await tester.pumpAndSettle();

      // An editor cannot outlive what it edits.
      expect(find.byKey(const Key('signal_fx_editor')), findsNothing);
      expect(tray.state.signalEffect, isNull);
    });

    testWidgets('opening a different card closes the editor', (tester) async {
      await openEditor(tester);
      await tester.tap(find.byKey(const Key('signal_card_track_1')));
      await tester.pumpAndSettle();

      // The index means nothing against another chain.
      expect(find.byKey(const Key('signal_fx_editor')), findsNothing);
      expect(tray.state.signalEffect, isNull);
    });
  });

  group('a screen reader can work the face', () {
    testWidgets('a card is a button it can actually activate', (tester) async {
      final handle = tester.ensureSemantics();
      await pump(tester);

      final l10n = l10nOf(tester);
      final node = tester.getSemantics(
        find.byKey(const Key('signal_card_input_0')),
      );
      // Announced as a button AND carrying the tap action that activates it.
      // Silencing the whole subtree — the InkWell included — leaves a node
      // that says "button" and does nothing when double-tapped, which is the
      // panel being unreachable for anyone using assistive tech.
      // Carries the tap action that ACTIVATES it, not just the button flag:
      // silencing the whole subtree — the InkWell included — leaves a node
      // that says "button" and does nothing when double-tapped.
      expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
      // One node carrying the card's facts, not six loose texts.
      expect(node.label, contains(l10n.signalCoordInput(1)));
      expect(node.label, contains(l10n.signalMonitorOff));
      handle.dispose();
    });

    testWidgets('the chosen segment stays reachable', (tester) async {
      final handle = tester.ensureSemantics();
      await pump(tester);
      await tester.tap(find.byKey(const Key('signal_card_input_0')));
      await tester.pumpAndSettle();
      final l10n = l10nOf(tester);

      // The segment that says what the setting IS must still be focusable and
      // activatable: guarding the re-tap by nulling `onTap` would drop it out
      // of traversal, so the reader could never land on the current value.
      final chosen = tester.getSemantics(
        find
            .ancestor(
              of: find.text(l10n.signalMixHeard),
              matching: find.byType(Semantics),
            )
            .first,
      );
      expect(chosen.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
      handle.dispose();
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
