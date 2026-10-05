import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:segno/app/segno_navigator.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/application/playback_settings.dart';
import 'package:segno/looper/application/record_settings.dart';
import 'package:segno/looper/application/record_timing_settings.dart';
import 'package:segno/looper/application/tempo_settings.dart';
import 'package:segno/looper/cubit/settings_tray_cubit.dart';
import 'package:segno/looper/looper.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_hub.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_page.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/looper/view/tray/tray_navigation_rail.dart';
import 'package:segno/theme/theme.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../../helpers/helpers.dart';

class _MockLooperBloc extends MockBloc<LooperEvent, LooperState>
    implements LooperBloc {}

class _MockLooperRepository extends Mock implements LooperRepository {}

/// Three playing takes at 120 BPM in Sync mode, Multi's shared length off.
const _rig = LooperState(
  tracks: [
    Track(state: TrackState.playing, lengthFrames: 96000),
    Track(channel: 1, state: TrackState.playing, lengthFrames: 96000),
    Track(channel: 2),
  ],
  transport: TransportState(
    isRunning: true,
    tempoBpm: 120,
    tempoSource: TempoSource.manual,
    masterLengthFrames: 96000,
    looperMode: LooperMode.song,
  ),
);

void main() {
  late TempoSettings tempoOwner;
  late _MockLooperBloc bloc;
  late _MockLooperRepository repository;
  late FakeKeyValueStore store;
  late SettingsRepository settings;
  late StreamController<LooperState> states;
  late StreamController<void> rigReplaced;
  late int confirmedLength;
  late LooperMode confirmedMode;
  late Map<int, int> confirmedTrackLengths;
  late LooperState currentRig;
  late int sessionRevision;
  late int confirmedDecay;
  late Map<int, int> confirmedTrackDecay;
  late bool confirmedOneShot;
  late Map<int, bool> confirmedTrackOneShot;
  late RecordTiming confirmedTiming;
  late GridDivision rememberedDivision;
  late Map<int, RecordTiming> confirmedTrackTiming;
  late ClickMode confirmedClickMode;
  late bool clickModeCaptureLocked;
  late int confirmedCountIn;
  late bool confirmedSoundStart;
  late bool recordStartRecovery;
  late bool recordStartSettled;

  setUpAll(() {
    registerFallbackValue(const LooperRecordPressed(0));
    registerFallbackValue(LooperMode.multi);
    registerFallbackValue(RecordTiming.immediately);
    registerFallbackValue(GridDivision.off);
    registerFallbackValue(<int, RecordTiming>{});
    registerFallbackValue(ClickMode.off);
    registerFallbackValue(RecordStartEditKind.restore);
  });

  setUp(() {
    bloc = _MockLooperBloc();
    repository = _MockLooperRepository();
    when(() => repository.lengthSettingsFailures).thenAnswer(
      (_) => const Stream<EngineResult>.empty(),
    );
    store = FakeKeyValueStore();
    settings = SettingsRepository(store: store);
    confirmedLength = 0;
    confirmedMode = LooperMode.song;
    confirmedTrackLengths = {};
    currentRig = _rig;
    sessionRevision = 0;
    confirmedDecay = 0;
    confirmedTrackDecay = {};
    confirmedOneShot = false;
    confirmedTrackOneShot = {};
    confirmedTiming = RecordTiming.immediately;
    rememberedDivision = GridDivision.off;
    confirmedTrackTiming = {};
    confirmedClickMode = ClickMode.off;
    clickModeCaptureLocked = false;
    confirmedCountIn = 1;
    confirmedSoundStart = false;
    recordStartRecovery = false;
    recordStartSettled = true;
    when(() => repository.sessionRevision).thenAnswer((_) => sessionRevision);
    when(() => repository.mixGeneration).thenReturn(0);
    when(() => repository.decayReplayResult).thenReturn(EngineResult.ok);
    when(
      () => repository.defaultOverdubDecay,
    ).thenAnswer((_) => confirmedDecay);
    when(
      () => repository.trackOverdubDecayOverrides,
    ).thenAnswer((_) => Map.unmodifiable(confirmedTrackDecay));
    when(() => repository.decayRestartIntent).thenAnswer(
      (_) => (
        defaultPercent: confirmedDecay,
        trackOverrides: Map.unmodifiable(confirmedTrackDecay),
      ),
    );
    when(() => repository.defaultOneShot).thenAnswer((_) => confirmedOneShot);
    when(() => repository.trackOneShotOverrides).thenAnswer(
      (_) => Map.unmodifiable(confirmedTrackOneShot),
    );
    when(() => repository.oneShotSettingsSettled).thenReturn(true);
    when(() => repository.oneShotRecoveryRequired).thenReturn(false);
    when(
      () => repository.settleOneShot(),
    ).thenAnswer((_) async => EngineResult.ok);
    when(() => repository.oneShotRestartIntent).thenAnswer(
      (_) => (
        defaultOneShot: confirmedOneShot,
        trackOverrides: Map<int, bool>.unmodifiable(confirmedTrackOneShot),
      ),
    );
    when(
      () => repository.setOneShotRestartIntent(
        defaultOneShot: any(named: 'defaultOneShot'),
        trackOverrides: any(named: 'trackOverrides'),
      ),
    ).thenAnswer((_) {});
    when(
      () => repository.setOneShotSnapshot(
        defaultOneShot: any(named: 'defaultOneShot'),
        trackOverrides: any(named: 'trackOverrides'),
      ),
    ).thenAnswer((call) {
      confirmedOneShot = call.namedArguments[#defaultOneShot] as bool;
      confirmedTrackOneShot = Map.of(
        call.namedArguments[#trackOverrides] as Map<int, bool>,
      );
      return EngineResult.ok;
    });
    when(
      () => repository.setOneShot(
        channel: any(named: 'channel'),
        oneShot: any(named: 'oneShot'),
        releasedOneShot: any(named: 'releasedOneShot'),
      ),
    ).thenAnswer((call) {
      final channel = call.namedArguments[#channel] as int;
      final value = call.namedArguments[#oneShot] as bool?;
      if (value == null) {
        confirmedTrackOneShot.remove(channel);
      } else {
        confirmedTrackOneShot[channel] = value;
      }
      return EngineResult.ok;
    });

    when(
      () => repository.setDecayRestartIntent(
        defaultPercent: any(named: 'defaultPercent'),
        trackOverrides: any(named: 'trackOverrides'),
      ),
    ).thenAnswer((_) {});
    when(
      () => repository.setTrackOverdubDecay(
        channel: any(named: 'channel'),
        percent: any(named: 'percent'),
      ),
    ).thenAnswer((call) {
      final channel = call.namedArguments[#channel] as int;
      final percent = call.namedArguments[#percent] as int?;
      if (percent == null) {
        confirmedTrackDecay.remove(channel);
      } else {
        confirmedTrackDecay[channel] = percent;
      }
      return EngineResult.ok;
    });
    when(() => repository.clickVolumeSettled).thenReturn(true);
    when(() => repository.clickVolumeRecoveryRequired).thenReturn(false);
    when(() => repository.clickModeFailures).thenAnswer(
      (_) => const Stream<EngineResult>.empty(),
    );
    when(() => repository.clickVolumeFailures).thenAnswer(
      (_) => const Stream<EngineResult>.empty(),
    );
    when(() => repository.clickModeSettled).thenReturn(true);
    when(() => repository.clickModeRecoveryRequired).thenReturn(false);
    when(() => repository.clickModeCaptureLocked).thenAnswer(
      (_) => clickModeCaptureLocked,
    );
    when(() => repository.clickModeRestartIntent).thenAnswer(
      (_) => confirmedClickMode,
    );
    when(() => repository.settleClickMode()).thenAnswer(
      (_) async => EngineResult.ok,
    );
    when(() => repository.setClickMode(any())).thenAnswer((call) {
      confirmedClickMode = call.positionalArguments.single as ClickMode;
      return EngineResult.ok;
    });
    when(
      () => repository.setClickMode(
        any(),
        releasedMode: any(named: 'releasedMode'),
      ),
    ).thenAnswer((call) {
      confirmedClickMode = call.positionalArguments.single as ClickMode;
      return EngineResult.ok;
    });
    when(() => repository.recordStartSettingsFailures).thenAnswer(
      (_) => const Stream<EngineResult>.empty(),
    );
    when(() => repository.recordStartSettingsSettled).thenAnswer(
      (_) => recordStartSettled,
    );
    when(
      () => repository.recordStartRecoveryRequired,
    ).thenAnswer((_) => recordStartRecovery);
    when(() => repository.recordStartCaptureLocked).thenAnswer(
      (_) => currentRig.tracks.any((track) => track.isCapturing),
    );
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
        releasedSettings: any(named: 'releasedSettings'),
      ),
    ).thenAnswer((call) {
      confirmedCountIn = call.namedArguments[#countInBars] as int;
      confirmedSoundStart = call.namedArguments[#soundStart] as bool;
      return EngineResult.ok;
    });
    when(() => repository.recordTimingFailures).thenAnswer(
      (_) => const Stream<EngineResult>.empty(),
    );
    when(() => repository.recordTimingCaptureLocked).thenAnswer(
      (_) => currentRig.tracks.any(
        (track) =>
            track.state == TrackState.recording ||
            track.state == TrackState.overdubbing,
      ),
    );
    when(() => repository.recordTimingSettingsSettled).thenReturn(true);
    when(() => repository.recordTimingRecoveryRequired).thenReturn(false);
    when(
      () => repository.defaultRecordTiming,
    ).thenAnswer((_) => confirmedTiming);
    when(() => repository.trackRecordTimingOverrides).thenAnswer(
      (_) => Map.unmodifiable(confirmedTrackTiming),
    );
    when(() => repository.recordTimingRestartIntent).thenAnswer(
      (_) => (
        defaultTiming: confirmedTiming,
        rememberedDivision: rememberedDivision,
        trackOverrides: Map.unmodifiable(confirmedTrackTiming),
      ),
    );
    when(() => repository.settleRecordTimingSettings()).thenAnswer(
      (_) async => EngineResult.ok,
    );
    when(
      () => repository.setRecordTimingSettings(
        defaultTiming: any(named: 'defaultTiming'),
        rememberedDivision: any(named: 'rememberedDivision'),
        trackOverrides: any(named: 'trackOverrides'),
      ),
    ).thenAnswer((call) {
      confirmedTiming = call.namedArguments[#defaultTiming] as RecordTiming;
      rememberedDivision =
          call.namedArguments[#rememberedDivision] as GridDivision;
      confirmedTrackTiming = Map.of(
        call.namedArguments[#trackOverrides] as Map<int, RecordTiming>,
      );
      return EngineResult.ok;
    });
    when(
      () => repository.setRecordTiming(
        any(),
        releasedTiming: any(named: 'releasedTiming'),
      ),
    ).thenAnswer((call) {
      confirmedTiming = call.positionalArguments.single as RecordTiming;
      if (confirmedTiming.quantize) {
        rememberedDivision = confirmedTiming.division;
      }
      return EngineResult.ok;
    });
    when(
      () => repository.setTrackRecordTiming(
        channel: any(named: 'channel'),
        timing: any(named: 'timing'),
        releasedTiming: any(named: 'releasedTiming'),
      ),
    ).thenAnswer((call) {
      final channel = call.namedArguments[#channel] as int;
      final value = call.namedArguments[#timing] as RecordTiming?;
      if (value == null) {
        confirmedTrackTiming.remove(channel);
      } else {
        confirmedTrackTiming[channel] = value;
      }
      return EngineResult.ok;
    });
    when(() => repository.recordLengthCaptureLocked).thenAnswer(
      (_) => currentRig.tracks.any(
        (track) =>
            track.state == TrackState.recording ||
            track.state == TrackState.overdubbing,
      ),
    );
    when(() => repository.lengthRecoveryRequired).thenReturn(false);
    when(() => repository.lengthSettingsSettled).thenReturn(true);
    when(() => repository.trackLengthPresetOverrides).thenAnswer(
      (_) => Map.unmodifiable(confirmedTrackLengths),
    );
    when(() => repository.lengthRestartIntent).thenAnswer(
      (_) => (
        defaultBars: confirmedLength,
        trackOverrides: Map<int, int>.unmodifiable(confirmedTrackLengths),
        mode: confirmedMode,
      ),
    );
    when(() => repository.sessionTransport).thenAnswer(
      (_) => TransportState(
        defaultLengthPresetBars: confirmedLength,
        looperMode: confirmedMode,
        recordTiming: confirmedTiming,
        quantizeDiv: rememberedDivision,
        clickMode: confirmedClickMode,
        countInBars: confirmedCountIn,
        autoRecord: confirmedSoundStart,
      ),
    );
    when(
      () => repository.settleLengthSettings(),
    ).thenAnswer((_) async => EngineResult.ok);
    states = StreamController<LooperState>.broadcast();
    rigReplaced = StreamController<void>.broadcast();
    when(() => repository.looperModeGate(any())).thenReturn(
      LooperModeGate.open,
    );
    when(() => repository.looperState).thenAnswer(
      (_) => states.stream.map((state) {
        currentRig = state;
        clickModeCaptureLocked = state.tracks.any(
          (track) =>
              track.state == TrackState.recording ||
              track.state == TrackState.overdubbing,
        );
        return state;
      }),
    );
    when(() => repository.rigReplaced).thenAnswer((_) => rigReplaced.stream);
    when(() => repository.state).thenAnswer((_) => currentRig);
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
    when(
      () => repository.setTrackLengthPreset(
        channel: any(named: 'channel'),
        bars: any(named: 'bars'),
        releasedBars: any(named: 'releasedBars'),
      ),
    ).thenAnswer((call) {
      final channel = call.namedArguments[#channel] as int;
      final bars = call.namedArguments[#bars] as int?;
      if (bars == null) {
        confirmedTrackLengths.remove(channel);
      } else {
        confirmedTrackLengths[channel] = bars;
      }
      return EngineResult.ok;
    });
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
        () => repository.settleClickVolume(),
      ).thenAnswer((_) async => EngineResult.ok),
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
      () =>
          when(
            () => repository.setOverdubDecay(any()),
          ).thenAnswer((call) {
            confirmedDecay = call.positionalArguments.single as int;
            return EngineResult.ok;
          }),
      () =>
          when(
            () => repository.setDefaultOneShot(
              oneShot: any(named: 'oneShot'),
              releasedOneShot: any(named: 'releasedOneShot'),
            ),
          ).thenAnswer((call) {
            confirmedOneShot = call.namedArguments[#oneShot] as bool;
            return EngineResult.ok;
          }),
    ]) {
      stub();
    }
  });

  tearDown(() async {
    await states.close();
    await rigReplaced.close();
  });

  void seed(LooperState state) {
    currentRig = state;
    confirmedLength = state.transport.defaultLengthPresetBars;
    confirmedMode = state.transport.looperMode;
    confirmedTrackLengths = {
      for (final track in state.tracks)
        if (track.lengthPresetOverride != null)
          track.channel: track.lengthPresetOverride!,
    };
    confirmedDecay = state.transport.overdubDecay;
    confirmedTrackDecay = {};
    for (final track in state.tracks) {
      final value = track.overdubDecayOverride;
      if (value != null) confirmedTrackDecay[track.channel] = value;
    }
    confirmedOneShot = state.transport.defaultOneShot;
    confirmedTrackOneShot = {
      for (final track in state.tracks)
        if (track.oneShotOverride != null)
          track.channel: track.oneShotOverride!,
    };
    confirmedTiming = state.transport.recordTiming;
    confirmedClickMode = state.transport.clickMode;
    clickModeCaptureLocked = state.tracks.any(
      (track) =>
          track.state == TrackState.recording ||
          track.state == TrackState.overdubbing,
    );
    rememberedDivision = state.transport.quantizeDiv;
    confirmedTrackTiming = {
      for (final track in state.tracks)
        if (track.recordTimingOverride != null)
          track.channel: track.recordTimingOverride!,
    };
    when(() => bloc.state).thenReturn(state);
    whenListen(bloc, states.stream, initialState: state);
  }

  late TempoCubit tempo;
  late RecordSettings options;
  late PlaybackSettings playbackOwner;
  late PlaybackOptionsCubit playback;
  late RecordTimingCubit timing;
  late TracksCubit tracks;
  late SettingsTrayCubit tray;

  Future<void> pump(
    WidgetTester tester, {
    LooperState state = _rig,
    LoopSettingsPageId initial = LoopSettingsPageId.hub,
    bool fromTray = false,
    ClickMode? savedClickMode,
    int? savedCountIn,
    bool loadRecordStart = true,
    ValueNotifier<Key>? pageIdentity,
  }) async {
    tester.view
      ..physicalSize = const Size(1920, 1080)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    seed(state);
    // The Click owner's startup read waits the settings writer initialized in
    // its zone. Rebind that writer inside testWidgets while retaining values
    // seeded before pump (for example the saved count-in choice).
    settings = SettingsRepository(store: store);
    if (savedClickMode != null) {
      await settings.restoreClickModeCheckpoint(savedClickMode.code);
    }
    if (savedCountIn != null) {
      await settings.saveRecordStartSettings(
        countInBars: savedCountIn,
        soundStart: false,
      );
    }
    await settings.saveLooperMode(confirmedMode.code);
    await settings.saveDefaultLengthPreset(confirmedLength);
    for (final entry in confirmedTrackLengths.entries) {
      await settings.saveTrackLengthPreset(entry.key, entry.value);
    }
    await settings.restoreDecayCheckpoint(
      channel: null,
      percent: confirmedDecay,
    );
    for (final entry in confirmedTrackDecay.entries) {
      await settings.restoreDecayCheckpoint(
        channel: entry.key,
        percent: entry.value,
      );
    }
    await settings.restoreOneShotCheckpoint(
      channel: null,
      oneShot: confirmedOneShot,
    );
    for (final entry in confirmedTrackOneShot.entries) {
      await settings.restoreOneShotCheckpoint(
        channel: entry.key,
        oneShot: entry.value,
      );
    }
    await settings.restoreRecordTimingCheckpoint((
      quantize: confirmedTiming.quantize,
      division: rememberedDivision.code,
      trackOverrides: {
        for (final entry in confirmedTrackTiming.entries)
          entry.key: entry.value.code,
      },
    ));
    tempoOwner = TempoSettings(
      repository: repository,
      settings: settings,
    );
    final closeTempoOwner = tempoOwner.close;
    addTearDown(() => unawaited(closeTempoOwner()));
    tempo = TempoCubit(settings: tempoOwner);
    await tempoOwner.clickModeOwner.load();
    if (loadRecordStart) await tempoOwner.loadRecordStart();
    options = RecordSettings(repository: repository, settings: settings);
    playbackOwner = PlaybackSettings(
      repository: repository,
      settings: settings,
    );
    final closePlaybackOwner = playbackOwner.close;
    addTearDown(() => unawaited(closePlaybackOwner()));
    await playbackOwner.load();
    playback = PlaybackOptionsCubit(settings: playbackOwner);
    await options.load();
    final timingOwner = RecordTimingSettings(
      repository: repository,
      settings: settings,
    );
    addTearDown(() => unawaited(timingOwner.close()));
    timing = RecordTimingCubit(settings: timingOwner);
    await timingOwner.load();
    tracks = TracksCubit(settings: settings);
    tray = SettingsTrayCubit();
    if (fromTray) tray.open();
    addTearDown(tray.close);
    resetSegnoNavigatorForTest();
    final closeRecordOwner = options.close;
    addTearDown(() => unawaited(closeRecordOwner()));
    for (final cubit in <BlocBase<Object?>>[
      tempo,
      playback,
      timing,
      tracks,
    ]) {
      addTearDown(() => unawaited(cubit.close()));
    }
    await tester.pumpWidget(
      RepositoryProvider<LooperRepository>.value(
        value: repository,
        child: MultiBlocProvider(
          providers: [
            BlocProvider<LooperBloc>.value(value: bloc),
            BlocProvider.value(value: tempo),
            BlocProvider(create: (_) => RecordOptionsCubit(settings: options)),
            BlocProvider.value(value: playback),
            BlocProvider.value(value: timing),
            BlocProvider.value(value: tracks),
            BlocProvider.value(value: tray),
          ],
          child: MaterialApp(
            navigatorKey: segnoNavigatorKey,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            theme: fromTray
                ? AppTheme.neon
                : ThemeData(extensions: const [SurfaceTheme.dark]),
            home: fromTray
                ? Scaffold(
                    body: Stack(
                      children: [
                        const SizedBox.expand(key: Key('test_tracks_stage')),
                        BlocBuilder<SettingsTrayCubit, SettingsTrayState>(
                          builder: (context, state) => state.dragProgress == 0
                              ? const SizedBox.shrink()
                              : ColoredBox(
                                  key: const Key('test_tray_cover'),
                                  color: Colors.black,
                                  child: SizedBox(
                                    width: 200,
                                    height: 800,
                                    child: TrayNavigationRail(
                                      onBrightness: () {},
                                    ),
                                  ),
                                ),
                        ),
                      ],
                    ),
                  )
                : pageIdentity == null
                ? LoopSettingsPage(initial: initial)
                : ValueListenableBuilder<Key>(
                    valueListenable: pageIdentity,
                    builder: (_, key, _) =>
                        LoopSettingsPage(key: key, initial: initial),
                  ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  AppLocalizations l10nOf(WidgetTester tester) =>
      AppLocalizations.of(tester.element(find.byType(LoopSettingsPage)));

  testWidgets('refused length tap explains failure and keeps saved choice', (
    tester,
  ) async {
    final failures = StreamController<EngineResult>.broadcast();
    addTearDown(failures.close);
    when(() => repository.lengthSettingsFailures).thenAnswer(
      (_) => failures.stream,
    );
    when(() => repository.setDefaultLengthPreset(any())).thenAnswer((_) {
      failures.add(EngineResult.invalid);
      return EngineResult.invalid;
    });
    await pump(tester, initial: LoopSettingsPageId.length);
    clearInteractions(repository);

    await tester.tap(find.byKey(const Key('loop_length_bars')));
    await tester.pumpAndSettle();

    expect(find.text(l10nOf(tester).loopSettingsRefused), findsOneWidget);
    expect(find.byKey(const Key('loop_stepper_value')), findsOneWidget);
    expect(find.text('4'), findsOneWidget);
    expect(
      find.text(l10nOf(tester).loopLengthNotApplied('Auto')),
      findsOneWidget,
    );
    expect(
      tester
          .widget<LoopChoiceButton>(
            find.byKey(const Key('loop_length_auto')),
          )
          .selected,
      isTrue,
    );
    expect(options.state.defaultLengthBars, 0);
    expect(await settings.loadDefaultLengthPreset(), 0);
    verifyNever(() => repository.settleLengthSettings());
  });

  for (final remount in [false, true]) {
    testWidgets(
      'late Use default refusal belongs only to its page (remount $remount)',
      (tester) async {
        final pageIdentity = ValueNotifier<Key>(UniqueKey());
        addTearDown(pageIdentity.dispose);
        await pump(
          tester,
          initial: LoopSettingsPageId.length,
          pageIdentity: pageIdentity,
          state: const LooperState(
            tracks: [Track(lengthPresetOverride: 6)],
            transport: TransportState(looperMode: LooperMode.song),
          ),
        );
        await tester.tap(find.byKey(const Key('loop_scope_track_0')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('loop_length_use_default')),
          findsOneWidget,
        );
        final receipt = Completer<EngineResult>();
        var observedReceipt = false;
        when(
          () => repository.setTrackLengthPreset(channel: 0, bars: null),
        ).thenReturn(EngineResult.ok);
        when(() => repository.settleLengthSettings()).thenAnswer((_) {
          observedReceipt = true;
          return receipt.future;
        });
        await tester.tap(find.byKey(const Key('loop_length_use_default')));
        await tester.pumpAndSettle();
        expect(observedReceipt, isTrue);
        expect(options.state.trackLengthPresetOverrides, {0: 6});
        if (remount) {
          pageIdentity.value = UniqueKey();
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const Key('loop_scope_track_0')));
          await tester.pumpAndSettle();
        }
        receipt.complete(EngineResult.invalid);
        await tester.pumpAndSettle();
        final l10n = l10nOf(tester);
        expect(options.state.trackLengthPresetOverrides, {0: 6});
        expect(await settings.loadTrackLengthPreset(0), 6);
        expect(
          find.text(l10n.loopLengthNotApplied(l10n.lengthPresetBars(6))),
          remount ? findsNothing : findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('callback refusal is visible on the mode page', (tester) async {
    final failures = StreamController<EngineResult>.broadcast();
    addTearDown(failures.close);
    when(() => repository.lengthSettingsFailures).thenAnswer(
      (_) => failures.stream,
    );
    await pump(tester, initial: LoopSettingsPageId.mode);
    failures.add(EngineResult.invalid);
    await tester.pumpAndSettle();

    expect(find.text(l10nOf(tester).loopSettingsRefused), findsOneWidget);
    expect(bloc.state.transport.looperMode, LooperMode.song);
    expect(tester.takeException(), isNull);
  });

  testWidgets('slider double tap only resets; single tap and drag commit', (
    tester,
  ) async {
    final previews = <double>[];
    final commits = <double>[];
    var resets = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(extensions: const [SurfaceTheme.dark]),
        home: Scaffold(
          body: Center(
            child: LoopSlider(
              key: const Key('test_loop_slider'),
              value: 0.5,
              width: 300,
              semanticLabel: 'Test level',
              onChanged: previews.add,
              onChangeEnd: commits.add,
              onDoubleTap: () => resets++,
            ),
          ),
        ),
      ),
    );
    final slider = find.byKey(const Key('test_loop_slider'));
    final tap = tester.getCenter(slider);
    await tester.tapAt(tap);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tapAt(tap);
    await tester.pump(const Duration(milliseconds: 400));
    expect(resets, 1);
    expect(previews, isEmpty);
    expect(commits, isEmpty);

    await tester.tapAt(tap);
    await tester.pump(const Duration(milliseconds: 400));
    expect(previews, hasLength(1));
    expect(commits, hasLength(1));

    await tester.drag(slider, const Offset(70, 0));
    await tester.pumpAndSettle();
    expect(previews.length, greaterThan(1));
    expect(commits, hasLength(2));
  });

  group('hub', () {
    testWidgets('tray Loop entry: Back keeps tray, Stage reveals Tracks', (
      tester,
    ) async {
      await pump(tester, fromTray: true);
      expect(find.byKey(const Key('test_tray_cover')), findsOneWidget);
      await tester.tap(find.byKey(const Key('settingsTrayRail_loop')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('loop_settings_page_hub')), findsOneWidget);
      await tester.tap(find.byKey(const Key('loop_settings_back')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('test_tray_cover')), findsOneWidget);

      await tester.tap(find.byKey(const Key('settingsTrayRail_loop')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('loop_settings_stage')));
      await tester.pumpAndSettle();
      expect(find.byType(LoopSettingsPage), findsNothing);
      expect(find.byKey(const Key('test_tray_cover')), findsNothing);
      expect(find.byKey(const Key('test_tracks_stage')), findsOneWidget);
      expect(tray.state.dragProgress, 0);
    });

    testWidgets('arrow focus and Enter open the next submenu', (tester) async {
      await pump(tester);
      final first = find.byKey(const Key('loop_hub_mode'));
      final ink = find.descendant(of: first, matching: find.byType(InkWell));
      Focus.of(tester.element(ink.first)).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('loop_settings_page_recording')),
        findsOneWidget,
      );
    });

    testWidgets('lists the six submenus with their current choices', (
      tester,
    ) async {
      await pump(tester);
      final l10n = l10nOf(tester);
      expect(find.byKey(const Key('loop_settings_page_hub')), findsOneWidget);
      expect(find.text(l10n.loopSettingsTitle), findsOneWidget);
      for (final row in [
        'mode',
        'recording',
        'tempo',
        'length',
        'playback',
        'audioTempo',
      ]) {
        expect(find.byKey(Key('loop_hub_$row')), findsOneWidget);
      }
      expect(find.text(l10n.looperModeSongLabel), findsOneWidget);
      expect(find.text(l10n.loopSummaryRecordPlayOverdub), findsOneWidget);
      expect(find.text(l10n.loopSummaryTempo('120', '4/4')), findsOneWidget);
      expect(
        find.text(
          l10n.loopSummaryPair(l10n.loopLengthAuto, l10n.loopTimingImmediately),
        ),
        findsOneWidget,
      );
      expect(
        find.text(
          l10n.loopSummaryPair(l10n.loopPlaybackLoop, l10n.loopSummaryNoDecay),
        ),
        findsOneWidget,
      );
    });

    testWidgets('a row opens its submenu and Back returns to the hub', (
      tester,
    ) async {
      await pump(tester);
      await tester.tap(find.byKey(const Key('loop_hub_recording')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('loop_settings_page_recording')),
        findsOneWidget,
      );
      expect(find.text(l10nOf(tester).loopSettingsCrumbNested), findsOneWidget);
      await tester.tap(find.byKey(const Key('loop_settings_back')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('loop_settings_page_hub')), findsOneWidget);
    });
  });

  group('Loop mode', () {
    testWidgets('an open mode dispatches the change; the current one is '
        'marked', (tester) async {
      await pump(tester, initial: LoopSettingsPageId.mode);
      final l10n = l10nOf(tester);
      expect(find.byKey(const Key('loop_mode_song')), findsOneWidget);
      expect(find.text(l10n.loopModeMultiDesc), findsOneWidget);
      await tester.tap(find.byKey(const Key('loop_mode_free')));
      await tester.pumpAndSettle();
      verify(
        () => bloc.add(const LooperModeChanged(LooperMode.free)),
      ).called(1);
    });

    testWidgets('a refused mode shows its reason and dispatches nothing', (
      tester,
    ) async {
      when(
        () => repository.looperModeGate(LooperMode.multi),
      ).thenReturn(LooperModeGate.spans);
      when(
        () => repository.looperModeGate(LooperMode.band),
      ).thenReturn(LooperModeGate.capturing);
      await pump(tester, initial: LoopSettingsPageId.mode);
      final l10n = l10nOf(tester);
      expect(find.text(l10n.loopModeReasonEqualLengths), findsOneWidget);
      expect(find.text(l10n.modeChangeBlockedCapturing), findsOneWidget);
      await tester.tap(find.byKey(const Key('loop_mode_multi')));
      await tester.pumpAndSettle();
      verifyNever(() => bloc.add(any(that: isA<LooperModeChanged>())));
    });

    testWidgets('playing loops ask before the switch, in the pen dialog', (
      tester,
    ) async {
      when(
        () => repository.looperModeGate(LooperMode.multi),
      ).thenReturn(LooperModeGate.playing);
      await pump(tester, initial: LoopSettingsPageId.mode);
      final l10n = l10nOf(tester);
      await tester.tap(find.byKey(const Key('loop_mode_multi')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('loop_mode_confirm')), findsOneWidget);
      expect(find.text(l10n.modeChangeStopBody), findsOneWidget);
      await tester.tap(find.byKey(const Key('loop_mode_confirm_cancel')));
      await tester.pumpAndSettle();
      verifyNever(() => bloc.add(any(that: isA<LooperModeChanged>())));

      await tester.tap(find.byKey(const Key('loop_mode_multi')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('loop_mode_confirm_switch')));
      await tester.pumpAndSettle();
      verify(
        () => bloc.add(const LooperModeChanged(LooperMode.multi)),
      ).called(1);
    });
  });

  group('Recording', () {
    testWidgets('unknown start has no selected method or provisional Pedal', (
      tester,
    ) async {
      await pump(
        tester,
        initial: LoopSettingsPageId.recording,
        loadRecordStart: false,
      );
      final l10n = l10nOf(tester);
      expect(find.text(l10n.recordStartUnavailable), findsOneWidget);
      for (final key in const [
        'loop_recording_pedal',
        'loop_recording_sound',
      ]) {
        final button = tester.widget<LoopChoiceButton>(find.byKey(Key(key)));
        expect(button.selected, isFalse);
        expect(button.enabled, isFalse);
      }
    });

    testWidgets('the choices write the record options and the note follows', (
      tester,
    ) async {
      await pump(tester, initial: LoopSettingsPageId.recording);
      final l10n = l10nOf(tester);
      expect(find.text(l10n.loopRecordingNoteCountIn(1)), findsOneWidget);
      await tester.tap(find.byKey(const Key('loop_recording_sound')));
      await tester.pumpAndSettle();
      expect(tempo.state.confirmedRecordStart?.soundStart, isTrue);
      expect(tempo.state.confirmedRecordStart?.countInBars, 0);
      expect(find.text(l10n.loopRecordingNoteSound), findsOneWidget);
      await tester.tap(find.byKey(const Key('loop_recording_overdub')));
      await tester.pumpAndSettle();
      expect(options.state.recDub, isTrue);
    });

    testWidgets('a count-in names itself in the note', (tester) async {
      await pump(
        tester,
        initial: LoopSettingsPageId.recording,
        savedCountIn: 2,
      );
      await tester.pumpAndSettle();
      expect(
        find.text(l10nOf(tester).loopRecordingNoteCountIn(2)),
        findsOneWidget,
      );
    });

    testWidgets('recovery keeps the last Sound selection but blocks edits', (
      tester,
    ) async {
      await pump(tester, initial: LoopSettingsPageId.recording);
      await tester.tap(find.byKey(const Key('loop_recording_sound')));
      await tester.pumpAndSettle();
      expect(tempo.state.confirmedRecordStart?.soundStart, isTrue);

      recordStartRecovery = true;
      states.add(currentRig);
      await tester.pumpAndSettle();
      expect(tempo.state.recordStartSnapshot, isNull);
      final sound = tester.widget<LoopChoiceButton>(
        find.byKey(const Key('loop_recording_sound')),
      );
      expect(sound.selected, isTrue);
      expect(sound.enabled, isFalse);
      expect(find.text(l10nOf(tester).recordStartUnavailable), findsOneWidget);
    });

    testWidgets('a capture locks the rows behind the banner', (tester) async {
      await pump(
        tester,
        state: const LooperState(
          tracks: [Track(state: TrackState.recording, lengthFrames: 10)],
        ),
        initial: LoopSettingsPageId.recording,
      );
      expect(find.byKey(const Key('loop_lock_banner')), findsOneWidget);
      await tester.tap(find.byKey(const Key('loop_recording_sound')));
      await tester.pumpAndSettle();
      expect(tempo.state.confirmedRecordStart?.soundStart, isFalse);
    });
  });

  group('Tempo & click', () {
    testWidgets('click, count-in and tap reach the tempo cubit', (
      tester,
    ) async {
      await pump(tester, initial: LoopSettingsPageId.tempo);
      expect(find.byKey(const Key('loop_tempo_readout')), findsOneWidget);
      expect(tempo.state.clickModeSnapshot?.mode, ClickMode.recFirst);
      await tester.tap(find.byKey(const Key('loop_click_playRec')));
      await tester.pumpAndSettle();
      expect(tempo.state.clickMode, ClickMode.playRec);
      await tester.tap(find.byKey(const Key('loop_count_in_2')));
      await tester.pumpAndSettle();
      expect(tempo.state.countInBars, 2);
      await tester.tap(find.byKey(const Key('loop_tempo_tap')));
      verify(repository.tapTempo).called(1);
    });

    testWidgets('unknown count-in has no provisional bar selected', (
      tester,
    ) async {
      await pump(
        tester,
        initial: LoopSettingsPageId.tempo,
        loadRecordStart: false,
      );
      expect(tempo.state.confirmedRecordStart, isNull);
      for (final bars in const [0, 1, 2, 4]) {
        final choice = tester.widget<LoopChoiceButton>(
          find.byKey(Key('loop_count_in_$bars')),
        );
        expect(choice.selected, isFalse);
        expect(choice.enabled, isFalse);
      }
      expect(
        find.byKey(const Key('loop_count_in_disabled_reason')),
        findsOneWidget,
      );
    });

    testWidgets('pending and recovery retain but disable Count-in 2', (
      tester,
    ) async {
      await pump(
        tester,
        initial: LoopSettingsPageId.tempo,
        savedCountIn: 2,
      );
      expect(tempo.state.confirmedRecordStart?.countInBars, 2);
      for (final recovering in const [false, true]) {
        recordStartSettled = recovering;
        recordStartRecovery = recovering;
        states.add(currentRig);
        await tester.pumpAndSettle();
        expect(tempo.state.recordStartSnapshot, isNull);
        final selected = tester.widget<LoopChoiceButton>(
          find.byKey(const Key('loop_count_in_2')),
        );
        expect(selected.selected, isTrue);
        expect(selected.enabled, isFalse);
        clearInteractions(repository);
        await tester.tap(find.byKey(const Key('loop_count_in_4')));
        await tester.pumpAndSettle();
        verifyNever(
          () => repository.setRecordStartSettings(
            countInBars: any(named: 'countInBars'),
            soundStart: any(named: 'soundStart'),
            editKind: any(named: 'editKind'),
            releasedSettings: any(named: 'releasedSettings'),
          ),
        );
      }
      await tester.tap(find.byKey(const Key('loop_settings_back')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('loop_hub_tempo')));
      await tester.pumpAndSettle();
      final reopened = tester.widget<LoopChoiceButton>(
        find.byKey(const Key('loop_count_in_2')),
      );
      expect(reopened.selected, isTrue);
      expect(reopened.enabled, isFalse);
    });

    testWidgets('capture retains and locks Count-in without a write', (
      tester,
    ) async {
      await pump(
        tester,
        initial: LoopSettingsPageId.tempo,
        savedCountIn: 2,
      );
      states.add(
        const LooperState(
          tracks: [Track(state: TrackState.recording)],
        ),
      );
      await tester.pumpAndSettle();
      expect(tempo.state.recordStartSnapshot?.captureLocked, isTrue);
      final selected = tester.widget<LoopChoiceButton>(
        find.byKey(const Key('loop_count_in_2')),
      );
      expect(selected.selected, isTrue);
      expect(selected.enabled, isFalse);
      clearInteractions(repository);
      await tester.tap(find.byKey(const Key('loop_count_in_4')));
      await tester.pumpAndSettle();
      verifyNever(
        () => repository.setRecordStartSettings(
          countInBars: any(named: 'countInBars'),
          soundStart: any(named: 'soundStart'),
          editKind: any(named: 'editKind'),
          releasedSettings: any(named: 'releasedSettings'),
        ),
      );
    });

    testWidgets('explicit Off is ready; capture retains and locks the choice', (
      tester,
    ) async {
      await pump(
        tester,
        initial: LoopSettingsPageId.tempo,
        savedClickMode: ClickMode.off,
      );
      expect(tempo.state.clickModeSnapshot?.mode, ClickMode.off);
      expect(
        tester
            .widget<LoopChoiceButton>(
              find.byKey(const Key('loop_click_off')),
            )
            .selected,
        isTrue,
      );
      states.add(
        const LooperState(
          tracks: [Track(state: TrackState.recording)],
        ),
      );
      await tester.pumpAndSettle();
      expect(tempo.state.clickModeSnapshot?.captureLocked, isTrue);
      expect(
        tester
            .widget<LoopChoiceButton>(
              find.byKey(const Key('loop_click_off')),
            )
            .selected,
        isTrue,
      );
      expect(
        tester
            .widget<LoopChoiceButton>(
              find.byKey(const Key('loop_click_playRec')),
            )
            .enabled,
        isFalse,
      );
      expect(
        find.byKey(const Key('loop_click_disabled_reason')),
        findsOneWidget,
      );
    });

    testWidgets('unconfirmed owner displays no provisional First selection', (
      tester,
    ) async {
      when(() => repository.setClickMode(any())).thenReturn(
        EngineResult.notReady,
      );
      await pump(tester, initial: LoopSettingsPageId.tempo);
      expect(tempo.state.clickModeSnapshot, isNull);
      expect(
        tester
            .widget<LoopChoiceButton>(
              find.byKey(const Key('loop_click_recFirst')),
            )
            .selected,
        isFalse,
      );
      expect(
        tester
            .widget<LoopChoiceButton>(
              find.byKey(const Key('loop_click_recFirst')),
            )
            .enabled,
        isFalse,
      );
      expect(find.text('Hear click is unavailable.'), findsOneWidget);
    });

    testWidgets('recovery dims the last confirmed Hear click choice', (
      tester,
    ) async {
      await pump(
        tester,
        initial: LoopSettingsPageId.tempo,
        savedClickMode: ClickMode.recFirst,
      );
      expect(tempo.state.clickModeSnapshot?.mode, ClickMode.recFirst);
      when(() => repository.clickModeRecoveryRequired).thenReturn(true);
      states.add(_rig);
      await tester.pumpAndSettle();
      expect(tempo.state.clickModeReady, isFalse);
      expect(tempo.state.clickMode, ClickMode.recFirst);
      final first = tester.widget<LoopChoiceButton>(
        find.byKey(const Key('loop_click_recFirst')),
      );
      expect(first.selected, isTrue);
      expect(first.enabled, isFalse);
      expect(find.text('Hear click is unavailable.'), findsOneWidget);

      await tester.tap(find.byKey(const Key('loop_settings_back')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('loop_hub_tempo')));
      await tester.pumpAndSettle();
      final reopened = tester.widget<LoopChoiceButton>(
        find.byKey(const Key('loop_click_recFirst')),
      );
      expect(reopened.selected, isTrue);
      expect(reopened.enabled, isFalse);
    });

    testWidgets('the signature button opens the grid and a pick returns', (
      tester,
    ) async {
      await pump(tester, initial: LoopSettingsPageId.tempo);
      await tester.tap(find.byKey(const Key('loop_tempo_signature')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('loop_settings_page_signature')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('loop_signature_7_8')));
      await tester.pumpAndSettle();
      expect(tempo.state.tsNum, 7);
      expect(tempo.state.tsDen, 8);
      expect(find.byKey(const Key('loop_settings_page_tempo')), findsOneWidget);
    });
  });

  group('Length & quantize', () {
    testWidgets('a 30-second loop can shorten refused 4 bars to 3', (
      tester,
    ) async {
      final failures = StreamController<EngineResult>.broadcast();
      addTearDown(failures.close);
      when(() => repository.lengthSettingsFailures).thenAnswer(
        (_) => failures.stream,
      );
      when(() => repository.setDefaultLengthPreset(any())).thenAnswer((call) {
        final bars = call.positionalArguments.single as int;
        // Four 4/4 bars at 30 BPM need 32 seconds; three need 24.
        if (bars * 8 > 30) {
          failures.add(EngineResult.invalid);
          return EngineResult.invalid;
        }
        confirmedLength = bars;
        return EngineResult.ok;
      });
      await pump(tester, initial: LoopSettingsPageId.length);

      await tester.tap(find.byKey(const Key('loop_length_bars')));
      await tester.pumpAndSettle();
      expect(options.state.defaultLengthBars, 0);
      expect(find.text('4'), findsOneWidget);
      await tester.tap(find.byKey(const Key('loop_stepper_minus')));
      await tester.pumpAndSettle();

      expect(options.state.defaultLengthBars, 3);
      expect(await settings.loadDefaultLengthPreset(), 3);
      expect(
        tester
            .widget<AppText>(
              find.byKey(const Key('loop_stepper_value')),
            )
            .data,
        '3',
      );
      expect(find.textContaining('Not applied.'), findsNothing);
    });

    testWidgets('repeated refusals advance from the last candidate', (
      tester,
    ) async {
      final failures = StreamController<EngineResult>.broadcast();
      addTearDown(failures.close);
      when(() => repository.lengthSettingsFailures).thenAnswer(
        (_) => failures.stream,
      );
      var capacityBars = 8;
      when(() => repository.setDefaultLengthPreset(any())).thenAnswer((call) {
        final bars = call.positionalArguments.single as int;
        if (bars > capacityBars) {
          failures.add(EngineResult.invalid);
          return EngineResult.invalid;
        }
        confirmedLength = bars;
        return EngineResult.ok;
      });
      await pump(tester, initial: LoopSettingsPageId.length);
      await options.setDefaultLengthBars(8);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('loop_length_auto')));
      await tester.pumpAndSettle();
      capacityBars = 6;

      await tester.tap(find.byKey(const Key('loop_length_bars')));
      await tester.pumpAndSettle();
      expect(find.text('8'), findsOneWidget);
      await tester.tap(find.byKey(const Key('loop_stepper_minus')));
      await tester.pumpAndSettle();
      expect(find.text('7'), findsOneWidget);
      expect(options.state.defaultLengthBars, 0);
      await tester.tap(find.byKey(const Key('loop_stepper_minus')));
      await tester.pumpAndSettle();
      expect(options.state.defaultLengthBars, 6);
      expect(await settings.loadDefaultLengthPreset(), 6);
      expect(find.text('6'), findsOneWidget);
    });

    testWidgets('a refused step keeps an existing confirmed Bars choice', (
      tester,
    ) async {
      final failures = StreamController<EngineResult>.broadcast();
      addTearDown(failures.close);
      when(() => repository.lengthSettingsFailures).thenAnswer(
        (_) => failures.stream,
      );
      when(() => repository.setDefaultLengthPreset(any())).thenAnswer((call) {
        final bars = call.positionalArguments.single as int;
        if (bars > 3) {
          failures.add(EngineResult.invalid);
          return EngineResult.invalid;
        }
        confirmedLength = bars;
        return EngineResult.ok;
      });
      await pump(tester, initial: LoopSettingsPageId.length);
      await options.setDefaultLengthBars(3);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('loop_stepper_plus')));
      await tester.pumpAndSettle();
      expect(find.text('4'), findsOneWidget);
      expect(options.state.defaultLengthBars, 3);
      expect(await settings.loadDefaultLengthPreset(), 3);
      expect(
        find.text(l10nOf(tester).loopLengthNotApplied('3 bars')),
        findsOneWidget,
      );
      expect(
        tester
            .widget<LoopChoiceButton>(
              find.byKey(const Key('loop_length_bars')),
            )
            .selected,
        isTrue,
      );
    });

    testWidgets('late refusal keeps the count and Back discards it', (
      tester,
    ) async {
      final failures = StreamController<EngineResult>.broadcast();
      addTearDown(failures.close);
      when(() => repository.lengthSettingsFailures).thenAnswer(
        (_) => failures.stream,
      );
      when(() => repository.setDefaultLengthPreset(any())).thenReturn(
        EngineResult.invalid,
      );
      await pump(tester, initial: LoopSettingsPageId.length);

      await tester.tap(find.byKey(const Key('loop_length_bars')));
      await tester.pump();
      expect(find.byKey(const Key('loop_stepper_value')), findsOneWidget);
      failures.add(EngineResult.invalid);
      await tester.pumpAndSettle();
      expect(
        find.text(l10nOf(tester).loopLengthNotApplied('Auto')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('loop_settings_back')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('loop_hub_length')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('loop_stepper_value')), findsNothing);
      expect(options.state.defaultLengthBars, 0);
    });

    testWidgets('a keyboard draft over a refused count cancels and commits', (
      tester,
    ) async {
      final failures = StreamController<EngineResult>.broadcast();
      addTearDown(failures.close);
      when(() => repository.lengthSettingsFailures).thenAnswer(
        (_) => failures.stream,
      );
      when(() => repository.setDefaultLengthPreset(any())).thenAnswer((call) {
        final bars = call.positionalArguments.single as int;
        if (bars > 3) {
          failures.add(EngineResult.invalid);
          return EngineResult.invalid;
        }
        confirmedLength = bars;
        return EngineResult.ok;
      });
      await pump(tester, initial: LoopSettingsPageId.length);
      await tester.tap(find.byKey(const Key('loop_length_bars')));
      await tester.pumpAndSettle();
      final count = find.byKey(const Key('loop_stepper_value'));
      Focus.of(tester.element(count)).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(tester.widget<AppText>(count).data, '3');
      await tester.tap(find.byKey(const Key('loop_settings_back')));
      await tester.pumpAndSettle();
      expect(tester.widget<AppText>(count).data, '4');
      expect(options.state.defaultLengthBars, 0);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(options.state.defaultLengthBars, 3);
      expect(tester.widget<AppText>(count).data, '3');
    });

    testWidgets('switching scope and starting capture discard a candidate', (
      tester,
    ) async {
      final failures = StreamController<EngineResult>.broadcast();
      addTearDown(failures.close);
      when(() => repository.lengthSettingsFailures).thenAnswer(
        (_) => failures.stream,
      );
      when(() => repository.setDefaultLengthPreset(any())).thenAnswer((_) {
        failures.add(EngineResult.invalid);
        return EngineResult.invalid;
      });
      await pump(tester, initial: LoopSettingsPageId.length);
      await tester.tap(find.byKey(const Key('loop_length_bars')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('loop_scope_track_1')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('loop_stepper_value')), findsNothing);
      await tester.tap(find.byKey(const Key('loop_scope_defaults')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('loop_stepper_value')), findsNothing);

      await tester.tap(find.byKey(const Key('loop_length_bars')));
      await tester.pumpAndSettle();
      states.add(
        const LooperState(
          tracks: [Track(state: TrackState.recording)],
          transport: TransportState(looperMode: LooperMode.song),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('loop_stepper_value')), findsNothing);
      expect(find.byKey(const Key('loop_lock_banner')), findsOneWidget);
    });

    testWidgets('a replacement session discards the previous candidate', (
      tester,
    ) async {
      final failures = StreamController<EngineResult>.broadcast();
      addTearDown(failures.close);
      when(() => repository.lengthSettingsFailures).thenAnswer(
        (_) => failures.stream,
      );
      when(() => repository.setDefaultLengthPreset(any())).thenAnswer((_) {
        failures.add(EngineResult.invalid);
        return EngineResult.invalid;
      });
      await pump(tester, initial: LoopSettingsPageId.length);
      await tester.tap(find.byKey(const Key('loop_length_bars')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('loop_stepper_value')), findsOneWidget);

      sessionRevision++;
      rigReplaced.add(null);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('loop_stepper_value')), findsNothing);
      expect(options.state.defaultLengthBars, 0);
    });

    testWidgets('capture and same-value session replacement cancel bar edits', (
      tester,
    ) async {
      const positive = LooperState(
        tracks: [Track()],
        transport: TransportState(
          looperMode: LooperMode.song,
          defaultLengthPresetBars: 3,
        ),
      );
      await pump(tester, initial: LoopSettingsPageId.length);
      await options.setDefaultLengthBars(3);
      await tester.pumpAndSettle();
      final count = find.byKey(const Key('loop_stepper_value'));
      Focus.of(tester.element(count)).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(tester.widget<AppText>(count).data, '4');

      states.add(
        const LooperState(
          tracks: [Track(state: TrackState.recording)],
          transport: TransportState(
            looperMode: LooperMode.song,
            defaultLengthPresetBars: 3,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.widget<AppText>(count).data, '3');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      verifyNever(() => repository.setDefaultLengthPreset(4));

      states.add(positive);
      await tester.pumpAndSettle();
      Focus.of(tester.element(count)).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(tester.widget<AppText>(count).data, '4');

      sessionRevision++;
      rigReplaced.add(null);
      await tester.pumpAndSettle();
      expect(tester.widget<AppText>(count).data, '3');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      verifyNever(() => repository.setDefaultLengthPreset(4));
      expect(options.state.defaultLengthBars, 3);
    });

    testWidgets('Auto remembers Bars separately for defaults and tracks', (
      tester,
    ) async {
      const song = LooperState(
        tracks: [
          Track(),
          Track(channel: 1, lengthPresetOverride: 4),
          Track(channel: 2, lengthPresetOverride: 6),
        ],
        transport: TransportState(looperMode: LooperMode.song),
      );
      await pump(tester, state: song, initial: LoopSettingsPageId.length);
      await options.setDefaultLengthBars(8);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('loop_length_auto')));
      await tester.pumpAndSettle();
      expect(options.state.defaultLengthBars, 0);

      await tester.tap(find.byKey(const Key('loop_scope_track_1')));
      await tester.pumpAndSettle();
      expect(find.text('4'), findsOneWidget);
      await tester.tap(find.byKey(const Key('loop_length_auto')));
      states.add(
        const LooperState(
          tracks: [
            Track(),
            Track(channel: 1, lengthPresetOverride: 0),
            Track(channel: 2, lengthPresetOverride: 6),
          ],
          transport: TransportState(looperMode: LooperMode.song),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('loop_scope_track_2')));
      await tester.pumpAndSettle();
      expect(find.text('6'), findsOneWidget);

      await tester.tap(find.byKey(const Key('loop_scope_defaults')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('loop_length_bars')));
      await tester.pumpAndSettle();
      expect(options.state.defaultLengthBars, 8);

      await tester.tap(find.byKey(const Key('loop_scope_track_1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('loop_length_bars')));
      await tester.pumpAndSettle();
      expect(options.state.trackLengthPresetOverrides[1], 4);
      expect(await settings.loadTrackLengthPreset(1), 4);
      await tester.tap(find.byKey(const Key('loop_scope_track_2')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('loop_length_auto')));
      states.add(
        const LooperState(
          tracks: [
            Track(),
            Track(channel: 1, lengthPresetOverride: 0),
            Track(channel: 2, lengthPresetOverride: 0),
          ],
          transport: TransportState(looperMode: LooperMode.song),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('loop_length_bars')));
      await tester.pumpAndSettle();
      expect(options.state.trackLengthPresetOverrides[2], 6);
      expect(await settings.loadTrackLengthPreset(2), 6);
    });

    testWidgets('bar draft cancels on Back and commits on Enter', (
      tester,
    ) async {
      await pump(tester, initial: LoopSettingsPageId.length);
      await options.setDefaultLengthBars(4);
      await tester.pumpAndSettle();
      final count = find.byKey(const Key('loop_stepper_value'));
      Focus.of(tester.element(count)).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(find.text('5'), findsOneWidget);
      expect(options.state.defaultLengthBars, 4);

      await tester.tap(find.byKey(const Key('loop_settings_back')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('loop_settings_page_length')),
        findsOneWidget,
      );
      expect(find.text('4'), findsOneWidget);
      expect(options.state.defaultLengthBars, 4);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(options.state.defaultLengthBars, 5);
    });

    testWidgets('defaults write the cubits; a track writes overrides', (
      tester,
    ) async {
      await pump(tester, initial: LoopSettingsPageId.length);
      await tester.tap(find.byKey(const Key('loop_timing_quarter')));
      await tester.pumpAndSettle();
      expect(timing.state.defaultTiming, RecordTiming.quarter);
      expect(timing.state.recordTimingReady, isTrue);
      await tester.tap(find.byKey(const Key('loop_length_bars')));
      await tester.pumpAndSettle();
      expect(options.state.defaultLengthBars, 4);

      await tester.tap(find.byKey(const Key('loop_scope_track_1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('loop_timing_bar')));
      await tester.pumpAndSettle();
      verify(
        () => bloc.add(
          const LooperTrackRecordTimingChanged(1, timing: RecordTiming.bar),
        ),
      ).called(1);
      await tester.tap(find.byKey(const Key('loop_length_auto')));
      await tester.pumpAndSettle();
      expect(options.state.trackLengthPresetOverrides[1], 0);
      expect(await settings.loadTrackLengthPreset(1), 0);
    });

    testWidgets('the stepper moves a fixed default length', (tester) async {
      await pump(tester, initial: LoopSettingsPageId.length);
      await options.setDefaultLengthBars(4);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('loop_stepper_value')), findsOneWidget);
      await tester.tap(find.byKey(const Key('loop_stepper_plus')));
      await tester.pumpAndSettle();
      expect(options.state.defaultLengthBars, 5);
      await tester.tap(find.byKey(const Key('loop_stepper_minus')));
      await tester.pumpAndSettle();
      expect(options.state.defaultLengthBars, 4);
    });

    testWidgets('a custom field shows its tag and Use default clears it', (
      tester,
    ) async {
      const state = LooperState(
        tracks: [
          Track(state: TrackState.playing, lengthFrames: 96000),
          Track(
            channel: 1,
            state: TrackState.playing,
            lengthFrames: 96000,
            lengthPresetOverride: 8,
            recordTimingOverride: RecordTiming.half,
          ),
        ],
        transport: TransportState(looperMode: LooperMode.song),
      );
      await pump(tester, state: state, initial: LoopSettingsPageId.length);
      final l10n = l10nOf(tester);
      await tester.tap(find.byKey(const Key('loop_scope_track_1')));
      await tester.pumpAndSettle();
      expect(find.text(l10n.loopOriginCustom), findsNWidgets(2));
      expect(find.byKey(const Key('loop_stepper_value')), findsOneWidget);
      await tester.tap(find.byKey(const Key('loop_length_use_default')));
      await tester.pumpAndSettle();
      expect(options.state.trackLengthPresetOverrides.containsKey(1), isFalse);
      expect(await settings.loadTrackLengthPreset(1), isNull);
      await tester.tap(find.byKey(const Key('loop_timing_use_default')));
      await tester.pumpAndSettle();
      verify(
        () => bloc.add(
          const LooperTrackRecordTimingChanged(1, timing: null),
        ),
      ).called(1);
    });

    testWidgets('in Multi a track shares the default length', (
      tester,
    ) async {
      const state = LooperState(
        tracks: [Track(state: TrackState.playing, lengthFrames: 96000)],
      );
      await pump(tester, state: state, initial: LoopSettingsPageId.length);
      await options.setDefaultLengthBars(4);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('loop_scope_track_0')));
      await tester.pumpAndSettle();
      expect(find.text(l10nOf(tester).loopSharedInMulti), findsOneWidget);
      expect(find.byKey(const Key('loop_length_use_default')), findsNothing);
      await tester.tap(find.byKey(const Key('loop_length_auto')));
      await tester.pumpAndSettle();
      verifyNever(
        () => bloc.add(any(that: isA<LooperTrackLengthPresetChanged>())),
      );
    });

    testWidgets('a capture locks the page', (tester) async {
      await pump(
        tester,
        state: const LooperState(
          tracks: [Track(state: TrackState.recording, lengthFrames: 10)],
        ),
        initial: LoopSettingsPageId.length,
      );
      expect(find.byKey(const Key('loop_lock_banner')), findsOneWidget);
      await tester.tap(find.byKey(const Key('loop_timing_quarter')));
      await tester.pumpAndSettle();
      expect(timing.state.defaultTiming, RecordTiming.immediately);
    });
  });

  group('Playback & overdub', () {
    testWidgets('matching explicit overrides remain Custom per field', (
      tester,
    ) async {
      await pump(
        tester,
        state: const LooperState(
          tracks: [
            Track(),
            Track(channel: 1, oneShotOverride: false, overdubDecayOverride: 0),
          ],
        ),
        initial: LoopSettingsPageId.playback,
      );
      await tester.tap(find.byKey(const Key('loop_scope_track_1')));
      await tester.pumpAndSettle();
      expect(find.text(l10nOf(tester).loopOriginCustom), findsNWidgets(2));
      await tester.tap(find.byKey(const Key('loop_decay_use_default')));
      await tester.pumpAndSettle();
      verify(
        () => bloc.add(const LooperTrackOverdubDecayChanged(1, percent: null)),
      ).called(1);
    });

    testWidgets('decay draft cancels on Back and double tap resets', (
      tester,
    ) async {
      await pump(tester, initial: LoopSettingsPageId.playback);
      final slider = find.byKey(const Key('loop_decay_slider'));
      final gesture = find.descendant(
        of: slider,
        matching: find.byType(GestureDetector),
      );
      Focus.of(tester.element(gesture.first)).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(playback.state.overdubDecay, 0);
      expect(find.text(l10nOf(tester).loopDecayPercent(1)), findsOneWidget);

      await tester.tap(find.byKey(const Key('loop_settings_back')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('loop_settings_page_playback')),
        findsOneWidget,
      );
      expect(playback.state.overdubDecay, 0);

      await playback.setOverdubDecay(40);
      await tester.pumpAndSettle();
      final box = tester.getRect(slider);
      final at = Offset(box.left + box.width / 2, box.center.dy);
      await tester.tapAt(at);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tapAt(at);
      await tester.pumpAndSettle();
      expect(playback.state.overdubDecay, 0);
    });

    testWidgets('changing track discards an unfinished decay edit', (
      tester,
    ) async {
      await pump(tester, initial: LoopSettingsPageId.playback);
      final slider = find.byKey(const Key('loop_decay_slider'));
      final gesture = find.descendant(
        of: slider,
        matching: find.byType(GestureDetector),
      );
      Focus.of(tester.element(gesture.first)).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      await tester.tap(find.byKey(const Key('loop_scope_track_1')));
      await tester.pumpAndSettle();
      expect(playback.state.overdubDecay, 0);
      verifyNever(
        () => bloc.add(any(that: isA<LooperTrackOverdubDecayChanged>())),
      );
    });

    testWidgets('capture transition discards an unfinished decay edit', (
      tester,
    ) async {
      await pump(tester, initial: LoopSettingsPageId.playback);
      final slider = find.byKey(const Key('loop_decay_slider'));
      final gesture = find.descendant(
        of: slider,
        matching: find.byType(GestureDetector),
      );
      Focus.of(tester.element(gesture.first)).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      states.add(
        const LooperState(tracks: [Track(state: TrackState.recording)]),
      );
      await tester.pumpAndSettle();
      expect(playback.state.overdubDecay, 0);
      expect(find.text(l10nOf(tester).loopDecayOff), findsOneWidget);
    });

    testWidgets('defaults write the playback options; a track writes '
        'overrides', (tester) async {
      await pump(tester, initial: LoopSettingsPageId.playback);
      final l10n = l10nOf(tester);
      expect(find.text(l10n.loopDecayOff), findsOneWidget);
      await tester.tap(find.byKey(const Key('loop_playback_once')));
      await tester.pumpAndSettle();
      expect(playback.state.defaultOneShot, isTrue);
      expect(find.text(l10n.loopPlaybackNoteOnce), findsOneWidget);

      await tester.tap(find.byKey(const Key('loop_scope_track_2')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('loop_playback_loop')));
      await tester.pumpAndSettle();
      verify(
        () => bloc.add(const LooperOneShotToggled(2, oneShot: false)),
      ).called(1);
    });

    testWidgets('the decay slider writes a percent', (tester) async {
      await pump(tester, initial: LoopSettingsPageId.playback);
      final slider = find.byKey(const Key('loop_decay_slider'));
      final box = tester.getRect(slider);
      await tester.tapAt(Offset(box.left + box.width / 2, box.center.dy));
      await tester.pump(const Duration(milliseconds: 400));
      expect(playback.state.overdubDecay, 50);
      expect(
        find.text(l10nOf(tester).loopDecayNote(50)),
        findsOneWidget,
      );
    });
  });

  group('Audio & tempo', () {
    testWidgets('reads out the recorded-speed state and takes no taps', (
      tester,
    ) async {
      await pump(tester, initial: LoopSettingsPageId.audioTempo);
      final l10n = l10nOf(tester);
      expect(find.text(l10n.loopAudioUnavailable), findsOneWidget);
      expect(find.text(l10n.loopAudioNoteOff), findsOneWidget);
      await tester.tap(find.byKey(const Key('loop_audio_follow_on')));
      await tester.pumpAndSettle();
      expect(find.text(l10n.loopAudioNoteOff), findsOneWidget);
    });
  });
}
