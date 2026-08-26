import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:routing_graph/routing_graph.dart';
import 'package:segno/audio_setup/cubit/inputs_cubit.dart';
import 'package:segno/audio_setup/cubit/monitor_cubit.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/cubit/settings_tray_cubit.dart';
import 'package:segno/looper/cubit/tracks_cubit.dart';
import 'package:segno/looper/view/fx_editor/fx_block_chip.dart';
import 'package:segno/looper/view/signal/fx_param_editor.dart';
import 'package:segno/looper/view/signal/signal_detail_panel.dart';
import 'package:segno/looper/view/signal/signal_tray_panel.dart';
import 'package:segno/looper/view/signal_graph/signal_style.dart';
import 'package:segno/theme/theme.dart';
import 'package:segno_engine/segno_engine.dart' as engine;
import 'package:settings_repository/settings_repository.dart';

import '../../../helpers/helpers.dart';

class _MockLooperBloc extends MockBloc<LooperEvent, LooperState>
    implements LooperBloc {}

class _MockLooperRepository extends Mock implements LooperRepository {}

/// A store whose recent-plugins read fails the way the real backends do.
///
/// An `ArgumentError`, not an `Exception`: `shared_preferences_foundation`
/// converts a platform argument failure into one on purpose, and the backends
/// cast the platform reply, so a corrupt stored value raises `TypeError`.
/// Both are `Error`s, so a catch narrowed to `Exception` misses them.
///
/// Scoped to the one key by asking the repository which it is, rather than
/// copying the string: a hardcoded key silently stops matching when the
/// repository renames it, and the test then passes because the read returned
/// null instead of throwing.
class _ThrowingStore extends FakeKeyValueStore {
  /// Whether the read under test actually failed.
  bool threw = false;

  @override
  Future<String?> getString(String key) async {
    if (key == SettingsRepository.recentPluginsKey) {
      threw = true;
      throw ArgumentError('no prefs here');
    }
    return super.getString(key);
  }
}

/// A store whose reads take a frame or two, as the appliance's platform
/// channel does.
///
/// The zero-latency fake makes the add dialog's re-entrancy window disappear
/// entirely, so a guard against double-opening cannot be tested against it —
/// the bug it prevents only exists when the read is slow.
class _SlowStore extends FakeKeyValueStore {
  @override
  Future<String?> getString(String key) async {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    return super.getString(key);
  }
}

/// A rig with a chain on every stage, so each panel has something to draw.
final _rig = LooperState(
  tracks: [
    Track(
      volume: 0.5,
      lanes: const [
        Lane(inputChannel: 0, volume: 0.5),
        Lane(inputChannel: 1),
      ],
      // Slot ids, because the editor names an entry by its identity — the
      // repository mints one at its write boundary, so anything the UI reads
      // back from state has them.
      effects: [
        BuiltInEffect(type: TrackEffectType.reverb, slotId: 'slot-reverb'),
        BuiltInEffect(type: TrackEffectType.tremolo, slotId: 'slot-tremolo'),
      ],
    ),
    const Track(channel: 1, lanes: [Lane(inputChannel: 1)]),
  ],
  masterEffects: [
    BuiltInEffect(type: TrackEffectType.drive, slotId: 'slot-master-drive'),
  ],
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
  late FakeAudioEngine catalogEngine;
  late _ThrowingStore throwingStore;
  late PluginCatalog catalog;

  /// What the fake repository has been told each input's monitor chain is,
  /// minted, so a read-back behaves like the real write boundary.
  final monitorChains = <int, List<TrackEffect>>{};

  setUpAll(() {
    registerFallbackValue(MonitorMode.off);
    registerFallbackValue(const LooperMuteToggled(0));
    registerFallbackValue(const <TrackEffect>[]);
  });

  setUp(() {
    monitorChains.clear();
    bloc = _MockLooperBloc();
    repository = _MockLooperRepository();
    when(() => repository.monitorChanges).thenAnswer(
      (_) => const Stream<int>.empty(),
    );
    when(() => repository.monitorParamChanges).thenAnswer(
      (_) => const Stream<int>.empty(),
    );
    when(
      () => repository.looperState,
    ).thenAnswer((_) => const Stream<LooperState>.empty());
    when(() => repository.state).thenReturn(_rig);
    when(repository.allMonitors).thenReturn(const {});
    // The add dialog reads the scan catalog for its shelf and its count. One
    // plugin that loaded and one file that did not — the failed entry keeps
    // an EMPTY id, so it must not be counted or offered.
    catalogEngine = FakeAudioEngine()
      ..pluginScanResults = const [
        engine.PluginDescriptor(
          id: 'plug.ok',
          name: 'Alpha',
          vendor: 'Acme',
          path: '/ok.vst3',
          format: engine.PluginFormat.vst3,
          version: 1,
        ),
        engine.PluginDescriptor(
          id: '',
          name: 'Broken.vst3',
          vendor: '',
          path: '/broken.vst3',
          format: engine.PluginFormat.vst3,
          version: 0,
        ),
      ];
    catalog = PluginCatalog(
      engine: catalogEngine,
      appVersion: 'test',
      pollInterval: const Duration(milliseconds: 1),
      statFile: (path) => (mtimeMs: 1, sizeBytes: 1),
    );
    when(() => repository.pluginCatalog).thenReturn(catalog);
    addTearDown(catalog.dispose);
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
      // The chain comes back MINTED, as the repository's write boundary does
      // it: the cubit re-reads after every push, and the panel names the entry
      // its editor is open on by slot id. A fake that answers with a bare list
      // hands back id-less entries, whose chips are inert — and every input-
      // stage test that opens one then quietly asserts nothing.
      () =>
          when(
            () => repository.setMonitorEffects(
              input: any(named: 'input'),
              effects: any(named: 'effects'),
            ),
          ).thenAnswer((call) {
            monitorChains[call.namedArguments[#input]
                as int] = withMintedSlotIds(
              call.namedArguments[#effects] as List<TrackEffect>,
            );
            return EngineResult.ok;
          }),
      // The panel offers a re-inherit only when the routed input has an
      // audible chain to copy; the fake says it does not.
      () => when(
        () => repository.laneCanInheritFromInput(any(), any()),
      ).thenReturn(false),
      () => when(
        () => repository.setMonitorChainEnabled(
          input: any(named: 'input'),
          enabled: any(named: 'enabled'),
        ),
      ).thenReturn(EngineResult.ok),
      () => when(() => repository.monitorEffects(any())).thenAnswer(
        (call) => monitorChains[call.positionalArguments.first] ?? const [],
      ),
    ]) {
      stub();
    }
  });

  Future<void> pump(
    WidgetTester tester, {
    FxStage stage = FxStage.input,
    LooperState? state,
    Stream<LooperState>? states,
    bool slowSettings = false,
    bool throwingSettings = false,
    // Sized HERE, because this sets the view itself: a test that assigns
    // `tester.view.physicalSize` before calling it has its size overwritten
    // and quietly runs at 1920x1080, which is exactly where the small-console
    // failures do not reproduce.
    Size size = const Size(1920, 1080),
  }) async {
    final rig = state ?? _rig;
    tester.view
      ..physicalSize = size
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    when(() => bloc.state).thenReturn(rig);
    whenListen(
      bloc,
      states ?? const Stream<LooperState>.empty(),
      initialState: rig,
    );

    settings = SettingsRepository(
      store: switch ((slowSettings, throwingSettings)) {
        (true, _) => _SlowStore(),
        (_, true) => throwingStore = _ThrowingStore(),
        _ => FakeKeyValueStore(),
      },
    );
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
        home: MultiRepositoryProvider(
          providers: [
            RepositoryProvider<LooperRepository>.value(value: repository),
            // The add dialog reads it for the recent-plugin shelf; the real
            // tray inherits it from `App`.
            RepositoryProvider<SettingsRepository>.value(value: settings),
          ],
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

    testWidgets('a lane explains itself in the words for a lane', (
      tester,
    ) async {
      await pump(tester, stage: FxStage.loop);
      await tester.tap(find.byKey(const Key('signal_card_loop_0_0')));
      await tester.pumpAndSettle();
      final l10n = l10nOf(tester);

      // Every explanation on this panel is per STAGE, and until now only the
      // input half was ever rendered: replacing all three ternaries with their
      // input variant left the whole suite green. The split is the decision
      // the ARB descriptions spend paragraphs defending — an input's monitor
      // neither records nor plays back, so "muted still records" there is not
      // imprecise, it describes a different control.
      for (final caption in [
        (l10n.signalPanelChain, l10n.signalPanelChainExplain),
        (l10n.signalPanelLevel, l10n.signalPanelLevelExplain),
        (l10n.signalPanelInMix, l10n.signalPanelInMixExplain),
      ]) {
        final button = find.descendant(
          of: find.ancestor(
            of: find.text(caption.$1),
            matching: find.byType(ConsoleCaption),
          ),
          matching: find.byKey(const Key('console_caption_explain')),
        );
        await tester.ensureVisible(button);
        await tester.pumpAndSettle();
        await tester.tap(button);
        await tester.pumpAndSettle();
        expect(find.text(caption.$2), findsOneWidget, reason: caption.$1);

        await tester.tap(find.byKey(const Key('console_caption_scrim')));
        await tester.pumpAndSettle();
      }
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

    testWidgets('a double tap on the level fader snaps it back to unity', (
      tester,
    ) async {
      await pump(tester);
      await tester.tap(find.byKey(const Key('signal_card_input_0')));
      await tester.pumpAndSettle();

      // A quarter along, deliberately NOT the centre — the centre of this bar
      // IS unity, so a reset there would be indistinguishable from the tap
      // that opened the window.
      final box = tester.getRect(find.byKey(const Key('signal_panel_level')));
      final spot = Offset(box.left + box.width / 4, box.center.dy);
      await tester.tapAt(spot);
      await tester.pumpAndSettle();
      expect(
        monitor.state.forInput(0).volume,
        moreOrLessEquals(kSignalMaxGain / 4, epsilon: 0.1),
      );
      // Explicitly past the window this tap opened. `pumpAndSettle` only
      // outlasts it by accident — it pumps in 100ms steps and the fill's own
      // animation happens to run 180 — so a shorter motion token would make
      // the pair below start one tap early and the test fail for a reason
      // that has nothing to do with the reset.
      await tester.pump(kDoubleTapTimeout * 2);

      // A bar has no numbers on it, so landing back on unity by dragging is
      // luck. The same tap twice, inside the double-tap window.
      await tester.tapAt(spot);
      await tester.pump(const Duration(milliseconds: 40));
      await tester.tapAt(spot);
      await tester.pumpAndSettle();

      expect(monitor.state.forInput(0).volume, moreOrLessEquals(1));
    });

    testWidgets('the reset confirms itself under the finger', (tester) async {
      final haptics = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'HapticFeedback.vibrate') {
            haptics.add(call.arguments as String? ?? '');
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );

      await pump(tester);
      await tester.tap(find.byKey(const Key('signal_card_input_0')));
      await tester.pumpAndSettle();

      final box = tester.getRect(find.byKey(const Key('signal_panel_level')));
      final spot = Offset(box.left + box.width / 4, box.center.dy);
      await tester.tapAt(spot);
      await tester.pumpAndSettle();
      await tester.pump(kDoubleTapTimeout * 2);
      expect(haptics, isEmpty);

      await tester.tapAt(spot);
      await tester.pump(const Duration(milliseconds: 40));
      await tester.tapAt(spot);
      await tester.pumpAndSettle();

      // A 0.25 → 0.5 snap is a small visible move on a bar someone is looking
      // away from. The same confirmation ConsoleValueBar gives.
      expect(haptics, isNotEmpty);
    });

    testWidgets('two taps far apart are two adjustments, not a reset', (
      tester,
    ) async {
      await pump(tester);
      await tester.tap(find.byKey(const Key('signal_card_input_0')));
      await tester.pumpAndSettle();

      final box = tester.getRect(find.byKey(const Key('signal_panel_level')));
      await tester.tapAt(Offset(box.left + box.width / 4, box.center.dy));
      await tester.pump(const Duration(milliseconds: 40));
      await tester.tapAt(Offset(box.left + box.width * 3 / 4, box.center.dy));
      await tester.pumpAndSettle();

      // Where the second tap was aimed, NOT unity: two taps further apart
      // than kDoubleTapSlop are never one double tap, and reading them as a
      // reset would throw the second one's position away.
      expect(
        monitor.state.forInput(0).volume,
        moreOrLessEquals(kSignalMaxGain * 3 / 4, epsilon: 0.1),
      );
      await tester.pump(kDoubleTapTimeout * 2);
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
          .widget<AppText>(
            find.descendant(
              of: find.byKey(Key('signal_panel_chip_$index')),
              matching: find.byType(AppText),
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

      // In the PANEL's strip: the card above it now names its chain too, so
      // an unscoped finder would pass on the card's summary alone.
      expect(
        find.descendant(
          of: find.byKey(const Key('signal_detail_panel')),
          matching: find.text(l10n.effectDrive),
        ),
        findsOneWidget,
      );
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

    testWidgets('a tile per parameter, and the editor drives the chain', (
      tester,
    ) async {
      await openEditor(tester);

      // Reverb's own parameters, from the engine's metadata.
      expect(find.byKey(const Key('signal_fx_param_0')), findsOneWidget);

      await tester.tap(find.byKey(const Key('signal_fx_param_0')));
      await tester.pumpAndSettle();
      // The tile opened the editor and wrote nothing on the way.
      verifyNever(
        () => bloc.add(any(that: isA<LooperBusEffectParamChanged>())),
      );

      final track = find.byKey(const Key('fxParamEditor_track'));
      await tester.tapAt(
        tester.getTopLeft(track) +
            Offset(tester.getSize(track).width * 0.75, 12),
      );
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
      expect(tray.state.signalEffectSlot, isNull);
    });

    testWidgets('opening a different card closes the editor', (tester) async {
      await openEditor(tester);
      await tester.tap(find.byKey(const Key('signal_card_track_1')));
      await tester.pumpAndSettle();

      // The index means nothing against another chain.
      expect(find.byKey(const Key('signal_fx_editor')), findsNothing);
      expect(tray.state.signalEffectSlot, isNull);
    });
  });

  group('the editor follows its entry', () {
    testWidgets('moving carries the editor to the new slot', (tester) async {
      await pump(tester, stage: FxStage.track);
      await tester.tap(find.byKey(const Key('signal_card_track_0')));
      await tester.pumpAndSettle();
      // Chip 1 (Tremolo) of [Reverb, Tremolo].
      await tester.tap(find.byKey(const Key('signal_panel_chip_1')));
      await tester.pumpAndSettle();
      expect(tray.state.signalEffectSlot, 'slot-tremolo');

      await tester.tap(find.byKey(const Key('signal_fx_move_up')));
      await tester.pumpAndSettle();

      // The selection does not move, because it never named a position: it
      // names the ENTRY, and the entry is the thing that moved. An index here
      // would have had to be rewritten by hand after every reorder, and a
      // missed rewrite left the editor describing whoever slid into the slot.
      expect(tray.state.signalEffectSlot, 'slot-tremolo');
      verify(
        () => bloc.add(any(that: isA<LooperBusEffectMoved>())),
      ).called(1);
    });

    testWidgets('a chain that empties hands the panel back', (tester) async {
      final states = StreamController<LooperState>.broadcast();
      addTearDown(states.close);
      await pump(tester, stage: FxStage.track, states: states.stream);
      await tester.tap(find.byKey(const Key('signal_card_track_0')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('signal_panel_chip_0')));
      await tester.pumpAndSettle();
      final l10n = l10nOf(tester);

      // Another surface strips the chain while the editor is open.
      states.add(
        LooperState(
          tracks: [
            Track(volume: 0.5, lanes: _rig.tracks.first.lanes),
            _rig.tracks[1],
          ],
          status: _rig.status,
        ),
      );
      await tester.pumpAndSettle();

      // Not a panel with no editor, no level, no mix and no chip to tap.
      expect(find.byKey(const Key('signal_fx_editor')), findsNothing);
      expect(tray.state.signalEffectSlot, isNull);
      expect(find.text(l10n.signalPanelLevel), findsOneWidget);
    });
  });

  group('the console explains its own controls', () {
    testWidgets('a caption answers what its controls do, in place', (
      tester,
    ) async {
      await pump(tester);
      await tester.tap(find.byKey(const Key('signal_card_input_0')));
      await tester.pumpAndSettle();
      final l10n = l10nOf(tester);

      // Nothing until asked: the explanation is for the person who does not
      // know yet, and a face that explains everything all the time is a face
      // nobody can scan.
      expect(find.text(l10n.signalPanelHearWhilePlayingExplain), findsNothing);
      final monitorShut = tester.getRect(
        find.byKey(const Key('signal_panel_monitor')),
      );

      await tester.tap(
        find.descendant(
          of: find.ancestor(
            of: find.text(l10n.signalPanelHearWhilePlaying),
            matching: find.byType(ConsoleCaption),
          ),
          matching: find.byKey(const Key('console_caption_explain')),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.text(l10n.signalPanelHearWhilePlayingExplain),
        findsOneWidget,
      );
      // Over the face, not wedged into it: the control it explains keeps its
      // place instead of being shoved down the panel by a paragraph. The row
      // merely EXISTING proves nothing — it exists either way — so this is
      // where it sits, before and after.
      expect(
        tester.getRect(find.byKey(const Key('signal_panel_monitor'))),
        monitorShut,
      );
    });

    testWidgets('asking again puts it away', (tester) async {
      await pump(tester);
      await tester.tap(find.byKey(const Key('signal_card_input_0')));
      await tester.pumpAndSettle();
      final l10n = l10nOf(tester);

      final button = find.descendant(
        of: find.ancestor(
          of: find.text(l10n.signalPanelInMix),
          matching: find.byType(ConsoleCaption),
        ),
        matching: find.byKey(const Key('console_caption_explain')),
      );
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.text(l10n.signalPanelInMixInputExplain), findsOneWidget);

      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.text(l10n.signalPanelInMixInputExplain), findsNothing);
    });

    testWidgets('each caption answers for itself', (tester) async {
      await pump(tester);
      await tester.tap(find.byKey(const Key('signal_card_input_0')));
      await tester.pumpAndSettle();
      final l10n = l10nOf(tester);

      await tester.tap(
        find.descendant(
          of: find.ancestor(
            of: find.text(l10n.signalPanelLevel),
            matching: find.byType(ConsoleCaption),
          ),
          matching: find.byKey(const Key('console_caption_explain')),
        ),
      );
      await tester.pumpAndSettle();

      // One caption opening must not open the others — four explanations at
      // once is the wall of text this replaces.
      expect(find.text(l10n.signalPanelLevelInputExplain), findsOneWidget);
      expect(find.text(l10n.signalPanelInMixInputExplain), findsNothing);
      expect(find.text(l10n.signalPanelHearWhilePlayingExplain), findsNothing);
    });

    testWidgets('every answer lands on the small console, whole', (
      tester,
    ) async {
      const console = Size(1024, 600);
      await pump(tester, size: console);
      await tester.tap(find.byKey(const Key('signal_card_input_0')));
      await tester.pumpAndSettle();
      final l10n = l10nOf(tester);

      // Every caption on the panel, top to bottom. The lowest is the one that
      // matters: anchored under its own row it ran to y=685 on a 600px screen,
      // and what fell off the bottom was the sentence about AUTO — the whole
      // reason that caption has an explanation.
      final captions = {
        l10n.signalPanelChain: l10n.signalPanelChainInputExplain,
        l10n.signalPanelLevel: l10n.signalPanelLevelInputExplain,
        l10n.signalPanelInMix: l10n.signalPanelInMixInputExplain,
        l10n.signalPanelHearWhilePlaying:
            l10n.signalPanelHearWhilePlayingExplain,
      };
      final screen = Offset.zero & console;

      for (final entry in captions.entries) {
        final button = find.descendant(
          of: find.ancestor(
            of: find.text(entry.key),
            matching: find.byType(ConsoleCaption),
          ),
          matching: find.byKey(const Key('console_caption_explain')),
        );
        // The panel is taller than this screen, so the lower captions are
        // reached by scrolling to them — which is also the only way the
        // caption that broke this could be tapped at all.
        await tester.ensureVisible(button);
        await tester.pumpAndSettle();
        await tester.tap(button);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: entry.key);

        // Above or below its caption, never across it. Clamping a paragraph
        // back onto the screen is not enough on its own: at the bottom of a
        // 600px face that puts the answer squarely over the caption and the
        // control it is about, so the answer flips to the other side instead.
        final answer = tester.getRect(
          find.byKey(const Key('console_caption_explanation')),
        );
        final caption = tester.getRect(button);
        expect(
          answer.bottom <= caption.top + 6 || answer.top >= caption.bottom - 6,
          isTrue,
          reason: '${entry.key}: $answer straddles its caption at $caption',
        );

        // The card, and the words in it. The card alone would pass with the
        // paragraph clipped inside it, and the words alone would pass with
        // them painted over the screen edge.
        for (final rect in [answer, tester.getRect(find.text(entry.value))]) {
          expect(
            screen.contains(rect.topLeft) && screen.contains(rect.bottomRight),
            isTrue,
            reason: '${entry.key}: $rect is not inside $console',
          );
        }

        // Dismissed from the barrier, not the caption: while an answer is up
        // the barrier is what a touch anywhere lands on, including on the `?`
        // that opened it.
        await tester.tap(find.byKey(const Key('console_caption_scrim')));
        await tester.pumpAndSettle();
        expect(find.text(entry.value), findsNothing, reason: entry.key);
      }
    });

    testWidgets('the question is the words, not the panel beside them', (
      tester,
    ) async {
      await pump(tester, size: const Size(1024, 600));
      await tester.tap(find.byKey(const Key('signal_card_input_0')));
      await tester.pumpAndSettle();
      final l10n = l10nOf(tester);

      final button = find.descendant(
        of: find.ancestor(
          of: find.text(l10n.signalPanelInMix),
          matching: find.byType(ConsoleCaption),
        ),
        matching: find.byKey(const Key('console_caption_explain')),
      );

      // The panel stretches its children, so a caption that does not shrink
      // to its own words is handed the whole width — 950px of mostly blank
      // panel, all of it opening an explanation. A tap aimed slightly high of
      // the segmented control below would spend itself on a paragraph, and
      // the next tap on dismissing it.
      final target = tester.getRect(button);
      final words = tester.getRect(find.text(l10n.signalPanelInMix));
      expect(target.width, lessThan(words.width + 60));

      // And the blank panel out at the trailing edge does nothing.
      await tester.tapAt(Offset(target.right + 300, target.center.dy));
      await tester.pumpAndSettle();
      expect(find.text(l10n.signalPanelInMixInputExplain), findsNothing);
    });

    testWidgets('the answer is on screen from its very first frame', (
      tester,
    ) async {
      await pump(tester);
      await tester.tap(find.byKey(const Key('signal_card_input_0')));
      await tester.pumpAndSettle();
      final l10n = l10nOf(tester);

      await tester.tap(
        find.descendant(
          of: find.ancestor(
            of: find.text(l10n.signalPanelInMix),
            matching: find.byType(ConsoleCaption),
          ),
          matching: find.byKey(const Key('console_caption_explain')),
        ),
      );

      // ONE frame, not `pumpAndSettle`: the anchor is measured when the answer
      // opens, and without that measurement the layout runs from `Rect.zero`
      // for a frame — a flash at the screen's top-left, then a jump down to
      // the caption. Settling first hides it completely.
      await tester.pump();
      final answer = tester.getRect(
        find.byKey(const Key('console_caption_explanation')),
      );
      final caption = tester.getRect(
        find.descendant(
          of: find.ancestor(
            of: find.text(l10n.signalPanelInMix),
            matching: find.byType(ConsoleCaption),
          ),
          matching: find.byKey(const Key('console_caption_explain')),
        ),
      );
      expect(answer.top, greaterThan(caption.top));
    });

    testWidgets('the chain keeps its power pill at the trailing edge', (
      tester,
    ) async {
      await pump(tester, size: const Size(1024, 600));
      await tester.tap(find.byKey(const Key('signal_card_input_0')));
      await tester.pumpAndSettle();

      // The caption's controls ride in its row so the answer can open under
      // them at full width. A row laid out from the leading edge would park
      // the power pill against the caption instead of at the panel's far
      // side, which is where every other domain's trailing control sits.
      final panel = tester.getRect(
        find.byKey(const Key('signal_detail_panel')),
      );
      final pill = tester.getRect(
        find.byKey(const Key('signal_panel_chain_power')),
      );
      expect(
        pill.right,
        closeTo(panel.right - SignalDetailPanel.padding + 1, 1),
      );
    });

    testWidgets('the question names the group it is about', (tester) async {
      final handle = tester.ensureSemantics();
      await pump(tester);
      await tester.tap(find.byKey(const Key('signal_card_input_0')));
      await tester.pumpAndSettle();
      final l10n = l10nOf(tester);

      // A row of identical "?" buttons tells a reader nothing about which
      // control each one belongs to.
      final node = tester.getSemantics(
        find.descendant(
          of: find.ancestor(
            of: find.text(l10n.signalPanelInMix),
            matching: find.byType(ConsoleCaption),
          ),
          matching: find.byKey(const Key('console_caption_explain')),
        ),
      );
      expect(node.label, contains(l10n.signalPanelInMix));
      handle.dispose();
    });
  });

  group('what the editor says about itself', () {
    testWidgets('a chain switched off says why nothing changed', (
      tester,
    ) async {
      await pump(tester, stage: FxStage.track);
      await tester.tap(find.byKey(const Key('signal_card_track_0')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('signal_panel_chip_0')));
      await tester.pumpAndSettle();

      // The rig's chain power is on, so no notice.
      expect(find.byKey(const Key('signal_fx_chain_off')), findsNothing);
    });

    testWidgets('a parameter is announced with the effect it belongs to', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pump(tester, stage: FxStage.track);
      await tester.tap(find.byKey(const Key('signal_card_track_0')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('signal_panel_chip_0')));
      await tester.pumpAndSettle();
      final l10n = l10nOf(tester);

      // A tile is 78px of mono at 9pt: what it can PRINT is a truncated name.
      // What it says out loud has to be the whole thing — "MIX" alone tells a
      // reader nothing about whose mix it is.
      final tile = tester.getSemantics(
        find.byKey(const Key('signal_fx_param_0')),
      );
      expect(tile.label, contains(l10n.effectReverb));

      await tester.tap(find.byKey(const Key('signal_fx_param_0')));
      await tester.pumpAndSettle();

      // And the editor's own breadcrumb says it in writing. Scoped to the
      // editor: the block chip and the panel title are still on screen above
      // it, so an unscoped finder passes with no breadcrumb at all.
      expect(
        find.descendant(
          of: find.byType(FxParamEditor),
          matching: find.textContaining(l10n.effectReverb),
        ),
        findsOneWidget,
      );
      handle.dispose();
    });
  });

  group('the add affordance', () {
    testWidgets('is the last chip, and is there on an empty chain', (
      tester,
    ) async {
      await pump(tester, stage: FxStage.track);
      // Track 1 carries no effects at all — the case where "put something on
      // it" matters most, and the one an early return used to hide.
      await tester.tap(find.byKey(const Key('signal_card_track_1')));
      await tester.pumpAndSettle();
      final l10n = l10nOf(tester);

      expect(find.byKey(const Key('signal_panel_chain_empty')), findsOneWidget);
      expect(find.byKey(const Key('signal_panel_add_chip')), findsOneWidget);
      expect(find.text(l10n.fxAddChip), findsOneWidget);
    });

    testWidgets('sits after the chain it will be added to', (tester) async {
      await pump(tester, stage: FxStage.track);
      await tester.tap(find.byKey(const Key('signal_card_track_0')));
      await tester.pumpAndSettle();

      // It lands at the end, so it sits at the end.
      final lastChip = tester.getTopLeft(
        find.byKey(const Key('signal_panel_chip_1')),
      );
      final add = tester.getTopLeft(
        find.byKey(const Key('signal_panel_add_chip')),
      );
      expect(add.dx, greaterThan(lastChip.dx));
    });

    testWidgets('opens the dialog, which names the chain and the place', (
      tester,
    ) async {
      await pump(tester, stage: FxStage.track);
      await tester.tap(find.byKey(const Key('signal_card_track_0')));
      await tester.pumpAndSettle();
      final l10n = l10nOf(tester);

      await tester.tap(find.byKey(const Key('signal_panel_add_chip')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('signal_add_effect')), findsOneWidget);
      expect(find.text(l10n.fxAddTitle), findsOneWidget);
      // Named, so there is no doubt which of three cards is being added to.
      final prose = tester.widget<AppText>(
        find
            .descendant(
              of: find.byKey(const Key('signal_add_effect')),
              matching: find.byType(AppText),
            )
            .at(1),
      );
      expect(prose.data, contains(l10n.trackName(const [], 0)));
    });

    testWidgets('a dialog opened mid-scan is not stuck looking', (
      tester,
    ) async {
      // A scan already in flight when the dialog opens — the appliance's
      // takes seconds, so this is "open it, close it, open it again".
      catalogEngine.pluginScanPending = true;
      await pump(tester, stage: FxStage.track);
      unawaited(catalog.scan());
      await tester.pump();
      await tester.tap(find.byKey(const Key('signal_card_track_0')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('signal_panel_add_chip')));
      await tester.pump();
      final l10n = l10nOf(tester);

      expect(find.text(l10n.fxAddScanning), findsOneWidget);

      // The scan lands. Skipping when one was already running left the dialog
      // subscribed to nothing: stuck on "Looking for plugins…" with its
      // browse row dead, recoverable only by closing and reopening.
      catalogEngine.pluginScanPending = false;
      await tester.pump(const Duration(milliseconds: 20));
      await tester.pumpAndSettle();

      expect(find.text(l10n.fxAddScanning), findsNothing);
      expect(find.text(l10n.fxAddBrowseAll(1)), findsOneWidget);
    });

    testWidgets('a dialog opened mid-RESCAN is not stuck looking either', (
      tester,
    ) async {
      // A scan has already completed once, so the cache is warm — which is
      // where the first version of this fix still stranded the dialog: it
      // returned early on the warm cache, subscribed to nothing, while its
      // build had already drawn "Looking for plugins…" off `isScanning`.
      await pump(tester, stage: FxStage.track);
      await tester.runAsync(catalog.scan);

      catalogEngine.pluginScanPending = true;
      unawaited(catalog.scan(rescan: true));
      await tester.pump();
      await tester.tap(find.byKey(const Key('signal_card_track_0')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('signal_panel_add_chip')));
      await tester.pump();
      final l10n = l10nOf(tester);

      expect(find.text(l10n.fxAddScanning), findsOneWidget);

      catalogEngine.pluginScanPending = false;
      await tester.pump(const Duration(milliseconds: 20));
      await tester.pumpAndSettle();

      expect(find.text(l10n.fxAddScanning), findsNothing);
      expect(find.text(l10n.fxAddBrowseAll(1)), findsOneWidget);
    });

    testWidgets('a rig with nothing loadable says so, and leads nowhere', (
      tester,
    ) async {
      catalogEngine.pluginScanResults = const [];
      await pump(tester, stage: FxStage.track);
      await tester.tap(find.byKey(const Key('signal_card_track_0')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('signal_panel_add_chip')));
      await tester.pump(const Duration(milliseconds: 20));
      await tester.pumpAndSettle();

      // The literal, not `l10n.fxAddBrowseAll(0)`: the widget resolves the
      // same lookup, so comparing the two passes for ANY wording, including
      // the "Browse all 0 plugins…" this exists to rule out. What is under
      // test is that the message has a `=0` branch at all.
      expect(find.text('No plugins available'), findsOneWidget);
      expect(find.textContaining('0 plugins'), findsNothing);
      final row = tester.widget<ConsoleRow>(
        find.descendant(
          of: find.byKey(const Key('signal_add_browse')),
          matching: find.byType(ConsoleRow),
        ),
      );
      expect(row.onTap, isNull);
    });

    testWidgets('a shelf read that throws still opens the dialog', (
      tester,
    ) async {
      await pump(tester, stage: FxStage.track, throwingSettings: true);
      await tester.tap(find.byKey(const Key('signal_card_track_0')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('signal_panel_add_chip')));
      await tester.pumpAndSettle();

      // A `MissingPluginException` is the likelier prefs failure, and the
      // shelf is a convenience — losing it must not lose the dialog, which
      // is what happened when the error escaped the `unawaited` call site.
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('signal_add_effect')), findsOneWidget);
      // The read really did fail — otherwise this passes for the wrong
      // reason the moment the key it watches stops matching.
      expect(throwingStore.threw, isTrue);
    });

    testWidgets('a rig with no plugins does not rescan on every open', (
      tester,
    ) async {
      catalogEngine.pluginScanResults = const [];
      await pump(tester, stage: FxStage.track);
      await tester.tap(find.byKey(const Key('signal_card_track_0')));
      await tester.pumpAndSettle();

      for (var open = 0; open < 3; open++) {
        await tester.tap(find.byKey(const Key('signal_panel_add_chip')));
        await tester.pump(const Duration(milliseconds: 20));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('signal_add_cancel')));
        await tester.pumpAndSettle();
      }

      // Gating on "did it FIND anything" walks the filesystem again on every
      // open of the default appliance, which has no plugins at all.
      // Exactly one: `lessThanOrEqualTo(1)` also passes at zero, so it would
      // survive the scan being deleted outright.
      expect(catalogEngine.pluginScanCount, 1);
    });

    testWidgets('a scan that lands while the dialog is open reaches it', (
      tester,
    ) async {
      await pump(tester, stage: FxStage.track);
      await tester.tap(find.byKey(const Key('signal_card_track_0')));
      await tester.pumpAndSettle();

      // Opened on a cold catalog: nothing has scanned yet.
      await tester.tap(find.byKey(const Key('signal_panel_add_chip')));
      await tester.pumpAndSettle();
      final l10n = l10nOf(tester);

      // The dialog does the looking itself and redraws when it finishes. A
      // fire-and-forget scan into a snapshot leaves the row reading zero for
      // as long as the dialog is open.
      await tester.runAsync(catalog.scan);
      await tester.pumpAndSettle();

      expect(find.text(l10n.fxAddBrowseAll(1)), findsOneWidget);
      expect(find.text(l10n.fxAddBrowseAll(0)), findsNothing);
    });

    testWidgets('the browse row counts only what loaded', (tester) async {
      await pump(tester, stage: FxStage.track);
      await tester.runAsync(catalog.scan);
      await tester.tap(find.byKey(const Key('signal_card_track_0')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('signal_panel_add_chip')));
      await tester.pumpAndSettle();
      final l10n = l10nOf(tester);

      // Two entries scanned, one of them a file that failed — offering it
      // would insert a `PluginRef` with no identity.
      expect(find.text(l10n.fxAddBrowseAll(1)), findsOneWidget);
      expect(find.text(l10n.fxAddBrowseAll(2)), findsNothing);
    });

    testWidgets('a built-in tap adds it and closes', (tester) async {
      await pump(tester, stage: FxStage.track);
      await tester.tap(find.byKey(const Key('signal_card_track_0')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('signal_panel_add_chip')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('signal_add_builtin_delay')));
      await tester.pumpAndSettle();

      // No confirm step: the tap IS the choice.
      expect(find.byKey(const Key('signal_add_effect')), findsNothing);
      verify(
        () => bloc.add(any(that: isA<LooperBusEffectAdded>())),
      ).called(1);
    });
  });

  group('the add dialog on the smallest screen', () {
    testWidgets('fits a 1024x600 console, shelf and all', (tester) async {
      await pump(tester, stage: FxStage.track, size: const Size(1024, 600));
      await tester.tap(find.byKey(const Key('signal_card_track_0')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('signal_panel_add_chip')));
      await tester.pumpAndSettle();

      // Two pixels short of the grid's four columns and it falls to two,
      // doubling the dialog's height and overflowing the shortest screen the
      // console ships on.
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('signal_add_effect')), findsOneWidget);
      expect(find.byKey(const Key('signal_add_cancel')), findsOneWidget);

      // Nothing to scroll: a `SingleChildScrollView` can never overflow, so
      // `takeException` proves nothing here — what matters is that the whole
      // dialog fits without one.
      final scroller = tester.widget<Scrollable>(
        find.descendant(
          of: find.byKey(const Key('signal_add_effect')),
          matching: find.byType(Scrollable),
        ),
      );
      expect(
        tester
            .state<ScrollableState>(find.byWidget(scroller))
            .position
            .maxScrollExtent,
        0,
      );

      // FOUR across, which is what makes it fit: the grid needs 694 for four
      // columns, and two pixels short it falls to two and doubles in height.
      final first = tester.getTopLeft(
        find.byKey(const Key('signal_add_builtin_drive')),
      );
      final fourth = tester.getTopLeft(
        find.byKey(const Key('signal_add_builtin_tremolo')),
      );
      expect(fourth.dy, first.dy);
    });

    testWidgets('one tap, one dialog', (tester) async {
      await pump(tester, stage: FxStage.track, slowSettings: true);
      await tester.tap(find.byKey(const Key('signal_card_track_0')));
      await tester.pumpAndSettle();

      // Two taps inside the settings round-trip. On the appliance that read
      // is a real platform hop, so without a guard the second tap stacks a
      // second dialog and the effect gets added twice.
      //
      // Both taps are dispatched at the SAME location before pumping: tapping
      // twice with a pump between lets the first dialog cover the chip, and
      // the second tap silently misses — which is what made the first version
      // of this test pass with the guard deleted.
      final chip = tester.getCenter(
        find.byKey(const Key('signal_panel_add_chip')),
      );
      await tester.tapAt(chip);
      await tester.pump(const Duration(milliseconds: 10));
      await tester.tapAt(chip);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('signal_add_effect')), findsOneWidget);
    });
  });

  group('the chain reorders by dragging', () {
    /// Whether the rows below the chain are showing.
    ///
    /// Their ROOM is kept while a drag is up, so their presence in the tree
    /// says nothing — only this does.
    bool tailShowing(WidgetTester tester) => tester
        .widget<Visibility>(find.byKey(const Key('signal_panel_tail')))
        .visible;

    /// Whether the add chip is showing. It keeps its ROOM while a drag is up,
    /// so its presence in the tree says nothing — only this does.
    bool addShowing(WidgetTester tester) => tester
        .widget<Visibility>(find.byKey(const Key('signal_panel_add_room')))
        .visible;

    /// A rig whose first track carries [effects] and nothing else.
    LooperState chainOf(List<TrackEffect> effects) => LooperState(
      tracks: [
        Track(
          volume: 0.5,
          lanes: const [Lane(inputChannel: 0), Lane(inputChannel: 1)],
          effects: effects,
        ),
      ],
      status: _rig.status,
    );

    /// Three entries, so a move can be wrong by one and still land somewhere:
    /// with two, every legal move is to 0 or 1 and an off-by-one
    /// normalisation is indistinguishable from a correct one.
    final three = chainOf([
      BuiltInEffect(type: TrackEffectType.reverb, slotId: 'slot-a'),
      BuiltInEffect(type: TrackEffectType.tremolo, slotId: 'slot-b'),
      BuiltInEffect(type: TrackEffectType.drive, slotId: 'slot-c'),
    ]);

    /// The rect of the chip at [chip], wherever it currently is.
    ///
    /// The lifted chip answers to its ghost key: the InkWell is swapped out
    /// for `childWhenDragging` while it is in the air.
    Rect chipRect(WidgetTester tester, int chip) {
      final chipAt = find.byKey(Key('signal_panel_chip_$chip'));
      return tester.getRect(
        chipAt.evaluate().isEmpty
            ? find.byKey(Key('signal_panel_ghost_$chip'))
            : chipAt,
      );
    }

    /// A point on one half of the chip at [chip] — the insertion point on
    /// that side of it.
    Offset half(WidgetTester tester, int chip, {required bool leading}) {
      final box = chipRect(tester, chip);
      return Offset(
        leading ? box.left + box.width * 0.25 : box.right - box.width * 0.25,
        box.center.dy,
      );
    }

    /// Picks the chip at [from] up and holds it over a half of chip [over] —
    /// its leading half unless [leading] says otherwise.
    ///
    /// Returns the live gesture: the drop is a separate step because half of
    /// what is under test happens WHILE the entry is held.
    Future<TestGesture> lift(
      WidgetTester tester, {
      required int from,
      required int over,
      bool leading = true,
    }) async {
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(Key('signal_panel_chip_$from'))),
      );
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      await gesture.moveTo(half(tester, over, leading: leading));
      await tester.pump();
      return gesture;
    }

    testWidgets('a press lifts an entry and a drop moves it', (tester) async {
      await pump(tester, stage: FxStage.track, state: three);
      await tester.tap(find.byKey(const Key('signal_card_track_0')));
      await tester.pumpAndSettle();

      final gesture = await lift(tester, from: 0, over: 2, leading: false);
      await gesture.up();
      await tester.pumpAndSettle();

      // Gap 3 is past the last entry, and the entry leaving position 0 slides
      // everything after it down: the destination is 2, not 3. Off by one and
      // the entry stops one short of where it was dropped, every time.
      final moved =
          verify(
                () => bloc.add(captureAny(that: isA<LooperBusEffectMoved>())),
              ).captured.single
              as LooperBusEffectMoved;
      expect(moved.from, 0);
      expect(moved.to, 2);
    });

    testWidgets('dropping where it already is does nothing', (tester) async {
      await pump(tester, stage: FxStage.track, state: three);
      await tester.tap(find.byKey(const Key('signal_card_track_0')));
      await tester.pumpAndSettle();

      // The near side of entry 2 is the far side of entry 1 — the place
      // entry 1 already occupies, named from the other chip.
      final gesture = await lift(tester, from: 1, over: 2);
      await tester.pump();
      // Not even marked: there is no landing place to show.
      expect(find.byKey(const Key('signal_panel_mark_2')), findsNothing);
      await gesture.up();
      await tester.pumpAndSettle();

      verifyNever(() => bloc.add(any(that: isA<LooperBusEffectMoved>())));
    });

    testWidgets('while an entry is held the panel is the chain alone', (
      tester,
    ) async {
      await pump(tester, stage: FxStage.track, state: three);
      await tester.tap(find.byKey(const Key('signal_card_track_0')));
      await tester.pumpAndSettle();
      expect(tailShowing(tester), isTrue);

      final gesture = await lift(tester, from: 0, over: 1, leading: false);

      // Level and `in the mix` go: they are questions about the chain, and
      // one of its entries is in the air. Hidden and untappable, but their
      // ROOM is kept — see `the strip stays put under the finger`.
      expect(tailShowing(tester), isFalse);
      await tester.tap(
        find.byKey(const Key('signal_panel_in_mix')),
        warnIfMissed: false,
      );
      await tester.pump();
      verifyNever(() => bloc.add(any(that: isA<LooperMuteToggled>())));
      // The chain itself is still all there — the entry being carried keeps
      // its place in the run as a ghost, so the chips around it do not slide
      // out from under the finger the moment the drag begins.
      expect(find.byKey(const Key('signal_panel_chip_1')), findsOneWidget);
      // And the place it would land is marked — on the chip the pointer is
      // over, painted, not laid out.
      expect(find.byKey(const Key('signal_panel_mark_2')), findsOneWidget);

      await gesture.up();
      await tester.pumpAndSettle();
      // And it comes back: a drop is not a way to lose the rest of the panel.
      expect(tailShowing(tester), isTrue);
    });

    testWidgets('a cancelled drag leaves the chain alone', (tester) async {
      await pump(tester, stage: FxStage.track, state: three);
      await tester.tap(find.byKey(const Key('signal_card_track_0')));
      await tester.pumpAndSettle();

      final gesture = await lift(tester, from: 0, over: 1, leading: false);
      await gesture.cancel();
      await tester.pumpAndSettle();

      verifyNever(() => bloc.add(any(that: isA<LooperBusEffectMoved>())));
      expect(tailShowing(tester), isTrue);
    });

    testWidgets('the entry that moves is the one under the finger', (
      tester,
    ) async {
      // Four entries and a live state stream, so the chain can change while
      // the drag is up — another surface removing an effect, a record-time
      // snapshot rewriting the lane.
      final states = StreamController<LooperState>();
      addTearDown(states.close);
      final four = chainOf([
        BuiltInEffect(type: TrackEffectType.reverb, slotId: 'slot-a'),
        BuiltInEffect(type: TrackEffectType.tremolo, slotId: 'slot-b'),
        BuiltInEffect(type: TrackEffectType.drive, slotId: 'slot-c'),
        BuiltInEffect(type: TrackEffectType.filter, slotId: 'slot-d'),
      ]);
      await pump(
        tester,
        stage: FxStage.track,
        state: four,
        states: states.stream,
      );
      await tester.tap(find.byKey(const Key('signal_card_track_0')));
      await tester.pumpAndSettle();

      // Lift C, at index 2.
      final gesture = await lift(tester, from: 2, over: 0);

      // A goes while C is held: C is index 1 now, not 2.
      states.add(chainOf(four.tracks.first.effects.sublist(1)));
      await tester.pump();

      // Off the run and back onto the head of the shortened chain. Moved
      // rather than held still: Flutter re-tests what is under a pointer only
      // when the pointer moves, so a finger that freezes at the exact moment
      // the chain changes drops on nothing — a no-op, not a wrong move.
      await gesture.moveTo(
        tester.getCenter(find.byKey(const Key('signal_detail_panel'))),
      );
      await tester.pump();
      await gesture.moveTo(half(tester, 0, leading: true));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      // Flutter snapshots a draggable's payload when the drag begins and
      // never revisits it, so an INDEX in there is stale by now: the drop
      // would have moved D, the entry that slid into position 2, while C sat
      // still under the finger. The payload is the slot id, resolved against
      // the chain at the moment of the drop — C is at 1 now, and 1 is what
      // moves.
      final moved =
          verify(
                () => bloc.add(captureAny(that: isA<LooperBusEffectMoved>())),
              ).captured.single
              as LooperBusEffectMoved;
      expect(moved.from, 1);
      expect(moved.to, 0);
    });

    testWidgets('a chain re-identified mid-drag still lets go', (tester) async {
      final states = StreamController<LooperState>();
      addTearDown(states.close);
      await pump(
        tester,
        stage: FxStage.track,
        state: three,
        states: states.stream,
      );
      await tester.tap(find.byKey(const Key('signal_card_track_0')));
      await tester.pumpAndSettle();

      final gesture = await lift(tester, from: 0, over: 1, leading: false);

      // Every slot id changes — what `withFreshSlotIds` does when a recording
      // inherits the monitor chain onto the lane. The chips are keyed by id,
      // so the one being carried is torn down and rebuilt.
      states.add(
        chainOf([
          for (final (i, e) in three.tracks.first.effects.indexed)
            BuiltInEffect(type: (e as BuiltInEffect).type, slotId: 'fresh-$i'),
        ]),
      );
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      // `onDragEnd` is gated on the chip still being MOUNTED, so hanging the
      // reset off it left the panel folded into drag mode for good — no level
      // row, no editor, no add chip, recoverable only by closing the card.
      expect(tailShowing(tester), isTrue);
      expect(find.byKey(const Key('signal_panel_mark_0')), findsNothing);
    });

    testWidgets('one entry travels at a time', (tester) async {
      await pump(tester, stage: FxStage.track, state: three);
      await tester.tap(find.byKey(const Key('signal_card_track_0')));
      await tester.pumpAndSettle();

      final first = await lift(tester, from: 0, over: 1, leading: false);
      final second = await tester.startGesture(
        tester.getCenter(find.byKey(const Key('signal_panel_chip_2'))),
      );
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      await second.moveTo(half(tester, 1, leading: true));
      await tester.pump();

      // The second chip does not lift. Both drops would be expressed against
      // the chain as it is drawn now, and the rewrite only lands on the bloc
      // round-trip — so the second, released a frame after the first, moves an
      // entry from a position the first drop has already invalidated. Nothing
      // here could speculatively apply the first move to make the second
      // one's coordinates true, so only one entry travels.
      expect(find.byKey(const Key('signal_panel_lift')), findsOneWidget);

      await first.up();
      await second.up();
      await tester.pumpAndSettle();

      verify(() => bloc.add(any(that: isA<LooperBusEffectMoved>()))).called(1);
      expect(tailShowing(tester), isTrue);
    });

    testWidgets('the strip stays put under the finger on a small console', (
      tester,
    ) async {
      await pump(
        tester,
        stage: FxStage.track,
        state: three,
        size: const Size(1024, 600),
      );
      await tester.tap(find.byKey(const Key('signal_card_track_0')));
      await tester.pumpAndSettle();

      // Down to the bottom, which is the only way to be touching the chain at
      // all on a console this size.
      await tester.drag(
        find.byKey(const Key('signal_detail_panel')),
        const Offset(0, -600),
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();
      final before = tester.getCenter(
        find.byKey(const Key('signal_panel_chip_0')),
      );

      final gesture = await tester.startGesture(before);
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      await tester.pump();

      // Hiding the rows below the chain WITHOUT keeping their room shortens
      // the panel, the scroll view clamps, and the whole strip is dragged up
      // to 180px out from under the finger the instant the press lands — a
      // release where the chip was picked up then hits a track card.
      final after = tester.getCenter(
        find.byKey(const Key('signal_panel_ghost_0')),
      );
      expect(after.dy, moreOrLessEquals(before.dy, epsilon: 1));

      await gesture.up();
      await tester.pumpAndSettle();
    });

    testWidgets('two presses in one frame still leave one drag standing', (
      tester,
    ) async {
      await pump(tester, stage: FxStage.track, state: three);
      await tester.tap(find.byKey(const Key('signal_card_track_0')));
      await tester.pumpAndSettle();

      // Both presses mature in the SAME frame, so the second chip's
      // recogniser fires before the rebuild that would have disarmed it —
      // the one race the build-time gate cannot close.
      final first = await tester.startGesture(
        tester.getCenter(find.byKey(const Key('signal_panel_chip_0'))),
      );
      final second = await tester.startGesture(
        tester.getCenter(find.byKey(const Key('signal_panel_chip_2'))),
      );
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      await tester.pump();

      // Both are carried somewhere and both released — the corruption case.
      // A over the end of the run, C over the head of it.
      await first.moveTo(half(tester, 2, leading: false));
      await second.moveTo(half(tester, 0, leading: true));
      await tester.pump();

      // The refused entry marks nothing. Flutter drives `onMove` on every
      // entered target, including one that already declined the data, so an
      // ungated strip painted a landing place for a move it would never make.
      expect(find.byKey(const Key('signal_panel_mark_0')), findsNothing);

      await first.up();
      await tester.pump();

      // The first drag ending must not clear a mode the second one owns: the
      // gaps would go while a finger was still carrying an entry, and that
      // drag could then only be abandoned.
      expect(tailShowing(tester), isFalse);

      await second.up();
      await tester.pumpAndSettle();
      expect(tailShowing(tester), isTrue);

      // And only ONE of them is placed — the first, where ITS finger was.
      // Each drop is expressed against the chain as drawn, and the rewrite
      // only lands on the bloc round-trip, so a second drop lands on a chain
      // the first has already changed: taken together the two moved A, which
      // the second finger never touched, and left the chain as it started.
      final moved =
          verify(
                () => bloc.add(captureAny(that: isA<LooperBusEffectMoved>())),
              ).captured.single
              as LooperBusEffectMoved;
      expect(moved.from, 0);
      expect(moved.to, 2);
    });

    testWidgets('the other release order also leaves one drag standing', (
      tester,
    ) async {
      await pump(tester, stage: FxStage.track, state: three);
      await tester.tap(find.byKey(const Key('signal_card_track_0')));
      await tester.pumpAndSettle();

      final first = await tester.startGesture(
        tester.getCenter(find.byKey(const Key('signal_panel_chip_0'))),
      );
      final second = await tester.startGesture(
        tester.getCenter(find.byKey(const Key('signal_panel_chip_2'))),
      );
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      await tester.pump();

      // The SECOND finger lets go first. Following one slot rather than the
      // set left the panel naming only the last drag to start: the first
      // entry was still in the air, and the strip unfolded around it — gaps
      // gone, add chip back, the level fader live again under a chip nobody
      // could drop, and a third chip liftable on top of it.
      await second.up();
      await tester.pump();
      expect(tailShowing(tester), isFalse);
      expect(addShowing(tester), isFalse);

      await first.up();
      await tester.pumpAndSettle();
      expect(tailShowing(tester), isTrue);
    });

    testWidgets('a control already under a finger stops when a chip lifts', (
      tester,
    ) async {
      await pump(tester, stage: FxStage.track, state: three);
      await tester.tap(find.byKey(const Key('signal_card_track_0')));
      await tester.pumpAndSettle();

      // One finger working the level row...
      final fader = await tester.startGesture(
        tester.getCenter(find.byKey(const Key('signal_panel_level'))),
      );
      await fader.moveBy(const Offset(40, 0));
      await tester.pump();
      verify(
        () => bloc.add(any(that: isA<LooperVolumeChanged>())),
      ).called(greaterThan(0));

      // ...while another lifts a chip.
      final chip = await tester.startGesture(
        tester.getCenter(find.byKey(const Key('signal_panel_chip_0'))),
      );
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      await tester.pump();

      await fader.moveBy(const Offset(60, 0));
      await tester.pump();
      await fader.up();
      await tester.pump();

      // Hiding the tail stops new touches and nothing else: `Visibility`
      // ignores POINTERS, so a recogniser that already owns one goes on
      // reporting to a control that is no longer on screen.
      verifyNever(() => bloc.add(any(that: isA<LooperVolumeChanged>())));

      await chip.up();
      await tester.pumpAndSettle();
    });

    testWidgets('a chain that wraps does not change the panel height', (
      tester,
    ) async {
      // Seven entries and a `+ effect` need two rows at 1024 wide; seven
      // entries alone need one. Removing the add chip when the drag starts
      // would therefore empty a row.
      await pump(
        tester,
        stage: FxStage.track,
        size: const Size(1024, 600),
        state: chainOf([
          for (final (i, type) in [
            TrackEffectType.reverb,
            TrackEffectType.tremolo,
            TrackEffectType.drive,
            TrackEffectType.filter,
            TrackEffectType.delay,
            TrackEffectType.echo,
            TrackEffectType.octaver,
          ].indexed)
            BuiltInEffect(type: type, slotId: 'slot-$i'),
        ]),
      );
      await tester.tap(find.byKey(const Key('signal_card_track_0')));
      await tester.pumpAndSettle();
      final before = tester
          .getSize(find.byKey(const Key('signal_detail_panel')))
          .height;

      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const Key('signal_panel_chip_0'))),
      );
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      await tester.pump();

      // A row lost here is 43px off the panel, and the panel is the last
      // thing in a scroll view: on a console scrolled down far enough to be
      // touching the chain at all, the position clamps and the whole run
      // slides — further than a chip is tall, so a drag along the line you
      // pressed on lands on nothing and the entry springs back unexplained.
      // The rows below keep their room for the same reason.
      expect(
        tester.getSize(find.byKey(const Key('signal_detail_panel'))).height,
        before,
      );

      await gesture.up();
      await tester.pumpAndSettle();
    });

    testWidgets('a drag does not undo what the fader was holding', (
      tester,
    ) async {
      await pump(tester, stage: FxStage.track, state: three);
      await tester.tap(find.byKey(const Key('signal_card_track_0')));
      await tester.pumpAndSettle();

      await tester.drag(
        find.byKey(const Key('signal_panel_level')),
        const Offset(-300, 0),
      );
      await tester.pumpAndSettle();
      // Track 0 sits at 0.5 gain; the rig is silent, so the fader is holding
      // the moved value on its own.
      expect(find.text(signalGainReadout(0.5)), findsNothing);

      final gesture = await lift(tester, from: 0, over: 1, leading: false);
      await gesture.up();
      await tester.pumpAndSettle();

      // Tearing the whole tail down to dispose its recognisers takes the
      // fader's held value with it, and the bar snaps back to a gain the
      // engine no longer has — undoing a setting by reordering an effect.
      expect(find.text(signalGainReadout(0.5)), findsNothing);
    });

    testWidgets('an effect is not deleted by a finger the fold hid', (
      tester,
    ) async {
      await pump(tester, stage: FxStage.track, state: three);
      await tester.tap(find.byKey(const Key('signal_card_track_0')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('signal_panel_chip_1')));
      await tester.pumpAndSettle();

      // A finger comes down on Remove...
      final remove = await tester.startGesture(
        tester.getCenter(find.byKey(const Key('signal_fx_remove'))),
      );
      // ...and before it lifts, another one picks up a chip.
      final chip = await tester.startGesture(
        tester.getCenter(find.byKey(const Key('signal_panel_chip_0'))),
      );
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      await tester.pump();
      await remove.up();
      await tester.pump();

      // The worst of the family: an entry deleted while the user was dragging
      // an unrelated one, with no editor on screen and nothing said.
      verifyNever(() => bloc.add(any(that: isA<LooperBusEffectRemoved>())));

      await chip.up();
      await tester.pumpAndSettle();
    });

    testWidgets('a chip is a button a screen reader can activate', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pump(tester, stage: FxStage.track, state: three);
      await tester.tap(find.byKey(const Key('signal_card_track_0')));
      await tester.pumpAndSettle();

      final node = tester.getSemantics(
        find.byKey(const Key('signal_panel_chip_1')),
      );
      // The drag wraps the chip in a draggable, and excluding THAT subtree
      // rather than just the drawing takes the InkWell's tap with it: the
      // chip then announces as a button that does nothing when double-tapped,
      // and the FX editor is unreachable from assistive tech.
      expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
      expect(
        node.label,
        fxBlockName(l10nOf(tester), three.tracks.first.effects[1]),
      );
      handle.dispose();
    });

    testWidgets('a drop lands from a fingers width off the gap', (
      tester,
    ) async {
      await pump(tester, stage: FxStage.track, state: three);
      await tester.tap(find.byKey(const Key('signal_card_track_0')));
      await tester.pumpAndSettle();

      final gesture = await lift(tester, from: 0, over: 1, leading: false);
      // Anywhere on the half counts, right up to the chip's own edge. The
      // targets used to be 5px gaps between the chips, with the chips
      // themselves accepting nothing — so a near miss was not a wrong move,
      // it was silence: the entry sprang back and the console gave no reason
      // why. A half chip is an order of magnitude more to aim at.
      final box = tester.getRect(find.byKey(const Key('signal_panel_chip_1')));
      await gesture.moveTo(Offset(box.right - 2, box.center.dy));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      verify(
        () => bloc.add(any(that: isA<LooperBusEffectMoved>())),
      ).called(1);
    });

    testWidgets('one chip cannot be lifted twice at once', (tester) async {
      await pump(tester, stage: FxStage.track, state: three);
      await tester.tap(find.byKey(const Key('signal_card_track_0')));
      await tester.pumpAndSettle();

      final first = await lift(tester, from: 0, over: 1, leading: false);
      // On the ghost: the chip it was lifted from keeps its place in the run,
      // and a second finger lands on exactly that.
      final second = await tester.startGesture(
        tester.getCenter(find.byKey(const Key('signal_panel_ghost_0'))),
      );
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      await tester.pump();

      // Both pointers are on the SAME chip, so both would carry the same slot
      // id — and the set the strip tracks cannot tell them apart. The first
      // release would then unfold the panel while the second finger was still
      // holding something, and that drag could only be abandoned.
      expect(find.byKey(const Key('signal_panel_lift')), findsOneWidget);

      await first.up();
      await second.up();
      await tester.pumpAndSettle();
      expect(tailShowing(tester), isTrue);
    });

    testWidgets('a tap still opens the editor rather than lifting', (
      tester,
    ) async {
      await pump(tester, stage: FxStage.track, state: three);
      await tester.tap(find.byKey(const Key('signal_card_track_0')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('signal_panel_chip_1')));
      await tester.pumpAndSettle();

      // The press is what distinguishes a move from a tap. A plain drag
      // recogniser would have swallowed this on a touch console.
      expect(tray.state.signalEffectSlot, 'slot-b');
      expect(tailShowing(tester), isTrue);
    });
  });

  group('a missing plugin is not a dead end', () {
    /// A track whose chain is [effects].
    LooperState busWith(List<TrackEffect> effects) => LooperState(
      tracks: [
        Track(
          volume: 0.5,
          lanes: const [Lane(inputChannel: 0)],
          effects: effects,
        ),
      ],
      status: _rig.status,
    );

    const moved = PluginEffect(
      ref: PluginRef(format: PluginFormat.vst3, id: 'moved.vst3'),
      name: 'Moved',
      slotId: 'slot-moved',
      unavailable: true,
    );

    testWidgets('relinking points the entry at an installed plugin', (
      tester,
    ) async {
      await pump(tester, stage: FxStage.track, state: busWith(const [moved]));
      await tester.tap(find.byKey(const Key('signal_card_track_0')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('signal_panel_chip_0')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('signal_fx_relink')));
      await tester.pumpAndSettle();
      // The same sheet the add dialog browses with — everything the scan
      // found, not a second list that could disagree with it.
      await tester.tap(find.byKey(const Key('signal_browse_plug.ok')));
      await tester.pumpAndSettle();

      // Relinked, NOT removed and re-added: the entry keeps the state that
      // `PluginEffect.state` exists to preserve, which is the whole reason
      // this is worth reaching.
      final event =
          verify(
                () =>
                    bloc.add(captureAny(that: isA<LooperBusPluginRelinked>())),
              ).captured.single
              as LooperBusPluginRelinked;
      expect(event.index, 0);
      expect(event.ref.id, 'plug.ok');
      verifyNever(() => bloc.add(any(that: isA<LooperBusEffectRemoved>())));
    });

    testWidgets('it relinks the entry it was opened on, not a position', (
      tester,
    ) async {
      await pump(tester, stage: FxStage.track, state: busWith(const [moved]));
      await tester.tap(find.byKey(const Key('signal_card_track_0')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('signal_panel_chip_0')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('signal_fx_relink')));
      await tester.pumpAndSettle();

      // The chain is rewritten while the picker is open — a record pass
      // snapshotting the monitor chain onto the lane, another surface adding
      // an entry. The editor was opened on position 0; a DIFFERENT plugin is
      // there now.
      when(() => bloc.state).thenReturn(
        busWith(const [
          PluginEffect(
            ref: PluginRef(format: PluginFormat.vst3, id: 'innocent'),
            name: 'Innocent',
            slotId: 'slot-innocent',
          ),
          moved,
        ]),
      );

      await tester.tap(find.byKey(const Key('signal_browse_plug.ok')));
      await tester.pumpAndSettle();

      // A captured position would have swapped the innocent entry's ref, and
      // replayed the missing plugin's saved state into a plugin it never came
      // from. The entry is named by identity across the wait.
      final event =
          verify(
                () =>
                    bloc.add(captureAny(that: isA<LooperBusPluginRelinked>())),
              ).captured.single
              as LooperBusPluginRelinked;
      expect(event.index, 1);
    });
    testWidgets('a tap in the frame the chain changed still names it', (
      tester,
    ) async {
      await pump(tester, stage: FxStage.track, state: busWith(const [moved]));
      await tester.tap(find.byKey(const Key('signal_card_track_0')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('signal_panel_chip_0')));
      await tester.pumpAndSettle();

      // The chain changes and the tap lands before the rebuild — the tree
      // still holds the placeholder that was drawn for the missing entry,
      // while a live read of the chain already sees a different one at 0.
      when(() => bloc.state).thenReturn(
        busWith(const [
          PluginEffect(
            ref: PluginRef(format: PluginFormat.vst3, id: 'innocent'),
            name: 'Innocent',
            slotId: 'slot-innocent',
          ),
          moved,
        ]),
      );
      await tester.tap(find.byKey(const Key('signal_fx_relink')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('signal_browse_plug.ok')));
      await tester.pumpAndSettle();

      // The identity comes from the entry the placeholder was DRAWN for, so
      // the innocent plugin at 0 is left alone.
      final event =
          verify(
                () =>
                    bloc.add(captureAny(that: isA<LooperBusPluginRelinked>())),
              ).captured.single
              as LooperBusPluginRelinked;
      expect(event.index, 1);
    });
  });

  group('the chain run is drawn as the pen draws it', () {
    testWidgets('a chip label sits in the middle of its chip', (tester) async {
      await pump(tester, stage: FxStage.track);
      await tester.tap(find.byKey(const Key('signal_card_track_0')));
      await tester.pumpAndSettle();

      final l10n = l10nOf(tester);
      final chip = tester.getRect(find.byKey(const Key('signal_panel_chip_0')));
      final label = tester.getRect(
        find.text(fxBlockName(l10n, _rig.tracks.first.effects.first)),
      );
      // Its own height, not the chip's — and comparing CENTRES would prove
      // nothing: an uncentred label is a text box stretched to the whole 38,
      // so its centre matches the chip's exactly while the glyphs inside sit
      // at the top, which is the thing being reported.
      expect(label.height, lessThan(chip.height));
      expect(
        label.top - chip.top,
        moreOrLessEquals(chip.bottom - label.bottom, epsilon: 0.5),
      );

      final add = tester.getRect(
        find.byKey(const Key('signal_panel_add_chip')),
      );
      final addLabel = tester.getRect(find.text(l10n.fxAddChip));
      expect(addLabel.height, lessThan(add.height));
      // And the two sit on the same line, which is what made the run read as
      // misaligned: the add chip has always centred its own.
      expect(label.top, moreOrLessEquals(addLabel.top, epsilon: 0.5));
    });

    testWidgets('the chip a drag lifts carries its label the same way', (
      tester,
    ) async {
      await pump(tester, stage: FxStage.track);
      await tester.tap(find.byKey(const Key('signal_card_track_0')));
      await tester.pumpAndSettle();

      final l10n = l10nOf(tester);
      final name = fxBlockName(l10n, _rig.tracks.first.effects.first);
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const Key('signal_panel_chip_0'))),
      );
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      await tester.pump();

      // The flying copy is a chip of its own, and a label that sits
      // differently in it jumps the moment the chip leaves the run.
      final lifted = tester.getRect(
        find.byKey(const Key('signal_panel_lift')),
      );
      final label = tester.getRect(
        find.descendant(
          of: find.byKey(const Key('signal_panel_lift')),
          matching: find.text(name),
        ),
      );
      // ONE LINE tall, not merely shorter than the chip: this one carries a
      // border, and a `Container` folds that into its padding — so an
      // uncentred label is a box inset 1px from each edge, which is both
      // shorter than the chip and symmetric about its middle. Only its own
      // height tells the two apart.
      expect(label.height, lessThan(20));
      expect(
        label.top - lifted.top,
        moreOrLessEquals(lifted.bottom - label.bottom, epsilon: 0.5),
      );

      await gesture.up();
      await tester.pumpAndSettle();
    });

    testWidgets('the run is spaced as the pen spaces it', (tester) async {
      await pump(tester, stage: FxStage.track);
      await tester.tap(find.byKey(const Key('signal_card_track_0')));
      await tester.pumpAndSettle();

      // `Drive` ends at 74 and `Tremolo` starts at 84 in SIGNAL/signal-detail,
      // and the same 10 sits before `+ effect`.
      final first = tester.getRect(
        find.byKey(const Key('signal_panel_chip_0')),
      );
      final second = tester.getRect(
        find.byKey(const Key('signal_panel_chip_1')),
      );
      final add = tester.getRect(
        find.byKey(const Key('signal_panel_add_chip')),
      );
      expect(second.left - first.right, 10);
      expect(add.left - second.right, 10);
    });
  });

  group('the chain can be switched, and re-inherited', () {
    /// Track 0 mid-take, with lane 0 drifted from its input or not.
    LooperState drifted({required bool overdubbing, bool diverges = true}) =>
        LooperState(
          tracks: [
            Track(
              volume: 0.5,
              state: overdubbing ? TrackState.overdubbing : TrackState.playing,
              lanes: [
                Lane(
                  volume: 0.5,
                  inputChainDiverges: diverges,
                ),
                const Lane(inputChannel: 1),
              ],
              effects: _rig.tracks.first.effects,
            ),
            const Track(channel: 1, lanes: [Lane(inputChannel: 1)]),
          ],
          status: _rig.status,
        );

    testWidgets('a chain that is off can be switched back on', (tester) async {
      await pump(
        tester,
        stage: FxStage.track,
        state: LooperState(
          tracks: [
            Track(
              volume: 0.5,
              lanes: const [Lane(inputChannel: 0)],
              chainEnabled: false,
              effects: [
                BuiltInEffect(type: TrackEffectType.reverb, slotId: 'slot-a'),
              ],
            ),
          ],
          status: _rig.status,
        ),
      );
      await tester.tap(find.byKey(const Key('signal_card_track_0')));
      await tester.pumpAndSettle();

      // The dock used to carry this and the dock is gone. A chain switched
      // off from anywhere else — a pedal binding, a restored session — could
      // be SEEN to be off and never turned back on.
      expect(
        find.byKey(const Key('signal_panel_chain_off_consequence')),
        findsOneWidget,
      );

      // And it sits beside the caption it qualifies, not across the panel
      // against the power pill: the caption's row is right-aligned so the pill
      // lands at the far edge, and a loose child would ride along with it.
      final caption = tester.getRect(
        find.text(l10nOf(tester).signalPanelChain),
      );
      final warning = tester.getRect(
        find.byKey(const Key('signal_panel_chain_off_consequence')),
      );
      final pill = tester.getRect(
        find.byKey(const Key('signal_panel_chain_power')),
      );
      expect(warning.left - caption.right, lessThan(100));
      expect(pill.left - warning.left, greaterThan(200));

      await tester.tap(find.byKey(const Key('signal_panel_chain_power')));
      await tester.pumpAndSettle();

      // ON, not "toggled": a pill that writes the state it is already in
      // leaves a chain that is off unable to come back, which is the whole
      // reason this control exists.
      final event =
          verify(
                () => bloc.add(
                  captureAny(that: isA<LooperTrackChainEnabledToggled>()),
                ),
              ).captured.single
              as LooperTrackChainEnabledToggled;
      expect(event.enabled, isTrue);
    });

    testWidgets("an input's chain switches through its monitor", (
      tester,
    ) async {
      await pump(tester);
      // The input needs a monitor of its own: the cubit refuses to flip one
      // that was never configured, rather than materialize a phantom that
      // would come back on every boot.
      monitor.addEffect(0);
      await tester.tap(find.byKey(const Key('signal_card_input_0')));
      await tester.pumpAndSettle();

      // Each stage writes through its own carrier — the input's is the
      // monitor, not the bloc.
      await tester.tap(find.byKey(const Key('signal_panel_chain_power')));
      await tester.pumpAndSettle();

      verify(
        () => repository.setMonitorChainEnabled(
          input: 0,
          enabled: any(named: 'enabled'),
        ),
      ).called(1);
    });

    testWidgets('the overdub warning appears when the overdub starts', (
      tester,
    ) async {
      final states = StreamController<LooperState>();
      addTearDown(states.close);
      await pump(tester, stage: FxStage.loop, states: states.stream);
      await tester.tap(find.byKey(const Key('signal_card_loop_0_0')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('signal_panel_overdub_mismatch')),
        findsNothing,
      );

      // The take has ALREADY drifted, and the overdub begins: only the
      // track's state moves. A panel watching the lane's own numbers sees
      // nothing at all, so the warning would appear solely if the player
      // happened to touch the fader while the overdub ran — never, in the one
      // case A7 exists for.
      states.add(drifted(overdubbing: false));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('signal_panel_overdub_mismatch')),
        findsNothing,
      );

      states.add(drifted(overdubbing: true));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('signal_panel_overdub_mismatch')),
        findsOneWidget,
      );
    });

    testWidgets('and when the drift appears mid-overdub', (tester) async {
      final states = StreamController<LooperState>();
      addTearDown(states.close);
      await pump(tester, stage: FxStage.loop, states: states.stream);
      await tester.tap(find.byKey(const Key('signal_card_loop_0_0')));
      await tester.pumpAndSettle();

      // The other order: the overdub is already running and the input's chain
      // is edited underneath it. Now only the DRIFT moves.
      states.add(drifted(overdubbing: true, diverges: false));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('signal_panel_overdub_mismatch')),
        findsNothing,
      );

      states.add(drifted(overdubbing: true));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('signal_panel_overdub_mismatch')),
        findsOneWidget,
      );
    });

    testWidgets('the re-inherit appears when the input gains a chain', (
      tester,
    ) async {
      await pump(tester, stage: FxStage.loop);
      await tester.tap(find.byKey(const Key('signal_card_loop_0_0')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('signal_panel_resync')), findsNothing);

      // Whether a take can be re-inherited is a fact about the INPUT's chain
      // — a pedal switching that chain on is what makes the action possible,
      // and nothing about the lane moves when it does. The dock used to watch
      // this; the dock is gone.
      when(
        () => repository.laneCanInheritFromInput(any(), any()),
      ).thenReturn(true);
      monitor.addEffect(0);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('signal_panel_resync')), findsOneWidget);
    });

    testWidgets('a lane offers a re-inherit when the input has one', (
      tester,
    ) async {
      when(
        () => repository.laneCanInheritFromInput(any(), any()),
      ).thenReturn(true);
      await pump(tester, stage: FxStage.loop);
      await tester.tap(find.byKey(const Key('signal_card_loop_0_0')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('signal_panel_resync')));
      await tester.pumpAndSettle();

      // A6: explicit and user-initiated — the take does not re-inherit on its
      // own, so without this the only way back was rebuilding the chain by
      // hand.
      verify(
        () => bloc.add(any(that: isA<LooperLaneChainResyncedFromInput>())),
      ).called(1);
    });

    testWidgets('no re-inherit when the input has nothing to copy', (
      tester,
    ) async {
      await pump(tester, stage: FxStage.loop);
      await tester.tap(find.byKey(const Key('signal_card_loop_0_0')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('signal_panel_resync')), findsNothing);
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
