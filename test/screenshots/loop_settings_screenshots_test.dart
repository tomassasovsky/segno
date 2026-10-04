@Tags(['screenshots'])
library;

import 'dart:async';
import 'dart:io';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/application/record_settings.dart';
import 'package:segno/looper/application/record_timing_settings.dart';
import 'package:segno/looper/application/tempo_settings.dart';
import 'package:segno/looper/looper.dart';
import 'package:segno/looper/model/one_shot.dart';
import 'package:segno/looper/model/overdub_decay.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_hub.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_page.dart';
import 'package:segno/theme/theme.dart';
import 'package:settings_repository/settings_repository.dart';

import '../helpers/helpers.dart';
import '../helpers/mock_decay_playback_settings.dart';

class _MockLooperBloc extends MockBloc<LooperEvent, LooperState>
    implements LooperBloc {}

class _MockLooperRepository extends Mock implements LooperRepository {}

/// Three takes in Song mode at 120 BPM, track 1 with its own timing and
/// decay, as the pen's per-track examples draw.
const _rig = LooperState(
  tracks: [
    Track(state: TrackState.playing, lengthFrames: 96000),
    Track(
      channel: 1,
      state: TrackState.playing,
      lengthFrames: 96000,
      lengthPresetOverride: 8,
      recordTimingOverride: RecordTiming.quarter,
      overdubDecayOverride: 25,
      oneShotOverride: true,
    ),
    Track(channel: 2),
    Track(channel: 3),
  ],
  transport: TransportState(
    isRunning: true,
    tempoBpm: 84,
    tempoSource: TempoSource.manual,
    masterLengthFrames: 96000,
    looperMode: LooperMode.song,
    currentBeat: 1,
  ),
);

void main() {
  late TempoSettings tempoOwner;
  const fontDir =
      '/Users/Tomas/development/flutter/bin/cache/artifacts/material_fonts';
  // Author-machine goldens, like the other screenshot suites here: the
  // Material fonts come from the local SDK, so everywhere else this skips.
  final hasScreenshotFonts = File('$fontDir/Roboto-Regular.ttf').existsSync();
  final authorCaptureDir = Platform.environment['SEGNO_AUTHOR_CAPTURE_DIR'];

  setUpAll(() async {
    registerFallbackValue(const LooperRecordPressed(0));
    registerFallbackValue(LooperMode.multi);
    registerFallbackValue(RecordTiming.immediately);
    registerFallbackValue(GridDivision.bar);
    registerFallbackValue(ClickMode.off);
    registerFallbackValue(RecordStartEditKind.restore);
    if (!hasScreenshotFonts) return;
    await loadScreenshotFont('Roboto', [
      '$fontDir/Roboto-Regular.ttf',
      '$fontDir/Roboto-Medium.ttf',
      '$fontDir/Roboto-Bold.ttf',
    ]);
    await loadScreenshotFont('Inter', [
      'assets/fonts/Inter-Regular.ttf',
      'assets/fonts/Inter-Medium.ttf',
      'assets/fonts/Inter-SemiBold.ttf',
      'assets/fonts/Inter-Bold.ttf',
    ]);
    await loadScreenshotFont('JetBrains Mono', [
      'assets/fonts/JetBrainsMono-Regular.ttf',
      'assets/fonts/JetBrainsMono-Medium.ttf',
      'assets/fonts/JetBrainsMono-SemiBold.ttf',
    ]);
    // The rail and stepper glyphs are a package font, which the harness does
    // not bundle: without this load every icon is a tofu box.
    await loadScreenshotFont('packages/lucide_icons_flutter/Lucide', [
      packageAssetPath('lucide_icons_flutter', 'assets/lucide.ttf'),
    ]);
  });

  late _MockLooperBloc bloc;
  late _MockLooperRepository repository;
  late SettingsRepository settings;
  late int confirmedLength;
  late Map<int, int> confirmedTrackLengths;
  late LooperMode confirmedMode;
  late RecordTiming confirmedTiming;
  late GridDivision confirmedDivision;
  late Map<int, RecordTiming> confirmedTrackTiming;
  late ClickMode confirmedClickMode;
  late int confirmedCountIn;
  late bool confirmedSoundStart;
  late bool recordStartCaptureLocked;
  late bool recordStartRecoveryRequired;

  setUp(() {
    bloc = _MockLooperBloc();
    repository = _MockLooperRepository();
    when(() => repository.lengthSettingsFailures).thenAnswer(
      (_) => const Stream<EngineResult>.empty(),
    );
    confirmedLength = 0;
    confirmedTrackLengths = {1: 8};
    confirmedMode = LooperMode.song;
    confirmedTiming = RecordTiming.immediately;
    confirmedDivision = GridDivision.bar;
    confirmedTrackTiming = {1: RecordTiming.quarter};
    confirmedClickMode = ClickMode.off;
    confirmedCountIn = 1;
    confirmedSoundStart = false;
    recordStartCaptureLocked = false;
    recordStartRecoveryRequired = false;
    when(() => repository.sessionRevision).thenReturn(0);
    when(() => repository.inputSetup).thenReturn(const InputSetup.empty());
    when(() => repository.laneCount(any())).thenAnswer((call) {
      final channel = call.positionalArguments.first as int;
      return repository.state.tracks
              .where((track) => track.channel == channel)
              .firstOrNull
              ?.lanes
              .length ??
          0;
    });
    when(() => repository.mixGeneration).thenReturn(0);
    when(() => repository.lengthRecoveryRequired).thenReturn(false);
    when(() => repository.lengthSettingsSettled).thenReturn(true);
    when(() => repository.recordLengthCaptureLocked).thenReturn(false);
    when(() => repository.trackLengthPresetOverrides).thenAnswer(
      (_) => Map.unmodifiable(confirmedTrackLengths),
    );
    when(
      () => repository.setLengthSettings(
        defaultBars: any(named: 'defaultBars'),
        overrides: any(named: 'overrides'),
        mode: any(named: 'mode'),
      ),
    ).thenAnswer((call) {
      confirmedLength = call.namedArguments[#defaultBars] as int;
      confirmedTrackLengths = Map.of(
        call.namedArguments[#overrides] as Map<int, int>,
      );
      confirmedMode = call.namedArguments[#mode] as LooperMode;
      return EngineResult.ok;
    });
    when(() => repository.recordTimingSettingsSettled).thenReturn(true);
    when(() => repository.recordTimingRecoveryRequired).thenReturn(false);
    when(() => repository.recordTimingCaptureLocked).thenReturn(false);
    when(
      () => repository.defaultRecordTiming,
    ).thenAnswer((_) => confirmedTiming);
    when(() => repository.trackRecordTimingOverrides).thenAnswer(
      (_) => Map.unmodifiable(confirmedTrackTiming),
    );
    when(
      () => repository.settleRecordTimingSettings(),
    ).thenAnswer((_) async => EngineResult.ok);
    when(
      () => repository.setRecordTimingSettings(
        defaultTiming: any(named: 'defaultTiming'),
        rememberedDivision: any(named: 'rememberedDivision'),
        trackOverrides: any(named: 'trackOverrides'),
      ),
    ).thenAnswer((call) {
      confirmedTiming = call.namedArguments[#defaultTiming] as RecordTiming;
      confirmedDivision =
          call.namedArguments[#rememberedDivision] as GridDivision;
      confirmedTrackTiming = Map.of(
        call.namedArguments[#trackOverrides] as Map<int, RecordTiming>,
      );
      return EngineResult.ok;
    });
    when(() => repository.sessionTransport).thenAnswer(
      (_) => TransportState(
        defaultLengthPresetBars: confirmedLength,
        looperMode: confirmedMode,
        recordTiming: confirmedTiming,
        quantizeDiv: confirmedDivision,
        clickMode: confirmedClickMode,
        countInBars: confirmedCountIn,
        autoRecord: confirmedSoundStart,
      ),
    );
    when(() => repository.clickModeFailures).thenAnswer(
      (_) => const Stream<EngineResult>.empty(),
    );
    when(() => repository.recordTimingFailures).thenAnswer(
      (_) => const Stream<EngineResult>.empty(),
    );
    when(() => repository.clickModeSettled).thenReturn(true);
    when(() => repository.recordStartSettingsFailures).thenAnswer(
      (_) => const Stream<EngineResult>.empty(),
    );
    when(() => repository.recordStartSettingsSettled).thenReturn(true);
    when(
      () => repository.recordStartRecoveryRequired,
    ).thenAnswer((_) => recordStartRecoveryRequired);
    when(
      () => repository.recordStartCaptureLocked,
    ).thenAnswer((_) => recordStartCaptureLocked);
    when(() => repository.recordStartSettings).thenAnswer(
      (_) => (
        countInBars: confirmedCountIn,
        soundStart: confirmedSoundStart,
      ),
    );
    when(() => repository.recordStartRestartIntent).thenAnswer(
      (_) => (
        countInBars: confirmedCountIn,
        soundStart: confirmedSoundStart,
      ),
    );
    when(() => repository.settleRecordStartSettings()).thenAnswer(
      (_) async => EngineResult.ok,
    );
    when(
      () => repository.setRecordStartSettings(
        countInBars: any(named: 'countInBars'),
        soundStart: any(named: 'soundStart'),
        editKind: any(named: 'editKind'),
      ),
    ).thenAnswer((call) {
      confirmedCountIn = call.namedArguments[#countInBars] as int;
      confirmedSoundStart = call.namedArguments[#soundStart] as bool;
      return EngineResult.ok;
    });
    when(() => repository.clickModeRecoveryRequired).thenReturn(false);
    when(() => repository.clickModeCaptureLocked).thenReturn(false);
    when(() => repository.clickModeRestartIntent).thenAnswer(
      (_) => confirmedClickMode,
    );
    when(() => repository.clickVolumeSettled).thenReturn(true);
    when(() => repository.clickVolumeRecoveryRequired).thenReturn(false);
    when(() => repository.settleClickMode()).thenAnswer(
      (_) async => EngineResult.ok,
    );
    when(() => repository.setClickMode(any())).thenAnswer((call) {
      confirmedClickMode = call.positionalArguments.single as ClickMode;
      return EngineResult.ok;
    });
    when(
      () => repository.settleLengthSettings(),
    ).thenAnswer((_) async => EngineResult.ok);
    when(
      () => repository.looperModeGate(any()),
    ).thenReturn(LooperModeGate.open);
    when(
      () => repository.looperState,
    ).thenAnswer((_) => const Stream<LooperState>.empty());
    when(
      () => repository.rigReplaced,
    ).thenAnswer((_) => const Stream<void>.empty());
    when(() => repository.state).thenReturn(_rig);
    for (final stub in <void Function()>[
      () => when(() => repository.setTempo(any())).thenReturn(EngineResult.ok),
      () => when(repository.tapTempo).thenReturn(EngineResult.ok),
      () => when(
        () => repository.setTimeSignature(any(), any()),
      ).thenReturn(EngineResult.ok),
      () => when(
        () => repository.setSyncTempo(on: any(named: 'on')),
      ).thenReturn(EngineResult.ok),
      () => when(
        () => repository.setClickOutput(any()),
      ).thenReturn(EngineResult.ok),
      () => when(
        () => repository.setClickVolume(any()),
      ).thenReturn(EngineResult.ok),
      () => when(
        () => repository.setRecDub(enabled: any(named: 'enabled')),
      ).thenReturn(EngineResult.ok),
      () => when(
        () => repository.setDefaultMultiple(multiple: any(named: 'multiple')),
      ).thenReturn(EngineResult.ok),
      () => when(() => repository.setDefaultLengthPreset(any())).thenAnswer((
        call,
      ) {
        confirmedLength = call.positionalArguments.single as int;
        return EngineResult.ok;
      }),
      () => when(
        () => repository.setRecordTiming(any()),
      ).thenReturn(EngineResult.ok),
      () => when(
        () => repository.setOverdubDecay(any()),
      ).thenReturn(EngineResult.ok),
      () => when(
        () => repository.setDefaultOneShot(oneShot: any(named: 'oneShot')),
      ).thenReturn(EngineResult.ok),
    ]) {
      stub();
    }
  });

  Future<void> pump(
    WidgetTester tester, {
    required LoopSettingsPageId page,
    LooperState state = _rig,
    Future<void> Function(TempoSettings tempo, RecordSettings options)? prepare,
  }) async {
    tester.view
      ..physicalSize = const Size(1920, 1080)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    recordStartCaptureLocked = state.tracks.any((track) => track.isCapturing);
    when(() => bloc.state).thenReturn(state);
    whenListen(bloc, const Stream<LooperState>.empty(), initialState: state);
    // The Click checkpoint and its initial writer must share testWidgets' zone.
    final store = FakeKeyValueStore()
      ..values['looper.mode'] = LooperMode.song.code
      ..values['tempo.length_preset.1'] = 8
      ..values['track_record_timing.1'] = RecordTiming.quarter.index;
    settings = SettingsRepository(store: store);
    tempoOwner = TempoSettings(repository: repository, settings: settings);
    final closeTempoOwner = tempoOwner.close;
    addTearDown(() => unawaited(closeTempoOwner()));
    final tempo = TempoCubit(settings: tempoOwner);
    final options = RecordSettings(
      repository: repository,
      settings: settings,
    );
    final playback = MockDecayPlaybackSettings(
      snapshot: DecaySnapshot(
        defaultPercent: 0,
        trackOverrides: const {1: 25},
      ),
      oneShot: OneShotSnapshot(
        defaultOneShot: false,
        trackOverrides: const {1: true},
      ),
    );
    addTearDown(playback.close);
    final timingOwner = RecordTimingSettings(
      repository: repository,
      settings: settings,
    );
    addTearDown(() => unawaited(timingOwner.close()));
    final timing = RecordTimingCubit(settings: timingOwner);
    final tracks = TracksCubit(settings: settings);
    final closeRecordOwner = options.close;
    addTearDown(() => unawaited(closeRecordOwner()));
    for (final cubit in <BlocBase<Object?>>[
      tempo,
      timing,
      tracks,
    ]) {
      addTearDown(() => unawaited(cubit.close()));
    }
    await tempo.setTempo(84);
    await tempoOwner.loadRecordStart();
    await tempoOwner.loadClickMode();
    expect(tempo.state.clickModeSnapshot?.mode, ClickMode.recFirst);
    await options.load();
    await timingOwner.load();
    expect(options.state.recordLengthReady, isTrue);
    expect(timing.state.recordTimingReady, isTrue);
    await prepare?.call(tempoOwner, options);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: ThemeData(
          fontFamily: SurfaceTheme.displayFont,
          extensions: const [SurfaceTheme.dark],
        ),
        home: RepositoryProvider<LooperRepository>.value(
          value: repository,
          child: MultiBlocProvider(
            providers: [
              BlocProvider<LooperBloc>.value(value: bloc),
              BlocProvider.value(value: tempo),
              BlocProvider(
                create: (_) => RecordOptionsCubit(settings: options),
              ),
              BlocProvider<PlaybackOptionsCubit>(
                create: (_) => PlaybackOptionsCubit(settings: playback),
              ),
              BlocProvider.value(value: timing),
              BlocProvider.value(value: tracks),
            ],
            child: LoopSettingsPage(initial: page),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('Loop settings hub', (tester) async {
    await pump(tester, page: LoopSettingsPageId.hub);
    await expectLater(
      find.byType(LoopSettingsPage),
      matchesGoldenFile('goldens/loop_settings_hub.png'),
    );
  }, skip: !hasScreenshotFonts);

  testWidgets('Loop mode with a refused card and the stop dialog', (
    tester,
  ) async {
    when(
      () => repository.looperModeGate(LooperMode.multi),
    ).thenReturn(LooperModeGate.spans);
    when(
      () => repository.looperModeGate(LooperMode.free),
    ).thenReturn(LooperModeGate.playing);
    await pump(tester, page: LoopSettingsPageId.mode);
    await expectLater(
      find.byType(LoopSettingsPage),
      matchesGoldenFile('goldens/loop_settings_mode.png'),
    );
    await tester.tap(find.byKey(const Key('loop_mode_free')));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/loop_settings_mode_confirm.png'),
    );
  }, skip: !hasScreenshotFonts);

  testWidgets('Recording, and locked while recording', (tester) async {
    await pump(tester, page: LoopSettingsPageId.recording);
    await expectLater(
      find.byType(LoopSettingsPage),
      matchesGoldenFile('goldens/loop_settings_recording.png'),
    );
  }, skip: !hasScreenshotFonts);

  testWidgets('Recording locked', (tester) async {
    await pump(
      tester,
      page: LoopSettingsPageId.recording,
      state: const LooperState(
        tracks: [Track(state: TrackState.recording, lengthFrames: 10)],
        transport: TransportState(isRunning: true, tempoBpm: 84),
      ),
    );
    await expectLater(
      find.byType(LoopSettingsPage),
      matchesGoldenFile('goldens/loop_settings_recording_locked.png'),
    );
  }, skip: !hasScreenshotFonts);

  testWidgets('Author recording-start Sound and recovery captures', (
    tester,
  ) async {
    await pump(
      tester,
      page: LoopSettingsPageId.recording,
      prepare: (tempo, _) async {
        expect((await tempoOwner.setCountInBars(0)).isOk, isTrue);
      },
    );
    await expectLater(
      find.byType(LoopSettingsPage),
      matchesGoldenFile('$authorCaptureDir/recording_pedal_off.png'),
    );
    expect((await tempoOwner.setSoundStart(enabled: true)).isOk, isTrue);
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(LoopSettingsPage),
      matchesGoldenFile('$authorCaptureDir/recording_sound_on.png'),
    );
    recordStartRecoveryRequired = true;
    expect(
      (await tempoOwner.setCountInBars(0)).isOk,
      isFalse,
    );
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(LoopSettingsPage),
      matchesGoldenFile('$authorCaptureDir/recording_sound_recovery.png'),
    );
  }, skip: !hasScreenshotFonts || authorCaptureDir == null);

  testWidgets('Tempo & click, and the time signature grid', (tester) async {
    await pump(tester, page: LoopSettingsPageId.tempo);
    expect(find.byKey(const Key('loop_click_recFirst')), findsOneWidget);
    expect(confirmedClickMode, ClickMode.recFirst);
    await expectLater(
      find.byType(LoopSettingsPage),
      matchesGoldenFile('goldens/loop_settings_tempo.png'),
    );
    await tester.tap(find.byKey(const Key('loop_tempo_signature')));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(LoopSettingsPage),
      matchesGoldenFile('goldens/loop_settings_signature.png'),
    );
  }, skip: !hasScreenshotFonts);

  testWidgets('Author Count-in Off and 2-bar captures', (tester) async {
    await pump(tester, page: LoopSettingsPageId.tempo);
    expect((await tempoOwner.setCountInBars(0)).isOk, isTrue);
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(LoopSettingsPage),
      matchesGoldenFile('$authorCaptureDir/tempo_count_in_off.png'),
    );
    expect((await tempoOwner.setCountInBars(2)).isOk, isTrue);
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(LoopSettingsPage),
      matchesGoldenFile('$authorCaptureDir/tempo_count_in_2.png'),
    );
  }, skip: !hasScreenshotFonts || authorCaptureDir == null);

  testWidgets('Length & quantize, defaults and a custom track', (
    tester,
  ) async {
    await pump(
      tester,
      page: LoopSettingsPageId.length,
      prepare: (_, options) => options.setDefaultLengthBars(4),
    );
    await expectLater(
      find.byType(LoopSettingsPage),
      matchesGoldenFile('goldens/loop_settings_length_defaults.png'),
    );
    await tester.tap(find.byKey(const Key('loop_scope_track_1')));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(LoopSettingsPage),
      matchesGoldenFile('goldens/loop_settings_length_custom.png'),
    );
  }, skip: !hasScreenshotFonts);

  testWidgets('Playback & overdub, a custom track', (tester) async {
    await pump(tester, page: LoopSettingsPageId.playback);
    await tester.tap(find.byKey(const Key('loop_scope_track_1')));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(LoopSettingsPage),
      matchesGoldenFile('goldens/loop_settings_playback_custom.png'),
    );
  }, skip: !hasScreenshotFonts);

  testWidgets('Audio & tempo readout', (tester) async {
    await pump(tester, page: LoopSettingsPageId.audioTempo);
    await expectLater(
      find.byType(LoopSettingsPage),
      matchesGoldenFile('goldens/loop_settings_audio_tempo.png'),
    );
  }, skip: !hasScreenshotFonts);
}
