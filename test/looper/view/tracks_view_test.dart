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
import 'package:segno/app/app_toasts.dart';
import 'package:segno/audio_setup/audio_setup.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/control/control.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/cubit/settings_tray_cubit.dart';
import 'package:segno/looper/looper.dart';
import 'package:segno/looper/view/settings_tray.dart';
import 'package:segno/looper/view/track_column.dart';
import 'package:segno/looper/view/tracks_chrome.dart';
import 'package:segno/performance/performance.dart';
import 'package:segno/session/session.dart';
import 'package:segno/theme/theme.dart';
import 'package:settings_repository/settings_repository.dart';
import 'package:toastification/toastification.dart';

import '../../helpers/helpers.dart';

class _MockLooperBloc extends MockBloc<LooperEvent, LooperState>
    implements LooperBloc {}

class _MockLooperRepository extends Mock implements LooperRepository {}

class _MockTransportClockCubit extends MockCubit<TransportClockState>
    implements TransportClockCubit {}

class _MockSessionCubit extends MockCubit<SessionState>
    implements SessionCubit {}

class _MockPerformanceRecorderCubit extends MockCubit<PerformanceRecorderState>
    implements PerformanceRecorderCubit {}

class _MockAudioSetupCubit extends MockCubit<AudioSetupState>
    implements AudioSetupCubit {}

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
  late TransportClockCubit transportClock;
  late AudioSetupCubit audioSetup;

  setUp(() {
    // The toast registry is module-level and survives between tests; a stale
    // entry would make the next identical toast a silent duplicate. The
    // `toastification` singleton leaks too, across files, under
    // `--optimization` (#875) — reset both so this test's toasts get a live
    // overlay regardless of what ran before.
    resetAppToastsForTest();
    resetToastificationForTest();
    addTearDown(() => dismissAppToast(AppToastId.undoClearAll));
    settings = SettingsRepository(store: FakeKeyValueStore());
    bloc = _MockLooperBloc();
    audioSetup = _MockAudioSetupCubit();
    whenListen(
      audioSetup,
      const Stream<AudioSetupState>.empty(),
      initialState: const AudioSetupState(),
    );
    tracks = TracksCubit(settings: settings);
    repository = _MockLooperRepository();
    when(() => repository.readTrackWaveform(any())).thenReturn(Float32List(0));
    when(() => repository.state).thenReturn(const LooperState());
    // The FX-chain announcement reads the repository's remembered intent —
    // the same value the bloc's toggle handler negates.
    when(() => repository.trackChainEnabled(any())).thenReturn(true);
    when(
      () => repository.monitorChanges,
    ).thenAnswer((_) => const Stream<int>.empty());
    when(
      () => repository.monitorParamChanges,
    ).thenAnswer((_) => const Stream<int>.empty());
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
    // The stage status bar is unconditional now; its tempo/clock readout
    // selects a TransportClockCubit. Mocked so no tick timer outlives a pump.
    transportClock = _MockTransportClockCubit();
    whenListen(
      transportClock,
      const Stream<TransportClockState>.empty(),
      initialState: const TransportClockState(),
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

  // The post-clear-all toast renders into a toastification overlay, which
  // needs the app's Navigator above it (hence wrapping MaterialApp, not its
  // child). Inert for the tests that never raise a toast.
  Future<void> pump(WidgetTester tester) => tester.pumpWidget(
    ToastificationWrapper(
      child: MaterialApp(
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
              BlocProvider<TransportClockCubit>.value(value: transportClock),
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
              // The device-lost banner and the not-running gate read the
              // audio setup cubit (#453).
              BlocProvider<AudioSetupCubit>.value(value: audioSetup),
            ],
            child: const TracksView(),
          ),
        ),
      ),
    ),
  );

  // A clear-all on a rig with content now raises the undo toast, which mounts a
  // frame late and, once shown, holds a ~6s auto-close timer plus toast
  // animation timers. Any test that clears content must drain them or the zone
  // fails on a pending timer after teardown (the leak the first attempt hit).
  //
  // Dismissing cancels the auto-close timer, but `pumpAndSettle` stops at the
  // end of the exit animation and leaves the bare Timer `toastification`
  // schedules to retire the overlay entry still pending — enough to trip the
  // post-teardown timer check, and enough to leave the global manager's
  // overlay dead so the NEXT test's toast renders into nothing and is never
  // found. Pump a fixed span past that teardown timer instead (the same
  // global-`toastification` trap `app_test.dart` documents around its own
  // failure toast).
  Future<void> settleToasts(WidgetTester tester) async {
    await tester.pumpAndSettle(); // mount + finish the entrance animation
    dismissAppToast(AppToastId.undoClearAll); // cancels the auto-close timer
    // Past the removal animation and the overlay teardown it schedules.
    await tester.pump(const Duration(seconds: 10));
  }

  testWidgets('every tap target on the performance surface is labeled '
      '(labeledTapTargetGuideline)', (tester) async {
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
  });

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
    verify(() => bloc.add(const LooperTrackChainToggled(1))).called(1);
    verifyNever(() => bloc.add(const LooperRecordPressed(1)));
    verifyNever(() => bloc.add(const LooperMuteToggled(1)));
  });

  testWidgets('the number keys toggle FX chains in FX mode', (tester) async {
    control.setMode(InteractionMode.fx);
    seed(const LooperState(tracks: [Track(), Track(channel: 1)]));
    await pump(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
    await tester.pump();

    verify(() => bloc.add(const LooperTrackChainToggled(1))).called(1);
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

  group('FX-mode stage transform (#692)', () {
    // A track with a real two-entry chain, so the entry run has chips to draw.
    // Not const: BuiltInEffect is not a const constructor.
    final chainedTrack = Track(
      effects: [
        BuiltInEffect(type: TrackEffectType.drive),
        BuiltInEffect(type: TrackEffectType.reverb),
      ],
    );

    testWidgets('an engaged chain re-dresses the tile with an ON power pill '
        'and its entries in signal order', (tester) async {
      control.setMode(InteractionMode.fx);
      seed(LooperState(tracks: [chainedTrack]));
      await pump(tester);

      // The cell is named CHAIN-FIRST (#692): its bound chain's target and the
      // chain itself — TRACK 1 (its own Track-stage chain, the default target)
      // and the head effect — never the track's own name as the cell identity.
      expect(find.byKey(const Key('tracks_tileFxTarget')), findsOneWidget);
      expect(find.text('TRACK 1 · DRIVE'), findsOneWidget);
      // The dominant power pill states the whole chain's on/off…
      expect(find.byKey(const Key('tracks_tileFxPower')), findsOneWidget);
      expect(find.text('ON'), findsOneWidget);
      // …and the entries read as chips in processing order.
      expect(find.byKey(const Key('tracks_tileFxEntryRun')), findsOneWidget);
      expect(find.text('Drive'), findsOneWidget);
      expect(find.text('Reverb'), findsOneWidget);
    });

    testWidgets('a bypassed chain shows an OFF pill and dims its entry run', (
      tester,
    ) async {
      control.setMode(InteractionMode.fx);
      seed(
        LooperState(
          tracks: [
            Track(
              chainEnabled: false,
              effects: [BuiltInEffect(type: TrackEffectType.drive)],
            ),
          ],
        ),
      );
      await pump(tester);

      expect(find.text('OFF'), findsOneWidget);
      // A switched-off chain is still named, but dimmed (R26) rather than
      // hidden — the entries stay on the tile so the player sees what is out.
      final runOpacity = tester.widget<Opacity>(
        find
            .ancestor(
              of: find.byKey(const Key('tracks_tileFxEntryRun')),
              matching: find.byType(Opacity),
            )
            .first,
      );
      expect(runOpacity.opacity, lessThan(1));
      expect(find.text('Drive'), findsOneWidget);
    });

    testWidgets('an empty track says NO CHAIN and shows no power pill', (
      tester,
    ) async {
      control.setMode(InteractionMode.fx);
      seed(const LooperState(tracks: [Track()]));
      await pump(tester);

      expect(find.byKey(const Key('tracks_tileFxNoChain')), findsOneWidget);
      expect(find.text('NO CHAIN'), findsOneWidget);
      // Nothing to power and no chain to name: the whole centered group is
      // replaced by NO CHAIN, so neither the pill, the entry run, nor the
      // TARGET · CHAIN identity is drawn.
      expect(find.byKey(const Key('tracks_tileFxTarget')), findsNothing);
      expect(find.byKey(const Key('tracks_tileFxPower')), findsNothing);
      expect(find.byKey(const Key('tracks_tileFxEntryRun')), findsNothing);
    });

    testWidgets('the stage takes the FX surface only in FX mode', (
      tester,
    ) async {
      final fxSurface = AppTheme.neon.extension<SurfaceTheme>()!.fxSurface;
      Iterable<Color?> scaffoldBackgrounds() => tester
          .widgetList<Scaffold>(find.byType(Scaffold))
          .map((s) => s.backgroundColor);

      seed(LooperState(tracks: [chainedTrack]));
      await pump(tester);
      // Record mode: no stage takes the FX surface.
      expect(scaffoldBackgrounds(), isNot(contains(fxSurface)));

      control.setMode(InteractionMode.fx);
      await tester.pump();
      // FX mode: the stage does.
      expect(scaffoldBackgrounds(), contains(fxSurface));
    });

    testWidgets('leaving FX mode restores the tile exactly', (tester) async {
      control.setMode(InteractionMode.fx);
      seed(LooperState(tracks: [chainedTrack]));
      await pump(tester);
      expect(find.byKey(const Key('tracks_tileFxPower')), findsOneWidget);

      // Back to record: the dressing is gone and the tile is its plain self —
      // the geometry and keys never moved, only the dressing came and went.
      control.setMode(InteractionMode.record);
      await tester.pump();
      expect(find.byKey(const Key('tracks_tileFxPower')), findsNothing);
      expect(find.byKey(const Key('tracks_tileFxEntryRun')), findsNothing);
      expect(find.text('ON'), findsNothing);
      // The chain-first identity is an FX-mode dressing too: gone with the
      // rest, and the track name label returns to identify the column.
      expect(find.byKey(const Key('tracks_tileFxTarget')), findsNothing);
      // The tile itself — its key, its tap target — is untouched.
      expect(find.byKey(const Key('tracks_tile_0')), findsOneWidget);
    });

    testWidgets('the FX-mode tap still toggles the chain past the dressing', (
      tester,
    ) async {
      // The dressing is an IgnorePointer overlay, so the tile tap that toggles
      // the chain must still land — the footswitch/tap map is frozen (#692).
      control.setMode(InteractionMode.fx);
      seed(LooperState(tracks: [chainedTrack]));
      await pump(tester);

      await tester.tap(find.byKey(const Key('tracks_tile_0')));
      verify(() => bloc.add(const LooperTrackChainToggled(0))).called(1);
    });
  });

  group('FX-mode cell identity is chain-first, never the track (#692)', () {
    // These pump a TrackColumn DIRECTLY so the bound chain's FX target can be
    // injected — the on-screen stage wires every column to its own Track
    // chain, so a non-track target (e.g. Master) cannot reach the cell through
    // TracksView, but the cell must still name it and never the column's track.
    Future<void> pumpColumn(
      WidgetTester tester, {
      required Track track,
      required String name,
      required InteractionMode mode,
      FxAddress? fxTarget,
      Map<int, String> inputNames = const {},
    }) {
      seed(LooperState(tracks: [track]));
      return tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.neon,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: MultiRepositoryProvider(
            providers: [
              RepositoryProvider<LooperRepository>.value(value: repository),
            ],
            child: MultiBlocProvider(
              providers: [
                BlocProvider<LooperBloc>.value(value: bloc),
                BlocProvider<TransportClockCubit>.value(value: transportClock),
                BlocProvider<TracksCubit>.value(value: tracks),
                BlocProvider<ControlCubit>.value(value: control),
              ],
              child: Scaffold(
                body: Center(
                  child: SizedBox(
                    width: 200,
                    height: 600,
                    child: TrackColumn(
                      track: track,
                      name: name,
                      selected: false,
                      mode: mode,
                      fxTarget: fxTarget,
                      inputNames: inputNames,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    testWidgets("a chain on the column's own track reads TRACK n · CHAIN, "
        'not the track name', (tester) async {
      await pumpColumn(
        tester,
        // A custom name distinct from its stage label, so borrowing it as the
        // identity would be visible — the default name is itself "TRACK n".
        name: 'GUITAR',
        mode: InteractionMode.fx,
        track: Track(
          channel: 2,
          effects: [BuiltInEffect(type: TrackEffectType.filter)],
        ),
      );

      // Chain-first: the default Track-stage target (TRACK 3, 1-based) and the
      // chain's head effect — never GUITAR as the cell identity.
      expect(find.text('TRACK 3 · FILTER'), findsOneWidget);
      expect(find.text('GUITAR'), findsNothing);
    });

    testWidgets('a bound chain targeting a NON-track stage reads that stage, '
        'not the column track', (tester) async {
      await pumpColumn(
        tester,
        name: 'GUITAR',
        mode: InteractionMode.fx,
        // The footswitch over the GUITAR column is bound to the MASTER insert's
        // chain: the cell must say MASTER, never TRACK 1 / GUITAR.
        fxTarget: const FxAddress(stage: FxStage.master),
        track: Track(effects: [BuiltInEffect(type: TrackEffectType.reverb)]),
      );

      expect(find.text('MASTER · REVERB'), findsOneWidget);
      expect(find.text('GUITAR'), findsNothing);
      expect(find.textContaining('TRACK'), findsNothing);
    });

    testWidgets('a NAMED input reads its name over a smaller INPUT n, chain '
        'in the chips', (tester) async {
      await pumpColumn(
        tester,
        name: 'TRACK 5',
        mode: InteractionMode.fx,
        // A footswitch bound to input socket 0's monitor chain, and the player
        // has named that socket "Guitar".
        fxTarget: const FxAddress(stage: FxStage.input),
        inputNames: const {0: 'Guitar'},
        track: Track(effects: [BuiltInEffect(type: TrackEffectType.filter)]),
      );

      // Two tiers: the socket's own name on the primary line, a smaller
      // INPUT 1 beneath it. The chain is NOT jammed into the identity — it
      // reads from the entry-run chip.
      expect(find.text('GUITAR'), findsOneWidget); // primary, uppercased
      expect(find.byKey(const Key('tracks_tileFxTargetSub')), findsOneWidget);
      expect(find.text('INPUT 1'), findsOneWidget); // sub-label
      expect(find.text('Filter'), findsOneWidget); // chain, in the chips
      // The identity line carries no "· CHAIN" for a named input.
      expect(find.textContaining('·'), findsNothing);
    });

    testWidgets('an UNNAMED input reads a single INPUT n line', (tester) async {
      await pumpColumn(
        tester,
        name: 'TRACK 5',
        mode: InteractionMode.fx,
        fxTarget: const FxAddress(stage: FxStage.input, index: 1),
        // No name for socket 1.
        track: Track(effects: [BuiltInEffect(type: TrackEffectType.filter)]),
      );

      // Single line, the generic stage label — no name, no second tier.
      expect(find.text('INPUT 2'), findsOneWidget);
      expect(find.byKey(const Key('tracks_tileFxTargetSub')), findsNothing);
      expect(find.text('Filter'), findsOneWidget); // chain, in the chips
    });

    testWidgets('leaving FX mode brings the track name back as the identity', (
      tester,
    ) async {
      await pumpColumn(
        tester,
        name: 'GUITAR',
        mode: InteractionMode.record,
        track: Track(effects: [BuiltInEffect(type: TrackEffectType.reverb)]),
      );

      // Outside FX mode the column is the track again: its name identifies it,
      // and no chain-first identity is drawn.
      expect(find.text('GUITAR'), findsOneWidget);
      expect(find.byKey(const Key('tracks_tileFxTarget')), findsNothing);
    });
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

    // Bank B -> channels 4-7. The stage bank pair is a readout (the feet
    // switch banks), so drive the cubit rather than tapping it.
    control.browseBank(1);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tracks_tile_4')), findsOneWidget);
    expect(find.byKey(const Key('tracks_tile_7')), findsOneWidget);
    expect(find.byKey(const Key('tracks_tile_0')), findsNothing);
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
        const LooperState(tracks: [Track(), Track(channel: 1)]),
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

    testWidgets('tapping a non-primary track crowns it (dispatches '
        'LooperCrownPrimaryPressed)', (tester) async {
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

      verify(() => bloc.add(const LooperCrownPrimaryPressed(1))).called(1);
    });

    testWidgets("the current primary track's own badge is inert — no un-crown "
        'gesture exists (D18)', (tester) async {
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
    });
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
      await settleToasts(tester); // clearing content raises the undo toast
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
    await tester.pumpAndSettle();

    // The console rename sheet reads KeyEvent.character, so it takes keys
    // directly rather than an enterText into a field; Enter is Save.
    for (var i = 0; i < 'TRACK 1'.length; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    }
    for (final ch in 'GUITAR'.split('')) {
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA, character: ch);
    }
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
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

      expect(borderColor(0), Colors.white); // selected: 4px white ring
      // Unselected: the pen's 1px near-black card hairline (the `card` token),
      // not borderless.
      expect(borderColor(1), AppTheme.neon.extension<SurfaceTheme>()!.card);
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

    // The strip is off by default on the console (the pedals carry readiness),
    // so every test here that expects one has to turn the pref on first.
    setUp(() async => tracks.setShowIndicators(value: true));

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

      // Bank B, then select channel 4.
      control.browseBank(1);
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

      expect(find.byKey(const Key('tracks_audioNotRunning')), findsOneWidget);
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

      final node = tester.getSemantics(find.byKey(const Key('tracks_tile_0')));
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

    testWidgets('the stage bank pair shows which bank is live', (tester) async {
      seed(
        LooperState(tracks: [for (var i = 0; i < 8; i++) Track(channel: i)]),
      );
      await pump(tester);

      // A readout, not a control -- the feet switch banks -- so this asserts
      // what it displays rather than a selected/button semantics role.
      expect(find.byKey(const Key('stage_bank_pair')), findsOneWidget);
      expect(find.byKey(const Key('stage_bank_0')), findsOneWidget);
      expect(find.byKey(const Key('stage_bank_1')), findsOneWidget);

      control.browseBank(1);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('tracks_tile_4')), findsOneWidget);
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

    testWidgets(
      'Cmd/Ctrl+Shift+C restores every track holding a clear restore point',
      (tester) async {
        seed(
          const LooperState(
            tracks: [
              Track(clearRestore: true),
              Track(channel: 1, state: TrackState.playing, lengthFrames: 48000),
              Track(channel: 2, clearRestore: true),
            ],
          ),
        );
        when(
          () => repository.undo(channel: any(named: 'channel')),
        ).thenReturn(EngineResult.ok);
        await pump(tester);

        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);

        // The whole rig comes back: exactly the pending-clear channels.
        verify(() => repository.undo()).called(1);
        verify(() => repository.undo(channel: 2)).called(1);
        verifyNever(() => repository.undo(channel: 1));
      },
    );

    testWidgets(
      'Cmd/Ctrl+Shift+C is inert when no clear restore point is pending',
      (tester) async {
        seed(
          const LooperState(
            tracks: [Track(state: TrackState.playing, lengthFrames: 48000)],
          ),
        );
        when(
          () => repository.undo(channel: any(named: 'channel')),
        ).thenReturn(EngineResult.ok);
        await pump(tester);

        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);

        verifyNever(() => repository.undo(channel: any(named: 'channel')));
      },
    );
  });

  group('undo-clear-all toast', () {
    testWidgets(
      'a clear-all raises a toast whose action restores the whole rig',
      (tester) async {
        seed(
          const LooperState(
            tracks: [
              Track(
                state: TrackState.playing,
                lengthFrames: 48000,
                clearRestore: true,
              ),
            ],
          ),
        );
        when(
          () => repository.undo(channel: any(named: 'channel')),
        ).thenReturn(EngineResult.ok);
        await pump(tester);

        // Every surface's clear-all lands in ControlCubit.clearAll, which
        // fires the cue the view listens for. pumpAndSettle so the toast's
        // entrance animation completes and it is present to find.
        await control.clearAll();
        await tester.pumpAndSettle();
        expect(find.byKey(const Key(AppToastId.undoClearAll)), findsOneWidget);

        await tester.tap(find.byKey(const Key(AppToastId.undoClearAllAction)));
        // The action restores the rig and dismisses its own toast. Pump past
        // the exit animation AND the bare Timer `toastification` schedules to
        // retire the overlay entry, so nothing outlives the test (the leak the
        // first attempt hit) and the global overlay is clean for the next one.
        await tester.pumpAndSettle();
        await tester.pump(const Duration(seconds: 10));

        verify(() => repository.undo()).called(1);
        expect(find.byKey(const Key(AppToastId.undoClearAll)), findsNothing);
      },
    );

    testWidgets('an empty-rig clear-all shows no toast', (tester) async {
      seed(const LooperState(tracks: [Track()]));
      await pump(tester);

      // Nothing to restore, so clearAll never fires the cue — no toast, no
      // lingering timer.
      await control.clearAll();
      await tester.pumpAndSettle();

      expect(find.byKey(const Key(AppToastId.undoClearAll)), findsNothing);
    });
  });

  group('rebuild scope', () {
    // The whole point of #646: a level tick must not rebuild the console.
    // `TracksView.build` creates this GestureDetector fresh every run (it
    // carries closures, so it is never const-canonicalised), which makes widget
    // identity an honest rebuild detector: the same instance across a pump
    // means the method did not re-run.
    //
    // The probe is the keyed detector rather than `TracksToolbar`, which went
    // with the desktop build -- and the console is the build whose frame
    // budget prompted this guard in the first place.
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
