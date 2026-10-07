import 'dart:async';
import 'dart:io';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fx_catalogue/fx_catalogue.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:operation_guards/operation_guards.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:pedal_repository/testing.dart';
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
import 'package:segno/looper/looper.dart';
import 'package:segno/looper/model/fx_destination.dart';
import 'package:segno/looper/view/foot_mixer_view.dart';
import 'package:segno/looper/view/fx/fx_page.dart';
import 'package:segno/looper/view/mixer_column.dart';
import 'package:segno/looper/view/stage_db_scale.dart';
import 'package:segno/looper/view/stage_top_bar.dart';
import 'package:segno/looper/view/track_column.dart';
import 'package:segno/looper/view/track_meters.dart';
import 'package:segno/looper/view/tracks_chrome.dart';
import 'package:segno/performance/performance.dart';
import 'package:segno/session/session.dart';
import 'package:segno/settings/settings.dart';
import 'package:segno/theme/theme.dart';
import 'package:segno/tuner/application/tuner_settings.dart';
import 'package:segno/tuner/cubit/tuner_cubit.dart';
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
  setUpAll(() {
    registerFallbackValue(const LooperRecordPressed(0));
    registerFallbackValue(LengthEdit.doubled);
  });

  late LooperBloc bloc;
  late TracksCubit tracks;
  late ControlCubit control;
  late LooperRepository repository;
  late SettingsRepository settings;
  late SessionCubit session;
  late PerformanceRepository performance;
  late FakeAudioEngine performanceEngine;
  // The free room an assigned Record performance sees; null is unknown.
  int? freeBytes;
  late PerformanceRecorderCubit performanceRecorder;
  late TransportClockCubit transportClock;
  late AudioSetupCubit audioSetup;
  late PedalRepository pedalRepo;
  late FakePedalLink pedalLink;

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
    pedalLink = FakePedalLink();
    pedalRepo = PedalRepository(pedalLink);
    addTearDown(pedalRepo.dispose);
    performanceEngine = FakeAudioEngine();
    freeBytes = null;
    performance = PerformanceRepository(
      guards: GuardRegistry(),
      engine: performanceEngine,
      exportsRoot: () async => Directory.systemTemp.path,
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
      freeSpaceBytes: (_) async => freeBytes,
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
  Future<void> pumpStage(
    WidgetTester tester, {
    KeyEventResult Function(FocusNode, KeyEvent)? onAncestorKey,
    Locale? locale,
    List<NavigatorObserver> navigatorObservers = const [],
  }) => tester.pumpWidget(
    ToastificationWrapper(
      child: MaterialApp(
        // The root key, so Settings and its destinations push over the stage.
        navigatorKey: segnoNavigatorKey,
        navigatorObservers: navigatorObservers,
        theme: AppTheme.neon,
        locale: locale,
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
              // The foot Tuner face reads the same cubits the app provides.
              BlocProvider<TunerCubit>(
                create: (_) => TunerCubit(
                  repository: repository,
                  settings: TunerSettings(settings: settings),
                ),
              ),
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
              BlocProvider<TunerCubit>(
                create: (_) => TunerCubit(
                  repository: repository,
                  settings: TunerSettings(settings: settings),
                ),
              ),
            ],
            child: onAncestorKey == null
                ? const TracksView()
                : Focus(onKeyEvent: onAncestorKey, child: const TracksView()),
          ),
        ),
      ),
    ),
  );

  Future<void> pump(
    WidgetTester tester, {
    KeyEventResult Function(FocusNode, KeyEvent)? onAncestorKey,
    Locale? locale,
    Size size = const Size(1920, 1080),
    List<NavigatorObserver> navigatorObservers = const [],
  }) {
    // The appliance's 1920 x 1080 page: the Mixer's top bar holds Backing &
    // click, Reset mixer and the Tuner together, wider than the default
    // 800 px test surface.
    tester.view
      ..physicalSize = size
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    return pumpStage(
      tester,
      onAncestorKey: onAncestorKey,
      locale: locale,
      navigatorObservers: navigatorObservers,
    );
  }

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

  group('Settings opens as a route over the stage', () {
    testWidgets('from the header icon', (tester) async {
      seed(const LooperState(tracks: [Track()]));
      await pump(tester);
      await tester.tap(find.byKey(const Key('stage_settings')));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsHomePage), findsOneWidget);
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
    when(
      () => repository.setTunerInput(input: any(named: 'input')),
    ).thenReturn(EngineResult.ok);
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

  group('Reverse', () {
    void pin(WidgetTester tester) {
      tester.view
        ..physicalSize = const Size(1920, 1080)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    }

    testWidgets('the REV marker shows on a reversed recorded track and '
        'remains after leaving Reverse', (tester) async {
      pin(tester);
      seed(
        const LooperState(
          tracks: [
            Track(
              state: TrackState.playing,
              lengthFrames: 48000,
              reversed: true,
            ),
            Track(channel: 1, state: TrackState.playing, lengthFrames: 48000),
            // A stale direction on an empty track never reads as REV.
            Track(channel: 2, reversed: true),
          ],
        ),
      );
      await pump(tester);
      control.setMode(InteractionMode.reverse);
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('foot_reverse_view')), findsOneWidget);
      control.setMode(InteractionMode.record);
      await tester.pump();
      await tester.pump();
      expect(find.text('REV'), findsOneWidget);
      expect(find.byKey(const Key('tracks_reverse_0')), findsOneWidget);
      expect(find.byKey(const Key('tracks_reverse_1')), findsNothing);
      expect(find.byKey(const Key('tracks_meta_2')), findsOneWidget);
      expect(find.byKey(const Key('tracks_reverse_2')), findsNothing);
      expect(
        find.bySemanticsLabel(RegExp('Track plays reversed')),
        findsOneWidget,
      );
    });

    testWidgets('a forward meta row is the pen row: evenly spread, no REV', (
      tester,
    ) async {
      pin(tester);
      seed(
        const LooperState(
          tracks: [
            Track(state: TrackState.playing, lengthFrames: 48000),
            Track(channel: 1, state: TrackState.playing, lengthFrames: 48000),
          ],
        ),
      );
      await pump(tester);
      for (final channel in [0, 1]) {
        Rect box(String part) =>
            tester.getRect(find.byKey(Key('tracks_${part}_$channel')));
        expect(find.byKey(Key('tracks_reverse_$channel')), findsNothing);
        final gapBarsLayers = box('layers').left - box('bars').right;
        final gapLayersFx = box('fx').left - box('layers').right;
        expect(
          gapLayersFx,
          closeTo(gapBarsLayers, 1),
          reason: 'track $channel',
        );
      }
    });

    for (final locale in const [Locale('en'), Locale('es')]) {
      testWidgets('REV never paints over a long count '
          '(${locale.languageCode}, 128 bars, 12 layers)', (tester) async {
        pin(tester);
        Track long(int channel, {bool reversed = false}) => Track(
          channel: channel,
          state: TrackState.playing,
          lengthFrames: 128000,
          peelDepth: 11,
          reversed: reversed,
        );
        seed(
          LooperState(
            status: const EngineStatus(sampleRate: 48000),
            transport: const TransportState(
              masterLengthFrames: 1000,
              loopBars: 1,
            ),
            tracks: [long(0, reversed: true), long(1), long(2), long(3)],
          ),
        );
        await pump(tester, locale: locale);
        Rect box(String part) =>
            tester.getRect(find.byKey(Key('tracks_${part}_0')));
        expect(find.textContaining('128'), findsWidgets);
        expect(box('reverse').left, greaterThan(box('layers').right));
        expect(box('reverse').right, lessThanOrEqualTo(box('fx').left));
        expect(box('layers').left, greaterThan(box('bars').right));
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('a refused toggle shows its notice once', (tester) async {
      pin(tester);
      seed(
        const LooperState(
          tracks: [
            Track(state: TrackState.playing, lengthFrames: 48000),
          ],
        ),
      );
      when(
        () => repository.toggleReverse(channel: any(named: 'channel')),
      ).thenAnswer((_) async => EngineResult.invalid);
      await pump(tester);
      control.setMode(InteractionMode.reverse);
      await tester.pump();
      await control.toggleFootReverseTrack(0);
      await tester.pumpAndSettle();
      expect(
        find.text('The track could not be turned around. Try again.'),
        findsOneWidget,
      );
      expect(control.state.footReverseFailure, 1);
      dismissAppToast(AppToastId.footReverseFailure);
      await tester.pump(const Duration(seconds: 10));
    });
  });

  testWidgets('Peel shows its surface and says why a press peeled nothing', (
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
    await pump(tester);
    control.setMode(InteractionMode.peel);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('foot_peel_view')), findsOneWidget);
    control.peelFootPeelTrack(0);
    await tester.pumpAndSettle();
    expect(
      find
          .text('Only the original take remains: there is no overdub to peel.')
          .hitTestable(),
      findsOneWidget,
    );
    verifyNever(() => repository.peel(channel: any(named: 'channel')));
    expect(tester.takeException(), isNull);
    dismissAppToast(AppToastId.footPeelRefused);
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('an assigned Peel says why it removed nothing, outside the '
      'Peel surface', (tester) async {
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
    pedalLink.hello();
    await tester.runAsync(
      () => control.setPedalSetup(
        const PedalSetup().withCustom(
          PedalButton.clear,
          bank: 0,
          pair: const ControlGesturePair(
            press: TrackOperationAction(
              operation: TrackOperation.peel,
              scope: SelectedTrackScope(),
            ),
          ),
        ),
      ),
    );
    await pump(tester);
    control.setMode(InteractionMode.custom);
    await tester.pumpAndSettle();
    pedalLink.press(PedalButton.clear, down: true);
    await tester.pump(const Duration(milliseconds: 50));
    pedalLink.press(PedalButton.clear, down: false);
    // The pedal events arrive on a real stream; let them land.
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(control.state.mode, InteractionMode.custom);
    expect(
      find
          .text('Only the original take remains: there is no overdub to peel.')
          .hitTestable(),
      findsOneWidget,
    );
    verifyNever(() => repository.peel(channel: any(named: 'channel')));
    dismissAppToast(AppToastId.footPeelRefused);
    await tester.pump(const Duration(seconds: 10));
  });

  for (final (operation, notice, toast) in [
    (
      TrackOperation.fade,
      'The track is empty: there is nothing to fade.',
      AppToastId.footFadeFailure,
    ),
    (
      TrackOperation.reverse,
      'The track is empty: there is nothing to turn around.',
      AppToastId.footReverseFailure,
    ),
  ]) {
    testWidgets('an assigned ${operation.name} aimed at an empty track says '
        'so outside its surface', (tester) async {
      tester.view
        ..physicalSize = const Size(1920, 1080)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      seed(const LooperState(tracks: [Track()]));
      pedalLink.hello();
      await tester.runAsync(
        () => control.setPedalSetup(
          const PedalSetup().withCustom(
            PedalButton.clear,
            bank: 0,
            pair: ControlGesturePair(
              press: TrackOperationAction(
                operation: operation,
                scope: const SelectedTrackScope(),
              ),
            ),
          ),
        ),
      );
      await pump(tester);
      control.setMode(InteractionMode.custom);
      await tester.pumpAndSettle();
      pedalLink.press(PedalButton.clear, down: true);
      await tester.pump(const Duration(milliseconds: 50));
      pedalLink.press(PedalButton.clear, down: false);
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
      expect(control.state.mode, InteractionMode.custom);
      expect(find.text(notice).hitTestable(), findsOneWidget);
      dismissAppToast(toast);
      await tester.pump(const Duration(seconds: 10));
    });
  }

  testWidgets('Custom shows its face, and an on-screen press on an '
      'assignment this build cannot run says so', (tester) async {
    tester.view
      ..physicalSize = const Size(1920, 1080)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    seed(const LooperState(tracks: [Track()]));
    pedalLink.hello();
    await tester.runAsync(
      () => control.setPedalSetup(
        const PedalSetup().withCustom(
          PedalButton.clear,
          bank: 0,
          pair: const ControlGesturePair(
            press: UnavailableAction('future:thing'),
          ),
        ),
      ),
    );
    await pump(tester);
    control.setMode(InteractionMode.custom);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('foot_custom_view')), findsOneWidget);
    await tester.tap(find.byKey(const Key('foot_custom_pedal_clear')));
    await tester.pumpAndSettle();
    expect(
      find
          .text(
            "This control's action isn't available in this version. "
            'Reassign it.',
          )
          .hitTestable(),
      findsOneWidget,
    );
    expect(control.state.assignedActionFailure, 1);
    dismissAppToast(AppToastId.assignedActionRefused);
    await tester.pump(const Duration(seconds: 10));
  });

  for (final lowDisk in [false, true]) {
    testWidgets('an assigned Record performance the rig refuses says why '
        '(lowDisk: $lowDisk)', (tester) async {
      tester.view
        ..physicalSize = const Size(1920, 1080)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      seed(const LooperState(tracks: [Track()]));
      if (lowDisk) {
        freeBytes = 1;
      } else {
        performanceEngine.perfArmResult = EngineResult.invalid;
      }
      pedalLink.hello();
      await tester.runAsync(
        () => control.setPedalSetup(
          const PedalSetup().withCustom(
            PedalButton.stop,
            bank: 0,
            pair: const ControlGesturePair(
              press: CommandAction(ControlCommand.recordPerformance),
            ),
          ),
        ),
      );
      await pump(tester);
      control.setMode(InteractionMode.custom);
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        pedalLink.press(PedalButton.stop, down: true);
        await Future<void>.delayed(const Duration(milliseconds: 30));
        pedalLink.press(PedalButton.stop, down: false);
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pumpAndSettle();
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));
      expect(
        find
            .text(
              lowDisk
                  ? l10n.perfLowDiskBlocked
                  : l10n.assignedActionRefused(l10n.actionRecordPerformance),
            )
            .hitTestable(),
        findsOneWidget,
      );
      expect(control.state.assignedActionFailure, 1);
      expect(performanceEngine.perfArmCalls, lowDisk ? 0 : 1);
      dismissAppToast(AppToastId.assignedActionRefused);
      await tester.pump(const Duration(seconds: 10));
    });
  }

  testWidgets('a refused assignment is named in its notice', (
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
    when(
      () => repository.undo(channel: any(named: 'channel')),
    ).thenReturn(EngineResult.invalid);
    const undo = TrackOperationAction(
      operation: TrackOperation.undo,
      scope: FixedTrackScope(0),
    );
    pedalLink.hello();
    await tester.runAsync(
      () => control.setPedalSetup(
        const PedalSetup().withCustom(
          PedalButton.clear,
          bank: 0,
          pair: const ControlGesturePair(press: undo),
        ),
      ),
    );
    await pump(tester);
    control.setMode(InteractionMode.custom);
    await tester.pumpAndSettle();
    pedalLink.press(PedalButton.clear, down: true);
    await tester.pump(const Duration(milliseconds: 50));
    pedalLink.press(PedalButton.clear, down: false);
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    expect(
      find
          .text(
            l10n.assignedActionRefused(
              controlActionLabel(l10n, const [], undo),
            ),
          )
          .hitTestable(),
      findsOneWidget,
    );
    expect(control.state.assignedActionFailure, 1);
    dismissAppToast(AppToastId.assignedActionRefused);
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('the foot Tuner shows its face, and an arm the engine '
      'refuses says so (#1229)', (tester) async {
    tester.view
      ..physicalSize = const Size(1920, 1080)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    seed(
      const LooperState(
        status: EngineStatus(inputChannels: 2),
        tracks: [Track()],
      ),
    );
    when(
      () => repository.setTunerInput(input: any(named: 'input')),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.setTunerMute(any()),
    ).thenReturn(EngineResult.invalid);
    await pump(tester);
    control.setMode(InteractionMode.tuner);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('foot_tuner_view')), findsOneWidget);
    expect(
      find.text('The tuner could not start. Try again.').hitTestable(),
      findsOneWidget,
    );
    control.setMode(InteractionMode.record);
    await tester.pumpAndSettle();
    verify(() => repository.setTunerInput(input: -1)).called(1);
    dismissAppToast(AppToastId.footTunerRefused);
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('the layer badge drops by one when a Peel removes a layer', (
    tester,
  ) async {
    final states = StreamController<LooperState>.broadcast();
    addTearDown(states.close);
    LooperState peeled(int depth) => LooperState(
      tracks: [
        Track(state: TrackState.playing, lengthFrames: 48000, peelDepth: depth),
      ],
    );
    when(() => bloc.state).thenReturn(peeled(2));
    when(() => repository.state).thenReturn(peeled(2));
    whenListen(bloc, states.stream, initialState: peeled(2));
    await pump(tester);
    Finder layers(String figure) => find.descendant(
      of: find.byKey(const Key('tracks_layers_0')),
      matching: find.text(figure),
    );
    expect(layers('3'), findsOneWidget);
    // A peel leaves the undo depth alone; the audible layer count drops.
    when(() => bloc.state).thenReturn(peeled(1));
    states.add(peeled(1));
    await tester.pump();
    await tester.pump();
    expect(layers('2'), findsOneWidget);
  });

  group('Multiply / Divide (#1168)', () {
    testWidgets('a sub-bar loop reads its beats on the stage', (
      tester,
    ) async {
      tester.view
        ..physicalSize = const Size(1920, 1080)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      // A sole 1-bar loop of 4/4 halved: 2 beats, no whole bar.
      seed(
        const LooperState(
          transport: TransportState(
            isRunning: true,
            masterLengthFrames: 48000,
            loopBeats: 2,
          ),
          status: EngineStatus(sampleRate: 48000),
          tracks: [Track(state: TrackState.playing, lengthFrames: 48000)],
        ),
      );
      await pump(tester);
      expect(
        find.bySemanticsLabel(RegExp('Track 1, 2 beats, 1 layer')),
        findsWidgets,
      );
    });

    testWidgets('the surface replaces the columns, and a refused edit shows '
        'its own notice once', (tester) async {
      tester.view
        ..physicalSize = const Size(1920, 1080)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      seed(
        const LooperState(
          tracks: [
            Track(state: TrackState.playing, lengthFrames: 48000),
          ],
        ),
      );
      when(
        () => repository.editLength(
          channel: any(named: 'channel'),
          edit: any(named: 'edit'),
        ),
      ).thenAnswer((_) async => EngineResult.modeMismatch);
      await pump(tester);
      control.setMode(InteractionMode.divide);
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('foot_length_view')), findsOneWidget);
      control.activateFootLengthPedal(PedalButton.clear); // Last half
      await tester.pumpAndSettle();
      expect(
        find.text(
          'That length does not fit the other loops, or would leave half a '
          'beat.',
        ),
        findsOneWidget,
      );
      expect(control.state.footLengthFailure, 1);
      dismissAppToast(AppToastId.footLengthRefused);
      await tester.pump(const Duration(seconds: 10));
    });
  });

  testWidgets('renders a tile per track', (tester) async {
    seed(const LooperState(tracks: [Track(), Track(channel: 1)]));
    await pump(tester);

    expect(find.byKey(const Key('tracks_tile_0')), findsOneWidget);
    expect(find.byKey(const Key('tracks_tile_1')), findsOneWidget);
  });

  testWidgets('the top bar Tuner button enters the Tuner by touch', (
    tester,
  ) async {
    when(
      () => repository.setTunerInput(input: any(named: 'input')),
    ).thenReturn(EngineResult.ok);
    when(() => repository.setTunerMute(any())).thenReturn(EngineResult.ok);
    seed(const LooperState(tracks: [Track()]));
    await pump(tester);
    await tester.tap(find.byKey(const Key('stage_tuner')));
    await tester.pump();
    expect(control.state.mode, InteractionMode.tuner);
  });

  testWidgets('the stage has no settings tray or pull handle', (
    tester,
  ) async {
    seed(const LooperState(tracks: [Track()]));
    await pump(tester);

    expect(find.byKey(const Key('settingsTray_handle')), findsNothing);
  });

  testWidgets('G reaches the Effects route', (
    tester,
  ) async {
    seed(const LooperState(tracks: [Track()]));
    await pump(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyG);
    await tester.pumpAndSettle();

    // Effects is a full-screen route. The route itself needs the app's root
    // navigator, which this harness does not install, so what this pins is
    // that the handler runs cleanly.
    expect(tester.takeException(), isNull);
  });

  testWidgets('tapping a tile only selects that channel in record mode', (
    tester,
  ) async {
    seed(const LooperState(tracks: [Track(), Track(channel: 1)]));
    await pump(tester);

    await tester.tap(find.byKey(const Key('tracks_tile_1')));
    // Record/Play operates the selected track; the tap arms it, never records.
    verifyNever(() => bloc.add(const LooperRecordPressed(1)));
    expect(control.state.cursor, 1);
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

  testWidgets('FX mode draws the FX face instead of the track tiles', (
    tester,
  ) async {
    control.setMode(InteractionMode.fx);
    seed(const LooperState(tracks: [Track(), Track(channel: 1)]));
    await pump(tester);

    // The pen's pedal-map face (10/03) replaces the stage; no tile is drawn
    // to tap (#1229).
    expect(find.byKey(const Key('foot_fx_view')), findsOneWidget);
    expect(find.byKey(const Key('tracks_tile_1')), findsNothing);
  });

  testWidgets('a refused FX stomp says why, once (#1229)', (tester) async {
    seed(const LooperState(tracks: [Track(), Track(channel: 1)]));
    await control.setGlobalBindings(
      PedalBindingSet([
        PedalBinding(
          key: const PedalBindingKey(button: PedalButton.undo),
          target: const FxChainTarget(
            FxAddress(stage: FxStage.input, index: 9),
          ).canonicalString(),
        ),
      ]),
    );
    control.setMode(InteractionMode.fx);
    await pump(tester);
    control.activateFootFxPedal(PedalButton.undo);
    await tester.pumpAndSettle();
    expect(
      find.text(
        "This pedal's effect is no longer available. Reassign it.",
      ),
      findsOneWidget,
    );
    expect(control.state.footFxFailure, 1);
    dismissAppToast(AppToastId.footFxFailure);
    await tester.pump(const Duration(seconds: 10));
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

  testWidgets('a number key runs its track switch binding in FX mode, bank '
      'B on 5 to 8 (#1229 review L2)', (tester) async {
    seed(
      const LooperState(
        tracks: [
          Track(),
          Track(channel: 1),
          Track(channel: 2),
          Track(channel: 3),
          Track(channel: 4),
          Track(channel: 5),
        ],
      ),
    );
    // Track switch 2 on bank B is bound to an input that is gone: running
    // it is refused with the face's notice, which is how the test sees it.
    await control.setGlobalBindings(
      PedalBindingSet([
        PedalBinding(
          key: const PedalBindingKey(button: PedalButton.track2, bank: 1),
          target: const FxChainTarget(
            FxAddress(stage: FxStage.input, index: 9),
          ).canonicalString(),
        ),
      ]),
    );
    control.setMode(InteractionMode.fx);
    await pump(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.digit6);
    await tester.pumpAndSettle();
    expect(control.state.footFxFailure, 1);
    verifyNever(() => bloc.add(const LooperTrackChainToggled(5)));
    expect(control.state.cursor, 5);
    // Switch 2 on bank A is unbound: its key toggles the track's own chain.
    await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
    await tester.pump();
    verify(() => bloc.add(const LooperTrackChainToggled(1))).called(1);
    expect(control.state.footFxFailure, 1);
    dismissAppToast(AppToastId.footFxFailure);
    await tester.pump(const Duration(seconds: 10));
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

  group('a track column is a live view of the bloc', () {
    // These pump a TrackColumn DIRECTLY, so the track it is handed and the
    // track the bloc holds can be made to differ on purpose.
    Future<void> pumpColumn(
      WidgetTester tester, {
      required Track track,
      required String name,
      required InteractionMode mode,
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
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

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
      seed(
        const LooperState(tracks: [Track(), Track(channel: 1, pending: true)]),
      );
      await pump(tester);

      await tester.tap(find.byKey(const Key('tracks_queued_1')));
      // The tap reaches the tile underneath, which selects; it never records.
      expect(control.state.cursor, 1);
      verifyNever(() => bloc.add(const LooperRecordPressed(1)));
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

    testWidgets('every strip carries the FX pair; its bypass switches a '
        'chain only when the track has one', (tester) async {
      seed(
        LooperState(
          tracks: [
            Track(
              state: TrackState.playing,
              lengthFrames: 1000,
              effects: [BuiltInEffect(type: TrackEffectType.delay)],
            ),
            const Track(
              channel: 1,
              state: TrackState.playing,
              lengthFrames: 1000,
            ),
          ],
        ),
      );
      await pump(tester);
      await showMixer(tester);

      for (final channel in [0, 1]) {
        expect(find.byKey(Key('mixer_fx_edit_$channel')), findsOneWidget);
        expect(find.byKey(Key('mixer_fx_$channel')), findsOneWidget);
      }
      // The pen's proportions: edit 97, bypass 50, beside Mute's 102.
      final mute = tester.getSize(find.byKey(const Key('mixer_mute_0'))).width;
      final edit = tester
          .getSize(find.byKey(const Key('mixer_fx_edit_0')))
          .width;
      final bypass = tester.getSize(find.byKey(const Key('mixer_fx_0'))).width;
      expect(edit / mute, closeTo(97 / 102, 0.02));
      expect(bypass / mute, closeTo(50 / 102, 0.02));

      await tester.tap(find.byKey(const Key('mixer_fx_0')));
      await tester.pump();
      verify(() => bloc.add(const LooperTrackChainToggled(0))).called(1);
      // Track 2 has no chain: its bypass is dimmed and switches nothing.
      await tester.tap(find.byKey(const Key('mixer_fx_1')));
      await tester.pump();
      verifyNever(() => bloc.add(const LooperTrackChainToggled(1)));
      Finder dim(String key) => find.descendant(
        of: find.byKey(Key(key)),
        matching: find.byType(Opacity),
      );
      expect(dim('mixer_fx_1'), findsOneWidget);
      expect(dim('mixer_fx_0'), findsNothing);
      expect(dim('mixer_fx_edit_1'), findsNothing, reason: 'edit is always on');
    });

    testWidgets('FX opens the Effects editor at that track', (tester) async {
      setSegnoFxCatalogueForTest(FxCatalogue.empty);
      addTearDown(() => setSegnoFxCatalogueForTest(null));
      seed(
        const LooperState(
          tracks: [
            Track(state: TrackState.playing, lengthFrames: 1000),
            Track(channel: 1, state: TrackState.playing, lengthFrames: 1000),
          ],
        ),
      );
      final pushed = <Route<dynamic>>[];
      await pump(
        tester,
        navigatorObservers: [_PushObserver(pushed.add)],
      );
      await showMixer(tester);
      pushed.clear();

      await tester.tap(find.byKey(const Key('mixer_fx_edit_1')));
      expect(pushed, hasLength(1));
      final route = pushed.single as PageRouteBuilder<void>;
      expect(route.settings.name, segnoFxRouteName);
      final page =
          route.pageBuilder(
                tester.element(find.byType(TracksView)),
                kAlwaysCompleteAnimation,
                kAlwaysCompleteAnimation,
              )
              as FxPage;
      expect(page.initial, const FxDestination.recordedTrack(1));
      // The editor itself is covered by its own tests; take the route down
      // before it builds against this test's providers.
      segnoNavigatorKey.currentState!.removeRoute(route);
      await tester.pumpAndSettle();
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
      // Wide enough for the Mixer's top bar, short enough to reduce it.
      await pump(tester, size: const Size(1920, 600));
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
      final sizes = <double>{};
      for (final key in ['mixer_mute_0', 'mixer_solo_0', 'mixer_fx_edit_0']) {
        final text = find.descendant(
          of: find.byKey(Key(key)),
          matching: find.byType(Text),
        );
        final label = tester.renderObject<RenderParagraph>(text);
        expect(label.size.height, lessThan(35));
        // Every label fits on one line inside its button, at one shared
        // size: a narrow strip shrinks the row together.
        expect(label.didExceedMaxLines, isFalse, reason: key);
        expect(
          label.size.width,
          lessThanOrEqualTo(tester.getSize(find.byKey(Key(key))).width),
          reason: key,
        );
        sizes.add(tester.widget<Text>(text).style!.fontSize!);
      }
      expect(sizes, hasLength(1));
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

    testWidgets('Backing & click belongs to the Mixer (#1200)', (tester) async {
      seed(const LooperState(tracks: [Track()]));
      await pump(tester);
      expect(find.byKey(const Key('stage_backing_click')), findsNothing);
      await showMixer(tester);
      expect(find.byKey(const Key('stage_backing_click')), findsOneWidget);
      // Beside Reset mixer, before it.
      expect(
        tester.getRect(find.byKey(const Key('stage_backing_click'))).right,
        lessThan(
          tester.getRect(find.byKey(const Key('stage_reset_mixer'))).left,
        ),
      );
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
        verifyNever(() => bloc.add(LooperRecordPressed(channel)));
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
    testWidgets('a take the salvage could not recover is announced (#1198)', (
      tester,
    ) async {
      whenListen(
        performanceRecorder,
        Stream.fromIterable(const [
          PerformanceRecorderIdle(recovering: true),
          PerformanceRecorderIdle(notRecovered: 1),
        ]),
        initialState: const PerformanceRecorderIdle(),
      );
      seed(const LooperState(tracks: [Track()]));
      await pump(tester);
      await tester.pump();

      expect(
        find.text('This take could not be recovered. Its files are kept.'),
        findsOneWidget,
      );
    });

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

    testWidgets('every refused arm shows its own toast (#1198, #640)', (
      tester,
    ) async {
      final controller = StreamController<PerformanceRecorderState>();
      addTearDown(controller.close);
      whenListen(
        performanceRecorder,
        controller.stream,
        initialState: const PerformanceRecorderIdle(),
      );
      seed(const LooperState(tracks: [Track()]));
      await pump(tester);
      const refused = Key('tracks_perfArmRefused_snackbar');
      const lowDisk = Key('tracks_perfLowDiskBlocked_snackbar');

      controller.add(
        const PerformanceRecorderIdle(
          refusedBy: GuardKind.sessionApply,
          refusal: 1,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(refused), findsOneWidget);
      // Let the first toast time out, so the next one is a new toast.
      await tester.pumpAndSettle(const Duration(seconds: 10));
      expect(find.byKey(refused), findsNothing);

      controller.add(
        const PerformanceRecorderIdle(
          refusedBy: GuardKind.sessionApply,
          refusal: 2,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(refused), findsOneWidget);
      await tester.pumpAndSettle(const Duration(seconds: 10));

      controller.add(
        const PerformanceRecorderIdle(lowDiskBlocked: true, refusal: 3),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(lowDisk), findsOneWidget);
      await tester.pumpAndSettle(const Duration(seconds: 10));

      // The USB drive in Save to went between the choice and the press.
      controller.add(
        const PerformanceRecorderIdle(driveUnavailable: true, refusal: 4),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('tracks_perfArmDriveUnavailable_snackbar')),
        findsOneWidget,
      );
    });

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
      // A bar and a half reads in its whole beats (#1168): 6 of 24000.
      (
        name: 'whole beats, fractional bars',
        transport: barTempo,
        length: 144000,
        rate: 48000,
        bars: '6',
      ),
      (
        name: 'fractional duration',
        transport: barTempo,
        length: 150000,
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

/// Records every route pushed onto the navigator it observes.
class _PushObserver extends NavigatorObserver {
  _PushObserver(this.onPush);

  final void Function(Route<dynamic> route) onPush;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      onPush(route);
}
