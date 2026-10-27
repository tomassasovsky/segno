import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:operation_guards/operation_guards.dart';
import 'package:routing_graph/routing_graph.dart';
import 'package:segno/audio_setup/cubit/audio_setup_cubit.dart';
import 'package:segno/audio_setup/cubit/inputs_cubit.dart';
import 'package:segno/audio_setup/view/device_page.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/application/record_settings.dart';
import 'package:segno/looper/application/record_timing_settings.dart';
import 'package:segno/looper/application/tempo_settings.dart';
import 'package:segno/looper/looper.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/theme/theme.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

class _MockLooperBloc extends MockBloc<LooperEvent, LooperState>
    implements LooperBloc {}

class _MockLooperRepository extends Mock implements LooperRepository {}

/// The host's own list: a Scarlett reported in both directions with its real
/// channel counts, the built-in pair, and a playback-only device.
const _devices = <AudioDevice>[
  AudioDevice(
    id: 'scarlett-out',
    name: 'Scarlett 18i20',
    isDefault: false,
    isInput: false,
    outputChannels: 20,
  ),
  AudioDevice(
    id: 'scarlett-in',
    name: 'Scarlett 18i20',
    isDefault: false,
    isInput: true,
    inputChannels: 18,
  ),
  AudioDevice(
    id: 'builtin-out',
    name: 'Built-in audio',
    isDefault: true,
    isInput: false,
    outputChannels: 2,
  ),
  AudioDevice(
    id: 'builtin-in',
    name: 'Built-in audio',
    isDefault: true,
    isInput: true,
    inputChannels: 2,
  ),
  // No capture half at all, and no count either — the two ways a device can
  // fail to answer, in one row.
  AudioDevice(
    id: 'hdmi-out',
    name: 'HDMI',
    isDefault: false,
    isInput: false,
  ),
];

const _open = EngineStatus(
  isConnected: true,
  deviceName: 'Scarlett 18i20',
  sampleRate: 48000,
  bufferFrames: 128,
  inputChannels: 18,
  outputChannels: 20,
  devicePresent: true,
  latencyState: LatencyState.done,
  measuredLatencyMs: 7.42,
  recordOffsetFrames: 64,
);

const _applied = AudioApplyResult(
  status: AudioApplyStatus.applied,
  result: EngineResult.ok,
);

void main() {
  late TempoSettings tempoOwner;
  late _MockLooperBloc bloc;
  late _MockLooperRepository repository;
  late SettingsRepository settings;
  late AudioSetupCubit audio;
  late InputsCubit inputs;
  late RecordTimingCubit quantize;
  late RecordSettings options;
  late TempoCubit tempo;
  late RecordTiming confirmedTiming;
  late GridDivision rememberedDivision;
  var confirmedCountIn = 1;
  var confirmedSoundStart = false;
  var startRecovering = false;
  var startCaptureLocked = false;

  /// The engine's own state stream, so a test can push a tick and watch the
  /// face react — the negotiation cases need it.
  late StreamController<LooperState> engine;

  setUpAll(() {
    registerFallbackValue(RecordTiming.immediately);
    registerFallbackValue(GridDivision.off);
    registerFallbackValue(<int, RecordTiming>{});
    registerFallbackValue(const EngineConfig());
    registerFallbackValue(const LooperRecordPressed(0));
    registerFallbackValue(RecordStartEditKind.restore);
  });

  setUp(() {
    confirmedCountIn = 1;
    confirmedSoundStart = false;
    startRecovering = false;
    startCaptureLocked = false;
    confirmedTiming = RecordTiming.immediately;
    rememberedDivision = GridDivision.off;
    bloc = _MockLooperBloc();
    repository = _MockLooperRepository();
    when(() => repository.clickModeFailures).thenAnswer(
      (_) => const Stream<EngineResult>.empty(),
    );
    when(() => repository.clickVolumeFailures).thenAnswer(
      (_) => const Stream<EngineResult>.empty(),
    );
    when(() => repository.clickModeCaptureLocked).thenReturn(false);
    when(() => repository.clickModeSettled).thenReturn(true);
    when(() => repository.recordStartSettingsFailures).thenAnswer(
      (_) => const Stream<EngineResult>.empty(),
    );
    when(() => repository.recordStartSettingsSettled).thenReturn(true);
    when(() => repository.recordStartRecoveryRequired).thenAnswer(
      (_) => startRecovering,
    );
    when(() => repository.recordStartCaptureLocked).thenAnswer(
      (_) => startCaptureLocked,
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
    engine = StreamController<LooperState>.broadcast();
    addTearDown(engine.close);
    when(() => repository.looperState).thenAnswer((_) => engine.stream);
    when(() => repository.lengthSettingsFailures).thenAnswer(
      (_) => const Stream<EngineResult>.empty(),
    );
    when(() => repository.state).thenReturn(const LooperState(status: _open));
    when(() => repository.sessionRevision).thenReturn(0);
    when(() => repository.mixGeneration).thenReturn(0);
    when(() => repository.recordLengthCaptureLocked).thenReturn(false);
    when(() => repository.clickVolumeSettled).thenReturn(true);
    when(() => repository.clickVolumeRecoveryRequired).thenReturn(false);
    when(() => repository.sessionTransport).thenAnswer(
      (_) => TransportState(
        recordTiming: confirmedTiming,
        quantizeDiv: rememberedDivision,
        countInBars: confirmedCountIn,
        autoRecord: confirmedSoundStart,
      ),
    );
    when(() => repository.lastEngineConfig).thenReturn(
      const EngineConfig(
        sampleRate: 48000,
        bufferFrames: 128,
        playbackDeviceId: 'scarlett-out',
        captureDeviceId: 'scarlett-in',
      ),
    );
    when(() => repository.applyAudioConfig(any())).thenReturn(_applied);
    when(() => repository.fxRoomAt(any(), any())).thenReturn(1 << 30);
    when(() => repository.setRecordOffset(any())).thenReturn(EngineResult.ok);
    when(repository.detectLoopback).thenReturn(const LoopbackInfo.none());
    when(repository.devices).thenReturn(_devices);
    when(() => repository.recordTimingFailures).thenAnswer(
      (_) => const Stream<EngineResult>.empty(),
    );
    when(() => repository.recordTimingSettingsSettled).thenReturn(true);
    when(() => repository.recordTimingRecoveryRequired).thenReturn(false);
    when(() => repository.recordTimingCaptureLocked).thenReturn(false);
    when(
      () => repository.defaultRecordTiming,
    ).thenAnswer((_) => confirmedTiming);
    when(() => repository.trackRecordTimingOverrides).thenReturn(const {});
    when(() => repository.recordTimingRestartIntent).thenAnswer(
      (_) => (
        defaultTiming: confirmedTiming,
        rememberedDivision: rememberedDivision,
        trackOverrides: const <int, RecordTiming>{},
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
        released: any(named: 'released'),
        editMask: any(named: 'editMask'),
      ),
    ).thenAnswer((call) {
      confirmedTiming = call.namedArguments[#defaultTiming] as RecordTiming;
      rememberedDivision =
          call.namedArguments[#rememberedDivision] as GridDivision;
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
      () => repository.setRecDub(enabled: any(named: 'enabled')),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.setDefaultMultiple(multiple: any(named: 'multiple')),
    ).thenReturn(EngineResult.ok);
    when(() => repository.setClickOutput(any())).thenReturn(EngineResult.ok);
    when(() => repository.setClickVolume(any())).thenReturn(EngineResult.ok);
  });

  AppLocalizations l10nOf(WidgetTester tester) =>
      AppLocalizations.of(tester.element(find.byType(DevicePage)));

  /// Mounts the Device page with the providers the app gives it.
  ///
  /// 1920x1080, deliberately: this face is drawn for that surface, and the
  /// default 800x600 test view pushes the lower rows below the fold where a
  /// tap lands on nothing.
  Future<void> pump(
    WidgetTester tester, {
    LooperState looper = const LooperState(status: _open),
    bool loadRecordStart = true,
  }) async {
    tester.view
      ..physicalSize = const Size(1920, 1080)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    when(() => bloc.state).thenReturn(looper);
    whenListen(
      bloc,
      const Stream<LooperState>.empty(),
      initialState: looper,
    );

    settings = SettingsRepository(store: FakeKeyValueStore());
    audio = AudioSetupCubit(
      repository: repository,
      settings: settings,
      guards: GuardRegistry(),
      backing: testBackingRepository(),
      // No periodic re-enumeration: a timer live for the length of the test
      // body fails the binding's invariant check before any tearDown runs.
      deviceRefreshInterval: Duration.zero,
    );
    inputs = InputsCubit(settings: settings, repository: repository);
    final quantizeOwner = RecordTimingSettings(
      repository: repository,
      settings: settings,
    );
    addTearDown(() => unawaited(quantizeOwner.close()));
    quantize = RecordTimingCubit(settings: quantizeOwner);
    await quantizeOwner.load();
    options = RecordSettings(repository: repository, settings: settings);
    tempoOwner = TempoSettings(
      repository: repository,
      settings: settings,
    );
    final closeTempoOwner = tempoOwner.close;
    addTearDown(() => unawaited(closeTempoOwner()));
    tempo = TempoCubit(settings: tempoOwner);
    if (loadRecordStart) await tempoOwner.recordStartOwner.load();
    // unawaited: awaiting a cubit close inside a testWidgets body deadlocks on
    // the binding's stream cancellation (flutter/flutter#139870).
    addTearDown(() => unawaited(audio.close()));
    addTearDown(() => unawaited(inputs.close()));
    addTearDown(() => unawaited(quantize.close()));
    addTearDown(() => unawaited(options.close()));
    addTearDown(() => unawaited(tempo.close()));

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
              BlocProvider.value(value: audio),
              BlocProvider.value(value: inputs),
              BlocProvider.value(value: quantize),
              BlocProvider(
                create: (_) => RecordOptionsCubit(settings: options),
              ),
              BlocProvider.value(value: tempo),
            ],
            child: const DevicePage(),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  LoopChoiceButton chip(WidgetTester tester, Key key) =>
      tester.widget<LoopChoiceButton>(find.byKey(key));

  LoopOutlinedButton button(WidgetTester tester, Key key) =>
      tester.widget<LoopOutlinedButton>(find.byKey(key));

  // ------------------------------------------------------------- the header

  group('the interface', () {
    testWidgets('names the pinned interface, its counts and that it is there', (
      tester,
    ) async {
      await pump(tester);
      final l10n = l10nOf(tester);
      expect(find.text('Scarlett 18i20'), findsOneWidget);
      expect(find.text(l10n.deviceInputsOutputs(18, 20)), findsOneWidget);
      expect(find.text(l10n.deviceConnected), findsOneWidget);
    });

    testWidgets('Change interface lists the interfaces, and a pick is drafted, '
        'not applied', (tester) async {
      await pump(tester);
      await tester.tap(find.byKey(const Key('device_change_interface')));
      await tester.pumpAndSettle();
      final l10n = l10nOf(tester);
      // One row per box, its counts once for both directions; unknown counts
      // say nothing.
      expect(find.text(l10n.audioDeviceChannels(18, 20)), findsOneWidget);
      expect(find.text('HDMI'), findsOneWidget);
      await tester.tap(find.byKey(const Key('audio_device_option_1')));
      await tester.pumpAndSettle();

      expect(audio.state.draft?.playbackDeviceId, 'builtin-out');
      expect(audio.state.draft?.captureDeviceId, 'builtin-in');
      verifyNever(() => repository.applyAudioConfig(any()));
      expect(find.byKey(const Key('device_apply_row')), findsOneWidget);
    });

    testWidgets('a pinned interface the host has lost stays listed, greyed', (
      tester,
    ) async {
      when(repository.devices).thenReturn(const []);
      await pump(tester);
      await tester.tap(find.byKey(const Key('device_change_interface')));
      await tester.pumpAndSettle();
      expect(
        find.text(l10nOf(tester).audioDeviceUnplugged),
        findsOneWidget,
      );
    });

    testWidgets('every output off gets a banner, not silence', (tester) async {
      await pump(
        tester,
        looper: const LooperState(
          status: _open,
          outputEnabledMask: 0,
        ),
      );
      expect(find.byKey(const Key('audio_no_outputs_banner')), findsOneWidget);
    });
  });

  // -------------------------------------------------------------- the draft

  group('the draft (pen 28/01)', () {
    testWidgets('tapping 256 shows the Apply row and the period, calling '
        'nothing; Cancel restores 128', (tester) async {
      await pump(tester);
      final l10n = l10nOf(tester);
      expect(find.byKey(const Key('device_apply_row')), findsNothing);
      expect(find.text('2.67'), findsOneWidget);

      await tester.tap(find.byKey(const Key('device_buffer_256')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('device_apply_row')), findsOneWidget);
      expect(find.text(l10n.deviceApplyNote), findsOneWidget);
      expect(find.text('5.33'), findsOneWidget);
      expect(chip(tester, const Key('device_buffer_256')).selected, isTrue);
      verifyNever(() => repository.applyAudioConfig(any()));

      await tester.tap(find.byKey(const Key('device_apply_cancel')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('device_apply_row')), findsNothing);
      expect(chip(tester, const Key('device_buffer_128')).selected, isTrue);
    });

    testWidgets('rate and buffer drafted together apply in one call', (
      tester,
    ) async {
      await pump(tester);
      await tester.tap(find.byKey(const Key('device_rate_96000')));
      await tester.tap(find.byKey(const Key('device_buffer_256')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('device_apply')));
      await tester.pumpAndSettle();
      final asked =
          verify(
                () => repository.applyAudioConfig(captureAny()),
              ).captured.single
              as EngineConfig;
      expect(asked.sampleRate, 96000);
      expect(asked.bufferFrames, 256);
    });

    testWidgets('the loop cap is drafted and applied with the rest', (
      tester,
    ) async {
      await pump(tester);
      await tester.tap(find.byKey(const Key('audio_max_loop_row')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('audio_max_loop_5')));
      await tester.pumpAndSettle();
      verifyNever(() => repository.applyAudioConfig(any()));
      await tester.tap(find.byKey(const Key('device_apply')));
      await tester.pumpAndSettle();
      final asked =
          verify(
                () => repository.applyAudioConfig(captureAny()),
              ).captured.single
              as EngineConfig;
      expect(asked.maxLoopFrames, 5 * 60 * 48000);
    });

    testWidgets('leaving the page drops the draft', (tester) async {
      await pump(tester);
      await tester.tap(find.byKey(const Key('device_buffer_256')));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
      expect(audio.state.draft, isNull);
    });
  });

  // ----------------------------------------------------------- applying

  group('applying (#1270 Part 3a)', () {
    const playingRig = LooperState(
      status: _open,
      tracks: [Track(state: TrackState.playing, lengthFrames: 48000)],
    );
    const recordedRig = LooperState(
      status: _open,
      tracks: [Track(state: TrackState.stopped, lengthFrames: 48000)],
    );

    setUp(() {
      when(
        () => repository.stopTrack(channel: any(named: 'channel')),
      ).thenReturn(EngineResult.ok);
    });

    bool focused(Key key) {
      final context = FocusManager.instance.primaryFocus?.context;
      if (context == null) return false;
      return find
          .ancestor(
            of: find.byElementPredicate((e) => e == context),
            matching: find.byKey(key),
          )
          .evaluate()
          .isNotEmpty;
    }

    testWidgets('Apply while playing asks first, focus on the answer that '
        'changes nothing, then applies', (tester) async {
      when(() => repository.state).thenReturn(playingRig);
      await pump(tester, looper: playingRig);
      await tester.tap(find.byKey(const Key('device_buffer_256')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('device_apply')));
      await tester.pumpAndSettle();

      final l10n = l10nOf(tester);
      expect(find.text(l10n.audioApplyTitle), findsOneWidget);
      expect(focused(const Key('device_confirm_cancel')), isTrue);
      verifyNever(() => repository.applyAudioConfig(any()));

      await tester.tap(find.byKey(const Key('device_confirm_confirm')));
      await tester.pumpAndSettle();
      verify(() => repository.stopTrack()).called(1);
      verify(() => repository.applyAudioConfig(any())).called(1);
    });

    testWidgets('locked rate chips stay, disabled, and say why to a screen '
        'reader', (tester) async {
      when(() => repository.state).thenReturn(recordedRig);
      await pump(tester, looper: recordedRig);
      final l10n = l10nOf(tester);
      final handle = tester.ensureSemantics();
      expect(chip(tester, const Key('device_rate_96000')).enabled, isFalse);
      expect(find.text(l10n.audioRateLocked), findsOneWidget);
      final node = tester.getSemantics(
        find.byKey(const Key('device_rate_96000')),
      );
      expect(node.label.trim(), l10n.sampleRateKhzLabel(96000));
      expect(node.hint, l10n.audioRateLocked);
      handle.dispose();
      await tester.tap(find.byKey(const Key('device_rate_96000')));
      await tester.pumpAndSettle();
      expect(audio.state.draft, isNull);
    });

    testWidgets('a rate the effects do not fit is refused with the reason', (
      tester,
    ) async {
      when(() => repository.fxRoomAt(96000, any())).thenReturn(-1);
      await pump(tester);
      await tester.tap(find.byKey(const Key('device_rate_96000')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('device_apply')));
      await tester.pumpAndSettle();
      final l10n = l10nOf(tester);
      expect(
        find.text(
          l10n.audioEffectsOverBudgetRate(l10n.sampleRateKhzLabel(96000)),
        ),
        findsOneWidget,
      );
      verifyNever(() => repository.applyAudioConfig(any()));
    });

    testWidgets('a device that negotiates something else reports it', (
      tester,
    ) async {
      await pump(tester);
      await tester.tap(find.byKey(const Key('device_rate_96000')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('device_apply')));
      await tester.pumpAndSettle();
      expect(audio.state.phase, ConfigPhase.refused);
      expect(find.byKey(const Key('audio_refused_banner')), findsOneWidget);
    });

    testWidgets('a failed open says so', (tester) async {
      when(() => repository.applyAudioConfig(any())).thenReturn(
        const AudioApplyResult(
          status: AudioApplyStatus.failed,
          result: EngineResult.device,
        ),
      );
      await pump(tester);
      await tester.tap(find.byKey(const Key('device_buffer_256')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('device_apply')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('audio_open_failed_banner')), findsOneWidget);
    });
  });

  // -------------------------------------------------------- the round trip

  group('the round trip', () {
    testWidgets('shows the measured figure, the offset, and the health rows', (
      tester,
    ) async {
      const dropping = LooperState(
        status: EngineStatus(
          isConnected: true,
          deviceName: 'Scarlett 18i20',
          sampleRate: 48000,
          bufferFrames: 128,
          inputChannels: 18,
          outputChannels: 20,
          devicePresent: true,
          latencyState: LatencyState.done,
          measuredLatencyMs: 7.42,
          recordOffsetFrames: 64,
          xrunCount: 3,
        ),
      );
      when(() => repository.state).thenReturn(dropping);
      await pump(tester, looper: dropping);
      final l10n = l10nOf(tester);
      expect(find.text(l10n.latencyMs('7.42')), findsOneWidget);
      expect(find.text(l10n.audioRecordOffsetSub(64)), findsOneWidget);
      expect(find.text(l10n.deviceEngineRunning), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('device_dropouts')),
          matching: find.text('3'),
        ),
        findsOneWidget,
      );
    });

    testWidgets(
      'Measure is disabled with the reason while a draft is pending',
      (tester) async {
        await pump(tester);
        expect(button(tester, const Key('audio_measure')).onTap, isNotNull);
        await tester.tap(find.byKey(const Key('device_buffer_256')));
        await tester.pumpAndSettle();
        expect(button(tester, const Key('audio_measure')).onTap, isNull);
        expect(
          find.text(l10nOf(tester).deviceApplyBeforeMeasuring),
          findsOneWidget,
        );
      },
    );

    testWidgets('a stopped engine: not measured, Measure disabled, Stopped', (
      tester,
    ) async {
      when(() => repository.state).thenReturn(const LooperState());
      await pump(tester, looper: const LooperState());
      final l10n = l10nOf(tester);
      expect(find.text(l10n.notMeasured), findsOneWidget);
      expect(find.text(l10n.audioMeasureUnavailable), findsOneWidget);
      expect(find.text(l10n.deviceEngineStopped), findsOneWidget);
      expect(button(tester, const Key('audio_measure')).onTap, isNull);
    });

    group('the cable test (#1270 Part 3b)', () {
      late Completer<LatencyResult> result;

      setUp(() {
        when(
          () => repository.measureLatency(
            output: any(named: 'output'),
            input: any(named: 'input'),
          ),
          // Made inside the test's zone, where its pumps deliver it.
        ).thenAnswer((_) => (result = Completer<LatencyResult>()).future);
        when(repository.cancelLatency).thenReturn(null);
        when(
          () => repository.stopTrack(channel: any(named: 'channel')),
        ).thenReturn(EngineResult.ok);
      });

      Future<void> open(WidgetTester tester) async {
        await tester.tap(find.byKey(const Key('audio_measure')));
        await tester.pumpAndSettle();
      }

      bool focused(Key key) {
        final context = FocusManager.instance.primaryFocus?.context;
        if (context == null) return false;
        return find
            .ancestor(
              of: find.byElementPredicate((e) => e == context),
              matching: find.byKey(key),
            )
            .evaluate()
            .isNotEmpty;
      }

      testWidgets('the encoder alone: output, input, Start test, Cancel', (
        tester,
      ) async {
        await pump(tester);
        await open(tester);
        expect(find.byKey(const Key('cable_test_dialog')), findsOneWidget);
        expect(focused(const Key('cable_test_output')), isTrue);
        for (final key in const [
          Key('cable_test_input'),
          Key('cable_test_start'),
          Key('cable_test_cancel'),
        ]) {
          FocusManager.instance.primaryFocus!.nextFocus();
          await tester.pump();
          expect(focused(key), isTrue, reason: '$key');
        }
      });

      testWidgets('a press steps the jack; Start test measures it, and DONE '
          'closes the dialog', (tester) async {
        await pump(tester);
        await open(tester);
        for (final jack in const [
          Key('cable_test_output'),
          Key('cable_test_output'),
          Key('cable_test_input'),
        ]) {
          await tester.tap(find.byKey(jack));
          await tester.pump();
        }
        await tester.tap(find.byKey(const Key('cable_test_start')));
        await tester.pump();

        verify(() => repository.measureLatency(output: 2, input: 1)).called(1);
        expect(find.byKey(const Key('cable_test_measuring')), findsOneWidget);
        result.complete(
          const LatencyResult.done(offsetFrames: 240, latencyMs: 5),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('cable_test_dialog')), findsNothing);
      });

      testWidgets('a route pushed over the dialog survives its closing', (
        tester,
      ) async {
        await pump(tester);
        await open(tester);
        await tester.tap(find.byKey(const Key('cable_test_start')));
        await tester.pump();
        unawaited(
          showDialog<void>(
            context: tester.element(find.byKey(const Key('cable_test_dialog'))),
            builder: (_) => const Text('power', key: Key('over_the_dialog')),
          ),
        );
        await tester.pumpAndSettle();
        result.complete(
          const LatencyResult.done(offsetFrames: 240, latencyMs: 5),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('cable_test_dialog')), findsNothing);
        expect(find.byKey(const Key('over_the_dialog')), findsOneWidget);
      });

      testWidgets('the note says playback stops while it plays', (
        tester,
      ) async {
        const playingRig = LooperState(
          status: _open,
          tracks: [Track(state: TrackState.playing, lengthFrames: 48000)],
        );
        when(() => repository.state).thenReturn(playingRig);
        await pump(tester, looper: playingRig);
        await open(tester);
        expect(find.text(l10nOf(tester).audioCableNoteStops), findsOneWidget);
      });

      testWidgets('no return keeps the dialog open with Retry', (tester) async {
        await pump(tester);
        await open(tester);
        await tester.tap(find.byKey(const Key('cable_test_start')));
        await tester.pump();
        result.complete(const LatencyResult(LatencyOutcome.noReturn));
        await tester.pumpAndSettle();
        final l10n = l10nOf(tester);
        expect(find.byKey(const Key('cable_test_dialog')), findsOneWidget);
        expect(find.text(l10n.audioCableNoReturn), findsOneWidget);
        expect(find.text(l10n.audioCableRetry), findsOneWidget);
      });

      testWidgets('leaving the page cancels a run', (tester) async {
        await pump(tester);
        await open(tester);
        await tester.tap(find.byKey(const Key('cable_test_start')));
        await tester.pump();
        await tester.pumpWidget(const SizedBox.shrink());
        verify(repository.cancelLatency).called(1);
        result.complete(const LatencyResult(LatencyOutcome.cancelled));
      });
    });
  });
}
