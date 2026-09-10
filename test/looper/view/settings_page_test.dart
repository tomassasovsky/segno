import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:performance_repository/performance_repository.dart';
import 'package:segno/audio_setup/audio_setup.dart';
import 'package:segno/control/control.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/looper.dart';
import 'package:segno/pedal/pedal.dart';
import 'package:segno/theme/theme.dart';
import 'package:segno/update/cubit/update_cubit.dart';
import 'package:segno/visualizer/visualizer.dart';
import 'package:settings_repository/settings_repository.dart';
import 'package:update_repository/update_repository.dart';

import '../../helpers/helpers.dart';

class _MockLooperRepository extends Mock implements LooperRepository {}

class _MockAudioSetupCubit extends MockCubit<AudioSetupState>
    implements AudioSetupCubit {}

class _MockMidiSetupCubit extends MockCubit<MidiSetupState>
    implements MidiSetupCubit {}

class _MockLooperBloc extends MockBloc<LooperEvent, LooperState>
    implements LooperBloc {}

void main() {
  late SettingsRepository settings;
  late TracksCubit tracks;
  late WaveformWindowCubit waveformWindow;
  late HighContrastCubit highContrast;
  late AudioSetupCubit audioSetup;
  late MidiSetupCubit midiSetup;
  late PedalRepository pedalRepo;
  late PerformanceRepository performance;
  late ControlCubit control;
  late PedalCubit pedal;
  late RefreshRateCubit refreshRate;
  late RecordTimingCubit quantize;
  late MonitorCubit monitor;
  late RecordOptionsCubit recordOptions;
  late LooperRepository repository;
  late LooperBloc looperBloc;
  late TempoCubit tempo;
  late UpdateCubit updates;

  setUpAll(() {
    registerFallbackValue(RecordTiming.immediately);
    registerFallbackValue(GridDivision.off);
    registerFallbackValue(MonitorMode.off);
    registerFallbackValue(ClickMode.off);
    registerFallbackValue(const LooperRecordPressed(0));
  });

  setUp(() {
    settings = SettingsRepository(store: FakeKeyValueStore());
    updates = UpdateCubit(
      updates: const UpdateRepository(backend: UnsupportedPlatformBackend()),
      settings: settings,
    );
    tracks = TracksCubit(settings: settings);
    waveformWindow = WaveformWindowCubit(settings: settings);
    highContrast = HighContrastCubit(settings: settings);
    audioSetup = _MockAudioSetupCubit();
    when(() => audioSetup.state).thenReturn(const AudioSetupState());
    midiSetup = _MockMidiSetupCubit();
    when(() => midiSetup.state).thenReturn(const MidiSetupState());
    whenListen(
      midiSetup,
      const Stream<MidiSetupState>.empty(),
      initialState: const MidiSetupState(),
    );
    repository = _MockLooperRepository();
    when(() => repository.state).thenReturn(
      const LooperState(
        tracks: [Track()],
        status: EngineStatus(inputChannels: 2, outputChannels: 2),
      ),
    );
    when(() => repository.monitorChanges).thenAnswer(
      (_) => const Stream<int>.empty(),
    );
    when(() => repository.monitorParamChanges).thenAnswer(
      (_) => const Stream<int>.empty(),
    );
    when(
      () => repository.looperState,
    ).thenAnswer((_) => const Stream<LooperState>.empty());
    // The real control cubit: it owns the shared InteractionMode whose
    // persisted default the View section edits.
    pedalRepo = PedalRepository(const NoopPedalTransport());
    performance = PerformanceRepository(
      engine: FakeAudioEngine(),
      exportsRoot: () async => '.',
    );
    addTearDown(performance.dispose);
    control = ControlCubit(
      looper: repository,
      pedal: pedalRepo,
      settings: settings,
      performance: performance,
      keepAliveInterval: Duration.zero,
    );
    addTearDown(control.close);
    // The Audio tab embeds the pedal output picker, driven by PedalCubit.
    pedal = PedalCubit(
      pedal: pedalRepo,
      settings: settings,
      pollInterval: Duration.zero,
    );
    addTearDown(pedal.close); // disposes pedalRepo (the lifecycle owner)
    // The MIDI-learn section enumerates its targets from the live rig; an
    // un-stubbed enumeration would fail the Audio tab's build.
    when(() => repository.allMonitors()).thenAnswer((_) => const {});
    when(() => repository.allLaneChains()).thenAnswer((_) => const {});
    when(() => repository.allTrackChains()).thenAnswer((_) => const {});
    when(() => repository.masterEffects).thenAnswer((_) => const []);
    when(
      () => repository.masterChainEnvelope(),
    ).thenReturn(const FxChainEnvelope());
    refreshRate = RefreshRateCubit(repository: repository, settings: settings);
    quantize = RecordTimingCubit(repository: repository, settings: settings);
    monitor = MonitorCubit(repository: repository, settings: settings);
    when(
      () => repository.setQuantize(enabled: any(named: 'enabled')),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.setRecordTiming(any()),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.setMonitorInputMode(
        input: any(named: 'input'),
        mode: any(named: 'mode'),
      ),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.setRecDub(enabled: any(named: 'enabled')),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.setAutoRecord(enabled: any(named: 'enabled')),
    ).thenReturn(EngineResult.ok);
    recordOptions = RecordOptionsCubit(
      repository: repository,
      settings: settings,
    );
    // The Tracks section's length-preset picker reads/drives LooperBloc,
    // provided app-wide in the real app (lib/app/view/app.dart) — mirrored
    // here (mocked, like the other MockCubit/MockBloc fixtures above) so the
    // settings route can find it.
    looperBloc = _MockLooperBloc();
    when(() => looperBloc.state).thenReturn(const LooperState());
    whenListen(
      looperBloc,
      const Stream<LooperState>.empty(),
      initialState: const LooperState(),
    );
    for (final stub in <void Function()>[
      () => when(() => repository.setTempo(any())).thenReturn(EngineResult.ok),
      () => when(
        () => repository.setTimeSignature(any(), any()),
      ).thenReturn(EngineResult.ok),
      () => when(
        () => repository.setSyncTempo(on: any(named: 'on')),
      ).thenReturn(EngineResult.ok),
      () => when(
        () => repository.setQuantizeDiv(any()),
      ).thenReturn(EngineResult.ok),
      () => when(
        () => repository.setClickMode(any()),
      ).thenReturn(EngineResult.ok),
      () => when(
        () => repository.setClickOutput(any()),
      ).thenReturn(EngineResult.ok),
      () => when(
        () => repository.setClickVolume(any()),
      ).thenReturn(EngineResult.ok),
      () => when(
        () => repository.setCountIn(any()),
      ).thenReturn(EngineResult.ok),
      () => when(repository.tapTempo).thenReturn(EngineResult.ok),
    ]) {
      stub();
    }
    tempo = TempoCubit(repository: repository, settings: settings);
  });

  Future<void> pump(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.neon,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: MultiRepositoryProvider(
        providers: [
          RepositoryProvider<LooperRepository>.value(value: repository),
          RepositoryProvider<SettingsRepository>.value(value: settings),
        ],
        child: MultiBlocProvider(
          providers: [
            BlocProvider<TracksCubit>.value(value: tracks),
            BlocProvider<WaveformWindowCubit>.value(value: waveformWindow),
            BlocProvider<HighContrastCubit>.value(value: highContrast),
            BlocProvider<AudioSetupCubit>.value(value: audioSetup),
            BlocProvider<MidiSetupCubit>.value(value: midiSetup),
            BlocProvider<ControlCubit>.value(value: control),
            BlocProvider<PedalCubit>.value(value: pedal),
            BlocProvider<RefreshRateCubit>.value(value: refreshRate),
            BlocProvider<RecordTimingCubit>.value(value: quantize),
            BlocProvider<MonitorCubit>.value(value: monitor),
            BlocProvider<RecordOptionsCubit>.value(value: recordOptions),
            BlocProvider<LooperBloc>.value(value: looperBloc),
            BlocProvider<TempoCubit>.value(value: tempo),
            BlocProvider<UpdateCubit>.value(value: updates),
          ],
          child: const SettingsPage(),
        ),
      ),
    ),
  );

  testWidgets('toggling the waveform window persists the preference', (
    tester,
  ) async {
    await pump(tester);

    await tester.tap(
      find.byKey(const Key('settings_waveformWindow_switch')),
    );
    await tester.pumpAndSettle();

    expect(waveformWindow.state.enabled, isFalse);
    expect(await settings.loadShowWaveformWindow(), isFalse);
  });

  testWidgets('toggling high contrast persists the preference', (
    tester,
  ) async {
    await pump(tester);

    expect(highContrast.state, isFalse);
    await tester.tap(
      find.byKey(const Key('settings_highContrast_switch')),
    );
    await tester.pumpAndSettle();

    expect(highContrast.state, isTrue);
    expect(await settings.loadHighContrast(), isTrue);
  });

  testWidgets('track-indicators toggle renders, reflects state, and flips it', (
    tester,
  ) async {
    await pump(tester);

    final toggle = find.byKey(const Key('settings_trackIndicators_switch'));
    expect(toggle, findsOneWidget);
    // Default off on the console (the pedals carry readiness).
    expect(tracks.state.showIndicators, isFalse);

    await tester.tap(toggle);
    await tester.pumpAndSettle();

    expect(tracks.state.showIndicators, isTrue);
    expect(await settings.loadShowTrackIndicators(), isTrue);
  });

  testWidgets('renaming a track updates the list and persists it', (
    tester,
  ) async {
    await pump(tester);

    await tester.tap(find.byKey(const Key('settings_tab_tracks')));
    await tester.pumpAndSettle();
    expect(find.text('TRACK 1'), findsOneWidget);

    await tester.tap(find.byKey(const Key('settings_trackName_0')));
    await tester.pumpAndSettle();

    // The sheet says WHAT it is about to rename, not just which ordinal
    // (#526) — before this it read "Rename track 1" beside a stage that
    // already called the track by name.
    final l10n = AppLocalizations.of(
      tester.element(find.byKey(const Key('console_rename_sheet'))),
    );
    expect(find.text(l10n.defaultTrackName(1)), findsWidgets);

    // The console sheet reads KeyEvent.character; Enter is Save.
    for (var i = 0; i < 'TRACK 1'.length; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    }
    for (final ch in 'DRUMS'.split('')) {
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA, character: ch);
    }
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(find.text('DRUMS'), findsOneWidget);
    expect(await settings.loadTrackName(0), 'DRUMS');
  });

  testWidgets('choosing a default mode persists it', (
    tester,
  ) async {
    await pump(tester);
    expect(control.state.defaultMode, InteractionMode.record);

    final mute = find.byKey(const Key('settings_defaultMode_mute'));
    await tester.ensureVisible(mute);
    await tester.tap(mute);
    await tester.pumpAndSettle();

    expect(control.state.defaultMode, InteractionMode.mute);
    expect(control.state.mode, InteractionMode.mute);
    expect(
      await settings.loadDefaultInteractionMode(),
      InteractionMode.mute.token,
    );
  });

  testWidgets('the default-mode picker never offers FX (R12)', (
    tester,
  ) async {
    await pump(tester);

    // Booting into FX with no chains is a dead surface, so the mode is
    // reachable only by cycling — there is no option to pick it here.
    expect(
      find.byKey(const Key('settings_defaultMode_record')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('settings_defaultMode_mute')), findsOneWidget);
    expect(find.byKey(const Key('settings_defaultMode_fx')), findsNothing);
  });

  testWidgets('choosing a refresh rate persists it and applies it', (
    tester,
  ) async {
    await pump(tester);
    expect(refreshRate.state, 60);

    final fast = find.byKey(const Key('settings_refreshRate_120'));
    await tester.ensureVisible(fast);
    await tester.tap(fast);
    await tester.pumpAndSettle();

    expect(refreshRate.state, 120);
    expect(await settings.loadRefreshHz(), 120);
    // 120 Hz -> 1_000_000 / 120 ≈ 8333 µs.
    verify(
      () => repository.setPollInterval(const Duration(microseconds: 8333)),
    ).called(1);
  });

  testWidgets('toggling quantize on the Audio tab persists and applies it', (
    tester,
  ) async {
    await pump(tester);
    expect(quantize.state.quantize, isFalse);

    // Quantize lives in the Audio > Recording group.
    await tester.tap(find.byKey(const Key('settings_tab_audio')));
    await tester.pumpAndSettle();
    final toggle = find.byKey(const Key('audioSettings_quantize_switch'));
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();

    expect(quantize.state.quantize, isTrue);
    expect(await settings.loadQuantize(), isTrue);
    verify(() => repository.setRecordTiming(RecordTiming.loopStart)).called(1);
  });

  testWidgets('selecting a section tab shows only that section', (
    tester,
  ) async {
    await pump(tester);
    // Defaults to the View section (the waveform-window toggle lives there).
    expect(
      find.byKey(const Key('settings_waveformWindow_switch')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('settings_trackName_0')), findsNothing);

    await tester.tap(find.byKey(const Key('settings_tab_tracks')));
    await tester.pumpAndSettle();
    // The Tracks section renders the per-track rename rows.
    expect(find.byKey(const Key('settings_trackName_0')), findsOneWidget);
    expect(
      find.byKey(const Key('settings_waveformWindow_switch')),
      findsNothing,
    );

    await tester.tap(find.byKey(const Key('settings_tab_audio')));
    await tester.pumpAndSettle();
    // The Audio section renders the inline device controls (not a nav tile).
    expect(
      find.byKey(const Key('audioSettings_playbackDevice_picker')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('audioSettings_measure_button')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('settings_trackName_0')), findsNothing);

    // The Loop settings entry opens its own route rather than a section
    // (accepted design, slice 2c); tapping it here, with no root navigator,
    // leaves the page on the Audio section.
    expect(find.byKey(const Key('settings_tab_loop')), findsOneWidget);
    await tester.tap(find.byKey(const Key('settings_tab_loop')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('audioSettings_playbackDevice_picker')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('settings_tab_tempo')), findsNothing);
    expect(find.byKey(const Key('settings_tab_mode')), findsNothing);

    // There is no longer a Routing tab — the whole-system signal flow moved to
    // the Signal surface.
    expect(find.byKey(const Key('settings_tab_routing')), findsNothing);
  });

  testWidgets('Escape pops the settings page', (tester) async {
    // Providers above MaterialApp so the pushed settings route can read them.
    await tester.pumpWidget(
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<LooperRepository>.value(value: repository),
          RepositoryProvider<SettingsRepository>.value(value: settings),
        ],
        child: MultiBlocProvider(
          providers: [
            BlocProvider<TracksCubit>.value(value: tracks),
            BlocProvider<WaveformWindowCubit>.value(value: waveformWindow),
            BlocProvider<HighContrastCubit>.value(value: highContrast),
            BlocProvider<AudioSetupCubit>.value(value: audioSetup),
            BlocProvider<MidiSetupCubit>.value(value: midiSetup),
            BlocProvider<ControlCubit>.value(value: control),
            BlocProvider<PedalCubit>.value(value: pedal),
            BlocProvider<RefreshRateCubit>.value(value: refreshRate),
            BlocProvider<RecordTimingCubit>.value(value: quantize),
            BlocProvider<MonitorCubit>.value(value: monitor),
            BlocProvider<RecordOptionsCubit>.value(value: recordOptions),
            BlocProvider<LooperBloc>.value(value: looperBloc),
            BlocProvider<TempoCubit>.value(value: tempo),
            BlocProvider<UpdateCubit>.value(value: updates),
          ],
          child: MaterialApp(
            theme: AppTheme.neon,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: ElevatedButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const SettingsPage(),
                      ),
                    ),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsPage), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(SettingsPage), findsNothing);
  });
}
