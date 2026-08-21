import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:performance_repository/performance_repository.dart';
import 'package:routing_graph/routing_graph.dart' show FocusableTapTarget;
import 'package:segno/audio_setup/audio_setup.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/control/control.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/cubit/settings_tray_cubit.dart';
import 'package:segno/looper/looper.dart';
import 'package:segno/looper/view/settings_tray.dart';
import 'package:segno/looper/view/tracks_chrome.dart';
import 'package:segno/performance/performance.dart';
import 'package:segno/session/session.dart';
import 'package:segno/theme/theme.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

class _MockLooperBloc extends MockBloc<LooperEvent, LooperState>
    implements LooperBloc {}

class _MockLooperRepository extends Mock implements LooperRepository {}

class _MockSessionCubit extends MockCubit<SessionState>
    implements SessionCubit {}

class _MockPerformanceRecorderCubit extends MockCubit<PerformanceRecorderState>
    implements PerformanceRecorderCubit {}

/// The rebuild probe for the `rebuild scope` group: a widget `TracksView.build`
/// creates unconditionally, in console and desktop layouts alike.
final Finder _chromeProbe = find.byKey(
  const Key('tracks_settings_secondaryTap'),
);

void main() {
  late LooperBloc bloc;
  late TracksCubit tracks;
  late ControlCubit control;
  late LooperRepository repository;
  late SettingsRepository settings;
  late SessionCubit session;
  late PerformanceRepository performance;
  late PerformanceRecorderCubit performanceRecorder;

  setUp(() {
    settings = SettingsRepository(store: FakeKeyValueStore());
    bloc = _MockLooperBloc();
    tracks = TracksCubit(settings: settings);
    repository = _MockLooperRepository();
    when(() => repository.readTrackWaveform(any())).thenReturn(Float32List(0));
    when(() => repository.state).thenReturn(const LooperState());
    // The FX-chain announcement reads the repository's remembered intent —
    // the same value the bloc's toggle handler negates.
    when(() => repository.trackChainEnabled(any())).thenReturn(true);
    when(() => repository.monitorChanges).thenAnswer(
      (_) => const Stream<int>.empty(),
    );
    when(
      () => repository.looperState,
    ).thenAnswer((_) => const Stream<LooperState>.empty());
    for (final stub in [
      () => repository.record(channel: any(named: 'channel')),
      () => repository.play(channel: any(named: 'channel')),
      () => repository.stopTrack(channel: any(named: 'channel')),
      () => repository.clear(channel: any(named: 'channel')),
    ]) {
      when(stub).thenReturn(EngineResult.ok);
    }
    when(
      () => repository.setMute(
        muted: any(named: 'muted'),
        channel: any(named: 'channel'),
      ),
    ).thenReturn(EngineResult.ok);
    // The real control cubit: it owns the system mode/cursor/bank the view
    // reads, and the M key / mode chip / number keys drive it.
    final pedalRepo = PedalRepository(const NoopPedalTransport());
    addTearDown(pedalRepo.dispose);
    performance = PerformanceRepository(
      engine: FakeAudioEngine(),
      exportsRoot: () async => '.',
    );
    control = ControlCubit(
      looper: repository,
      pedal: pedalRepo,
      settings: settings,
      performance: performance,
      keepAliveInterval: Duration.zero,
    );
    addTearDown(control.close);
    session = _MockSessionCubit();
    when(() => session.state).thenReturn(const SessionState());
    when(session.save).thenAnswer((_) async {});
    when(session.refreshSessions).thenAnswer((_) async {});
    when(() => session.saveAs(any())).thenAnswer((_) async {});
    when(() => session.exportMixdown()).thenAnswer((_) async {});
    when(() => session.exportStems()).thenAnswer((_) async {});
    performanceRecorder = _MockPerformanceRecorderCubit();
    when(
      () => performanceRecorder.state,
    ).thenReturn(const PerformanceRecorderIdle());
    when(performanceRecorder.toggleArm).thenAnswer((_) async {});
    when(
      () => performanceRecorder.renameCompletedCapture(any()),
    ).thenAnswer((_) async {});
  });

  void seed(LooperState state) {
    when(() => bloc.state).thenReturn(state);
    // Keep the repository snapshot (what ControlIntents reads) in step with
    // the bloc state the view renders.
    when(() => repository.state).thenReturn(state);
    whenListen(bloc, const Stream<LooperState>.empty(), initialState: state);
  }

  Future<void> pump(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.neon,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: MultiRepositoryProvider(
        providers: [
          RepositoryProvider<LooperRepository>.value(value: repository),
          RepositoryProvider<PerformanceRepository>.value(value: performance),
          RepositoryProvider<SettingsRepository>.value(value: settings),
        ],
        child: MultiBlocProvider(
          providers: [
            BlocProvider<LooperBloc>.value(value: bloc),
            BlocProvider<TracksCubit>.value(value: tracks),
            BlocProvider<ControlCubit>.value(value: control),
            BlocProvider<SessionCubit>.value(value: session),
            BlocProvider<PerformanceRecorderCubit>.value(
              value: performanceRecorder,
            ),
            // The tray's Signal domain draws input cards, so opening it needs
            // the same cubits the app provides around it.
            BlocProvider<InputsCubit>(
              create: (_) =>
                  InputsCubit(settings: settings, repository: repository),
            ),
            BlocProvider<MonitorCubit>(
              create: (_) =>
                  MonitorCubit(repository: repository, settings: settings),
            ),
          ],
          child: const TracksView(),
        ),
      ),
    ),
  );

  testWidgets(
    'every tap target on the performance surface is labeled '
    '(labeledTapTargetGuideline)',
    (tester) async {
      // The regression net for the Big Picture's hand-labeling: any tappable
      // node added without a semantic name — an icon-only IconButton with no
      // tooltip, a bare GestureDetector, a FocusableTapTarget with no label —
      // fails this. Locks in the transport controls, track tiles, mode toggle,
      // and bank switch.
      final handle = tester.ensureSemantics();
      seed(const LooperState(tracks: [Track(), Track(channel: 1)]));
      await pump(tester);
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      handle.dispose();
    },
  );

  testWidgets('renders a tile per track', (tester) async {
    seed(const LooperState(tracks: [Track(), Track(channel: 1)]));
    await pump(tester);

    expect(find.byKey(const Key('tracks_tile_0')), findsOneWidget);
    expect(find.byKey(const Key('tracks_tile_1')), findsOneWidget);
  });

  testWidgets('mounts the settings tray with its always-visible handle', (
    tester,
  ) async {
    seed(const LooperState(tracks: [Track()]));
    await pump(tester);

    expect(find.byKey(const Key('settingsTray_handle')), findsOneWidget);
  });

  /// The tray's own state, read from inside the provider it lives under.
  SettingsTrayState trayState(WidgetTester tester) =>
      BlocProvider.of<SettingsTrayCubit>(
        tester.element(find.byType(SettingsTray)),
      ).state;

  testWidgets('the Signal button opens the tray at Signal', (tester) async {
    seed(const LooperState(tracks: [Track()]));
    await pump(tester);

    expect(find.byKey(const Key('tracks_openSignal')), findsOneWidget);
    await tester.tap(find.byKey(const Key('tracks_openSignal')));
    await tester.pumpAndSettle();

    // Signal used to be a pushed page of its own. Asserting the button EXISTS
    // is what let it keep existing while leading nowhere.
    expect(trayState(tester).destination, SettingsTrayDestination.signal);
    expect(trayState(tester).dragProgress, 1);
  });

  testWidgets('G opens the tray at Signal too', (tester) async {
    seed(const LooperState(tracks: [Track()]));
    await pump(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyG);
    await tester.pumpAndSettle();

    // The key handler is built from a context ABOVE the tray's own provider
    // unless something puts it below: reading the cubit from the wrong one
    // throws `ProviderNotFoundException` out of the key callback, and on a
    // console build — where the toolbar is hidden — `G` is the only way in.
    expect(tester.takeException(), isNull);
    expect(trayState(tester).destination, SettingsTrayDestination.signal);
  });

  testWidgets('exposes a visible Settings button', (tester) async {
    seed(const LooperState(tracks: [Track()]));
    await pump(tester);

    // Settings was previously reachable only by the `S` key or right-click;
    // the top-bar button makes it operable by pointer/touch.
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    expect(find.byKey(const Key('tracks_openSettings')), findsOneWidget);
    expect(find.byTooltip(l10n.settingsTooltip), findsOneWidget);
  });

  testWidgets('tapping a tile records that channel in record mode', (
    tester,
  ) async {
    seed(const LooperState(tracks: [Track(), Track(channel: 1)]));
    await pump(tester);

    await tester.tap(find.byKey(const Key('tracks_tile_1')));
    verify(() => bloc.add(const LooperRecordPressed(1))).called(1);
  });

  testWidgets('tapping a tile mutes/unmutes that channel in mute mode', (
    tester,
  ) async {
    control.toggleMode(); // record -> mute
    seed(const LooperState(tracks: [Track(), Track(channel: 1)]));
    await pump(tester);

    await tester.tap(find.byKey(const Key('tracks_tile_1')));
    // Mirrors the mute-mode number-key behavior; does not arm recording.
    verify(() => bloc.add(const LooperMuteToggled(1))).called(1);
    verifyNever(() => bloc.add(const LooperRecordPressed(1)));
    // The tap also selects the tapped channel.
    expect(control.state.cursor, 1);
  });

  testWidgets('tapping a tile toggles that track FX chain in FX mode', (
    tester,
  ) async {
    control.setMode(InteractionMode.fx);
    seed(const LooperState(tracks: [Track(), Track(channel: 1)]));
    await pump(tester);

    await tester.tap(find.byKey(const Key('tracks_tile_1')));
    // One interaction mode for every surface: touch does what the pedal's
    // track stomp and the number keys do.
    verify(
      () => bloc.add(const LooperTrackChainToggled(1)),
    ).called(1);
    verifyNever(() => bloc.add(const LooperRecordPressed(1)));
    verifyNever(() => bloc.add(const LooperMuteToggled(1)));
  });

  testWidgets('the number keys toggle FX chains in FX mode', (tester) async {
    control.setMode(InteractionMode.fx);
    seed(const LooperState(tracks: [Track(), Track(channel: 1)]));
    await pump(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
    await tester.pump();

    verify(
      () => bloc.add(const LooperTrackChainToggled(1)),
    ).called(1);
    verifyNever(() => bloc.add(const LooperMuteToggled(1)));
    expect(control.state.cursor, 1); // the digit still selects
  });

  testWidgets('M cycles the mode chip through REC, MUTE and FX, announcing '
      'each landed mode', (tester) async {
    // Assert the DELIVERED announcement text, not the getter: a getter-only
    // assertion passes even when two ARB keys collide and the string that
    // actually ships is some other surface's copy.
    final announcements = <String>[];
    tester.binding.defaultBinaryMessenger.setMockDecodedMessageHandler(
      SystemChannels.accessibility,
      (message) async {
        final data = message! as Map<dynamic, dynamic>;
        if (data['type'] == 'announce') {
          announcements.add(
            (data['data'] as Map<dynamic, dynamic>)['message'] as String,
          );
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockDecodedMessageHandler(
        SystemChannels.accessibility,
        null,
      ),
    );

    seed(const LooperState(tracks: [Track()]));
    await pump(tester);

    Future<void> cycle() async {
      await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
      await tester.pump();
    }

    final l10n = await AppLocalizations.delegate.load(const Locale('en'));

    await cycle();
    expect(control.state.mode, InteractionMode.mute);
    await cycle();
    expect(control.state.mode, InteractionMode.fx);
    // The chip renders the landed mode, so the screen and the plate agree.
    expect(find.text('FX'), findsOneWidget);
    expect(announcements, contains(l10n.a11yModeFx));
    expect(l10n.a11yModeFx, 'FX mode');
    await cycle();
    expect(control.state.mode, InteractionMode.record);
    expect(announcements, contains(l10n.a11yModeRecord));
  });

  testWidgets('an FX-chain key toggle announces the chain state', (
    tester,
  ) async {
    final announcements = <String>[];
    tester.binding.defaultBinaryMessenger.setMockDecodedMessageHandler(
      SystemChannels.accessibility,
      (message) async {
        final data = message! as Map<dynamic, dynamic>;
        if (data['type'] == 'announce') {
          announcements.add(
            (data['data'] as Map<dynamic, dynamic>)['message'] as String,
          );
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockDecodedMessageHandler(
        SystemChannels.accessibility,
        null,
      ),
    );

    control.setMode(InteractionMode.fx);
    seed(const LooperState(tracks: [Track(), Track(channel: 1)]));
    await pump(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
    await tester.pump();

    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    expect(announcements, contains(l10n.a11yTrackFxChainOff));
    // Pinned literally: these keys once collided with the FX editor's own
    // chain-power strings, and the getter silently resolved to those.
    expect(l10n.a11yTrackFxChainOff, 'Track FX chain off');
    expect(l10n.a11yTrackFxChainOn, 'Track FX chain on');
  });

  testWidgets('an FX-mode track tile reads its chain state to a screen '
      'reader', (tester) async {
    final handle = tester.ensureSemantics();
    try {
      control.setMode(InteractionMode.fx);
      seed(
        const LooperState(
          tracks: [Track(), Track(channel: 1, chainEnabled: false)],
        ),
      );
      await pump(tester);

      // The tile carries no other cue for chain state, so the label must:
      // one track engaged, one bypassed.
      expect(find.bySemanticsLabel(RegExp('FX chain on')), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('FX chain off')), findsOneWidget);
    } finally {
      handle.dispose();
    }
  });

  testWidgets('long-pressing a tile stops that channel', (tester) async {
    seed(const LooperState(tracks: [Track()]));
    await pump(tester);

    await tester.longPress(find.byKey(const Key('tracks_tile_0')));
    verify(() => bloc.add(const LooperStopPressed(0))).called(1);
  });

  testWidgets('shows one bank of four and switches A/B', (tester) async {
    seed(LooperState(tracks: [for (var i = 0; i < 8; i++) Track(channel: i)]));
    await pump(tester);

    // Bank A shows channels 0-3 only.
    expect(find.byKey(const Key('tracks_tile_0')), findsOneWidget);
    expect(find.byKey(const Key('tracks_tile_3')), findsOneWidget);
    expect(find.byKey(const Key('tracks_tile_4')), findsNothing);

    // Switch to bank B -> channels 4-7.
    await tester.tap(find.byKey(const Key('tracks_bank_1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tracks_tile_4')), findsOneWidget);
    expect(find.byKey(const Key('tracks_tile_7')), findsOneWidget);
    expect(find.byKey(const Key('tracks_tile_0')), findsNothing);
  });

  group('transport tempo display', () {
    testWidgets('hidden when no tempo has ever been set (grid-off)', (
      tester,
    ) async {
      seed(const LooperState(tracks: [Track()]));
      await pump(tester);

      expect(find.byKey(const Key('tracks_transportTempo')), findsNothing);
    });

    testWidgets('shows the current BPM and beat dots once a tempo is set', (
      tester,
    ) async {
      // Wide enough for the beat-indicator's width-threshold gate to show
      // it (see the dedicated fallback/narrow-toolbar cases below).
      tester.view.physicalSize = const Size(1400, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      seed(
        const LooperState(
          transport: TransportState(
            tempoBpm: 120,
            tempoSource: TempoSource.manual,
            currentBeat: 1,
          ),
          tracks: [Track()],
        ),
      );
      await pump(tester);

      expect(tester.takeException(), isNull);
      final display = find.byKey(const Key('tracks_transportTempo'));
      expect(display, findsOneWidget);
      expect(find.text('120.0 BPM'), findsOneWidget);
      // Small numerator (default 4/4) -> individual dots, not the "N/M"
      // compact text the large-numerator fallback below uses.
      expect(
        find.descendant(of: display, matching: find.textContaining('/')),
        findsNothing,
      );
    });

    testWidgets('shows a counting-in readout with a beat countdown', (
      tester,
    ) async {
      seed(
        const LooperState(
          transport: TransportState(
            tempoBpm: 120,
            tempoSource: TempoSource.manual,
            countingIn: true,
            countInBeatsLeft: 3,
          ),
          tracks: [Track()],
        ),
      );
      await pump(tester);

      expect(find.text('Count-in 3'), findsOneWidget);
    });

    testWidgets(
      'a 15/8 signature at a normal width falls back to compact "beat N/M" '
      'text instead of 15 dots (~130px of fixed width)',
      (tester) async {
        // Wide enough that the beat-indicator's width-threshold gate shows
        // it (the toolbar's full icon cluster otherwise leaves little slack
        // at the default 800×600 test surface — see the narrow-toolbar case
        // below for that regime).
        tester.view.physicalSize = const Size(1400, 600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        seed(
          const LooperState(
            transport: TransportState(
              tempoBpm: 120,
              tempoSource: TempoSource.manual,
              tsNum: 15,
              tsDen: 8,
              currentBeat: 2,
            ),
            tracks: [Track()],
          ),
        );

        await pump(tester);

        expect(tester.takeException(), isNull);
        expect(find.text('3/15'), findsOneWidget);
      },
    );

    testWidgets(
      'a 15/8 signature on a narrow toolbar renders without a RenderFlex '
      'overflow, even where the beat indicator itself is dropped',
      (tester) async {
        // Narrower than the default 800×600 test surface — the toolbar's
        // full icon cluster plus this readout is already tight there (the
        // regression this guards: 15 non-shrinkable dots at ~130px used to
        // overflow regardless of how far the tempo text ellipsized).
        tester.view.physicalSize = const Size(700, 600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        seed(
          const LooperState(
            transport: TransportState(
              tempoBpm: 120,
              tempoSource: TempoSource.manual,
              tsNum: 15,
              tsDen: 8,
              currentBeat: 2,
            ),
            tracks: [Track()],
          ),
        );

        await pump(tester);

        // No RenderFlex overflow — the assertion the review demanded.
        expect(tester.takeException(), isNull);
        // At this width the LayoutBuilder gate drops the indicator
        // entirely rather than squeezing it (still zero-overflow either
        // way); the tempo text alone remains visible.
        expect(find.text('120.0 BPM'), findsOneWidget);
      },
    );
  });

  group('pending arm badge', () {
    testWidgets('shows on a track with a pending quantized/signal arm', (
      tester,
    ) async {
      seed(const LooperState(tracks: [Track(pending: true)]));
      await pump(tester);

      expect(find.byIcon(Icons.schedule_outlined), findsOneWidget);
    });

    testWidgets('absent on a track with no pending arm', (tester) async {
      seed(const LooperState(tracks: [Track()]));
      await pump(tester);

      expect(find.byIcon(Icons.schedule_outlined), findsNothing);
    });
  });

  group('crown badge (D18, B5c)', () {
    testWidgets('absent in Multi mode', (tester) async {
      seed(
        // LooperMode.multi is TransportState's default — explicit here only
        // for readability (this is a Multi-mode test).
        const LooperState(
          tracks: [Track(), Track(channel: 1)],
        ),
      );
      await pump(tester);

      expect(find.byKey(const Key('tracks_crown_0')), findsNothing);
      expect(find.byKey(const Key('tracks_crown_1')), findsNothing);
    });

    testWidgets('absent in Song and Free modes too — Sync/Band only', (
      tester,
    ) async {
      for (final mode in [LooperMode.song, LooperMode.free]) {
        seed(
          LooperState(
            transport: TransportState(looperMode: mode),
            tracks: const [Track()],
          ),
        );
        await pump(tester);
        expect(
          find.byKey(const Key('tracks_crown_0')),
          findsNothing,
          reason: mode.name,
        );
      }
    });

    testWidgets('visible on every track in Sync mode', (tester) async {
      seed(
        const LooperState(
          transport: TransportState(looperMode: LooperMode.sync),
          tracks: [Track(), Track(channel: 1)],
        ),
      );
      await pump(tester);

      expect(find.byKey(const Key('tracks_crown_0')), findsOneWidget);
      expect(find.byKey(const Key('tracks_crown_1')), findsOneWidget);
    });

    testWidgets('visible in Band mode too', (tester) async {
      seed(
        const LooperState(
          transport: TransportState(looperMode: LooperMode.band),
          tracks: [Track()],
        ),
      );
      await pump(tester);

      expect(find.byKey(const Key('tracks_crown_0')), findsOneWidget);
    });

    testWidgets(
      'tapping a non-primary track crowns it (dispatches '
      'LooperCrownPrimaryPressed)',
      (tester) async {
        seed(
          const LooperState(
            transport: TransportState(
              looperMode: LooperMode.sync,
              primaryTrack: 0,
            ),
            tracks: [Track(), Track(channel: 1)],
          ),
        );
        await pump(tester);

        await tester.tap(find.byKey(const Key('tracks_crown_1')));
        await tester.pumpAndSettle();

        verify(
          () => bloc.add(const LooperCrownPrimaryPressed(1)),
        ).called(1);
      },
    );

    testWidgets(
      "the current primary track's own badge is inert — no un-crown "
      'gesture exists (D18)',
      (tester) async {
        seed(
          const LooperState(
            transport: TransportState(
              looperMode: LooperMode.sync,
              primaryTrack: 0,
            ),
            tracks: [Track()],
          ),
        );
        await pump(tester);

        await tester.tap(find.byKey(const Key('tracks_crown_0')));
        await tester.pumpAndSettle();

        verifyNever(() => bloc.add(const LooperCrownPrimaryPressed(0)));
      },
    );
  });

  group('keyboard', () {
    testWidgets('M toggles the tracks mode', (tester) async {
      seed(const LooperState(tracks: [Track()]));
      await pump(tester);
      expect(control.state.mode, InteractionMode.record);

      await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
      await tester.pump();
      expect(control.state.mode, InteractionMode.mute);
    });

    testWidgets('a number key selects that track', (tester) async {
      seed(const LooperState(tracks: [Track(), Track(channel: 1)]));
      await pump(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
      await tester.pump();
      expect(control.state.cursor, 1);
    });

    testWidgets('record mode: R records the selected track', (tester) async {
      seed(const LooperState(tracks: [Track(), Track(channel: 1)]));
      await pump(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
      await tester.pump();
      verify(() => bloc.add(const LooperRecordPressed(1))).called(1);
    });

    testWidgets('mute mode: a number key selects and toggles mute', (
      tester,
    ) async {
      seed(const LooperState(tracks: [Track(), Track(channel: 1)]));
      await pump(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyM); // -> mute mode
      await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
      await tester.pump();
      expect(control.state.cursor, 0);
      verify(() => bloc.add(const LooperMuteToggled(0))).called(1);
    });

    testWidgets('Space plays all when nothing is playing', (tester) async {
      seed(
        const LooperState(
          tracks: [Track(state: TrackState.stopped, lengthFrames: 100)],
        ),
      );
      await pump(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      verify(() => bloc.add(const LooperPlayAllPressed())).called(1);
    });

    testWidgets('C clears all', (tester) async {
      seed(
        const LooperState(
          tracks: [Track(state: TrackState.stopped, lengthFrames: 100)],
        ),
      );
      await pump(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
      await tester.pump();
      // Clear-all is a ControlIntents action: every content track is cleared
      // and re-armed on the engine directly.
      verify(() => repository.clear()).called(1);
      verify(() => repository.setMute(muted: false)).called(1);
    });

    testWidgets('F toggles fullscreen without error', (tester) async {
      seed(const LooperState(tracks: [Track()]));
      await pump(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.pump();
    });
  });

  testWidgets('renaming a track updates its label', (tester) async {
    seed(const LooperState(tracks: [Track()]));
    await pump(tester);
    expect(find.text('TRACK 1'), findsOneWidget);

    await tester.tap(find.byKey(const Key('tracks_name_0')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400)); // open dialog

    await tester.enterText(
      find.byKey(const Key('renameTrack_field')),
      'GUITAR',
    );
    await tester.tap(find.byKey(const Key('renameTrack_save')));
    await tester.pumpAndSettle();

    expect(find.text('GUITAR'), findsOneWidget);
    expect(find.text('TRACK 1'), findsNothing);
    expect(await settings.loadTrackName(0), 'GUITAR');
  });

  group('mute-mode visuals', () {
    final looper = AppTheme.neon.extension<LooperTheme>()!;

    // The meter Container inside a track tile (the _PeakBar's fill).
    Container barOf(WidgetTester tester, int channel) =>
        tester
                .widget<FractionallySizedBox>(
                  find.descendant(
                    of: find.byKey(Key('tracks_tile_$channel')),
                    matching: find.byType(FractionallySizedBox),
                  ),
                )
                .child!
            as Container;

    // The meter fill fraction (the _PeakBar's height factor) for a tile.
    double fillOf(WidgetTester tester, int channel) => tester
        .widget<FractionallySizedBox>(
          find.descendant(
            of: find.byKey(Key('tracks_tile_$channel')),
            matching: find.byType(FractionallySizedBox),
          ),
        )
        .heightFactor!;

    testWidgets('a stopped loaded track freezes its last meter level', (
      tester,
    ) async {
      const playing = LooperState(
        tracks: [
          Track(state: TrackState.playing, lengthFrames: 1000, peak: 0.81),
        ],
      );
      const stopped = LooperState(
        tracks: [Track(state: TrackState.stopped, lengthFrames: 1000)],
      );
      final controller = StreamController<LooperState>();
      addTearDown(controller.close);
      var current = playing;
      when(() => bloc.state).thenAnswer((_) => current);
      whenListen(bloc, controller.stream, initialState: playing);
      await pump(tester);

      final live = fillOf(tester, 0);
      expect(live, greaterThan(0));

      // Stop: the track reports peak 0, but the bar holds its last live fill
      // instead of collapsing.
      current = stopped;
      controller.add(stopped);
      await tester.pump();
      expect(fillOf(tester, 0), live);
    });

    testWidgets('a rising level moves the bar', (tester) async {
      // The companion to the freeze test above, and the guard #646 needs: that
      // one asserts the fill STAYS PUT, so it passes whether or not updates
      // reach the column. Since the track now arrives through a selector in
      // `_TrackSlot` rather than being handed down directly, a selector that
      // stopped yielding new values would freeze every meter on the console
      // with the rest of the suite still green.
      const low = LooperState(
        tracks: [
          Track(state: TrackState.playing, lengthFrames: 1000, peak: 0.2),
        ],
      );
      const high = LooperState(
        tracks: [
          Track(state: TrackState.playing, lengthFrames: 1000, peak: 0.9),
        ],
      );
      final controller = StreamController<LooperState>();
      addTearDown(controller.close);
      var current = low;
      when(() => bloc.state).thenAnswer((_) => current);
      whenListen(bloc, controller.stream, initialState: low);
      await pump(tester);

      final before = fillOf(tester, 0);
      current = high;
      controller.add(high);
      await tester.pump();

      expect(
        fillOf(tester, 0),
        greaterThan(before),
        reason:
            'a level change no longer reaches TrackColumn -- the '
            '_TrackSlot selector has stopped yielding new tracks (see #646)',
      );
    });

    testWidgets('a track with nothing recorded has no bar (height 0)', (
      tester,
    ) async {
      seed(const LooperState(tracks: [Track()])); // empty, no content
      await pump(tester);

      final box = tester.widget<FractionallySizedBox>(
        find.descendant(
          of: find.byKey(const Key('tracks_tile_0')),
          matching: find.byType(FractionallySizedBox),
        ),
      );
      expect(box.heightFactor, 0.0);
    });

    testWidgets('the meter color is the track state color', (tester) async {
      seed(
        const LooperState(
          tracks: [
            Track(state: TrackState.recording),
            Track(channel: 1, state: TrackState.playing),
          ],
        ),
      );
      await pump(tester);
      expect(
        barOf(tester, 0).color,
        looper.meterColor(
          LooperMeterState.recording,
          mode: InteractionMode.record,
        ),
      );
      expect(
        barOf(tester, 1).color,
        looper.meterColor(
          LooperMeterState.playing,
          mode: InteractionMode.record,
        ),
      );
    });

    testWidgets('mute mode uses the mute-mode meter table', (tester) async {
      control.toggleMode(); // record -> mute
      seed(const LooperState(tracks: [Track(state: TrackState.playing)]));
      await pump(tester);
      expect(
        barOf(tester, 0).color,
        looper.meterColor(LooperMeterState.playing, mode: InteractionMode.mute),
      );
    });

    testWidgets('a muted track uses the muted override color', (tester) async {
      seed(
        const LooperState(
          tracks: [Track(state: TrackState.playing, muted: true)],
        ),
      );
      await pump(tester);
      expect(
        barOf(tester, 0).color,
        looper.meterColor(LooperMeterState.muted, mode: InteractionMode.record),
      );
    });

    testWidgets('the tile border is white only when selected', (tester) async {
      control.selectTrack(0);
      seed(
        const LooperState(
          tracks: [
            Track(state: TrackState.recording), // selected + recording
            Track(channel: 1, state: TrackState.playing), // unselected
          ],
        ),
      );
      await pump(tester);

      Color borderColor(int channel) {
        final tile = tester.widget<Container>(
          find
              .ancestor(
                of: find.byKey(Key('tracks_tile_$channel')),
                matching: find.byType(Container),
              )
              .first,
        );
        return ((tile.decoration! as BoxDecoration).border! as Border)
            .top
            .color;
      }

      expect(borderColor(0), Colors.white); // selected
      expect(borderColor(1), Colors.transparent); // unselected
    });

    testWidgets('track tiles have no glow shadow', (tester) async {
      seed(
        const LooperState(
          tracks: [
            Track(state: TrackState.recording),
            Track(channel: 1),
          ],
        ),
      );
      await pump(tester);

      final tile = tester.widget<Container>(
        find
            .ancestor(
              of: find.byKey(const Key('tracks_tile_0')),
              matching: find.byType(Container),
            )
            .first,
      );
      final decoration = tile.decoration! as BoxDecoration;
      expect(decoration.boxShadow, anyOf(isNull, isEmpty));
    });
  });

  group('track indicators', () {
    final looper = AppTheme.neon.extension<LooperTheme>()!;

    Color indicatorColorOf(WidgetTester tester, int channel) {
      final box = tester.widget<DecoratedBox>(
        find.descendant(
          of: find.byKey(Key('tracks_indicator_$channel')),
          matching: find.byType(DecoratedBox),
        ),
      );
      return (box.decoration as BoxDecoration).color!;
    }

    testWidgets('renders one strip per visible tile when the pref is on', (
      tester,
    ) async {
      seed(const LooperState(tracks: [Track(), Track(channel: 1)]));
      await pump(tester);

      expect(find.byKey(const Key('tracks_indicator_0')), findsOneWidget);
      expect(find.byKey(const Key('tracks_indicator_1')), findsOneWidget);
    });

    testWidgets('is absent from the tree when the pref is off', (tester) async {
      await tracks.setShowIndicators(value: false);
      seed(const LooperState(tracks: [Track()]));
      await pump(tester);

      expect(find.byKey(const Key('tracks_indicator_0')), findsNothing);
      // The tile itself still renders — only the strip is gone.
      expect(find.byKey(const Key('tracks_tile_0')), findsOneWidget);
    });

    testWidgets('colour reflects the track status', (tester) async {
      seed(
        const LooperState(
          tracks: [
            Track(state: TrackState.recording), // -> record
            Track(channel: 1, state: TrackState.playing), // -> play
            Track(channel: 2), // empty, unselected -> idle
          ],
        ),
      );
      await pump(tester);

      expect(
        indicatorColorOf(tester, 0),
        looper.indicatorColor(TrackIndicator.record),
      );
      expect(
        indicatorColorOf(tester, 1),
        looper.indicatorColor(TrackIndicator.play),
      );
      expect(
        indicatorColorOf(tester, 2),
        looper.indicatorColor(TrackIndicator.idle),
      );
    });

    testWidgets('mute mode arms the selected empty tile green', (tester) async {
      control
        ..toggleMode() // record -> mute
        ..selectTrack(0);
      seed(const LooperState(tracks: [Track()])); // empty + selected
      await pump(tester);

      // Proves muteMode flows from the shared PedalCubit mode into
      // TrackIndicator.of: an empty selected track arms play (green) in mute
      // mode, not record (red).
      expect(
        indicatorColorOf(tester, 0),
        looper.indicatorColor(TrackIndicator.play),
      );
    });

    testWidgets('a stopped track that holds a loop is armed to play', (
      tester,
    ) async {
      seed(
        const LooperState(
          tracks: [Track(state: TrackState.stopped, lengthFrames: 1000)],
        ),
      );
      await pump(tester);

      // After a stop, a loaded loop stays lit green (armed to play) rather
      // than going dim.
      expect(
        indicatorColorOf(tester, 0),
        looper.indicatorColor(TrackIndicator.play),
      );
    });

    testWidgets('a muted track reads as idle', (tester) async {
      seed(
        const LooperState(
          tracks: [Track(state: TrackState.playing, muted: true)],
        ),
      );
      await pump(tester);

      expect(
        indicatorColorOf(tester, 0),
        looper.indicatorColor(TrackIndicator.idle),
      );
    });

    testWidgets('only the selected tile arms (empty + selected)', (
      tester,
    ) async {
      control.selectTrack(1);
      seed(
        const LooperState(
          tracks: [Track(), Track(channel: 1), Track(channel: 2)],
        ),
      );
      await pump(tester);

      // Record mode by default: the selected empty track arms red, the rest
      // stay idle.
      expect(
        indicatorColorOf(tester, 0),
        looper.indicatorColor(TrackIndicator.idle),
      );
      expect(
        indicatorColorOf(tester, 1),
        looper.indicatorColor(TrackIndicator.record),
      );
      expect(
        indicatorColorOf(tester, 2),
        looper.indicatorColor(TrackIndicator.idle),
      );
    });

    testWidgets('selecting an off-bank channel reveals its bank', (
      tester,
    ) async {
      control.selectTrack(5); // channel in bank B -> selection reveals bank B
      seed(
        LooperState(tracks: [for (var i = 0; i < 8; i++) Track(channel: i)]),
      );
      await pump(tester);

      // Bank B is now showing, so the selected channel is visible and armed —
      // a selection can never hide behind the other bank.
      expect(find.byKey(const Key('tracks_tile_5')), findsOneWidget);
      expect(find.byKey(const Key('tracks_tile_0')), findsNothing);
      expect(
        indicatorColorOf(tester, 5),
        looper.indicatorColor(TrackIndicator.record),
      );
    });

    testWidgets('a bank switch reassigns the armed tile', (tester) async {
      control.selectTrack(0);
      seed(
        LooperState(tracks: [for (var i = 0; i < 8; i++) Track(channel: i)]),
      );
      await pump(tester);

      // Channel 0 is selected and visible in bank A -> armed.
      expect(
        indicatorColorOf(tester, 0),
        looper.indicatorColor(TrackIndicator.record),
      );

      // Switch to bank B and select channel 4.
      await tester.tap(find.byKey(const Key('tracks_bank_1')));
      await tester.pumpAndSettle();
      control.selectTrack(4);
      await tester.pumpAndSettle();

      // The previously-armed tile is no longer in the tree; the newly-selected
      // visible tile arms.
      expect(find.byKey(const Key('tracks_indicator_0')), findsNothing);
      expect(
        indicatorColorOf(tester, 4),
        looper.indicatorColor(TrackIndicator.record),
      );
    });

    testWidgets('toggling the pref live-updates without restart', (
      tester,
    ) async {
      seed(const LooperState(tracks: [Track()]));
      await pump(tester);
      expect(find.byKey(const Key('tracks_indicator_0')), findsOneWidget);

      await tracks.setShowIndicators(value: false);
      await tester.pump();
      expect(find.byKey(const Key('tracks_indicator_0')), findsNothing);

      await tracks.setShowIndicators(value: true);
      await tester.pump();
      expect(find.byKey(const Key('tracks_indicator_0')), findsOneWidget);
    });

    testWidgets('carries no semantics of its own (ExcludeSemantics)', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      seed(const LooperState(tracks: [Track(state: TrackState.recording)]));
      await pump(tester);

      // The strip is wrapped in ExcludeSemantics, so no semantics node is
      // attached to its key — the tile's label remains the only state source.
      expect(
        find.descendant(
          of: find.byKey(const Key('tracks_indicator_0')),
          matching: find.byType(ExcludeSemantics),
        ),
        findsOneWidget,
      );
      handle.dispose();
    });
  });

  group('audio-not-running affordance', () {
    testWidgets('shows when the engine is not connected', (tester) async {
      seed(const LooperState(tracks: [Track()]));
      await pump(tester);

      expect(
        find.byKey(const Key('tracks_audioNotRunning')),
        findsOneWidget,
      );
    });

    testWidgets('is hidden once the engine is connected', (tester) async {
      seed(
        const LooperState(
          tracks: [Track()],
          status: EngineStatus(isConnected: true),
        ),
      );
      await pump(tester);

      expect(find.byKey(const Key('tracks_audioNotRunning')), findsNothing);
    });
  });

  group('accessibility', () {
    testWidgets('track tile is a labelled button naming its state', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      seed(const LooperState(tracks: [Track()]));
      await pump(tester);

      final node = tester.getSemantics(
        find.byKey(const Key('tracks_tile_0')),
      );
      // Colour-only meter state (1.4.1) is named in the accessible label, and
      // the tile carries a button role (4.1.2).
      expect(node.label, contains('empty'));
      expect(node, isSemantics(isButton: true));
      handle.dispose();
    });

    testWidgets('a tile exposes a tap action for screen readers (4.1.2)', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      seed(const LooperState(tracks: [Track()]));
      await pump(tester);

      // The labelled tile must keep a tap semantics action so VoiceOver/
      // TalkBack can activate it (the actual record path is covered by the
      // pointer-tap test above).
      expect(
        tester.getSemantics(find.byKey(const Key('tracks_tile_0'))),
        isSemantics(isButton: true, hasTapAction: true),
      );
      handle.dispose();
    });

    testWidgets('the bank tab exposes its selected state', (tester) async {
      final handle = tester.ensureSemantics();
      seed(
        LooperState(tracks: [for (var i = 0; i < 8; i++) Track(channel: i)]),
      );
      await pump(tester);

      expect(
        tester.getSemantics(find.byKey(const Key('tracks_bank_0'))),
        isSemantics(isButton: true, isSelected: true),
      );
      expect(
        tester.getSemantics(find.byKey(const Key('tracks_bank_1'))),
        isSemantics(isButton: true, isSelected: false),
      );
      handle.dispose();
    });

    testWidgets('the mode indicator is a labelled toggle button', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      seed(const LooperState(tracks: [Track()]));
      await pump(tester);

      final node = tester.getSemantics(
        find.byKey(const Key('tracks_mode_indicator')),
      );
      expect(node, isSemantics(isButton: true));
      expect(node.label, isNotEmpty);
      handle.dispose();
    });

    // The indicator's colour pair per mode — icon, label, border AND fill are
    // all asserted: a half-applied change (say, a token border over a stale
    // hardcoded fill — exactly the #737 defect) must not pass.
    Future<(Color, Color, Color, Color?)> indicatorOf(
      WidgetTester tester,
      InteractionMode mode, {
      ThemeData? theme,
    }) async {
      await tester.pumpApp(
        theme: theme,
        Scaffold(
          body: ModeIndicator(mode: mode, onToggle: () {}),
        ),
      );
      final scope = find.byKey(const Key('tracks_mode_indicator'));
      final icon = tester
          .widget<Icon>(find.descendant(of: scope, matching: find.byType(Icon)))
          .color!;
      final label = tester
          .widget<Text>(find.descendant(of: scope, matching: find.byType(Text)))
          .style!
          .color!;
      final box =
          tester
                  .widget<Container>(
                    find.descendant(
                      of: scope,
                      matching: find.byType(Container),
                    ),
                  )
                  .decoration!
              as BoxDecoration;
      return (box.border!.top.color, icon, label, box.color);
    }

    testWidgets('the mode indicator reads the SurfaceTheme token pairs', (
      tester,
    ) async {
      // Rec red over its wash, mute green over its wash (#693 — the owner's
      // call: mute reads green, matching the stage pill), FX accent blue over
      // the deliberately FLAT `accentSurface` — the same token pairs the
      // stage status bar's pill reads, so the two surfaces cannot disagree.
      final s = AppTheme.neon.extension<SurfaceTheme>()!;
      expect(await indicatorOf(tester, InteractionMode.record), (
        s.rec,
        s.rec,
        s.rec,
        s.recSurface,
      ));
      expect(await indicatorOf(tester, InteractionMode.mute), (
        s.success,
        s.success,
        s.success,
        s.successSurface,
      ));
      expect(await indicatorOf(tester, InteractionMode.fx), (
        s.accent,
        s.accent,
        s.accent,
        s.accentSurface,
      ));
    });

    testWidgets('the mode indicator fill follows the high-contrast flavor', (
      tester,
    ) async {
      // The #737 regression this pins: the fill was an inline
      // `color.withValues(alpha: 0.16)`, which the dark flavor's token values
      // round close enough to that a dark-only test cannot see the bug. High
      // contrast is the only flavor that overrides the washes — it lifts
      // them to 0x33 (0.2) — so it is the only flavor where a hardcoded
      // alpha visibly pins this chip below the stage pill beside it.
      final hc = AppTheme.highContrast;
      final s = hc.extension<SurfaceTheme>()!;

      final rec = await indicatorOf(tester, InteractionMode.record, theme: hc);
      final mute = await indicatorOf(tester, InteractionMode.mute, theme: hc);
      final fx = await indicatorOf(tester, InteractionMode.fx, theme: hc);

      expect(rec, (s.rec, s.rec, s.rec, s.recSurface));
      expect(mute, (s.success, s.success, s.success, s.successSurface));
      expect(fx, (s.accent, s.accent, s.accent, s.accentSurface));

      // Stated as the reading rather than the hex: the two washes sit at one
      // fill weight, and that weight is the boosted one — a hardcode cannot
      // satisfy this. `accentSurface` is exempt by design: the pen draws it
      // FLAT (opaque in both flavors), not as a wash, so its "boost" is a
      // brighter flat value rather than a heavier alpha. Which flat value is
      // a contrast constraint, held in `test/theme/app_theme_test.dart`
      // (#768), not a free choice.
      expect(rec.$4!.a, mute.$4!.a);
      expect(
        rec.$4!.a,
        greaterThan(SurfaceTheme.dark.recSurface.a),
        reason: 'high contrast must boost the wash, not pin it at 0.16',
      );
      expect(fx.$4!.a, 1.0, reason: 'accentSurface is flat by design');
    });

    testWidgets('Tab is not swallowed by the tracks key handler', (
      tester,
    ) async {
      seed(const LooperState(tracks: [Track()]));
      await pump(tester);

      // The root Focus consumes plain keys (so macOS does not beep) but must
      // let Tab through, or keyboard focus can never reach the tiles (2.1.2).
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(FocusManager.instance.primaryFocus, isNotNull);
      // No exception; the tile targets are focusable.
      expect(find.byType(FocusableTapTarget), findsWidgets);
    });
  });

  group('keyboard-shortcut help', () {
    testWidgets('the chrome carries a labelled help button', (tester) async {
      seed(const LooperState(tracks: [Track()]));
      await pump(tester);

      final l10n = await AppLocalizations.delegate.load(const Locale('en'));
      expect(find.byKey(const Key('tracks_shortcutsHelp')), findsOneWidget);
      expect(find.byTooltip(l10n.a11yShortcutsHelp), findsWidgets);
    });

    testWidgets('the help button opens the legend dialog', (tester) async {
      seed(const LooperState(tracks: [Track()]));
      await pump(tester);

      await tester.tap(find.byKey(const Key('tracks_shortcutsHelp')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('shortcutsHelp_dialog')), findsOneWidget);
    });

    testWidgets('the ? key (Shift+/) opens the legend dialog', (tester) async {
      seed(const LooperState(tracks: [Track()]));
      await pump(tester);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.slash);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('shortcutsHelp_dialog')), findsOneWidget);
    });

    testWidgets('the legend lists a known shortcut', (tester) async {
      seed(const LooperState(tracks: [Track()]));
      await pump(tester);

      await tester.tap(find.byKey(const Key('tracks_shortcutsHelp')));
      await tester.pumpAndSettle();

      final l10n = await AppLocalizations.delegate.load(const Locale('en'));
      // The Space chip and its description both render.
      expect(find.text('Space'), findsOneWidget);
      expect(find.text(l10n.shortcutPlayStopAll), findsOneWidget);
    });

    testWidgets('a row is a single merged Semantics node', (tester) async {
      final handle = tester.ensureSemantics();
      seed(const LooperState(tracks: [Track()]));
      await pump(tester);

      await tester.tap(find.byKey(const Key('tracks_shortcutsHelp')));
      await tester.pumpAndSettle();

      final l10n = await AppLocalizations.delegate.load(const Locale('en'));
      final node = tester.getSemantics(
        find.byKey(const Key('shortcutRow_clear')),
      );
      // Reads as "<keys>: <description>", not two loose fragments.
      expect(node.label, 'C: ${l10n.clearAllTooltip}');
      handle.dispose();
    });

    testWidgets('the modifier chip shows ⌘ on macOS', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      seed(const LooperState(tracks: [Track()]));
      await pump(tester);

      await tester.tap(find.byKey(const Key('tracks_shortcutsHelp')));
      await tester.pumpAndSettle();

      expect(
        find.descendant(
          of: find.byKey(const Key('shortcutRow_undo')),
          matching: find.text('⌘Z'),
        ),
        findsOneWidget,
      );
      // Reset inline: the foundation-var invariant runs at the end of the test
      // body, before tearDown callbacks.
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('the modifier chip shows Ctrl off macOS', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      seed(const LooperState(tracks: [Track()]));
      await pump(tester);

      await tester.tap(find.byKey(const Key('tracks_shortcutsHelp')));
      await tester.pumpAndSettle();

      expect(
        find.descendant(
          of: find.byKey(const Key('shortcutRow_undo')),
          matching: find.text('Ctrl+Z'),
        ),
        findsOneWidget,
      );
      debugDefaultTargetPlatformOverride = null;
    });
  });

  group('session menu', () {
    testWidgets('the session button is present and accessibly labelled', (
      tester,
    ) async {
      seed(const LooperState(tracks: [Track()]));
      await pump(tester);
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));
      expect(find.byKey(const Key('tracks_session_menu')), findsOneWidget);
      expect(find.byTooltip(l10n.a11ySessionMenu), findsOneWidget);
    });

    testWidgets('the folder button opens the Sessions popup', (tester) async {
      seed(const LooperState(tracks: [Track()]));
      await pump(tester);
      await tester.tap(find.byKey(const Key('tracks_session_menu')));
      await tester.pumpAndSettle();
      verify(session.refreshSessions).called(1);
      expect(find.byKey(const Key('sessions_manager')), findsOneWidget);
    });

    testWidgets('the top bar shows "Unsaved" with no open session', (
      tester,
    ) async {
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));
      seed(const LooperState(tracks: [Track()]));
      await pump(tester);
      final label = tester.widget<AppText>(
        find.byKey(const Key('tracks_session_name')),
      );
      expect(label.data, l10n.sessionUnsaved);
    });

    testWidgets('the top bar shows the current session name', (tester) async {
      when(
        () => session.state,
      ).thenReturn(const SessionState(currentSessionName: 'Verse'));
      seed(const LooperState(tracks: [Track()]));
      await pump(tester);
      expect(
        tester
            .widget<AppText>(find.byKey(const Key('tracks_session_name')))
            .data,
        'Verse',
      );
    });

    testWidgets('Cmd/Ctrl+S writes back through the cubit', (tester) async {
      seed(const LooperState(tracks: [Track()]));
      await pump(tester);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      verify(session.save).called(1);
    });

    testWidgets('a save-as request opens the name dialog', (tester) async {
      whenListen(
        session,
        Stream.fromIterable(const [
          SessionState(outcome: SessionOutcome.saveAsRequested),
        ]),
        initialState: const SessionState(),
      );
      seed(const LooperState(tracks: [Track()]));
      await pump(tester);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('sessionName_field')), findsOneWidget);
    });

    testWidgets('a success outcome surfaces a live-region SnackBar', (
      tester,
    ) async {
      whenListen(
        session,
        Stream.fromIterable(const [
          SessionState(status: SessionStatus.working),
          SessionState(
            status: SessionStatus.success,
            outcome: SessionOutcome.saved,
          ),
        ]),
        initialState: const SessionState(),
      );
      seed(const LooperState(tracks: [Track()]));
      await pump(tester);
      await tester.pump(); // deliver the emitted states

      final handle = tester.ensureSemantics();
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));
      expect(find.text(l10n.sessionSaved), findsOneWidget);
      // The SnackBar content is wrapped in a live region (WCAG 4.1.3).
      expect(
        tester.getSemantics(find.text(l10n.sessionSaved)),
        isSemantics(isLiveRegion: true),
      );
      handle.dispose();
    });

    testWidgets('a sample-rate mismatch surfaces the localized error', (
      tester,
    ) async {
      whenListen(
        session,
        Stream.fromIterable(const [
          SessionState(status: SessionStatus.working),
          SessionState(
            status: SessionStatus.failure,
            error: SessionError.sampleRateMismatch,
            errorMessage: 'session sample rate 44100 Hz does not match …',
          ),
        ]),
        initialState: const SessionState(),
      );
      seed(const LooperState(tracks: [Track()]));
      await pump(tester);
      await tester.pump();

      final l10n = await AppLocalizations.delegate.load(const Locale('en'));
      expect(find.text(l10n.sessionErrorSampleRate), findsOneWidget);
    });
  });

  group('performance recorder', () {
    testWidgets('A toggles arm', (tester) async {
      seed(const LooperState(tracks: [Track()]));
      await pump(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.pump();
      verify(performanceRecorder.toggleArm).called(1);
    });

    testWidgets(
      'a boot-time salvage emission opens no dialog — crash recovery runs '
      'silently in the repository, and even its busy flag is not a prompt '
      '(#679)',
      (tester) async {
        whenListen(
          performanceRecorder,
          Stream.fromIterable(const [
            PerformanceRecorderIdle(recovering: true),
            PerformanceRecorderIdle(),
          ]),
          initialState: const PerformanceRecorderIdle(),
        );
        seed(const LooperState(tracks: [Track()]));
        await pump(tester);
        await tester.pump();

        expect(find.byType(ConsoleDialogShell), findsNothing);
      },
    );

    testWidgets('a completed capture opens the completion sheet', (
      tester,
    ) async {
      whenListen(
        performanceRecorder,
        Stream.fromIterable(const [
          PerformanceRecorderCompleted(PerformanceRecordDone('/tmp/perf-1')),
        ]),
        initialState: const PerformanceRecorderRendering(percent: 100),
      );
      seed(const LooperState(tracks: [Track()]));
      await pump(tester);
      await tester.pump();

      expect(find.byKey(const Key('perfCompletion_sheet')), findsOneWidget);
    });

    testWidgets(
      'a short-capture auto-discard shows a SnackBar, not the completion '
      'sheet',
      (tester) async {
        whenListen(
          performanceRecorder,
          Stream.fromIterable(const [
            PerformanceRecorderCompleted.discardedShort(),
          ]),
          initialState: const PerformanceRecorderRendering(percent: 100),
        );
        seed(const LooperState(tracks: [Track()]));
        await pump(tester);
        await tester.pump();

        final l10n = await AppLocalizations.delegate.load(const Locale('en'));
        expect(find.text(l10n.perfDiscarded), findsOneWidget);
        expect(find.byKey(const Key('perfCompletion_sheet')), findsNothing);
      },
    );

    testWidgets(
      'renaming (re-emitting Completed with a different path) does not '
      'reopen the completion sheet once dismissed',
      (tester) async {
        final controller = StreamController<PerformanceRecorderState>();
        addTearDown(controller.close);
        whenListen(
          performanceRecorder,
          controller.stream,
          initialState: const PerformanceRecorderRendering(percent: 100),
        );
        seed(const LooperState(tracks: [Track()]));
        await pump(tester);

        controller.add(
          const PerformanceRecorderCompleted(
            PerformanceRecordDone('/tmp/perf-1'),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('perfCompletion_sheet')), findsOneWidget);

        await tester.tap(find.byKey(const Key('perfCompletion_close')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('perfCompletion_sheet')), findsNothing);

        // The "rename" — a second Completed with a different path — must not
        // reopen the sheet the user already dismissed.
        controller.add(
          const PerformanceRecorderCompleted(
            PerformanceRecordDone('/tmp/renamed'),
          ),
        );
        await tester.pump();
        expect(find.byKey(const Key('perfCompletion_sheet')), findsNothing);
      },
    );
  });

  group('transport controls', () {
    // A connected engine holding recorded audio — the state in which the
    // global transport buttons are live.
    LooperState connected({
      List<Track> tracks = const [
        Track(state: TrackState.stopped, lengthFrames: 100),
      ],
    }) => LooperState(
      tracks: tracks,
      status: const EngineStatus(isConnected: true),
    );

    testWidgets('play/stop all and clear all render', (tester) async {
      seed(connected());
      await pump(tester);

      expect(find.byKey(const Key('tracks_playStopAll')), findsOneWidget);
      expect(find.byKey(const Key('tracks_clearAll')), findsOneWidget);
      // With nothing playing, the toggle shows the play icon.
      final icon = tester.widget<Icon>(
        find.descendant(
          of: find.byKey(const Key('tracks_playStopAll')),
          matching: find.byType(Icon),
        ),
      );
      expect(icon.icon, Icons.play_arrow);
    });

    testWidgets('play all dispatches when nothing is playing', (tester) async {
      seed(connected());
      await pump(tester);

      await tester.tap(find.byKey(const Key('tracks_playStopAll')));
      verify(() => bloc.add(const LooperPlayAllPressed())).called(1);
    });

    testWidgets('the toggle shows stop and stops all when a track is active', (
      tester,
    ) async {
      seed(
        connected(
          tracks: const [Track(state: TrackState.playing, lengthFrames: 100)],
        ),
      );
      await pump(tester);

      // Icon flips to stop while a track is active.
      final icon = tester.widget<Icon>(
        find.descendant(
          of: find.byKey(const Key('tracks_playStopAll')),
          matching: find.byType(Icon),
        ),
      );
      expect(icon.icon, Icons.stop);

      await tester.tap(find.byKey(const Key('tracks_playStopAll')));
      verify(() => bloc.add(const LooperStopAllPressed())).called(1);
    });

    for (final state in const [TrackState.recording, TrackState.overdubbing]) {
      testWidgets('the toggle reads "active" while $state', (tester) async {
        seed(connected(tracks: [Track(state: state, lengthFrames: 100)]));
        await pump(tester);

        final icon = tester.widget<Icon>(
          find.descendant(
            of: find.byKey(const Key('tracks_playStopAll')),
            matching: find.byType(Icon),
          ),
        );
        expect(icon.icon, Icons.stop);
      });
    }

    testWidgets('clear all announces to assistive tech', (tester) async {
      final announcements = <String>[];
      tester.binding.defaultBinaryMessenger.setMockDecodedMessageHandler(
        SystemChannels.accessibility,
        (message) async {
          final data = message! as Map<dynamic, dynamic>;
          if (data['type'] == 'announce') {
            announcements.add(
              (data['data'] as Map<dynamic, dynamic>)['message'] as String,
            );
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger
            .setMockDecodedMessageHandler(SystemChannels.accessibility, null),
      );

      seed(connected());
      await pump(tester);
      await tester.tap(find.byKey(const Key('tracks_clearAll')));
      await tester.pump();

      final l10n = await AppLocalizations.delegate.load(const Locale('en'));
      // The button shares the keyboard path's announcement (anti-drift).
      expect(announcements, contains(l10n.a11yAllCleared));
    });

    testWidgets('clear all dispatches instantly (no dialog)', (tester) async {
      seed(connected());
      await pump(tester);

      await tester.tap(find.byKey(const Key('tracks_clearAll')));
      // Clear-all is a ControlIntents action straight to the engine.
      verify(() => repository.clear()).called(1);
    });

    testWidgets('both are disabled when the engine is disconnected', (
      tester,
    ) async {
      seed(
        const LooperState(
          tracks: [Track(state: TrackState.stopped, lengthFrames: 100)],
        ),
      );
      await pump(tester);

      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('tracks_playStopAll')))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('tracks_clearAll')))
            .onPressed,
        isNull,
      );
    });

    testWidgets('both are disabled when there is no content', (tester) async {
      seed(
        const LooperState(
          tracks: [Track()],
          status: EngineStatus(isConnected: true),
        ),
      );
      await pump(tester);

      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('tracks_playStopAll')))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('tracks_clearAll')))
            .onPressed,
        isNull,
      );
    });

    testWidgets(
      'play is blocked when every loaded track is muted (clear stays on)',
      (tester) async {
        seed(
          connected(
            tracks: const [
              Track(state: TrackState.stopped, lengthFrames: 100, muted: true),
              Track(
                channel: 1,
                state: TrackState.stopped,
                lengthFrames: 100,
                muted: true,
              ),
            ],
          ),
        );
        await pump(tester);

        // Nothing would sound, so Play All is disabled...
        expect(
          tester
              .widget<IconButton>(
                find.byKey(const Key('tracks_playStopAll')),
              )
              .onPressed,
          isNull,
        );
        // ...but Clear All stays available (there is still content to clear).
        expect(
          tester
              .widget<IconButton>(find.byKey(const Key('tracks_clearAll')))
              .onPressed,
          isNotNull,
        );
      },
    );

    testWidgets('play is allowed when at least one loaded track is unmuted', (
      tester,
    ) async {
      seed(
        connected(
          tracks: const [
            Track(state: TrackState.stopped, lengthFrames: 100, muted: true),
            Track(channel: 1, state: TrackState.stopped, lengthFrames: 100),
          ],
        ),
      );
      await pump(tester);

      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('tracks_playStopAll')))
            .onPressed,
        isNotNull,
      );
      await tester.tap(find.byKey(const Key('tracks_playStopAll')));
      verify(() => bloc.add(const LooperPlayAllPressed())).called(1);
    });

    testWidgets('stop stays available while a muted track is active', (
      tester,
    ) async {
      seed(
        connected(
          tracks: const [
            Track(state: TrackState.playing, lengthFrames: 100, muted: true),
          ],
        ),
      );
      await pump(tester);

      // A muted but active track can still be stopped.
      await tester.tap(find.byKey(const Key('tracks_playStopAll')));
      verify(() => bloc.add(const LooperStopAllPressed())).called(1);
    });

    testWidgets('Space is a no-op when every loaded track is muted', (
      tester,
    ) async {
      seed(
        connected(
          tracks: const [
            Track(state: TrackState.stopped, lengthFrames: 100, muted: true),
          ],
        ),
      );
      await pump(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      verifyNever(() => bloc.add(const LooperPlayAllPressed()));
    });

    testWidgets('fullscreen button renders on desktop and is tappable', (
      tester,
    ) async {
      // Reset inline (not via addTearDown): the foundation-var invariant check
      // runs at the end of the test body, before tearDown callbacks.
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      seed(connected());
      await pump(tester);

      expect(find.byKey(const Key('tracks_fullscreen')), findsOneWidget);
      // The helper swallows the missing platform channel in tests.
      await tester.tap(find.byKey(const Key('tracks_fullscreen')));
      await tester.pump();
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('fullscreen button is absent off desktop windowing', (
      tester,
    ) async {
      // A mobile target stands in for "not desktop windowing" (the gate also
      // hides the button on web).
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      seed(connected());
      await pump(tester);

      expect(find.byKey(const Key('tracks_fullscreen')), findsNothing);
      debugDefaultTargetPlatformOverride = null;
    });
  });

  group('per-track undo/redo', () {
    testWidgets('appear only on the selected column', (tester) async {
      control.selectTrack(0);
      seed(
        const LooperState(
          tracks: [
            Track(lengthFrames: 100, state: TrackState.stopped),
            Track(channel: 1, lengthFrames: 100, state: TrackState.stopped),
          ],
          status: EngineStatus(isConnected: true),
        ),
      );
      await pump(tester);

      expect(find.byKey(const Key('tracks_undo_0')), findsOneWidget);
      expect(find.byKey(const Key('tracks_redo_0')), findsOneWidget);
      expect(find.byKey(const Key('tracks_undo_1')), findsNothing);
      expect(find.byKey(const Key('tracks_redo_1')), findsNothing);
    });

    testWidgets('undo dispatches for the selected channel', (tester) async {
      control.selectTrack(0);
      seed(
        const LooperState(
          tracks: [Track(lengthFrames: 100, state: TrackState.stopped)],
        ),
      );
      await pump(tester);

      await tester.tap(find.byKey(const Key('tracks_undo_0')));
      verify(() => bloc.add(const LooperUndoPressed(0))).called(1);
    });

    testWidgets('undo is disabled when the track has no content', (
      tester,
    ) async {
      control.selectTrack(0);
      seed(const LooperState(tracks: [Track()]));
      await pump(tester);

      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('tracks_undo_0')))
            .onPressed,
        isNull,
      );
    });

    testWidgets('redo is disabled with no redo history', (tester) async {
      control.selectTrack(0);
      seed(
        const LooperState(
          tracks: [Track(lengthFrames: 100, state: TrackState.stopped)],
        ),
      );
      await pump(tester);

      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('tracks_redo_0')))
            .onPressed,
        isNull,
      );
    });

    testWidgets('redo dispatches when a layer can be redone', (tester) async {
      control.selectTrack(0);
      seed(
        const LooperState(
          tracks: [
            Track(lengthFrames: 100, state: TrackState.stopped, redoDepth: 1),
          ],
        ),
      );
      await pump(tester);

      await tester.tap(find.byKey(const Key('tracks_redo_0')));
      verify(() => bloc.add(const LooperRedoPressed(0))).called(1);
    });

    testWidgets('the tooltips name the macOS shortcut', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      control.selectTrack(0);
      seed(
        const LooperState(
          tracks: [Track(lengthFrames: 100, state: TrackState.stopped)],
        ),
      );
      await pump(tester);

      final l10n = await AppLocalizations.delegate.load(const Locale('en'));
      expect(find.byTooltip(l10n.undoTooltip('⌘Z')), findsOneWidget);
      expect(find.byTooltip(l10n.redoTooltip('⌘⇧Z')), findsOneWidget);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('the tooltips use Ctrl off macOS', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      control.selectTrack(0);
      seed(
        const LooperState(
          tracks: [Track(lengthFrames: 100, state: TrackState.stopped)],
        ),
      );
      await pump(tester);

      final l10n = await AppLocalizations.delegate.load(const Locale('en'));
      expect(find.byTooltip(l10n.undoTooltip('Ctrl+Z')), findsOneWidget);
      expect(find.byTooltip(l10n.redoTooltip('Ctrl+Y')), findsOneWidget);
      debugDefaultTargetPlatformOverride = null;
    });
  });

  group('keyboard refactor parity', () {
    testWidgets('U undoes the selected track', (tester) async {
      seed(const LooperState(tracks: [Track(), Track(channel: 1)]));
      await pump(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyU);
      await tester.pump();
      verify(() => bloc.add(const LooperUndoPressed(1))).called(1);
    });

    testWidgets('Ctrl+Y redoes the selected track', (tester) async {
      seed(const LooperState(tracks: [Track()]));
      await pump(tester);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyY);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      verify(() => bloc.add(const LooperRedoPressed(0))).called(1);
    });

    testWidgets('Cmd/Ctrl+Z undoes and Cmd/Ctrl+Shift+Z redoes', (
      tester,
    ) async {
      seed(const LooperState(tracks: [Track()]));
      await pump(tester);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      verify(() => bloc.add(const LooperUndoPressed(0))).called(1);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      verify(() => bloc.add(const LooperRedoPressed(0))).called(1);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    });
  });

  group('rebuild scope', () {
    // The whole point of #646: a level tick must not rebuild the console.
    // `TracksView.build` creates this GestureDetector fresh every run (it
    // carries closures, so it is never const-canonicalised), which makes widget
    // identity an honest rebuild detector: the same instance across a pump
    // means the method did not re-run.
    //
    // The probe is the keyed detector rather than `TracksToolbar` because the
    // toolbar is compiled out when `kConsoleMode` is true -- and the console is
    // the build whose frame budget prompted this. Probing something both
    // layouts contain keeps the guard meaningful under
    // `--dart-define=SEGNO_CONSOLE=true` instead of throwing on a missing
    // widget.
    late StreamController<LooperState> states;

    setUp(() => states = StreamController<LooperState>.broadcast());
    tearDown(() => states.close());

    void seedStream(LooperState initial) {
      when(() => bloc.state).thenReturn(initial);
      when(() => repository.state).thenReturn(initial);
      whenListen(bloc, states.stream, initialState: initial);
    }

    testWidgets('a level-only change does not rebuild the chrome', (
      tester,
    ) async {
      const quiet = LooperState(
        tracks: [Track(), Track(channel: 1)],
        status: EngineStatus(isConnected: true),
      );
      seedStream(quiet);
      await pump(tester);

      final before = tester.widget<GestureDetector>(_chromeProbe);

      // Exactly what a moving meter emits: same structure, new levels and a
      // new playhead. Nothing the chrome renders depends on any of it.
      const loud = LooperState(
        tracks: [
          Track(rms: 0.8, peak: 0.9, playheadFrames: 4410),
          Track(channel: 1, rms: 0.5, peak: 0.6, playheadFrames: 4410),
        ],
        status: EngineStatus(isConnected: true),
      );
      when(() => bloc.state).thenReturn(loud);
      states.add(loud);
      await tester.pump();

      expect(
        identical(before, tester.widget<GestureDetector>(_chromeProbe)),
        isTrue,
        reason:
            'a meter tick rebuilt TracksView -- the selector is leaking '
            'live audio fields (see #646)',
      );
    });

    testWidgets('a structural change still rebuilds the chrome', (
      tester,
    ) async {
      const connected = LooperState(
        tracks: [Track()],
        status: EngineStatus(isConnected: true),
      );
      seedStream(connected);
      await pump(tester);

      final before = tester.widget<GestureDetector>(_chromeProbe);

      // Losing the engine is exactly the kind of change the chrome exists to
      // show: it must get through the selector.
      const lost = LooperState(tracks: [Track()]);
      when(() => bloc.state).thenReturn(lost);
      states.add(lost);
      await tester.pump();

      expect(
        identical(before, tester.widget<GestureDetector>(_chromeProbe)),
        isFalse,
        reason: 'the selector swallowed a structural change',
      );
      expect(find.byType(AudioNotRunningBanner), findsOneWidget);
    });
  });
}
