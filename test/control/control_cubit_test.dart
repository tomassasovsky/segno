import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:pedal_repository/testing.dart';
import 'package:performance_repository/performance_repository.dart';
import 'package:segno/control/control.dart';
import 'package:segno/looper/model/interaction_mode.dart';
import 'package:settings_repository/settings_repository.dart';

import '../helpers/helpers.dart';

class _MockLooperRepository extends Mock implements LooperRepository {}

/// A real [PerformanceRepository] that additionally logs when
/// [persistLiveLanes] runs, into a shared [log] list — proves the D-CLEAR
/// ordering (persist-before-clear) without mocking file I/O, since the
/// repository itself is not mock-friendly (real disk access).
class _RecordingPerformanceRepository extends PerformanceRepository {
  _RecordingPerformanceRepository({
    required this.log,
    required super.engine,
    required super.exportsRoot,
  });

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
    late FakePedalLink transport;
    late PedalRepository pedal;
    late PerformanceRepository performance;
    late ControlCubit cubit;
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

    setUp(() {
      looper = _MockLooperRepository();
      looperStates = StreamController<LooperState>.broadcast(sync: true);
      settings = SettingsRepository(store: FakeKeyValueStore());
      transport = FakePedalLink();
      pedal = PedalRepository(transport);
      when(() => looper.looperState).thenAnswer((_) => looperStates.stream);
      for (final stub in [
        () => looper.record(channel: any(named: 'channel')),
        () => looper.undo(channel: any(named: 'channel')),
        () => looper.redo(channel: any(named: 'channel')),
        () => looper.clear(channel: any(named: 'channel')),
        () => looper.play(channel: any(named: 'channel')),
        () => looper.stopTrack(channel: any(named: 'channel')),
      ]) {
        when(stub).thenReturn(EngineResult.ok);
      }
      when(
        () => looper.setMute(
          muted: any(named: 'muted'),
          channel: any(named: 'channel'),
        ),
      ).thenReturn(EngineResult.ok);
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
        engine: FakeAudioEngine(),
        exportsRoot: () async => tempDir.path,
        now: () => clock,
      );
      // Every emit projects a frame from the repository snapshot, so the
      // snapshot has to exist before the first one; setEngine() re-stubs it.
      when(() => looper.state).thenReturn(_stateWith(_emptyTracks()));
      cubit = ControlCubit(
        looper: looper,
        pedal: pedal,
        settings: settings,
        performance: performance,
      );
      setEngine(_emptyTracks());
    });

    tearDown(() async {
      await cubit.close();
      await pedal.dispose();
      await looperStates.close();
      performance.dispose();
      tempDir.deleteSync(recursive: true);
    });

    group('mode', () {
      test('toggleMode cycles Record -> Mute -> FX -> Record', () {
        expect(cubit.state.mode, InteractionMode.record);
        cubit.toggleMode();
        expect(cubit.state.mode, InteractionMode.mute);
        cubit.toggleMode();
        expect(cubit.state.mode, InteractionMode.fx);
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

      test('setDefaultMode persists the token and applies the mode', () async {
        await cubit.setDefaultMode(InteractionMode.mute);
        expect(cubit.state.defaultMode, InteractionMode.mute);
        expect(cubit.state.mode, InteractionMode.mute);
        expect(
          await settings.loadDefaultInteractionMode(),
          InteractionMode.mute.token,
        );
      });

      test('load boots the live mode into the persisted default', () async {
        await settings.saveDefaultInteractionMode(InteractionMode.mute.token);
        await cubit.load();
        expect(cubit.state.defaultMode, InteractionMode.mute);
        expect(cubit.state.mode, InteractionMode.mute);
      });

      test('load boots into mute from the legacy persisted token "play" '
          '(pre-rename installs)', () async {
        await settings.saveDefaultInteractionMode('play');
        await cubit.load();
        expect(cubit.state.defaultMode, InteractionMode.mute);
        expect(cubit.state.mode, InteractionMode.mute);
      });

      test('toggleMode does not change the persisted default mode', () async {
        cubit.toggleMode();
        expect(cubit.state.mode, InteractionMode.mute);
        expect(cubit.state.defaultMode, InteractionMode.record);
        expect(await settings.loadDefaultInteractionMode(), isNull);
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
        // During a count-in the defining track is still EMPTY engine-side;
        // only the transport flag says a take is in gestation. The abort is
        // channel-agnostic (the count-in is global transport state), so the
        // cubit addresses channel 0.
        final state = _stateWith(_emptyTracks(), countingIn: true);
        when(() => looper.state).thenReturn(state);
        looperStates.add(state);

        cubit.setMode(InteractionMode.fx);

        verify(() => looper.finalizeTake(channel: 0)).called(1);
        expect(cubit.state.mode, InteractionMode.fx);
      });

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

      test('entering FX mode reads LIVE engine truth for the arm sweep, not '
          'the polled snapshot', () {
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

        verifyNever(() => looper.cancelArm(channel: any(named: 'channel')));
      });

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

      test('a stored "fx" boot default falls back to record (R12)', () async {
        await settings.saveDefaultInteractionMode(InteractionMode.fx.token);
        await cubit.load();
        expect(cubit.state.defaultMode, InteractionMode.record);
        expect(cubit.state.mode, InteractionMode.record);
      });

      test(
        'setDefaultMode refuses FX — it is never a boot mode (R12)',
        () async {
          // Debug builds fail loudly — a caller offering FX here has a bug...
          await expectLater(
            cubit.setDefaultMode(InteractionMode.fx),
            throwsA(isA<AssertionError>()),
          );
          // ...and nothing is applied or persisted either way, which is what
          // keeps a release build off the dead boot surface.
          expect(cubit.state.defaultMode, InteractionMode.record);
          expect(cubit.state.mode, InteractionMode.record);
          expect(await settings.loadDefaultInteractionMode(), isNull);
        },
      );
    });

    // #632: the MODE switch's second style — a Record ↔ Mute tap cycle with
    // FX behind the hold that arms performance recording under the default
    // style. The default style's behaviour (three-stop cycle, MODE hold =
    // performance record) stays pinned by the 'mode' and 'FX mode' groups
    // above/below.
    group('mode switch style (#632)', () {
      /// Presses and releases [button] on the wire, letting the decoded event
      /// reach the cubit.
      Future<void> stomp(PedalButton button) async {
        transport
          ..press(button, down: true)
          ..press(button, down: false);
        await pumpEventQueue();
      }

      /// Holds [button] past the 500 ms long-press threshold, then releases.
      /// Real delays (not fake_async) — the wire events reach the cubit
      /// through the repository's stream, which a fake clock cannot pump.
      Future<void> hold(PedalButton button) async {
        transport.press(button, down: true);
        await pumpEventQueue();
        await Future<void>.delayed(const Duration(milliseconds: 600));
        transport.press(button, down: false);
        await pumpEventQueue();
      }

      test('defaults to cycleThree — existing rigs see no change', () {
        expect(cubit.state.modeSwitchStyle, ModeSwitchStyle.cycleThree);
      });

      test(
        'holdFx: a pedal MODE tap cycles Record <-> Mute and never lands '
        'on FX',
        () async {
          await cubit.setModeSwitchStyle(ModeSwitchStyle.holdFx);
          await stomp(PedalButton.mode);
          expect(cubit.state.mode, InteractionMode.mute);
          await stomp(PedalButton.mode);
          expect(cubit.state.mode, InteractionMode.record);
          await stomp(PedalButton.mode);
          expect(cubit.state.mode, InteractionMode.mute);
        },
      );

      test(
        'holdFx: toggleMode (keyboard M / on-screen chip) still cycles all '
        'three modes — the setting governs the pedal only, so FX stays '
        'reachable with no pedal plugged in',
        () async {
          await cubit.setModeSwitchStyle(ModeSwitchStyle.holdFx);
          cubit.toggleMode();
          expect(cubit.state.mode, InteractionMode.mute);
          cubit.toggleMode();
          expect(cubit.state.mode, InteractionMode.fx);
          cubit.toggleMode();
          expect(cubit.state.mode, InteractionMode.record);
        },
      );

      test('holdFx: a MODE hold enters FX and a second hold returns to '
          'record', () async {
        await cubit.setModeSwitchStyle(ModeSwitchStyle.holdFx);
        await hold(PedalButton.mode);
        expect(cubit.state.mode, InteractionMode.fx);
        await hold(PedalButton.mode);
        expect(cubit.state.mode, InteractionMode.record);
      });

      test('holdFx: a second hold returns to MUTE when FX was entered from '
          'mute — the return mode is wherever the foot was', () async {
        await cubit.setModeSwitchStyle(ModeSwitchStyle.holdFx);
        await stomp(PedalButton.mode); // record -> mute
        expect(cubit.state.mode, InteractionMode.mute);
        await hold(PedalButton.mode); // mute -> fx
        expect(cubit.state.mode, InteractionMode.fx);
        await hold(PedalButton.mode); // fx -> back to mute, not record
        expect(cubit.state.mode, InteractionMode.mute);
      });

      test('holdFx: a MODE tap while in FX also returns to the entered-from '
          'mode — a stray tap can never strand the foot', () async {
        await cubit.setModeSwitchStyle(ModeSwitchStyle.holdFx);
        await stomp(PedalButton.mode); // record -> mute
        await hold(PedalButton.mode); // mute -> fx
        await stomp(PedalButton.mode); // fx -> back to mute
        expect(cubit.state.mode, InteractionMode.mute);
      });

      test('holdFx: the mode and its LED frame flip AT the hold threshold, '
          'not at release', () async {
        await cubit.setModeSwitchStyle(ModeSwitchStyle.holdFx);

        // Press and stay held: below the threshold nothing flips — the LEDs
        // keep showing the mode the foot is still in.
        transport.press(PedalButton.mode, down: true);
        await pumpEventQueue();
        expect(cubit.state.mode, InteractionMode.record);
        expect(
          transport.lastFrame?.mode,
          PedalMode.rec,
        );

        // Past the threshold, foot STILL down: the mode has flipped and the
        // pushed frame already carries FX.
        await Future<void>.delayed(const Duration(milliseconds: 600));
        expect(cubit.state.mode, InteractionMode.fx);
        expect(
          transport.lastFrame?.mode,
          PedalMode.fx,
        );

        // The release is silent — the hold retired the tap action.
        transport.press(PedalButton.mode, down: false);
        await pumpEventQueue();
        expect(cubit.state.mode, InteractionMode.fx);
      });

      test('holdFx: the MODE hold no longer arms performance recording — the '
          'hold is the FX door instead', () async {
        await cubit.setModeSwitchStyle(ModeSwitchStyle.holdFx);
        await hold(PedalButton.mode);
        expect(cubit.state.mode, InteractionMode.fx);
        expect(performance.armedDirectory, isNull);
      });

      // #677: with the MODE hold gone to the FX door, BANK carries the
      // recording hold under holdFx — and stays a plain press under
      // cycleThree, where the MODE hold still arms.
      test('cycleThree: a BANK hold stays a plain press-time bank toggle '
          'and never arms recording — regression pin', () async {
        expect(cubit.state.modeSwitchStyle, ModeSwitchStyle.cycleThree);
        // The toggle fires ON the press, before any threshold could elapse —
        // no gesture is armed under this style.
        transport.press(PedalButton.bank, down: true);
        await pumpEventQueue();
        expect(cubit.state.activeBank, 1);
        expect(cubit.state.cursor, ControlState.tracksPerBank);
        // Held past the threshold: the hold means nothing and the release
        // adds nothing.
        await Future<void>.delayed(const Duration(milliseconds: 600));
        transport.press(PedalButton.bank, down: false);
        await pumpEventQueue();
        expect(cubit.state.activeBank, 1);
        expect(performance.armedDirectory, isNull);
      });

      test('holdFx: a BANK tap still toggles the bank — moved to the '
          'release, the price of telling a tap from a hold', () async {
        await cubit.setModeSwitchStyle(ModeSwitchStyle.holdFx);
        transport.press(PedalButton.bank, down: true);
        await pumpEventQueue();
        // Below the threshold nothing has happened yet.
        expect(cubit.state.activeBank, 0);
        transport.press(PedalButton.bank, down: false);
        await pumpEventQueue();
        expect(cubit.state.activeBank, 1);
        expect(cubit.state.cursor, ControlState.tracksPerBank);
        expect(performance.armedDirectory, isNull);
      });

      test('holdFx: a BANK hold arms performance recording and does NOT '
          'toggle the bank — the pedal path the MODE hold gave up', () async {
        await cubit.setModeSwitchStyle(ModeSwitchStyle.holdFx);
        final armed = awaitStatus(performance, PerformanceCaptureStatus.armed);
        await hold(PedalButton.bank);
        await armed;
        expect(performance.armedDirectory, isNotNull);
        expect(cubit.state.activeBank, 0); // the hold retired the tap
        expect(cubit.state.cursor, 0);
        expect(cubit.state.mode, InteractionMode.record); // untouched
      });

      test('holdFx: a second BANK hold disarms again', () async {
        await cubit.setModeSwitchStyle(ModeSwitchStyle.holdFx);
        final armed = awaitStatus(performance, PerformanceCaptureStatus.armed);
        await hold(PedalButton.bank);
        await armed;
        expect(performance.armedDirectory, isNotNull);

        // Past disarm's double-press guard window (D-GUARD) — the fake clock
        // does not advance with the real 600 ms long-press delay.
        clock = clock.add(PerformanceRepository.disarmGuardWindow * 2);

        // `done`, not the first non-armed status: disarm passes through
        // `finalizing` and only clears the directory at the end of it.
        final disarmed = awaitStatus(
          performance,
          PerformanceCaptureStatus.done,
        );
        await hold(PedalButton.bank);
        await disarmed;
        expect(performance.armedDirectory, isNull);
      });

      test('holdFx: the frame pushed through a BANK-hold arm carries the '
          'armed light and still shows bank A', () async {
        await cubit.setModeSwitchStyle(ModeSwitchStyle.holdFx);
        await pumpEventQueue();
        transport.sent.clear();

        final armed = awaitStatus(performance, PerformanceCaptureStatus.armed);
        // Press and stay held: below the threshold nothing is pushed for the
        // bank and nothing is armed.
        transport.press(PedalButton.bank, down: true);
        await pumpEventQueue();
        expect(performance.armedDirectory, isNull);

        // Past the threshold, foot STILL down: the arm has landed and the
        // pushed frame already carries it — commit-at-threshold, like the
        // MODE hold's own FX flip.
        await Future<void>.delayed(const Duration(milliseconds: 600));
        await armed;
        await pumpEventQueue();
        final frame = transport.lastFrame;
        expect(frame?.performanceArmed, isTrue);
        expect(frame?.activeBank, 0);

        // The release is silent — the hold retired the bank toggle.
        transport.press(PedalButton.bank, down: false);
        await pumpEventQueue();
        expect(cubit.state.activeBank, 0);
        expect(
          transport.lastFrame?.performanceArmed,
          isTrue,
        );
      });

      test('a style change clears the FX return latch — a mute latched under '
          'an earlier holdFx spell is not read after a round-trip', () async {
        await cubit.setModeSwitchStyle(ModeSwitchStyle.holdFx);
        await stomp(PedalButton.mode); // record -> mute
        await hold(PedalButton.mode); // mute -> fx (latch = mute)
        await hold(PedalButton.mode); // fx -> mute (latch still = mute)
        await cubit.setModeSwitchStyle(ModeSwitchStyle.cycleThree);
        cubit.toggleMode(); // mute -> fx, the three-way cycle, no latch
        expect(cubit.state.mode, InteractionMode.fx);
        await cubit.setModeSwitchStyle(ModeSwitchStyle.holdFx);
        // The hold out of FX honours the record FALLBACK, not the mute the
        // earlier holdFx spell latched: the style change dropped it.
        await hold(PedalButton.mode);
        expect(cubit.state.mode, InteractionMode.record);
      });

      test('holdFx: FX entered from the keyboard/chip (toggleMode) still '
          'exits to the mode it was entered from — the latch rides setMode, '
          'the one entry point, not only the hold', () async {
        await cubit.setModeSwitchStyle(ModeSwitchStyle.holdFx);
        await hold(PedalButton.mode); // record -> fx (an earlier hold session)
        await hold(PedalButton.mode); // fx -> record
        await stomp(PedalButton.mode); // record -> mute; perform here
        cubit.toggleMode(); // keyboard M: mute -> fx
        expect(cubit.state.mode, InteractionMode.fx);
        // The pedal TAP out of FX lands in MUTE — the mode the M key left —
        // not the record the earlier hold session latched.
        await stomp(PedalButton.mode);
        expect(cubit.state.mode, InteractionMode.mute);
        // And the pedal HOLD out honours the same latch.
        cubit.toggleMode(); // mute -> fx again
        await hold(PedalButton.mode);
        expect(cubit.state.mode, InteractionMode.mute);
      });

      test('setModeSwitchStyle persists the token', () async {
        await cubit.setModeSwitchStyle(ModeSwitchStyle.holdFx);
        expect(cubit.state.modeSwitchStyle, ModeSwitchStyle.holdFx);
        expect(
          await settings.loadModeSwitchStyle(),
          ModeSwitchStyle.holdFx.token,
        );
      });

      test('load restores the persisted style', () async {
        await settings.saveModeSwitchStyle(ModeSwitchStyle.holdFx.token);
        await cubit.load();
        expect(cubit.state.modeSwitchStyle, ModeSwitchStyle.holdFx);
      });

      test('an unknown stored token falls back to cycleThree', () async {
        await settings.saveModeSwitchStyle('sideways');
        await cubit.load();
        expect(cubit.state.modeSwitchStyle, ModeSwitchStyle.cycleThree);
      });
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

      /// Holds [button] past the 500 ms long-press threshold, then releases.
      /// Real delays (not fake_async) — the wire events reach the cubit
      /// through the repository's stream, which a fake clock cannot pump.
      Future<void> hold(PedalButton button) async {
        transport.press(button, down: true);
        await pumpEventQueue();
        await Future<void>.delayed(const Duration(milliseconds: 600));
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

      test('Stop is FX panic: every Track chain off', () async {
        trackChains[1] = [BuiltInEffect(type: TrackEffectType.drive)];
        trackChains[5] = [BuiltInEffect(type: TrackEffectType.reverb)];

        await stomp(PedalButton.stop);

        for (final channel in [1, 5]) {
          verify(
            () => looper.setTrackChainEnabled(channel: channel, enabled: false),
          ).called(1);
        }
      });

      test('FX panic leaves a track with NO chain alone — a bypass persisted '
          'for an empty chain would silently mute the effects added to that '
          'track later, and the boot restore replays it forever', () async {
        trackChains[1] = [BuiltInEffect(type: TrackEffectType.drive)];

        await stomp(PedalButton.stop);

        expect(chainEnabled, {1: false}, reason: 'only the real chain flips');
        for (final channel in [0, 2, 3, 4, 5, 6, 7]) {
          verifyNever(
            () => looper.setTrackChainEnabled(channel: channel, enabled: false),
          );
          expect(await settings.loadTrackFxChain(channel), isNull);
        }
      });

      test('the FX panic fires on the PRESS, so a synthetic release (the '
          'plate releasing a held switch as it leaves the tree) cannot '
          'bypass anything on its own', () async {
        trackChains[1] = [BuiltInEffect(type: TrackEffectType.drive)];

        // Press only — no release yet.
        transport.press(PedalButton.stop, down: true);
        await pumpEventQueue();
        expect(chainEnabled[1], isFalse, reason: 'panic landed on the press');

        // A release on its own is inert: it only retires the pending hold.
        chainEnabled.clear();
        transport.press(PedalButton.stop, down: false);
        await pumpEventQueue();
        expect(chainEnabled, isEmpty);
      });

      test('a Stop LONG-PRESS follows the panic with a restore', () async {
        trackChains[1] = [BuiltInEffect(type: TrackEffectType.drive)];

        await hold(PedalButton.stop);

        // The press panicked, the hold restored — landing on the state the
        // restore promises regardless of what the pattern was before.
        verify(
          () => looper.setTrackChainEnabled(channel: 1, enabled: false),
        ).called(1);
        verify(
          () => looper.setTrackChainEnabled(channel: 1, enabled: true),
        ).called(1);
        expect(chainEnabled[1], isTrue);
      });

      test('a Stop hold that leaves FX mode before the threshold does not '
          'restore from a mode with no chain LEDs', () async {
        trackChains[1] = [BuiltInEffect(type: TrackEffectType.drive)];

        transport.press(PedalButton.stop, down: true);
        await pumpEventQueue();
        expect(chainEnabled[1], isFalse); // the press panicked

        cubit.setMode(InteractionMode.record); // foot leaves FX mid-hold
        await Future<void>.delayed(const Duration(milliseconds: 600));
        transport.press(PedalButton.stop, down: false);
        await pumpEventQueue();

        verifyNever(
          () => looper.setTrackChainEnabled(channel: 1, enabled: true),
        );
        expect(chainEnabled[1], isFalse);
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
        transport.turn(4);
        await pumpEventQueue();
        verify(() => looper.setMasterGain(any())).called(1);
      });

      test(
        'MODE long-press still arms performance recording (unchanged)',
        () async {
          final armed = awaitStatus(
            performance,
            PerformanceCaptureStatus.armed,
          );
          await hold(PedalButton.mode);
          await armed;
          expect(performance.armedDirectory, isNotNull);
          expect(cubit.state.mode, InteractionMode.fx); // not a mode cycle
        },
      );

      test('a MODE tap cycles out of FX back to record', () async {
        await stomp(PedalButton.mode);
        expect(cubit.state.mode, InteractionMode.record);
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

      test('a panic over already-disabled chains writes nothing twice', () {
        trackChains[1] = [BuiltInEffect(type: TrackEffectType.drive)];
        cubit
          ..panicTrackChains()
          ..panicTrackChains();
        verify(
          () => looper.setTrackChainEnabled(channel: 1, enabled: false),
        ).called(1);
      });
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
        final locked = ControlCubit(
          looper: looper,
          pedal: pedal,
          settings: settings,
          performance: performance,
          takeLocked: () => true,
        );
        addTearDown(locked.close);
        locked.recPlay();
        verifyNever(() => looper.record());
      });

      test('takeLocked suppresses rec-mode trackPressed', () {
        final locked = ControlCubit(
          looper: looper,
          pedal: pedal,
          settings: settings,
          performance: performance,
          takeLocked: () => true,
        );
        addTearDown(locked.close);
        locked.trackPressed(2);
        expect(locked.state.cursor, 0);
      });

      test('takeLocked suppresses togglePerformanceRecord', () {
        final locked = ControlCubit(
          looper: looper,
          pedal: pedal,
          settings: settings,
          performance: performance,
          takeLocked: () => true,
        );
        addTearDown(locked.close);
        locked.togglePerformanceRecord();
        expect(performance.armedDirectory, isNull);
      });

      test('takeLocked suppresses pedal Clear', () async {
        final lockedTransport = FakePedalLink();
        final lockedPedal = PedalRepository(lockedTransport);
        addTearDown(lockedPedal.dispose);
        final locked = ControlCubit(
          looper: looper,
          pedal: lockedPedal,
          settings: settings,
          performance: performance,
          takeLocked: () => true,
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
        expect(cubit.state.parkedResume, isEmpty); // consumed
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
        verify(() => looper.record()).called(1); // finalize first
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

          verify(() => looper.clear()).called(1);
          verify(() => looper.clear(channel: 1)).called(1); // redo path wiped
          verifyNever(() => looper.clear(channel: 2));
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
          final armedCubit = ControlCubit(
            looper: looper,
            pedal: pedal,
            settings: settings,
            performance: recordingPerformance,
          );
          addTearDown(armedCubit.close);

          await recordingPerformance.arm();
          await pumpEventQueue(); // deliver captureStatus.armed to the cubit

          setEngine(
            _tracksWith(const [
              Track(state: TrackState.playing, lengthFrames: 48000),
            ]),
          );
          when(() => looper.clear(channel: any(named: 'channel'))).thenAnswer((
            _,
          ) {
            log.add('looper.clear');
            return EngineResult.ok;
          });

          await armedCubit.clearAll();

          expect(log, ['persistLiveLanes', 'looper.clear']);
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
        final unarmedCubit = ControlCubit(
          looper: looper,
          pedal: pedal,
          settings: settings,
          performance: unarmedPerformance,
        );
        addTearDown(unarmedCubit.close);

        await unarmedCubit.clearAll();

        expect(log, isEmpty);
        verify(() => looper.clear()).called(1);
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
          final armedCubit = ControlCubit(
            looper: looper,
            pedal: pedal,
            settings: settings,
            performance: recordingPerformance,
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
          verify(() => looper.clear()).called(1);
        },
      );
    });

    group('undoClearAll', () {
      test(
        'undoes every track holding a clear restore point, and only those',
        () {
          setEngine(
            _tracksWith(const [
              Track(clearRestore: true),
              Track(channel: 1, state: TrackState.playing, lengthFrames: 48000),
              Track(channel: 2, clearRestore: true),
              // Peelable layer, not a clear restore point.
              Track(
                channel: 3,
                state: TrackState.playing,
                lengthFrames: 48000,
                undoDepth: 2,
              ),
            ]),
          );

          cubit.undoClearAll();

          // Exactly the two pending-clear channels are restored.
          verify(() => looper.undo()).called(1);
          verify(() => looper.undo(channel: 2)).called(1);
          verifyNever(() => looper.undo(channel: 1));
          verifyNever(() => looper.undo(channel: 3));
          for (var channel = 4; channel < 8; channel++) {
            verifyNever(() => looper.undo(channel: channel));
          }
        },
      );

      test('is a no-op when no track holds a clear restore point', () {
        setEngine(
          _tracksWith(const [
            Track(state: TrackState.playing, lengthFrames: 48000),
            Track(
              channel: 1,
              state: TrackState.playing,
              lengthFrames: 48000,
              undoDepth: 3,
            ),
          ]),
        );

        cubit.undoClearAll();

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
          final wired = ControlCubit(
            looper: looper,
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
        transport.press(PedalButton.bank, down: true);
        await pumpEventQueue();
        expect(cubit.state.activeBank, 1);
        expect(cubit.state.cursor, 4);
      });

      test('a track press targets the visible bank base', () async {
        transport.press(PedalButton.bank, down: true); // -> bank B
        await pumpEventQueue();
        transport.press(PedalButton.track3, down: true);
        await pumpEventQueue();
        // track3 == index 2, bank B base 4 -> channel 6 (idle press selects).
        expect(cubit.state.cursor, 6);
      });

      test('the encoder drives the master gain', () async {
        transport.turn(-8); // -8 detents
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

        verify(() => looper.clear()).called(1);
        verify(() => looper.clear(channel: 1)).called(1);
        verifyNever(() => looper.clear(channel: 2));
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
          // Default long-press threshold is 500 ms.
          await Future<void>.delayed(const Duration(milliseconds: 600));
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

      group('mode press timing (D-PEDAL)', () {
        test('tap toggles mode and does NOT arm/disarm performance '
            'recording', () async {
          expect(cubit.state.mode, InteractionMode.record);
          transport
            ..press(PedalButton.mode, down: true) // press
            ..press(PedalButton.mode, down: false); // quick release == tap
          await pumpEventQueue();

          expect(cubit.state.mode, InteractionMode.mute);
          expect(performance.armedDirectory, isNull);
        });

        test(
          'long-press arms performance recording and does NOT flip mode',
          () async {
            final armed = awaitStatus(
              performance,
              PerformanceCaptureStatus.armed,
            );
            transport.press(PedalButton.mode, down: true);
            // Default long-press threshold is 500 ms.
            await Future<void>.delayed(const Duration(milliseconds: 600));
            transport.press(PedalButton.mode, down: false);
            await armed;

            expect(cubit.state.mode, InteractionMode.record); // unchanged
            expect(performance.armedDirectory, isNotNull);
          },
        );

        test('a long-press then a second long-press disarms again', () async {
          final armed = awaitStatus(
            performance,
            PerformanceCaptureStatus.armed,
          );
          transport.press(PedalButton.mode, down: true);
          await Future<void>.delayed(const Duration(milliseconds: 600));
          transport.press(PedalButton.mode, down: false);
          await armed;
          expect(performance.armedDirectory, isNotNull);

          // Past disarm's double-press guard window (D-GUARD) — the fake
          // clock does not advance with the real 600ms long-press delay
          // above, so it must be moved explicitly for the second long-press
          // to actually disarm rather than be guarded.
          clock = clock.add(PerformanceRepository.disarmGuardWindow * 2);

          // `done`, not the first non-armed status: disarm passes through
          // `finalizing` and only clears the directory at the end of it.
          final disarmed = awaitStatus(
            performance,
            PerformanceCaptureStatus.done,
          );
          transport.press(PedalButton.mode, down: true);
          await Future<void>.delayed(const Duration(milliseconds: 600));
          transport.press(PedalButton.mode, down: false);
          await disarmed;

          expect(performance.armedDirectory, isNull);
        });

        test(
          'a release with no matching press does not cycle the mode',
          () async {
            transport.press(PedalButton.mode, down: false); // release only
            await pumpEventQueue();

            expect(cubit.state.mode, InteractionMode.record); // unchanged
            expect(performance.armedDirectory, isNull);
          },
        );
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
          'MODE still cycles the mode and Bank still switches banks',
          () async {
            await cubit.setGlobalBindings(
              PedalBindingSet([bind(PedalButton.mode), bind(PedalButton.bank)]),
            );

            await stomp(PedalButton.bank);
            expect(cubit.state.activeBank, 1);
            expect(chainEnabled.containsKey(3), isFalse);

            await stomp(PedalButton.mode);
            expect(cubit.state.mode, InteractionMode.record);
          },
        );
      });

      group('long-press system gestures survive a remap (B12)', () {
        test('a bound Stop runs its binding on the press but KEEPS the '
            "restore-all hold — the panic's only undo must stay reachable "
            'whatever the user mapped', () async {
          trackChains[1] = [BuiltInEffect(type: TrackEffectType.drive)];
          await cubit.setGlobalBindings(
            PedalBindingSet([bind(PedalButton.stop)]),
          );

          await press(PedalButton.stop);
          expect(chainEnabled[3], isFalse, reason: 'the binding ran');
          expect(chainEnabled.containsKey(1), isFalse, reason: 'no panic');

          await Future<void>.delayed(const Duration(milliseconds: 600));
          await release(PedalButton.stop);

          // The hold restored every Track chain, the one the binding had just
          // bypassed included. Channel 1 was never bypassed (the binding took
          // the press instead of the panic), so the sweep skips it as a no-op
          // rather than writing a flag it already holds.
          expect(chainEnabled[3], isTrue, reason: 'the hold restored it');
          expect(chainEnabled.containsKey(1), isFalse);
        });

        test('MODE long-press still arms performance recording', () async {
          await cubit.setGlobalBindings(
            PedalBindingSet([bind(PedalButton.mode)]),
          );
          final armed = awaitStatus(
            performance,
            PerformanceCaptureStatus.armed,
          );
          await press(PedalButton.mode);
          await Future<void>.delayed(const Duration(milliseconds: 600));
          await release(PedalButton.mode);
          await armed;

          expect(performance.armedDirectory, isNotNull);
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

        final reloaded = ControlCubit(
          looper: looper,
          pedal: pedal,
          settings: settings,
          performance: performance,
        );
        addTearDown(reloaded.close);
        await reloaded.load();
        expect(reloaded.state.globalBindings, set);
      });
    });

    group('frame projection (frames out via PedalRepository)', () {
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
        transport.turn(-8);
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
          addTearDown(idlePedal.dispose);
          final idle = ControlCubit(
            looper: looper,
            pedal: idlePedal,
            settings: settings,
            performance: performance,
          );
          addTearDown(idle.close);
          expect(idleLink.lastFrame, isNull, reason: 'nothing before load()');
          await idle.load();
          expect(idleLink.lastFrame, isNotNull);
        },
      );

      test('Clear LED lights while the footswitch is held and darkens on '
          'release', () async {
        setEngine(_emptyTracks());
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

      test('sends a loop-top pulse when the playhead wraps', () async {
        setEngine(_emptyTracks(), masterPositionFrames: 40000);
        await pumpEventQueue();
        transport.sent.clear();
        setEngine(_emptyTracks(), masterPositionFrames: 10);
        await pumpEventQueue();

        expect(
          transport.sent.any((m) => m is LoopTopMessage),
          isTrue,
        );
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
