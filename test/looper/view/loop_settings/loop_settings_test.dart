import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/looper.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_hub.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_page.dart';
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
  late _MockLooperBloc bloc;
  late _MockLooperRepository repository;
  late SettingsRepository settings;
  late StreamController<LooperState> states;

  setUpAll(() {
    registerFallbackValue(const LooperRecordPressed(0));
    registerFallbackValue(LooperMode.multi);
    registerFallbackValue(RecordTiming.immediately);
    registerFallbackValue(ClickMode.off);
  });

  setUp(() {
    bloc = _MockLooperBloc();
    repository = _MockLooperRepository();
    settings = SettingsRepository(store: FakeKeyValueStore());
    states = StreamController<LooperState>.broadcast();
    when(() => repository.looperModeGate(any())).thenReturn(
      LooperModeGate.open,
    );
    when(() => repository.looperState).thenAnswer((_) => states.stream);
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
        () => repository.setClickMode(any()),
      ).thenReturn(EngineResult.ok),
      () => when(
        () => repository.setClickOutput(any()),
      ).thenReturn(EngineResult.ok),
      () => when(
        () => repository.setClickVolume(any()),
      ).thenReturn(EngineResult.ok),
      () =>
          when(() => repository.setCountIn(any())).thenReturn(EngineResult.ok),
      () => when(
        () => repository.setRecDub(enabled: any(named: 'enabled')),
      ).thenReturn(EngineResult.ok),
      () => when(
        () => repository.setAutoRecord(enabled: any(named: 'enabled')),
      ).thenReturn(EngineResult.ok),
      () => when(
        () => repository.setDefaultMultiple(multiple: any(named: 'multiple')),
      ).thenReturn(EngineResult.ok),
      () => when(
        () => repository.setDefaultLengthPreset(any()),
      ).thenReturn(EngineResult.ok),
      () => when(
        () => repository.setRecordTiming(any()),
      ).thenReturn(EngineResult.ok),
      () => when(
        () => repository.setOverdubDecay(any()),
      ).thenReturn(EngineResult.ok),
      () => when(
        () => repository.setDefaultOnce(once: any(named: 'once')),
      ).thenReturn(EngineResult.ok),
    ]) {
      stub();
    }
  });

  tearDown(() => states.close());

  void seed(LooperState state) {
    when(() => bloc.state).thenReturn(state);
    whenListen(bloc, states.stream, initialState: state);
  }

  late TempoCubit tempo;
  late RecordOptionsCubit options;
  late PlaybackOptionsCubit playback;
  late RecordTimingCubit timing;
  late TracksCubit tracks;

  Future<void> pump(
    WidgetTester tester, {
    LooperState state = _rig,
    LoopSettingsPageId initial = LoopSettingsPageId.hub,
  }) async {
    tester.view
      ..physicalSize = const Size(1920, 1080)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    seed(state);
    tempo = TempoCubit(repository: repository, settings: settings);
    options = RecordOptionsCubit(repository: repository, settings: settings);
    playback = PlaybackOptionsCubit(repository: repository, settings: settings);
    timing = RecordTimingCubit(repository: repository, settings: settings);
    tracks = TracksCubit(settings: settings);
    for (final cubit in <BlocBase<Object?>>[
      tempo,
      options,
      playback,
      timing,
      tracks,
    ]) {
      addTearDown(() => unawaited(cubit.close()));
    }
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: ThemeData(extensions: const [SurfaceTheme.dark]),
        home: RepositoryProvider<LooperRepository>.value(
          value: repository,
          child: MultiBlocProvider(
            providers: [
              BlocProvider<LooperBloc>.value(value: bloc),
              BlocProvider.value(value: tempo),
              BlocProvider.value(value: options),
              BlocProvider.value(value: playback),
              BlocProvider.value(value: timing),
              BlocProvider.value(value: tracks),
            ],
            child: LoopSettingsPage(initial: initial),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  AppLocalizations l10nOf(WidgetTester tester) =>
      AppLocalizations.of(tester.element(find.byType(LoopSettingsPage)));

  group('hub', () {
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
    testWidgets('the choices write the record options and the note follows', (
      tester,
    ) async {
      await pump(tester, initial: LoopSettingsPageId.recording);
      final l10n = l10nOf(tester);
      expect(find.text(l10n.loopRecordingNotePedal), findsOneWidget);
      await tester.tap(find.byKey(const Key('loop_recording_sound')));
      await tester.pumpAndSettle();
      expect(options.state.autoRecord, isTrue);
      expect(find.text(l10n.loopRecordingNoteSound), findsOneWidget);
      await tester.tap(find.byKey(const Key('loop_recording_overdub')));
      await tester.pumpAndSettle();
      expect(options.state.recDub, isTrue);
    });

    testWidgets('a count-in names itself in the note', (tester) async {
      await settings.saveCountInBars(2);
      await pump(tester, initial: LoopSettingsPageId.recording);
      await tempo.load();
      await tester.pumpAndSettle();
      expect(
        find.text(l10nOf(tester).loopRecordingNoteCountIn(2)),
        findsOneWidget,
      );
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
      expect(options.state.autoRecord, isFalse);
    });
  });

  group('Tempo & click', () {
    testWidgets('click, count-in and tap reach the tempo cubit', (
      tester,
    ) async {
      await pump(tester, initial: LoopSettingsPageId.tempo);
      expect(find.byKey(const Key('loop_tempo_readout')), findsOneWidget);
      await tester.tap(find.byKey(const Key('loop_click_playRec')));
      await tester.pumpAndSettle();
      expect(tempo.state.clickMode, ClickMode.playRec);
      await tester.tap(find.byKey(const Key('loop_count_in_2')));
      await tester.pumpAndSettle();
      expect(tempo.state.countInBars, 2);
      await tester.tap(find.byKey(const Key('loop_tempo_tap')));
      verify(repository.tapTempo).called(1);
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
    testWidgets('defaults write the cubits; a track writes overrides', (
      tester,
    ) async {
      await pump(tester, initial: LoopSettingsPageId.length);
      await tester.tap(find.byKey(const Key('loop_timing_quarter')));
      await tester.pumpAndSettle();
      expect(timing.state, RecordTiming.quarter);
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
      verify(
        () => bloc.add(const LooperTrackLengthPresetChanged(1, 0)),
      ).called(1);
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
      verify(
        () => bloc.add(const LooperTrackLengthPresetChanged(1, null)),
      ).called(1);
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
      expect(timing.state, RecordTiming.immediately);
    });
  });

  group('Playback & overdub', () {
    testWidgets('defaults write the playback options; a track writes '
        'overrides', (tester) async {
      await pump(tester, initial: LoopSettingsPageId.playback);
      final l10n = l10nOf(tester);
      expect(find.text(l10n.loopDecayOff), findsOneWidget);
      await tester.tap(find.byKey(const Key('loop_playback_once')));
      await tester.pumpAndSettle();
      expect(playback.state.once, isTrue);
      expect(find.text(l10n.loopPlaybackNoteOnce), findsOneWidget);

      await tester.tap(find.byKey(const Key('loop_scope_track_2')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('loop_playback_loop')));
      await tester.pumpAndSettle();
      verify(
        () => bloc.add(const LooperTrackOnceChanged(2, once: false)),
      ).called(1);
    });

    testWidgets('the decay slider writes a percent', (tester) async {
      await pump(tester, initial: LoopSettingsPageId.playback);
      final slider = find.byKey(const Key('loop_decay_slider'));
      final box = tester.getRect(slider);
      await tester.tapAt(Offset(box.left + box.width / 2, box.center.dy));
      await tester.pumpAndSettle();
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
