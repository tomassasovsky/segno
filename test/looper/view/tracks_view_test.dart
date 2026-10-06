import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:performance_repository/performance_repository.dart';
import 'package:routing_graph/routing_graph.dart' show FocusableTapTarget;
import 'package:segno/app/app_toasts.dart';
import 'package:segno/app/application/owned_value_port.dart';
import 'package:segno/app/fx_chain_persistence.dart';
import 'package:segno/app/mix_settings_coordinator.dart';
import 'package:segno/app/segno_navigator.dart';
import 'package:segno/appliance/display_brightness_cubit.dart';
import 'package:segno/audio_setup/audio_setup.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/control/control.dart';
import 'package:segno/control/model/foot_mixer.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/cubit/settings_tray_cubit.dart';
import 'package:segno/looper/looper.dart';
import 'package:segno/looper/view/foot_mixer_view.dart';
import 'package:segno/looper/view/mixer_column.dart';
import 'package:segno/looper/view/settings_tray.dart';
import 'package:segno/looper/view/stage_db_scale.dart';
import 'package:segno/looper/view/stage_top_bar.dart';
import 'package:segno/looper/view/track_column.dart';
import 'package:segno/looper/view/track_meters.dart';
import 'package:segno/looper/view/tracks_chrome.dart';
import 'package:segno/performance/performance.dart';
import 'package:segno/session/session.dart';
import 'package:segno/settings/settings.dart';
import 'package:segno/theme/theme.dart';
import 'package:segno/visualizer/widgets/waveform_view.dart';
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

class _BrightnessStore extends FakeKeyValueStore {
  bool refuse = true;

  @override
  Future<void> setDouble(String key, double value) async {
    if (key == 'ui.brightness' && refuse) {
      throw StateError('brightness storage unavailable');
    }
    await super.setDouble(key, value);
  }
}

/// The rebuild probe for the `rebuild scope` group: a widget `TracksView.build`
/// creates unconditionally, in console and desktop layouts alike.
final Finder _chromeProbe = find.byKey(
  const Key('tracks_settings_secondaryTap'),
);

/// The rebuild probe for one track column: `_TrackSlot` builds its
/// [TrackColumn] fresh on every run, so the same instance across a pump means
/// that slot did not re-run.
Finder _column(int channel) => find.byWidgetPredicate(
  (widget) => widget is TrackColumn && widget.track.channel == channel,
);

void main() {
  late MixSettingsCoordinator mixSettings;
  late FxChainPersistence fxPersistence;
  setUpAll(() => registerFallbackValue(const LooperRecordPressed(0)));

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
  late PedalRepository pedalRepo;

  setUp(() {
    resetSegnoNavigatorForTest();
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
    when(() => repository.fxReplayConfirmed).thenAnswer(
      (_) => const Stream<({int mixGeneration, int sessionRevision})>.empty(),
    );
    when(() => repository.readTrackWaveform(any())).thenReturn(Float32List(0));
    when(() => repository.clearAll(any())).thenReturn(EngineResult.ok);
    when(() => repository.undoClearAll()).thenReturn(EngineResult.ok);
    when(() => repository.state).thenReturn(const LooperState());
    when(() => repository.mixGeneration).thenReturn(0);
    when(() => repository.sessionRevision).thenReturn(0);
    when(() => repository.inputSetup).thenReturn(const InputSetup.empty());
    when(repository.allMonitors).thenReturn(const {});
    when(() => repository.laneCount(any())).thenReturn(1);
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
    when(
      () => repository.mixSettingsFailures,
    ).thenAnswer((_) => const Stream.empty());
    for (final stub in [
      () => repository.record(channel: any(named: 'channel')),
      () => repository.play(channel: any(named: 'channel')),
      () => repository.stopTrack(channel: any(named: 'channel')),
      () => repository.cancelArm(channel: any(named: 'channel')),
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
    pedalRepo = PedalRepository(NoopPedalLink());
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
    fxPersistence = FxChainPersistence(looper: repository);
    mixSettings = testMixSettings(repository, settings: settings);
    addTearDown(() => unawaited(mixSettings.close()));
    final ownedFade = testFadeSettings();
    control = ControlCubit(
      fxPersistence: fxPersistence,
      looper: repository,
      mixSettings: mixSettings,
      pedal: pedalRepo,
      settings: settings,
      performance: performance,
      fadeSettings: ownedFade,
      ownedValues: OwnedValuePort(
        looper: repository,
        clickVolume: FakeClickVolumeControl(),
        clickMode: FakeClickModeControl(),
        recordStart: FakeRecordStartControl(),
        decay: FakeDecayControl(),
        oneShot: FakeOneShotControl(),
        recordLength: FakeRecordLengthControl(),
        recordTiming: FakeRecordTimingControl(),
        fade: ownedFade,
      ),
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
  Future<void> pump(
    WidgetTester tester, {
    KeyEventResult Function(FocusNode, KeyEvent)? onAncestorKey,
  }) => tester.pumpWidget(
    ToastificationWrapper(
      child: MaterialApp(
        // The root key, so Settings and its destinations push over the stage.
        navigatorKey: segnoNavigatorKey,
        theme: AppTheme.neon,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: MultiRepositoryProvider(
          providers: [
            RepositoryProvider<LooperRepository>.value(value: repository),
            RepositoryProvider<PerformanceRepository>.value(value: performance),
            RepositoryProvider<SettingsRepository>.value(value: settings),
            RepositoryProvider<PedalRepository>.value(value: pedalRepo),
          ],
          child: MultiBlocProvider(
            providers: [
              BlocProvider<DisplayBrightnessCubit>(
                create: (_) => DisplayBrightnessCubit(settings: settings),
              ),
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
                create: (_) => MonitorCubit(
                  fxPersistence: fxPersistence,
                  mixSettings: mixSettings,
                  repository: repository,
                  settings: settings,
                ),
              ),
              // The device-lost banner and the not-running gate read the
              // audio setup cubit (#453).
              BlocProvider<AudioSetupCubit>.value(value: audioSetup),
            ],
            child: onAncestorKey == null
                ? const TracksView()
                : Focus(onKeyEvent: onAncestorKey, child: const TracksView()),
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

  testWidgets(
    'Foot Mixer is distinct from the normal Mixer and pages all inputs',
    (tester) async {
      seed(
        const LooperState(
          status: EngineStatus(inputChannels: 18),
          tracks: [
            Track(state: TrackState.playing, lengthFrames: 48000),
            Track(channel: 1),
          ],
        ),
      );
      tracks.showView(StageView.mixer);
      await pump(tester);
      control.setMode(InteractionMode.mixer);
      await tester.pump();
      expect(find.byType(FootMixerView), findsOneWidget);
      expect(find.byKey(const Key('stage_mixer_run')), findsNothing);
      await tester.tap(find.text('Inputs'));
      await tester.pump();
      for (var page = 0; page < 4; page++) {
        await tester.tap(find.byKey(const Key('foot_mixer_pedal_bank')));
        await tester.pump();
      }
      expect(find.text('Inputs 17–18'), findsOneWidget);
      expect(control.state.activeBank, 0);
      expect(control.state.cursor, 0);
      expect(control.state.footMixer.domain, FootMixerDomain.inputs);
      await tester.tap(find.byKey(const Key('foot_mixer_exit')));
      await tester.pump();
      expect(find.byType(FootMixerView), findsNothing);
      expect(find.byKey(const Key('stage_mixer_run')), findsOneWidget);
    },
  );

  group('Settings opens over the stage, never the tray', () {
    // The stage is under the Settings route, so its tray is offstage.
    double scrim(WidgetTester tester) => tester
        .widget<AnimatedOpacity>(
          find.byKey(const Key('settingsTray_scrim'), skipOffstage: false),
        )
        .opacity;

    testWidgets('from the header icon', (tester) async {
      seed(const LooperState(tracks: [Track()]));
      await pump(tester);
      await tester.tap(find.byKey(const Key('stage_settings')));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsHomePage), findsOneWidget);
      expect(scrim(tester), 0);
    });

    testWidgets('from the foot Mixer', (tester) async {
      seed(const LooperState(tracks: [Track()]));
      await pump(tester);
      control.setMode(InteractionMode.mixer);
      await tester.pump();
      await tester.tap(
        find.descendant(
          of: find.byType(FootMixerView),
          matching: find.text('Settings'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(SettingsHomePage), findsOneWidget);
      expect(scrim(tester), 0);
    });
  });

  for (final activation in [
    LogicalKeyboardKey.enter,
    LogicalKeyboardKey.space,
  ]) {
    testWidgets(
      'Foot Mixer focused buttons activate with ${activation.debugName}',
      (tester) async {
        seed(const LooperState(tracks: [Track()]));
        await pump(tester);
        control.setMode(InteractionMode.mixer);
        await tester.pump();
        final exit = find.descendant(
          of: find.byKey(const Key('foot_mixer_exit')),
          matching: find.byIcon(Icons.chevron_left),
        );
        Focus.of(tester.element(exit)).requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(activation);
        await tester.pump();
        expect(control.state.mode, InteractionMode.record);
        control.setMode(InteractionMode.mixer);
        await tester.pump();
        final settingsButton = find.descendant(
          of: find.byType(FootMixerView),
          matching: find.text('Settings'),
        );
        Focus.of(tester.element(settingsButton)).requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(activation);
        await tester.pumpAndSettle();
        expect(find.byType(SettingsHomePage), findsOneWidget);
        // Settings opens over the stage; the tray stays shut.
        expect(
          tester
              .widget<AnimatedOpacity>(
                find.byKey(
                  const Key('settingsTray_scrim'),
                  skipOffstage: false,
                ),
              )
              .opacity,
          0,
        );
        verifyNever(() => bloc.add(const LooperPlayAllPressed()));
      },
    );
  }

  testWidgets(
    'Foot Mixer preserves modifier shortcuts and blocks plain transport',
    (tester) async {
      seed(const LooperState(tracks: [Track()]));
      final passedKeys = <LogicalKeyboardKey>[];
      await pump(
        tester,
        onAncestorKey: (_, event) {
          if (event is KeyDownEvent) passedKeys.add(event.logicalKey);
          return KeyEventResult.ignored;
        },
      );
      control.setMode(InteractionMode.mixer);
      await tester.pump();
      for (final modifier in [
        LogicalKeyboardKey.controlLeft,
        LogicalKeyboardKey.metaLeft,
      ]) {
        passedKeys.clear();
        await tester.sendKeyDownEvent(modifier);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
        verify(() => bloc.add(const LooperUndoPressed(0))).called(1);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
        verify(session.save).called(1);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyQ);
        expect(passedKeys, contains(LogicalKeyboardKey.keyQ));
        await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
        expect(control.state.mode, InteractionMode.mixer);
        await tester.sendKeyUpEvent(modifier);
      }
      passedKeys.clear();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
      expect(passedKeys, isEmpty);
      expect(control.state.cursor, 0);
      verifyNever(() => bloc.add(const LooperPlayAllPressed()));
      verifyNever(() => bloc.add(const LooperPlayPressed(0)));
    },
  );

  testWidgets('Foot Mixer refusal is visible above the real Settings tray', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(1920, 1080)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    seed(
      const LooperState(
        tracks: [Track(state: TrackState.playing, lengthFrames: 48000)],
      ),
    );
    when(() => repository.trackMuted(0)).thenReturn(false);
    when(
      () => repository.setMute(muted: true),
    ).thenReturn(EngineResult.invalid);
    when(() => repository.laneMuted(any(), any())).thenReturn(false);
    when(() => repository.fxRecipesSettled).thenReturn(true);
    when(() => repository.laneEffects(any(), any())).thenReturn(const []);
    when(() => repository.laneChainEnabled(any(), any())).thenReturn(true);
    when(
      () => repository.laneChainInheritedFrom(any(), any()),
    ).thenReturn(const []);
    await pump(tester);
    control.setMode(InteractionMode.mixer);
    await tester.pump();
    tester.element(find.byType(SettingsTray)).read<SettingsTrayCubit>().open();
    await tester.pumpAndSettle();
    await control.toggleFootMixerMute();
    await tester.pumpAndSettle();
    expect(
      find
          .text('The Mixer change could not be completed. Try again.')
          .hitTestable(),
      findsOneWidget,
    );
    expect(control.state.footMixerFailure, 1);
    expect(tester.takeException(), isNull);
    dismissAppToast(AppToastId.footMixerFailure);
    await tester.pump(const Duration(seconds: 10));
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

  testWidgets('brightness failure stays visible above the real tray and '
      'another adjustment saves', (tester) async {
    tester.view
      ..physicalSize = const Size(1920, 1080)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = _BrightnessStore();
    settings = SettingsRepository(store: store);
    seed(const LooperState(tracks: [Track()]));
    await pump(tester);
    tester.element(find.byType(SettingsTray)).read<SettingsTrayCubit>().open();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settingsTrayRail_brightness')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settingsTray_brightness')));
    await tester.pumpAndSettle();
    final context = tester.element(find.byType(SettingsTray));
    final title = context.l10n.powerOffSaveFailedTitle;
    // A SnackBar can exist but be painted and hit-tested behind the opaque
    // SettingsTray sibling. The failure must be reachable above that sibling.
    expect(find.text(title).hitTestable(), findsOneWidget);
    expect(store.values['ui.brightness'], isNull);
    expect(tester.takeException(), isNull);
    store.refuse = false;
    await tester.drag(
      find.byKey(const Key('settingsTray_brightness')),
      const Offset(0, -80),
    );
    await tester.pumpAndSettle();
    expect(
      await settings.loadBrightness(),
      context.read<DisplayBrightnessCubit>().state,
    );
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('G reaches the Effects route, and no longer opens the tray', (
    tester,
  ) async {
    seed(const LooperState(tracks: [Track()]));
    await pump(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyG);
    await tester.pumpAndSettle();

    // Effects is a full-screen route now, not a tray domain. The route itself
    // needs the app's root navigator, which this harness does not install, so
    // what this pins is that the handler runs cleanly and leaves the tray
    // alone — the shortcut used to open it.
    expect(tester.takeException(), isNull);
    expect(trayState(tester).dragProgress, 0);
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

  testWidgets('M cycles the mode chip through every mode, announcing each '
      'landed one', (tester) async {
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
    expect(announcements, contains(l10n.a11yModeFx));
    expect(l10n.a11yModeFx, 'FX mode');
    await cycle();
    expect(control.state.mode, InteractionMode.custom);
    expect(announcements, contains(l10n.a11yModeCustom));
    expect(l10n.a11yModeCustom, 'Custom controls');
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
    /// The cell's identity line — the FX-mode dressing's own text, which the
    /// always-visible track name above the meter is not part of.
    String fxIdentity(WidgetTester tester) => tester
        .widget<AppText>(find.byKey(const Key('tracks_tileFxTarget')))
        .data!;

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
      Track? liveTrack,
    }) {
      // [track] is seeded as the bloc's OWN track for its channel, not just
      // handed to the widget. A column is a live view: its meter reads the
      // level for `track.channel` out of the ambient bloc (see
      // `TrackColumn.track`), so a harness that let the two disagree would
      // make every meter assertion here true for the wrong reason.
      // [liveTrack] exists only to break that on purpose.
      seed(LooperState(tracks: [liveTrack ?? track]));
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
      expect(fxIdentity(tester), isNot(contains('GUITAR')));
    });

    testWidgets('a value-equal Track from an EARLIER poll is accepted', (
      tester,
    ) async {
      // The instance a column is handed is a tick old by design: the slot
      // above it only rebuilds when the STEADY facts change, so it keeps
      // passing the projection from whichever poll last changed them, while
      // `_project` builds a fresh `lanes` list literal every tick. The guard
      // therefore has to be Equatable-deep — a shallow compare of the prop
      // lists calls two value-equal projections different and red-screens the
      // stage on the next theme rebuild.
      // `List.of`, not a literal: a const literal would be canonicalised into
      // the same instance both times and make this test vacuous, which is
      // exactly what the analyzer would rather have here.
      Track projected({required double peak}) => Track(
        peak: peak,
        lanes: List.of(const [Lane(inputChannel: 0)]),
        effects: List.of([BuiltInEffect(type: TrackEffectType.drive)]),
      );

      await pumpColumn(
        tester,
        name: 'DRUMS',
        mode: InteractionMode.record,
        track: projected(peak: 0),
        // Same facts, new lists, and a level that has moved since — exactly
        // what the rig looks like one poll later.
        liveTrack: projected(peak: 0.9),
      );

      expect(tester.takeException(), isNull);
    });

    testWidgets('a channel the bloc does not hold trips the live-view assert', (
      tester,
    ) async {
      // A snapshot surface — a saved 8-channel session on a 2-channel rig —
      // would otherwise draw a permanently flat meter per missing channel,
      // silently, in debug and release alike.
      await pumpColumn(
        tester,
        name: 'GUITAR',
        mode: InteractionMode.record,
        track: const Track(channel: 5),
        liveTrack: const Track(),
      );

      expect(tester.takeException(), isA<AssertionError>());
    });

    testWidgets('a Track the bloc does not hold trips the live-view assert', (
      tester,
    ) async {
      // The rule the doc on `TrackColumn.track` states, enforced instead of
      // asked for: the meter reads its level out of the ambient bloc by
      // channel, so a column handed a track that bloc does not hold draws one
      // track's facts under another's level — and renders perfectly while
      // doing it. Nothing on screen, and no screenshot, would show it.
      await pumpColumn(
        tester,
        name: 'GUITAR',
        mode: InteractionMode.record,
        track: const Track(muted: true),
        liveTrack: const Track(),
      );

      expect(tester.takeException(), isA<AssertionError>());
    });

    testWidgets('a bound chain targeting a NON-track stage reads that stage, '
        'not the column track', (tester) async {
      await pumpColumn(
        tester,
        name: 'GUITAR',
        mode: InteractionMode.fx,
        // The footswitch over the GUITAR column is bound to the FIRST OUTPUT
        // destination's chain: the cell must say OUT 1, never TRACK 1 /
        // GUITAR.
        fxTarget: const FxAddress(stage: FxStage.output),
        track: Track(effects: [BuiltInEffect(type: TrackEffectType.reverb)]),
      );

      expect(find.text('OUT 1 · REVERB'), findsOneWidget);
      expect(fxIdentity(tester), isNot(contains('GUITAR')));
      expect(fxIdentity(tester), isNot(contains('TRACK')));
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

  group('queued cue', () {
    testWidgets('a pending arm on an empty track reads Record · Loop start', (
      tester,
    ) async {
      seed(const LooperState(tracks: [Track(pending: true)]));
      await pump(tester);

      expect(find.byKey(const Key('tracks_queued_0')), findsOneWidget);
      expect(find.text('Record'), findsOneWidget);
      expect(find.text('Loop start'), findsOneWidget);
    });

    testWidgets('a pending arm on a recorded track reads Overdub, and names '
        'the quantize grid', (tester) async {
      seed(
        const LooperState(
          transport: TransportState(quantizeDiv: GridDivision.bar),
          tracks: [
            Track(
              state: TrackState.playing,
              lengthFrames: 1000,
              pending: true,
              pendingTrigger: ArmTrigger.grid,
            ),
          ],
        ),
      );
      await pump(tester);

      expect(find.text('Overdub'), findsOneWidget);
      expect(find.text('Next bar'), findsOneWidget);
    });

    testWidgets("a Sound start arm names the signal, from the engine's own "
        'trigger — not the settings', (tester) async {
      // No RecordOptionsCubit is provided here at all: the boundary is a
      // fact the engine publishes with the arm.
      seed(
        const LooperState(
          transport: TransportState(quantizeDiv: GridDivision.bar),
          tracks: [Track(pending: true, pendingTrigger: ArmTrigger.sound)],
        ),
      );
      await pump(tester);

      expect(find.text('Record'), findsOneWidget);
      expect(find.text('Sound'), findsOneWidget);
      expect(find.text('Next bar'), findsNothing);
    });

    testWidgets("an overdub's punch-out reads Play at the loop start, whatever "
        'the grid', (tester) async {
      seed(
        const LooperState(
          transport: TransportState(quantizeDiv: GridDivision.eighth),
          tracks: [
            Track(
              state: TrackState.overdubbing,
              lengthFrames: 1000,
              pending: true,
              pendingTrigger: ArmTrigger.grid,
            ),
          ],
        ),
      );
      await pump(tester);

      expect(find.text('Play'), findsOneWidget);
      expect(find.text('Loop start'), findsOneWidget);
    });

    const takeEnding = Track(
      state: TrackState.recording,
      lengthFrames: 500,
      pending: true,
      pendingTrigger: ArmTrigger.grid,
    );

    testWidgets('a queued take-end reads Play on the grid', (tester) async {
      seed(
        const LooperState(
          transport: TransportState(quantizeDiv: GridDivision.bar),
          tracks: [takeEnding],
        ),
      );
      await pump(tester);
      expect(find.text('Play'), findsOneWidget);
      expect(find.text('Next bar'), findsOneWidget);
    });

    testWidgets('a queued take-end reads Overdub under rec/dub', (
      tester,
    ) async {
      seed(
        const LooperState(
          transport: TransportState(
            quantizeDiv: GridDivision.bar,
            recDub: true,
          ),
          tracks: [takeEnding],
        ),
      );
      await pump(tester);
      expect(find.text('Overdub'), findsOneWidget);
    });

    testWidgets('a section arm plays a stopped track and stops a sounding '
        'one, at the loop start', (tester) async {
      seed(
        const LooperState(
          transport: TransportState(quantizeDiv: GridDivision.bar),
          tracks: [
            Track(
              state: TrackState.stopped,
              lengthFrames: 1000,
              pending: true,
              pendingTrigger: ArmTrigger.section,
            ),
            Track(
              channel: 1,
              state: TrackState.playing,
              lengthFrames: 1000,
              pending: true,
              pendingTrigger: ArmTrigger.section,
            ),
          ],
        ),
      );
      await pump(tester);

      expect(find.text('Play'), findsOneWidget);
      expect(find.text('Stop'), findsOneWidget);
      expect(find.text('Loop start'), findsNWidgets(2));
    });

    testWidgets('absent on a track with no pending arm', (tester) async {
      seed(const LooperState(tracks: [Track()]));
      await pump(tester);

      expect(find.byKey(const Key('tracks_queued_0')), findsNothing);
    });

    testWidgets('the cue is a readout: the tap still reaches the tile', (
      tester,
    ) async {
      seed(const LooperState(tracks: [Track(pending: true)]));
      await pump(tester);

      await tester.tap(find.byKey(const Key('tracks_queued_0')));
      // A second press cancels the arm — the tile's record path, not a cue.
      verify(() => bloc.add(const LooperRecordPressed(0))).called(1);
    });
  });

  group('primary crown', () {
    testWidgets('marks the primary track in every mode, Multi included', (
      tester,
    ) async {
      for (final mode in LooperMode.values) {
        seed(
          LooperState(
            transport: TransportState(looperMode: mode, primaryTrack: 1),
            tracks: const [
              Track(state: TrackState.playing, lengthFrames: 1000),
              Track(
                channel: 1,
                state: TrackState.playing,
                lengthFrames: 1000,
              ),
            ],
          ),
        );
        await pump(tester);
        expect(
          find.byKey(const Key('tracks_crown_1')),
          findsOneWidget,
          reason: mode.name,
        );
        expect(
          find.byKey(const Key('tracks_crown_0')),
          findsNothing,
          reason: mode.name,
        );
      }
    });

    testWidgets('an empty session has none', (tester) async {
      seed(const LooperState(tracks: [Track(), Track(channel: 1)]));
      await pump(tester);

      expect(find.byKey(const Key('tracks_crown_0')), findsNothing);
      expect(find.byKey(const Key('tracks_crown_1')), findsNothing);
    });

    testWidgets('selection and bank do not move it', (tester) async {
      seed(
        LooperState(
          transport: const TransportState(primaryTrack: 2),
          tracks: [
            for (var i = 0; i < 8; i++)
              Track(channel: i, state: TrackState.playing, lengthFrames: 1000),
          ],
        ),
      );
      await pump(tester);
      expect(find.byKey(const Key('tracks_crown_2')), findsOneWidget);

      control.selectTrack(0);
      await tester.pump();
      expect(find.byKey(const Key('tracks_crown_2')), findsOneWidget);
      expect(find.byKey(const Key('tracks_crown_0')), findsNothing);

      // Bank B reveals the other four tracks and no second crown.
      control.browseBank(1);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('tracks_crown_2')), findsNothing);
      for (var i = 4; i < 8; i++) {
        expect(find.byKey(Key('tracks_crown_$i')), findsNothing);
      }
    });

    testWidgets('is a readout, not a control — tapping it crowns nothing', (
      tester,
    ) async {
      seed(
        const LooperState(
          transport: TransportState(primaryTrack: 0),
          tracks: [
            Track(state: TrackState.playing, lengthFrames: 1000),
            Track(channel: 1, state: TrackState.playing, lengthFrames: 1000),
          ],
        ),
      );
      await pump(tester);

      await tester.tap(find.byKey(const Key('tracks_crown_0')));
      await tester.pumpAndSettle();
      verifyNever(() => bloc.add(any(that: isA<LooperCrownPrimaryPressed>())));
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
      // as one grouped edit and re-armed on the engine directly.
      verify(() => repository.clearAll([0])).called(1);
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

    testWidgets('the tile uses a 2px ring with selection color', (
      tester,
    ) async {
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

      BorderSide borderSide(int channel) {
        final tile = tester.widget<Container>(
          find
              .ancestor(
                of: find.byKey(Key('tracks_tile_$channel')),
                matching: find.byType(Container),
              )
              .first,
        );
        return ((tile.decoration! as BoxDecoration).border! as Border).top;
      }

      final selectedSide = borderSide(0);
      expect(selectedSide.color, Colors.white);
      expect(selectedSide.width, 2);

      // Unselected: the pen's 2px near-black card stroke (the `card` token),
      // not borderless.
      final unselectedSide = borderSide(1);
      expect(
        unselectedSide.color,
        AppTheme.neon.extension<SurfaceTheme>()!.card,
      );
      expect(unselectedSide.width, 2);
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

  group('layout', () {
    testWidgets('the top bar leads, the footer trails the track run', (
      tester,
    ) async {
      seed(const LooperState(tracks: [Track()]));
      await pump(tester);

      final stageTop = tester.getTopLeft(find.byType(TracksView)).dy;
      final bar = tester.getRect(find.byKey(const Key('stage_top_bar')));
      final run = tester.getRect(find.byKey(const Key('stage_track_run')));
      final footer = tester.getRect(find.byKey(const Key('stage_footer')));

      expect(bar.top, stageTop);
      expect(bar.height, StageTopBar.height);
      expect(run.top, greaterThan(bar.bottom));
      expect(footer.top, greaterThanOrEqualTo(run.bottom));
    });

    testWidgets('the shared dBFS scales flank the run and line up with the '
        'meters', (tester) async {
      seed(const LooperState(tracks: [Track()]));
      await pump(tester);

      final scales = find.byType(StageDbScale);
      expect(scales, findsNWidgets(2));
      final run = tester.getRect(find.byKey(const Key('stage_track_run')));
      final left = tester.getRect(scales.first);
      final right = tester.getRect(scales.last);
      expect(left.right, lessThanOrEqualTo(run.left));
      expect(right.left, greaterThanOrEqualTo(run.right));
      expect(left.top, run.top);
      expect(left.bottom, run.bottom);
    });

    testWidgets('the view menu switches to Wave and back', (tester) async {
      seed(
        const LooperState(
          tracks: [Track(state: TrackState.playing, lengthFrames: 1000)],
        ),
      );
      await pump(tester);
      expect(find.byKey(const Key('stage_track_run')), findsOneWidget);

      await tester.tap(find.byKey(const Key('stage_view_menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('stage_view_wave')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('stage_wave_run')), findsOneWidget);
      expect(find.byKey(const Key('wave_row_0')), findsOneWidget);
      expect(find.byKey(const Key('stage_track_run')), findsNothing);
      // Browsing views never touches playback or the selection.
      verifyNever(() => bloc.add(any()));
      expect(control.state.cursor, 0);

      await tester.tap(find.byKey(const Key('stage_view_menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('stage_view_track')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('stage_track_run')), findsOneWidget);
    });

    /// Opens the Mixer through the same menu a player uses.
    Future<void> showMixer(WidgetTester tester) async {
      await tester.tap(find.byKey(const Key('stage_view_menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('stage_view_mixer')));
      await tester.pumpAndSettle();
    }

    testWidgets('the view menu switches to the Mixer and back', (tester) async {
      seed(
        const LooperState(
          tracks: [
            Track(state: TrackState.playing, lengthFrames: 1000),
            Track(channel: 1, state: TrackState.playing, lengthFrames: 1000),
          ],
        ),
      );
      await pump(tester);
      await showMixer(tester);

      expect(find.byKey(const Key('stage_mixer_run')), findsOneWidget);
      expect(find.byKey(const Key('mixer_mute_0')), findsOneWidget);
      expect(find.byKey(const Key('mixer_mute_1')), findsOneWidget);
      expect(find.byKey(const Key('stage_track_run')), findsNothing);
      // Browsing views never touches playback or the selection.
      verifyNever(() => bloc.add(any()));
      expect(control.state.cursor, 0);

      await tester.tap(find.byKey(const Key('stage_view_menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('stage_view_track')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('stage_track_run')), findsOneWidget);
      expect(find.byKey(const Key('stage_mixer_run')), findsNothing);
    });

    testWidgets('Mute and Solo write the track they are on, and a long press '
        'on Solo clears every one', (tester) async {
      seed(
        const LooperState(
          tracks: [
            Track(state: TrackState.playing, lengthFrames: 1000),
            Track(channel: 1, state: TrackState.playing, lengthFrames: 1000),
          ],
        ),
      );
      await pump(tester);
      await showMixer(tester);

      await tester.tap(find.byKey(const Key('mixer_mute_1')));
      await tester.pump();
      verify(() => bloc.add(const LooperMuteToggled(1))).called(1);

      await tester.tap(find.byKey(const Key('mixer_solo_1')));
      await tester.pump();
      verify(() => bloc.add(const LooperTrackSoloToggled(1))).called(1);

      await tester.longPress(find.byKey(const Key('mixer_solo_0')));
      await tester.pump();
      verify(() => bloc.add(const LooperSoloCleared())).called(1);
    });

    testWidgets('the pan bar previews under the finger and commits once, and '
        'a double tap returns the track to the centre', (tester) async {
      seed(
        const LooperState(
          tracks: [Track(state: TrackState.playing, lengthFrames: 1000)],
        ),
      );
      await pump(tester);
      await showMixer(tester);
      final l10n = AppLocalizations.of(
        tester.element(find.byType(TracksView)),
      );
      String readout() => tester
          .widget<Text>(
            find.descendant(
              of: find.byKey(const Key('mixer_pan_readout_0')),
              matching: find.byType(Text),
            ),
          )
          .data!;
      expect(readout(), l10n.routingPanCenter);

      final bar = find.byKey(const Key('mixer_pan_0'));
      final box = tester.getRect(bar);
      final gesture = await tester.startGesture(
        Offset(box.left + 4, box.center.dy),
      );
      await tester.pump();
      await gesture.moveBy(const Offset(40, 0));
      await tester.pump();
      await gesture.moveTo(Offset(box.left + box.width * 0.9, box.center.dy));
      await tester.pump();
      // The readout follows the finger; nothing is written yet.
      expect(readout(), isNot(l10n.routingPanCenter));
      verifyNever(() => bloc.add(any(that: isA<LooperTrackPanChanged>())));

      await gesture.up();
      await tester.pump();
      final panned = verify(
        () => bloc.add(captureAny(that: isA<LooperTrackPanChanged>())),
      ).captured.cast<LooperTrackPanChanged>();
      expect(panned, hasLength(1));
      expect(panned.single.pan, greaterThan(0));

      await tester.tap(bar);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(bar);
      // Settles the double-tap recogniser's own countdown.
      await tester.pumpAndSettle();
      final centred = verify(
        () => bloc.add(captureAny(that: isA<LooperTrackPanChanged>())),
      ).captured.cast<LooperTrackPanChanged>();
      expect(centred.last.pan, 0);
    });

    testWidgets('a Fade replaces only the caption, never the saved level', (
      tester,
    ) async {
      seed(
        const LooperState(
          tracks: [
            Track(
              state: TrackState.playing,
              lengthFrames: 1000,
              fade: FadeImage(amount: .5, target: 0, fullTravelSeconds: 4),
            ),
            Track(
              channel: 1,
              state: TrackState.playing,
              lengthFrames: 1000,
              fade: FadeImage(amount: 0, target: 0),
            ),
            Track(
              channel: 2,
              state: TrackState.playing,
              lengthFrames: 1000,
              fade: FadeImage(amount: .25, target: .25),
            ),
            Track(channel: 3, state: TrackState.playing, lengthFrames: 1000),
          ],
        ),
      );
      await pump(tester);
      await showMixer(tester);
      String caption(int channel) => tester
          .widget<AppText>(find.byKey(Key('mixer_gain_caption_$channel')))
          .data!;
      expect(caption(0), 'Fading');
      expect(caption(1), 'Faded out');
      expect(caption(2), 'Fade 25%');
      expect(caption(3), isNot(anyOf('Fading', 'Faded out')));
      for (var channel = 0; channel < 4; channel++) {
        expect(
          tester
              .widget<AppText>(find.byKey(Key('mixer_gain_readout_$channel')))
              .data,
          tester
              .widget<AppText>(find.byKey(const Key('mixer_gain_readout_3')))
              .data,
          reason: 'every track keeps its saved unity level',
        );
      }
    });

    testWidgets('the level marker rides the meter, commits once, and a double '
        'tap returns the track to unity', (tester) async {
      seed(
        const LooperState(
          tracks: [
            Track(state: TrackState.playing, lengthFrames: 1000, volume: 0.5),
          ],
        ),
      );
      await pump(tester);
      await showMixer(tester);
      expect(find.byKey(const Key('mixer_level_marker_0')), findsOneWidget);

      final meter = find.byKey(const Key('mixer_level_0'));
      final box = tester.getRect(meter);
      final gesture = await tester.startGesture(box.center);
      await tester.pump();
      await gesture.moveBy(const Offset(0, -20));
      await tester.pump();
      await gesture.moveTo(Offset(box.center.dx, box.top + box.height * 0.1));
      await tester.pump();
      verifyNever(() => bloc.add(any(that: isA<LooperVolumeChanged>())));
      expect(
        tester
            .widget<AppText>(find.byKey(const Key('mixer_gain_readout_0')))
            .data,
        '−0.6 dB',
      );

      await gesture.up();
      await tester.pump();
      final levels = verify(
        () => bloc.add(captureAny(that: isA<LooperVolumeChanged>())),
      ).captured.cast<LooperVolumeChanged>();
      expect(levels, hasLength(1));
      // The marker travels in decibels; 10% from the top is near unity.
      expect(levels.single.volume, closeTo(0.94, 0.05));

      await tester.tap(meter);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(meter);
      await tester.pumpAndSettle();
      final unity = verify(
        () => bloc.add(captureAny(that: isA<LooperVolumeChanged>())),
      ).captured.cast<LooperVolumeChanged>();
      expect(unity.last.volume, 1);
    });

    for (final gain in [0.0, 1.0, 2.0]) {
      testWidgets('gain $gain keeps its logarithmic marker body inside the '
          'meter', (tester) async {
        seed(LooperState(tracks: [Track(volume: gain)]));
        await pump(tester);
        await showMixer(tester);

        final meter = tester.getRect(find.byKey(const Key('mixer_level_0')));
        final marker = tester.getRect(
          find.byKey(const Key('mixer_level_marker_0')),
        );
        final unity = tester.getRect(find.byKey(const Key('mixer_unity_0')));
        expect(marker.top, greaterThanOrEqualTo(meter.top));
        expect(marker.bottom, lessThanOrEqualTo(meter.bottom));
        final expected = gain == 0
            ? meter.bottom - marker.height
            : gain == 2
            ? meter.top
            : unity.top;
        expect(marker.top, closeTo(expected, 0.02));
        expect(
          tester
              .widget<AppText>(
                find.byKey(const Key('mixer_gain_readout_0')),
              )
              .data,
          switch (gain) {
            0 => '−∞',
            1 => '0.0 dB',
            _ => '+6.0 dB',
          },
        );
      });
    }

    testWidgets('a foreign gain write cancels a live touch draft before lift', (
      tester,
    ) async {
      const original = LooperState(tracks: [Track(volume: 0.5)]);
      final changes = StreamController<LooperState>.broadcast();
      addTearDown(changes.close);
      seed(original);
      whenListen(bloc, changes.stream, initialState: original);
      await pump(tester);
      await showMixer(tester);

      final meter = tester.getRect(find.byKey(const Key('mixer_level_0')));
      final gesture = await tester.startGesture(meter.center);
      await gesture.moveBy(const Offset(0, -40));
      await tester.pump();
      changes.add(const LooperState(tracks: [Track(volume: 0.8)]));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<AppText>(find.byKey(const Key('mixer_gain_readout_0')))
            .data,
        '−1.9 dB',
      );
      await gesture.up();
      await tester.pump();
      verifyNever(() => bloc.add(any(that: isA<LooperVolumeChanged>())));
      expect(
        tester
            .widget<AppText>(find.byKey(const Key('mixer_gain_readout_0')))
            .data,
        '−1.9 dB',
      );
    });

    testWidgets('bank changes discard an equal-valued pan draft and metadata '
        'selects through the shared cursor', (tester) async {
      seed(
        LooperState(
          tracks: [
            for (var channel = 0; channel < 8; channel++)
              Track(channel: channel),
          ],
        ),
      );
      await pump(tester);
      await showMixer(tester);

      final pan = tester.getRect(find.byKey(const Key('mixer_pan_0')));
      final gesture = await tester.startGesture(pan.center);
      await gesture.moveBy(const Offset(40, 0));
      await tester.pump();
      control.browseBank(1);
      await tester.pumpAndSettle();
      expect(control.state.activeBank, 1);
      expect(find.byKey(const Key('mixer_pan_0')), findsNothing);
      expect(find.byKey(const Key('mixer_pan_4')), findsOneWidget);
      await gesture.up();
      await tester.pump();
      verifyNever(() => bloc.add(any(that: isA<LooperTrackPanChanged>())));
      await tester.tap(find.byKey(const Key('mixer_select_4')));
      await tester.pump();
      expect(control.state.cursor, 4);
    });

    testWidgets('a held gain tap cannot commit after selecting another track', (
      tester,
    ) async {
      seed(const LooperState(tracks: [Track(), Track(channel: 1)]));
      await pump(tester);
      await showMixer(tester);
      final meter = tester.getRect(find.byKey(const Key('mixer_level_0')));
      final oldTouch = await tester.startGesture(meter.center);
      await tester.pump();
      await tester.tap(find.byKey(const Key('mixer_select_1')));
      await tester.pumpAndSettle();
      expect(control.state.cursor, 1);
      await oldTouch.up();
      await tester.pumpAndSettle();
      verifyNever(() => bloc.add(any(that: isA<LooperVolumeChanged>())));
    });

    testWidgets('opening Reset discards a held pan drag before release', (
      tester,
    ) async {
      seed(const LooperState(tracks: [Track()]));
      await pump(tester);
      await showMixer(tester);
      final pan = tester.getRect(find.byKey(const Key('mixer_pan_0')));
      final oldTouch = await tester.startGesture(pan.center);
      await oldTouch.moveBy(const Offset(40, 0));
      await tester.pump();
      await tester.tap(find.byKey(const Key('stage_reset_mixer')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('mixer_reset_confirm')), findsOneWidget);
      await oldTouch.up();
      await tester.pump();
      verifyNever(() => bloc.add(any(that: isA<LooperTrackPanChanged>())));
    });

    testWidgets('encoder pan draft cancels on Escape and commits on press', (
      tester,
    ) async {
      seed(const LooperState(tracks: [Track()]));
      await pump(tester);
      await showMixer(tester);
      final bar = find.byKey(const Key('mixer_pan_0'));
      final centre = AppLocalizations.of(tester.element(bar)).routingPanCenter;
      Focus.of(tester.element(bar)).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(
        tester
            .widget<AppText>(find.byKey(const Key('mixer_pan_readout_0')))
            .data,
        isNot(centre),
      );
      verifyNever(() => bloc.add(any(that: isA<LooperTrackPanChanged>())));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(
        tester
            .widget<AppText>(find.byKey(const Key('mixer_pan_readout_0')))
            .data,
        centre,
      );
      verifyNever(() => bloc.add(any(that: isA<LooperTrackPanChanged>())));
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      final edits = verify(
        () => bloc.add(captureAny(that: isA<LooperTrackPanChanged>())),
      ).captured.cast<LooperTrackPanChanged>();
      expect(edits, hasLength(1));
      expect(edits.single.pan, closeTo(0.05, 0.001));
    });

    testWidgets('the strip meters the two sides separately', (tester) async {
      seed(
        const LooperState(
          tracks: [
            Track(
              state: TrackState.playing,
              lengthFrames: 1000,
              peakL: 1,
              peakR: 0.001,
            ),
          ],
        ),
      );
      await pump(tester);
      await showMixer(tester);

      double fill(String key) => tester
          .widget<FractionallySizedBox>(
            find.descendant(
              of: find.byKey(Key(key)),
              matching: find.byType(FractionallySizedBox),
            ),
          )
          .heightFactor!;
      // Left is at full scale, right is all but silent: one lane each, not a
      // single bar of their sum.
      expect(fill('mixer_meter_l_0'), 1);
      expect(fill('mixer_meter_r_0'), lessThan(0.2));
    });

    testWidgets('the reduced-height Mixer keeps its side scale at the meter', (
      tester,
    ) async {
      seed(
        const LooperState(
          tracks: [
            Track(),
            Track(channel: 1),
            Track(channel: 2),
            Track(channel: 3),
          ],
        ),
      );
      await tracks.rename(0, 'GUITAR');
      await pump(tester);
      await showMixer(tester);
      final scale = tester.getRect(find.byType(StageDbScale).first);
      final meter = tester.getRect(find.byKey(const Key('mixer_level_0')));
      final run = tester.getRect(find.byKey(const Key('stage_mixer_run')));
      final factor = scale.height / MixerColumn.minimumHeight;
      expect(factor, lessThan(1));
      expect(
        run.width,
        closeTo(
          tester.getSize(find.byType(TracksView)).width -
              2 * StageTopBar.sideInset -
              2 * StageDbScale.width * factor -
              32 * factor,
          0.05,
        ),
      );
      final title = tester.renderObject<RenderParagraph>(
        find.text('GUITAR'),
      );
      expect(title.size.height, lessThan(50));
      expect(
        tester.getSize(find.byKey(const Key('mixer_mute_0'))).width,
        greaterThan(35),
      );
      for (final key in ['mixer_mute_0', 'mixer_solo_0']) {
        final label = tester.renderObject<RenderParagraph>(
          find.descendant(
            of: find.byKey(Key(key)),
            matching: find.byType(Text),
          ),
        );
        expect(label.size.height, lessThan(35));
      }
      expect(
        meter.top,
        closeTo(scale.top + MixerColumn.meterTopInset * factor, 0.05),
      );
      expect(
        meter.bottom,
        closeTo(scale.bottom - MixerColumn.meterBottomInset * factor, 0.05),
      );
      final marks = [0, -6, -12, -18, -24, -36, -48, -60];
      for (var index = 0; index < marks.length - 1; index++) {
        final upper = tester.getRect(
          find.descendant(
            of: find.byType(StageDbScale).first,
            matching: find.text('${marks[index]}'),
          ),
        );
        final lower = tester.getRect(
          find.descendant(
            of: find.byType(StageDbScale).first,
            matching: find.text('${marks[index + 1]}'),
          ),
        );
        expect(upper.bottom, lessThanOrEqualTo(lower.top));
      }
    });

    testWidgets('Reset mixer belongs to the Mixer, and resets the mix', (
      tester,
    ) async {
      seed(
        const LooperState(
          tracks: [Track(state: TrackState.playing, lengthFrames: 1000)],
        ),
      );
      await pump(tester);
      // Not on the Track view: an action that changes eight values at once
      // sits beside the values it changes.
      expect(find.byKey(const Key('stage_reset_mixer')), findsNothing);

      await showMixer(tester);
      expect(find.byKey(const Key('stage_reset_mixer')), findsOneWidget);
      await tester.tap(find.byKey(const Key('stage_reset_mixer')));
      await tester.pump();
      expect(find.byKey(const Key('mixer_reset_confirm')), findsOneWidget);
      await tester.tap(find.byKey(const Key('mixer_reset_cancel')));
      await tester.pumpAndSettle();
      verifyNever(() => bloc.add(const LooperMixerReset()));
      await tester.tap(find.byKey(const Key('stage_reset_mixer')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('mixer_reset_apply')));
      await tester.pumpAndSettle();
      verify(() => bloc.add(const LooperMixerReset())).called(1);
    });

    testWidgets('Reset confirmation cannot apply to a replaced session', (
      tester,
    ) async {
      seed(const LooperState(tracks: [Track()]));
      await pump(tester);
      await showMixer(tester);
      await tester.tap(find.byKey(const Key('stage_reset_mixer')));
      await tester.pump();
      when(() => repository.mixGeneration).thenReturn(1);
      await tester.tap(find.byKey(const Key('mixer_reset_apply')));
      await tester.pumpAndSettle();
      verifyNever(() => bloc.add(const LooperMixerReset()));
    });

    testWidgets('the footer reads tempo, elapsed time, output and mode', (
      tester,
    ) async {
      seed(
        const LooperState(
          transport: TransportState(
            tempoBpm: 84,
            tempoSource: TempoSource.manual,
            looperMode: LooperMode.sync,
            outputPeak: 0.5,
          ),
          tracks: [Track()],
        ),
      );
      await pump(tester);

      expect(find.text('84.0'), findsOneWidget);
      expect(find.text('4/4'), findsOneWidget);
      expect(find.text('00:00:00'), findsOneWidget);
      expect(find.text('OUT -6.0 dBFS'), findsOneWidget);
      expect(find.text('SYNC'), findsOneWidget);
    });

    testWidgets('the footer counts a count-in down in place of the '
        'signature', (tester) async {
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
      expect(find.text('4/4'), findsNothing);
    });

    testWidgets('the footer flags output clipping in red', (tester) async {
      seed(
        const LooperState(
          transport: TransportState(outputPeak: 1),
          tracks: [Track()],
        ),
      );
      await pump(tester);

      final output = tester.widget<AppText>(
        find.byKey(const Key('stage_footer_output')),
      );
      expect(output.data, 'OUT CLIP');
      expect(
        output.style!.color,
        AppTheme.neon.extension<SurfaceTheme>()!.rec,
      );
    });

    testWidgets('Wave fits the desktop launch size with four tracks', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(800, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      seed(
        LooperState(
          tracks: [
            for (var i = 0; i < 4; i++)
              Track(channel: i, state: TrackState.playing, lengthFrames: 96000),
          ],
        ),
      );
      tracks.showView(StageView.wave);
      await pump(tester);
      expect(tester.takeException(), isNull);
      for (var channel = 0; channel < 4; channel++) {
        final row = find.byKey(Key('wave_row_$channel'));
        expect(row, findsOneWidget);
        expect(find.byKey(Key('wave_name_$channel')), findsOneWidget);
        await tester.tap(row);
        await tester.pump();
        expect(control.state.cursor, channel);
        verify(() => bloc.add(LooperRecordPressed(channel))).called(1);
        expect(tester.takeException(), isNull);
      }
    });

    testWidgets(
      'bars describe divided and multiple takes on both stage views',
      (
        tester,
      ) async {
        await tester.binding.setSurfaceSize(const Size(1920, 1080));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        seed(
          const LooperState(
            status: EngineStatus(sampleRate: 48000),
            transport: TransportState(
              masterLengthFrames: 384000,
              loopBars: 4,
              looperMode: LooperMode.sync,
            ),
            tracks: [
              Track(state: TrackState.playing, lengthFrames: 96000),
              Track(channel: 1),
              Track(
                channel: 2,
                state: TrackState.playing,
                lengthFrames: 768000,
                multiple: 2,
              ),
            ],
          ),
        );
        await pump(tester);
        for (final count in [
          (channel: 0, bars: '1'),
          (channel: 2, bars: '8'),
        ]) {
          expect(
            find.descendant(
              of: find.byKey(Key('tracks_bars_${count.channel}')),
              matching: find.text(count.bars),
            ),
            findsOneWidget,
          );
        }
        expect(
          find.descendant(
            of: find.byKey(const Key('tracks_bars_1')),
            matching: find.text('—'),
          ),
          findsOneWidget,
        ); // the empty track

        tracks.showView(StageView.wave);
        await tester.pump();
        expect(
          tester
              .widgetList<WaveformView>(find.byType(WaveformView))
              .map(
                (waveform) => waveform.bars,
              ),
          [1, 0, 8],
        );
      },
    );
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

    testWidgets('the bank button reveals the other bank without moving the '
        'selection', (tester) async {
      seed(
        LooperState(tracks: [for (var i = 0; i < 8; i++) Track(channel: i)]),
      );
      control.selectTrack(2);
      await pump(tester);
      // Scoped to the button: the tray behind the stage carries its own bank
      // letters now that it lands on Control rather than the retired Signal
      // face, so a bare text finder would match two of them.
      final bank = find.descendant(
        of: find.byKey(const Key('stage_bank_button')),
        matching: find.text('A'),
      );
      expect(bank, findsOneWidget);

      await tester.tap(find.byKey(const Key('stage_bank_button')));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byKey(const Key('stage_bank_button')),
          matching: find.text('B'),
        ),
        findsOneWidget,
      );
      expect(find.byKey(const Key('tracks_tile_4')), findsOneWidget);
      expect(find.byKey(const Key('tracks_tile_2')), findsNothing);
      // The selected track stays where it was, out of sight.
      expect(control.state.cursor, 2);
      verifyNever(() => bloc.add(any()));
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
        // Whole-rig recovery is the repository's: the group, else each
        // restore point on its own.
        verify(() => repository.undoClearAll()).called(1);
        verifyNever(() => repository.undo(channel: any(named: 'channel')));
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

        verify(() => repository.undoClearAll()).called(1);
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

    const barTempo = TransportState(
      tempoSource: TempoSource.manual,
      tempoBpm: 120,
    );

    for (final change in [
      (
        name: 'completed duration',
        transport: barTempo,
        length: 288000,
        rate: 48000,
        bars: '3',
      ),
      (
        name: 'established master grid',
        transport: const TransportState(
          masterLengthFrames: 240000,
          loopBars: 5,
        ),
        length: 192000,
        rate: 48000,
        bars: '4',
      ),
      (
        name: 'tempo',
        transport: const TransportState(
          tempoSource: TempoSource.manual,
          tempoBpm: 60,
        ),
        length: 192000,
        rate: 48000,
        bars: '1',
      ),
      (
        name: 'time signature',
        transport: const TransportState(
          tempoSource: TempoSource.manual,
          tempoBpm: 120,
          tsNum: 2,
        ),
        length: 192000,
        rate: 48000,
        bars: '4',
      ),
      (
        name: 'sample rate',
        transport: barTempo,
        length: 192000,
        rate: 96000,
        bars: '1',
      ),
      (
        name: 'unavailable sample rate',
        transport: barTempo,
        length: 192000,
        rate: 0,
        bars: '—',
      ),
      (
        name: 'unavailable tempo',
        transport: const TransportState(),
        length: 192000,
        rate: 48000,
        bars: '—',
      ),
      (
        name: 'fractional duration',
        transport: barTempo,
        length: 144000,
        rate: 48000,
        bars: '—',
      ),
    ]) {
      testWidgets('changing ${change.name} updates the visible bar count', (
        tester,
      ) async {
        seedStream(
          const LooperState(
            transport: barTempo,
            tracks: [Track(state: TrackState.playing, lengthFrames: 192000)],
            status: EngineStatus(sampleRate: 48000),
          ),
        );
        await pump(tester);
        final bars = find.byKey(const Key('tracks_bars_0'));
        expect(
          find.descendant(of: bars, matching: find.text('2')),
          findsOneWidget,
        );

        final next = LooperState(
          transport: change.transport,
          tracks: [
            Track(state: TrackState.playing, lengthFrames: change.length),
          ],
          status: EngineStatus(sampleRate: change.rate),
        );
        when(() => bloc.state).thenReturn(next);
        states.add(next);
        await tester.pump();

        expect(
          find.descendant(of: bars, matching: find.text(change.bars)),
          findsOneWidget,
        );
      });
    }

    testWidgets('a growing take does not rebuild chrome or sibling columns', (
      tester,
    ) async {
      const sibling = Track(
        channel: 1,
        state: TrackState.playing,
        lengthFrames: 96000,
      );
      seedStream(
        const LooperState(
          transport: barTempo,
          tracks: [
            Track(state: TrackState.recording, lengthFrames: 96000),
            sibling,
          ],
          status: EngineStatus(sampleRate: 48000),
        ),
      );
      await pump(tester);
      final chrome = tester.widget<GestureDetector>(_chromeProbe);
      final other = tester.widget<TrackColumn>(_column(1));
      const next = LooperState(
        transport: barTempo,
        tracks: [
          Track(state: TrackState.recording, lengthFrames: 192000),
          sibling,
        ],
        status: EngineStatus(sampleRate: 48000),
      );
      when(() => bloc.state).thenReturn(next);
      states.add(next);
      await tester.pump();

      expect(
        identical(chrome, tester.widget<GestureDetector>(_chromeProbe)),
        isTrue,
      );
      expect(identical(other, tester.widget<TrackColumn>(_column(1))), isTrue);
      expect(
        find.descendant(
          of: find.byKey(const Key('tracks_bars_0')),
          matching: find.text('—'),
        ),
        findsOneWidget,
      );
    });

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

      // Exactly what a moving meter emits: same structure, new levels.
      // Nothing the chrome renders depends on any of it.
      const loud = LooperState(
        tracks: [
          Track(peak: 0.9),
          Track(channel: 1, peak: 0.6),
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

    testWidgets('a level-only change rebuilds no column, only the bar', (
      tester,
    ) async {
      // One level deeper than the chrome guard above, and the half #832 did
      // not deliver while the transport ran: a moving level must not rebuild
      // the ~250-line tile around it either. `_TrackSlot` creates its
      // TrackColumn fresh on every run, so widget identity is an honest
      // rebuild detector here too.
      const quiet = LooperState(
        tracks: [
          Track(state: TrackState.playing, lengthFrames: 96000),
          Track(channel: 1, state: TrackState.playing, lengthFrames: 96000),
        ],
        status: EngineStatus(isConnected: true),
      );
      seedStream(quiet);
      await pump(tester);

      final before = tester.widget<TrackColumn>(_column(0));
      final other = tester.widget<TrackColumn>(_column(1));

      const loud = LooperState(
        tracks: [
          Track(state: TrackState.playing, lengthFrames: 96000, peak: 0.9),
          Track(channel: 1, state: TrackState.playing, lengthFrames: 96000),
        ],
        status: EngineStatus(isConnected: true),
      );
      when(() => bloc.state).thenReturn(loud);
      states.add(loud);
      await tester.pump();

      expect(
        identical(other, tester.widget<TrackColumn>(_column(1))),
        isTrue,
        reason:
            "track 0's meter tick rebuilt track 1's column -- a per-track "
            'field is leaking into every column (see #646)',
      );
      expect(
        identical(before, tester.widget<TrackColumn>(_column(0))),
        isTrue,
        reason:
            "track 0's own column rebuilt for a level -- the slot is still "
            'comparing the whole Track instead of its steady slice',
      );
      // ...and the level still got through, to the one widget that draws it.
      expect(
        tester
            .widget<PeakMeterBar>(
              find.descendant(
                of: find.byKey(const Key('tracks_tile_0')),
                matching: find.byType(PeakMeterBar),
              ),
            )
            .peak,
        0.9,
      );
    });

    for (final change in [
      (
        name: 'content',
        before: const Track(state: TrackState.recording),
        after: const Track(state: TrackState.recording, lengthFrames: 1),
      ),
      (
        name: 'recording state',
        before: const Track(),
        after: const Track(state: TrackState.recording),
      ),
      (
        name: 'recording length',
        before: const Track(state: TrackState.recording, lengthFrames: 1),
        after: const Track(state: TrackState.recording, lengthFrames: 2),
      ),
      (name: 'mute', before: const Track(), after: const Track(muted: true)),
      (
        name: 'input routing',
        before: const Track(),
        after: const Track(inputMask: 0x2),
      ),
      (
        name: 'output routing',
        before: const Track(),
        after: const Track(outputMask: 0x4),
      ),
      (
        name: 'FX',
        before: const Track(),
        after: Track(effects: [BuiltInEffect(type: TrackEffectType.drive)]),
      ),
    ]) {
      testWidgets('a ${change.name} change updates only its column', (
        tester,
      ) async {
        // Keep the global active-transport chrome steady while track 0 changes.
        const otherTrack = Track(
          channel: 1,
          state: TrackState.playing,
          lengthFrames: 96000,
        );
        seedStream(LooperState(tracks: [change.before, otherTrack]));
        await pump(tester);
        final before = tester.widget<TrackColumn>(_column(0));
        final other = tester.widget<TrackColumn>(_column(1));

        final next = LooperState(tracks: [change.after, otherTrack]);
        when(() => bloc.state).thenReturn(next);
        states.add(next);
        await tester.pump();

        final updated = tester.widget<TrackColumn>(_column(0));
        expect(identical(before, updated), isFalse);
        expect(updated.track, change.after);
        expect(
          identical(other, tester.widget<TrackColumn>(_column(1))),
          isTrue,
        );
        final meter = tester.widget<PeakMeterBar>(
          find.descendant(
            of: _column(0),
            matching: find.byType(PeakMeterBar),
          ),
        );
        expect(meter.hasContent, change.after.hasContent);
      });
    }

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
