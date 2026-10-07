import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:operation_guards/operation_guards.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:pedal_repository/testing.dart';
import 'package:performance_repository/performance_repository.dart';
import 'package:segno/app/application/owned_value_port.dart';
import 'package:segno/app/fx_chain_persistence.dart';
import 'package:segno/control/binding/pedal_palette.dart';
import 'package:segno/control/control.dart';
import 'package:segno/control/model/foot_fx.dart';
import 'package:segno/looper/model/interaction_mode.dart';
import 'package:settings_repository/settings_repository.dart';

import '../helpers/helpers.dart';

class _MockLooperRepository extends Mock implements LooperRepository {}

class _PedalSetupStore extends FakeKeyValueStore {
  bool refuseSetup = false;
  bool failAfterSetupWrite = false;
  String? refuseSetupValue;
  Completer<void>? setupReadGate;
  Completer<void>? setupReadSampled;

  @override
  Future<String?> getString(String key) async {
    final value = await super.getString(key);
    if (key == 'pedal.setup' && setupReadGate != null) {
      final sampled = setupReadSampled;
      if (sampled != null && !sampled.isCompleted) sampled.complete();
      await setupReadGate!.future;
    }
    return value;
  }

  @override
  Future<void> setString(String key, String value) async {
    if (refuseSetup && key == 'pedal.setup') {
      throw Exception('pedal setup storage refused');
    }
    if (key == 'pedal.setup' && value == refuseSetupValue) {
      throw StateError('pedal setup checkpoint restoration refused');
    }
    await super.setString(key, value);
    if (failAfterSetupWrite && key == 'pedal.setup') {
      failAfterSetupWrite = false;
      throw StateError('pedal setup write failed after storage');
    }
  }
}

/// A real [PerformanceRepository] that additionally logs when
/// [persistLiveLanes] runs, into a shared [log] list — proves the D-CLEAR
/// ordering (persist-before-clear) without mocking file I/O, since the
/// repository itself is not mock-friendly (real disk access).
class _RecordingPerformanceRepository extends PerformanceRepository {
  _RecordingPerformanceRepository({
    required this.log,
    required super.engine,
    required super.exportsRoot,
  }) : super(guards: GuardRegistry());

  final List<String> log;

  /// When set, holds [persistLiveLanes] open until completed — lets a test
  /// close the cubit while the D-CLEAR persist is still in flight.
  Completer<void>? persistGate;

  @override
  Future<void> persistLiveLanes() async {
    log.add('persistLiveLanes');
    final gate = persistGate;
    if (gate != null) await gate.future;
    await super.persistLiveLanes();
  }
}

LooperState _stateWith(
  List<Track> tracks, {
  int masterLengthFrames = 48000,
  int masterPositionFrames = 0,
  int sampleRate = 48000,
  bool countingIn = false,
}) => LooperState(
  transport: TransportState(
    isRunning: true,
    masterLengthFrames: masterLengthFrames,
    masterPositionFrames: masterPositionFrames,
    countingIn: countingIn,
  ),
  tracks: tracks,
  status: EngineStatus(sampleRate: sampleRate),
);

List<Track> _emptyTracks([int count = 8]) => [
  for (var i = 0; i < count; i++) Track(channel: i),
];

List<Track> _tracksWith(List<Track> overrides) => [
  for (var i = 0; i < 8; i++)
    overrides.firstWhere(
      (t) => t.channel == i,
      orElse: () => Track(channel: i),
    ),
];

/// The ONE control-surface interpreter, tested over mocked engine truth: the
/// intent methods (shared by keyboard / on-screen surfaces), the stored-
/// intent invalidation reducer, and the pedal I/O it owns through
/// [PedalRepository] — footswitch decode in, projected LED frames out.
void main() {
  /// Completes when [repository] reaches a status [matches] accepts.
  ///
  /// `ControlCubit` fires `arm()`/`disarm()` and forgets them, and both write
  /// to the filesystem — so how many turns of the event queue they take is a
  /// property of the machine, not of the code. Pumping the queue (or waiting
  /// out a long-press and pumping) and then reading `armedDirectory` is a
  /// race these tests lost under load and under a reordered run.
  ///
  /// Bounded, because `arm()` has two paths that return without emitting at
  /// all — an idempotent re-arm, and the rollback when the engine refuses. An
  /// unbounded wait there is a thirty-second stall pointing at a stream; this
  /// is a prompt failure naming what never happened.
  Future<void> awaitStatusWhere(
    PerformanceRepository repository,
    bool Function(PerformanceCaptureStatus) matches, {
    String what = 'the expected status',
  }) => repository.captureStatus
      .firstWhere(matches)
      .timeout(
        const Duration(seconds: 5),
        onTimeout: () => throw StateError('never reached $what'),
      );

  /// Completes when [repository] reaches exactly [status].
  Future<void> awaitStatus(
    PerformanceRepository repository,
    PerformanceCaptureStatus status,
  ) =>
      awaitStatusWhere(repository, (value) => value == status, what: '$status');

  group('ControlCubit', () {
    late _MockLooperRepository looper;
    late StreamController<LooperState> looperStates;
    late SettingsRepository settings;
    late _PedalSetupStore setupStore;
    late FakePedalLink transport;
    late PedalRepository pedal;
    late PerformanceRepository performance;
    late ControlCubit cubit;
    late bool takeIsLocked;
    late Directory tempDir;
    late DateTime clock;

    /// The repository's remembered Track-chain intent, stubbed as real state
    /// (absence == enabled) so a stomp's read-modify-write behaves like the
    /// live repository rather than a frozen `true`.
    late Map<int, bool> chainEnabled;

    /// The Track-stage chains the repository reports per channel.
    late Map<int, List<TrackEffect>> trackChains;

    /// Publishes [tracks] as engine truth: both the pull (`looper.state`) and
    /// the push (the cubit's reducer subscription) see the same snapshot.
    void setEngine(
      List<Track> tracks, {
      int masterPositionFrames = 0,
    }) {
      final state = _stateWith(
        tracks,
        masterPositionFrames: masterPositionFrames,
      );
      when(() => looper.state).thenReturn(state);
      looperStates.add(state);
    }

    setUp(() async {
      takeIsLocked = false;
      looper = _MockLooperRepository();
      when(() => looper.sessionRevision).thenReturn(0);
      when(() => looper.mixGeneration).thenReturn(0);
      when(() => looper.inputSetup).thenReturn(const InputSetup.empty());
      when(() => looper.laneCount(any())).thenReturn(1);
      final laneMutes = <(int, int), bool>{};
      when(() => looper.laneMuted(any(), any())).thenAnswer(
        (call) =>
            laneMutes[(
              call.positionalArguments[0] as int,
              call.positionalArguments[1] as int,
            )] ??
            false,
      );
      when(() => looper.laneEffects(any(), any())).thenReturn(const []);
      when(() => looper.laneChainEnabled(any(), any())).thenReturn(true);
      when(
        () => looper.laneChainInheritedFrom(any(), any()),
      ).thenReturn(const []);

      when(() => looper.mixSettingsSettled).thenReturn(true);

      when(() => looper.mixRecoveryRequired).thenReturn(false);

      when(
        () => looper.mixSettingsFailures,
      ).thenAnswer((_) => const Stream.empty());
      when(() => looper.fxRecipesSettled).thenReturn(true);
      when(
        () => looper.fxReplayConfirmed,
      ).thenAnswer((_) => const Stream.empty());
      when(() => looper.lengthSettingsSettled).thenReturn(true);
      when(() => looper.recordLengthCaptureLocked).thenAnswer(
        (_) => looper.state.tracks.any((track) => track.isCapturing),
      );
      when(() => looper.recordTimingCaptureLocked).thenAnswer(
        (_) => looper.state.tracks.any((track) => track.isCapturing),
      );
      when(() => looper.recordTimingSettingsSettled).thenReturn(true);
      when(() => looper.recordStartCaptureLocked).thenAnswer(
        (_) => looper.state.tracks.any((track) => track.isCapturing),
      );
      when(() => looper.recordStartSettingsSettled).thenReturn(true);
      when(() => looper.clickModeCaptureLocked).thenAnswer(
        (_) => looper.state.tracks.any((track) => track.isCapturing),
      );
      when(() => looper.clickModeSettled).thenReturn(true);
      when(() => looper.sessionTransport).thenAnswer(
        (_) => looper.state.transport,
      );
      when(() => looper.mixSettingsSnapshot).thenReturn(MixSettingsSnapshot());
      when(
        () => looper.settleFxRecipes(
          waitForCallback: true,
          cancelled: any(named: 'cancelled'),
        ),
      ).thenAnswer((_) async => EngineResult.ok);
      looperStates = StreamController<LooperState>.broadcast(sync: true);
      setupStore = _PedalSetupStore();
      settings = SettingsRepository(store: setupStore);
      transport = FakePedalLink();
      pedal = PedalRepository(transport);
      transport.hello();
      await pumpEventQueue();
      when(() => looper.looperState).thenAnswer((_) => looperStates.stream);
      when(() => looper.clearAll(any())).thenReturn(EngineResult.ok);
      when(() => looper.undoClearAll()).thenReturn(EngineResult.ok);
      when(() => looper.cancelCountIn()).thenReturn(EngineResult.ok);
      when(() => looper.recordRetryPending(any())).thenReturn(false);
      for (final stub in [
        () => looper.record(channel: any(named: 'channel')),
        () => looper.undo(channel: any(named: 'channel')),
        () => looper.redo(channel: any(named: 'channel')),
        () => looper.clear(channel: any(named: 'channel')),
        () => looper.play(channel: any(named: 'channel')),
        () => looper.stopTrack(channel: any(named: 'channel')),
        () => looper.stopRecordControl(channel: any(named: 'channel')),
      ]) {
        when(stub).thenReturn(EngineResult.ok);
      }
      when(
        () => looper.setMute(
          muted: any(named: 'muted'),
          channel: any(named: 'channel'),
        ),
      ).thenAnswer((call) {
        laneMutes[(call.namedArguments[#channel] as int, 0)] =
            call.namedArguments[#muted] as bool;
        return EngineResult.ok;
      });
      when(() => looper.trackMuted(any())).thenAnswer((call) {
        final channel = call.positionalArguments.first as int;
        return looper.state.tracks[channel].muted;
      });
      when(() => looper.setMasterGain(any())).thenReturn(EngineResult.ok);
      when(
        () => looper.cancelArm(channel: any(named: 'channel')),
      ).thenReturn(EngineResult.ok);
      when(
        () => looper.finalizeTake(channel: any(named: 'channel')),
      ).thenReturn(EngineResult.ok);

      chainEnabled = <int, bool>{};
      when(() => looper.trackChainEnabled(any())).thenAnswer(
        (call) => chainEnabled[call.positionalArguments.first as int] ?? true,
      );
      when(
        () => looper.setTrackChainEnabled(
          channel: any(named: 'channel'),
          enabled: any(named: 'enabled'),
        ),
      ).thenAnswer((call) {
        chainEnabled[call.namedArguments[#channel] as int] =
            call.namedArguments[#enabled] as bool;
        return EngineResult.ok;
      });
      // Which channels actually HAVE a Track-stage chain. Empty by default —
      // a sweep must leave a chain-less track alone, so tests that want one
      // flipped have to give it a chain first.
      trackChains = <int, List<TrackEffect>>{};
      when(() => looper.trackEffects(any())).thenAnswer(
        (call) =>
            trackChains[call.positionalArguments.first as int] ??
            const <TrackEffect>[],
      );
      // Which channels the rig has a Track-stage chain on at all — what the
      // binding resolver consults to tell an absent chain (a stale target)
      // from a configured-but-empty one.
      when(() => looper.allTrackChains()).thenAnswer(
        (_) => {
          for (final channel in trackChains.keys)
            channel: const FxChainEnvelope(),
        },
      );
      when(
        () => looper.setTrackEffectEnabled(
          channel: any(named: 'channel'),
          index: any(named: 'index'),
          enabled: any(named: 'enabled'),
        ),
      ).thenAnswer((call) {
        final channel = call.namedArguments[#channel] as int;
        final index = call.namedArguments[#index] as int;
        final chain = trackChains[channel];
        if (chain == null || index < 0 || index >= chain.length) {
          return EngineResult.invalid;
        }
        trackChains[channel] = List<TrackEffect>.of(chain)
          ..[index] = (chain[index] as BuiltInEffect).copyWith(
            enabled: call.namedArguments[#enabled] as bool,
          );
        return EngineResult.ok;
      });

      tempDir = Directory.systemTemp.createTempSync('segno_control_cubit');
      clock = DateTime(2026, 7, 6, 14, 30, 15);
      performance = PerformanceRepository(
        guards: GuardRegistry(),
        engine: FakeAudioEngine(),
        exportsRoot: () async => tempDir.path,
        now: () => clock,
      );
      // Every emit projects a frame from the repository snapshot, so the
      // snapshot has to exist before the first one; setEngine() re-stubs it.
      when(() => looper.state).thenReturn(_stateWith(_emptyTracks()));
      final ownedFade = testFadeSettings();
      cubit = ControlCubit(
        fxPersistence: FxChainPersistence(looper: looper),
        looper: looper,
        mixSettings: testMixSettings(looper),
        pedal: pedal,
        settings: settings,
        performance: performance,
        takeLocked: () => takeIsLocked,
        fadeSettings: ownedFade,
        ownedValues: OwnedValuePort(
          looper: looper,
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
      setEngine(_emptyTracks());
    });

    tearDown(() async {
      if (!cubit.isClosed) await cubit.close();
      await pedal.dispose();
      await looperStates.close();
      performance.dispose();
      tempDir.deleteSync(recursive: true);
    });

    group('mode', () {
      test('toggleMode cycles Record -> Mute -> FX -> Custom -> Record', () {
        expect(cubit.state.mode, InteractionMode.record);
        cubit.toggleMode();
        expect(cubit.state.mode, InteractionMode.mute);
        cubit.toggleMode();
        expect(cubit.state.mode, InteractionMode.fx);
        cubit.toggleMode();
        expect(cubit.state.mode, InteractionMode.custom);
        cubit.toggleMode();
        expect(cubit.state.mode, InteractionMode.record);
      });

      test('entering Mute previews the whole content set as parkedResume', () {
        setEngine(
          _tracksWith(const [
            Track(state: TrackState.playing, lengthFrames: 48000),
            Track(
              channel: 2,
              state: TrackState.stopped,
              muted: true,
              lengthFrames: 48000,
            ),
          ]),
        );
        cubit.toggleMode();
        // Stopped and muted content is included — Rec/Play resumes it all.
        expect(cubit.state.parkedResume, {0, 2});
      });

      test('entering Mute leaves a live capture recording (the mode toggle '
          'is a view change, not a transport action)', () {
        setEngine(
          _tracksWith(const [Track(state: TrackState.recording)]),
        );
        cubit.toggleMode();
        // No finalize: the take keeps recording until the user ends it
        // explicitly (back in Rec mode, Rec/Play — or Stop).
        verifyNever(() => looper.record(channel: any(named: 'channel')));
        verifyNever(() => looper.record());
        expect(cubit.state.mode, InteractionMode.mute);
        // The capture still previews as a parked-resume member.
        expect(cubit.state.parkedResume, {0});
      });

      test('setMode to the current mode is a no-op', () {
        cubit.setMode(InteractionMode.record);
        verifyNever(() => looper.record(channel: any(named: 'channel')));
        expect(cubit.state.mode, InteractionMode.record);
      });

      test('a stored Mute default boots Record and is marked once', () async {
        await setupStore.setString('looper.default_mode', 'mute');
        cubit.setMode(InteractionMode.mute);
        await cubit.load();
        expect(cubit.state.mode, InteractionMode.record);
        expect(cubit.state.retiredBootMode, InteractionMode.mute);
        // Read once: the key is gone, so the next start has nothing to say.
        expect(await settings.takeRetiredDefaultInteractionMode(), isNull);
      });

      for (final token in ['record', 'play', 'fx', 'custom']) {
        test('a stored "$token" default boots Record with no notice', () async {
          await setupStore.setString('looper.default_mode', token);
          await cubit.load();
          expect(cubit.state.mode, InteractionMode.record);
          expect(cubit.state.retiredBootMode, isNull);
          expect(await settings.takeRetiredDefaultInteractionMode(), isNull);
        });
      }

      // An install that was set up before this build: a stored pedal setup,
      // bindings or boot default.
      final upgrades = <String, Future<void> Function()>{
        'pedal setup': () => settings.savePedalSetup(
          const PedalSetup().encode(),
        ),
        'bindings': () => settings.savePedalBindings(
          PedalBindingSet(const []).encode(),
        ),
        'boot default': () => setupStore.setString(
          'looper.default_mode',
          'record',
        ),
      };
      for (final MapEntry(key: what, value: store) in upgrades.entries) {
        test(
          'the first FX entry after an upgrade with a stored $what says '
          'once that Stop no longer sweeps the track chains (#1229)',
          () async {
            await store();
            await cubit.load();
            expect(cubit.state.fxStopChangeNotice, isFalse);
            cubit.setMode(InteractionMode.fx);
            expect(cubit.state.fxStopChangeNotice, isTrue);
            await pumpEventQueue();
            expect(await settings.loadFxStopChangeNoticeShown(), isTrue);
          },
        );
      }

      // A fresh install: never told, and boot writes nothing; the decision
      // is stored before anything could make a later boot read it as an
      // upgrade (#1229 review L1).
      final freshStores = <String, Future<void> Function(ControlCubit)>{
        'its first FX entry': (cubit) async =>
            cubit.setMode(InteractionMode.fx),
        'a pedal setup save': (cubit) => cubit.setPedalSetup(
          const PedalSetup(modeHold: InteractionMode.mixer),
        ),
        'a bindings save': (cubit) => cubit.setGlobalBindings(
          PedalBindingSet([
            PedalBinding(
              key: const PedalBindingKey(button: PedalButton.track1, bank: 0),
              target: const FxChainTarget(
                FxAddress(stage: FxStage.track),
              ).canonicalString(),
            ),
          ]),
        ),
      };
      for (final MapEntry(key: what, value: act) in freshStores.entries) {
        test('a fresh install never hears about the old Stop, and stores '
            'that at $what', () async {
          await cubit.load();
          await pumpEventQueue();
          expect(
            await settings.loadFxStopChangeNoticeShown(),
            isFalse,
            reason: 'boot writes nothing',
          );
          await act(cubit);
          await pumpEventQueue();
          expect(await settings.loadFxStopChangeNoticeShown(), isTrue);
          cubit.setMode(InteractionMode.fx);
          expect(cubit.state.fxStopChangeNotice, isFalse);
        });
      }

      test('an install already told hears nothing on FX entry', () async {
        await settings.saveFxStopChangeNoticeShown();
        await cubit.load();
        cubit.setMode(InteractionMode.fx);
        expect(cubit.state.fxStopChangeNotice, isFalse);
      });

      test('no stored default boots Record with no notice', () async {
        await cubit.load();
        expect(cubit.state.mode, InteractionMode.record);
        expect(cubit.state.retiredBootMode, isNull);
      });

      test('entering FX mode FINALIZES a live capture at the entry gesture '
          'via the immediate-finalize primitive, never a record press '
          '(#405)', () {
        setEngine(
          _tracksWith(const [Track(state: TrackState.recording)]),
        );
        cubit.setMode(InteractionMode.fx);
        // The primitive, not record(): a record press under quantize ARMS a
        // loop-top finalize instead of ending the take — the withdrawn A5
        // attempt this entry replaces. finalizeTake ends the take on-grid
        // (rounded up, tail silent) with no arm machinery involved.
        verify(() => looper.finalizeTake(channel: 0)).called(1);
        verifyNever(() => looper.record(channel: any(named: 'channel')));
        verifyNever(() => looper.record());
        expect(cubit.state.mode, InteractionMode.fx);
      });

      test('a DEFINING take survives FX entry: the engine refusal is the '
          'fallback, silently accepted (#405)', () {
        setEngine(
          _tracksWith(const [Track(state: TrackState.recording)]),
        );
        // The engine refuses the defining take (finalizing it would let a
        // mode switch set the session's bar length). The cubit asks — it
        // cannot know which take defines the grid — and accepts the refusal
        // as "the capture survives", entering FX regardless.
        when(
          () => looper.finalizeTake(channel: any(named: 'channel')),
        ).thenReturn(EngineResult.invalid);
        cubit.setMode(InteractionMode.fx);
        verify(() => looper.finalizeTake(channel: 0)).called(1);
        expect(cubit.state.mode, InteractionMode.fx);
      });

      test('entering FX mode leaves a live OVERDUB running — punch-out is '
          'out of scope, exactly as under Mute (#405 decision 2)', () {
        setEngine(
          _tracksWith(const [
            Track(state: TrackState.overdubbing, lengthFrames: 48000),
          ]),
        );
        cubit.setMode(InteractionMode.fx);
        verifyNever(() => looper.finalizeTake(channel: any(named: 'channel')));
        verifyNever(() => looper.record(channel: any(named: 'channel')));
        expect(cubit.state.mode, InteractionMode.fx);
      });

      test('entering FX mode mid COUNT-IN aborts it — nothing has been '
          'captured, and no track even reads as recording yet (#405 '
          'decision 3)', () {
        // Empty-looking tracks can already have queued launch requests.
        // Cancel each address; finalizeTake must not impersonate global Stop.
        final state = _stateWith(_emptyTracks(), countingIn: true);
        when(() => looper.state).thenReturn(state);
        looperStates.add(state);

        cubit.setMode(InteractionMode.fx);

        for (var channel = 0; channel < 8; channel++) {
          verify(() => looper.cancelArm(channel: channel)).called(1);
        }
        verifyNever(() => looper.finalizeTake(channel: any(named: 'channel')));
        expect(cubit.state.mode, InteractionMode.fx);
      });

      test(
        'FX entry cancels earlier requests before membership publication',
        () {
          setEngine(_emptyTracks());

          cubit.setMode(InteractionMode.fx);

          for (var channel = 0; channel < 8; channel++) {
            verify(() => looper.cancelArm(channel: channel)).called(1);
          }
          verifyNever(() => looper.record(channel: any(named: 'channel')));
          verifyNever(
            () => looper.finalizeTake(channel: any(named: 'channel')),
          );
          verifyNever(() => looper.stopTrack(channel: any(named: 'channel')));
        },
      );

      test(
        'FX entry stays on transport controls when cancellation is refused',
        () {
          when(
            () => looper.cancelArm(channel: 6),
          ).thenReturn(EngineResult.invalid);
          cubit.setMode(InteractionMode.fx);
          expect(cubit.state.mode, InteractionMode.record);
          verifyNever(
            () => looper.finalizeTake(channel: any(named: 'channel')),
          );
          when(() => looper.cancelArm(channel: 6)).thenReturn(EngineResult.ok);
          cubit.setMode(InteractionMode.fx);
          expect(cubit.state.mode, InteractionMode.fx);
        },
      );

      test('the arm sweep runs BEFORE the finalize on a capturing track with '
          'a pending loop-top finalize arm — the primitive refuses under a '
          'live arm, and the sweep is what retires it (#405)', () {
        setEngine(
          _tracksWith(const [
            Track(state: TrackState.recording, pending: true),
          ]),
        );
        cubit.setMode(InteractionMode.fx);
        verifyInOrder([
          () => looper.cancelArm(channel: 0),
          () => looper.finalizeTake(channel: 0),
        ]);
      });

      test(
        'entering FX mode CANCELS a pending arm rather than recording it',
        () {
          setEngine(
            _tracksWith(const [Track(pending: true)]),
          );
          // The arm has not fired, so nothing is "capturing" — but leaving it
          // would start a take seconds later with every FX-mode control inert.
          cubit.setMode(InteractionMode.fx);

          // The distinction is the whole point: `record()` is only a cancel
          // for an arm whose trigger it owns, and only while the conditions
          // that created the arm still hold — with the transport parked the
          // same call STARTS the capture (pinned natively by
          // test_record_press_on_pending_arm_starts_when_parked). Asserting
          // "a record command was issued" cannot tell those apart, so pin the
          // unconditional cancel instead.
          verify(() => looper.cancelArm(channel: 0)).called(1);
          verifyNever(() => looper.record(channel: any(named: 'channel')));
          verifyNever(() => looper.record());
        },
      );

      test('an armed PUNCH-OUT on a capturing track has its arm cancelled and '
          'the take left alone', () {
        // pending AND capturing at once: a quantized punch-out waiting for the
        // loop top. Only the arm is retired — re-pressing record here would
        // have re-armed the very thing just cancelled.
        setEngine(
          _tracksWith(const [
            Track(state: TrackState.overdubbing, pending: true),
          ]),
        );
        cubit.setMode(InteractionMode.fx);

        verify(() => looper.cancelArm(channel: 0)).called(1);
        verifyNever(() => looper.record(channel: any(named: 'channel')));
        verifyNever(() => looper.record());
        // And the dub itself is untouched: overdubbing is not RECORDING, so
        // the immediate finalize never fires for it (#405 decision 2).
        verifyNever(() => looper.finalizeTake(channel: any(named: 'channel')));
      });

      test(
        'FX cancellation stays safe with an already retired published arm',
        () {
          // The polled snapshot still shows an arm the engine has already
          // retired; the live read is what the sweep must follow.
          looperStates.add(
            _stateWith(_tracksWith(const [Track(pending: true)])),
          );
          when(() => looper.state).thenReturn(
            _stateWith(
              _tracksWith(const [
                Track(state: TrackState.playing, lengthFrames: 48000),
              ]),
            ),
          );

          cubit.setMode(InteractionMode.fx);

          for (var channel = 0; channel < 8; channel++) {
            verify(() => looper.cancelArm(channel: channel)).called(1);
          }
          verifyNever(() => looper.record(channel: any(named: 'channel')));
          verifyNever(() => looper.stopTrack(channel: any(named: 'channel')));
        },
      );

      test('entering FX mode with nothing capturing touches the transport '
          'not at all', () {
        setEngine(
          _tracksWith(const [
            Track(state: TrackState.playing, lengthFrames: 48000),
          ]),
        );
        cubit.setMode(InteractionMode.fx);
        verifyNever(() => looper.record(channel: any(named: 'channel')));
        verifyNever(() => looper.record());
        verifyNever(() => looper.stopTrack(channel: any(named: 'channel')));
        verifyNever(() => looper.finalizeTake(channel: any(named: 'channel')));
      });

      test('side effects fire for the LANDED mode only — the cycle never '
          'runs an intermediate mode entry (A5)', () async {
        setEngine(
          _tracksWith(const [
            Track(state: TrackState.playing, lengthFrames: 48000),
          ]),
        );
        // Watch the EMITTED states, not just the final one: an implementation
        // that walked the cycle (setMode(mute) then setMode(fx)) would land
        // the same way while firing mute's entry on the way through, and a
        // final-state assertion could never see it — fx's own entry clears
        // exactly what mute's would have latched.
        final seen = <(InteractionMode, Set<int>)>[];
        final sub = cubit.stream.listen(
          (s) => seen.add((s.mode, s.parkedResume)),
        );
        addTearDown(() => unawaited(sub.cancel()));

        cubit
          ..toggleMode() // -> mute, which DOES latch (it is the landed mode)
          ..toggleMode(); // -> fx
        await pumpEventQueue();

        expect(
          seen.map((e) => e.$1),
          [InteractionMode.mute, InteractionMode.fx],
          reason: 'each tap lands exactly one mode',
        );
        expect(seen.first.$2, {0}, reason: 'mute landed, so mute latched');
        expect(seen.last.$2, isEmpty, reason: 'fx landed, so fx cleared');

        // ...and jumping straight to FX skips mute's entry entirely: no
        // intermediate state is emitted at all.
        seen.clear();
        cubit
          ..setMode(InteractionMode.record)
          ..setMode(InteractionMode.fx);
        await pumpEventQueue();
        expect(seen.map((e) => e.$1), [
          InteractionMode.record,
          InteractionMode.fx,
        ]);
      });

      test('FX entry clears the stored mute-mode intent', () {
        setEngine(
          _tracksWith(const [
            Track(state: TrackState.stopped, lengthFrames: 48000),
          ]),
        );
        cubit.toggleMode(); // -> mute, parkedResume = {0}
        expect(cubit.state.parkedResume, {0});
        cubit.toggleMode(); // -> fx
        expect(cubit.state.parkedResume, isEmpty);
        expect(cubit.state.excluded, isEmpty);
      });
    });

    group('Pedal setup Press and Hold', () {
      Future<void> stomp(PedalButton button) async {
        transport
          ..press(button, down: true)
          ..press(button, down: false);
        await pumpEventQueue();
      }

      Future<void> hold(PedalButton button) async {
        transport.press(button, down: true);
        await pumpEventQueue();
        await Future<void>.delayed(const Duration(milliseconds: 850));
        transport.press(button, down: false);
        await pumpEventQueue();
      }

      test('fresh setup keeps Mute Press and Custom Hold', () {
        expect(cubit.state.pedalSetup.modePress, InteractionMode.mute);
        expect(cubit.state.pedalSetup.modeHold, InteractionMode.custom);
      });

      test('Press waits for release when MODE has a Hold', () async {
        transport.press(PedalButton.mode, down: true);
        await pumpEventQueue();
        expect(cubit.state.mode, InteractionMode.record);
        transport.press(PedalButton.mode, down: false);
        await pumpEventQueue();
        expect(cubit.state.mode, InteractionMode.mute);
      });

      test('MODE without Hold acts on contact', () async {
        await cubit.setPedalSetup(
          cubit.state.pedalSetup.copyWith(clearModeHold: true),
        );
        transport.press(PedalButton.mode, down: true);
        await pumpEventQueue();
        expect(cubit.state.mode, InteractionMode.mute);
      });

      test(
        'MODE Hold fires at threshold, with no second Press on release',
        () async {
          transport.press(PedalButton.mode, down: true);
          await pumpEventQueue();
          expect(cubit.state.mode, InteractionMode.record);
          await Future<void>.delayed(const Duration(milliseconds: 850));
          expect(cubit.state.mode, InteractionMode.custom);
          expect(transport.lastFrame?.mode, PedalMode.custom);
          transport.press(PedalButton.mode, down: false);
          await pumpEventQueue();
          expect(cubit.state.mode, InteractionMode.custom);
          expect(performance.armedDirectory, isNull);
        },
      );

      test('Custom MODE exits directly to Tracks', () async {
        await stomp(PedalButton.mode);
        expect(cubit.state.mode, InteractionMode.mute);
        await hold(PedalButton.mode);
        expect(cubit.state.mode, InteractionMode.custom);
        await stomp(PedalButton.mode);
        expect(cubit.state.mode, InteractionMode.record);
      });

      test('an explicitly saved FX Hold keeps its return door', () async {
        await cubit.setPedalSetup(
          cubit.state.pedalSetup.copyWith(modeHold: InteractionMode.fx),
        );
        await stomp(PedalButton.mode);
        expect(cubit.state.mode, InteractionMode.mute);
        await hold(PedalButton.mode);
        expect(cubit.state.mode, InteractionMode.fx);
        await hold(PedalButton.mode);
        expect(cubit.state.mode, InteractionMode.mute);
      });

      test('BANK tap pages on release while Hold remains the physical '
          'performance-recording path', () async {
        transport.press(PedalButton.bank, down: true);
        await pumpEventQueue();
        expect(cubit.state.activeBank, 0);
        transport.press(PedalButton.bank, down: false);
        await pumpEventQueue();
        expect(cubit.state.activeBank, 1);
        expect(performance.armedDirectory, isNull);

        final armed = awaitStatus(performance, PerformanceCaptureStatus.armed);
        await hold(PedalButton.bank);
        await armed;
        expect(cubit.state.activeBank, 1, reason: 'Hold retires the page tap');
        expect(performance.armedDirectory, isNotNull);
      });

      test(
        'Record/Play remains immediate and its Hold undoes the take',
        () async {
          transport.press(PedalButton.recPlay, down: true);
          await pumpEventQueue();
          verify(() => looper.record()).called(1);
          await Future<void>.delayed(const Duration(milliseconds: 850));
          verify(() => looper.undo()).called(1);
          transport.press(PedalButton.recPlay, down: false);
          await pumpEventQueue();
        },
      );

      test('Record Hold follows the new selection before it fires', () async {
        transport.press(PedalButton.recPlay, down: true);
        await pumpEventQueue();
        cubit.selectTrack(2);
        await Future<void>.delayed(const Duration(milliseconds: 850));
        verify(() => looper.undo(channel: 2)).called(1);
        verifyNever(() => looper.undo());
        transport.press(PedalButton.recPlay, down: false);
        await pumpEventQueue();
      });

      test('Record Hold remains available in Mute mode', () async {
        cubit.setMode(InteractionMode.mute);
        transport.press(PedalButton.recPlay, down: true);
        await pumpEventQueue();
        await Future<void>.delayed(const Duration(milliseconds: 850));
        verify(() => looper.undo()).called(1);
        transport.press(PedalButton.recPlay, down: false);
        await pumpEventQueue();
      });

      test('a Track Hold can clear its contact-selected track', () async {
        await cubit.setPedalSetup(
          cubit.state.pedalSetup.copyWith(trackHold: TrackHold.clearTrack),
        );
        await hold(PedalButton.track3);
        expect(cubit.state.cursor, 2);
        verify(() => looper.clear(channel: 2)).called(1);
      });

      test(
        'Track Hold follows the current bank position until it fires',
        () async {
          await cubit.setPedalSetup(
            cubit.state.pedalSetup.copyWith(trackHold: TrackHold.clearTrack),
          );
          transport.press(PedalButton.track1, down: true);
          await pumpEventQueue();
          cubit.browseBank(1);
          await Future<void>.delayed(const Duration(milliseconds: 850));
          verify(() => looper.clear(channel: 4)).called(1);
          verifyNever(() => looper.clear());
          transport.press(PedalButton.track1, down: false);
          await pumpEventQueue();
        },
      );

      test(
        'Arm overdub Hold does not start a take on an empty track',
        () async {
          await hold(PedalButton.track2);
          verifyNever(() => looper.record(channel: 1));
        },
      );

      test(
        'Arm overdub Hold starts only when the track has loop content',
        () async {
          setEngine(
            _tracksWith(const [
              Track(channel: 1, state: TrackState.playing, lengthFrames: 48000),
            ]),
          );
          transport.press(PedalButton.track2, down: true);
          await pumpEventQueue();
          verifyNever(() => looper.record(channel: 1));
          await Future<void>.delayed(const Duration(milliseconds: 850));
          verify(() => looper.record(channel: 1)).called(1);
          transport.press(PedalButton.track2, down: false);
          await pumpEventQueue();
        },
      );

      test(
        'Arm overdub Hold leaves a take started during the hold recording',
        () async {
          setEngine(
            _tracksWith(const [
              Track(channel: 1, state: TrackState.playing, lengthFrames: 48000),
            ]),
          );
          transport.press(PedalButton.track2, down: true);
          await pumpEventQueue();
          // The native callback can begin an overdub before the repository's
          // next UI poll. Only the fresh repository pull sees it yet.
          when(() => looper.state).thenReturn(
            _stateWith(
              _tracksWith(const [
                Track(
                  channel: 1,
                  state: TrackState.recording,
                  lengthFrames: 48000,
                ),
              ]),
            ),
          );
          await Future<void>.delayed(const Duration(milliseconds: 850));
          verifyNever(() => looper.record(channel: 1));
          transport.press(PedalButton.track2, down: false);
          await pumpEventQueue();
        },
      );

      test(
        'Arm overdub Hold leaves an existing quantized arm pending',
        () async {
          setEngine(
            _tracksWith(const [
              Track(channel: 1, state: TrackState.playing, lengthFrames: 48000),
            ]),
          );
          transport.press(PedalButton.track2, down: true);
          await pumpEventQueue();
          when(() => looper.state).thenReturn(
            _stateWith(
              _tracksWith(const [
                Track(
                  channel: 1,
                  state: TrackState.playing,
                  lengthFrames: 48000,
                  pending: true,
                ),
              ]),
            ),
          );
          await Future<void>.delayed(const Duration(milliseconds: 850));
          verifyNever(() => looper.record(channel: 1));
          transport.press(PedalButton.track2, down: false);
          await pumpEventQueue();
        },
      );

      test('configured Track Hold does not run in Mute mode', () async {
        await cubit.setPedalSetup(
          cubit.state.pedalSetup.copyWith(trackHold: TrackHold.clearTrack),
        );
        cubit.setMode(InteractionMode.mute);
        await hold(PedalButton.track2);
        verifyNever(() => looper.clear(channel: 1));
      });

      test('setup Save is durable before new gestures become live', () async {
        final next = cubit.state.pedalSetup.copyWith(
          modePress: InteractionMode.fx,
          trackHold: TrackHold.clearTrack,
        );
        await cubit.setPedalSetup(next);
        expect(cubit.state.pedalSetup, next);
        expect(await settings.loadPedalSetup(), next.encode());
        await cubit.load();
        expect(cubit.state.pedalSetup, next);
      });

      test(
        'hue-only Save preserves an accepted held contact and its mask',
        () async {
          transport.press(PedalButton.undo, down: true);
          await pumpEventQueue();
          final held = transport.lastFrame!;
          expect(held.isLit(PedalButton.undo), isTrue);
          final next = cubit.state.pedalSetup.copyWith(
            palette: const PedalPalette().withChoice(
              PedalButton.undo,
              const BuiltInPaletteEntry(PedalPaletteColor.cyan),
            ),
          );
          await cubit.setPedalSetup(next);
          final recolored = transport.lastFrame!;
          expect(recolored.isLit(PedalButton.undo), isTrue);
          expect(recolored.activeButtonMask, held.activeButtonMask);
          // Record mode lights in fixed state colours; the saved hue waits
          // for Custom mode.
          expect(
            recolored.colorFor(PedalButton.undo),
            held.colorFor(PedalButton.undo),
          );
          expect(await settings.loadPedalSetup(), next.encode());
          transport.press(PedalButton.undo, down: false);
          await pumpEventQueue();
          expect(transport.lastFrame!.isLit(PedalButton.undo), isFalse);
        },
      );

      test('failed hue Save keeps the old frame and durable palette', () async {
        transport.press(PedalButton.undo, down: true);
        await pumpEventQueue();
        final held = transport.lastFrame!;
        setupStore.refuseSetup = true;
        await expectLater(
          cubit.setPedalSetup(
            cubit.state.pedalSetup.copyWith(
              palette: const PedalPalette().withChoice(
                PedalButton.undo,
                const BuiltInPaletteEntry(PedalPaletteColor.red),
              ),
            ),
          ),
          throwsException,
        );
        expect(transport.lastFrame, held);
        expect(cubit.state.pedalSetup.palette, const PedalPalette());
        transport.press(PedalButton.undo, down: false);
        await pumpEventQueue();
      });

      test(
        'hue-only Save retains a pending Mode gesture and FX return',
        () async {
          transport.press(PedalButton.mode, down: true);
          await pumpEventQueue();
          await cubit.setPedalSetup(
            cubit.state.pedalSetup.copyWith(
              palette: const PedalPalette().withChoice(
                PedalButton.mode,
                const BuiltInPaletteEntry(PedalPaletteColor.blue),
              ),
            ),
          );
          transport.press(PedalButton.mode, down: false);
          await pumpEventQueue();
          expect(cubit.state.mode, InteractionMode.mute);

          await cubit.setPedalSetup(
            cubit.state.pedalSetup.copyWith(
              modePress: InteractionMode.fx,
              clearModeHold: true,
            ),
          );
          cubit.setMode(InteractionMode.fx);
          await cubit.setPedalSetup(
            cubit.state.pedalSetup.copyWith(
              palette: cubit.state.pedalSetup.palette.withChoice(
                PedalButton.mode,
                const BuiltInPaletteEntry(PedalPaletteColor.amber),
              ),
            ),
          );
          transport
            ..press(PedalButton.mode, down: true)
            ..press(PedalButton.mode, down: false);
          await pumpEventQueue();
          expect(cubit.state.mode, InteractionMode.mute);
        },
      );

      test(
        'Save waits for an older boot read before publishing its setup',
        () async {
          const old = PedalSetup();
          const next = PedalSetup(modePress: InteractionMode.fx);
          await settings.savePedalSetup(old.encode());
          setupStore
            ..setupReadGate = Completer<void>()
            ..setupReadSampled = Completer<void>();
          final loading = cubit.load();
          await setupStore.setupReadSampled!.future;
          final saving = cubit.setPedalSetup(next);
          await pumpEventQueue();
          setupStore.setupReadGate!.complete();
          await loading;
          await saving;
          expect(cubit.state.pedalSetup, next);
          expect(await settings.loadPedalSetup(), next.encode());
        },
      );

      test(
        'storage refusal keeps the prior live setup and its gestures',
        () async {
          final prior = cubit.state.pedalSetup;
          setupStore.refuseSetup = true;
          await expectLater(
            cubit.setPedalSetup(prior.copyWith(modePress: InteractionMode.fx)),
            throwsException,
          );
          expect(cubit.state.pedalSetup, prior);
          expect(await settings.loadPedalSetup(), isNull);
          await stomp(PedalButton.mode);
          expect(cubit.state.mode, InteractionMode.mute);
        },
      );

      test(
        'write-then-throw restores the saved setup without changing gestures',
        () async {
          final prior = cubit.state.pedalSetup;
          await settings.savePedalSetup(prior.encode());
          setupStore.failAfterSetupWrite = true;

          await expectLater(
            cubit.setPedalSetup(prior.copyWith(modePress: InteractionMode.fx)),
            throwsA(
              isA<PedalSetupSaveException>().having(
                (error) => error.checkpointRestored,
                'restored',
                isTrue,
              ),
            ),
          );
          expect(cubit.state.pedalSetup, prior);
          expect(await settings.loadPedalSetup(), prior.encode());
          await stomp(PedalButton.mode);
          expect(cubit.state.mode, InteractionMode.mute);
        },
      );

      test(
        'failed checkpoint restore remains visible until same-value Save '
        'repairs storage',
        () async {
          final prior = cubit.state.pedalSetup;
          await settings.savePedalSetup(prior.encode());
          setupStore
            ..failAfterSetupWrite = true
            ..refuseSetupValue = prior.encode();

          await expectLater(
            cubit.setPedalSetup(prior.copyWith(modePress: InteractionMode.fx)),
            throwsA(
              isA<PedalSetupSaveException>().having(
                (error) => error.checkpointRestored,
                'checkpoint restored',
                isFalse,
              ),
            ),
          );
          expect(cubit.state.pedalSetup, prior);
          expect(cubit.state.pedalSetupPersistenceUncertain, isTrue);
          expect(await settings.loadPedalSetup(), isNot(prior.encode()));

          setupStore.refuseSetupValue = null;
          await cubit.setPedalSetup(prior);
          expect(cubit.state.pedalSetupPersistenceUncertain, isFalse);
          expect(await settings.loadPedalSetup(), prior.encode());
        },
      );

      test(
        'an explicitly malformed saved action is inert until deliberate Save',
        () async {
          await settings.savePedalSetup('{"modePress":"sideways"}');
          await cubit.load();
          expect(cubit.state.pedalSetupUnavailable, isTrue);
          expect(cubit.state.pedalSetup, const PedalSetup());
          await stomp(PedalButton.mode);
          expect(cubit.state.mode, InteractionMode.record);

          await cubit.setPedalSetup(const PedalSetup());
          expect(cubit.state.pedalSetupUnavailable, isFalse);
          expect(await settings.loadPedalSetup(), const PedalSetup().encode());
          await stomp(PedalButton.mode);
          expect(cubit.state.mode, InteractionMode.mute);
        },
      );

      test(
        'a malformed Track Hold cannot become default Arm overdub',
        () async {
          await settings.savePedalSetup(
            '{"trackHold":"future-unknown-action"}',
          );
          await cubit.load();
          expect(cubit.state.pedalSetupUnavailable, isTrue);
          setEngine(
            _tracksWith(const [
              Track(channel: 1, state: TrackState.playing, lengthFrames: 48000),
            ]),
          );

          transport.press(PedalButton.track2, down: true);
          await pumpEventQueue();
          clearInteractions(looper);
          await Future<void>.delayed(const Duration(milliseconds: 850));
          verifyNever(() => looper.record(channel: 1));
          transport.press(PedalButton.track2, down: false);
          await pumpEventQueue();
        },
      );

      test('Save retires the previous pending gesture', () async {
        transport.press(PedalButton.mode, down: true);
        await pumpEventQueue();
        await cubit.setPedalSetup(
          cubit.state.pedalSetup.copyWith(modePress: InteractionMode.fx),
        );
        transport.press(PedalButton.mode, down: false);
        await pumpEventQueue();
        expect(cubit.state.mode, InteractionMode.record);
      });
    });

    group('Custom controls', () {
      Future<void> stomp(PedalButton button) async {
        transport
          ..press(button, down: true)
          ..press(button, down: false);
        await pumpEventQueue();
      }

      Future<void> assign(
        PedalButton button,
        ControlGesturePair pair, {
        int bank = 0,
      }) async {
        await cubit.setPedalSetup(
          cubit.state.pedalSetup.withCustom(button, bank: bank, pair: pair),
        );
        cubit.setMode(InteractionMode.custom);
      }

      test(
        'unassigned controls do nothing; MODE exits and BANK pages',
        () async {
          cubit.setMode(InteractionMode.custom);
          await stomp(PedalButton.undo);
          await stomp(PedalButton.clear);
          verifyNever(() => looper.undo(channel: any(named: 'channel')));
          verifyNever(() => looper.clear(channel: any(named: 'channel')));
          await stomp(PedalButton.bank);
          expect(cubit.state.activeBank, 1);
          await stomp(PedalButton.mode);
          expect(cubit.state.mode, InteractionMode.record);
        },
      );

      test(
        'Press-only fires on contact; paired Press waits for release',
        () async {
          await assign(
            PedalButton.undo,
            const ControlGesturePair(press: CommandAction(ControlCommand.undo)),
          );
          transport.press(PedalButton.undo, down: true);
          await pumpEventQueue();
          verify(() => looper.undo()).called(1);
          transport.press(PedalButton.undo, down: false);
          await pumpEventQueue();

          await assign(
            PedalButton.undo,
            const ControlGesturePair(
              press: CommandAction(ControlCommand.undo),
              hold: CommandAction(ControlCommand.redo),
            ),
          );
          transport.press(PedalButton.undo, down: true);
          await pumpEventQueue();
          verifyNever(() => looper.undo(channel: any(named: 'channel')));
          transport.press(PedalButton.undo, down: false);
          await pumpEventQueue();
          verify(() => looper.undo()).called(1);
        },
      );

      test('Hold fires once and suppresses paired Press on release', () async {
        await assign(
          PedalButton.undo,
          const ControlGesturePair(
            press: CommandAction(ControlCommand.undo),
            hold: CommandAction(ControlCommand.redo),
          ),
        );
        transport.press(PedalButton.undo, down: true);
        await pumpEventQueue();
        await Future<void>.delayed(const Duration(milliseconds: 850));
        await pumpEventQueue();
        transport.press(PedalButton.undo, down: false);
        await pumpEventQueue();
        verify(() => looper.redo()).called(1);
        verifyNever(() => looper.undo(channel: any(named: 'channel')));
      });

      test('selected Hold follows new cursor at fire', () async {
        await assign(
          PedalButton.stop,
          const ControlGesturePair(
            hold: TrackOperationAction(
              operation: TrackOperation.clear,
              scope: SelectedTrackScope(),
            ),
          ),
        );
        transport.press(PedalButton.stop, down: true);
        await pumpEventQueue();
        cubit.selectTrack(2);
        await Future<void>.delayed(const Duration(milliseconds: 850));
        await pumpEventQueue();
        verify(() => looper.clear(channel: 2)).called(1);
        transport.press(PedalButton.stop, down: false);
        await pumpEventQueue();
      });

      test('bank switch resolves current bank at fire', () async {
        await assign(
          PedalButton.track1,
          const ControlGesturePair(press: CommandAction(ControlCommand.undo)),
        );
        await cubit.setPedalSetup(
          cubit.state.pedalSetup.withCustom(
            PedalButton.track1,
            bank: 1,
            pair: const ControlGesturePair(
              press: CommandAction(ControlCommand.redo),
            ),
          ),
        );
        cubit.setMode(InteractionMode.custom);
        await stomp(PedalButton.track1);
        verify(() => looper.undo()).called(1);
        cubit.browseBank(1);
        await stomp(PedalButton.track1);
        verify(() => looper.redo()).called(1);
      });

      test('changed assignment and take lock retire pending Hold', () async {
        await assign(
          PedalButton.undo,
          const ControlGesturePair(
            press: CommandAction(ControlCommand.undo),
            hold: CommandAction(ControlCommand.redo),
          ),
        );
        transport.press(PedalButton.undo, down: true);
        await pumpEventQueue();
        await cubit.setPedalSetup(
          cubit.state.pedalSetup.withCustom(
            PedalButton.undo,
            bank: 0,
            pair: const ControlGesturePair(
              press: CommandAction(ControlCommand.clearAll),
            ),
          ),
        );
        transport.press(PedalButton.undo, down: false);
        await pumpEventQueue();
        verifyNever(() => looper.clearAll(any()));
        verifyNever(() => looper.undo(channel: any(named: 'channel')));

        await assign(
          PedalButton.undo,
          const ControlGesturePair(press: CommandAction(ControlCommand.undo)),
        );
        takeIsLocked = true;
        await stomp(PedalButton.undo);
        verifyNever(() => looper.undo(channel: any(named: 'channel')));
      });

      test('assignment alone stays dark; live Mute state drives LED', () async {
        await assign(
          PedalButton.track1,
          const ControlGesturePair(
            press: TrackOperationAction(
              operation: TrackOperation.mute,
              scope: SelectedTrackScope(),
            ),
          ),
        );
        await pumpEventQueue();
        expect(transport.lastFrame?.trackLeds[0], PedalTrackLed.off);
        setEngine(_tracksWith(const [Track(muted: true)]));
        await pumpEventQueue();
        expect(transport.lastFrame?.trackLeds[0], PedalTrackLed.blue);
        cubit.selectTrack(1);
        await pumpEventQueue();
        expect(transport.lastFrame?.trackLeds[0], PedalTrackLed.off);
      });

      test('refused Custom Record/Play never lights its contact', () async {
        await assign(
          PedalButton.stop,
          const ControlGesturePair(
            press: CommandAction(ControlCommand.recordPlay),
          ),
        );
        when(
          () => looper.record(channel: any(named: 'channel')),
        ).thenReturn(EngineResult.notReady);

        transport.press(PedalButton.stop, down: true);
        await pumpEventQueue();

        verify(
          () => looper.record(channel: any(named: 'channel')),
        ).called(1);
        expect(transport.lastFrame?.isLit(PedalButton.stop), isFalse);
        transport.press(PedalButton.stop, down: false);
        await pumpEventQueue();
      });

      test('refused Custom Clear All keeps its contact dark', () async {
        await assign(
          PedalButton.stop,
          const ControlGesturePair(
            press: CommandAction(ControlCommand.clearAll),
          ),
        );
        setEngine(
          _tracksWith(const [
            Track(state: TrackState.playing, lengthFrames: 48000),
          ]),
        );
        when(() => looper.clearAll(any())).thenReturn(EngineResult.notReady);

        transport.press(PedalButton.stop, down: true);
        await pumpEventQueue();

        verify(() => looper.clearAll([0])).called(1);
        expect(transport.lastFrame?.isLit(PedalButton.stop), isFalse);
        transport.press(PedalButton.stop, down: false);
        await pumpEventQueue();
      });

      test(
        'normal Stop lights only on admission and clears on link loss',
        () async {
          setEngine(
            _tracksWith(const [
              Track(state: TrackState.playing, lengthFrames: 48000),
            ]),
          );
          cubit.setMode(InteractionMode.record);
          when(
            () => looper.setMute(
              muted: any(named: 'muted'),
              channel: any(named: 'channel'),
            ),
          ).thenReturn(EngineResult.notReady);
          transport.press(PedalButton.stop, down: true);
          await pumpEventQueue();
          expect(transport.lastFrame?.isLit(PedalButton.stop), isFalse);
          transport.press(PedalButton.stop, down: false);
          await pumpEventQueue();

          when(
            () => looper.setMute(
              muted: any(named: 'muted'),
              channel: any(named: 'channel'),
            ),
          ).thenReturn(EngineResult.ok);
          transport.press(PedalButton.stop, down: true);
          await pumpEventQueue();
          expect(transport.lastFrame?.isLit(PedalButton.stop), isTrue);

          transport.emit(
            const HelloMessage(
              protocolVersion: PedalLinkCodec.protocolVersion + 1,
              firmwareMajor: 1,
              firmwareMinor: 0,
            ),
          );
          await pumpEventQueue();
          transport.hello();
          await pumpEventQueue();
          expect(transport.lastFrame?.isLit(PedalButton.stop), isFalse);
        },
      );

      test('Mute Stop refusal leaves its contact dark', () async {
        setEngine(
          _tracksWith(const [
            Track(state: TrackState.playing, lengthFrames: 48000),
          ]),
        );
        cubit.setMode(InteractionMode.mute);
        when(
          () => looper.stopTrack(channel: any(named: 'channel')),
        ).thenReturn(EngineResult.notReady);
        transport.press(PedalButton.stop, down: true);
        await pumpEventQueue();
        verify(
          () => looper.stopTrack(channel: any(named: 'channel')),
        ).called(1);
        expect(transport.lastFrame?.isLit(PedalButton.stop), isFalse);
        transport.press(PedalButton.stop, down: false);
        await pumpEventQueue();
      });

      test(
        'an unbound FX Stop stays dark: it does nothing in FX mode',
        () async {
          trackChains[0] = [BuiltInEffect(type: TrackEffectType.drive)];
          cubit.setMode(InteractionMode.fx);
          transport.press(PedalButton.stop, down: true);
          await pumpEventQueue();
          verifyNever(
            () => looper.setTrackChainEnabled(
              channel: any(named: 'channel'),
              enabled: any(named: 'enabled'),
            ),
          );
          expect(transport.lastFrame?.isLit(PedalButton.stop), isFalse);
          transport.press(PedalButton.stop, down: false);
          await pumpEventQueue();
        },
      );

      test('Hold LED follows fired function, not unrelated Press', () async {
        await assign(
          PedalButton.track1,
          const ControlGesturePair(
            press: TrackOperationAction(
              operation: TrackOperation.mute,
              scope: FixedTrackScope(0),
            ),
            hold: TrackOperationAction(
              operation: TrackOperation.mute,
              scope: FixedTrackScope(1),
            ),
          ),
        );
        transport.press(PedalButton.track1, down: true);
        await pumpEventQueue();
        expect(transport.lastFrame?.trackLeds[0], PedalTrackLed.off);
        await Future<void>.delayed(const Duration(milliseconds: 850));
        setEngine(_tracksWith(const [Track(channel: 1, muted: true)]));
        await pumpEventQueue();
        expect(transport.lastFrame?.trackLeds[0], PedalTrackLed.blue);
        await cubit.setPedalSetup(
          cubit.state.pedalSetup.copyWith(
            palette: const PedalPalette().withChoice(
              PedalButton.track1,
              const BuiltInPaletteEntry(PedalPaletteColor.violet),
            ),
          ),
        );
        expect(transport.lastFrame?.trackLeds[0], PedalTrackLed.blue);
        expect(
          transport.lastFrame?.colorFor(PedalButton.track1),
          PedalPaletteColor.violet.color,
        );
        transport.press(PedalButton.track1, down: false);
        await pumpEventQueue();
        expect(transport.lastFrame?.trackLeds[0], PedalTrackLed.blue);
      });

      test(
        'shared Custom transport light follows its live target on both banks',
        () async {
          await assign(
            PedalButton.stop,
            const ControlGesturePair(
              press: TrackOperationAction(
                operation: TrackOperation.mute,
                scope: FixedTrackScope(0),
              ),
            ),
          );
          expect(transport.lastFrame?.isLit(PedalButton.stop), isFalse);
          transport.press(PedalButton.stop, down: true);
          await pumpEventQueue();
          setEngine(_tracksWith(const [Track(muted: true)]));
          await pumpEventQueue();
          expect(transport.lastFrame?.isLit(PedalButton.stop), isTrue);
          transport.press(PedalButton.stop, down: false);
          await pumpEventQueue();
          cubit.browseBank(1);
          await pumpEventQueue();
          expect(transport.lastFrame?.isLit(PedalButton.stop), isTrue);
          expect(transport.lastFrame?.isLit(PedalButton.bank), isTrue);
        },
      );
      test(
        'Custom transport selected light retargets after contact ends',
        () async {
          await assign(
            PedalButton.stop,
            const ControlGesturePair(
              press: TrackOperationAction(
                operation: TrackOperation.mute,
                scope: SelectedTrackScope(),
              ),
            ),
          );
          transport.press(PedalButton.stop, down: true);
          await pumpEventQueue();
          setEngine(_tracksWith(const [Track(muted: true)]));
          await pumpEventQueue();
          expect(transport.lastFrame?.isLit(PedalButton.stop), isTrue);
          transport.press(PedalButton.stop, down: false);
          await pumpEventQueue();
          cubit.selectTrack(1);
          await pumpEventQueue();
          expect(transport.lastFrame?.isLit(PedalButton.stop), isFalse);
        },
      );
    });

    // The FX-mode button matrix: every one of the ten controls is defined,
    // and the three inert ones are proven inert (A2/A4) — a stray stomp must
    // never erase the set.
    group('FX mode', () {
      /// Presses and releases [button] on the wire, letting the decoded event
      /// reach the cubit.
      Future<void> stomp(PedalButton button) async {
        transport
          ..press(button, down: true)
          ..press(button, down: false);
        await pumpEventQueue();
      }

      /// Holds [button] past the 800 ms long-press threshold, then releases.
      /// Real delays (not fake_async) — the wire events reach the cubit
      /// through the repository's stream, which a fake clock cannot pump.
      Future<void> hold(PedalButton button) async {
        transport.press(button, down: true);
        await pumpEventQueue();
        await Future<void>.delayed(const Duration(milliseconds: 850));
        transport.press(button, down: false);
        await pumpEventQueue();
      }

      setUp(() {
        setEngine(_emptyTracks());
        cubit.setMode(InteractionMode.fx);
      });

      test('a track stomp toggles that track Track-stage chain', () async {
        await stomp(PedalButton.track1);
        verify(
          () => looper.setTrackChainEnabled(channel: 0, enabled: false),
        ).called(1);

        await stomp(PedalButton.track1);
        verify(
          () => looper.setTrackChainEnabled(channel: 0, enabled: true),
        ).called(1);
      });

      test('track stomps are bank-aware (A3): bank B stomps 4..7', () async {
        cubit.browseBank(1);
        await stomp(PedalButton.track2);
        verify(
          () => looper.setTrackChainEnabled(channel: 5, enabled: false),
        ).called(1);
        verifyNever(
          () => looper.setTrackChainEnabled(channel: 1, enabled: false),
        );
      });

      test(
        'a stomp persists the chain envelope so a reboot keeps it',
        () async {
          await stomp(PedalButton.track1);
          expect(await settings.loadTrackFxChain(0), isNotNull);
        },
      );

      test('an unbound Stop is INERT in FX mode, tap and hold alike (pen '
          '10/03, #1229)', () async {
        trackChains[1] = [BuiltInEffect(type: TrackEffectType.drive)];

        await stomp(PedalButton.stop);
        await hold(PedalButton.stop);

        verifyNever(
          () => looper.setTrackChainEnabled(
            channel: any(named: 'channel'),
            enabled: any(named: 'enabled'),
          ),
        );
        expect(chainEnabled, isEmpty);
        expect(transport.lastFrame?.isLit(PedalButton.stop), isFalse);
      });

      test('stop() in FX mode changes no chain (#1229)', () async {
        trackChains[1] = [BuiltInEffect(type: TrackEffectType.drive)];
        cubit.stop();
        await pumpEventQueue();
        expect(chainEnabled, isEmpty);
      });

      test('Track FX off and Track FX on run from any assigned control, '
          'and off leaves a track with NO chain alone', () async {
        trackChains[1] = [BuiltInEffect(type: TrackEffectType.drive)];
        trackChains[5] = [BuiltInEffect(type: TrackEffectType.reverb)];
        // A stale bypass on a chain-less track, the state "on" exists to cure.
        chainEnabled[2] = false;
        await cubit.setPedalSetup(
          cubit.state.pedalSetup
              .withCustom(
                PedalButton.stop,
                bank: 0,
                pair: const ControlGesturePair(
                  press: CommandAction(ControlCommand.trackFxOff),
                ),
              )
              .withCustom(
                PedalButton.undo,
                bank: 0,
                pair: const ControlGesturePair(
                  press: CommandAction(ControlCommand.trackFxOn),
                ),
              ),
        );
        cubit.setMode(InteractionMode.custom);

        await stomp(PedalButton.stop);
        // A bypass persisted for an empty chain would silently mute the
        // effects added to that track later: only the real chains flip.
        expect(chainEnabled, {1: false, 2: false, 5: false});
        for (final channel in [0, 2, 3, 4, 6, 7]) {
          expect(await settings.loadTrackFxChain(channel), isNull);
        }

        await stomp(PedalButton.undo);
        // On is "all on", the empties included: a chain-less track can carry
        // a stale bypass this is the cure for.
        expect(chainEnabled, {1: true, 2: true, 5: true});
      });

      test(
        'Stop in Rec/Mute mode still acts on the PRESS (no gesture split)',
        () async {
          cubit.setMode(InteractionMode.record);
          setEngine(
            _tracksWith(const [
              Track(state: TrackState.playing, lengthFrames: 48000),
            ]),
          );
          transport.press(PedalButton.stop, down: true);
          await pumpEventQueue();
          verify(() => looper.setMute(muted: true)).called(1);
        },
      );

      test('Clear is INERT — a stray stomp never erases the set', () async {
        setEngine(
          _tracksWith(const [
            Track(state: TrackState.playing, lengthFrames: 48000),
          ]),
        );
        await stomp(PedalButton.clear);
        verifyNever(() => looper.clear(channel: any(named: 'channel')));
        expect(cubit.state.mode, InteractionMode.fx); // no home-and-reset
      });

      test('Rec/Play is INERT (reserved, A4)', () async {
        setEngine(
          _tracksWith(const [
            Track(state: TrackState.stopped, lengthFrames: 48000),
          ]),
        );
        await stomp(PedalButton.recPlay);
        verifyNever(() => looper.record(channel: any(named: 'channel')));
        verifyNever(() => looper.record());
        verifyNever(() => looper.play(channel: any(named: 'channel')));
        verifyNever(() => looper.play());
      });

      test(
        'Undo is INERT until the #219 contract — tap AND long-press',
        () async {
          await stomp(PedalButton.undo);
          await hold(PedalButton.undo); // past the redo threshold too
          verifyNever(() => looper.undo(channel: any(named: 'channel')));
          verifyNever(() => looper.undo());
          verifyNever(() => looper.redo(channel: any(named: 'channel')));
          verifyNever(() => looper.redo());
        },
      );

      test('Bank still switches banks', () async {
        await stomp(PedalButton.bank);
        expect(cubit.state.activeBank, 1);
        expect(cubit.state.cursor, 4);
      });

      test('the encoder still drives master gain', () async {
        // EncoderNavigation routes a stage turn here (#1276).
        cubit.encoderTurned(4);
        await pumpEventQueue();
        verify(() => looper.setMasterGain(any())).called(1);
      });

      test('a MODE hold only exits the FX door, on contact, without arming '
          'performance', () async {
        await hold(PedalButton.mode);
        expect(cubit.state.mode, InteractionMode.record);
        expect(performance.armedDirectory, isNull);
      });

      test('MODE is the FX face Exit: back to the mode FX was entered '
          'from, on contact (pen 10/03)', () async {
        transport.press(PedalButton.mode, down: true);
        await pumpEventQueue();
        expect(cubit.state.mode, InteractionMode.record);
        transport.press(PedalButton.mode, down: false);
        await pumpEventQueue();

        cubit
          ..setMode(InteractionMode.mute)
          ..setMode(InteractionMode.fx);
        await stomp(PedalButton.mode);
        expect(cubit.state.mode, InteractionMode.mute);
      });

      test('toggleTrackChain ignores out-of-range channels', () {
        cubit
          ..toggleTrackChain(-1)
          ..toggleTrackChain(8);
        verifyNever(
          () => looper.setTrackChainEnabled(
            channel: any(named: 'channel'),
            enabled: any(named: 'enabled'),
          ),
        );
      });

      test(
        'Track FX off over already-disabled chains writes nothing twice',
        () async {
          trackChains[1] = [BuiltInEffect(type: TrackEffectType.drive)];
          await cubit.setPedalSetup(
            cubit.state.pedalSetup.withCustom(
              PedalButton.stop,
              bank: 0,
              pair: const ControlGesturePair(
                press: CommandAction(ControlCommand.trackFxOff),
              ),
            ),
          );
          cubit.setMode(InteractionMode.custom);
          await stomp(PedalButton.stop);
          await stomp(PedalButton.stop);
          verify(
            () => looper.setTrackChainEnabled(channel: 1, enabled: false),
          ).called(1);
        },
      );
    });

    group('cursor / bank', () {
      test('selectTrack moves the cursor into its bank', () {
        cubit.selectTrack(5);
        expect(cubit.state.cursor, 5);
        expect(cubit.state.activeBank, 1);
        expect(cubit.state.bankBaseChannel, 4);
        expect(cubit.state.bankContains(5), isTrue);
        expect(cubit.state.bankContains(2), isFalse);
      });

      test('selectTrack ignores out-of-range channels', () {
        cubit
          ..selectTrack(-1)
          ..selectTrack(8);
        expect(cubit.state.cursor, 0);
      });

      test('browseBank reveals the bank WITHOUT moving the cursor', () {
        cubit.browseBank(1);
        expect(cubit.state.activeBank, 1);
        expect(cubit.state.cursor, 0); // browse only

        cubit
          ..browseBank(-1)
          ..browseBank(2);
        expect(cubit.state.activeBank, 1); // out-of-range ignored
      });

      test('toggleBankWithCursor moves the cursor to the new bank base', () {
        cubit.toggleBankWithCursor();
        expect(cubit.state.activeBank, 1);
        expect(cubit.state.cursor, 4);

        cubit.toggleBankWithCursor();
        expect(cubit.state.activeBank, 0);
        expect(cubit.state.cursor, 0);
      });
    });

    group('recPlay in Rec mode', () {
      test('drives the cursor track record cycle', () {
        cubit.recPlay();
        verify(() => looper.record()).called(1);
      });

      test('a foot Record press survives a single refusal', () async {
        // #1146: the engine refuses a fresh capture for one callback block
        // after an emptying; the repository owes the press one retry, so the
        // contact stays accepted (lit) while it resolves.
        when(
          () => looper.record(channel: any(named: 'channel')),
        ).thenReturn(EngineResult.notReady);
        when(() => looper.recordRetryPending(0)).thenReturn(true);

        transport.press(PedalButton.recPlay, down: true);
        await pumpEventQueue();
        verify(() => looper.record(channel: any(named: 'channel'))).called(1);
        expect(transport.lastFrame?.isLit(PedalButton.recPlay), isTrue);
        transport.press(PedalButton.recPlay, down: false);
        await pumpEventQueue();
        expect(transport.lastFrame?.isLit(PedalButton.recPlay), isFalse);
      });

      test(
        'a refused Record press with no retry owed keeps its contact dark',
        () async {
          when(
            () => looper.record(channel: any(named: 'channel')),
          ).thenReturn(EngineResult.notReady);

          transport.press(PedalButton.recPlay, down: true);
          await pumpEventQueue();
          expect(transport.lastFrame?.isLit(PedalButton.recPlay), isFalse);
          transport.press(PedalButton.recPlay, down: false);
          await pumpEventQueue();
        },
      );

      test('unmutes and overdubs a muted, still-running track', () {
        setEngine(
          _tracksWith(const [
            Track(state: TrackState.playing, muted: true, lengthFrames: 48000),
          ]),
        );
        cubit.recPlay();
        verify(() => looper.setMute(muted: false)).called(1);
        verify(() => looper.record()).called(1);
      });

      test('resumes a muted, parked track without overdub', () {
        setEngine(
          _tracksWith(const [
            Track(state: TrackState.stopped, muted: true, lengthFrames: 48000),
          ]),
        );
        cubit.recPlay();
        verify(() => looper.setMute(muted: false)).called(1);
        verify(() => looper.play()).called(1);
        verifyNever(() => looper.record(channel: any(named: 'channel')));
      });

      test('takeLocked suppresses recPlay', () {
        final ownedFade = testFadeSettings();
        final locked = ControlCubit(
          fxPersistence: FxChainPersistence(looper: looper),
          looper: looper,
          mixSettings: testMixSettings(looper),
          pedal: pedal,
          settings: settings,
          performance: performance,
          takeLocked: () => true,
          fadeSettings: ownedFade,
          ownedValues: OwnedValuePort(
            looper: looper,
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
        addTearDown(locked.close);
        locked.recPlay();
        verifyNever(() => looper.record());
      });

      test('takeLocked suppresses rec-mode trackPressed', () {
        final ownedFade = testFadeSettings();
        final locked = ControlCubit(
          fxPersistence: FxChainPersistence(looper: looper),
          looper: looper,
          mixSettings: testMixSettings(looper),
          pedal: pedal,
          settings: settings,
          performance: performance,
          takeLocked: () => true,
          fadeSettings: ownedFade,
          ownedValues: OwnedValuePort(
            looper: looper,
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
        addTearDown(locked.close);
        locked.trackPressed(2);
        expect(locked.state.cursor, 0);
      });

      test('takeLocked suppresses togglePerformanceRecord', () async {
        final ownedFade = testFadeSettings();
        final locked = ControlCubit(
          fxPersistence: FxChainPersistence(looper: looper),
          looper: looper,
          mixSettings: testMixSettings(looper),
          pedal: pedal,
          settings: settings,
          performance: performance,
          takeLocked: () => true,
          fadeSettings: ownedFade,
          ownedValues: OwnedValuePort(
            looper: looper,
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
        addTearDown(locked.close);
        locked.togglePerformanceRecord();
        await pumpEventQueue();
        expect(performance.armedDirectory, isNull);
      });

      test('takeLocked suppresses pedal Clear', () async {
        final lockedTransport = FakePedalLink();
        final lockedPedal = PedalRepository(lockedTransport);
        lockedTransport.hello();
        await pumpEventQueue();
        addTearDown(lockedPedal.dispose);
        final ownedFade = testFadeSettings();
        final locked = ControlCubit(
          fxPersistence: FxChainPersistence(looper: looper),
          looper: looper,
          mixSettings: testMixSettings(looper),
          pedal: lockedPedal,
          settings: settings,
          performance: performance,
          takeLocked: () => true,
          fadeSettings: ownedFade,
          ownedValues: OwnedValuePort(
            looper: looper,
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
        addTearDown(locked.close);
        setEngine(
          _tracksWith(const [
            Track(state: TrackState.playing, lengthFrames: 48000),
          ]),
        );
        lockedTransport.press(PedalButton.clear, down: true);
        await Future<void>.delayed(Duration.zero);
        verifyNever(() => looper.clear());
        verifyNever(() => looper.clear(channel: any(named: 'channel')));
      });
    });

    group('recPlay in Mute mode', () {
      test('parked: resumes the latched set and consumes it', () {
        setEngine(
          _tracksWith(const [
            Track(state: TrackState.stopped, lengthFrames: 48000),
            Track(channel: 1, state: TrackState.stopped, lengthFrames: 48000),
          ]),
        );
        cubit
          ..toggleMode() // -> mute, parkedResume = {0, 1}
          ..recPlay();
        verify(() => looper.play()).called(1);
        verify(() => looper.play(channel: 1)).called(1);
        verifyNever(() => looper.play(channel: 2));
        // A deferred launch (count-in, quantized) leaves the loop parked, so
        // the membership is kept until the loop is observed running.
        expect(cubit.state.parkedResume, {0, 1});
        setEngine(
          _tracksWith(const [
            Track(state: TrackState.playing, lengthFrames: 48000),
            Track(channel: 1, state: TrackState.playing, lengthFrames: 48000),
          ]),
        );
        expect(cubit.state.parkedResume, isEmpty); // consumed
      });

      test('a running snapshot before Stop lands keeps the latched set', () {
        setEngine(
          _tracksWith(const [
            Track(state: TrackState.playing, lengthFrames: 48000),
            Track(channel: 1, state: TrackState.playing, lengthFrames: 48000),
          ]),
        );
        cubit
          ..toggleMode() // Mute while running
          ..stop(); // latches the running set
        expect(cubit.state.parkedResume, {0, 1});
        // A poll lands before the engine applies the stops: still running.
        setEngine(
          _tracksWith(const [
            Track(state: TrackState.playing, lengthFrames: 48000),
            Track(channel: 1, state: TrackState.playing, lengthFrames: 48000),
          ]),
        );
        expect(cubit.state.parkedResume, {0, 1});
        setEngine(
          _tracksWith(const [
            Track(state: TrackState.stopped, lengthFrames: 48000),
            Track(channel: 1, state: TrackState.stopped, lengthFrames: 48000),
          ]),
        );
        expect(
          cubit.state.parkedResume,
          {0, 1},
          reason: 'parked with the latch',
        );
      });

      test('a second Rec/Play during a deferred launch keeps the deselected '
          'member out', () {
        setEngine(
          _tracksWith(const [
            Track(state: TrackState.stopped, lengthFrames: 48000),
            Track(channel: 1, state: TrackState.stopped, lengthFrames: 48000),
          ]),
        );
        cubit
          ..toggleMode() // parkedResume = {0, 1}
          ..trackPressed(1); // deselect track 2 while parked
        expect(cubit.state.parkedResume, {0});
        cubit
          ..recPlay() // deferred: the loop stays parked
          ..recPlay(); // toggles the same member, cancelling the launch
        verify(() => looper.play()).called(2);
        verifyNever(() => looper.play(channel: 1));
        verifyNever(() => looper.setMute(muted: false, channel: 1));
        expect(cubit.state.parkedResume, {0});
      });

      test('parked with an empty resume set falls back to ALL content', () {
        // Enter Play with nothing recorded: the latch is empty. Content
        // appearing afterwards (e.g. a session load while parked) never
        // re-latches — the reducer only prunes — so Rec/Play falls back.
        cubit.toggleMode();
        expect(cubit.state.parkedResume, isEmpty);
        setEngine(
          _tracksWith(const [
            Track(state: TrackState.stopped, lengthFrames: 48000),
            Track(channel: 1, state: TrackState.stopped, lengthFrames: 48000),
          ]),
        );
        cubit.recPlay();
        verify(() => looper.play()).called(1);
        verify(() => looper.play(channel: 1)).called(1);
      });

      test('refused deselected mute prevents parked transport resume', () {
        setEngine(
          _tracksWith(const [
            Track(state: TrackState.stopped, lengthFrames: 48000),
            Track(channel: 1, state: TrackState.stopped, lengthFrames: 48000),
          ]),
        );
        cubit
          ..toggleMode()
          ..trackPressed(1);
        expect(cubit.state.parkedResume, {0});
        when(
          () => looper.setMute(muted: true, channel: 1),
        ).thenReturn(EngineResult.invalid);
        cubit.recPlay();
        verifyNever(() => looper.play(channel: any(named: 'channel')));
        expect(cubit.state.parkedResume, {0});
      });

      for (final parked in [true, false]) {
        test(
          'later mute refusal prevents every play (parked: $parked)',
          () async {
            setEngine(
              _tracksWith([
                Track(
                  state: parked ? TrackState.stopped : TrackState.playing,
                  lengthFrames: 48000,
                ),
                const Track(
                  channel: 1,
                  state: TrackState.stopped,
                  muted: true,
                  lengthFrames: 48000,
                ),
                const Track(
                  channel: 2,
                  state: TrackState.stopped,
                  lengthFrames: 48000,
                ),
              ]),
            );
            cubit.toggleMode();
            final before = cubit.state.parkedResume;
            when(
              () => looper.setMute(muted: false, channel: 1),
            ).thenReturn(EngineResult.invalid);
            cubit.recPlay();
            verifyNever(() => looper.play(channel: any(named: 'channel')));
            verify(() => looper.setMute(muted: false, channel: 2)).called(1);
            expect(cubit.state.parkedResume, before);
            await pumpEventQueue();
            expect(await settings.loadLaneMute(0, 0), isFalse);
            when(
              () => looper.setMute(muted: false, channel: 1),
            ).thenReturn(EngineResult.ok);
            cubit.recPlay();
            for (var channel = 0; channel < 3; channel++) {
              verify(() => looper.play(channel: channel)).called(1);
            }
            // Kept until a snapshot shows the loop running.
            expect(cubit.state.parkedResume, before);
          },
        );
      }

      test('nothing recorded: a no-op', () {
        cubit
          ..toggleMode()
          ..recPlay();
        verifyNever(() => looper.play(channel: any(named: 'channel')));
      });

      test('running: expands to the whole content set', () {
        setEngine(
          _tracksWith(const [
            Track(state: TrackState.playing, lengthFrames: 48000),
            Track(channel: 1, state: TrackState.stopped, lengthFrames: 48000),
          ]),
        );
        cubit
          ..toggleMode()
          ..recPlay();
        // ch1 (parked content) joins; ch0 is re-asserted too.
        verify(() => looper.play()).called(1);
        verify(() => looper.play(channel: 1)).called(1);
      });

      test('running with the full audible set already in: a no-op', () {
        setEngine(
          _tracksWith(const [
            Track(state: TrackState.playing, lengthFrames: 48000),
            Track(channel: 1, state: TrackState.playing, lengthFrames: 48000),
          ]),
        );
        cubit
          ..toggleMode()
          ..recPlay();
        verifyNever(() => looper.play(channel: any(named: 'channel')));
        verifyNever(() => looper.stopTrack(channel: any(named: 'channel')));
      });
    });

    group('stop', () {
      test(
        'Rec Stop cancels before snapshot publication without toggling record',
        () {
          cubit.stop();
          verifyInOrder([
            () => looper.stopRecordControl(channel: 0),
            () => looper.setMute(muted: true),
          ]);
          verifyNever(() => looper.record(channel: any(named: 'channel')));
        },
      );

      test('refused Rec Stop leaves mute and playback unchanged', () {
        when(
          () => looper.stopRecordControl(channel: 0),
        ).thenReturn(EngineResult.notReady);
        cubit.stop();
        verifyNever(
          () => looper.setMute(
            muted: any(named: 'muted'),
            channel: any(named: 'channel'),
          ),
        );
        verifyNever(() => looper.stopTrack(channel: any(named: 'channel')));
        verifyNever(() => looper.record(channel: any(named: 'channel')));
      });

      test(
        'Mute Stop cancels an unpublished countdown without touching grid arms',
        () {
          cubit
            ..setMode(InteractionMode.mute)
            ..stop();
          verify(() => looper.cancelCountIn()).called(1);
          verifyNever(() => looper.cancelArm(channel: any(named: 'channel')));
          verifyNever(() => looper.record(channel: any(named: 'channel')));
        },
      );

      test(
        'refused Count-in cancellation leaves Mute Stop and resume intact',
        () {
          setEngine(
            _tracksWith(const [
              Track(state: TrackState.playing, lengthFrames: 48000),
            ]),
          );
          cubit.setMode(InteractionMode.mute);
          final resume = cubit.state.parkedResume;
          when(() => looper.cancelCountIn()).thenReturn(EngineResult.invalid);
          cubit.stop();
          expect(cubit.state.parkedResume, resume);
          verifyNever(() => looper.stopTrack(channel: any(named: 'channel')));
        },
      );

      test('Rec mode: mutes the cursor track', () {
        setEngine(
          _tracksWith(const [
            Track(state: TrackState.playing, lengthFrames: 48000),
            Track(channel: 1, state: TrackState.playing, lengthFrames: 48000),
          ]),
        );
        cubit.stop();
        verify(() => looper.setMute(muted: true)).called(1);
        // ch1 keeps sounding: no park.
        verifyNever(() => looper.stopTrack(channel: any(named: 'channel')));
      });

      test('Rec mode: finalizes a capture before muting', () {
        setEngine(
          _tracksWith(const [Track(state: TrackState.recording)]),
        );
        cubit.stop();
        verify(() => looper.stopRecordControl(channel: 0)).called(1);
        verify(() => looper.setMute(muted: true)).called(1);
      });

      test('Rec mode: muting the sole audible track parks everything', () {
        setEngine(
          _tracksWith(const [
            Track(state: TrackState.playing, lengthFrames: 48000),
          ]),
        );
        cubit.stop();
        verify(() => looper.setMute(muted: true)).called(1);
        verify(() => looper.stopTrack()).called(1);
      });

      test(
        'Mute mode: parks every running track and latches the resume set',
        () {
          setEngine(
            _tracksWith(const [
              Track(state: TrackState.playing, lengthFrames: 48000),
              Track(
                channel: 1,
                state: TrackState.playing,
                muted: true,
                lengthFrames: 48000,
              ),
            ]),
          );
          cubit
            ..toggleMode()
            ..stop();
          // Muted-but-running ch1 is frozen too (mute silences, park
          // freezes).
          verify(() => looper.stopTrack()).called(1);
          verify(() => looper.stopTrack(channel: 1)).called(1);
          // The latch captured the running set at INTENT time.
          expect(cubit.state.parkedResume, {0, 1});
        },
      );

      test('Mute mode: stop while already parked keeps the resume set', () {
        setEngine(
          _tracksWith(const [
            Track(state: TrackState.stopped, lengthFrames: 48000),
          ]),
        );
        cubit
          ..toggleMode() // parkedResume = {0}
          ..stop();
        verifyNever(() => looper.stopTrack(channel: any(named: 'channel')));
        expect(cubit.state.parkedResume, {0});
      });
    });

    group('trackPressed in Rec mode', () {
      test('selects the track while idle', () {
        cubit.trackPressed(2);
        expect(cubit.state.cursor, 2);
        verifyNever(() => looper.record(channel: any(named: 'channel')));
      });

      test('finishes the loop when the capturing track is pressed', () {
        setEngine(
          _tracksWith(const [Track(state: TrackState.recording)]),
        );
        cubit.trackPressed(0);
        verify(() => looper.record()).called(1);
      });

      test('hands off a live recording to the pressed track', () {
        setEngine(
          _tracksWith(const [Track(state: TrackState.recording)]),
        );
        cubit.trackPressed(2);
        verify(() => looper.record()).called(1); // finalize
        verify(() => looper.record(channel: 2)).called(1); // start pressed
        expect(cubit.state.cursor, 2);
      });
    });

    group('trackPressed in Mute mode', () {
      test('an empty track is a no-op', () {
        cubit
          ..toggleMode()
          ..trackPressed(3);
        verifyNever(() => looper.play(channel: any(named: 'channel')));
        expect(cubit.state.parkedResume, isEmpty);
      });

      test('parked: toggles resume membership, unmuting a joining track', () {
        setEngine(
          _tracksWith(const [
            Track(state: TrackState.stopped, lengthFrames: 48000),
            Track(
              channel: 1,
              state: TrackState.stopped,
              muted: true,
              lengthFrames: 48000,
            ),
          ]),
        );
        cubit
          ..toggleMode() // parkedResume = {0, 1}
          ..trackPressed(0); // leave the set
        expect(cubit.state.parkedResume, {1});
        verifyNever(() => looper.stopTrack(channel: any(named: 'channel')));

        cubit.trackPressed(0); // rejoin
        expect(cubit.state.parkedResume, {0, 1});

        // A muted member leaving then rejoining: the rejoin is a muted
        // NON-member arming, so it unmutes to read green.
        cubit.trackPressed(1); // leave -> {0}
        expect(cubit.state.parkedResume, {0});
        cubit.trackPressed(1); // rejoin: muted non-member -> unmute
        verify(() => looper.setMute(muted: false, channel: 1)).called(1);
        expect(cubit.state.parkedResume, {0, 1});
      });

      test('running mute persists the accepted lane value', () async {
        setEngine(
          _tracksWith(const [
            Track(state: TrackState.playing, lengthFrames: 48000),
            Track(channel: 1, state: TrackState.playing, lengthFrames: 48000),
          ]),
        );
        cubit
          ..toggleMode()
          ..trackPressed(0);
        await pumpEventQueue();
        expect(await settings.loadLaneMute(0, 0), isTrue);
      });

      test('refused last-track mute cannot park the transport', () {
        setEngine(
          _tracksWith(const [
            Track(state: TrackState.playing, lengthFrames: 48000),
          ]),
        );
        when(
          () => looper.setMute(muted: true),
        ).thenReturn(EngineResult.invalid);
        cubit
          ..toggleMode()
          ..trackPressed(0);
        verifyNever(() => looper.stopTrack(channel: any(named: 'channel')));
      });

      test(
        'refused parked unmute cannot play or consume resume membership',
        () {
          setEngine(
            _tracksWith(const [
              Track(
                state: TrackState.stopped,
                muted: true,
                lengthFrames: 48000,
              ),
            ]),
          );
          when(
            () => looper.setMute(muted: false),
          ).thenReturn(EngineResult.invalid);
          cubit.toggleMode();
          final before = cubit.state.parkedResume;
          cubit.recPlay();
          verifyNever(() => looper.play(channel: any(named: 'channel')));
          expect(cubit.state.parkedResume, before);
        },
      );

      test('running: a live track press toggles its mute', () {
        setEngine(
          _tracksWith(const [
            Track(state: TrackState.playing, lengthFrames: 48000),
            Track(channel: 1, state: TrackState.playing, lengthFrames: 48000),
          ]),
        );
        cubit
          ..toggleMode()
          ..trackPressed(0);
        verify(() => looper.setMute(muted: true)).called(1);
        // ch1 keeps sounding: no park.
        verifyNever(() => looper.stopTrack(channel: any(named: 'channel')));

        // Engine reflects the mute; pressing again unmutes (out-of-mix join).
        setEngine(
          _tracksWith(const [
            Track(state: TrackState.playing, muted: true, lengthFrames: 48000),
            Track(channel: 1, state: TrackState.playing, lengthFrames: 48000),
          ]),
        );
        cubit.trackPressed(0);
        verify(() => looper.setMute(muted: false)).called(1);
      });

      test('muting the last audible track parks with an empty latch', () {
        setEngine(
          _tracksWith(const [
            Track(state: TrackState.playing, muted: true, lengthFrames: 48000),
            Track(channel: 1, state: TrackState.playing, lengthFrames: 48000),
          ]),
        );
        cubit
          ..toggleMode()
          ..trackPressed(1); // mute the only audible track
        verify(() => looper.setMute(muted: true, channel: 1)).called(1);
        // Every running track parks (the muted one too).
        verify(() => looper.stopTrack()).called(1);
        verify(() => looper.stopTrack(channel: 1)).called(1);
        // Empty latch: the next Rec/Play falls back to ALL content.
        expect(cubit.state.parkedResume, isEmpty);
      });

      test('running: a parked content track joins the mix', () {
        setEngine(
          _tracksWith(const [
            Track(state: TrackState.playing, lengthFrames: 48000),
            Track(
              channel: 1,
              state: TrackState.stopped,
              muted: true,
              lengthFrames: 48000,
            ),
          ]),
        );
        cubit
          ..toggleMode()
          ..trackPressed(1);
        verify(() => looper.setMute(muted: false, channel: 1)).called(1);
        verify(() => looper.play(channel: 1)).called(1);
      });
    });

    group('clearAll', () {
      test(
        'wipes content AND redo-able tracks, unmuting and persisting',
        () async {
          setEngine(
            _tracksWith(const [
              Track(
                state: TrackState.playing,
                muted: true,
                lengthFrames: 48000,
              ),
              Track(channel: 1, redoDepth: 2), // undone-to-empty
            ]),
          );
          cubit
            ..toggleMode()
            ..selectTrack(5);
          unawaited(cubit.clearAll());

          // One grouped edit: content AND the redo-able track, nothing else.
          verify(() => looper.clearAll([0, 1])).called(1);
          verifyNever(() => looper.clear(channel: any(named: 'channel')));
          verify(() => looper.setMute(muted: false)).called(1);
          verify(() => looper.setMute(muted: false, channel: 1)).called(1);

          // The whole-rig reset: overlay home again.
          expect(cubit.state.mode, InteractionMode.record);
          expect(cubit.state.cursor, 0);
          expect(cubit.state.parkedResume, isEmpty);

          // The unmute persists per lane (lane 0 default when none reported).
          await Future<void>.delayed(Duration.zero);
          expect(await settings.loadLaneMute(0, 0), isFalse);
          expect(await settings.loadLaneMute(1, 0), isFalse);
        },
      );

      test(
        'while armed, persistLiveLanes runs BEFORE any looper.clear (D-CLEAR)',
        () async {
          final log = <String>[];
          final recordingPerformance = _RecordingPerformanceRepository(
            log: log,
            engine: FakeAudioEngine(),
            exportsRoot: () async => tempDir.path,
          );
          addTearDown(recordingPerformance.dispose);
          final ownedFade = testFadeSettings();
          final armedCubit = ControlCubit(
            fxPersistence: FxChainPersistence(looper: looper),
            looper: looper,
            mixSettings: testMixSettings(looper),
            pedal: pedal,
            settings: settings,
            performance: recordingPerformance,
            fadeSettings: ownedFade,
            ownedValues: OwnedValuePort(
              looper: looper,
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
          addTearDown(armedCubit.close);

          await recordingPerformance.arm();
          await pumpEventQueue(); // deliver captureStatus.armed to the cubit

          setEngine(
            _tracksWith(const [
              Track(state: TrackState.playing, lengthFrames: 48000),
            ]),
          );
          when(() => looper.clearAll(any())).thenAnswer((_) {
            log.add('looper.clearAll');
            return EngineResult.ok;
          });

          await armedCubit.clearAll();

          expect(log, ['persistLiveLanes', 'looper.clearAll']);
        },
      );

      test('while NOT armed, clearAll never calls persistLiveLanes', () async {
        setEngine(
          _tracksWith(const [
            Track(state: TrackState.playing, lengthFrames: 48000),
          ]),
        );
        final log = <String>[];
        final unarmedPerformance = _RecordingPerformanceRepository(
          log: log,
          engine: FakeAudioEngine(),
          exportsRoot: () async => tempDir.path,
        );
        addTearDown(unarmedPerformance.dispose);
        final ownedFade = testFadeSettings();
        final unarmedCubit = ControlCubit(
          fxPersistence: FxChainPersistence(looper: looper),
          looper: looper,
          mixSettings: testMixSettings(looper),
          pedal: pedal,
          settings: settings,
          performance: unarmedPerformance,
          fadeSettings: ownedFade,
          ownedValues: OwnedValuePort(
            looper: looper,
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
        addTearDown(unarmedCubit.close);

        await unarmedCubit.clearAll();

        expect(log, isEmpty);
        verify(() => looper.clearAll([0])).called(1);
      });

      // The armed path is the only one that awaits, so it is the only one whose
      // emit can land on a closed cubit. The engine clear still has to happen —
      // it is what the user asked for, and the looper outlives the console.
      test(
        'while armed, clearAll survives the console closing mid-persist',
        () async {
          final log = <String>[];
          final recordingPerformance = _RecordingPerformanceRepository(
            log: log,
            engine: FakeAudioEngine(),
            exportsRoot: () async => tempDir.path,
          );
          addTearDown(recordingPerformance.dispose);
          final ownedFade = testFadeSettings();
          final armedCubit = ControlCubit(
            fxPersistence: FxChainPersistence(looper: looper),
            looper: looper,
            mixSettings: testMixSettings(looper),
            pedal: pedal,
            settings: settings,
            performance: recordingPerformance,
            fadeSettings: ownedFade,
            ownedValues: OwnedValuePort(
              looper: looper,
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
          addTearDown(armedCubit.close);

          await recordingPerformance.arm();
          await pumpEventQueue(); // deliver captureStatus.armed to the cubit

          setEngine(
            _tracksWith(const [
              Track(state: TrackState.playing, lengthFrames: 48000),
            ]),
          );

          recordingPerformance.persistGate = Completer<void>();
          final pending = armedCubit.clearAll();
          await pumpEventQueue();
          await armedCubit.close();
          recordingPerformance.persistGate!.complete();

          await expectLater(pending, completes);
          verify(() => looper.clearAll([0])).called(1);
        },
      );
    });

    group('undoClearAll', () {
      test('delegates whole-rig recovery to the repository', () {
        when(() => looper.undoClearAll()).thenReturn(EngineResult.ok);
        setEngine(
          _tracksWith(const [
            Track(clearRestore: true),
            Track(channel: 1, state: TrackState.playing, lengthFrames: 48000),
          ]),
        );

        cubit.undoClearAll();

        // The repository owns the group and the per-track fallback; the cubit
        // never picks a channel itself.
        verify(() => looper.undoClearAll()).called(1);
        verifyNever(() => looper.undo(channel: any(named: 'channel')));
        verifyNever(() => looper.undo());
      });

      test(
        'does not re-home the overlay (unlike clearAll)',
        () {
          setEngine(_tracksWith(const [Track(channel: 2, clearRestore: true)]));
          cubit
            ..toggleMode() // leave record mode
            ..selectTrack(5); // move the cursor off home
          final before = cubit.state;

          cubit.undoClearAll();

          // Recovery restores the rig the user had — cursor and mode included.
          expect(cubit.state.mode, before.mode);
          expect(cubit.state.cursor, before.cursor);
        },
      );

      test(
        'clearAll bumps clearAllPulse when a content track is cleared',
        () async {
          setEngine(
            _tracksWith(const [
              Track(state: TrackState.playing, lengthFrames: 48000),
            ]),
          );
          final before = cubit.state.clearAllPulse;

          await cubit.clearAll();

          // The pulse is the cue the tracks view's undo toast listens for.
          expect(cubit.state.clearAllPulse, before + 1);
        },
      );

      test(
        'clearAll leaves clearAllPulse untouched when nothing to restore',
        () async {
          setEngine(_emptyTracks());
          final before = cubit.state.clearAllPulse;

          await cubit.clearAll();

          expect(cubit.state.clearAllPulse, before);
        },
      );
    });

    group('performance recording (D-PEDAL)', () {
      test(
        'togglePerformanceRecord arms the repository when unarmed, then '
        'disarms it on a second call',
        () async {
          expect(performance.armedDirectory, isNull);

          final armed = awaitStatus(
            performance,
            PerformanceCaptureStatus.armed,
          );
          cubit.togglePerformanceRecord();
          await armed;
          expect(performance.armedDirectory, isNotNull);

          // Past disarm's double-press guard window (D-GUARD) — this test
          // proves the toggle mechanic, not the guard itself.
          clock = clock.add(PerformanceRepository.disarmGuardWindow * 2);

          // `done`, not merely "no longer armed": disarm passes through
          // `finalizing` and only clears the directory at the end of it, so a
          // wait that stops at the first non-armed status reads it too early.
          final disarmed = awaitStatus(
            performance,
            PerformanceCaptureStatus.done,
          );
          cubit.togglePerformanceRecord();
          await disarmed;
          expect(performance.armedDirectory, isNull);
        },
      );

      test(
        'the pedal arm stamps the provider chains into the snapshot',
        () async {
          // The pedal gesture must record the same rig the toolbar path does —
          // before this was wired both armed with an empty chain set, so a
          // capture documented no FX at all.
          final ownedFade = testFadeSettings();
          final wired = ControlCubit(
            fxPersistence: FxChainPersistence(looper: looper),
            looper: looper,
            mixSettings: testMixSettings(looper),
            pedal: pedal,
            settings: settings,
            performance: performance,
            currentChains: () => const PerformanceChains(
              monitors: [
                PerformanceMonitorState(
                  input: 1,
                  enabled: true,
                  outputMask: 0x2,
                  volume: 1,
                  muted: false,
                  effects: [],
                ),
              ],
              limiterEnabled: true,
              limiterCeiling: 0.8,
            ),
            fadeSettings: ownedFade,
            ownedValues: OwnedValuePort(
              looper: looper,
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
          addTearDown(wired.close);

          final armed = awaitStatus(
            performance,
            PerformanceCaptureStatus.armed,
          );
          wired.togglePerformanceRecord();
          await armed;

          final snapshot =
              jsonDecode(
                    File(
                      '${performance.armedDirectory}/arm-snapshot.json',
                    ).readAsStringSync(),
                  )
                  as Map<String, dynamic>;
          expect(snapshot['limiterOn'], isTrue);
          expect(snapshot['limiterCeiling'], 0.8);
          expect(
            (snapshot['monitors'] as List).single,
            containsPair('input', 1),
          );
        },
      );

      test(
        '_onPerformanceStatus reactivity: an external arm() (bypassing '
        "this cubit's own method) is still reflected in the projected frame",
        () async {
          transport.sent.clear();

          // Drive the repository directly — not through
          // cubit.togglePerformanceRecord() — to prove the cubit reacts to
          // the shared captureStatus stream regardless of who triggered it
          // (mirrors PerformanceRecorderCubit's own reactive design).
          await performance.arm();
          await pumpEventQueue();

          final frame = transport.lastFrame;
          expect(frame?.performanceArmed, isTrue);

          await performance.disarmAndFinalize();
          await pumpEventQueue();

          final disarmedFrame = transport.lastFrame;
          expect(disarmedFrame?.performanceArmed, isFalse);
        },
      );
    });

    group('undo / redo / encoder', () {
      test('undo and redo pass straight through to the repository', () {
        cubit
          ..undo(3)
          ..redo(5);
        verify(() => looper.undo(channel: 3)).called(1);
        verify(() => looper.redo(channel: 5)).called(1);
        verifyNever(() => looper.clear(channel: any(named: 'channel')));
      });

      test('encoderTurned accumulates the master gain and clamps at 0', () {
        cubit.encoderTurned(-8); // 1.0 - 8/64
        final captured = verify(
          () => looper.setMasterGain(captureAny()),
        ).captured;
        expect(captured.single, closeTo(1 - 8 / 64, 1e-9));

        cubit.encoderTurned(-64); // clamps at 0
        final clamped = verify(
          () => looper.setMasterGain(captureAny()),
        ).captured;
        expect(clamped.single, 0.0);
      });
    });

    group('looper reducer (the invalidation table)', () {
      test('clamps the cursor when the track list shrinks', () {
        cubit.selectTrack(7);
        expect(cubit.state.cursor, 7);

        setEngine(_emptyTracks(4));
        expect(cubit.state.cursor, 3);
        expect(cubit.state.activeBank, 0); // follows the clamped cursor
      });

      test('prunes parkedResume of emptied tracks', () {
        setEngine(
          _tracksWith(const [
            Track(state: TrackState.stopped, lengthFrames: 48000),
            Track(channel: 1, state: TrackState.stopped, lengthFrames: 48000),
          ]),
        );
        cubit.toggleMode(); // parkedResume = {0, 1}
        // Track 1 empties (undo-to-empty / clear): it drops from the set.
        setEngine(
          _tracksWith(const [
            Track(state: TrackState.stopped, lengthFrames: 48000),
          ]),
        );
        expect(cubit.state.parkedResume, {0});
      });

      test('keeps capturing tracks in the stored sets', () {
        setEngine(
          _tracksWith(const [Track(state: TrackState.recording)]),
        );
        cubit.toggleMode(); // capture survives; parkedResume = {0}
        expect(cubit.state.parkedResume, {0});
        setEngine(
          _tracksWith(const [Track(state: TrackState.recording)]),
        );
        expect(cubit.state.parkedResume, {0}); // finishing a loop: kept
      });

      test('a no-change snapshot does not emit', () {
        final emits = <ControlState>[];
        final sub = cubit.stream.listen(emits.add);

        setEngine(_emptyTracks());
        expect(emits, isEmpty);
        unawaited(sub.cancel());
      });
    });

    group('pedal decode (events in via PedalRepository)', () {
      test('Rec/Play decodes into the record intent on the cursor', () async {
        transport.press(PedalButton.recPlay, down: true);
        await pumpEventQueue();
        verify(() => looper.record()).called(1);
      });

      test('Mode toggles the shared mode', () async {
        // A tap (press + quick release) — mode now rides the same
        // tap-vs-long-press split as undo (D-PEDAL): a bare press alone no
        // longer toggles it.
        transport
          ..press(PedalButton.mode, down: true)
          ..press(PedalButton.mode, down: false);
        await pumpEventQueue();
        expect(cubit.state.mode, InteractionMode.mute);
      });

      test('Bank toggles the active bank and moves the cursor', () async {
        transport
          ..press(PedalButton.bank, down: true)
          ..press(PedalButton.bank, down: false);
        await pumpEventQueue();
        expect(cubit.state.activeBank, 1);
        expect(cubit.state.cursor, 4);
      });

      test('a track press targets the visible bank base', () async {
        transport
          ..press(PedalButton.bank, down: true)
          ..press(PedalButton.bank, down: false); // -> bank B
        await pumpEventQueue();
        transport.press(PedalButton.track3, down: true);
        await pumpEventQueue();
        // track3 == index 2, bank B base 4 -> channel 6 (idle press selects).
        expect(cubit.state.cursor, 6);
      });

      test('the encoder drives the master gain', () async {
        cubit.encoderTurned(-8); // -8 detents, routed by EncoderNavigation
        await pumpEventQueue();
        verify(() => looper.setMasterGain(any())).called(1);
      });

      test('Clear decodes into the unified clear-all', () async {
        setEngine(
          _tracksWith(const [
            Track(state: TrackState.playing, muted: true, lengthFrames: 48000),
            Track(channel: 1, state: TrackState.playing, lengthFrames: 48000),
          ]),
        );
        transport.press(PedalButton.clear, down: true);
        await pumpEventQueue();

        verify(() => looper.clearAll([0, 1])).called(1);
        verifyNever(() => looper.clear(channel: any(named: 'channel')));
        verify(() => looper.setMute(muted: false)).called(1);
        verify(() => looper.setMute(muted: false, channel: 1)).called(1);
        expect(cubit.state.mode, InteractionMode.record);
        expect(cubit.state.cursor, 0);
      });

      group('undo press timing', () {
        test('tap undoes the cursor track', () async {
          transport
            ..press(PedalButton.undo, down: true) // press
            ..press(PedalButton.undo, down: false); // quick release == tap
          await pumpEventQueue();

          verify(() => looper.undo()).called(1);
          verifyNever(() => looper.redo(channel: any(named: 'channel')));
          verifyNever(() => looper.clear(channel: any(named: 'channel')));
        });

        test('the undo target is latched at press time', () async {
          transport.press(PedalButton.undo, down: true); // press, cursor 0
          await pumpEventQueue();
          // An on-screen click mid-hold must not retarget the committed
          // action.
          cubit.selectTrack(3);
          transport.press(PedalButton.undo, down: false);
          await pumpEventQueue();

          verify(() => looper.undo()).called(1); // channel 0, not 3
          verifyNever(() => looper.undo(channel: 3));
        });

        test('long-press redoes instead', () async {
          transport.press(PedalButton.undo, down: true);
          // Default long-press threshold is 800 ms.
          await Future<void>.delayed(const Duration(milliseconds: 850));
          transport.press(PedalButton.undo, down: false);
          await pumpEventQueue();

          verify(() => looper.redo()).called(1);
          verifyNever(() => looper.undo(channel: any(named: 'channel')));
        });

        test('a release with no matching press is inert — the on-screen '
            'plate note-offs every held switch as it leaves the tree, and an '
            'unpaired one must not fire a tap', () async {
          transport.press(PedalButton.undo, down: false); // release only
          await pumpEventQueue();

          verifyNever(() => looper.undo(channel: any(named: 'channel')));
          verifyNever(() => looper.redo(channel: any(named: 'channel')));
        });

        test('a second release after a completed tap fires nothing', () async {
          transport
            ..press(PedalButton.undo, down: true)
            ..press(PedalButton.undo, down: false);
          await pumpEventQueue();
          verify(() => looper.undo()).called(1);

          transport.press(PedalButton.undo, down: false);
          await pumpEventQueue();

          verifyNever(() => looper.undo(channel: any(named: 'channel')));
        });
      });

      group('MODE and Bank gesture timing', () {
        test('MODE tap enters Mute and never arms performance', () async {
          transport
            ..press(PedalButton.mode, down: true)
            ..press(PedalButton.mode, down: false);
          await pumpEventQueue();
          expect(cubit.state.mode, InteractionMode.mute);
          expect(performance.armedDirectory, isNull);
        });

        test(
          'MODE Hold enters Custom at 800 ms and does not run Press',
          () async {
            transport.press(PedalButton.mode, down: true);
            await pumpEventQueue();
            expect(cubit.state.mode, InteractionMode.record);
            await Future<void>.delayed(const Duration(milliseconds: 850));
            expect(cubit.state.mode, InteractionMode.custom);
            transport.press(PedalButton.mode, down: false);
            await pumpEventQueue();
            expect(cubit.state.mode, InteractionMode.custom);
            expect(performance.armedDirectory, isNull);
          },
        );

        test(
          'Bank Hold arms then disarms performance without paging',
          () async {
            final armed = awaitStatus(
              performance,
              PerformanceCaptureStatus.armed,
            );
            transport.press(PedalButton.bank, down: true);
            await Future<void>.delayed(const Duration(milliseconds: 850));
            transport.press(PedalButton.bank, down: false);
            await armed;
            expect(cubit.state.activeBank, 0);
            expect(performance.armedDirectory, isNotNull);

            clock = clock.add(PerformanceRepository.disarmGuardWindow * 2);
            final done = awaitStatus(
              performance,
              PerformanceCaptureStatus.done,
            );
            transport.press(PedalButton.bank, down: true);
            await Future<void>.delayed(const Duration(milliseconds: 850));
            transport.press(PedalButton.bank, down: false);
            await done;
            expect(cubit.state.activeBank, 0);
            expect(performance.armedDirectory, isNull);
          },
        );

        test('unmatched MODE release cannot run Press', () async {
          transport.press(PedalButton.mode, down: false);
          await pumpEventQueue();
          expect(cubit.state.mode, InteractionMode.record);
        });
      });
    });

    group('pedal remap (part 6b)', () {
      /// The Track-stage chain on channel 3, and one slot inside it.
      const chain3 = FxChainTarget(FxAddress(stage: FxStage.track, index: 3));
      const slotB = FxSlotTarget(
        address: FxAddress(stage: FxStage.track, index: 3),
        slotId: 'b',
      );

      PedalBinding bind(
        PedalButton button, {
        int? bank,
        FxBindingTarget target = chain3,
        BindingBehavior behavior = BindingBehavior.toggle,
        String? rawTarget,
      }) => PedalBinding(
        key: PedalBindingKey(button: button, bank: bank),
        target: rawTarget ?? target.canonicalString(),
        behavior: behavior,
      );

      Future<void> stomp(PedalButton button) async {
        transport
          ..press(button, down: true)
          ..press(button, down: false);
        await pumpEventQueue();
      }

      Future<void> press(PedalButton button) async {
        transport.press(button, down: true);
        await pumpEventQueue();
      }

      Future<void> release(PedalButton button) async {
        transport.press(button, down: false);
        await pumpEventQueue();
      }

      setUp(() {
        // A real chain on channel 3 so its flag is stompable, with two slots
        // so a slot binding has something to point at.
        trackChains[3] = [
          BuiltInEffect(type: TrackEffectType.drive, slotId: 'a'),
          BuiltInEffect(type: TrackEffectType.reverb, slotId: 'b'),
        ];
        setEngine(_emptyTracks());
        cubit.setMode(InteractionMode.fx);
      });

      group('Press and Hold assignment', () {
        const chain0 = FxChainTarget(
          FxAddress(stage: FxStage.track),
        );

        Future<void> assign({BindingScope scope = BindingScope.fixed}) async {
          trackChains[0] = [BuiltInEffect(type: TrackEffectType.drive)];
          await cubit.setGlobalBindings(
            PedalBindingSet([
              PedalBinding(
                key: const PedalBindingKey(
                  button: PedalButton.track1,
                  bank: 0,
                ),
                target: chain3.canonicalString(),
                holdTarget: chain0.canonicalString(),
                holdScope: scope,
              ),
            ]),
          );
        }

        test('short release fires Press once; Hold suppresses Press', () async {
          await assign();
          await press(PedalButton.track1);
          expect(chainEnabled, isEmpty, reason: 'down alone chooses neither');
          await release(PedalButton.track1);
          expect(chainEnabled[3], isFalse);
          expect(chainEnabled.containsKey(0), isFalse);

          await press(PedalButton.track1);
          await Future<void>.delayed(const Duration(milliseconds: 850));
          expect(chainEnabled[0], isFalse, reason: 'Hold fires while down');
          await release(PedalButton.track1);
          expect(chainEnabled[3], isFalse, reason: 'no second Press');
        });

        test(
          'selected Hold follows cursor before firing',
          () async {
            await assign(scope: BindingScope.selected);
            chainEnabled[0] = false;
            chainEnabled[3] = true;
            cubit.selectTrack(0);
            await press(PedalButton.track1);
            cubit.selectTrack(3);
            await Future<void>.delayed(const Duration(milliseconds: 850));
            expect(chainEnabled[3], isFalse, reason: 'cursor at fire time');
            expect(chainEnabled[0], isFalse, reason: 'old selection untouched');
            await release(PedalButton.track1);
          },
        );

        test('while Held, LED follows fired Hold instead of Press', () async {
          await assign(scope: BindingScope.selected);
          chainEnabled[0] = true;
          chainEnabled[3] = true;
          cubit.selectTrack(0);
          expect(transport.lastFrame?.trackLeds[0], isNot(PedalTrackLed.off));
          await press(PedalButton.track1);
          await Future<void>.delayed(const Duration(milliseconds: 850));
          expect(chainEnabled[0], isFalse);
          expect(chainEnabled[3], isTrue);
          expect(transport.lastFrame?.trackLeds[0], PedalTrackLed.off);
          await release(PedalButton.track1);
        });

        test('a remembered Bank A Hold never lights Bank B binding', () async {
          trackChains[0] = [BuiltInEffect(type: TrackEffectType.drive)];
          chainEnabled[0] = false;
          chainEnabled[3] = false;
          await cubit.setGlobalBindings(
            PedalBindingSet([
              PedalBinding(
                key: const PedalBindingKey(
                  button: PedalButton.track1,
                  bank: 0,
                ),
                target: chain0.canonicalString(),
                holdTarget: chain3.canonicalString(),
              ),
              PedalBinding(
                key: const PedalBindingKey(
                  button: PedalButton.track1,
                  bank: 1,
                ),
                target: chain0.canonicalString(),
              ),
            ]),
          );
          await press(PedalButton.track1);
          await Future<void>.delayed(const Duration(milliseconds: 850));
          await release(PedalButton.track1);
          expect(chainEnabled[3], isTrue);
          expect(transport.lastFrame?.trackLeds[0], isNot(PedalTrackLed.off));
          cubit.toggleBankWithCursor();
          expect(cubit.state.activeBank, 1);
          expect(transport.lastFrame?.trackLeds[4], PedalTrackLed.off);
          await stomp(PedalButton.track1);
          expect(chainEnabled[0], isTrue);
          expect(transport.lastFrame?.trackLeds[4], PedalTrackLed.blue);
        });

        test('take lock after down cancels Hold and short release', () async {
          await assign();
          await press(PedalButton.track1);
          takeIsLocked = true;
          await Future<void>.delayed(const Duration(milliseconds: 850));
          await release(PedalButton.track1);
          expect(chainEnabled, isEmpty);
        });

        test('equal session binding recall retires a pending hold', () async {
          await assign();
          await press(PedalButton.track1);
          cubit.applySessionBindings(PedalBindingSet.empty);
          await Future<void>.delayed(const Duration(milliseconds: 850));
          await release(PedalButton.track1);
          expect(chainEnabled, isEmpty);
        });

        test(
          'session revision fences Hold before binding recall completes',
          () async {
            var session = 0;
            when(() => looper.sessionRevision).thenAnswer((_) => session);
            await assign();
            await press(PedalButton.track1);
            session =
                1; // applySession begins before applySessionBindings is called
            await Future<void>.delayed(const Duration(milliseconds: 850));
            await release(PedalButton.track1);
            expect(chainEnabled, isEmpty);
          },
        );

        test(
          'a take lock acquired after down cancels system Stop Hold',
          () async {
            trackChains[1] = [BuiltInEffect(type: TrackEffectType.drive)];
            chainEnabled[1] = false;
            chainEnabled[3] = false;
            await cubit.setGlobalBindings(
              PedalBindingSet([bind(PedalButton.stop)]),
            );
            await press(PedalButton.stop);
            expect(chainEnabled[3], isTrue, reason: 'bound Press is immediate');
            takeIsLocked = true;
            await Future<void>.delayed(const Duration(milliseconds: 850));
            await release(PedalButton.stop);
            expect(
              chainEnabled[1],
              isFalse,
              reason: 'restore-all did not fire',
            );
          },
        );

        test(
          'selected momentary restores its fired track after cursor moves',
          () async {
            trackChains[0] = [BuiltInEffect(type: TrackEffectType.drive)];
            chainEnabled[0] = false;
            chainEnabled[3] = true;
            await cubit.setGlobalBindings(
              PedalBindingSet([
                PedalBinding(
                  key: const PedalBindingKey(
                    button: PedalButton.track1,
                    bank: 0,
                  ),
                  target: chain3.canonicalString(),
                  behavior: BindingBehavior.momentary,
                  scope: BindingScope.selected,
                ),
              ]),
            );
            cubit.selectTrack(0);
            await press(PedalButton.track1);
            expect(chainEnabled[0], isTrue);
            cubit.selectTrack(3);
            await release(PedalButton.track1);
            expect(chainEnabled[0], isFalse);
            expect(chainEnabled[3], isTrue);
          },
        );

        test(
          'refused momentary has no latch; refused restore retries',
          () async {
            chainEnabled[3] = false;
            var refuseEnable = true;
            var refuseRestore = false;
            final recipeApplied = Completer<EngineResult>();
            when(
              () => looper.settleFxRecipes(
                waitForCallback: true,
                cancelled: any(named: 'cancelled'),
              ),
            ).thenAnswer((_) => recipeApplied.future);
            when(
              () => looper.setTrackChainEnabled(
                channel: any(named: 'channel'),
                enabled: any(named: 'enabled'),
              ),
            ).thenAnswer((call) {
              final enabled = call.namedArguments[#enabled] as bool;
              if ((enabled && refuseEnable) || (!enabled && refuseRestore)) {
                return EngineResult.notReady;
              }
              chainEnabled[call.namedArguments[#channel] as int] = enabled;
              return EngineResult.ok;
            });
            await cubit.setGlobalBindings(
              PedalBindingSet([
                PedalBinding(
                  key: const PedalBindingKey(
                    button: PedalButton.track1,
                    bank: 0,
                  ),
                  target: chain3.canonicalString(),
                  behavior: BindingBehavior.momentary,
                ),
              ]),
            );

            await press(PedalButton.track1);
            expect(chainEnabled[3], isFalse);
            expect(cubit.state.heldMomentary, isEmpty);
            await release(PedalButton.track1);

            refuseEnable = false;
            await press(PedalButton.track1);
            expect(chainEnabled[3], isTrue);
            refuseRestore = true;
            await release(PedalButton.track1);
            expect(chainEnabled[3], isTrue);
            expect(cubit.state.heldMomentary, isNotEmpty);

            refuseRestore = false;
            recipeApplied.complete(EngineResult.ok);
            // No LooperState change accompanies this callback acknowledgment.
            await pumpEventQueue();
            expect(chainEnabled[3], isFalse);
            expect(cubit.state.heldMomentary, isEmpty);
          },
        );

        test(
          'removed stable slot cannot block a replacement assignment',
          () async {
            trackChains[3] = [
              BuiltInEffect(
                type: TrackEffectType.drive,
                slotId: 'old',
                enabled: false,
              ),
            ];
            await cubit.setGlobalBindings(
              PedalBindingSet([
                PedalBinding(
                  key: const PedalBindingKey(
                    button: PedalButton.track1,
                    bank: 0,
                  ),
                  target: const FxSlotTarget(
                    address: FxAddress(stage: FxStage.track, index: 3),
                    slotId: 'old',
                  ).canonicalString(),
                  behavior: BindingBehavior.momentary,
                ),
              ]),
            );
            await press(PedalButton.track1);
            expect(trackChains[3]!.single.enabled, isTrue);
            trackChains[3] = [
              BuiltInEffect(
                type: TrackEffectType.reverb,
                slotId: 'new',
              ),
            ];
            await release(PedalButton.track1);
            await cubit.setGlobalBindings(
              PedalBindingSet([
                PedalBinding(
                  key: const PedalBindingKey(
                    button: PedalButton.track1,
                    bank: 0,
                  ),
                  target: const FxSlotTarget(
                    address: FxAddress(stage: FxStage.track, index: 3),
                    slotId: 'new',
                  ).canonicalString(),
                ),
              ]),
            );
            await stomp(PedalButton.track1);
            expect(trackChains[3]!.single.enabled, isFalse);
            expect(cubit.state.heldMomentary, isEmpty);
          },
        );
      });

      group('what the LED reports', () {
        test(
          'a bound switch lights from its own target, not the track',
          () async {
            // track1 bound to channel 3's chain, so its LED must follow THAT
            // chain — channel 0's is a different flag, and stomping the switch
            // never touches it.
            await cubit.setGlobalBindings(
              PedalBindingSet([bind(PedalButton.track1, bank: 0)]),
            );
            cubit.setMode(InteractionMode.fx);
            await pumpEventQueue();
            transport.sent.clear();
            await stomp(PedalButton.track1);
            await pumpEventQueue();

            expect(chainEnabled[3], isFalse, reason: 'the bound chain is off');
            expect(
              transport.lastFrame?.trackLeds[0],
              PedalTrackLed.off,
              reason: 'the LED follows the bound chain it just switched off',
            );
          },
        );

        test('a stale binding lights nothing', () async {
          await cubit.setGlobalBindings(
            PedalBindingSet([
              bind(PedalButton.track1, bank: 0, rawTarget: 'not-a-target'),
            ]),
          );
          await pumpEventQueue();

          // The last push is the current projection: the cubit pushes on
          // every change and the diff only ever suppresses an identical frame.
          // R25: a binding that names nothing writes nothing and lights
          // nothing. Falling back to the channel's own chain would light for
          // a chain the switch does not drive.
          expect(
            transport.lastFrame?.trackLeds[0],
            PedalTrackLed.off,
          );
        });
      });

      group('dispatch', () {
        test('a bound button overrides its contextual default', () async {
          // Unbound, track1 in bank A stomps channel 0's own chain.
          await cubit.setGlobalBindings(
            PedalBindingSet([bind(PedalButton.track1, bank: 0)]),
          );
          await stomp(PedalButton.track1);

          expect(chainEnabled[3], isFalse, reason: 'the BOUND chain flipped');
          verifyNever(
            () => looper.setTrackChainEnabled(channel: 0, enabled: false),
          );
        });

        test(
          'an UNBOUND button keeps its part 5b contextual behavior',
          () async {
            await cubit.setGlobalBindings(
              PedalBindingSet([bind(PedalButton.track1, bank: 0)]),
            );
            await stomp(PedalButton.track2);

            expect(chainEnabled[1], isFalse, reason: 'contextual: channel 1');
            expect(chainEnabled.containsKey(3), isFalse);
          },
        );

        test('bindings are INERT outside FX mode — the transport modes are '
            'not a surface a remap may shadow', () async {
          await cubit.setGlobalBindings(
            PedalBindingSet([bind(PedalButton.stop)]),
          );
          cubit.setMode(InteractionMode.record);
          await stomp(PedalButton.stop);

          expect(chainEnabled.containsKey(3), isFalse);
        });

        test('a toggle binding flips the target back and forth', () async {
          await cubit.setGlobalBindings(
            PedalBindingSet([bind(PedalButton.recPlay)]),
          );
          await stomp(PedalButton.recPlay);
          expect(chainEnabled[3], isFalse);
          await stomp(PedalButton.recPlay);
          expect(chainEnabled[3], isTrue);
        });

        test('a SLOT binding flips one effect, leaving the chain flag '
            'alone (A9)', () async {
          await cubit.setGlobalBindings(
            PedalBindingSet([bind(PedalButton.recPlay, target: slotB)]),
          );
          await stomp(PedalButton.recPlay);

          expect(trackChains[3]![1].enabled, isFalse);
          expect(
            trackChains[3]![0].enabled,
            isTrue,
            reason: 'slot a untouched',
          );
          expect(chainEnabled.containsKey(3), isFalse, reason: 'chain flag');
        });

        test('a slot binding survives an INSERT above it — positional churn '
            'never retargets (A9)', () async {
          await cubit.setGlobalBindings(
            PedalBindingSet([bind(PedalButton.recPlay, target: slotB)]),
          );
          trackChains[3] = [
            BuiltInEffect(type: TrackEffectType.delay, slotId: 'new'),
            ...trackChains[3]!,
          ];
          await stomp(PedalButton.recPlay);

          final byId = {
            for (final fx in trackChains[3]!) fx.slotId: fx.enabled,
          };
          expect(byId['b'], isFalse, reason: 'the bound slot flipped');
          expect(byId['new'], isTrue, reason: 'the inserted one did not');
          expect(byId['a'], isTrue);
        });

        test('track bindings are per-bank (A3)', () async {
          await cubit.setGlobalBindings(
            PedalBindingSet([bind(PedalButton.track1, bank: 1)]),
          );
          // Bank A: unbound, so track1 acts contextually on channel 0.
          await stomp(PedalButton.track1);
          expect(chainEnabled[0], isFalse);
          expect(chainEnabled.containsKey(3), isFalse);

          cubit.browseBank(1);
          await stomp(PedalButton.track1);
          expect(chainEnabled[3], isFalse, reason: 'bank B is bound');
        });
      });

      group('MODE and Bank are never remappable (B12)', () {
        test('the model refuses to hold a binding on either', () async {
          await cubit.setGlobalBindings(
            PedalBindingSet([bind(PedalButton.mode), bind(PedalButton.bank)]),
          );
          expect(cubit.state.globalBindings.isEmpty, isTrue);
        });

        test(
          'MODE keeps its configured pair and Bank still switches banks',
          () async {
            await cubit.setGlobalBindings(
              PedalBindingSet([bind(PedalButton.mode), bind(PedalButton.bank)]),
            );

            await stomp(PedalButton.bank);
            expect(cubit.state.activeBank, 1);
            expect(chainEnabled.containsKey(3), isFalse);

            // MODE is the FX face's Exit (pen 10/03): a binding never
            // shadows it.
            await stomp(PedalButton.mode);
            expect(cubit.state.mode, InteractionMode.record);
          },
        );
      });

      group('bound transport switches in FX mode (#1229)', () {
        test('a bound Stop runs only its binding: no panic on the press and '
            'no restore on the hold', () async {
          trackChains[1] = [BuiltInEffect(type: TrackEffectType.drive)];
          await cubit.setGlobalBindings(
            PedalBindingSet([bind(PedalButton.stop)]),
          );

          await press(PedalButton.stop);
          expect(chainEnabled[3], isFalse, reason: 'the binding ran');
          expect(chainEnabled.containsKey(1), isFalse, reason: 'no panic');

          await Future<void>.delayed(const Duration(milliseconds: 850));
          await release(PedalButton.stop);
          expect(chainEnabled[3], isFalse, reason: 'no restore-all hold');
          expect(chainEnabled.containsKey(1), isFalse);
        });

        test('bound Rec/Play, Stop, Undo and Clear light for what their '
            'binding drives, and their face reads the same', () async {
          await cubit.setGlobalBindings(
            PedalBindingSet([
              bind(PedalButton.recPlay),
              bind(PedalButton.clear),
            ]),
          );
          await pumpEventQueue();
          // chain 3 starts enabled: both bound switches are lit; the unbound
          // Stop and Undo are dark.
          expect(transport.lastFrame?.isLit(PedalButton.recPlay), isTrue);
          expect(transport.lastFrame?.isLit(PedalButton.clear), isTrue);
          expect(transport.lastFrame?.isLit(PedalButton.stop), isFalse);
          expect(transport.lastFrame?.isLit(PedalButton.undo), isFalse);
          expect(
            cubit.state.fxSwitches[PedalButton.recPlay],
            (lit: true, stale: false),
          );

          await stomp(PedalButton.recPlay);
          expect(chainEnabled[3], isFalse);
          await pumpEventQueue();
          expect(transport.lastFrame?.isLit(PedalButton.recPlay), isFalse);
          expect(transport.lastFrame?.isLit(PedalButton.clear), isFalse);
          expect(
            cubit.state.fxSwitches[PedalButton.clear],
            (lit: false, stale: false),
          );
        });

        test('a stale binding is refused with one notice and lights '
            'nothing', () async {
          await cubit.setGlobalBindings(
            PedalBindingSet([
              bind(
                PedalButton.undo,
                target: const FxChainTarget(
                  FxAddress(stage: FxStage.output, index: 9),
                ),
              ),
            ]),
          );
          await pumpEventQueue();
          expect(
            cubit.state.fxSwitches[PedalButton.undo],
            (lit: false, stale: true),
          );
          final before = cubit.state.footFxFailure;
          await stomp(PedalButton.undo);
          expect(cubit.state.footFxFailure, before + 1);
          expect(cubit.state.footFxRefusal, FootFxRefusal.unavailable);
          expect(transport.lastFrame?.isLit(PedalButton.undo), isFalse);
        });

        test('a refused write is reported as a failure', () async {
          await cubit.setGlobalBindings(
            PedalBindingSet([bind(PedalButton.recPlay)]),
          );
          when(
            () => looper.setTrackChainEnabled(
              channel: 3,
              enabled: any(named: 'enabled'),
            ),
          ).thenReturn(EngineResult.notReady);
          final before = cubit.state.footFxFailure;
          await stomp(PedalButton.recPlay);
          expect(cubit.state.footFxFailure, before + 1);
          expect(cubit.state.footFxRefusal, FootFxRefusal.failed);
        });

        test('an on-screen contact runs a binding and a cancelled one '
            'still restores a held momentary', () async {
          await cubit.setGlobalBindings(
            PedalBindingSet([
              bind(PedalButton.track1, bank: 0),
              bind(PedalButton.clear, behavior: BindingBehavior.momentary),
            ]),
          );
          final tap = Object();
          cubit
            ..footFxPressed(PedalButton.track1, tap)
            ..footFxReleased(PedalButton.track1, tap);
          await pumpEventQueue();
          expect(chainEnabled[3], isFalse, reason: 'the toggle ran');

          final held = Object();
          cubit.footFxPressed(PedalButton.clear, held);
          await pumpEventQueue();
          expect(chainEnabled[3], isTrue, reason: 'held on');
          expect(
            cubit.state.fxSwitches[PedalButton.clear],
            (lit: true, stale: false),
          );
          cubit.footFxCancelled(PedalButton.clear, held);
          await pumpEventQueue();
          expect(chainEnabled[3], isFalse, reason: 'restored, never stranded');
          expect(
            cubit.state.fxSwitches[PedalButton.clear],
            (lit: false, stale: false),
          );
        });

        test('accessible activation toggles, skips a momentary, pages Bank '
            'and exits by MODE', () async {
          await cubit.setGlobalBindings(
            PedalBindingSet([
              bind(PedalButton.track1, bank: 0),
              bind(
                PedalButton.track2,
                bank: 0,
                behavior: BindingBehavior.momentary,
              ),
            ]),
          );
          cubit.activateFootFxPedal(PedalButton.track2);
          expect(chainEnabled.containsKey(3), isFalse);
          cubit.activateFootFxPedal(PedalButton.track1);
          expect(chainEnabled[3], isFalse);
          // An unbound track switch toggles its own chain.
          cubit.activateFootFxPedal(PedalButton.track3);
          expect(chainEnabled[2], isFalse);
          cubit.activateFootFxPedal(PedalButton.bank);
          expect(cubit.state.activeBank, 1);
          cubit.activateFootFxPedal(PedalButton.mode);
          expect(cubit.state.mode, InteractionMode.record);
          // Outside FX mode it does nothing.
          cubit.activateFootFxPedal(PedalButton.bank);
          expect(cubit.state.activeBank, 1);
        });

        test('fxSwitches is empty outside FX mode', () async {
          await cubit.setGlobalBindings(
            PedalBindingSet([bind(PedalButton.recPlay)]),
          );
          expect(cubit.state.fxSwitches, isNotEmpty);
          cubit.setMode(InteractionMode.record);
          expect(cubit.state.fxSwitches, isEmpty);
        });

        test('MODE exits on contact despite an attempted remap', () async {
          await cubit.setGlobalBindings(
            PedalBindingSet([bind(PedalButton.mode)]),
          );
          await press(PedalButton.mode);
          expect(cubit.state.mode, InteractionMode.record);
          await Future<void>.delayed(const Duration(milliseconds: 850));
          await release(PedalButton.mode);
          expect(cubit.state.mode, InteractionMode.record);
          expect(performance.armedDirectory, isNull);
        });
      });

      group('momentary (B1)', () {
        Future<void> bindMomentary({FxBindingTarget target = chain3}) =>
            cubit.setGlobalBindings(
              PedalBindingSet([
                bind(
                  PedalButton.recPlay,
                  target: target,
                  behavior: BindingBehavior.momentary,
                ),
              ]),
            );

        for (final restoring in [false, true]) {
          test('close cancels and drains a pending binding '
              '${restoring ? 'release' : 'press'} confirmation', () async {
            chainEnabled[3] = false;
            await bindMomentary();
            if (restoring) await press(PedalButton.recPlay);
            final receipt = Completer<EngineResult>();
            bool Function()? cancelled;
            when(
              () => looper.settleFxRecipes(
                waitForCallback: true,
                cancelled: any(named: 'cancelled'),
              ),
            ).thenAnswer((call) {
              cancelled = call.namedArguments[#cancelled] as bool Function();
              return receipt.future;
            });
            if (restoring) {
              await release(PedalButton.recPlay);
            } else {
              await press(PedalButton.recPlay);
            }
            expect(cancelled, isNotNull);
            final closing = cubit.close();
            await pumpEventQueue();
            final closedBeforeReceipt = cubit.isClosed;
            final cancellationRequested = cancelled!();
            receipt.complete(EngineResult.notReady);
            await closing;
            await pumpEventQueue();
            expect(cancellationRequested, isTrue);
            expect(closedBeforeReceipt, isFalse);
            expect(cubit.isClosed, isTrue);
          });
        }

        test(
          'press enables and release restores what the press captured',
          () async {
            chainEnabled[3] = false; // starts bypassed
            await bindMomentary();

            await press(PedalButton.recPlay);
            expect(chainEnabled[3], isTrue, reason: 'held = enabled');

            await release(PedalButton.recPlay);
            expect(chainEnabled[3], isFalse, reason: 'restored to prior');
          },
        );

        test('a press over an ALREADY-enabled target restores it enabled — '
            'the release writes the captured state, not a blind off', () async {
          await bindMomentary();
          await press(PedalButton.recPlay);
          await release(PedalButton.recPlay);
          expect(cubit.state.mode, InteractionMode.fx);
          expect(chainEnabled[3] ?? true, isTrue);
        });

        test('last-writer-wins: a UI toggle mid-hold is overwritten by the '
            'release, which restores what THIS press saw', () async {
          chainEnabled[3] = false;
          await bindMomentary();

          await press(PedalButton.recPlay);
          // Another writer flips it while the foot is down.
          cubit.toggleTrackChain(3);
          expect(chainEnabled[3], isFalse);

          await release(PedalButton.recPlay);
          expect(chainEnabled[3], isFalse, reason: 'the capture won');
        });

        test('works on a slot target too', () async {
          await bindMomentary(target: slotB);
          trackChains[3] = [
            trackChains[3]![0],
            (trackChains[3]![1] as BuiltInEffect).copyWith(enabled: false),
          ];

          await press(PedalButton.recPlay);
          expect(trackChains[3]![1].enabled, isTrue);

          await release(PedalButton.recPlay);
          expect(trackChains[3]![1].enabled, isFalse);
        });

        group('no stuck momentary (flow SC-2) — every path that strands a '
            'press without its release restores at the ONE enforcement '
            'point', () {
          setUp(() async {
            chainEnabled[3] = false;
            await bindMomentary();
            await press(PedalButton.recPlay);
            expect(chainEnabled[3], isTrue, reason: 'held');
          });

          test('a MODE switch out of FX', () async {
            cubit.setMode(InteractionMode.record);
            expect(chainEnabled[3], isFalse);
          });

          test(
            'a pedal disconnect — the release never arrives',
            () async {
              transport.hello();
              await pumpEventQueue();
              expect(chainEnabled[3], isTrue, reason: 'still held');
              // Releasing the link reports it disconnected at once — the same
              // status a board that went quiet reports after helloTimeout
              // (pinned in the package's own tests), without a real-time wait.
              await pedal.dispose();
              await pumpEventQueue();
              expect(chainEnabled[3], isFalse);
            },
          );

          test('a session load replacing the binding set', () async {
            cubit.applySessionBindings(
              PedalBindingSet([bind(PedalButton.stop)]),
            );
            expect(chainEnabled[3], isFalse);
          });

          test('a live edit from the assignment screen', () async {
            await cubit.setGlobalBindings(PedalBindingSet.empty);
            expect(chainEnabled[3], isFalse);
          });

          test('and a late release afterwards writes nothing more', () async {
            cubit.setMode(InteractionMode.record);
            chainEnabled.remove(3);
            await release(PedalButton.recPlay);
            expect(chainEnabled.containsKey(3), isFalse);
          });
        });

        test('a REPEATED press with no release between captures only ONCE — '
            'a dropped NoteOff must not let the release restore the state '
            'this binding itself enabled (B1)', () async {
          chainEnabled[3] = false;
          await bindMomentary();

          await press(PedalButton.recPlay);
          expect(chainEnabled[3], isTrue);
          await press(PedalButton.recPlay); // the NoteOff never arrived
          await release(PedalButton.recPlay);

          expect(
            chainEnabled[3],
            isFalse,
            reason: 'restores what the FIRST press captured',
          );
        });

        test('a bank change mid-hold still releases the pressed binding — '
            'the release is matched by BUTTON, not the live bank', () async {
          chainEnabled[3] = false;
          await cubit.setGlobalBindings(
            PedalBindingSet([
              bind(
                PedalButton.track1,
                bank: 0,
                behavior: BindingBehavior.momentary,
              ),
            ]),
          );

          await press(PedalButton.track1);
          expect(chainEnabled[3], isTrue);

          cubit.browseBank(1); // foot still down
          await release(PedalButton.track1);
          expect(chainEnabled[3], isFalse);
        });
      });

      group('stale targets (R25)', () {
        test('a mid-song stomp on a stale binding is a NO-OP', () async {
          await cubit.setGlobalBindings(
            PedalBindingSet([
              bind(
                PedalButton.recPlay,
                target: const FxChainTarget(
                  FxAddress(stage: FxStage.track, index: 7),
                ),
              ),
            ]),
          );
          await stomp(PedalButton.recPlay);

          expect(chainEnabled, isEmpty);
          verifyNever(
            () => looper.setTrackChainEnabled(
              channel: any(named: 'channel'),
              enabled: any(named: 'enabled'),
            ),
          );
        });

        test('a target string that no longer parses is a no-op, not a '
            'crash', () async {
          await cubit.setGlobalBindings(
            PedalBindingSet([bind(PedalButton.recPlay, rawTarget: 'garbage')]),
          );
          await stomp(PedalButton.recPlay);
          expect(chainEnabled, isEmpty);
        });

        test('a slot deleted out from under a binding never falls back to '
            'the chain or to its old neighbour', () async {
          await cubit.setGlobalBindings(
            PedalBindingSet([bind(PedalButton.recPlay, target: slotB)]),
          );
          trackChains[3] = [trackChains[3]![0]]; // slot b deleted
          await stomp(PedalButton.recPlay);

          expect(trackChains[3]!.single.enabled, isTrue);
          expect(chainEnabled, isEmpty);
        });

        test('a stale MOMENTARY press captures nothing, so its release has '
            'nothing to restore', () async {
          await cubit.setGlobalBindings(
            PedalBindingSet([
              bind(
                PedalButton.recPlay,
                rawTarget: 'garbage',
                behavior: BindingBehavior.momentary,
              ),
            ]),
          );
          await press(PedalButton.recPlay);
          await release(PedalButton.recPlay);
          expect(chainEnabled, isEmpty);
        });
      });

      group('stompFor (the Signal chip source)', () {
        test('reports a HELD binding over an unheld one on the same chain — '
            'the held marker explains an enabled state no click can undo, so '
            'it must not be hidden by whichever binding sorts first', () async {
          chainEnabled[3] = false;
          await cubit.setGlobalBindings(
            PedalBindingSet([
              // recPlay sorts BEFORE track1, and is the unheld one.
              bind(PedalButton.recPlay),
              bind(
                PedalButton.track1,
                bank: 0,
                behavior: BindingBehavior.momentary,
              ),
            ]),
          );

          await press(PedalButton.track1);

          final stomp = cubit.state.stompFor(
            const FxAddress(stage: FxStage.track, index: 3),
          );
          expect(stomp?.held, isTrue);
          expect(stomp?.binding.key.button, PedalButton.track1);

          await release(PedalButton.track1);
          expect(
            cubit.state
                .stompFor(const FxAddress(stage: FxStage.track, index: 3))
                ?.held,
            isFalse,
          );
        });

        test('an unbound chain reports nothing', () {
          expect(
            cubit.state.stompFor(
              const FxAddress(stage: FxStage.track, index: 3),
            ),
            isNull,
          );
        });
      });

      group('merge rule (A12)', () {
        test(
          'a session with bindings overrides the globals WHOLESALE',
          () async {
            await cubit.setGlobalBindings(
              PedalBindingSet([
                bind(PedalButton.recPlay),
                bind(PedalButton.stop),
              ]),
            );
            cubit.applySessionBindings(
              PedalBindingSet([bind(PedalButton.undo)]),
            );

            // The session's own button acts...
            await stomp(PedalButton.undo);
            expect(chainEnabled[3], isFalse);

            // ...and a global-only button is back to its contextual default.
            chainEnabled.clear();
            await stomp(PedalButton.recPlay);
            expect(
              chainEnabled,
              isEmpty,
              reason: 'recPlay is inert in FX (A4)',
            );
          },
        );

        test('a session with NO bindings falls back to the globals', () async {
          await cubit.setGlobalBindings(
            PedalBindingSet([bind(PedalButton.recPlay)]),
          );
          cubit.applySessionBindings(PedalBindingSet.empty);

          await stomp(PedalButton.recPlay);
          expect(chainEnabled[3], isFalse);
        });
      });

      test('the global set persists and reloads through settings', () async {
        final set = PedalBindingSet([
          bind(PedalButton.stop, behavior: BindingBehavior.momentary),
          bind(PedalButton.track2, bank: 1, target: slotB),
        ]);
        await cubit.setGlobalBindings(set);

        expect(
          PedalBindingSet.decode(await settings.loadPedalBindings() ?? ''),
          set,
        );

        final ownedFade = testFadeSettings();
        final reloaded = ControlCubit(
          fxPersistence: FxChainPersistence(looper: looper),
          looper: looper,
          mixSettings: testMixSettings(looper),
          pedal: pedal,
          settings: settings,
          performance: performance,
          fadeSettings: ownedFade,
          ownedValues: OwnedValuePort(
            looper: looper,
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
        addTearDown(reloaded.close);
        await reloaded.load();
        expect(reloaded.state.globalBindings, set);
      });
    });

    group('frame projection (frames out via PedalRepository)', () {
      test('normal Undo lights only for accepted physical contact', () async {
        setEngine(_emptyTracks());
        transport.press(PedalButton.undo, down: true);
        await pumpEventQueue();
        expect(transport.lastFrame?.isLit(PedalButton.undo), isTrue);
        transport.press(PedalButton.undo, down: false);
        await pumpEventQueue();
        expect(transport.lastFrame?.isLit(PedalButton.undo), isFalse);

        takeIsLocked = true;
        transport.press(PedalButton.undo, down: true);
        await pumpEventQueue();
        expect(transport.lastFrame?.isLit(PedalButton.undo), isFalse);
        transport.press(PedalButton.undo, down: false);
        await pumpEventQueue();
      });

      test('pushes an encoded frame to the pedal link', () async {
        transport.sent.clear();

        // Rec mode (default): the cursor track (0) is red; a playing
        // non-cursor track is off (green-for-playing is a Mute-mode concern).
        setEngine(
          _tracksWith(const [
            Track(), // track 0 (cursor) -> red indicator
            Track(channel: 1, state: TrackState.playing, lengthFrames: 48000),
          ]),
        );
        await pumpEventQueue();

        expect(transport.sent, isNotEmpty);
        final frame = transport.lastFrame;
        expect(frame, isNotNull);
        expect(frame!.trackLeds[0], PedalTrackLed.red);
        expect(frame.trackLeds[1], PedalTrackLed.off);
      });

      test('an encoder turn pushes the new master gain in the frame', () async {
        setEngine(_tracksWith(const [Track()]));
        await pumpEventQueue();
        transport.sent.clear();

        // -8 detents at step 1/64 -> gain 0.875 (the pedal renders this).
        cubit.encoderTurned(-8);
        await pumpEventQueue();

        expect(transport.sent, isNotEmpty);
        final frame = transport.lastFrame;
        expect(frame, isNotNull);
        expect(frame!.masterGain, closeTo(0.875, 0.01));
      });

      test('a stored-intent change re-projects without a looper tick', () {
        setEngine(_emptyTracks());
        transport.sent.clear();

        cubit.selectTrack(3); // cursor moves -> the red LED must follow

        final frame = transport.lastFrame;
        expect(frame!.selectedTrack, 3);
        expect(frame.trackLeds[3], PedalTrackLed.red);
        expect(frame.trackLeds[0], PedalTrackLed.off);
      });

      test(
        'pushes the restored state on load(), before any LooperState '
        'streams (regression: a null _looperState left the LEDs dark)',
        () async {
          // NB: no setEngine() — this cubit never receives a streamed
          // LooperState; only the synchronous `looper.state` snapshot (an idle
          // empty set from the outer setUp) is available. Liveness after this
          // first push is the repository's (it answers hellos), so this is the
          // one push the cubit owes unprompted. Its own link and repository:
          // the shared one already holds this frame, and a repeat is dropped.
          final idleLink = FakePedalLink();
          final idlePedal = PedalRepository(idleLink);
          idleLink.hello();
          await pumpEventQueue();
          addTearDown(idlePedal.dispose);
          final ownedFade = testFadeSettings();
          final idle = ControlCubit(
            fxPersistence: FxChainPersistence(looper: looper),
            looper: looper,
            mixSettings: testMixSettings(looper),
            pedal: idlePedal,
            settings: settings,
            performance: performance,
            fadeSettings: ownedFade,
            ownedValues: OwnedValuePort(
              looper: looper,
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
          addTearDown(idle.close);
          expect(idleLink.lastFrame, isNull, reason: 'nothing before load()');
          await idle.load();
          expect(idleLink.lastFrame, isNotNull);
        },
      );

      test('Clear LED lights while the footswitch is held and darkens on '
          'release', () async {
        setEngine(
          _tracksWith(const [
            Track(state: TrackState.playing, lengthFrames: 48000),
          ]),
        );
        transport.sent.clear();

        // Press: the Clear LED bit is set.
        transport.press(PedalButton.clear, down: true);
        await pumpEventQueue();
        expect(
          transport.lastFrame?.clearFadeActive,
          isTrue,
        );

        // Release (note-off): the bit clears again.
        transport.press(PedalButton.clear, down: false);
        await pumpEventQueue();
        expect(
          transport.lastFrame?.clearFadeActive,
          isFalse,
        );
      });

      test('Clear on an empty rig leaves its LED dark', () async {
        setEngine(_emptyTracks());
        transport.press(PedalButton.clear, down: true);
        await pumpEventQueue();
        expect(transport.lastFrame?.clearFadeActive, isFalse);
        expect(transport.lastFrame?.isLit(PedalButton.clear), isFalse);
        transport.press(PedalButton.clear, down: false);
        await pumpEventQueue();
      });

      test(
        'global_color carries the ring activity color (recording = red)',
        () async {
          transport.sent.clear();
          setEngine(
            _tracksWith(const [Track(state: TrackState.recording)]),
          );
          await pumpEventQueue();

          final frame = transport.lastFrame;
          expect(frame?.globalColor, GlobalColor.red);
        },
      );

      test(
        'the pushed frame carries the per-track LED projection',
        () async {
          transport.sent.clear();
          setEngine(
            _tracksWith(const [
              Track(), // ch0 cursor by default -> red
              Track(channel: 1, state: TrackState.recording),
            ]),
          );
          await pumpEventQueue();

          final leds = transport.lastFrame?.trackLeds;
          expect(leds?[0], PedalTrackLed.red);
          expect(leds?[1], PedalTrackLed.red);
          expect(leds?[2], PedalTrackLed.off);

          cubit.selectTrack(2);
          await pumpEventQueue();
          expect(
            transport.lastFrame?.trackLeds[2],
            PedalTrackLed.red,
          );
        },
      );
    });
  });
}
