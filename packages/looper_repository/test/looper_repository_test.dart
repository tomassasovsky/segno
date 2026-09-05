import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
// The audio-config + effect types are domain types here (from the barrel); the
// engine-typed fixtures fed to the fake engine use the `le` prefix.
import 'package:segno_engine/segno_engine.dart'
    hide
        AudioBackend,
        AudioDevice,
        BuiltInEffect,
        EngineConfig,
        LatencyState,
        LoopbackInfo,
        LoopbackKind,
        ParamReadout,
        PluginEffect,
        PluginFormat,
        PluginParamInfo,
        PluginRef,
        TrackEffect,
        TrackEffectParam,
        TrackEffectType,
        encodeTrackEffects;
import 'package:segno_engine/segno_engine.dart'
    as le
    show
        AudioDevice,
        LatencyState,
        LoopbackInfo,
        LoopbackKind,
        PluginDescriptor,
        PluginFormat,
        PluginParamInfo;

import 'helpers/fake_audio_engine.dart';

final EngineSnapshot _playingSnapshot = _playingAt(24000);

/// One playing track with independently controlled transport and meter values.
EngineSnapshot _playingAt(int masterPositionFrames, {double peak = 0.5}) =>
    EngineSnapshot(
      isRunning: true,
      sampleRate: 48000,
      bufferFrames: 128,
      inputChannels: 2,
      outputChannels: 4,
      framesProcessed: 0,
      xrunCount: 0,
      inputRms: 0,
      inputPeak: 0,
      outputRms: 0,
      latencyState: le.LatencyState.idle,
      measuredLatencyMs: -1,
      masterLengthFrames: 96000,
      masterPositionFrames: masterPositionFrames,
      tracks: [
        TrackSnapshot(
          state: TrackState.playing,
          volume: 0.8,
          muted: false,
          lengthFrames: 96000,
          undoDepth: 1,
          rms: 0.3,
          peak: peak,
          inputMask: 0x2,
          outputMask: 0x2,
        ),
      ],
    );

/// One playing track with one real lane — the cache-telemetry gate is a
/// per-lane concern, and [_playingSnapshot]'s tracks carry no lanes.
const _laneSnapshot = EngineSnapshot(
  isRunning: true,
  sampleRate: 48000,
  bufferFrames: 128,
  inputChannels: 2,
  outputChannels: 4,
  framesProcessed: 0,
  xrunCount: 0,
  inputRms: 0,
  inputPeak: 0,
  outputRms: 0,
  latencyState: le.LatencyState.idle,
  measuredLatencyMs: -1,
  masterLengthFrames: 96000,
  tracks: [
    TrackSnapshot(
      state: TrackState.playing,
      volume: 1,
      muted: false,
      lengthFrames: 96000,
      undoDepth: 0,
      rms: 0,
      peak: 0,
      lanes: [
        LaneSnapshot(
          inputChannel: 0,
          outputMask: 0x3,
          volume: 1,
          muted: false,
          lengthFrames: 96000,
          rms: 0,
          peak: 0,
        ),
      ],
    ),
  ],
);

void main() {
  late FakeAudioEngine engine;
  late StreamController<void> ticker;

  setUp(() {
    engine = FakeAudioEngine();
    ticker = StreamController<void>.broadcast();
  });

  tearDown(() => ticker.close());

  LooperRepository buildRepo() =>
      LooperRepository(engine: engine, ticker: ticker.stream);

  group('cache telemetry gate', () {
    // The shared snapshot above carries no lanes, and this gate is entirely
    // about per-LANE reads — so seed one lane to observe.
    setUp(() => engine.nextSnapshot = _laneSnapshot);

    test('is off by default and polls no lane', () {
      final repo = buildRepo();
      addTearDown(repo.dispose);

      expect(repo.cacheTelemetryEnabled, isFalse);
      expect(
        repo.state.tracks.first.lanes.first.cacheState,
        isNull,
        reason: 'unobserved is not the same as live',
      );
      // The point of the gate: a cache-state sweep drains the engine and runs
      // a scheduler pass, so an off gate must not merely hide the result — it
      // must not ask.
      expect(engine.laneCacheSweeps, 0);
    });

    test('turning it on republishes immediately with observed states', () {
      final repo = buildRepo();
      addTearDown(repo.dispose);
      engine.seededLaneCacheStates[(0, 0)] = LaneCacheState.cached;

      repo.setCacheTelemetryEnabled(enabled: true);

      expect(
        repo.state.tracks.first.lanes.first.cacheState,
        LaneCacheState.cached,
      );
      expect(engine.laneCacheSweeps, 1);
    });

    test('turning it back off clears every lane state and stops reading', () {
      final repo = buildRepo()..setCacheTelemetryEnabled(enabled: true);
      addTearDown(repo.dispose);
      engine.laneCacheSweeps = 0;

      repo.setCacheTelemetryEnabled(enabled: false);

      expect(repo.state.tracks.first.lanes.first.cacheState, isNull);
      expect(engine.laneCacheSweeps, 0);
    });

    test(
      'a local edit reuses the last refresh instead of re-reading the engine',
      () {
        // _reproject() runs on every local edit — including each frame of a
        // dragged FX knob. Reading telemetry there would put a drain plus a
        // scheduler sweep inside the gesture _reproject exists to keep
        // responsive, so the projection must reuse the polled states.
        final repo = buildRepo()..setCacheTelemetryEnabled(enabled: true);
        addTearDown(repo.dispose);
        repo.setLaneEffects(
          channel: 0,
          lane: 0,
          effects: [BuiltInEffect(type: TrackEffectType.drive)],
        );
        engine.laneCacheSweeps = 0;

        for (var i = 0; i < 10; i++) {
          repo.setLaneEffectParam(
            channel: 0,
            lane: 0,
            index: 0,
            param: 0,
            value: i / 10,
          );
        }

        expect(engine.laneCacheSweeps, 0);
      },
    );

    test('a poll runs exactly one batched sweep', () {
      final repo = buildRepo()..setCacheTelemetryEnabled(enabled: true);
      addTearDown(repo.dispose);
      final sub = repo.looperState.listen((_) {});
      addTearDown(sub.cancel);
      engine.laneCacheSweeps = 0;

      ticker.add(null);

      // One tick, ONE sweep for every lane at once (#418) — never a per-lane
      // read loop, and no duplicate from a projection that also polls.
      return Future<void>.delayed(Duration.zero, () {
        expect(engine.laneCacheSweeps, 1);
      });
    });

    test('setting the same value is a no-op', () {
      final repo = buildRepo();
      addTearDown(repo.dispose);
      engine.laneCacheSweeps = 0;

      repo.setCacheTelemetryEnabled(enabled: false);

      // No republish, so no sweep — the guard is what keeps a redundant
      // preference write from costing a full poll.
      expect(engine.laneCacheSweeps, 0);
    });
  });

  group('poll interval', () {
    test('reports and updates the configured cadence', () {
      final repo = LooperRepository(
        engine: engine,
        ticker: ticker.stream,
        pollInterval: const Duration(milliseconds: 32),
      );
      addTearDown(repo.dispose);

      expect(repo.pollInterval, const Duration(milliseconds: 32));

      repo.setPollInterval(const Duration(milliseconds: 8));
      expect(repo.pollInterval, const Duration(milliseconds: 8));

      // Setting the same value is a no-op.
      repo.setPollInterval(const Duration(milliseconds: 8));
      expect(repo.pollInterval, const Duration(milliseconds: 8));
    });

    test('default-timer polling keeps running after a cadence change', () {
      // No injected ticker: the real Timer path is exercised.
      final repo = LooperRepository(
        engine: engine,
        pollInterval: const Duration(milliseconds: 32),
      );
      addTearDown(repo.dispose);

      // Subscribing starts the default poll timer.
      final sub = repo.looperState.listen((_) {});
      addTearDown(sub.cancel);

      repo.setPollInterval(const Duration(milliseconds: 8));
      expect(repo.pollInterval, const Duration(milliseconds: 8));
    });
  });

  group('projection', () {
    test('maps a snapshot into looper domain models', () {
      engine.nextSnapshot = _playingSnapshot;
      final repo = buildRepo();

      final state = repo.state;
      expect(state.transport.isRunning, isTrue);
      expect(state.transport.masterLengthFrames, 96000);
      expect(state.transport.masterPositionFrames, 24000);
      expect(state.transport.progress, closeTo(0.25, 1e-6));
      expect(state.track.state, TrackState.playing);
      expect(state.track.volume, closeTo(0.8, 1e-6));
      expect(state.track.muted, isFalse);
      expect(state.track.lengthFrames, 96000);
      expect(state.track.peak, closeTo(0.5, 1e-6));
      expect(state.track.canUndo, isTrue);
      expect(state.track.hasContent, isTrue);
      expect(state.track.inputMask, 0x2);
      expect(state.track.outputMask, 0x2);
      expect(state.status.deviceName, 'Fake Device');
      expect(state.status.sampleRate, 48000);
      expect(state.status.inputChannels, 2);
      expect(state.status.outputChannels, 4);
      expect(state.status.isConnected, isTrue);
    });

    test('the master playhead moving does not change any track', () {
      // The transport position belongs to the TRANSPORT. Copying it onto every
      // `Track` (as `playheadFrames` once did) made all eight tracks compare
      // unequal on every poll tick of a running loop, regardless of their own
      // levels — which silently put every track tile back on the rebuild path
      // #646/#654/#832 built to keep it off.
      engine.nextSnapshot = _playingSnapshot;
      final repo = buildRepo();
      final before = repo.state;

      engine.nextSnapshot = _playingAt(48000);
      final after = repo.state;

      expect(after.transport.masterPositionFrames, 48000);
      expect(
        after.tracks,
        before.tracks,
        reason: 'a track carries a copy of the master transport position',
      );
    });

    test('projects multiple tracks with their channel indices', () {
      engine.nextSnapshot = const EngineSnapshot(
        isRunning: true,
        sampleRate: 48000,
        bufferFrames: 128,
        framesProcessed: 0,
        xrunCount: 0,
        inputRms: 0,
        inputPeak: 0,
        outputRms: 0,
        latencyState: le.LatencyState.idle,
        measuredLatencyMs: -1,
        masterLengthFrames: 48000,
        tracks: [
          TrackSnapshot(
            state: TrackState.playing,
            volume: 1,
            muted: false,
            lengthFrames: 48000,
            undoDepth: 0,
            rms: 0,
            peak: 0,
          ),
          TrackSnapshot(
            state: TrackState.overdubbing,
            volume: 0.5,
            muted: true,
            lengthFrames: 48000,
            undoDepth: 1,
            rms: 0,
            peak: 0,
          ),
        ],
      );
      final state = buildRepo().state;
      expect(state.tracks, hasLength(2));
      expect(state.tracks[0].channel, 0);
      expect(state.tracks[1].channel, 1);
      expect(state.tracks[1].state, TrackState.overdubbing);
      expect(state.tracks[1].muted, isTrue);
      expect(state.hasContent, isTrue);
    });

    test('maps a per-lane snapshot into Track.lanes', () {
      engine
        ..nextSnapshot = const EngineSnapshot(
          isRunning: true,
          sampleRate: 48000,
          bufferFrames: 128,
          framesProcessed: 0,
          xrunCount: 0,
          inputRms: 0,
          inputPeak: 0,
          outputRms: 0,
          latencyState: le.LatencyState.idle,
          measuredLatencyMs: -1,
          masterLengthFrames: 48000,
          tracks: [
            TrackSnapshot(
              state: TrackState.playing,
              volume: 1,
              muted: false,
              lengthFrames: 48000,
              undoDepth: 0,
              rms: 0,
              peak: 0,
              lanes: [
                LaneSnapshot(
                  inputChannel: 0,
                  outputMask: 0x1,
                  volume: 0.8,
                  muted: false,
                  lengthFrames: 48000,
                  rms: 0.2,
                  peak: 0.4,
                ),
                LaneSnapshot(
                  inputChannel: 1,
                  outputMask: 0x2,
                  volume: 0.5,
                  muted: true,
                  lengthFrames: 48000,
                  rms: 0,
                  peak: 0,
                ),
              ],
            ),
          ],
        )
        // Remembered lane-1 effects are attached to the projected lane.
        ..startResult = EngineResult.ok;
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setLaneEffects(
          channel: 0,
          lane: 1,
          effects: [BuiltInEffect(type: TrackEffectType.drive)],
        );

      final track = repo.state.tracks[0];
      expect(track.lanes, hasLength(2));
      expect(track.lanes[0].inputChannel, 0);
      expect(track.lanes[0].outputMask, 0x1);
      expect(track.lanes[0].volume, closeTo(0.8, 1e-6));
      expect(track.lanes[0].effects, isEmpty);
      expect(track.lanes[1].inputChannel, 1);
      expect(track.lanes[1].muted, isTrue);
      expect(
        (track.lanes[1].effects.single as BuiltInEffect).type,
        TrackEffectType.drive,
      );
    });

    test('projects a track loop multiple', () {
      engine.nextSnapshot = const EngineSnapshot(
        isRunning: true,
        sampleRate: 48000,
        bufferFrames: 128,
        framesProcessed: 0,
        xrunCount: 0,
        inputRms: 0,
        inputPeak: 0,
        outputRms: 0,
        latencyState: le.LatencyState.idle,
        measuredLatencyMs: -1,
        masterLengthFrames: 48000,
        tracks: [
          TrackSnapshot(
            state: TrackState.playing,
            volume: 1,
            muted: false,
            lengthFrames: 96000,
            undoDepth: 0,
            rms: 0,
            peak: 0,
            multiple: 2,
          ),
        ],
      );
      final track = buildRepo().state.tracks.first;
      expect(track.multiple, 2);
      expect(track.isMultiple, isTrue);
      expect(track.lengthFrames, 96000);
    });

    test('initial snapshot projects an empty looper', () {
      final repo = buildRepo();
      final state = repo.state;
      expect(state.track.state, TrackState.empty);
      expect(state.track.hasContent, isFalse);
      expect(state.transport.hasLoop, isFalse);
      expect(state.transport.progress, 0);
    });

    test('projects the excluded input mask onto EngineStatus', () {
      engine.nextSnapshot = const EngineSnapshot(
        isRunning: true,
        sampleRate: 48000,
        bufferFrames: 128,
        inputChannels: 2,
        outputChannels: 2,
        excludedInputMask: 0x2,
        framesProcessed: 0,
        xrunCount: 0,
        inputRms: 0,
        inputPeak: 0,
        outputRms: 0,
        latencyState: le.LatencyState.idle,
        measuredLatencyMs: -1,
      );
      expect(buildRepo().state.status.excludedInputMask, 0x2);
    });

    test('projects the clip + conditioning masks onto EngineStatus', () {
      engine.nextSnapshot = const EngineSnapshot(
        isRunning: true,
        sampleRate: 48000,
        bufferFrames: 128,
        inputChannels: 4,
        outputChannels: 2,
        inputClipMask: 0x5,
        inputCondMask: 0x2,
        framesProcessed: 0,
        xrunCount: 0,
        inputRms: 0,
        inputPeak: 0,
        outputRms: 0,
        latencyState: le.LatencyState.idle,
        measuredLatencyMs: -1,
      );
      final status = buildRepo().state.status;
      expect(status.inputClipMask, 0x5);
      expect(status.inputCondMask, 0x2);
      expect(status.isInputHot(0), isTrue);
      expect(status.isInputHot(1), isFalse);
      expect(status.isInputHot(2), isTrue);
      expect(status.isInputHot(-1), isFalse);
      expect(status.isInputConditioned(1), isTrue);
      expect(status.isInputConditioned(0), isFalse);
      expect(status.isInputConditioned(32), isFalse);
    });

    test('projects fx added latency onto EngineStatus (frames + ms)', () {
      engine.nextSnapshot = const EngineSnapshot(
        isRunning: true,
        sampleRate: 48000,
        bufferFrames: 128,
        inputChannels: 2,
        outputChannels: 2,
        framesProcessed: 0,
        xrunCount: 0,
        inputRms: 0,
        inputPeak: 0,
        outputRms: 0,
        latencyState: le.LatencyState.idle,
        measuredLatencyMs: -1,
        fxAddedLatencyFrames: 1024,
      );
      final status = buildRepo().state.status;
      expect(status.fxAddedLatencyFrames, 1024);
      expect(status.fxAddedLatencyMs, closeTo(1024 * 1000 / 48000, 1e-9));
    });

    test('exposes the callback telemetry as a pull, not on the state', () {
      // A 64-frame period at 96 kHz — the appliance's real configuration, and
      // the one #722's clicks were characterised on. The armed window is worse
      // than the session as a whole: exactly the reading this is here to make
      // legible.
      engine.nextCallbackTelemetry = const CallbackTelemetry(
        budgetUs: 666,
        session: CallbackWindowStats(
          calls: 360000,
          periods: 90000,
          latePeriods: 12,
          gapEvents: 4,
          maxUs: 1900,
          meanUs: 140,
          maxGapUs: 4100,
          buckets: [80000, 9000, 800, 100, 50, 30, 8, 12],
          xruns: [4, 1, 0, 0],
        ),
        armed: CallbackWindowStats(
          calls: 120000,
          periods: 30000,
          latePeriods: 11,
          gapEvents: 4,
          maxUs: 1900,
          meanUs: 210,
          maxGapUs: 4100,
          buckets: [20000, 8000, 900, 50, 20, 10, 9, 11],
          xruns: [4, 1, 0, 0],
        ),
      );
      final telemetry = buildRepo().readCallbackTelemetry();

      expect(telemetry.budgetUs, 666);
      expect(telemetry.session.latePeriods, 12);
      expect(telemetry.session.xrunsOf(XrunKind.playbackUnderrun), 4);
      expect(telemetry.session.xrunsOf(XrunKind.captureOverrun), 1);
      expect(telemetry.session.xrunTotal, 5);
      expect(telemetry.armed.meanUs, 210);
      expect(telemetry.armed.hasTrouble, isTrue);
      // Armed vs unarmed: 11 of the 12 missed deadlines, and every dropout,
      // happened inside the armed window.
      expect(telemetry.session.latePeriods - telemetry.armed.latePeriods, 1);
      expect(telemetry.session.xrunTotal - telemetry.armed.xrunTotal, 0);
    });

    test('telemetry never reaches LooperState, so the dedupe still holds', () {
      // The regression this guards: these counters tick on every audio
      // callback, so if they rode EngineStatus no two projections could ever
      // compare equal — `looperState`'s `next == _last` gate would be
      // permanently defeated and an IDLE rig would re-broadcast its whole
      // state (every track, lane and effect) on every poll tick. That is CPU
      // pressure invented by the instrument that exists to find CPU pressure.
      //
      // Mutating the fake's telemetry and asserting `repo.state` is unchanged
      // cannot fail — the projection never reads that field, precisely because
      // the defence is STRUCTURAL. So this is a golden over the field set of
      // `EngineStatus`, the only carrier of engine health inside `LooperState`:
      // it fails loudly the day a field is added, and whoever adds one has to
      // say in the diff whether it moves at callback rate.
      const expectedFields = <String>{
        'deviceName',
        'sampleRate',
        'bufferFrames',
        'inputChannels',
        'outputChannels',
        'latencyState',
        'measuredLatencyMs',
        'xrunCount',
        'isConnected',
        'devicePresent',
        'excludedInputMask',
        'inputClipMask',
        'inputCondMask',
        'recordOffsetFrames',
        'fxAddedLatencyFrames',
        'activeBackend',
      };

      final actual = _declaredFinalFields(
        'lib/src/models/engine_status.dart',
        'EngineStatus extends Equatable',
      );
      expect(
        actual,
        expectedFields,
        reason:
            'EngineStatus gained or lost a field. Anything that moves at '
            'audio-callback rate must stay off it — read it through '
            'LooperRepository.readCallbackTelemetry() instead, which is a '
            'method precisely so it does not read like cheap state. If the '
            'new field moves at human pace (like xrunCount), add it above.',
      );
      expect(
        actual.where(
          (f) =>
              f.contains('latePeriod') ||
              f.contains('gapEvent') ||
              f.contains('telemetry') ||
              f.contains('Telemetry'),
        ),
        isEmpty,
      );

      // And the pull still reports the fresh numbers the state does not carry.
      final repo = buildRepo();
      engine.nextCallbackTelemetry = const CallbackTelemetry(
        budgetUs: 666,
        session: CallbackWindowStats(periods: 1000000, latePeriods: 99),
        armed: CallbackWindowStats(periods: 999, latePeriods: 42),
      );
      expect(repo.readCallbackTelemetry().session.latePeriods, 99);
    });

    test('telemetry defaults to nothing measured', () {
      const telemetry = CallbackTelemetry.empty;
      expect(telemetry.budgetUs, 0);
      expect(telemetry.session, CallbackWindowStats.empty);
      expect(telemetry.armed, CallbackWindowStats.empty);
      expect(telemetry.session.hasTrouble, isFalse);
      expect(buildRepo().readCallbackTelemetry(), CallbackTelemetry.empty);
    });
  });

  group('looperState stream', () {
    test(
      'a peak-only poll reaches subscribers without changing steady facts',
      () async {
        engine.nextSnapshot = _playingAt(24000, peak: 0.1);
        final repo = buildRepo();
        addTearDown(repo.dispose);
        final emitted = <LooperState>[];
        final sub = repo.looperState.listen(emitted.add);
        addTearDown(sub.cancel);
        await Future<void>.delayed(Duration.zero);

        engine.nextSnapshot = _playingAt(24000, peak: 0.9);
        ticker.add(null);
        await Future<void>.delayed(Duration.zero);

        // The unchanged following poll is still suppressed.
        ticker.add(null);
        await Future<void>.delayed(Duration.zero);

        expect(emitted, hasLength(2));
        expect(emitted.map((state) => state.track.peak), [0.1, 0.9]);
        expect(emitted.last.transport, emitted.first.transport);
        expect(emitted.last.track.steadyProps, emitted.first.track.steadyProps);
      },
    );

    test('emits a projected state on each tick, distinctly', () async {
      final repo = buildRepo();
      final emitted = <LooperState>[];
      final sub = repo.looperState.listen(emitted.add);
      addTearDown(sub.cancel);

      // onListen polls once (initial/empty).
      await Future<void>.delayed(Duration.zero);

      engine.nextSnapshot = _playingSnapshot;
      ticker.add(null);
      await Future<void>.delayed(Duration.zero);

      // A tick with no change does not emit again.
      ticker.add(null);
      await Future<void>.delayed(Duration.zero);

      expect(emitted, hasLength(2));
      expect(emitted.first.track.state, TrackState.empty);
      expect(emitted.last.track.state, TrackState.playing);
    });

    test('a late subscriber immediately receives the current state', () async {
      final repo = buildRepo();

      // A first listener drives the engine to a steady playing state.
      engine.nextSnapshot = _playingSnapshot;
      final first = repo.looperState.listen((_) {});
      addTearDown(first.cancel);
      await Future<void>.delayed(Duration.zero);

      // A second listener that subscribes afterwards must get the current
      // state right away, without waiting for the next change.
      LooperState? lateState;
      final second = repo.looperState.listen((s) => lateState = s);
      addTearDown(second.cancel);
      await Future<void>.delayed(Duration.zero);

      expect(lateState, isNotNull);
      expect(lateState!.track.state, TrackState.playing);
    });

    test('a lane fx param change re-emits the projected state', () async {
      // Regression: setLaneEffectParam mutated the stored chain list in place,
      // but _project hands that same list to the emitted state by reference —
      // so the last-emitted state was retroactively mutated and the poll's
      // next == _last diff suppressed the update (UI never refreshed).
      const snapshot = EngineSnapshot(
        isRunning: true,
        sampleRate: 48000,
        bufferFrames: 128,
        framesProcessed: 0,
        xrunCount: 0,
        inputRms: 0,
        inputPeak: 0,
        outputRms: 0,
        latencyState: le.LatencyState.idle,
        measuredLatencyMs: -1,
        masterLengthFrames: 48000,
        tracks: [
          TrackSnapshot(
            state: TrackState.playing,
            volume: 1,
            muted: false,
            lengthFrames: 48000,
            undoDepth: 0,
            rms: 0,
            peak: 0,
            lanes: [
              LaneSnapshot(
                inputChannel: 0,
                outputMask: 0x1,
                volume: 1,
                muted: false,
                lengthFrames: 48000,
                rms: 0,
                peak: 0,
              ),
            ],
          ),
        ],
      );
      // Explicit params (length >= 3) so the index-2 tweak below is valid
      // regardless of any effect's default-param count.
      final repo = buildRepo()
        ..setLaneEffects(
          channel: 0,
          lane: 0,
          effects: [
            BuiltInEffect(
              type: TrackEffectType.delay,
              params: const [0.3, 0.4, 0.5, 0],
            ),
          ],
        );
      engine.nextSnapshot = snapshot;

      final emitted = <LooperState>[];
      final sub = repo.looperState.listen(emitted.add);
      addTearDown(sub.cancel);
      await Future<void>.delayed(Duration.zero); // initial poll
      ticker.add(null); // steady — must not re-emit
      await Future<void>.delayed(Duration.zero);
      final settled = emitted.length;

      // A live param tweak (index 2): no structural edit. It must re-emit
      // immediately — without waiting for the next poll tick — so a dragged
      // knob doesn't lag a frame behind the gesture.
      repo.setLaneEffectParam(
        channel: 0,
        lane: 0,
        index: 0,
        param: 2,
        value: 0.9,
      );
      await Future<void>.delayed(Duration.zero);

      expect(emitted.length, settled + 1, reason: 'param change must re-emit');
      expect(
        (emitted.last.tracks[0].lanes[0].effects.single as BuiltInEffect)
            .params[2],
        closeTo(0.9, 1e-9),
      );
    });

    test('polling restarts cleanly across subscribe/cancel cycles', () async {
      // The default ticker is single-subscription; a subscribe → cancel →
      // subscribe cycle (hot restart, a bloc rebuild) must not throw
      // "Stream has already been listened to".
      final repo = LooperRepository(engine: engine);
      addTearDown(repo.dispose);

      final sub1 = repo.looperState.listen((_) {});
      await Future<void>.delayed(Duration.zero);
      await sub1.cancel();

      final sub2 = repo.looperState.listen((_) {});
      await Future<void>.delayed(Duration.zero);
      await sub2.cancel();
    });
  });

  group('commands forward to the engine', () {
    test('each command calls the matching engine method', () {
      buildRepo()
        ..startEngine(const EngineConfig(sampleRate: 48000))
        ..record()
        ..stopTrack()
        ..play()
        ..undo()
        ..redo()
        ..clear()
        ..measureLatency()
        ..stopEngine()
        ..setVolume(0.5)
        ..setMute(muted: true);

      expect(
        engine.calls,
        containsAllInOrder(<String>[
          'start',
          'record',
          'stopTrack',
          'play',
          // undo asks what the tap would do before making it, so it knows
          // whether to put a cleared take's FX chains back.
          'undoRestoresClear',
          'undo',
          'redo',
          // The user's clear leaves a way back; only session load erases
          // outright (via the engine's plain `clear`).
          'clearUndoable',
          'measureLatency',
          'stop',
        ]),
      );
      expect(engine.lastConfig?.sampleRate, 48000);
      expect(engine.lastVolume, 0.5);
      expect(engine.lastMuted, isTrue);
    });

    test('startEngine stores the last successful config', () {
      const config = EngineConfig(
        sampleRate: 96000,
        bufferFrames: 64,
      );
      final repo = buildRepo();

      expect(repo.lastEngineConfig, isNull);
      expect(repo.startEngine(config), EngineResult.ok);
      expect(repo.lastEngineConfig, config);
    });

    test('startEngine does not store config when start fails', () {
      engine.startResult = EngineResult.device;
      const config = EngineConfig(sampleRate: 96000);
      final repo = buildRepo();

      expect(repo.startEngine(config), EngineResult.device);
      expect(repo.lastEngineConfig, isNull);
    });

    test('setQuantize is deferred until running, then applied', () {
      // Not running yet: the value is remembered but not pushed to the engine.
      final repo = buildRepo()..setQuantize(enabled: true);
      expect(engine.lastQuantize, isNull);

      // A start re-applies the remembered quantize state.
      repo.startEngine(const EngineConfig());
      expect(engine.lastQuantize, isTrue);
    });

    test('setQuantize applies immediately while running', () {
      final repo = buildRepo()..startEngine(const EngineConfig());
      // The start re-applied the default (off).
      expect(engine.lastQuantize, isFalse);

      repo.setQuantize(enabled: true);
      expect(engine.lastQuantize, isTrue);
    });

    test('cancelArm reaches the engine while running, and is a no-op when '
        'stopped (an arm cannot outlive the engine that held it)', () {
      final repo = buildRepo()..cancelArm(channel: 3);
      expect(engine.cancelledArms, isEmpty); // not running yet

      repo
        ..startEngine(const EngineConfig())
        ..cancelArm(channel: 3);
      expect(engine.cancelledArms, [3]);
    });

    test('finalizeTake reaches the engine while running, is a no-op when '
        'stopped (a live take cannot outlive the engine capturing it), and '
        'surfaces the engine refusal untranslated — the caller reads it as '
        '"the capture survives" (#405)', () {
      final repo = buildRepo();
      expect(repo.finalizeTake(channel: 3), EngineResult.ok);
      expect(engine.finalizedTakes, isEmpty); // not running yet

      repo.startEngine(const EngineConfig());
      expect(repo.finalizeTake(channel: 3), EngineResult.ok);
      expect(engine.finalizedTakes, [3]);

      // The defining-take refusal is a contract, not an error to swallow.
      engine.finalizeTakeResult = EngineResult.invalid;
      expect(repo.finalizeTake(channel: 3), EngineResult.invalid);
      expect(engine.finalizedTakes, [3, 3]);
    });

    test('per-track quantize overrides are deferred then re-applied', () {
      final repo = buildRepo()
        ..setTrackQuantize(channel: 1, enabled: true)
        ..setTrackQuantize(channel: 2, enabled: false);
      expect(engine.trackQuantize, isEmpty); // not running yet

      repo.startEngine(const EngineConfig());
      expect(engine.trackQuantize[1], isTrue);
      expect(engine.trackQuantize[2], isFalse);
    });

    test(
      'clearing a per-track override (null) inherits the global default',
      () {
        final repo = buildRepo()
          ..startEngine(const EngineConfig())
          ..setTrackQuantize(channel: 1, enabled: true);
        expect(engine.trackQuantize[1], isTrue);

        repo.setTrackQuantize(channel: 1, enabled: null);
        expect(engine.trackQuantize[1], isNull);

        // A later restart does not re-apply the cleared override.
        engine.trackQuantize.clear();
        repo.startEngine(const EngineConfig());
        expect(engine.trackQuantize.containsKey(1), isFalse);
      },
    );

    test('a per-track override is projected onto the track it names', () async {
      // The engine takes the override and never reports it back, so the
      // repository's own map is the only thing that knows it — and a surface
      // that draws the override has to be told when it changes, including on
      // the session load that writes them with no user gesture at all.
      engine.nextSnapshot = const EngineSnapshot(
        isRunning: true,
        sampleRate: 48000,
        bufferFrames: 128,
        framesProcessed: 0,
        xrunCount: 0,
        inputRms: 0,
        inputPeak: 0,
        outputRms: 0,
        latencyState: le.LatencyState.idle,
        measuredLatencyMs: -1,
        tracks: [
          TrackSnapshot(
            state: TrackState.empty,
            volume: 1,
            muted: false,
            lengthFrames: 0,
            undoDepth: 0,
            rms: 0,
            peak: 0,
          ),
        ],
      );
      final repo = buildRepo()..startEngine(const EngineConfig());
      expect(repo.state.tracks.first.quantizeOverride, isNull);

      final emitted = repo.looperState.firstWhere(
        (state) => state.tracks.first.quantizeOverride != null,
      );
      repo.setTrackQuantize(channel: 0, enabled: false);

      expect((await emitted).tracks.first.quantizeOverride, isFalse);
      expect(repo.state.tracks.first.quantizeOverride, isFalse);

      repo.setTrackQuantize(channel: 0, enabled: true);
      expect(repo.state.tracks.first.quantizeOverride, isTrue);

      repo.setTrackQuantize(channel: 0, enabled: null);
      expect(repo.state.tracks.first.quantizeOverride, isNull);
    });

    test('rec/dub, auto-record and multiples re-apply on start', () {
      final repo = buildRepo()
        ..setRecDub(enabled: true)
        ..setAutoRecord(enabled: true)
        ..setDefaultMultiple(multiple: 2)
        ..setTrackMultiple(channel: 1, multiple: 3);
      expect(engine.lastRecDub, isNull); // not running yet
      expect(engine.trackMultiple, isEmpty);

      repo.startEngine(const EngineConfig());
      expect(engine.lastRecDub, isTrue);
      expect(engine.lastAutoRecord, isTrue);
      expect(engine.lastDefaultMultiple, 2);
      expect(engine.trackMultiple[1], 3);
    });

    test('setMasterGain is deferred until running, then re-applied', () {
      // Not running yet: the value is remembered but not pushed to the engine,
      // and the call still reports success.
      final repo = buildRepo();
      expect(repo.setMasterGain(0.5), EngineResult.ok);
      expect(engine.lastMasterGain, isNull);

      // A start re-applies the remembered gain so it survives device changes.
      repo.startEngine(const EngineConfig());
      expect(engine.lastMasterGain, 0.5);
    });

    test('setMasterGain re-applies on every restart (device change)', () {
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setMasterGain(0.4);
      expect(engine.lastMasterGain, 0.4);

      // A restart (e.g. a reconnect or device switch) resets the engine, so the
      // remembered gain must be pushed again — this is why it is stored.
      engine.lastMasterGain = null;
      repo
        ..stopEngine()
        ..startEngine(const EngineConfig());
      expect(engine.lastMasterGain, 0.4);
    });

    test('setMasterGain applies immediately while running', () {
      final repo = buildRepo()..startEngine(const EngineConfig());
      // The start re-applied the default (unity).
      expect(engine.lastMasterGain, 1.0);

      repo.setMasterGain(0.25);
      expect(engine.lastMasterGain, 0.25);
    });

    test('setMasterGain clamps to 0..1 before reaching the engine', () {
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setMasterGain(2);
      expect(engine.lastMasterGain, 1.0);
      repo.setMasterGain(-1);
      expect(engine.lastMasterGain, 0.0);
    });

    test('limiter getters expose the cached state the engine cannot read', () {
      // The engine's limiter surface is write-only, so these getters are the
      // only truth a caller (a performance-capture arm) can read.
      final repo = buildRepo();
      expect(repo.limiterEnabled, isTrue);
      expect(repo.limiterCeiling, 0.99);
    });

    test('the limiter cache is what start pushes, on every restart', () {
      final repo = buildRepo()..startEngine(const EngineConfig());
      expect(engine.lastLimiterEnabled, isTrue);
      expect(engine.lastLimiterCeiling, 0.99);

      // A restart resets the engine's limiter to off, so the cached state must
      // be pushed again — the getters keep reporting what the engine is
      // actually driven with.
      engine
        ..lastLimiterEnabled = null
        ..lastLimiterCeiling = null;
      repo
        ..stopEngine()
        ..startEngine(const EngineConfig());
      expect(engine.lastLimiterEnabled, repo.limiterEnabled);
      expect(engine.lastLimiterCeiling, repo.limiterCeiling);
    });

    test('setRecordOffset is deferred until running, then re-applied', () {
      final repo = buildRepo();
      expect(repo.setRecordOffset(240), EngineResult.ok);
      expect(engine.lastRecordOffset, isNull); // not pushed while stopped

      repo.startEngine(const EngineConfig());
      expect(engine.lastRecordOffset, 240); // re-applied on start
    });

    test('setRecordOffset re-applies on every restart (device change)', () {
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setRecordOffset(240);
      expect(engine.lastRecordOffset, 240);

      // A restart (reconnect / device switch) resets the engine's offset to 0,
      // so the remembered compensation must be pushed again.
      engine.lastRecordOffset = null;
      repo
        ..stopEngine()
        ..startEngine(const EngineConfig());
      expect(engine.lastRecordOffset, 240);
    });

    test('setTunerInput re-arms on restart while armed, and stays disarmed '
        'once the face has left', () {
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setTunerInput(input: 2);
      expect(engine.tunerInput, 2);

      // A reconnect under an open Tuner face: the engine comes back disarmed,
      // and the face armed once on the way in and will not do so again.
      engine.tunerInput = -1;
      repo
        ..stopEngine()
        ..startEngine(const EngineConfig());
      expect(engine.tunerInput, 2);

      // Once the face disarms, a restart leaves it disarmed — nothing resumes
      // analysing behind a face nobody is looking at.
      repo.setTunerInput(input: -1);
      engine.tunerInput = 0;
      repo
        ..stopEngine()
        ..startEngine(const EngineConfig());
      expect(engine.tunerInput, 0);
    });

    test('an arm issued while stopped lands on the next start', () {
      final repo = buildRepo()..setTunerInput(input: 1);
      expect(engine.tunerInput, -1);

      repo.startEngine(const EngineConfig());
      expect(engine.tunerInput, 1);
    });

    test('setRecordOffset clamps a negative to zero', () {
      buildRepo()
        ..startEngine(const EngineConfig())
        ..setRecordOffset(-5);
      expect(engine.lastRecordOffset, 0);
    });

    test('an engine-measured offset is captured from the poll and re-applied '
        'on restart', () async {
      final repo = buildRepo()..startEngine(const EngineConfig());
      final sub = repo.looperState.listen((_) {});
      addTearDown(sub.cancel);

      // A measurement auto-sets the engine's offset (not via setRecordOffset);
      // the poll must mirror it into the remembered value.
      engine.nextSnapshot = const EngineSnapshot(
        isRunning: true,
        sampleRate: 48000,
        bufferFrames: 128,
        framesProcessed: 0,
        xrunCount: 0,
        inputRms: 0,
        inputPeak: 0,
        outputRms: 0,
        latencyState: le.LatencyState.idle,
        measuredLatencyMs: -1,
        recordOffsetFrames: 240,
      );
      ticker.add(null);
      await Future<void>.delayed(Duration.zero);

      // A restart re-applies the CAPTURED offset, not a stale zero.
      engine.lastRecordOffset = null;
      repo
        ..stopEngine()
        ..startEngine(const EngineConfig());
      expect(engine.lastRecordOffset, 240);
    });

    test('a per-lane effects chain is deferred then re-applied on start', () {
      final repo = buildRepo()
        ..setLaneEffects(
          lane: 0,
          channel: 1,
          effects: [
            BuiltInEffect(
              type: TrackEffectType.delay,
              params: const [0.3, 0.4, 0.5],
            ),
          ],
        );
      expect(engine.laneFx, isEmpty); // not running yet

      repo.startEngine(const EngineConfig());
      // Track-addressed effects map to lane 0.
      expect(engine.laneFx[(1, 0, 0)]?.code, TrackEffectType.delay.code);
      expect(engine.laneFxParam[(1, 0, 0, 1)], 0.4);
      expect(engine.laneFxCount[(1, 0)], 1);
    });

    test('a live param tweak updates the entry without resetting it', () {
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setLaneEffects(
          lane: 0,
          channel: 0,
          effects: [BuiltInEffect(type: TrackEffectType.drive)],
        );
      engine.calls.clear();

      repo.setLaneEffectParam(
        lane: 0,
        channel: 0,
        index: 0,
        param: 0,
        value: 0.9,
      );
      expect(engine.laneFxParam[(0, 0, 0, 0)], 0.9);
      // No setLaneFx (which would reset DSP) — only the granular param call.
      expect(engine.calls, isNot(contains('setLaneFx')));
      expect(engine.calls, contains('setLaneFxParam'));

      // The tweak is remembered and re-applied on restart.
      engine.laneFxParam.clear();
      repo.startEngine(const EngineConfig());
      expect(engine.laneFxParam[(0, 0, 0, 0)], 0.9);
    });

    test(
      'a plugin entry loads through the slot ABI, not the built-in FX push',
      () {
        // A plugin slot loads through the dedicated slot ABI (setLanePlugin)
        // rather than the built-in setLaneFx push: it must not disturb the
        // built-in entries around it, and the active count still spans the
        // whole chain (so trailing built-ins keep their indices).
        buildRepo()
          ..startEngine(const EngineConfig())
          ..setLaneEffects(
            lane: 0,
            channel: 0,
            effects: [
              BuiltInEffect(type: TrackEffectType.drive),
              // index 1 is a plugin between two built-ins.
              const PluginEffect(
                ref: PluginRef(format: PluginFormat.clap, id: 'p'),
              ),
              BuiltInEffect(type: TrackEffectType.reverb),
            ],
          );

        // Built-in entries pushed at their own indices; the plugin loads via
        // the slot ABI at index 1 (never setLaneFx).
        expect(engine.laneFx[(0, 0, 0)]?.code, TrackEffectType.drive.code);
        expect(engine.laneFx.containsKey((0, 0, 1)), isFalse);
        expect(engine.lanePlugins[(0, 0, 1)], 'p');
        expect(engine.laneFx[(0, 0, 2)]?.code, TrackEffectType.reverb.code);
        // The active count still spans all three entries.
        expect(engine.laneFxCount[(0, 0)], 3);
      },
    );

    test('a plugin entry enumerates its params into the projected chain', () {
      engine.nextParamInfos = const [
        le.PluginParamInfo(
          id: 100,
          name: 'Mix',
          unit: '',
          min: 0,
          max: 1,
          def: 0.5,
          stepCount: 0,
          flags: 0x01,
        ),
      ];
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setLaneEffects(
          lane: 0,
          channel: 0,
          effects: const [
            PluginEffect(
              ref: PluginRef(format: PluginFormat.clap, id: 'p'),
            ),
          ],
        );

      final fx = repo.laneEffects(0, 0).single as PluginEffect;
      expect(fx.params, hasLength(1));
      expect(fx.params.single.id, 100);
      expect(fx.params.single.name, 'Mix');
    });

    test('a discrete param is enriched with its per-step labels', () {
      // A 3-state enum (stepCount 2 over [0, 2]) -> step values 0/1/2.
      engine.nextParamInfos = const [
        le.PluginParamInfo(
          id: 100,
          name: 'Filter Type',
          unit: '',
          min: 0,
          max: 2,
          def: 0,
          stepCount: 2,
          flags: 0x01 | 0x10, // automatable + stepped
        ),
      ];
      engine.paramValueTexts.addAll({
        (100, 0.0): 'Lowpass',
        (100, 1.0): 'Highpass',
        (100, 2.0): 'Bandpass',
      });
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setLaneEffects(
          lane: 0,
          channel: 0,
          effects: const [
            PluginEffect(
              ref: PluginRef(format: PluginFormat.clap, id: 'p'),
            ),
          ],
        );

      final fx = repo.laneEffects(0, 0).single as PluginEffect;
      final param = fx.params.single;
      expect(param.valueTexts, ['Lowpass', 'Highpass', 'Bandpass']);
      expect(param.isEnum, isTrue);
    });

    test('a discrete param with incomplete labels stays a bare knob', () {
      engine.nextParamInfos = const [
        le.PluginParamInfo(
          id: 100,
          name: 'Filter Type',
          unit: '',
          min: 0,
          max: 2,
          def: 0,
          stepCount: 2,
          flags: 0x01 | 0x10,
        ),
      ];
      // Only two of the three steps resolve to text -> no dropdown.
      engine.paramValueTexts.addAll({
        (100, 0.0): 'Lowpass',
        (100, 2.0): 'Bandpass',
      });
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setLaneEffects(
          lane: 0,
          channel: 0,
          effects: const [
            PluginEffect(
              ref: PluginRef(format: PluginFormat.clap, id: 'p'),
            ),
          ],
        );

      final fx = repo.laneEffects(0, 0).single as PluginEffect;
      final param = fx.params.single;
      expect(param.valueTexts, isEmpty);
      expect(param.isEnum, isFalse);
    });

    test('lanePluginParamText forwards to the loaded slot', () {
      engine.nextParamInfos = const [
        le.PluginParamInfo(
          id: 100,
          name: 'Gain',
          unit: 'dB',
          min: 0,
          max: 1,
          def: 0.5,
          stepCount: 0,
          flags: 0x01,
        ),
      ];
      engine.paramValueTexts[(100, 0.5)] = '-6.0 dB';
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setLaneEffects(
          lane: 0,
          channel: 0,
          effects: const [
            PluginEffect(
              ref: PluginRef(format: PluginFormat.clap, id: 'p'),
            ),
          ],
        );

      expect(
        repo.lanePluginParamText(
          channel: 0,
          lane: 0,
          index: 0,
          paramId: 100,
          value: 0.5,
        ),
        '-6.0 dB',
      );
      // No plugin at that index -> null, not a throw.
      expect(
        repo.lanePluginParamText(
          channel: 0,
          lane: 0,
          index: 5,
          paramId: 100,
          value: 0.5,
        ),
        isNull,
      );
    });

    test('monitorPluginParamText forwards to the loaded monitor slot', () {
      engine.nextParamInfos = const [
        le.PluginParamInfo(
          id: 100,
          name: 'Gain',
          unit: 'dB',
          min: 0,
          max: 1,
          def: 0.5,
          stepCount: 0,
          flags: 0x01,
        ),
      ];
      engine.paramValueTexts[(100, 0.5)] = '-6.0 dB';
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setMonitorEffects(
          input: 0,
          effects: const [
            PluginEffect(
              ref: PluginRef(format: PluginFormat.clap, id: 'p'),
            ),
          ],
        );

      expect(
        repo.monitorPluginParamText(
          input: 0,
          index: 0,
          paramId: 100,
          value: 0.5,
        ),
        '-6.0 dB',
      );
      expect(
        repo.monitorPluginParamText(
          input: 9,
          index: 0,
          paramId: 100,
          value: 0.5,
        ),
        isNull,
      );
    });

    test('persisted plugin paramValues replay through the RT queue', () {
      buildRepo()
        ..startEngine(const EngineConfig())
        ..setLaneEffects(
          lane: 0,
          channel: 0,
          effects: const [
            PluginEffect(
              ref: PluginRef(format: PluginFormat.clap, id: 'p'),
              paramValues: {100: 0.25},
            ),
          ],
        );
      expect(engine.pluginParamSets, hasLength(1));
      expect(engine.pluginParamSets.single.paramId, 100);
      expect(engine.pluginParamSets.single.value, 0.25);
    });

    test('setLanePluginParam routes to the loaded slot and remembers it', () {
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setLaneEffects(
          lane: 0,
          channel: 0,
          effects: const [
            PluginEffect(
              ref: PluginRef(format: PluginFormat.clap, id: 'p'),
            ),
          ],
        );

      expect(
        repo.setLanePluginParam(
          channel: 0,
          lane: 0,
          index: 0,
          paramId: 200,
          value: 0.8,
        ),
        EngineResult.ok,
      );
      // The set reached the plugin via the RT queue...
      expect(engine.pluginParamSets.last.paramId, 200);
      expect(engine.pluginParamSets.last.value, 0.8);
      // ...and is remembered on the entry so it survives a reload / persists.
      final fx = repo.laneEffects(0, 0).single as PluginEffect;
      expect(fx.paramValues[200], 0.8);
    });

    test('setLanePluginParam on a non-plugin entry is invalid', () {
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setLaneEffects(
          lane: 0,
          channel: 0,
          effects: [BuiltInEffect(type: TrackEffectType.drive)],
        );
      expect(
        repo.setLanePluginParam(
          channel: 0,
          lane: 0,
          index: 0,
          paramId: 100,
          value: 0.5,
        ),
        EngineResult.invalid,
      );
    });

    test('setMonitorPluginParam on a non-plugin entry is invalid', () {
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setMonitorEffects(
          input: 1,
          effects: [BuiltInEffect(type: TrackEffectType.drive)],
        );
      expect(
        repo.setMonitorPluginParam(
          input: 1,
          index: 0,
          paramId: 100,
          value: 0.5,
        ),
        EngineResult.invalid,
      );
    });

    test('setMonitorPluginParam routes to the loaded monitor slot', () {
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setMonitorEffects(
          input: 2,
          effects: const [
            PluginEffect(
              ref: PluginRef(format: PluginFormat.vst3, id: 'm'),
            ),
          ],
        );
      expect(engine.monitorPlugins[(2, 0)], 'm');

      expect(
        repo.setMonitorPluginParam(
          input: 2,
          index: 0,
          paramId: 300,
          value: 0.4,
        ),
        EngineResult.ok,
      );
      expect(engine.pluginParamSets.last.paramId, 300);
      expect(engine.pluginParamSets.last.value, 0.4);
      expect(
        (repo.monitorEffects(2).single as PluginEffect).paramValues[300],
        0.4,
      );
    });

    test('a plugin param set with no loaded slot is invalid', () {
      // Engine not started => no slot loaded for the remembered chain.
      final repo = buildRepo()
        ..setLaneEffects(
          lane: 0,
          channel: 0,
          effects: const [
            PluginEffect(
              ref: PluginRef(format: PluginFormat.clap, id: 'p'),
            ),
          ],
        )
        ..startEngine(const EngineConfig());
      // Simulate a failed load: the next plugin load returns no handle.
      engine.nextSlotHandle = null;
      repo.setLaneEffects(
        lane: 0,
        channel: 0,
        effects: const [
          PluginEffect(
            ref: PluginRef(format: PluginFormat.clap, id: 'p'),
          ),
        ],
      );
      expect(
        repo.setLanePluginParam(
          channel: 0,
          lane: 0,
          index: 0,
          paramId: 100,
          value: 0.5,
        ),
        EngineResult.invalid,
      );
    });

    test('openLanePluginEditor opens the loaded slot editor', () {
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setLaneEffects(
          lane: 0,
          channel: 0,
          effects: const [
            PluginEffect(
              ref: PluginRef(format: PluginFormat.clap, id: 'p'),
            ),
          ],
        );
      expect(
        repo.openLanePluginEditor(channel: 0, lane: 0, index: 0),
        EngineResult.ok,
      );
      expect(engine.openEditors, hasLength(1));
      expect(
        repo.isLanePluginEditorOpen(channel: 0, lane: 0, index: 0),
        isTrue,
      );
    });

    test('openLanePluginEditor without a loaded plugin is invalid', () {
      final repo = buildRepo()..startEngine(const EngineConfig());
      expect(
        repo.openLanePluginEditor(channel: 0, lane: 0, index: 0),
        EngineResult.invalid,
      );
    });

    test('refreshLanePluginParams mirrors editor-driven values (D-SYNC)', () {
      engine.nextParamInfos = const [
        le.PluginParamInfo(
          id: 100,
          name: 'Mix',
          unit: '',
          min: 0,
          max: 1,
          def: 0.5,
          stepCount: 0,
          flags: 0x01,
        ),
      ];
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setLaneEffects(
          lane: 0,
          channel: 0,
          effects: const [
            PluginEffect(
              ref: PluginRef(format: PluginFormat.clap, id: 'p'),
            ),
          ],
        );
      // The editor moves param 100 to 0.7; the next read-back mirrors it.
      engine.nextParamValues[100] = 0.7;
      expect(
        repo.refreshLanePluginParams(channel: 0, lane: 0, index: 0),
        isTrue,
      );
      expect(
        (repo.laneEffects(0, 0).single as PluginEffect).paramValues[100],
        0.7,
      );
      // A second read-back with no change reports nothing moved.
      expect(
        repo.refreshLanePluginParams(channel: 0, lane: 0, index: 0),
        isFalse,
      );
    });

    test('a parameter that is shown but not automatable is read back too', () {
      engine.nextParamInfos = const [
        le.PluginParamInfo(
          id: 100,
          name: 'Gain Reduction',
          unit: 'dB',
          min: -60,
          max: 0,
          def: 0,
          stepCount: 0,
          // Visible and READ-ONLY, and not automatable — a meter. The console
          // draws these, so a read-back that skips them leaves the drawn
          // value frozen at the plugin's default for good: a live-looking
          // number guaranteed to be wrong, including right after the user
          // moved it in the plugin's own window.
          flags: 0x02,
        ),
        le.PluginParamInfo(
          id: 101,
          name: 'Secret',
          unit: '',
          min: 0,
          max: 1,
          def: 0,
          stepCount: 0,
          // Hidden: not drawn anywhere, so not read either.
          flags: 0x08,
        ),
      ];
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setLaneEffects(
          lane: 0,
          channel: 0,
          effects: const [
            PluginEffect(
              ref: PluginRef(format: PluginFormat.clap, id: 'p'),
            ),
          ],
        );

      engine.nextParamValues[100] = -12;
      engine.nextParamValues[101] = 0.9;
      expect(
        repo.refreshLanePluginParams(channel: 0, lane: 0, index: 0),
        isTrue,
      );
      final values =
          (repo.laneEffects(0, 0).single as PluginEffect).paramValues;
      expect(values[100], -12);
      expect(values.containsKey(101), isFalse);
    });

    test('what the plugin will not let the host set is never set', () {
      engine.nextParamInfos = const [
        le.PluginParamInfo(
          id: 100,
          name: 'Gain Reduction',
          unit: 'dB',
          min: -60,
          max: 0,
          def: 0,
          stepCount: 0,
          // Read-only, and not automatable: the console draws it, so the
          // read-back puts it in `paramValues` — but the host does not own
          // it. Replaying it writes a stale meter reading into the plugin's
          // own storage, and overrides with a captured value whatever the
          // restored state blob had just put there.
          flags: 0x02,
        ),
        le.PluginParamInfo(
          id: 101,
          name: 'Mix',
          unit: '',
          min: 0,
          max: 1,
          def: 0.5,
          stepCount: 0,
          flags: 0x01,
        ),
        le.PluginParamInfo(
          id: 102,
          name: 'Output Level',
          unit: 'dB',
          min: -60,
          max: 0,
          def: 0,
          stepCount: 0,
          // Automatable AND read-only — a meter the host may watch but not
          // move. Either flag alone is enough to refuse the write.
          flags: 0x01 | 0x02,
        ),
      ];
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setLaneEffects(
          lane: 0,
          channel: 0,
          effects: const [
            PluginEffect(
              ref: PluginRef(format: PluginFormat.clap, id: 'p'),
            ),
          ],
        );
      engine.nextParamValues[100] = -12;
      engine.nextParamValues[101] = 0.7;
      engine.nextParamValues[102] = -3;
      expect(
        repo.refreshLanePluginParams(channel: 0, lane: 0, index: 0),
        isTrue,
      );

      // Re-apply the chain: every structural edit, engine restart and session
      // reload comes back through here.
      engine.pluginParamSets.clear();
      repo.setLaneEffects(
        lane: 0,
        channel: 0,
        effects: repo.laneEffects(0, 0),
      );

      // The exact set, not `everyElement` — which is true of an empty list,
      // and an empty list is the failure where the replay is dropped
      // altogether.
      expect(engine.pluginParamSets.map((s) => s.paramId).toSet(), {101});
    });

    test('what the console will draw is read back at load', () {
      engine.nextParamInfos = const [
        le.PluginParamInfo(
          id: 10,
          name: 'Mode',
          unit: '',
          min: 0,
          max: 2,
          def: 0,
          stepCount: 2,
          // Visible and NOT automatable — a setting the console draws
          // read-only. Nothing replays it, and the refresh polls only run
          // while the plugin's own window is open, which on the appliance is
          // never. Unread at load, the console would draw whatever was last
          // persisted rather than what the plugin is at once its state blob
          // has been restored on top.
          flags: 0x10,
        ),
      ];
      engine.nextParamValues[10] = 2;
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setLaneEffects(
          lane: 0,
          channel: 0,
          effects: const [
            PluginEffect(
              ref: PluginRef(format: PluginFormat.clap, id: 'p'),
              paramValues: {10: 0},
            ),
          ],
        );

      expect(
        (repo.laneEffects(0, 0).single as PluginEffect).paramValues[10],
        2,
      );
    });

    test('a saved value is not clobbered by the read it was written past', () {
      engine.nextParamInfos = const [
        le.PluginParamInfo(
          id: 100,
          name: 'Gain',
          unit: 'dB',
          min: -60,
          max: 0,
          def: 0,
          stepCount: 0,
          flags: 0x01,
        ),
      ];
      // The plugin is still at its default: a param set is RT-queued and
      // drained at the next process block, while a get is immediate. Reading
      // one back at bind time therefore answers with the PRE-replay value.
      engine.nextParamValues[100] = 0;
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setLaneEffects(
          lane: 0,
          channel: 0,
          effects: const [
            PluginEffect(
              ref: PluginRef(format: PluginFormat.clap, id: 'p'),
              paramValues: {100: -12},
            ),
          ],
        );

      // Capturing that would overwrite the user's setting with the plugin's
      // default — on every structural edit, engine restart and relink, and
      // permanently on VST3, whose controller is never told what the host
      // set. What was just written is not read back.
      expect(
        (repo.laneEffects(0, 0).single as PluginEffect).paramValues[100],
        -12,
      );
    });

    test('a meter reading -inf never reaches the chain', () {
      engine.nextParamInfos = const [
        le.PluginParamInfo(
          id: 10,
          name: 'Mode',
          unit: '',
          min: 0,
          max: 2,
          def: 0,
          stepCount: 2,
          flags: 0x10,
        ),
      ];
      // What a dB meter reads at silence. The hosts pass it through
      // unclamped, and `jsonEncode` throws on it — from inside the bloc's own
      // push, so the failure is not the value: it is every later edit of this
      // chain going unsaved.
      engine.nextParamValues[10] = double.negativeInfinity;
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setLaneEffects(
          lane: 0,
          channel: 0,
          effects: const [
            PluginEffect(
              ref: PluginRef(format: PluginFormat.clap, id: 'p'),
              paramValues: {10: 1},
            ),
          ],
        );

      final chain = repo.laneEffects(0, 0);
      expect((chain.single as PluginEffect).paramValues[10], 1);
      // The repository's own encoder, which is what the bloc and the monitor
      // cubit call on every push.
      expect(() => encodeTrackEffects(chain), returnsNormally);
    });

    test(
      "relinking to a DIFFERENT plugin does not carry the old one's values",
      () {
        engine.nextParamInfos = const [
          le.PluginParamInfo(
            id: 100,
            name: 'Gain Reduction',
            unit: 'dB',
            min: -60,
            max: 0,
            def: 0,
            stepCount: 0,
            flags: 0x01 | 0x02,
          ),
        ];
        engine.nextParamValues[100] = -40;
        final repo = buildRepo()
          ..startEngine(const EngineConfig())
          ..setLaneEffects(
            lane: 0,
            channel: 0,
            effects: const [
              PluginEffect(
                ref: PluginRef(format: PluginFormat.clap, id: 'A'),
                state: 'AAAA',
              ),
            ],
          );

        // Param 100 on the NEW plugin is an ordinary 0..1 mix.
        engine
          ..nextParamInfos = const [
            le.PluginParamInfo(
              id: 100,
              name: 'Mix',
              unit: '',
              min: 0,
              max: 1,
              def: 0.5,
              stepCount: 0,
              flags: 0x01,
            ),
          ]
          ..nextParamValues.clear()
          ..pluginParamSets.clear();
        repo.relinkLanePlugin(
          channel: 0,
          lane: 0,
          index: 0,
          ref: const PluginRef(format: PluginFormat.clap, id: 'B'),
        );

        // Parameter ids mean whatever the new plugin says they mean. Carrying
        // the old one's capture across sets an unrelated parameter to a number
        // from another plugin's range — here a 0..1 mix to −40 — and hands it a
        // state blob that is not even its format. Reachable from the console,
        // whose relink browses every installed plugin.
        final fx = repo.laneEffects(0, 0).single as PluginEffect;
        expect(fx.paramValues, isEmpty);
        expect(engine.pluginParamSets, isEmpty);
        // The blob still travels: a plugin that does not recognise one
        // rejects it, and the alternative is losing the settings of an entry
        // whose plugin merely moved.
        expect(fx.state, 'AAAA');
      },
    );

    test('relinking to the SAME plugin keeps its state and tweaks', () {
      engine.nextParamInfos = const [
        le.PluginParamInfo(
          id: 100,
          name: 'Mix',
          unit: '',
          min: 0,
          max: 1,
          def: 0.5,
          stepCount: 0,
          flags: 0x01,
        ),
      ];
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setLaneEffects(
          lane: 0,
          channel: 0,
          effects: const [
            PluginEffect(
              ref: PluginRef(format: PluginFormat.clap, id: 'A'),
              state: 'AAAA',
              paramValues: {100: 0.25},
            ),
          ],
        )
        ..relinkLanePlugin(
          channel: 0,
          lane: 0,
          index: 0,
          // Same plugin, new version — the file moved, or the installed one
          // drifted. This is what the capture exists for.
          ref: const PluginRef(format: PluginFormat.clap, id: 'A', version: 2),
        );

      final fx = repo.laneEffects(0, 0).single as PluginEffect;
      expect(fx.paramValues[100], 0.25);
      expect(fx.state, 'AAAA');
    });

    test('a refresh drops a -inf reading too', () {
      engine.nextParamInfos = const [
        le.PluginParamInfo(
          id: 100,
          name: 'Gain Reduction',
          unit: 'dB',
          min: -60,
          max: 0,
          def: 0,
          stepCount: 0,
          flags: 0x01 | 0x02,
        ),
      ];
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setLaneEffects(
          lane: 0,
          channel: 0,
          effects: const [
            PluginEffect(
              ref: PluginRef(format: PluginFormat.clap, id: 'p'),
            ),
          ],
        );

      // The editor-sync poll reaches this on every tick while a plugin window
      // is open, and once more on close. A `-inf` taken here cannot be
      // encoded, and the throw comes out of the cubit's own push — so the
      // damage is every later edit of the chain going unsaved.
      engine.nextParamValues[100] = double.negativeInfinity;
      repo.refreshLanePluginParams(channel: 0, lane: 0, index: 0);

      // Left at what the bind-time read saw, rather than taking the -inf.
      final chain = repo.laneEffects(0, 0);
      expect((chain.single as PluginEffect).paramValues[100], 0);
      expect(() => encodeTrackEffects(chain), returnsNormally);
    });

    test('a plugin that enumerates nothing still gets its saved values', () {
      // A VST3 whose edit controller failed to instantiate, a CLAP with no
      // params extension: the plugin loads and reports no parameters. A
      // keep-list built from those flags is empty, and would discard every
      // saved value on each engine start.
      engine.nextParamInfos = const [];
      buildRepo()
        ..startEngine(const EngineConfig())
        ..setLaneEffects(
          lane: 0,
          channel: 0,
          effects: const [
            PluginEffect(
              ref: PluginRef(format: PluginFormat.clap, id: 'p'),
              paramValues: {42: 0.75},
            ),
          ],
        );

      expect(
        engine.pluginParamSets.map((s) => (s.paramId, s.value)),
        contains((42, 0.75)),
      );
    });

    test('closeLanePluginEditor closes the slot and reads params back', () {
      engine.nextParamInfos = const [
        le.PluginParamInfo(
          id: 100,
          name: 'Mix',
          unit: '',
          min: 0,
          max: 1,
          def: 0.5,
          stepCount: 0,
          flags: 0x01,
        ),
      ];
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setLaneEffects(
          lane: 0,
          channel: 0,
          effects: const [
            PluginEffect(
              ref: PluginRef(format: PluginFormat.clap, id: 'p'),
            ),
          ],
        )
        ..openLanePluginEditor(channel: 0, lane: 0, index: 0);
      engine.nextParamValues[100] = 0.9; // the editor's final state

      expect(
        repo.closeLanePluginEditor(channel: 0, lane: 0, index: 0),
        EngineResult.ok,
      );
      expect(engine.openEditors, isEmpty);
      // The close re-read landed the editor's final value in the model.
      expect(
        (repo.laneEffects(0, 0).single as PluginEffect).paramValues[100],
        0.9,
      );
    });

    test('a monitor plugin editor opens, reads back, and closes', () {
      engine.nextParamInfos = const [
        le.PluginParamInfo(
          id: 200,
          name: 'Tone',
          unit: '',
          min: 0,
          max: 1,
          def: 0.5,
          stepCount: 0,
          flags: 0x01,
        ),
      ];
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setMonitorEffects(
          input: 1,
          effects: const [
            PluginEffect(
              ref: PluginRef(format: PluginFormat.vst3, id: 'm'),
            ),
          ],
        );
      expect(
        repo.openMonitorPluginEditor(input: 1, index: 0),
        EngineResult.ok,
      );
      expect(repo.isMonitorPluginEditorOpen(input: 1, index: 0), isTrue);

      engine.nextParamValues[200] = 0.4;
      expect(repo.refreshMonitorPluginParams(input: 1, index: 0), isTrue);
      expect(
        (repo.monitorEffects(1).single as PluginEffect).paramValues[200],
        0.4,
      );

      expect(
        repo.closeMonitorPluginEditor(input: 1, index: 0),
        EngineResult.ok,
      );
      expect(repo.isMonitorPluginEditorOpen(input: 1, index: 0), isFalse);
    });

    test(
      'a plugin that fails to load is flagged unavailable (D-MISS)',
      () async {
        engine.nextSlotHandle = null; // load fails (uninstalled / moved)
        final repo = buildRepo()
          ..startEngine(const EngineConfig())
          ..setLaneEffects(
            lane: 0,
            channel: 0,
            effects: const [
              PluginEffect(
                ref: PluginRef(format: PluginFormat.clap, id: 'gone'),
              ),
            ],
          );
        // Cold-start recovery kicks a scan; let it complete (it finds nothing)]
        // so the entry settles from the transient loading state to the genuine
        // unavailable placeholder.
        await repo.pluginCatalog.scan();
        final fx = repo.laneEffects(0, 0).single as PluginEffect;
        // Preserved as a placeholder, never dropped to `none`.
        expect(fx.unavailable, isTrue);
        expect(fx.ref.id, 'gone');
        // Not in the scan catalog -> missing, not an unsupported topology.
        expect(fx.unsupported, isFalse);
      },
    );

    test(
      'a failed plugin keeps its persisted name in the placeholder',
      () async {
        engine.nextSlotHandle = null; // not loadable (catalog has no match)
        final repo = buildRepo()
          ..startEngine(const EngineConfig())
          ..setLaneEffects(
            lane: 0,
            channel: 0,
            effects: const [
              PluginEffect(
                ref: PluginRef(format: PluginFormat.clap, id: 'gone'),
                name: 'Saved Reverb',
              ),
            ],
          );
        await repo.pluginCatalog.scan(); // settle recovery -> unavailable
        final fx = repo.laneEffects(0, 0).single as PluginEffect;
        // The persisted name survives the bind + recovery, so the placeholder
        // reads as the plugin's name rather than a cryptic id.
        expect(fx.unavailable, isTrue);
        expect(fx.name, 'Saved Reverb');
      },
    );

    test(
      'a restored plugin recovers itself once the cold-start scan lands',
      () async {
        // A cold restart: the chain is restored (through setTrackEffects) after
        // the engine started, so its first apply hits the still-empty scan
        // cache and the plugin fails to load. The recovery flips it to
        // "loading…" (F5) and kicks a catalog scan; when that lands the entry
        // re-applies itself, resolving availability + the descriptor name —
        // without the user relinking by hand.
        engine
          ..pluginScanResults = const [
            le.PluginDescriptor(
              id: 'p',
              name: 'Catalog Reverb',
              vendor: 'Acme',
              path: '/Library/Audio/Plug-Ins/CLAP/reverb.clap',
              format: le.PluginFormat.clap,
              version: 0,
            ),
          ]
          // Cold start: the scan cache is empty, so the first load fails.
          ..nextSlotHandle = null;
        final repo = buildRepo()
          ..startEngine(const EngineConfig())
          ..setLaneEffects(
            lane: 0,
            channel: 0,
            effects: const [
              PluginEffect(
                ref: PluginRef(format: PluginFormat.clap, id: 'p'),
              ),
            ],
          );
        // First apply against the empty cache fails; recovery flips it to
        // loading (not a premature "unavailable") and its scan is now in
        // flight.
        final mid = repo.laneEffects(0, 0).single as PluginEffect;
        expect(mid.loading, isTrue);
        expect(mid.unavailable, isFalse);

        // The plugin is loadable once scanned; joining the in-flight recovery
        // scan drives the re-apply.
        engine.nextSlotHandle = MockPluginSlotHandle('p');
        await repo.pluginCatalog.scan();

        final fx = repo.laneEffects(0, 0).single as PluginEffect;
        expect(fx.loading, isFalse);
        expect(fx.unavailable, isFalse);
        expect(fx.name, 'Catalog Reverb');
      },
    );

    test('a failed load whose id is in the catalog is flagged '
        'unsupported', () async {
      // The plugin IS installed (the scan found it) but the engine refused to
      // load it — an instrument / multi-bus topology (D-BUS), not a missing
      // file. The card must say "unsupported", not "missing".
      engine.pluginScanResults = const [
        le.PluginDescriptor(
          id: 'synth',
          name: 'Big Synth',
          vendor: 'Acme',
          path: '/Library/Audio/Plug-Ins/CLAP/synth.clap',
          format: le.PluginFormat.clap,
          version: 0,
        ),
      ];
      final repo = buildRepo()..startEngine(const EngineConfig());
      await repo.pluginCatalog.scan();

      engine.nextSlotHandle = null; // engine rejects the load (topology)
      repo.setLaneEffects(
        lane: 0,
        channel: 0,
        effects: const [
          PluginEffect(
            ref: PluginRef(format: PluginFormat.clap, id: 'synth'),
          ),
        ],
      );

      final fx = repo.laneEffects(0, 0).single as PluginEffect;
      expect(fx.unavailable, isTrue);
      expect(fx.unsupported, isTrue);
    });

    test(
      'a bus-stage plugin is named from the catalog, not left a TUID',
      () async {
        engine.pluginScanResults = const [
          le.PluginDescriptor(
            id: 'aab1cc2200000000',
            name: 'Valhalla Vintage Verb',
            vendor: 'Valhalla DSP',
            path: '/Library/Audio/Plug-Ins/VST3/verb.vst3',
            format: le.PluginFormat.vst3,
            version: 0,
          ),
          le.PluginDescriptor(
            id: 'ddee4455ffff0000',
            name: 'TAL Reverb 4',
            vendor: 'TAL',
            path: '/Library/Audio/Plug-Ins/VST3/tal.vst3',
            format: le.PluginFormat.vst3,
            version: 0,
          ),
        ];
        final repo = buildRepo()..startEngine(const EngineConfig());
        addTearDown(repo.dispose);
        await repo.pluginCatalog.scan();

        // What the browse sheet builds: an identity, no name. On a lane the
        // load resolves it; a bus entry never loads, so nothing else would.
        repo.setMasterEffects(
          effects: const [
            PluginEffect(
              ref: PluginRef(format: PluginFormat.vst3, id: 'aab1cc2200000000'),
            ),
          ],
        );
        expect(
          (repo.masterEffects.single as PluginEffect).name,
          'Valhalla Vintage Verb',
        );

        // And a relink onto a DIFFERENT plugin re-reads it: the surface keeps
        // the entry's own name across the edit, which would leave the card
        // naming the plugin that was replaced.
        repo.setMasterEffects(
          effects: const [
            PluginEffect(
              ref: PluginRef(format: PluginFormat.vst3, id: 'ddee4455ffff0000'),
              name: 'Valhalla Vintage Verb',
            ),
          ],
        );
        expect(
          (repo.masterEffects.single as PluginEffect).name,
          'TAL Reverb 4',
        );
      },
    );

    test(
      'a bus chain restored before any scan is named when the scan lands',
      () async {
        engine.pluginScanResults = const [
          le.PluginDescriptor(
            id: 'aab1cc2200000000',
            name: 'Valhalla Vintage Verb',
            vendor: 'Valhalla DSP',
            path: '/Library/Audio/Plug-Ins/VST3/verb.vst3',
            format: le.PluginFormat.vst3,
            version: 0,
          ),
        ];
        final repo = buildRepo()..startEngine(const EngineConfig());
        addTearDown(repo.dispose);

        // Boot order: the saved chains are restored BEFORE anything scans, and
        // every chain saved by a build that did not name bus entries has no
        // name to fall back on. Nothing loads a bus plugin, so without the
        // recovery this entry reads as a 32-character TUID for the whole
        // session — and the next write persists the empty name again.
        repo.setTrackEffects(
          channel: 1,
          effects: const [
            PluginEffect(
              ref: PluginRef(format: PluginFormat.vst3, id: 'aab1cc2200000000'),
            ),
          ],
        );
        expect((repo.trackEffects(1).single as PluginEffect).name, isEmpty);

        // The master is restored after it, out of its own field — and after
        // the track's kick has already registered its continuation, so this
        // chain is named only if the master write kicks the recovery too.
        repo.setMasterEffects(
          effects: const [
            PluginEffect(
              ref: PluginRef(format: PluginFormat.vst3, id: 'aab1cc2200000000'),
            ),
          ],
        );
        expect((repo.masterEffects.single as PluginEffect).name, isEmpty);

        // On the STREAM, not just the getters: the cards read the projected
        // state, so a recovery that names the cache without emitting leaves
        // every one of them showing the id it was meant to replace.
        final named = expectLater(
          repo.looperState,
          emitsThrough(
            predicate<LooperState>(
              (s) =>
                  (s.masterEffects.singleOrNull as PluginEffect?)?.name ==
                  'Valhalla Vintage Verb',
              'the master chain named',
            ),
          ),
        );
        await repo.pluginCatalog.scan();
        await Future<void>.delayed(Duration.zero);
        await named;

        expect(
          (repo.masterEffects.single as PluginEffect).name,
          'Valhalla Vintage Verb',
        );
        expect(
          (repo.trackEffects(1).single as PluginEffect).name,
          'Valhalla Vintage Verb',
        );
      },
    );

    test('a repository disposed mid-scan does not project into a closed '
        'stream', () async {
      engine.pluginScanResults = const [
        le.PluginDescriptor(
          id: 'aab1cc2200000000',
          name: 'Valhalla Vintage Verb',
          vendor: 'Valhalla DSP',
          path: '/Library/Audio/Plug-Ins/VST3/verb.vst3',
          format: le.PluginFormat.vst3,
          version: 0,
        ),
      ];
      // The scan outlives the repository: the recovery's continuation runs
      // after the dispose below, and projecting into a closed controller
      // throws an uncaught async error — in whichever test happens to be
      // running when it lands, since the isolate is shared.
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setMasterEffects(
          effects: const [
            PluginEffect(
              ref: PluginRef(
                format: PluginFormat.vst3,
                id: 'aab1cc2200000000',
              ),
            ),
          ],
        );
      await repo.dispose();
      await repo.pluginCatalog.scan();
      await Future<void>.delayed(Duration.zero);
    });

    test('a bus write does not disturb an unavailable LANE plugin', () async {
      final repo = buildRepo()..startEngine(const EngineConfig());
      addTearDown(repo.dispose);
      engine.nextSlotHandle = null; // nothing loads: the lane entry is D-MISS
      repo.setLaneEffects(
        channel: 0,
        lane: 0,
        effects: const [
          PluginEffect(
            ref: PluginRef(format: PluginFormat.vst3, id: 'gone'),
          ),
        ],
      );
      await repo.pluginCatalog.scan(); // settle the lane's own recovery
      final pushes = engine.calls.where((c) => c == 'setLanePlugin').length;
      expect((repo.laneEffects(0, 0).single as PluginEffect).loading, isFalse);

      // A knob on a bus chain, fired at drag rate. The lane recovery must not
      // ride along: it flips every unavailable lane entry to "loading…" and
      // re-applies the chain, so the card would strobe between a spinner and
      // its relink offer for the length of the drag.
      for (var i = 0; i < 3; i++) {
        repo.setMasterEffects(
          effects: [
            BuiltInEffect(type: TrackEffectType.drive, params: [i / 3]),
          ],
        );
      }

      final fx = repo.laneEffects(0, 0).single as PluginEffect;
      expect(fx.loading, isFalse);
      expect(fx.unavailable, isTrue);
      expect(engine.calls.where((c) => c == 'setLanePlugin').length, pushes);
    });

    test('a TRACK bus chain alone is named when the scan lands', () async {
      engine.pluginScanResults = const [
        le.PluginDescriptor(
          id: 'aab1cc2200000000',
          name: 'Valhalla Vintage Verb',
          vendor: 'Valhalla DSP',
          path: '/Library/Audio/Plug-Ins/VST3/verb.vst3',
          format: le.PluginFormat.vst3,
          version: 0,
        ),
      ];
      final repo = buildRepo()..startEngine(const EngineConfig());
      addTearDown(repo.dispose);

      // No master chain: a rig whose only plugin is on a track bus has to be
      // named by that setter's own kick, and nothing else will do it for it.
      repo.setTrackEffects(
        channel: 1,
        effects: const [
          PluginEffect(
            ref: PluginRef(format: PluginFormat.vst3, id: 'aab1cc2200000000'),
          ),
        ],
      );
      expect((repo.trackEffects(1).single as PluginEffect).name, isEmpty);

      await repo.pluginCatalog.scan();
      await Future<void>.delayed(Duration.zero);

      expect(
        (repo.trackEffects(1).single as PluginEffect).name,
        'Valhalla Vintage Verb',
      );
    });

    test('a bus plugin whose id decoded to nothing is not named after a '
        'failed scan entry', () async {
      engine.pluginScanResults = const [
        // What a bundle that could not be scanned looks like: no id, and the
        // offending FILE's name where a plugin's would be.
        le.PluginDescriptor(
          id: '',
          name: 'broken.vst3',
          vendor: '',
          path: '/Library/Audio/Plug-Ins/VST3/broken.vst3',
          format: le.PluginFormat.vst3,
          version: 0,
        ),
      ];
      final repo = buildRepo()..startEngine(const EngineConfig());
      addTearDown(repo.dispose);
      await repo.pluginCatalog.scan();

      repo.setMasterEffects(
        effects: const [
          PluginEffect(
            ref: PluginRef(format: PluginFormat.vst3, id: ''),
          ),
        ],
      );

      expect((repo.masterEffects.single as PluginEffect).name, isEmpty);
    });

    test(
      'a bus-stage plugin the catalog has never seen keeps its own name',
      () {
        final repo = buildRepo()..startEngine(const EngineConfig());
        addTearDown(repo.dispose);

        // Uninstalled, or scanned on another machine: the saved name is all
        // there is, and it is what tells the player which plugin to relink to.
        repo.setTrackEffects(
          channel: 0,
          effects: const [
            PluginEffect(
              ref: PluginRef(format: PluginFormat.vst3, id: 'gone'),
              name: 'Ancient Chorus',
            ),
          ],
        );

        expect(
          (repo.trackEffects(0).single as PluginEffect).name,
          'Ancient Chorus',
        );
      },
    );

    test('a bus-stage plugin keeps no parameters to draw', () {
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setTrackEffects(
          channel: 0,
          effects: const [
            PluginEffect(
              ref: PluginRef(format: PluginFormat.clap, id: 'p'),
              state: 'AAAA',
              paramValues: {1: 0.25},
              // A chain copied from somewhere it DID load — a rack, or a
              // lane-to-bus paste — arrives carrying the enumerated params of
              // that instance.
              params: [
                PluginParamInfo(
                  id: 1,
                  name: 'Mix',
                  unit: '',
                  min: 0,
                  max: 1,
                  def: 0.5,
                  stepCount: 0,
                  flags: 0x01,
                ),
              ],
            ),
          ],
        );

      // The params describe a LOADED instance and there is none: the engine
      // hosts no plugins at this stage. Kept, they draw a row per parameter
      // in the editor — working-looking faders over a plugin that is not
      // running — and the placeholder saying so never appears, because a
      // chain with rows to draw is not empty.
      final fx = repo.trackEffects(0).single as PluginEffect;
      expect(fx.unsupported, isTrue);
      expect(fx.params, isEmpty);
      // And keeps everything it would need to become hostable later, which
      // is the whole argument for keeping the entry at all.
      expect(fx.paramValues, {1: 0.25});
      expect(fx.state, 'AAAA');
      expect(fx.slotId, isNotNull);
    });

    test('a loaded plugin whose installed version drifts is flagged', () async {
      // Same id, different installed version than the saved ref -> the plugin
      // still loads, but the card notes the drift (D-MISS).
      engine.pluginScanResults = const [
        le.PluginDescriptor(
          id: 'p',
          name: 'Reverb',
          vendor: 'Acme',
          path: '/Library/Audio/Plug-Ins/CLAP/reverb.clap',
          format: le.PluginFormat.clap,
          version: 0x00020000, // 2.0.0 installed
        ),
      ];
      final repo = buildRepo()..startEngine(const EngineConfig());
      await repo.pluginCatalog.scan();

      engine.nextSlotHandle = MockPluginSlotHandle('p');
      repo.setLaneEffects(
        lane: 0,
        channel: 0,
        effects: const [
          PluginEffect(
            ref: PluginRef(
              format: PluginFormat.clap,
              id: 'p',
              version: 0x00010000, // 1.0.0 saved
            ),
          ),
        ],
      );

      final fx = repo.laneEffects(0, 0).single as PluginEffect;
      expect(fx.unavailable, isFalse);
      expect(fx.versionChanged, isTrue);
    });

    test('a restored plugin reads as loading while the boot scan is pending, '
        'then unavailable once it lands still missing (F5)', () async {
      // Cold boot: the plugin can't load (empty native cache) and a scan will
      // run. While the scan is pending the entry must render "loading", not a
      // premature "unavailable" — then flip to unavailable if it stays missing.
      engine
        ..nextSlotHandle =
            null // load fails (cold cache)
        ..scanProgressOverride = const PluginScanProgress(
          done: false, // the boot scan does not complete yet
          found: 0,
          scanned: 0,
          total: 1,
        );
      final repo = buildRepo()
        ..setLaneEffects(
          lane: 0,
          channel: 0,
          effects: const [
            PluginEffect(
              ref: PluginRef(format: PluginFormat.clap, id: 'p'),
            ),
          ],
        )
        ..startEngine(const EngineConfig());
      addTearDown(repo.dispose);

      // The startup scan is kicked and pending -> loading, not unavailable.
      var fx = repo.laneEffects(0, 0).single as PluginEffect;
      expect(fx.loading, isTrue);
      expect(fx.unavailable, isFalse);

      // Let the scan complete with the plugin still absent -> unavailable.
      engine.scanProgressOverride = const PluginScanProgress(
        done: true,
        found: 0,
        scanned: 1,
        total: 1,
      );
      await repo.pluginCatalog.scan(); // joins + drains the in-flight scan

      fx = repo.laneEffects(0, 0).single as PluginEffect;
      expect(fx.loading, isFalse);
      expect(fx.unavailable, isTrue);
    });

    test('a restored MONITOR plugin also reads as loading during the boot '
        'scan (F5, monitor apply path)', () async {
      // The cold-start recovery flips unavailable entries to loading on both
      // the lane and monitor apply paths — cover the monitor call site too so a
      // monitor-only regression is caught.
      engine
        ..nextSlotHandle = null
        ..scanProgressOverride = const PluginScanProgress(
          done: false,
          found: 0,
          scanned: 0,
          total: 1,
        );
      final repo = buildRepo()
        ..setMonitorEffects(
          input: 0,
          effects: const [
            PluginEffect(
              ref: PluginRef(format: PluginFormat.clap, id: 'p'),
            ),
          ],
        )
        ..startEngine(const EngineConfig());
      addTearDown(repo.dispose);

      final fx = repo.monitorEffects(0).single as PluginEffect;
      expect(fx.loading, isTrue);
      expect(fx.unavailable, isFalse);
    });

    test('a loaded plugin the catalog has not seen is not flagged drifted', () {
      // No scan has run, so there is no descriptor to compare against: drift is
      // undetectable and must stay false (never a false "versions match").
      engine.nextSlotHandle = MockPluginSlotHandle('p');
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setLaneEffects(
          lane: 0,
          channel: 0,
          effects: const [
            PluginEffect(
              ref: PluginRef(
                format: PluginFormat.clap,
                id: 'p',
                version: 0x00010000,
              ),
            ),
          ],
        );
      final fx = repo.laneEffects(0, 0).single as PluginEffect;
      expect(fx.unavailable, isFalse);
      expect(fx.versionChanged, isFalse);
    });

    test('relinkLanePlugin swaps the ref, keeps state, and reloads', () async {
      engine.nextSlotHandle = null; // initial load fails -> unavailable
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setLaneEffects(
          lane: 0,
          channel: 0,
          effects: [
            PluginEffect(
              ref: const PluginRef(format: PluginFormat.clap, id: 'gone'),
              state: base64Encode([1, 2, 3]),
            ),
          ],
        );
      await repo.pluginCatalog.scan(); // settle recovery -> unavailable
      expect(
        (repo.laneEffects(0, 0).single as PluginEffect).unavailable,
        isTrue,
      );

      // A working plugin is now available; relink to it.
      engine.nextSlotHandle = MockPluginSlotHandle('new');
      expect(
        repo.relinkLanePlugin(
          channel: 0,
          lane: 0,
          index: 0,
          ref: const PluginRef(format: PluginFormat.vst3, id: 'new'),
        ),
        EngineResult.ok,
      );
      final fx = repo.laneEffects(0, 0).single as PluginEffect;
      expect(fx.ref.id, 'new');
      expect(fx.unavailable, isFalse);
      expect(fx.state, base64Encode([1, 2, 3])); // preserved
      // The reloaded (frozen) instance received the preserved state blob.
      expect(engine.stateSets.last, [1, 2, 3]);
    });

    test('an empty chain drops the lane and zeroes the count on restart', () {
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setLaneEffects(
          lane: 0,
          channel: 0,
          effects: [BuiltInEffect(type: TrackEffectType.drive)],
        );
      expect(engine.laneFx[(0, 0, 0)]?.code, TrackEffectType.drive.code);

      repo.setLaneEffects(lane: 0, channel: 0, effects: const []);
      expect(engine.laneFxCount[(0, 0)], 0);

      engine.laneFx.clear();
      repo.startEngine(const EngineConfig());
      expect(engine.laneFx.containsKey((0, 0, 0)), isFalse);
    });

    test('a monitor chain is deferred then re-applied on start', () {
      final repo = buildRepo()
        ..setMonitorEffects(
          input: 0,
          effects: [
            BuiltInEffect(
              type: TrackEffectType.delay,
              params: const [0.3, 0.4, 0.5],
            ),
          ],
        );
      expect(engine.monitorFx, isEmpty); // not running yet

      repo.startEngine(const EngineConfig());
      expect(engine.monitorFx[(0, 0)]?.code, TrackEffectType.delay.code);
      expect(engine.monitorFxParam[(0, 0, 1)], 0.4);
      expect(engine.monitorFxCount[0], 1);
    });

    test('a monitor param tweak updates the entry without resetting it', () {
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setMonitorEffects(
          input: 0,
          effects: [BuiltInEffect(type: TrackEffectType.drive)],
        );
      engine.calls.clear();

      repo.setMonitorEffectParam(input: 0, index: 0, param: 0, value: 0.9);
      expect(engine.monitorFxParam[(0, 0, 0)], 0.9);
      // No setMonitorInputFx (which would reset DSP) — only the granular call.
      expect(engine.calls, isNot(contains('setMonitorInputFx')));
      expect(engine.calls, contains('setMonitorInputFxParam'));

      // The tweak is remembered and re-applied on restart.
      engine.monitorFxParam.clear();
      repo.startEngine(const EngineConfig());
      expect(engine.monitorFxParam[(0, 0, 0)], 0.9);
    });

    test('setMonitorOutput routes the chain and reapplies on restart', () {
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setMonitorOutput(input: 0, mask: 0x2);
      expect(engine.monitorOutput[0], 0x2);

      engine.monitorOutput.clear();
      repo.startEngine(const EngineConfig());
      expect(engine.monitorOutput[0], 0x2);
    });

    test('setMonitorOutput is remembered before the engine starts', () {
      final repo = buildRepo()..setMonitorOutput(input: 1, mask: 0x1);
      expect(engine.monitorOutput, isEmpty); // not running yet
      repo.startEngine(const EngineConfig());
      expect(engine.monitorOutput[1], 0x1);
    });

    test('setMonitorVolume applies the gain and reapplies on restart', () {
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setMonitorVolume(input: 0, volume: 0.5);
      expect(engine.monitorVolume[0], 0.5);

      engine.monitorVolume.clear();
      repo.startEngine(const EngineConfig());
      expect(engine.monitorVolume[0], 0.5);
    });

    test('setMonitorMute mutes the chain and reapplies on restart', () {
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setMonitorMute(input: 0, muted: true);
      expect(engine.monitorMute[0], isTrue);

      engine.monitorMute.clear();
      repo.startEngine(const EngineConfig());
      expect(engine.monitorMute[0], isTrue);
    });

    test('setInputConditioningEnabled forwards while running', () {
      buildRepo()
        ..startEngine(const EngineConfig())
        ..setInputConditioningEnabled(input: 0, enabled: true);
      expect(engine.conditioningEnabled[0], isTrue);
    });

    test('setInputConditioningParam forwards the code + real-unit value', () {
      buildRepo()
        ..startEngine(const EngineConfig())
        ..setInputConditioningParam(
          input: 1,
          param: InputConditioningParam.hpfHz,
          value: 80,
        );
      expect(engine.conditioningParam[(1, InputConditioningParam.hpfHz)], 80);
    });

    test('conditioning intent is remembered and reapplied on restart', () {
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setInputConditioningParam(
          input: 0,
          param: InputConditioningParam.expRatio,
          value: 3,
        )
        ..setInputConditioningEnabled(input: 0, enabled: true);

      engine.conditioningEnabled.clear();
      engine.conditioningParam.clear();
      repo.startEngine(const EngineConfig());

      expect(engine.conditioningEnabled[0], isTrue);
      expect(
        engine.conditioningParam[(0, InputConditioningParam.expRatio)],
        3,
      );
    });

    test('conditioning set while stopped applies on the next start', () {
      final repo = buildRepo()
        ..setInputConditioningEnabled(input: 0, enabled: true);
      // Nothing forwarded yet: the device is not running.
      expect(engine.conditioningEnabled.containsKey(0), isFalse);

      repo.startEngine(const EngineConfig());
      expect(engine.conditioningEnabled[0], isTrue);
    });

    test('rejects an out-of-range conditioning input without touching '
        'the engine', () {
      final repo = buildRepo()..startEngine(const EngineConfig());
      expect(
        repo.setInputConditioningEnabled(input: -1, enabled: true),
        EngineResult.invalid,
      );
      expect(
        repo.setInputConditioningParam(
          input: kMaxMonitoredInputs,
          param: InputConditioningParam.hpfHz,
          value: 40,
        ),
        EngineResult.invalid,
      );
      expect(engine.conditioningEnabled, isEmpty);
      expect(engine.conditioningParam, isEmpty);
    });

    test('an empty monitor chain (clean path) zeroes the count', () {
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setMonitorEffects(
          input: 0,
          effects: [BuiltInEffect(type: TrackEffectType.drive)],
        );
      expect(engine.monitorFx[(0, 0)]?.code, TrackEffectType.drive.code);

      repo.setMonitorEffects(input: 0, effects: const []);
      expect(engine.monitorFxCount[0], 0);
    });

    test('setOutputEnabled applies the gate and reapplies on restart', () {
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setOutputEnabled(output: 1, enabled: false);
      expect(engine.outputEnabled[1], isFalse);
      expect(repo.outputEnabled(1), isFalse);
      expect(repo.outputEnabled(0), isTrue); // default-on

      // Only the off entry is remembered and re-asserted on restart.
      engine.outputEnabled.clear();
      repo.startEngine(const EngineConfig());
      expect(engine.outputEnabled[1], isFalse);

      // Re-enabling drops the stored off entry (default-on); not re-pushed.
      repo.setOutputEnabled(output: 1, enabled: true);
      engine.outputEnabled.clear();
      repo.startEngine(const EngineConfig());
      expect(engine.outputEnabled.containsKey(1), isFalse);
    });

    test('_project surfaces the output gate from the re-apply cache', () {
      // The engine claims every output is on — which is what a STOPPED engine
      // always claims, since the gate is only re-applied at start. The mask the
      // app reads has to be the repository's own intent, or a session loaded
      // with an output gated reads as audible until the device opens.
      engine.nextSnapshot = const EngineSnapshot(
        isRunning: false,
        sampleRate: 48000,
        bufferFrames: 128,
        framesProcessed: 0,
        xrunCount: 0,
        inputRms: 0,
        inputPeak: 0,
        outputRms: 0,
        latencyState: le.LatencyState.idle,
        measuredLatencyMs: -1,
      );
      final repo = buildRepo()..setOutputEnabled(output: 1, enabled: false);
      final state = repo.state;
      expect(state.isOutputEnabled(0), isTrue);
      expect(state.isOutputEnabled(1), isFalse);

      // And re-enabling puts the bit back.
      repo.setOutputEnabled(output: 1, enabled: true);
      expect(repo.state.isOutputEnabled(1), isTrue);
    });

    test('setOutputEnabled re-projects so a stopped rig reports it', () async {
      // No user gesture on the face that draws this: a session load gates the
      // output, and without the re-projection nothing on the stream would say
      // so. Mirrors the setTrackQuantize case.
      final repo = buildRepo();
      final states = <LooperState>[];
      final sub = repo.looperState.listen(states.add);
      addTearDown(() => unawaited(sub.cancel()));

      repo.setOutputEnabled(output: 2, enabled: false);
      await Future<void>.delayed(Duration.zero);
      expect(states, isNotEmpty);
      expect(states.last.isOutputEnabled(2), isFalse);
    });

    test('record snapshots the input monitor chain onto the lane (G3/AC3)', () {
      // Track 0 is EMPTY (so a record is a fresh capture). Lane 0 records input
      // 0 by default.
      engine.nextSnapshot = const EngineSnapshot(
        isRunning: true,
        sampleRate: 48000,
        bufferFrames: 128,
        framesProcessed: 0,
        xrunCount: 0,
        inputRms: 0,
        inputPeak: 0,
        outputRms: 0,
        latencyState: le.LatencyState.idle,
        measuredLatencyMs: -1,
        tracks: [TrackSnapshot.empty()],
      );
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setMonitorEffects(
          input: 0,
          effects: [BuiltInEffect(type: TrackEffectType.delay)],
        )
        ..record(); // track 0 EMPTY -> snapshot copies the input chain

      // The lane now holds a copy of the input chain.
      expect(
        (repo.laneEffects(0, 0).single as BuiltInEffect).type,
        TrackEffectType.delay,
      );

      // Editing the input chain afterwards does NOT alter the recorded lane
      // (copy-on-record, not a live reference — D3).
      repo.setMonitorEffects(
        input: 0,
        effects: [BuiltInEffect(type: TrackEffectType.drive)],
      );
      expect(
        (repo.laneEffects(0, 0).single as BuiltInEffect).type,
        TrackEffectType.delay,
      );
    });

    test('the record snapshot fires onLaneChainChanged for each copied lane '
        '(F3)', () {
      engine.nextSnapshot = const EngineSnapshot(
        isRunning: true,
        sampleRate: 48000,
        bufferFrames: 128,
        framesProcessed: 0,
        xrunCount: 0,
        inputRms: 0,
        inputPeak: 0,
        outputRms: 0,
        latencyState: le.LatencyState.idle,
        measuredLatencyMs: -1,
        tracks: [TrackSnapshot.empty()],
      );
      final changed = <(int, int)>[];
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..onLaneChainChanged = (channel, lane) {
          changed.add((channel, lane));
        }
        ..setMonitorEffects(
          input: 0,
          effects: [BuiltInEffect(type: TrackEffectType.delay)],
        )
        ..record();
      addTearDown(repo.dispose);

      // The notification fired for the take's lane, and the reported chain is
      // the post-take (snapshot-copied) one.
      expect(changed, [(0, 0)]);
      expect(
        (repo.laneEffects(0, 0).single as BuiltInEffect).type,
        TrackEffectType.delay,
      );
    });

    test('a dry monitor does not fire onLaneChainChanged (nothing copied)', () {
      engine.nextSnapshot = const EngineSnapshot(
        isRunning: true,
        sampleRate: 48000,
        bufferFrames: 128,
        framesProcessed: 0,
        xrunCount: 0,
        inputRms: 0,
        inputPeak: 0,
        outputRms: 0,
        latencyState: le.LatencyState.idle,
        measuredLatencyMs: -1,
        tracks: [TrackSnapshot.empty()],
      );
      final changed = <(int, int)>[];
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..onLaneChainChanged = (channel, lane) {
          changed.add((channel, lane));
        }
        ..record(); // clean input chain -> no snapshot copy
      addTearDown(repo.dispose);

      expect(changed, isEmpty);
    });

    test('record keeps a staged lane chain when the input monitor chain is '
        'empty (dry monitor never wipes lane FX)', () {
      // Track 0 is EMPTY, so record is a fresh capture; input 0's monitor
      // chain is clean. The lane's own (staged / persistence-restored) chain
      // must survive the snapshot instead of being cleared.
      engine.nextSnapshot = const EngineSnapshot(
        isRunning: true,
        sampleRate: 48000,
        bufferFrames: 128,
        framesProcessed: 0,
        xrunCount: 0,
        inputRms: 0,
        inputPeak: 0,
        outputRms: 0,
        latencyState: le.LatencyState.idle,
        measuredLatencyMs: -1,
        tracks: [TrackSnapshot.empty()],
      );
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setLaneEffects(
          channel: 0,
          lane: 0,
          effects: [BuiltInEffect(type: TrackEffectType.reverb)],
        )
        ..record();

      expect(
        (repo.laneEffects(0, 0).single as BuiltInEffect).type,
        TrackEffectType.reverb,
      );
    });

    test('clear drops the take FX chain so a dry re-record does not inherit it '
        '(leftover-from-previous-config fix)', () {
      engine.nextSnapshot = const EngineSnapshot(
        isRunning: true,
        sampleRate: 48000,
        bufferFrames: 128,
        framesProcessed: 0,
        xrunCount: 0,
        inputRms: 0,
        inputPeak: 0,
        outputRms: 0,
        latencyState: le.LatencyState.idle,
        measuredLatencyMs: -1,
        tracks: [TrackSnapshot.empty()],
      );
      final persisted = <(int, int)>[];
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..onLaneChainChanged = (channel, lane) {
          persisted.add((channel, lane));
        }
        // Config A: monitor [reverb, delay], record onto the lane.
        ..setMonitorEffects(
          input: 0,
          effects: [
            BuiltInEffect(type: TrackEffectType.reverb),
            BuiltInEffect(type: TrackEffectType.delay),
          ],
        )
        ..record();
      addTearDown(repo.dispose);
      expect(repo.laneEffects(0, 0), hasLength(2));

      // Erase the take and go dry (a config change), then re-record.
      repo
        ..clear()
        ..setMonitorEffects(input: 0, effects: const [])
        ..record();

      // The fresh dry take is dry — A's chain did not survive the clear — and
      // the emptied chain was persisted (so a restart can't replay it).
      expect(repo.laneEffects(0, 0), isEmpty);
      expect(persisted, contains((0, 0)));
    });

    test('the user clear takes the undoable engine path', () {
      engine.nextSnapshot = const EngineSnapshot(
        isRunning: true,
        sampleRate: 48000,
        bufferFrames: 128,
        framesProcessed: 0,
        xrunCount: 0,
        inputRms: 0,
        inputPeak: 0,
        outputRms: 0,
        latencyState: le.LatencyState.idle,
        measuredLatencyMs: -1,
        tracks: [TrackSnapshot.empty()],
      );
      final repo = buildRepo()..startEngine(const EngineConfig());
      addTearDown(repo.dispose);
      engine.calls.clear();

      repo.clear();

      expect(engine.calls, contains('clearUndoable'));
      expect(engine.calls, isNot(contains('clear')));
    });

    test('undoing a clear puts the take FX chain back and re-persists it', () {
      engine.nextSnapshot = const EngineSnapshot(
        isRunning: true,
        sampleRate: 48000,
        bufferFrames: 128,
        framesProcessed: 0,
        xrunCount: 0,
        inputRms: 0,
        inputPeak: 0,
        outputRms: 0,
        latencyState: le.LatencyState.idle,
        measuredLatencyMs: -1,
        tracks: [TrackSnapshot.empty()],
      );
      final persisted = <(int, int)>[];
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..onLaneChainChanged = (channel, lane) {
          persisted.add((channel, lane));
        }
        ..setMonitorEffects(
          input: 0,
          effects: [
            BuiltInEffect(type: TrackEffectType.reverb),
            BuiltInEffect(type: TrackEffectType.delay),
          ],
        )
        ..record();
      addTearDown(repo.dispose);
      expect(repo.laneEffects(0, 0), hasLength(2));

      repo.clear();
      expect(repo.laneEffects(0, 0), isEmpty);

      // The engine says this undo restores the cleared take, so the chain the
      // clear erased comes back with it.
      engine.undoRestoresClearResult = true;
      persisted.clear();
      repo.undo();

      expect(repo.laneEffects(0, 0), hasLength(2));
      expect(
        repo.laneEffects(0, 0).map((e) => (e as BuiltInEffect).type),
        [TrackEffectType.reverb, TrackEffectType.delay],
      );
      // Re-persisted, or a restart would replay the clear's emptied chain over
      // the restored take (F3).
      expect(persisted, contains((0, 0)));
    });

    test('an undo that peels a layer leaves the FX chain alone', () {
      engine.nextSnapshot = const EngineSnapshot(
        isRunning: true,
        sampleRate: 48000,
        bufferFrames: 128,
        framesProcessed: 0,
        xrunCount: 0,
        inputRms: 0,
        inputPeak: 0,
        outputRms: 0,
        latencyState: le.LatencyState.idle,
        measuredLatencyMs: -1,
        tracks: [TrackSnapshot.empty()],
      );
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setMonitorEffects(
          input: 0,
          effects: [BuiltInEffect(type: TrackEffectType.reverb)],
        )
        ..record();
      addTearDown(repo.dispose);

      repo.clear();
      // The engine reports no restore point (a fresh recording retired it),
      // so the stale snapshot must stay inert rather than resurrect a chain
      // onto a take that no longer exists.
      engine.undoRestoresClearResult = false;
      repo.undo();

      expect(repo.laneEffects(0, 0), isEmpty);
    });

    test(
      'applySession clears destructively — a loaded session is not undoable',
      () {
        engine.nextSnapshot = const EngineSnapshot(
          isRunning: true,
          sampleRate: 48000,
          bufferFrames: 128,
          framesProcessed: 0,
          xrunCount: 0,
          inputRms: 0,
          inputPeak: 0,
          outputRms: 0,
          latencyState: le.LatencyState.idle,
          measuredLatencyMs: -1,
          tracks: [TrackSnapshot.empty()],
        );
        final repo = buildRepo()..startEngine(const EngineConfig());
        addTearDown(repo.dispose);
        engine.calls.clear();

        unawaited(repo.applySession(const SessionRig()));

        expect(engine.calls, contains('clear'));
        expect(engine.calls, isNot(contains('clearUndoable')));
      },
    );

    test('record captures the monitor plugin state onto the lane (D-P1)', () {
      engine
        ..nextState = Uint8List.fromList([1, 2, 3, 4])
        ..nextSnapshot = const EngineSnapshot(
          isRunning: true,
          sampleRate: 48000,
          bufferFrames: 128,
          framesProcessed: 0,
          xrunCount: 0,
          inputRms: 0,
          inputPeak: 0,
          outputRms: 0,
          latencyState: le.LatencyState.idle,
          measuredLatencyMs: -1,
          tracks: [TrackSnapshot.empty()],
        );
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setMonitorEffects(
          input: 0,
          effects: const [
            PluginEffect(
              ref: PluginRef(format: PluginFormat.clap, id: 'p'),
            ),
          ],
        )
        ..record();

      // The lane's frozen copy carries the captured opaque state blob.
      final fx = repo.laneEffects(0, 0).single as PluginEffect;
      expect(fx.state, base64Encode([1, 2, 3, 4]));
    });

    test('a monitor plugin whose capture fails is dropped (bypassed) on the '
        'lane (D-P1)', () {
      engine
        ..nextState =
            Uint8List(0) // capture failure -> bypass
        ..nextSnapshot = const EngineSnapshot(
          isRunning: true,
          sampleRate: 48000,
          bufferFrames: 128,
          framesProcessed: 0,
          xrunCount: 0,
          inputRms: 0,
          inputPeak: 0,
          outputRms: 0,
          latencyState: le.LatencyState.idle,
          measuredLatencyMs: -1,
          tracks: [TrackSnapshot.empty()],
        );
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setMonitorEffects(
          input: 0,
          effects: const [
            PluginEffect(
              ref: PluginRef(format: PluginFormat.clap, id: 'p'),
            ),
          ],
        )
        ..record();

      expect(repo.laneEffects(0, 0), isEmpty);
    });

    test('a mid-chain capture failure drops only that entry, keeping order '
        '(D-P1)', () {
      engine
        ..nextState =
            Uint8List(0) // every plugin capture fails -> bypass
        ..nextSnapshot = const EngineSnapshot(
          isRunning: true,
          sampleRate: 48000,
          bufferFrames: 128,
          framesProcessed: 0,
          xrunCount: 0,
          inputRms: 0,
          inputPeak: 0,
          outputRms: 0,
          latencyState: le.LatencyState.idle,
          measuredLatencyMs: -1,
          tracks: [TrackSnapshot.empty()],
        );
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setMonitorEffects(
          input: 0,
          effects: [
            BuiltInEffect(type: TrackEffectType.drive),
            const PluginEffect(
              ref: PluginRef(format: PluginFormat.clap, id: 'p'),
            ),
            BuiltInEffect(type: TrackEffectType.reverb),
          ],
        )
        ..record();

      // The plugin (index 1) is dropped; the surrounding built-ins keep order.
      final lane = repo.laneEffects(0, 0);
      expect(lane, hasLength(2));
      expect((lane[0] as BuiltInEffect).type, TrackEffectType.drive);
      expect((lane[1] as BuiltInEffect).type, TrackEffectType.reverb);
    });

    test('record PUSHES the snapshotted chain to the engine, not just the '
        'cache (one-authority sink)', () {
      // The repository is the sole record-time snapshot authority: after a
      // record-from-EMPTY it must push the copied lane chain to the engine (the
      // engine no longer self-snapshots), so the engine holds exactly what the
      // repo cached.
      engine.nextSnapshot = const EngineSnapshot(
        isRunning: true,
        sampleRate: 48000,
        bufferFrames: 128,
        framesProcessed: 0,
        xrunCount: 0,
        inputRms: 0,
        inputPeak: 0,
        outputRms: 0,
        latencyState: le.LatencyState.idle,
        measuredLatencyMs: -1,
        tracks: [TrackSnapshot.empty()],
      );
      buildRepo()
        ..startEngine(const EngineConfig())
        ..setMonitorEffects(
          input: 0,
          effects: [
            BuiltInEffect(type: TrackEffectType.delay),
            BuiltInEffect(type: TrackEffectType.reverb),
          ],
        )
        ..record();

      // The engine's lane FX now mirror the snapshot the repo computed. (The
      // fake records the engine-package enum, hidden here; compare by name.)
      expect(engine.laneFx[(0, 0, 0)]?.name, 'delay');
      expect(engine.laneFx[(0, 0, 1)]?.name, 'reverb');
      expect(engine.laneFxCount[(0, 0)], 2);
      // The lane-FX push is enqueued BEFORE the record command, so the chain is
      // published before the take can ever play back (no audible gap).
      expect(
        engine.calls.lastIndexOf('setLaneFxCount') <
            engine.calls.indexOf('record'),
        isTrue,
      );
    });

    test('record pushes the captured plugin WITH its frozen state to the '
        'engine (not a placeholder — D-P1)', () {
      engine
        ..nextState = Uint8List.fromList([1, 2, 3, 4])
        ..nextSnapshot = const EngineSnapshot(
          isRunning: true,
          sampleRate: 48000,
          bufferFrames: 128,
          framesProcessed: 0,
          xrunCount: 0,
          inputRms: 0,
          inputPeak: 0,
          outputRms: 0,
          latencyState: le.LatencyState.idle,
          measuredLatencyMs: -1,
          tracks: [TrackSnapshot.empty()],
        );
      buildRepo()
        ..startEngine(const EngineConfig())
        ..setMonitorEffects(
          input: 0,
          effects: const [
            PluginEffect(
              ref: PluginRef(format: PluginFormat.clap, id: 'p'),
            ),
          ],
        )
        ..record();

      // The lane plugin was loaded on the engine and seeded with the exact
      // opaque state captured from the monitor slot — the frozen instance, not
      // a stateless placeholder (the C-side clobber the fix removes).
      expect(engine.lanePlugins[(0, 0, 0)], 'p');
      expect(engine.stateSets, isNotEmpty);
      expect(engine.stateSets.last, Uint8List.fromList([1, 2, 3, 4]));
    });

    test('a dry monitor pushes NO lane FX edit on record (non-clobber)', () {
      // Track 0 EMPTY, input 0 monitor clean, lane 0 holds a staged chain. The
      // record must not touch the engine's lane FX (never a count=0 push), so a
      // deliberately staged / restored engine chain survives untouched.
      engine.nextSnapshot = const EngineSnapshot(
        isRunning: true,
        sampleRate: 48000,
        bufferFrames: 128,
        framesProcessed: 0,
        xrunCount: 0,
        inputRms: 0,
        inputPeak: 0,
        outputRms: 0,
        latencyState: le.LatencyState.idle,
        measuredLatencyMs: -1,
        tracks: [TrackSnapshot.empty()],
      );
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setLaneEffects(
          channel: 0,
          lane: 0,
          effects: [BuiltInEffect(type: TrackEffectType.reverb)],
        );
      engine.calls.clear();
      repo.record();

      // No lane-FX command rode the ring for this dry take.
      expect(engine.calls.where((c) => c.startsWith('setLaneFx')), isEmpty);
    });

    test('an overdub (non-EMPTY track) neither snapshots nor pushes lane '
        'FX', () {
      // Track 0 is PLAYING — a record press is an overdub, not a fresh capture,
      // so the monitor chain must NOT be snapshot-copied or pushed (the gate
      // the fix preserves).
      engine.nextSnapshot = const EngineSnapshot(
        isRunning: true,
        sampleRate: 48000,
        bufferFrames: 128,
        framesProcessed: 0,
        xrunCount: 0,
        inputRms: 0,
        inputPeak: 0,
        outputRms: 0,
        latencyState: le.LatencyState.idle,
        measuredLatencyMs: -1,
        tracks: [
          TrackSnapshot(
            state: TrackState.playing,
            volume: 1,
            muted: false,
            lengthFrames: 96000,
            undoDepth: 1,
            rms: 0,
            peak: 0,
          ),
        ],
      );
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setMonitorEffects(
          input: 0,
          effects: [BuiltInEffect(type: TrackEffectType.delay)],
        );
      engine.calls.clear();
      repo.record();

      expect(engine.calls.where((c) => c.startsWith('setLaneFx')), isEmpty);
      expect(repo.laneEffects(0, 0), isEmpty);
    });

    test('a non-empty monitor whose every plugin capture fails overwrites a '
        'staged lane to empty on cache AND engine (D2 + one-authority)', () {
      // The all-captures-fail edge: input 0 monitors a single plugin whose
      // state capture fails (bypassed), while lane 0 holds a staged chain. The
      // monitored chain still overwrites the lane (D2) — reducing it to empty —
      // and, crucially, that empty is PUSHED so a stale staged engine chain
      // can't outlive the take (cache == engine). This is NOT the dry-monitor
      // path (which keeps the lane); the monitor here is non-empty.
      engine
        ..nextState =
            Uint8List(0) // capture failure -> the entry is dropped
        ..nextSnapshot = const EngineSnapshot(
          isRunning: true,
          sampleRate: 48000,
          bufferFrames: 128,
          framesProcessed: 0,
          xrunCount: 0,
          inputRms: 0,
          inputPeak: 0,
          outputRms: 0,
          latencyState: le.LatencyState.idle,
          measuredLatencyMs: -1,
          tracks: [TrackSnapshot.empty()],
        );
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setLaneEffects(
          channel: 0,
          lane: 0,
          effects: [BuiltInEffect(type: TrackEffectType.reverb)],
        )
        ..setMonitorEffects(
          input: 0,
          effects: const [
            PluginEffect(
              ref: PluginRef(format: PluginFormat.clap, id: 'p'),
            ),
          ],
        );
      engine.calls.clear();
      repo.record();

      // Cache is emptied AND the engine was pushed the empty chain (count 0) —
      // the staged reverb no longer sounds anywhere.
      expect(repo.laneEffects(0, 0), isEmpty);
      expect(engine.laneFxCount[(0, 0)], 0);
    });

    test('a later take captures the CURRENT monitor chain, leaving an earlier '
        "take's snapshot intact (D3)", () {
      // Two temporally-separate takes on two empty tracks: track 0 records
      // input 0 monitoring [delay]; the monitor is then retuned to [drive] and
      // track 1 (lane 0 records input 1) records. Each take froze the chain
      // that was live at ITS record — neither take mutates the other.
      engine.nextSnapshot = const EngineSnapshot(
        isRunning: true,
        sampleRate: 48000,
        bufferFrames: 128,
        framesProcessed: 0,
        xrunCount: 0,
        inputRms: 0,
        inputPeak: 0,
        outputRms: 0,
        latencyState: le.LatencyState.idle,
        measuredLatencyMs: -1,
        tracks: [TrackSnapshot.empty(), TrackSnapshot.empty()],
      );
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setLaneInput(channel: 1, lane: 0, inputChannel: 1)
        ..setMonitorEffects(
          input: 0,
          effects: [BuiltInEffect(type: TrackEffectType.delay)],
        )
        ..record() // track 0 freezes [delay]
        ..setMonitorEffects(
          input: 1,
          effects: [BuiltInEffect(type: TrackEffectType.drive)],
        )
        ..record(channel: 1); // track 1 freezes [drive]

      expect(
        (repo.laneEffects(0, 0).single as BuiltInEffect).type,
        TrackEffectType.delay,
      );
      expect(
        (repo.laneEffects(1, 0).single as BuiltInEffect).type,
        TrackEffectType.drive,
      );
    });

    test('a corrupt state blob is ignored; the plugin still loads', () {
      engine.nextParamInfos = const [
        le.PluginParamInfo(
          id: 100,
          name: 'Mix',
          unit: '',
          min: 0,
          max: 1,
          def: 0.5,
          stepCount: 0,
          flags: 0x01,
        ),
      ];
      // A garbage (non-base64) blob must not crash the restore.
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setLaneEffects(
          lane: 0,
          channel: 0,
          effects: const [
            PluginEffect(
              ref: PluginRef(format: PluginFormat.clap, id: 'p'),
              state: 'not-valid-base64!!!',
            ),
          ],
        );
      final fx = repo.laneEffects(0, 0).single as PluginEffect;
      expect(fx.unavailable, isFalse); // loaded fine, just at default state
      expect(fx.params, hasLength(1));
    });

    test('restoring a lane plugin replays its state blob (D-P1 frozen)', () {
      buildRepo()
        ..startEngine(const EngineConfig())
        ..setLaneEffects(
          lane: 0,
          channel: 0,
          effects: [
            PluginEffect(
              ref: const PluginRef(format: PluginFormat.clap, id: 'p'),
              state: base64Encode([9, 8, 7]),
            ),
          ],
        );
      // The lane loaded its own instance and pushed the saved blob to it.
      expect(engine.stateSets, isNotEmpty);
      expect(engine.stateSets.last, [9, 8, 7]);
    });

    test('clearing a track multiple (0) drops the override', () {
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setTrackMultiple(channel: 1, multiple: 2);
      expect(engine.trackMultiple[1], 2);

      repo.setTrackMultiple(channel: 1, multiple: 0);
      expect(engine.trackMultiple[1], 0);

      engine.trackMultiple.clear();
      repo.startEngine(const EngineConfig());
      expect(engine.trackMultiple.containsKey(1), isFalse);
    });

    test(
      'a per-input monitor enable is deferred until running, then applied',
      () {
        final repo = buildRepo()
          ..setMonitorInputMode(input: 1, mode: MonitorMode.on);
        expect(engine.monitorInputEnabled, isEmpty); // not running yet

        repo.startEngine(const EngineConfig());
        expect(engine.monitorInputEnabled[1], isTrue);
      },
    );

    test('per-input monitors are independent and survive a restart', () {
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setMonitorInputMode(input: 0, mode: MonitorMode.on)
        ..setMonitorOutput(input: 0, mask: 0x1)
        ..setMonitorInputMode(input: 1, mode: MonitorMode.on)
        ..setMonitorOutput(input: 1, mask: 0x2);
      expect(engine.monitorInputEnabled[0], isTrue);
      expect(engine.monitorOutput[0], 0x1);
      expect(engine.monitorOutput[1], 0x2);

      // Disabling one input leaves the other untouched.
      repo.setMonitorInputMode(input: 0, mode: MonitorMode.off);
      expect(engine.monitorInputEnabled[0], isFalse);
      expect(engine.monitorInputEnabled[1], isTrue);

      // Both are re-applied on restart.
      engine.monitorInputEnabled.clear();
      engine.monitorOutput.clear();
      repo.startEngine(const EngineConfig());
      expect(engine.monitorInputEnabled[0], isFalse);
      expect(engine.monitorInputEnabled[1], isTrue);
      expect(engine.monitorOutput[0], 0x1);
      expect(engine.monitorOutput[1], 0x2);
    });

    test('engineVersion is forwarded', () {
      final repo = buildRepo();
      expect(repo.engineVersion, 'fake-engine');
    });

    test('setRecordOffset forwards to the engine while running', () {
      // Now a cached setter (deferred until running, re-applied on restart), so
      // it forwards while the engine is up — the deferred/restart paths are
      // covered in the audio-config group.
      buildRepo()
        ..startEngine(const EngineConfig())
        ..setRecordOffset(480);
      expect(engine.calls, contains('setRecordOffset'));
      expect(engine.lastRecordOffset, 480);
    });

    test('setInputMask maps the lowest selected input onto lane 0', () {
      // 0x6 selects inputs 1 and 2; the lowest (1) records into lane 0.
      buildRepo().setInputMask(channel: 2, mask: 0x6);
      expect(engine.calls, contains('setLaneInput'));
      expect(engine.laneInput[(2, 0)], 1);
    });

    test('setOutputMask forwards the mask onto lane 0', () {
      buildRepo().setOutputMask(channel: 1, mask: 0x5);
      expect(engine.calls, contains('setLaneOutput'));
      expect(engine.laneOutput[(1, 0)], 0x5);
    });

    test('setLaneCount remembers, defers, and re-applies on start', () {
      final repo = buildRepo()..setLaneCount(channel: 2, count: 3);
      // Not running yet: remembered but not pushed to the engine.
      expect(engine.laneCount, isEmpty);
      expect(repo.laneCount(2), 3);

      repo.startEngine(const EngineConfig());
      expect(engine.laneCount[2], 3);

      // Count 1 (the default) drops the override and does not re-apply.
      repo.setLaneCount(channel: 2, count: 1);
      expect(repo.laneCount(2), 1);
      engine.laneCount.clear();
      repo.startEngine(const EngineConfig());
      expect(engine.laneCount.containsKey(2), isFalse);
    });

    test('setMute on a multi-lane track mutes EVERY lane, not just lane 0', () {
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setLaneCount(channel: 2, count: 3);
      addTearDown(repo.dispose);

      repo.setMute(muted: true, channel: 2);
      expect(engine.laneMute[(2, 0)], isTrue);
      expect(engine.laneMute[(2, 1)], isTrue);
      expect(engine.laneMute[(2, 2)], isTrue);

      // Unmute spans the whole track too.
      repo.setMute(muted: false, channel: 2);
      expect(engine.laneMute[(2, 0)], isFalse);
      expect(engine.laneMute[(2, 1)], isFalse);
      expect(engine.laneMute[(2, 2)], isFalse);
    });

    test(
      'trackMuted reads the remembered whole-track intent synchronously',
      () {
        // The synchronous reader toggles resolve from — the polled snapshot is
        // ~16 ms stale, and a toggle resolved from it can double-apply inside
        // the echo window (segno #704 review).
        final repo = buildRepo()
          ..startEngine(const EngineConfig())
          ..setLaneCount(channel: 2, count: 2);
        addTearDown(repo.dispose);

        expect(repo.trackMuted(2), isFalse);
        repo.setMute(muted: true, channel: 2);
        expect(repo.trackMuted(2), isTrue);

        // A partially-muted track is not "muted": trackMuted mirrors setMute's
        // whole-track reading, every lane of it.
        repo.setLaneMute(muted: false, channel: 2, lane: 1);
        expect(repo.trackMuted(2), isFalse);

        repo.setMute(muted: false, channel: 2);
        expect(repo.trackMuted(2), isFalse);
      },
    );

    test(
      'setVolume on a multi-lane track sets EVERY lane, not just lane 0',
      () {
        final repo = buildRepo()
          ..startEngine(const EngineConfig())
          ..setLaneCount(channel: 2, count: 3);
        addTearDown(repo.dispose);

        repo.setVolume(0.4, channel: 2);
        expect(engine.laneVol[(2, 0)], 0.4);
        expect(engine.laneVol[(2, 1)], 0.4);
        expect(engine.laneVol[(2, 2)], 0.4);
      },
    );

    test('clearing a muted multi-lane track unmutes every lane (so a later '
        'record/overdub is audible)', () {
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setLaneCount(channel: 1, count: 2)
        ..setMute(muted: true, channel: 1);
      addTearDown(repo.dispose);
      expect(engine.laneMute[(1, 0)], isTrue);
      expect(engine.laneMute[(1, 1)], isTrue);

      // The clear path (engine clear + track-level unmute, as the bloc/cubit do).
      repo
        ..clear(channel: 1)
        ..setMute(muted: false, channel: 1);

      // Regression: lane 1 must not stay muted (only lane 0 got it before).
      expect(engine.laneMute[(1, 0)], isFalse);
      expect(engine.laneMute[(1, 1)], isFalse);
    });

    test('recording onto a PLAYING track (overdub) unmutes every lane, like a '
        'fresh take does', () {
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setLaneCount(channel: 0, count: 2)
        ..setMute(muted: true);
      addTearDown(repo.dispose);
      expect(engine.laneMute[(0, 0)], isTrue);
      expect(engine.laneMute[(0, 1)], isTrue);

      // Track 0 is playing -> this record() starts an overdub.
      engine.nextSnapshot = _playingSnapshot;
      repo.record();

      expect(engine.laneMute[(0, 0)], isFalse);
      expect(engine.laneMute[(0, 1)], isFalse);
      expect(engine.calls, contains('record'));
    });

    test('detectLoopback forwards the engine result', () {
      engine.loopback = const le.LoopbackInfo(
        available: true,
        kind: le.LoopbackKind.monitor,
        deviceName: 'Monitor of Built-in',
      );
      final repo = buildRepo();
      final info = repo.detectLoopback();
      expect(info.available, isTrue);
      expect(info.kind, LoopbackKind.monitor);
      expect(engine.calls, contains('detectLoopback'));
    });
  });

  group('tempo grid + click + count-in (A4b)', () {
    test('setTempo is deferred until running, then re-applied', () {
      final repo = buildRepo()..setTempo(140);
      expect(engine.lastTempoBpm, isNull); // not running yet

      repo.startEngine(const EngineConfig());
      expect(engine.lastTempoBpm, 140);
    });

    test('setTempo applies immediately while running', () {
      buildRepo()
        ..startEngine(const EngineConfig())
        ..setTempo(90);
      expect(engine.lastTempoBpm, 90);
    });

    test(
      'an unset tempo is never pushed on start (0 would clamp up to 30)',
      () {
        buildRepo().startEngine(const EngineConfig());
        expect(engine.lastTempoBpm, isNull);
      },
    );

    test('setTempo re-applies on every restart (device change)', () {
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setTempo(128);
      expect(engine.lastTempoBpm, 128);

      // A restart (reconnect / device switch) resets the engine's tempo grid
      // to the tempo-free defaults, so the remembered tempo must be pushed
      // again.
      engine.lastTempoBpm = null;
      repo
        ..stopEngine()
        ..startEngine(const EngineConfig());
      expect(engine.lastTempoBpm, 128);
    });

    test('setTimeSignature is deferred until running, then re-applied', () {
      final repo = buildRepo()..setTimeSignature(3, 4);
      expect(engine.lastTimeSignature, isNull); // not running yet

      repo.startEngine(const EngineConfig());
      expect(engine.lastTimeSignature, (3, 4));
    });

    test('setTimeSignature applies immediately while running', () {
      buildRepo()
        ..startEngine(const EngineConfig())
        ..setTimeSignature(5, 8);
      expect(engine.lastTimeSignature, (5, 8));
    });

    test('tapTempo forwards to the engine and is never remembered', () {
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..tapTempo();
      expect(engine.calls, contains('tapTempo'));

      // A momentary action, not remembered state: a restart never replays it.
      engine.calls.clear();
      repo
        ..stopEngine()
        ..startEngine(const EngineConfig());
      expect(engine.calls, isNot(contains('tapTempo')));
    });

    test('setSyncTempo is deferred until running, then re-applied', () {
      final repo = buildRepo()..setSyncTempo(on: false);
      expect(engine.lastSyncTempo, isNull); // not running yet

      repo.startEngine(const EngineConfig());
      expect(engine.lastSyncTempo, isFalse);
    });

    test('setQuantizeDiv is deferred until running, then re-applied', () {
      final repo = buildRepo()..setQuantizeDiv(GridDivision.eighth);
      expect(engine.lastQuantizeDiv, isNull); // not running yet

      repo.startEngine(const EngineConfig());
      expect(engine.lastQuantizeDiv, GridDivision.eighth);
    });

    test('setClickMode is deferred until running, then re-applied', () {
      final repo = buildRepo()..setClickMode(ClickMode.playRec);
      expect(engine.lastClickMode, isNull); // not running yet

      repo.startEngine(const EngineConfig());
      expect(engine.lastClickMode, ClickMode.playRec);
    });

    test('setClickOutput is deferred until running, then re-applied', () {
      final repo = buildRepo()..setClickOutput(0x3);
      expect(engine.lastClickOutput, isNull); // not running yet

      repo.startEngine(const EngineConfig());
      expect(engine.lastClickOutput, 0x3);
    });

    test('setClickVolume is deferred until running, then re-applied', () {
      final repo = buildRepo()..setClickVolume(0.5);
      expect(engine.lastClickVolume, isNull); // not running yet

      repo.startEngine(const EngineConfig());
      expect(engine.lastClickVolume, 0.5);
    });

    test('setClickVolume applies immediately while running', () {
      final repo = buildRepo()..startEngine(const EngineConfig());
      // The start re-applied the default (unity).
      expect(engine.lastClickVolume, 1.0);

      repo.setClickVolume(0.25);
      expect(engine.lastClickVolume, 0.25);
    });

    test('setCountIn is deferred until running, then re-applied', () {
      final repo = buildRepo()..setCountIn(2);
      expect(engine.lastCountIn, isNull); // not running yet

      repo.startEngine(const EngineConfig());
      expect(engine.lastCountIn, 2);
    });

    test('setCountIn clamps a negative to zero', () {
      buildRepo()
        ..startEngine(const EngineConfig())
        ..setCountIn(-3);
      expect(engine.lastCountIn, 0);
    });

    test('setLooperMode is deferred until running, then re-applied', () {
      final repo = buildRepo()..setLooperMode(LooperMode.sync);
      expect(engine.lastLooperMode, isNull); // not running yet

      repo.startEngine(const EngineConfig());
      expect(engine.lastLooperMode, LooperMode.sync);
    });

    test('setLooperMode applies immediately while running', () {
      buildRepo()
        ..startEngine(const EngineConfig())
        ..setLooperMode(LooperMode.band);
      expect(engine.lastLooperMode, LooperMode.band);
    });

    test(
      'the grid-off defaults (signature 4/4, sync on, quantize div/click/ '
      'count-in off, looper mode multi) still re-apply on a plain start',
      () {
        buildRepo().startEngine(const EngineConfig());
        expect(engine.lastTimeSignature, (4, 4));
        expect(engine.lastSyncTempo, isTrue);
        expect(engine.lastQuantizeDiv, GridDivision.off);
        expect(engine.lastClickMode, ClickMode.off);
        expect(engine.lastClickOutput, 0);
        expect(engine.lastClickVolume, 1.0);
        expect(engine.lastCountIn, 0);
        expect(engine.lastLooperMode, LooperMode.multi);
      },
    );

    test(
      'signature, sync, quantize div, click mode/output/volume, count-in, '
      'and looper mode re-apply on every restart (device change)',
      () {
        final repo = buildRepo()
          ..startEngine(const EngineConfig())
          ..setTimeSignature(3, 4)
          ..setSyncTempo(on: false)
          ..setQuantizeDiv(GridDivision.bar)
          ..setClickMode(ClickMode.rec)
          ..setClickOutput(0x1)
          ..setClickVolume(0.7)
          ..setCountIn(4)
          ..setLooperMode(LooperMode.free);

        engine
          ..lastTimeSignature = null
          ..lastSyncTempo = null
          ..lastQuantizeDiv = null
          ..lastClickMode = null
          ..lastClickOutput = null
          ..lastClickVolume = null
          ..lastCountIn = null
          ..lastLooperMode = null;
        repo
          ..stopEngine()
          ..startEngine(const EngineConfig());

        expect(engine.lastTimeSignature, (3, 4));
        expect(engine.lastSyncTempo, isFalse);
        expect(engine.lastQuantizeDiv, GridDivision.bar);
        expect(engine.lastClickMode, ClickMode.rec);
        expect(engine.lastClickOutput, 0x1);
        expect(engine.lastClickVolume, 0.7);
        expect(engine.lastCountIn, 4);
        expect(engine.lastLooperMode, LooperMode.free);
      },
    );

    test(
      'setTrackLengthPreset is deferred until running, then re-applied',
      () {
        final repo = buildRepo()..setTrackLengthPreset(channel: 1, bars: 4);
        expect(engine.trackLengthPreset, isEmpty); // not running yet

        repo.startEngine(const EngineConfig());
        expect(engine.trackLengthPreset[1], 4);
      },
    );

    test('setTrackLengthPreset applies immediately while running', () {
      buildRepo()
        ..startEngine(const EngineConfig())
        ..setTrackLengthPreset(channel: 2, bars: 8);
      expect(engine.trackLengthPreset[2], 8);
    });

    test('setTrackLengthPreset(0) clears a remembered preset (AUTO)', () {
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setTrackLengthPreset(channel: 1, bars: 4);
      expect(engine.trackLengthPreset[1], 4);

      repo.setTrackLengthPreset(channel: 1, bars: 0);
      expect(engine.trackLengthPreset[1], 0);

      // A restart no longer replays the cleared preset.
      engine.trackLengthPreset.clear();
      repo
        ..stopEngine()
        ..startEngine(const EngineConfig());
      expect(engine.trackLengthPreset, isEmpty);
    });

    test(
      'per-track length presets re-apply on every restart (device change)',
      () {
        final repo = buildRepo()
          ..startEngine(const EngineConfig())
          ..setTrackLengthPreset(channel: 1, bars: 3);
        expect(engine.trackLengthPreset[1], 3);

        engine.trackLengthPreset.clear();
        repo
          ..stopEngine()
          ..startEngine(const EngineConfig());
        expect(engine.trackLengthPreset[1], 3);
      },
    );

    test('crownPrimary is deferred until running, then re-applied', () {
      final repo = buildRepo()..crownPrimary(channel: 2);
      expect(engine.lastCrownedChannel, isNull); // not running yet

      repo.startEngine(const EngineConfig());
      expect(engine.lastCrownedChannel, 2);
    });

    test('crownPrimary applies immediately while running', () {
      buildRepo()
        ..startEngine(const EngineConfig())
        ..crownPrimary(channel: 5);
      expect(engine.lastCrownedChannel, 5);
    });

    test(
      'the crown re-applies on every restart (device change), like looper '
      'mode — D18, no un-crown call means the cache never has a "default" '
      'to fall back to, only a remembered channel',
      () {
        final repo = buildRepo()
          ..startEngine(const EngineConfig())
          ..crownPrimary(channel: 4);
        expect(engine.lastCrownedChannel, 4);

        engine.lastCrownedChannel = null;
        repo
          ..stopEngine()
          ..startEngine(const EngineConfig());
        expect(engine.lastCrownedChannel, 4);
      },
    );

    test('a never-crowned track does not push crownPrimary on start', () {
      buildRepo().startEngine(const EngineConfig());
      expect(engine.lastCrownedChannel, isNull);
    });

    test('setOneShot is deferred until running, then re-applied', () {
      final repo = buildRepo()..setOneShot(channel: 1, oneShot: true);
      expect(engine.trackOneShot, isEmpty); // not running yet

      repo.startEngine(const EngineConfig());
      expect(engine.trackOneShot[1], isTrue);
    });

    test('setOneShot applies immediately while running', () {
      buildRepo()
        ..startEngine(const EngineConfig())
        ..setOneShot(channel: 2, oneShot: true);
      expect(engine.trackOneShot[2], isTrue);
    });

    test('setOneShot(false) clears a remembered flag', () {
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setOneShot(channel: 1, oneShot: true);
      expect(engine.trackOneShot[1], isTrue);

      repo.setOneShot(channel: 1, oneShot: false);
      expect(engine.trackOneShot[1], isFalse);

      // A restart no longer replays the cleared flag.
      engine.trackOneShot.clear();
      repo
        ..stopEngine()
        ..startEngine(const EngineConfig());
      expect(engine.trackOneShot, isEmpty);
    });

    test(
      'per-track one-shot flags re-apply on every restart (device change)',
      () {
        final repo = buildRepo()
          ..startEngine(const EngineConfig())
          ..setOneShot(channel: 3, oneShot: true);
        expect(engine.trackOneShot[3], isTrue);

        engine.trackOneShot.clear();
        repo
          ..stopEngine()
          ..startEngine(const EngineConfig());
        expect(engine.trackOneShot[3], isTrue);
      },
    );

    test(
      'TransportState projects every tempo-grid + click + count-in + '
      'looper-mode field from the snapshot',
      () {
        engine.nextSnapshot = const EngineSnapshot(
          isRunning: true,
          sampleRate: 48000,
          bufferFrames: 128,
          framesProcessed: 0,
          xrunCount: 0,
          inputRms: 0,
          inputPeak: 0,
          outputRms: 0,
          latencyState: le.LatencyState.idle,
          measuredLatencyMs: -1,
          tempoBpm: 128,
          tempoSource: TempoSource.manual,
          tsNum: 3,
          syncTempo: false,
          quantizeDiv: GridDivision.quarter,
          loopBars: 4,
          currentBeat: 2,
          clickMode: ClickMode.playRec,
          clickMask: 0x3,
          clickVolume: 0.8,
          countInBars: 2,
          countingIn: true,
          countInBeatsLeft: 3,
          looperMode: LooperMode.band,
          primaryTrack: 2,
        );

        // primaryTrack now projects from the repository's own re-apply
        // cache, not the raw snapshot field (independent review of #295,
        // D18 stale-crown fix — see `_project`'s doc) — crown through the
        // real API so the cache agrees with the snapshot fixture above,
        // matching how a genuinely-crowned engine is reached in practice.
        final transport =
            (buildRepo()..crownPrimary(channel: 2)).state.transport;
        expect(transport.tempoBpm, 128);
        expect(transport.tempoSource, TempoSource.manual);
        expect(transport.tsNum, 3);
        expect(transport.tsDen, 4);
        expect(transport.syncTempo, isFalse);
        expect(transport.quantizeDiv, GridDivision.quarter);
        expect(transport.loopBars, 4);
        expect(transport.currentBeat, 2);
        expect(transport.clickMode, ClickMode.playRec);
        expect(transport.clickMask, 0x3);
        expect(transport.clickVolume, closeTo(0.8, 1e-9));
        expect(transport.countInBars, 2);
        expect(transport.countingIn, isTrue);
        expect(transport.countInBeatsLeft, 3);
        expect(transport.looperMode, LooperMode.band);
        expect(transport.primaryTrack, 2);
      },
    );

    test(
      'TransportState defaults to the tempo-free grid-off values',
      () {
        final transport = buildRepo().state.transport;
        expect(transport.tempoBpm, 0);
        expect(transport.tempoSource, TempoSource.none);
        expect(transport.tsNum, 4);
        expect(transport.tsDen, 4);
        expect(transport.syncTempo, isTrue);
        expect(transport.quantizeDiv, GridDivision.off);
        expect(transport.loopBars, 0);
        expect(transport.currentBeat, 0);
        expect(transport.clickMode, ClickMode.off);
        expect(transport.clickMask, 0);
        expect(transport.clickVolume, 1);
        expect(transport.countInBars, 0);
        expect(transport.countingIn, isFalse);
        expect(transport.countInBeatsLeft, 0);
        expect(transport.looperMode, LooperMode.multi);
        expect(transport.primaryTrack, -1);
      },
    );
  });

  group('applySession', () {
    /// A snapshot with [count] settled-empty tracks (the post-clear state), so
    /// the apply's settle wait passes immediately.
    EngineSnapshot clearedSnapshot(int count) => EngineSnapshot(
      isRunning: true,
      sampleRate: 48000,
      bufferFrames: 128,
      framesProcessed: 0,
      xrunCount: 0,
      inputRms: 0,
      inputPeak: 0,
      outputRms: 0,
      latencyState: le.LatencyState.idle,
      measuredLatencyMs: -1,
      tracks: [for (var i = 0; i < count; i++) const TrackSnapshot.empty()],
    );

    /// A single-lane (lane 0) rig track holding one live layer of [pcm].
    SessionRigTrack rigTrack(
      int channel,
      Float32List pcm, {
      double volume = 1,
      bool muted = false,
      int outputMask = 0x3,
      int inputChannel = 0,
      int lengthPresetBars = 0,
      bool oneShot = false,
    }) => SessionRigTrack(
      channel: channel,
      lengthPresetBars: lengthPresetBars,
      oneShot: oneShot,
      lanes: [
        SessionRigLane(
          lane: 0,
          layers: [pcm],
          volume: volume,
          muted: muted,
          outputMask: outputMask,
          inputChannel: inputChannel,
        ),
      ],
    );

    test(
      'clears every track, imports stems, commits, and applies mix',
      () async {
        engine.nextSnapshot = clearedSnapshot(2);
        final repo = buildRepo()..startEngine(const EngineConfig());
        addTearDown(repo.dispose);

        final pcm = Float32List.fromList([1, 1, 1, 1]);
        await repo.applySession(
          SessionRig(
            baseLengthFrames: 4,
            tracks: [rigTrack(0, pcm, volume: 0.5, muted: true)],
          ),
          clearPollInterval: Duration.zero,
        );

        expect(
          engine.calls,
          containsAllInOrder(<String>[
            'clear',
            'clear',
            'importLayer',
            'finalizeLayers',
            'commitSession',
            'setLaneVolume',
            'setLaneMute',
          ]),
        );
        expect(engine.importedTracks[0], pcm);
        expect(engine.committedBaseFrames, 4);
        expect(engine.laneVol[(0, 0)], 0.5);
        expect(engine.laneMute[(0, 0)], isTrue);
      },
    );

    test('fires rigReplaced once on a successful apply — the explicit seam '
        '(the cleared window is transient, so the projection alone cannot '
        'announce the replacement)', () async {
      engine.nextSnapshot = clearedSnapshot(2);
      final repo = buildRepo()..startEngine(const EngineConfig());
      addTearDown(repo.dispose);

      final replacements = <void>[];
      final sub = repo.rigReplaced.listen(replacements.add);
      addTearDown(sub.cancel);

      await repo.applySession(
        SessionRig(
          baseLengthFrames: 4,
          tracks: [
            rigTrack(0, Float32List.fromList([1, 1, 1, 1])),
          ],
        ),
        clearPollInterval: Duration.zero,
      );
      // The listen microtask.
      await Future<void>.delayed(Duration.zero);

      expect(replacements, hasLength(1));
    });

    test('does not fire rigReplaced on a failed apply — a failed load leaves '
        'a stably empty rig the projection does announce', () async {
      // Never settles empty, so the apply's clear wait throws.
      engine.nextSnapshot = _playingSnapshot;
      final repo = buildRepo()..startEngine(const EngineConfig());
      addTearDown(repo.dispose);

      final replacements = <void>[];
      final sub = repo.rigReplaced.listen(replacements.add);
      addTearDown(sub.cancel);

      await expectLater(
        repo.applySession(
          const SessionRig(),
          clearPollInterval: Duration.zero,
          clearPollAttempts: 1,
        ),
        throwsStateError,
      );
      await Future<void>.delayed(Duration.zero);

      expect(replacements, isEmpty);
    });

    test('an empty rig imports nothing and establishes no master', () async {
      engine.nextSnapshot = clearedSnapshot(2);
      final repo = buildRepo()..startEngine(const EngineConfig());
      addTearDown(repo.dispose);

      await repo.applySession(
        const SessionRig(),
        clearPollInterval: Duration.zero,
      );

      expect(engine.calls, isNot(contains('importLayer')));
      expect(engine.calls, isNot(contains('commitSession')));
      expect(engine.committedBaseFrames, isNull);
    });

    test('a restart after apply replays the LOADED mix, never the pre-load '
        'caches (F2a/F2b)', () async {
      engine.nextSnapshot = clearedSnapshot(3);
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        // Pre-load rig: remembered volume + mute on track 2.
        ..setLaneVolume(0.9, channel: 2, lane: 0)
        ..setLaneMute(muted: true, channel: 2, lane: 0);
      addTearDown(repo.dispose);

      await repo.applySession(
        SessionRig(
          baseLengthFrames: 4,
          tracks: [
            rigTrack(0, Float32List.fromList([1, 1, 1, 1]), volume: 0.5),
          ],
        ),
        clearPollInterval: Duration.zero,
      );

      // A device restart replays only the loaded session's mix.
      engine.laneVol.clear();
      engine.laneMute.clear();
      repo
        ..stopEngine()
        ..startEngine(const EngineConfig());

      expect(engine.laneVol, {(0, 0): 0.5});
      expect(engine.laneMute, {(0, 0): false});
    });

    test(
      'resets a stale length preset to AUTO when the loaded session leaves '
      'it undefined (A6)',
      () async {
        engine.nextSnapshot = clearedSnapshot(2);
        final repo = buildRepo()
          ..startEngine(const EngineConfig())
          // A live/prior session left track 0 at a 4-bar preset.
          ..setTrackLengthPreset(channel: 0, bars: 4);
        addTearDown(repo.dispose);
        expect(engine.trackLengthPreset[0], 4);

        // The loaded session's track 0 has content but no preset (AUTO),
        // and it says nothing at all about track 1.
        await repo.applySession(
          SessionRig(
            baseLengthFrames: 4,
            tracks: [
              rigTrack(0, Float32List.fromList([1, 1, 1, 1])),
            ],
          ),
          clearPollInterval: Duration.zero,
        );

        expect(engine.trackLengthPreset[0], 0);
        expect(engine.trackLengthPreset[1], 0);

        // A restart replays only the loaded (AUTO) value, not the stale 4.
        engine.trackLengthPreset.clear();
        repo
          ..stopEngine()
          ..startEngine(const EngineConfig());
        expect(engine.trackLengthPreset.containsKey(0), isFalse);
      },
    );

    test(
      "applies the loaded session's own nonzero length preset per track "
      '(A6)',
      () async {
        engine.nextSnapshot = clearedSnapshot(2);
        final repo = buildRepo()..startEngine(const EngineConfig());
        addTearDown(repo.dispose);

        await repo.applySession(
          SessionRig(
            baseLengthFrames: 4,
            tracks: [
              rigTrack(
                0,
                Float32List.fromList([1, 1, 1, 1]),
                lengthPresetBars: 8,
              ),
            ],
          ),
          clearPollInterval: Duration.zero,
        );

        expect(engine.trackLengthPreset[0], 8);
      },
    );

    test(
      'resets a stale one-shot flag when the loaded session leaves it '
      'undefined (B5c) — mirrors the A6 length-preset reset above, since '
      'a_one_shot survives `clear` by the same "setting, not content" rule',
      () async {
        engine.nextSnapshot = clearedSnapshot(2);
        final repo = buildRepo()
          ..startEngine(const EngineConfig())
          // A live/prior session left track 0 marked One Shot.
          ..setOneShot(channel: 0, oneShot: true);
        addTearDown(repo.dispose);
        expect(engine.trackOneShot[0], isTrue);

        // The loaded session's track 0 has content but is not One Shot, and
        // it says nothing at all about track 1.
        await repo.applySession(
          SessionRig(
            baseLengthFrames: 4,
            tracks: [
              rigTrack(0, Float32List.fromList([1, 1, 1, 1])),
            ],
          ),
          clearPollInterval: Duration.zero,
        );

        expect(engine.trackOneShot[0], isFalse);
        expect(engine.trackOneShot[1], isFalse);

        // A restart replays only the loaded (off) value, not the stale true.
        engine.trackOneShot.clear();
        repo
          ..stopEngine()
          ..startEngine(const EngineConfig());
        expect(engine.trackOneShot.containsKey(0), isFalse);
      },
    );

    test(
      "applies the loaded session's own one-shot flag per track (B5c)",
      () async {
        engine.nextSnapshot = clearedSnapshot(2);
        final repo = buildRepo()..startEngine(const EngineConfig());
        addTearDown(repo.dispose);

        await repo.applySession(
          SessionRig(
            baseLengthFrames: 4,
            tracks: [
              rigTrack(0, Float32List.fromList([1, 1, 1, 1]), oneShot: true),
            ],
          ),
          clearPollInterval: Duration.zero,
        );

        expect(engine.trackOneShot[0], isTrue);
      },
    );

    test(
      'restores a One Shot flag pre-armed on a CONTENT-LESS channel via '
      'rig.oneShotChannels (independent review of #295): channel 1 has no '
      'SessionRigTrack (no content), so only the session-level set can '
      'restore it — a plain per-track restore would silently drop it',
      () async {
        engine.nextSnapshot = clearedSnapshot(2);
        final repo = buildRepo()..startEngine(const EngineConfig());
        addTearDown(repo.dispose);

        await repo.applySession(
          SessionRig(
            baseLengthFrames: 4,
            tracks: [
              rigTrack(0, Float32List.fromList([1, 1, 1, 1])),
            ],
            oneShotChannels: const {1},
          ),
          clearPollInterval: Duration.zero,
        );

        expect(engine.trackOneShot[0], isFalse);
        expect(engine.trackOneShot[1], isTrue);

        // Restored through the remembered cache too, so a restart replays it.
        engine.trackOneShot.clear();
        repo
          ..stopEngine()
          ..startEngine(const EngineConfig());
        expect(engine.trackOneShot[1], isTrue);
      },
    );

    test(
      'ignores an out-of-range channel in rig.oneShotChannels rather than '
      'pushing an invalid channel to the engine (a manifest saved on a '
      'build with more physical tracks than this engine)',
      () async {
        engine.nextSnapshot = clearedSnapshot(2);
        final repo = buildRepo()..startEngine(const EngineConfig());
        addTearDown(repo.dispose);

        await repo.applySession(
          SessionRig(
            baseLengthFrames: 4,
            tracks: [
              rigTrack(0, Float32List.fromList([1, 1, 1, 1])),
            ],
            oneShotChannels: const {7},
          ),
          clearPollInterval: Duration.zero,
        );

        expect(engine.trackOneShot.containsKey(7), isFalse);
      },
    );

    test(
      'ignores an out-of-range rig.primaryTrack rather than pushing an '
      'invalid channel to the engine or poisoning the re-apply cache '
      '(a manifest saved on a build with more physical tracks than this '
      'engine)',
      () async {
        engine.nextSnapshot = clearedSnapshot(2);
        final repo = buildRepo()..startEngine(const EngineConfig());
        addTearDown(repo.dispose);

        await repo.applySession(
          SessionRig(
            baseLengthFrames: 4,
            tracks: [
              rigTrack(0, Float32List.fromList([1, 1, 1, 1])),
            ],
            primaryTrack: 7,
          ),
          clearPollInterval: Duration.zero,
        );

        expect(engine.lastCrownedChannel, isNull);
      },
    );

    test(
      "applies the loaded session's looper mode and crown (B5c)",
      () async {
        engine.nextSnapshot = clearedSnapshot(2);
        final repo = buildRepo()..startEngine(const EngineConfig());
        addTearDown(repo.dispose);

        await repo.applySession(
          SessionRig(
            baseLengthFrames: 4,
            tracks: [
              rigTrack(0, Float32List.fromList([1, 1, 1, 1])),
            ],
            looperMode: LooperMode.band,
            primaryTrack: 1,
          ),
          clearPollInterval: Duration.zero,
        );

        expect(engine.lastLooperMode, LooperMode.band);
        expect(engine.lastCrownedChannel, 1);
      },
    );

    test(
      'pushes the looper mode BEFORE any content is imported, so a '
      "content-bearing session's mode is never silently dropped by the D4 "
      'content lock (B5c)',
      () async {
        engine.nextSnapshot = clearedSnapshot(2);
        final repo = buildRepo()..startEngine(const EngineConfig());
        addTearDown(repo.dispose);
        // `startEngine`'s own re-apply cascade (independent review of #295)
        // pushes a `setLooperMode` call of its own BEFORE `applySession` ever
        // runs — leaving it in `engine.calls` would let `indexOf` resolve to
        // that pre-existing call instead of `applySession`'s own, making
        // `modeIndex < importIndex` trivially true regardless of where
        // `applySession` actually places its mode push. Clear it first, like
        // every other test in this file that asserts on `engine.calls` after
        // `startEngine` (e.g. the effects test above).
        engine.calls.clear();

        await repo.applySession(
          SessionRig(
            baseLengthFrames: 4,
            tracks: [
              rigTrack(0, Float32List.fromList([1, 1, 1, 1])),
            ],
            looperMode: LooperMode.sync,
          ),
          clearPollInterval: Duration.zero,
        );

        final modeIndex = engine.calls.indexOf('setLooperMode');
        final importIndex = engine.calls.indexOf('importLayer');
        expect(modeIndex, greaterThanOrEqualTo(0));
        expect(importIndex, greaterThanOrEqualTo(0));
        expect(modeIndex, lessThan(importIndex));
      },
    );

    test(
      'a session load resets the primary-track RE-APPLY CACHE when it '
      'defines no crown, even though the live engine keeps a prior crown '
      '(B5c, D18: no un-crown call exists on the live engine)',
      () async {
        engine.nextSnapshot = clearedSnapshot(2);
        final repo = buildRepo()
          ..startEngine(const EngineConfig())
          // A live/prior session crowned track 1.
          ..crownPrimary(channel: 1);
        addTearDown(repo.dispose);
        expect(engine.lastCrownedChannel, 1);

        // The loaded session defines no crown at all.
        engine.lastCrownedChannel = null;
        await repo.applySession(
          SessionRig(
            baseLengthFrames: 4,
            tracks: [
              rigTrack(0, Float32List.fromList([1, 1, 1, 1])),
            ],
          ),
          clearPollInterval: Duration.zero,
        );

        // No new crownPrimary call was pushed to the LIVE engine — D18's "no
        // un-crown call" means the prior crown is not (and cannot be) undone
        // here. This is the documented limitation, not a bug.
        expect(engine.lastCrownedChannel, isNull);

        // But the re-apply CACHE was reset: a subsequent restart does not
        // resurrect the stale crown.
        repo
          ..stopEngine()
          ..startEngine(const EngineConfig());
        expect(engine.lastCrownedChannel, isNull);
      },
    );

    test(
      'a session load with no crown reports NO primary track to the UI even '
      'when the raw engine snapshot still reflects a prior crown '
      '(independent review of #295, D18 stale-crown leak fix): '
      'TransportState.primaryTrack must project from the reset-aware cache, '
      'not the raw snapshot field the engine can never un-set',
      () async {
        final repo = buildRepo()
          ..startEngine(const EngineConfig())
          // A live/prior session crowned track 1.
          ..crownPrimary(channel: 1);
        addTearDown(repo.dispose);

        // The loaded session defines no crown at all — but, matching D18's
        // "no un-crown call exists", the RAW engine snapshot keeps reporting
        // the prior crown for the rest of this test, exactly like the real
        // native engine would.
        engine.nextSnapshot = const EngineSnapshot(
          isRunning: true,
          sampleRate: 48000,
          bufferFrames: 128,
          framesProcessed: 0,
          xrunCount: 0,
          inputRms: 0,
          inputPeak: 0,
          outputRms: 0,
          latencyState: le.LatencyState.idle,
          measuredLatencyMs: -1,
          tracks: [TrackSnapshot.empty(), TrackSnapshot.empty()],
          primaryTrack: 1,
        );
        await repo.applySession(
          SessionRig(
            baseLengthFrames: 4,
            tracks: [
              rigTrack(0, Float32List.fromList([1, 1, 1, 1])),
            ],
          ),
          clearPollInterval: Duration.zero,
        );

        // The raw snapshot the UI would otherwise read straight off still
        // says 1 — but the projected state must not leak it.
        expect(engine.nextSnapshot.primaryTrack, 1);
        expect(repo.state.transport.primaryTrack, -1);
      },
    );

    test('resets remembered chains the rig does not define — lane and '
        'monitor (F2c)', () async {
      engine.nextSnapshot = clearedSnapshot(2);
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setLaneEffects(
          channel: 0,
          lane: 0,
          effects: [BuiltInEffect(type: TrackEffectType.drive)],
        )
        ..setMonitorEffects(
          input: 1,
          effects: [BuiltInEffect(type: TrackEffectType.reverb)],
        );
      addTearDown(repo.dispose);

      await repo.applySession(
        const SessionRig(),
        clearPollInterval: Duration.zero,
      );

      // Engine chain lengths were explicitly zeroed (leftovers can't sound).
      expect(engine.laneFxCount[(0, 0)], 0);
      expect(engine.monitorFxCount[1], 0);
      expect(repo.laneEffects(0, 0), isEmpty);
      expect(repo.monitorEffects(1), isEmpty);

      // And a restart replays nothing stale.
      engine.laneFx.clear();
      engine.monitorFx.clear();
      repo
        ..stopEngine()
        ..startEngine(const EngineConfig());
      expect(engine.laneFx, isEmpty);
      expect(engine.monitorFx, isEmpty);
    });

    test('resets remembered TRACK-stage and MASTER chains the rig does not '
        'define, chain flags included (R17, the F2 class extended to the bus '
        'stages)', () async {
      engine.nextSnapshot = clearedSnapshot(2);
      // Session A: FX on two track buses and on the Master insert, with one
      // bus chain-DISABLED and the Master chain-disabled too.
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setTrackEffects(
          channel: 0,
          effects: [BuiltInEffect(type: TrackEffectType.drive)],
        )
        ..setTrackChainEnabled(channel: 1, enabled: false)
        ..setMasterEffects(
          effects: [BuiltInEffect(type: TrackEffectType.reverb)],
        )
        ..setMasterChainEnabled(enabled: false);
      addTearDown(repo.dispose);
      expect(engine.trackFxCount[0], 1);
      expect(engine.masterFxCount, 1);

      // Session B defines neither bus stage.
      await repo.applySession(
        const SessionRig(),
        clearPollInterval: Duration.zero,
      );

      // Engine chain lengths zeroed and every chain flag back to enabled.
      expect(engine.trackFxCount[0], 0);
      expect(engine.masterFxCount, 0);
      expect(engine.trackFxChainEnabled[1], isTrue);
      expect(engine.masterFxChainEnabled, isTrue);
      // Repository caches clean.
      expect(repo.trackEffects(0), isEmpty);
      expect(repo.masterEffects, isEmpty);
      expect(repo.trackChainEnabled(0), isTrue);
      expect(repo.trackChainEnabled(1), isTrue);
      expect(repo.masterChainEnabled, isTrue);
      expect(repo.allTrackChains(), isEmpty);

      // And a restart replays nothing stale.
      engine.trackFx.clear();
      engine.masterFx.clear();
      repo
        ..stopEngine()
        ..startEngine(const EngineConfig());
      expect(engine.trackFx, isEmpty);
      expect(engine.masterFx, isEmpty);
    });

    test('applies the rig BUS stages, chain flags included (R17)', () async {
      engine.nextSnapshot = clearedSnapshot(2);
      final repo = buildRepo()..startEngine(const EngineConfig());
      addTearDown(repo.dispose);

      await repo.applySession(
        SessionRig(
          trackChains: {
            0: FxChainEnvelope(
              entries: [BuiltInEffect(type: TrackEffectType.delay)],
            ),
            1: const FxChainEnvelope(chainEnabled: false),
          },
          masterChain: FxChainEnvelope(
            chainEnabled: false,
            entries: [BuiltInEffect(type: TrackEffectType.filter)],
          ),
        ),
        clearPollInterval: Duration.zero,
      );

      expect(engine.trackFx[(0, 0)]?.code, TrackEffectType.delay.code);
      expect(engine.trackFxCount[0], 1);
      expect(engine.trackFxChainEnabled[1], isFalse);
      expect(engine.masterFx[0]?.code, TrackEffectType.filter.code);
      expect(engine.masterFxChainEnabled, isFalse);
      expect(repo.trackChainEnabled(1), isFalse);
      expect(repo.masterChainEnabled, isFalse);

      // The caches are truthful: a restart reproduces the loaded bus chains.
      engine.trackFx.clear();
      engine.masterFx.clear();
      repo
        ..stopEngine()
        ..startEngine(const EngineConfig());
      expect(engine.trackFx[(0, 0)]?.code, TrackEffectType.delay.code);
      expect(engine.masterFx[0]?.code, TrackEffectType.filter.code);
    });

    test('resets a remembered bus chain on a channel this engine cannot own, '
        'even when the rig "defines" it — the bounded apply cannot push it, so '
        'skipping the reset would strand the leftover', () async {
      engine.nextSnapshot = clearedSnapshot(2);
      final repo = buildRepo()..startEngine(const EngineConfig());
      addTearDown(repo.dispose);
      // A chain remembered for a channel beyond this engine's track count —
      // e.g. a cache left by a manifest saved on a build with more tracks.
      repo.setTrackEffects(
        channel: 5,
        effects: [BuiltInEffect(type: TrackEffectType.drive)],
      );
      expect(repo.trackEffects(5), isNotEmpty);

      await repo.applySession(
        SessionRig(
          trackChains: {
            5: FxChainEnvelope(
              entries: [BuiltInEffect(type: TrackEffectType.reverb)],
            ),
          },
        ),
        clearPollInterval: Duration.zero,
      );

      // Not applied (out of range) and therefore reset, not left behind.
      expect(repo.trackEffects(5), isEmpty);
      expect(repo.allTrackChains(), isEmpty);
    });

    test('restores a lane envelope whole — entries, chain flag, and the '
        'inheritance marker (R13/R15)', () async {
      engine.nextSnapshot = clearedSnapshot(2);
      // A leftover disabled flag + marker on a DIFFERENT lane must not survive.
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setLaneChainEnabled(channel: 1, lane: 0, enabled: false)
        ..setLaneChainMeta(channel: 1, lane: 0, inheritedFrom: [7]);
      addTearDown(repo.dispose);

      await repo.applySession(
        SessionRig(
          laneChains: {
            (0, 0): FxChainEnvelope(
              chainEnabled: false,
              meta: const FxChainMeta(inheritedFrom: [2, 3]),
              entries: [BuiltInEffect(type: TrackEffectType.drive)],
            ),
          },
          monitors: const [
            SessionRigMonitor(
              input: 0,
              mode: MonitorMode.on,
              outputMask: 0x3,
              volume: 1,
              muted: false,
              effects: [],
              chainEnabled: false,
            ),
          ],
        ),
        clearPollInterval: Duration.zero,
      );

      expect(repo.laneChainEnabled(0, 0), isFalse);
      expect(repo.laneChainInheritedFrom(0, 0), [2, 3]);
      expect(engine.laneFxChainEnabled[(0, 0)], isFalse);
      // The undefined lane's leftover flag/marker are gone.
      expect(repo.laneChainEnabled(1, 0), isTrue);
      expect(repo.laneChainInheritedFrom(1, 0), isEmpty);
      // A monitor's chain flag restores from its own envelope too.
      expect(repo.monitorChainEnabled(0), isFalse);
      expect(engine.monitorFxChainEnabled[0], isFalse);
    });

    test('fully resets a leftover monitor the rig does not define — routing '
        'and mix, not just its chain (F2)', () async {
      engine.nextSnapshot = clearedSnapshot(2);
      // Session A left input 1 enabled with custom routing / mix.
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setMonitorInputMode(input: 1, mode: MonitorMode.on)
        ..setMonitorOutput(input: 1, mask: 0x4)
        ..setMonitorVolume(input: 1, volume: 0.3)
        ..setMonitorMute(input: 1, muted: true);
      addTearDown(repo.dispose);

      // Session B does not define input 1 at all.
      await repo.applySession(
        const SessionRig(),
        clearPollInterval: Duration.zero,
      );

      // The leftover monitor is fully reset to disabled defaults — an enabled
      // monitor from A can never keep sounding under B.
      expect(repo.monitorMode(1), MonitorMode.off);
      expect(repo.monitorOutput(1), 0x3);
      expect(repo.monitorVolume(1), 1);
      expect(repo.monitorMuted(1), isFalse);
      expect(engine.monitorInputEnabled[1], isFalse);
    });

    test("resets a leftover track's lane count/routing the rig omits — the "
        "engine must not keep session A's lanes for a record", () async {
      engine.nextSnapshot = clearedSnapshot(2);
      // Session A configured track 0 with two lanes recording inputs 3 and 5.
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setLaneCount(channel: 0, count: 2)
        ..setLaneInput(channel: 0, lane: 0, inputChannel: 3)
        ..setLaneInput(channel: 0, lane: 1, inputChannel: 5)
        ..setLaneOutput(channel: 0, lane: 0, mask: 0x4);
      addTearDown(repo.dispose);
      expect(engine.laneCount[0], 2);

      // Session B leaves track 0 empty (defines no track 0). `clear` does not
      // reset the engine's lane_count/routing, so without the countermand a
      // record into track 0 would record 2 lanes on inputs 3+5.
      await repo.applySession(
        const SessionRig(),
        clearPollInterval: Duration.zero,
      );

      // Engine reset to a single fresh lane (lane 0 records input 0 to the
      // first output pair), matching the purged cache — no session-A leftover.
      expect(engine.laneCount[0], 1);
      expect(engine.laneInput[(0, 0)], 0);
      expect(engine.laneOutput[(0, 0)], 0x3);
      expect(repo.laneCount(0), 1);
    });

    test(
      'applies the rig chains and monitors through the cached setters',
      () async {
        engine.nextSnapshot = clearedSnapshot(2);
        final repo = buildRepo()..startEngine(const EngineConfig());
        addTearDown(repo.dispose);

        await repo.applySession(
          SessionRig(
            laneChains: {
              (1, 0): FxChainEnvelope(
                entries: [BuiltInEffect(type: TrackEffectType.delay)],
              ),
            },
            monitors: [
              SessionRigMonitor(
                input: 0,
                mode: MonitorMode.on,
                outputMask: 0x1,
                volume: 0.7,
                muted: false,
                effects: [BuiltInEffect(type: TrackEffectType.reverb)],
              ),
            ],
          ),
          clearPollInterval: Duration.zero,
        );

        expect(engine.laneFx[(1, 0, 0)]?.code, TrackEffectType.delay.code);
        expect(engine.laneFxCount[(1, 0)], 1);
        expect(engine.monitorFx[(0, 0)]?.code, TrackEffectType.reverb.code);
        expect(engine.monitorInputEnabled[0], isTrue);
        expect(engine.monitorOutput[0], 0x1);
        expect(engine.monitorVolume[0], 0.7);
        expect(engine.monitorMute[0], isFalse);

        // The caches are truthful: a restart reproduces the loaded chains.
        engine.laneFx.clear();
        engine.monitorFx.clear();
        repo
          ..stopEngine()
          ..startEngine(const EngineConfig());
        expect(engine.laneFx[(1, 0, 0)]?.code, TrackEffectType.delay.code);
        expect(engine.monitorFx[(0, 0)]?.code, TrackEffectType.reverb.code);
      },
    );

    test(
      'retries an import that races a not-yet-acked clear, then succeeds',
      () async {
        // The engine rejects the first couple of imports (the posted-clear ack
        // race); applySession retries and the import lands rather than failing.
        engine
          ..nextSnapshot = clearedSnapshot(1)
          ..importFailCountdown = 2;
        final repo = buildRepo()..startEngine(const EngineConfig());
        addTearDown(repo.dispose);

        final pcm = Float32List.fromList([1, 1, 1, 1]);
        await repo.applySession(
          SessionRig(baseLengthFrames: 4, tracks: [rigTrack(0, pcm)]),
          clearPollInterval: Duration.zero,
        );

        expect(engine.importFailCountdown, 0); // the retries were consumed
        expect(
          engine.importedTracks[0],
          pcm,
        ); // and the import ultimately landed
      },
    );

    test('throws when the engine never settles to cleared', () async {
      engine.nextSnapshot = _playingSnapshot;
      final repo = buildRepo()..startEngine(const EngineConfig());
      addTearDown(repo.dispose);

      await expectLater(
        repo.applySession(
          const SessionRig(),
          clearPollInterval: Duration.zero,
          clearPollAttempts: 2,
        ),
        throwsStateError,
      );
    });

    test('throws when a stem import is rejected', () async {
      engine
        ..nextSnapshot = clearedSnapshot(1)
        ..importResult = EngineResult.invalid;
      final repo = buildRepo()..startEngine(const EngineConfig());
      addTearDown(repo.dispose);

      await expectLater(
        repo.applySession(
          SessionRig(
            baseLengthFrames: 4,
            tracks: [
              rigTrack(0, Float32List.fromList([1, 1, 1, 1])),
            ],
          ),
          clearPollInterval: Duration.zero,
        ),
        throwsStateError,
      );
    });

    test(
      'imports every lane of a multi-lane track and restores per-lane mix',
      () async {
        engine.nextSnapshot = clearedSnapshot(1);
        final repo = buildRepo()..startEngine(const EngineConfig());
        addTearDown(repo.dispose);

        final lane0 = Float32List.fromList([1, 1, 1, 1]);
        final lane1 = Float32List.fromList([2, 2, 2, 2]);
        await repo.applySession(
          SessionRig(
            baseLengthFrames: 4,
            tracks: [
              SessionRigTrack(
                channel: 0,
                lanes: [
                  SessionRigLane(
                    lane: 0,
                    layers: [lane0],
                    volume: 0.5,
                    muted: false,
                    outputMask: 0x1,
                    inputChannel: 0,
                  ),
                  SessionRigLane(
                    lane: 1,
                    layers: [lane1],
                    volume: 0.25,
                    muted: true,
                    outputMask: 0x2,
                    inputChannel: 1,
                  ),
                ],
              ),
            ],
          ),
          clearPollInterval: Duration.zero,
        );

        expect(engine.importedLanes[(0, 0)], lane0);
        expect(engine.importedLanes[(0, 1)], lane1);
        expect(engine.laneVol[(0, 0)], 0.5);
        expect(engine.laneVol[(0, 1)], 0.25);
        expect(engine.laneMute[(0, 1)], isTrue);
        // Per-lane routing is restored too, not just the mix.
        expect(engine.laneInput[(0, 0)], 0);
        expect(engine.laneInput[(0, 1)], 1);
        expect(engine.laneOutput[(0, 0)], 0x1);
        expect(engine.laneOutput[(0, 1)], 0x2);
        expect(engine.laneCount[0], 2);
        expect(repo.laneCount(0), 2);
      },
    );

    test(
      'imports every overdub layer in order and finalizes the undo/redo stacks',
      () async {
        engine.nextSnapshot = clearedSnapshot(1);
        final repo = buildRepo()..startEngine(const EngineConfig());
        addTearDown(repo.dispose);

        final undo0 = Float32List.fromList([1, 1, 1, 1]);
        final live = Float32List.fromList([2, 2, 2, 2]);
        final redo0 = Float32List.fromList([3, 3, 3, 3]);
        await repo.applySession(
          SessionRig(
            baseLengthFrames: 4,
            tracks: [
              SessionRigTrack(
                channel: 0,
                lanes: [
                  SessionRigLane(
                    lane: 0,
                    layers: [undo0, live, redo0],
                    volume: 1,
                    muted: false,
                    outputMask: 0x3,
                    inputChannel: 0,
                    undoCount: 1,
                    redoCount: 1,
                  ),
                ],
              ),
            ],
          ),
          clearPollInterval: Duration.zero,
        );

        expect(engine.importedLayers[(0, 0, 0)], undo0);
        expect(engine.importedLayers[(0, 0, 1)], live);
        expect(engine.importedLayers[(0, 0, 2)], redo0);
        // The reconstructed stacks are published with the shared depths.
        expect(engine.finalizedLayers[0], (1, 1));
      },
    );
  });

  group('chain and monitor read accessors', () {
    test(
      'allLaneChains and allMonitors expose the remembered chains',
      () {
        final repo = buildRepo()
          ..setLaneEffects(
            channel: 1,
            lane: 2,
            effects: [BuiltInEffect(type: TrackEffectType.drive)],
          )
          ..setMonitorEffects(
            input: 3,
            effects: [BuiltInEffect(type: TrackEffectType.echo)],
          );
        addTearDown(repo.dispose);

        final lanes = repo.allLaneChains();
        expect(lanes.keys, [(1, 2)]);
        expect(
          (lanes[(1, 2)]!.entries.single as BuiltInEffect).type,
          TrackEffectType.drive,
        );
        expect(lanes[(1, 2)]!.chainEnabled, isTrue);
        final monitors = repo.allMonitors();
        expect(monitors.keys, [3]);
        expect(
          (monitors[3]!.effects.single as BuiltInEffect).type,
          TrackEffectType.echo,
        );
      },
    );

    test(
      'allLaneChains enumerates a lane that carries ONLY a disabled chain '
      'flag or an inheritance marker — state a chain-keyed enumeration would '
      'silently drop on save',
      () {
        final repo = buildRepo()
          ..setLaneChainEnabled(channel: 0, lane: 1, enabled: false)
          ..setLaneChainMeta(channel: 2, lane: 0, inheritedFrom: [3]);
        addTearDown(repo.dispose);

        final lanes = repo.allLaneChains();
        expect(lanes.keys.toSet(), {(0, 1), (2, 0)});
        expect(lanes[(0, 1)]!.chainEnabled, isFalse);
        expect(lanes[(0, 1)]!.entries, isEmpty);
        expect(lanes[(2, 0)]!.meta?.inheritedFrom, [3]);
      },
    );

    test(
      'allTrackChains and masterChainEnvelope expose the remembered bus '
      'stages, flag-only channels included',
      () {
        final repo = buildRepo()
          ..setTrackEffects(
            channel: 1,
            effects: [BuiltInEffect(type: TrackEffectType.reverb)],
          )
          ..setTrackChainEnabled(channel: 2, enabled: false)
          ..setMasterEffects(
            effects: [BuiltInEffect(type: TrackEffectType.filter)],
          )
          ..setMasterChainEnabled(enabled: false);
        addTearDown(repo.dispose);

        final tracks = repo.allTrackChains();
        expect(tracks.keys.toSet(), {1, 2});
        expect(
          (tracks[1]!.entries.single as BuiltInEffect).type,
          TrackEffectType.reverb,
        );
        expect(tracks[1]!.chainEnabled, isTrue);
        expect(tracks[2]!.entries, isEmpty);
        expect(tracks[2]!.chainEnabled, isFalse);

        final master = repo.masterChainEnvelope();
        expect(
          (master.entries.single as BuiltInEffect).type,
          TrackEffectType.filter,
        );
        expect(master.chainEnabled, isFalse);
      },
    );

    test('masterChainEnvelope reads as the empty enabled envelope when no '
        'Master chain is configured', () {
      final repo = buildRepo();
      addTearDown(repo.dispose);

      expect(repo.masterChainEnvelope(), const FxChainEnvelope());
    });

    test('allMonitors captures an enabled DRY monitor (no FX chain)', () {
      // The regression that dropped dry monitors on save: an enabled input with
      // an empty chain must still be enumerated so it round-trips through a
      // session save/load.
      final repo = buildRepo()
        ..setMonitorInputMode(input: 2, mode: MonitorMode.on)
        ..setMonitorOutput(input: 2, mask: 0x2);
      addTearDown(repo.dispose);

      final monitors = repo.allMonitors();
      expect(monitors.keys, [2]);
      expect(monitors[2]!.mode, MonitorMode.on);
      expect(monitors[2]!.outputMask, 0x2);
      expect(monitors[2]!.effects, isEmpty);
    });

    test('allMonitors omits inputs equal to the disabled default', () {
      // Touching a monitor back to the default (or a no-op setter) leaves no
      // meaningful state, so it must not bloat the enumeration / bundle.
      final repo = buildRepo()
        ..setMonitorInputMode(input: 1, mode: MonitorMode.on)
        ..setMonitorInputMode(input: 1, mode: MonitorMode.off)
        ..setMonitorOutput(input: 1, mask: 0x3) // the default mask
        ..setMonitorVolume(input: 1, volume: 1) // unity (default)
        ..setMonitorMute(input: 1, muted: false); // default
      addTearDown(repo.dispose);

      expect(repo.allMonitors(), isEmpty);
    });

    test('allMonitors captures volume / mute / output-varied monitors', () {
      final repo = buildRepo()
        ..setMonitorVolume(input: 0, volume: 0.4)
        ..setMonitorMute(input: 1, muted: true)
        ..setMonitorOutput(input: 2, mask: 0x1);
      addTearDown(repo.dispose);

      final monitors = repo.allMonitors();
      expect(monitors.keys.toSet(), {0, 1, 2});
      expect(monitors[0]!.volume, closeTo(0.4, 1e-6));
      expect(monitors[1]!.muted, isTrue);
      expect(monitors[2]!.outputMask, 0x1);
    });

    test(
      'monitor config getters read the remembered intent (with defaults)',
      () {
        final repo = buildRepo();
        addTearDown(repo.dispose);

        expect(repo.monitorMode(0), MonitorMode.off);
        expect(repo.monitorOutput(0), 0x3);
        expect(repo.monitorVolume(0), 1);
        expect(repo.monitorMuted(0), isFalse);

        repo
          ..setMonitorInputMode(input: 0, mode: MonitorMode.on)
          ..setMonitorOutput(input: 0, mask: 0x1)
          ..setMonitorVolume(input: 0, volume: 0.4)
          ..setMonitorMute(input: 0, muted: true);

        expect(repo.monitorMode(0), MonitorMode.on);
        expect(repo.monitorOutput(0), 0x1);
        expect(repo.monitorVolume(0), 0.4);
        expect(repo.monitorMuted(0), isTrue);
      },
    );
  });

  group('reconnect supervisor', () {
    late StreamController<void> reconnectTicker;

    setUp(() => reconnectTicker = StreamController<void>.broadcast());
    tearDown(() => reconnectTicker.close());

    LooperRepository buildSupervised() => LooperRepository(
      engine: engine,
      ticker: ticker.stream,
      reconnectTicker: reconnectTicker.stream,
    );

    EngineSnapshot runningSnapshot({required bool devicePresent}) =>
        EngineSnapshot(
          isRunning: true,
          devicePresent: devicePresent,
          sampleRate: 48000,
          bufferFrames: 128,
          framesProcessed: 0,
          xrunCount: 0,
          inputRms: 0,
          inputPeak: 0,
          outputRms: 0,
          latencyState: le.LatencyState.idle,
          measuredLatencyMs: -1,
        );

    const pinned = le.AudioDevice(
      id: 'out-1',
      name: 'Scarlett 2i2',
      isDefault: false,
      isInput: false,
    );
    const captureDevice = le.AudioDevice(
      id: 'in-1',
      name: 'Built-in Mic',
      isDefault: false,
      isInput: true,
    );
    const otherDevice = le.AudioDevice(
      id: 'out-2',
      name: 'Headphones',
      isDefault: false,
      isInput: false,
    );

    int startCount() => engine.calls.where((c) => c == 'start').length;
    int stopCount() => engine.calls.where((c) => c == 'stop').length;

    test('reopens a pinned device when it reappears', () async {
      engine.nextSnapshot = runningSnapshot(devicePresent: true);
      final repo = buildSupervised()
        ..startEngine(const EngineConfig(playbackDeviceId: 'out-1'));
      expect(startCount(), 1);

      final sub = repo.looperState.listen((_) {});
      addTearDown(sub.cancel);
      await Future<void>.delayed(Duration.zero);

      // Device is lost: snapshot reports present == false.
      engine.nextSnapshot = runningSnapshot(devicePresent: false);
      ticker.add(null);
      await Future<void>.delayed(Duration.zero);

      // Still absent from enumeration → no restart yet.
      engine.devices = const [];
      reconnectTicker.add(null);
      await Future<void>.delayed(Duration.zero);
      expect(startCount(), 1);

      // Reappears → stop + restart on the same device.
      engine.devices = const [pinned];
      reconnectTicker.add(null);
      await Future<void>.delayed(Duration.zero);

      expect(engine.calls, containsAllInOrder(<String>['stop', 'start']));
      expect(startCount(), 2);
      expect(engine.lastConfig?.playbackDeviceId, 'out-1');
    });

    test(
      'a reconnect re-applies the remembered rig (lanes + monitors)',
      () async {
        engine.nextSnapshot = runningSnapshot(devicePresent: true);
        final repo = buildSupervised()
          ..startEngine(const EngineConfig(playbackDeviceId: 'out-1'))
          // Stage some live rig state: a monitor enable + a lane routing.
          ..setMonitorInputMode(input: 0, mode: MonitorMode.on)
          ..setLaneOutput(channel: 0, lane: 0, mask: 0x2);
        final sub = repo.looperState.listen((_) {});
        addTearDown(sub.cancel);
        await Future<void>.delayed(Duration.zero);

        final monitorReapplyBefore = engine.calls
            .where((c) => c == 'setMonitorInputEnabled')
            .length;
        final laneReapplyBefore = engine.calls
            .where((c) => c == 'setLaneOutput')
            .length;

        // Device lost, then reappears → reconnect.
        engine.nextSnapshot = runningSnapshot(devicePresent: false);
        ticker.add(null);
        await Future<void>.delayed(Duration.zero);
        engine.devices = const [pinned];
        reconnectTicker.add(null);
        await Future<void>.delayed(Duration.zero);

        expect(startCount(), 2); // reconnected
        // The reconnect went through startEngine, so the freshly-started engine
        // received the remembered rig again — it did not come back at defaults.
        expect(
          engine.calls.where((c) => c == 'setMonitorInputEnabled').length,
          greaterThan(monitorReapplyBefore),
        );
        expect(
          engine.calls.where((c) => c == 'setLaneOutput').length,
          greaterThan(laneReapplyBefore),
        );
      },
    );

    test('never restarts the system default on transient loss', () async {
      engine.nextSnapshot = runningSnapshot(devicePresent: true);
      final repo = buildSupervised()
        ..startEngine(const EngineConfig()); // empty device id = default
      final sub = repo.looperState.listen((_) {});
      addTearDown(sub.cancel);
      await Future<void>.delayed(Duration.zero);

      engine.nextSnapshot = runningSnapshot(devicePresent: false);
      ticker.add(null);
      await Future<void>.delayed(Duration.zero);

      // Even though the device "reappears", a default config is never pinned.
      engine.devices = const [pinned];
      reconnectTicker.add(null);
      await Future<void>.delayed(Duration.zero);

      expect(startCount(), 1);
      expect(engine.calls, isNot(contains('stop')));
    });

    test('a deliberate stop cancels reconnection', () async {
      engine.nextSnapshot = runningSnapshot(devicePresent: true);
      final repo = buildSupervised()
        ..startEngine(const EngineConfig(playbackDeviceId: 'out-1'));
      final sub = repo.looperState.listen((_) {});
      addTearDown(sub.cancel);
      await Future<void>.delayed(Duration.zero);

      engine.nextSnapshot = runningSnapshot(devicePresent: false);
      ticker.add(null);
      await Future<void>.delayed(Duration.zero);

      repo.stopEngine();
      final startsAfterStop = startCount();

      // The device reappears, but the user stopped — no auto-restart.
      engine.devices = const [pinned];
      reconnectTicker.add(null);
      await Future<void>.delayed(Duration.zero);

      expect(startCount(), startsAfterStop);
    });

    test('devicePresent is projected onto EngineStatus', () {
      engine.nextSnapshot = runningSnapshot(devicePresent: true);
      expect(buildSupervised().state.status.devicePresent, isTrue);
      engine.nextSnapshot = runningSnapshot(devicePresent: false);
      expect(buildSupervised().state.status.devicePresent, isFalse);
    });

    test('reopens a pinned capture device when it reappears', () async {
      engine.nextSnapshot = runningSnapshot(devicePresent: true);
      final repo = buildSupervised()
        ..startEngine(const EngineConfig(captureDeviceId: 'in-1'));
      final sub = repo.looperState.listen((_) {});
      addTearDown(sub.cancel);
      await Future<void>.delayed(Duration.zero);

      engine.nextSnapshot = runningSnapshot(devicePresent: false);
      ticker.add(null);
      await Future<void>.delayed(Duration.zero);

      // A playback device alone does not satisfy a pinned capture device.
      engine.devices = const [pinned];
      reconnectTicker.add(null);
      await Future<void>.delayed(Duration.zero);
      expect(startCount(), 1);

      // The capture device returns → reopen.
      engine.devices = const [pinned, captureDevice];
      reconnectTicker.add(null);
      await Future<void>.delayed(Duration.zero);
      expect(startCount(), 2);
      expect(engine.lastConfig?.captureDeviceId, 'in-1');
    });

    test(
      'does not retry a failed restart until the device list changes',
      () async {
        engine.nextSnapshot = runningSnapshot(devicePresent: true);
        final repo = buildSupervised()
          ..startEngine(const EngineConfig(playbackDeviceId: 'out-1'));
        final sub = repo.looperState.listen((_) {});
        addTearDown(sub.cancel);
        await Future<void>.delayed(Duration.zero);

        engine.nextSnapshot = runningSnapshot(devicePresent: false);
        ticker.add(null);
        await Future<void>.delayed(Duration.zero);

        // Device present, but the engine refuses to open it.
        engine
          ..devices = const [pinned]
          ..startResult = EngineResult.device;
        reconnectTicker.add(null);
        await Future<void>.delayed(Duration.zero);
        final stopsAfterFirst = stopCount();
        final startsAfterFirst = startCount();
        expect(startsAfterFirst, 2); // one failed reopen attempt

        // Same device list → no further thrash.
        reconnectTicker.add(null);
        await Future<void>.delayed(Duration.zero);
        expect(stopCount(), stopsAfterFirst);
        expect(startCount(), startsAfterFirst);

        // The list changes (a re-plug) → retry, and this time it succeeds.
        engine
          ..startResult = EngineResult.ok
          ..devices = const [pinned, otherDevice];
        reconnectTicker.add(null);
        await Future<void>.delayed(Duration.zero);
        expect(startCount(), startsAfterFirst + 1);
      },
    );

    test('devices() forwards to the engine enumeration, mapped to domain', () {
      engine.devices = const [pinned];
      final repo = buildSupervised();
      // The repository maps engine AudioDevice -> domain AudioDevice.
      expect(repo.devices(), const [
        AudioDevice(
          id: 'out-1',
          name: 'Scarlett 2i2',
          isDefault: false,
          isInput: false,
        ),
      ]);
      expect(engine.calls, contains('enumerateDevices'));
    });
  });

  group('dispose', () {
    test('disposes the engine and closes the stream', () async {
      final repo = buildRepo();
      await repo.dispose();
      expect(engine.calls, contains('dispose'));
    });
  });

  group('pluginCatalog', () {
    test('exposes a lazily-built, stable catalog over the engine', () {
      final repo = buildRepo();
      final catalog = repo.pluginCatalog;
      expect(catalog, isA<PluginCatalog>());
      // Lazy + cached: the same instance every read.
      expect(repo.pluginCatalog, same(catalog));
    });
  });

  group('engine factories', () {
    test('createMockEngine builds a mock + its deterministic start config', () {
      final mock = createMockEngine();

      // The start config mirrors the mock's defaults (and value-equality
      // exercises the domain EngineConfig props).
      expect(
        mock.startConfig,
        const EngineConfig(
          sampleRate: 48000,
          bufferFrames: 128,
          inputChannels: 18,
          outputChannels: 20,
          playbackDeviceId: 'mock-interface',
          captureDeviceId: 'mock-interface',
        ),
      );
      // The engine drives a repository that comes up on the mock config.
      final repo = LooperRepository(
        engine: mock.engine,
        ticker: const Stream<void>.empty(),
      );
      addTearDown(repo.dispose);
      expect(repo.startEngine(mock.startConfig).isOk, isTrue);
    });
  });

  group('slotId minting at the repository write boundary (A9)', () {
    test('setLaneEffects mints ids for id-less entries exactly once', () {
      final repo = buildRepo()..startEngine(const EngineConfig());
      addTearDown(repo.dispose);

      repo.setLaneEffects(
        channel: 0,
        lane: 0,
        effects: [BuiltInEffect(type: TrackEffectType.drive)],
      );
      final minted = repo.laneEffects(0, 0).single.slotId;
      expect(minted, isNotNull);

      // Re-setting the same (already-minted) chain keeps the id — mint once.
      repo.setLaneEffects(channel: 0, lane: 0, effects: repo.laneEffects(0, 0));
      expect(repo.laneEffects(0, 0).single.slotId, minted);
    });

    test('ids are unique across entries, chains, and stages', () {
      final repo = buildRepo()..startEngine(const EngineConfig());
      addTearDown(repo.dispose);

      repo
        ..setLaneEffects(
          channel: 0,
          lane: 0,
          effects: [
            BuiltInEffect(type: TrackEffectType.drive),
            BuiltInEffect(type: TrackEffectType.delay),
          ],
        )
        ..setMonitorEffects(
          input: 0,
          effects: [BuiltInEffect(type: TrackEffectType.echo)],
        )
        ..setTrackEffects(
          channel: 0,
          effects: [BuiltInEffect(type: TrackEffectType.filter)],
        )
        ..setMasterEffects(
          effects: [BuiltInEffect(type: TrackEffectType.reverb)],
        );

      final ids = [
        ...repo.laneEffects(0, 0).map((e) => e.slotId),
        repo.monitorEffects(0).single.slotId,
        repo.trackEffects(0).single.slotId,
        repo.masterEffects.single.slotId,
      ];
      expect(ids.every((id) => id != null), isTrue);
      expect(ids.toSet(), hasLength(ids.length));
    });

    test('ids survive param edits and reorders', () {
      final repo = buildRepo()..startEngine(const EngineConfig());
      addTearDown(repo.dispose);

      repo.setLaneEffects(
        channel: 0,
        lane: 0,
        effects: [
          BuiltInEffect(type: TrackEffectType.drive),
          BuiltInEffect(type: TrackEffectType.delay),
        ],
      );
      final before = repo.laneEffects(0, 0).map((e) => e.slotId).toList();

      repo.setLaneEffectParam(
        channel: 0,
        lane: 0,
        index: 0,
        param: 0,
        value: 0.9,
      );
      expect(repo.laneEffects(0, 0).map((e) => e.slotId), before);

      // A reorder re-set through the boundary keeps each entry's id.
      repo.setLaneEffects(
        channel: 0,
        lane: 0,
        effects: repo.laneEffects(0, 0).reversed.toList(),
      );
      expect(repo.laneEffects(0, 0).map((e) => e.slotId), before.reversed);
    });
  });

  group('four-stage chains: track + master setters (FX v3 part 3a)', () {
    test('setTrackEffects updates cache and pushes type/params/enabled/count '
        'to the engine bus stage', () {
      final repo = buildRepo()..startEngine(const EngineConfig());
      addTearDown(repo.dispose);

      repo.setTrackEffects(
        channel: 1,
        effects: [
          BuiltInEffect(
            type: TrackEffectType.delay,
            params: const [0.3, 0.4, 0.5, 0],
          ),
          BuiltInEffect(type: TrackEffectType.reverb, enabled: false),
        ],
      );

      expect(repo.trackEffects(1), hasLength(2));
      expect(engine.trackFx[(1, 0)]?.name, 'delay');
      expect(engine.trackFx[(1, 1)]?.name, 'reverb');
      expect(engine.trackFxParam[(1, 0, 0)], 0.3);
      // The per-slot enabled bit is pushed for EVERY slot on every apply.
      expect(engine.trackFxEnabled[(1, 0)], isTrue);
      expect(engine.trackFxEnabled[(1, 1)], isFalse);
      expect(engine.trackFxCount[1], 2);
    });

    test('setMasterEffects updates cache and pushes the Master insert', () {
      final repo = buildRepo()..startEngine(const EngineConfig());
      addTearDown(repo.dispose);

      repo.setMasterEffects(
        effects: [BuiltInEffect(type: TrackEffectType.echo, enabled: false)],
      );

      expect(repo.masterEffects, hasLength(1));
      expect(engine.masterFx[0]?.name, 'echo');
      expect(engine.masterFxEnabled[0], isFalse);
      expect(engine.masterFxCount, 1);
    });

    test('a hosted plugin at a bus stage publishes as passthrough (no bus '
        'slot ABI yet) and is MARKED unsupported in the domain chain', () {
      final repo = buildRepo()..startEngine(const EngineConfig());
      addTearDown(repo.dispose);

      repo
        ..setTrackEffects(
          channel: 0,
          effects: const [
            PluginEffect(
              ref: PluginRef(format: PluginFormat.clap, id: 'p'),
            ),
          ],
        )
        ..setMasterEffects(
          effects: const [
            PluginEffect(
              ref: PluginRef(format: PluginFormat.vst3, id: 'q'),
            ),
          ],
        );

      // Kept, never dropped — but flagged with the D-MISS placeholder posture
      // so it cannot read as an active slot while the engine renders `none`.
      final trackPlugin = repo.trackEffects(0).single as PluginEffect;
      expect(trackPlugin.unavailable, isTrue);
      expect(trackPlugin.unsupported, isTrue);
      expect(trackPlugin.ref.id, 'p');
      final masterPlugin = repo.masterEffects.single as PluginEffect;
      expect(masterPlugin.unavailable, isTrue);
      expect(masterPlugin.unsupported, isTrue);
      expect(engine.trackFx[(0, 0)]?.name, 'none');
      expect(engine.trackFxCount[0], 1);
      expect(engine.masterFx[0]?.name, 'none');
    });

    test('track/master chains and flags are projected onto LooperState', () {
      engine.nextSnapshot = _playingSnapshot;
      final repo = buildRepo()..startEngine(const EngineConfig());
      addTearDown(repo.dispose);

      repo
        ..setTrackEffects(
          channel: 0,
          effects: [BuiltInEffect(type: TrackEffectType.drive)],
        )
        ..setTrackChainEnabled(channel: 0, enabled: false)
        ..setMasterEffects(
          effects: [BuiltInEffect(type: TrackEffectType.reverb)],
        )
        ..setMasterChainEnabled(enabled: false);

      final state = repo.state;
      expect(state.tracks.first.effects, hasLength(1));
      expect(state.tracks.first.chainEnabled, isFalse);
      expect(state.masterEffects, hasLength(1));
      expect(state.masterChainEnabled, isFalse);
    });
  });

  group('per-slot + per-chain enable setters (R15/R16)', () {
    test('per-slot setters update cache + engine together on all four '
        'stages', () {
      final repo = buildRepo()..startEngine(const EngineConfig());
      addTearDown(repo.dispose);

      repo
        ..setLaneEffects(
          channel: 0,
          lane: 0,
          effects: [BuiltInEffect(type: TrackEffectType.drive)],
        )
        ..setMonitorEffects(
          input: 2,
          effects: [BuiltInEffect(type: TrackEffectType.delay)],
        )
        ..setTrackEffects(
          channel: 1,
          effects: [BuiltInEffect(type: TrackEffectType.echo)],
        )
        ..setMasterEffects(
          effects: [BuiltInEffect(type: TrackEffectType.reverb)],
        );

      expect(
        repo.setLaneEffectEnabled(
          channel: 0,
          lane: 0,
          index: 0,
          enabled: false,
        ),
        EngineResult.ok,
      );
      expect(
        repo.setMonitorEffectEnabled(input: 2, index: 0, enabled: false),
        EngineResult.ok,
      );
      expect(
        repo.setTrackEffectEnabled(channel: 1, index: 0, enabled: false),
        EngineResult.ok,
      );
      expect(
        repo.setMasterEffectEnabled(index: 0, enabled: false),
        EngineResult.ok,
      );

      // Cache side.
      expect(repo.laneEffects(0, 0).single.enabled, isFalse);
      expect(repo.monitorEffects(2).single.enabled, isFalse);
      expect(repo.trackEffects(1).single.enabled, isFalse);
      expect(repo.masterEffects.single.enabled, isFalse);
      // Engine side.
      expect(engine.laneFxEnabled[(0, 0, 0)], isFalse);
      expect(engine.monitorFxEnabled[(2, 0)], isFalse);
      expect(engine.trackFxEnabled[(1, 0)], isFalse);
      expect(engine.masterFxEnabled[0], isFalse);
    });

    test('per-slot setters reject an out-of-range index', () {
      final repo = buildRepo()..startEngine(const EngineConfig());
      addTearDown(repo.dispose);

      expect(
        repo.setLaneEffectEnabled(
          channel: 0,
          lane: 0,
          index: 0,
          enabled: false,
        ),
        EngineResult.invalid,
      );
      expect(
        repo.setMasterEffectEnabled(index: 3, enabled: false),
        EngineResult.invalid,
      );
    });

    test('enabled setters work while STOPPED on ALL FOUR stages — the flag '
        'lands on the engine immediately, no ring', () {
      // Never started: the direct-atomic bindings must still be called.
      final repo = buildRepo();
      addTearDown(repo.dispose);

      repo
        ..setLaneEffects(
          channel: 0,
          lane: 0,
          effects: [BuiltInEffect(type: TrackEffectType.drive)],
        )
        ..setMonitorEffects(
          input: 1,
          effects: [BuiltInEffect(type: TrackEffectType.delay)],
        )
        ..setTrackEffects(
          channel: 0,
          effects: [BuiltInEffect(type: TrackEffectType.echo)],
        )
        ..setMasterEffects(
          effects: [BuiltInEffect(type: TrackEffectType.reverb)],
        )
        ..setLaneEffectEnabled(channel: 0, lane: 0, index: 0, enabled: false)
        ..setMonitorEffectEnabled(input: 1, index: 0, enabled: false)
        ..setTrackEffectEnabled(channel: 0, index: 0, enabled: false)
        ..setMasterEffectEnabled(index: 0, enabled: false)
        ..setLaneChainEnabled(channel: 0, lane: 0, enabled: false)
        ..setMonitorChainEnabled(input: 1, enabled: false)
        ..setTrackChainEnabled(channel: 0, enabled: false)
        ..setMasterChainEnabled(enabled: false);

      expect(engine.laneFxEnabled[(0, 0, 0)], isFalse);
      expect(engine.monitorFxEnabled[(1, 0)], isFalse);
      expect(engine.trackFxEnabled[(0, 0)], isFalse);
      expect(engine.masterFxEnabled[0], isFalse);
      expect(engine.laneFxChainEnabled[(0, 0)], isFalse);
      expect(engine.monitorFxChainEnabled[1], isFalse);
      expect(engine.trackFxChainEnabled[0], isFalse);
      expect(engine.masterFxChainEnabled, isFalse);
    });

    test('per-chain setters update the remembered flag + engine on all four '
        'stages', () {
      final repo = buildRepo()..startEngine(const EngineConfig());
      addTearDown(repo.dispose);

      repo
        ..setLaneChainEnabled(channel: 0, lane: 1, enabled: false)
        ..setMonitorChainEnabled(input: 3, enabled: false)
        ..setTrackChainEnabled(channel: 2, enabled: false)
        ..setMasterChainEnabled(enabled: false);

      expect(repo.laneChainEnabled(0, 1), isFalse);
      expect(repo.monitorChainEnabled(3), isFalse);
      expect(repo.trackChainEnabled(2), isFalse);
      expect(repo.masterChainEnabled, isFalse);
      expect(engine.laneFxChainEnabled[(0, 1)], isFalse);
      expect(engine.monitorFxChainEnabled[3], isFalse);
      expect(engine.trackFxChainEnabled[2], isFalse);
      expect(engine.masterFxChainEnabled, isFalse);

      // Flags default to enabled and re-enable restores the default.
      repo.setLaneChainEnabled(channel: 0, lane: 1, enabled: true);
      expect(repo.laneChainEnabled(0, 1), isTrue);
      expect(repo.laneChainEnabled(5, 5), isTrue); // never-set default
    });

    test('a chain apply re-pushes EVERY slot enabled bit so index-keyed '
        'engine flags can never migrate onto the wrong effect (R16)', () {
      final repo = buildRepo()..startEngine(const EngineConfig());
      addTearDown(repo.dispose);

      final drive = BuiltInEffect(type: TrackEffectType.drive);
      final delay = BuiltInEffect(type: TrackEffectType.delay, enabled: false);
      repo.setLaneEffects(channel: 0, lane: 0, effects: [drive, delay]);
      expect(engine.laneFxEnabled[(0, 0, 0)], isTrue);
      expect(engine.laneFxEnabled[(0, 0, 1)], isFalse);

      // Reorder: the disabled DELAY moves to index 0. Every index is
      // re-pushed from the domain chain, so the flags follow the effects.
      repo.setLaneEffects(
        channel: 0,
        lane: 0,
        effects: repo.laneEffects(0, 0).reversed.toList(),
      );
      expect(engine.laneFxEnabled[(0, 0, 0)], isFalse);
      expect(engine.laneFxEnabled[(0, 0, 1)], isTrue);
    });
  });

  group('four-stage fingerprints (R16)', () {
    test('track/master fingerprints fold the cached chain + flags', () {
      final repo = buildRepo()..startEngine(const EngineConfig());
      addTearDown(repo.dispose);

      expect(repo.trackFxChainFingerprint(0), FxFingerprint.offset);
      expect(repo.masterFxChainFingerprint(), FxFingerprint.offset);

      repo.setTrackEffects(
        channel: 0,
        effects: [BuiltInEffect(type: TrackEffectType.drive)],
      );
      final enabled = repo.trackFxChainFingerprint(0);
      expect(enabled, isNot(FxFingerprint.offset));

      repo.setTrackChainEnabled(channel: 0, enabled: false);
      expect(repo.trackFxChainFingerprint(0), isNot(enabled));
    });

    test('lane/monitor fingerprints reflect per-slot and chain flags', () {
      final repo = buildRepo()..startEngine(const EngineConfig());
      addTearDown(repo.dispose);

      repo.setLaneEffects(
        channel: 0,
        lane: 0,
        effects: [BuiltInEffect(type: TrackEffectType.drive)],
      );
      final base = repo.laneChainFingerprint(0, 0);

      repo.setLaneEffectEnabled(channel: 0, lane: 0, index: 0, enabled: false);
      final slotOff = repo.laneChainFingerprint(0, 0);
      expect(slotOff, isNot(base));

      repo.setLaneEffectEnabled(channel: 0, lane: 0, index: 0, enabled: true);
      expect(repo.laneChainFingerprint(0, 0), base); // toggle round-trip

      repo.setLaneChainEnabled(channel: 0, lane: 0, enabled: false);
      expect(repo.laneChainFingerprint(0, 0), isNot(base));
    });
  });

  group('re-apply on restart: four-stage chains + flags', () {
    test('a restart replays track/master chains and every stage chain '
        'flag', () {
      final repo = buildRepo()..startEngine(const EngineConfig());
      addTearDown(repo.dispose);

      repo
        ..setTrackEffects(
          channel: 0,
          effects: [BuiltInEffect(type: TrackEffectType.delay)],
        )
        ..setMasterEffects(
          effects: [BuiltInEffect(type: TrackEffectType.reverb)],
        )
        ..setLaneChainEnabled(channel: 0, lane: 0, enabled: false)
        ..setMonitorChainEnabled(input: 1, enabled: false)
        ..setTrackChainEnabled(channel: 0, enabled: false)
        ..setMasterChainEnabled(enabled: false)
        ..stopEngine();

      // Wipe the fake's records so only the restart replay repopulates them.
      engine.trackFx.clear();
      engine.trackFxCount.clear();
      engine.masterFx.clear();
      engine.masterFxCount = null;
      engine.laneFxChainEnabled.clear();
      engine.monitorFxChainEnabled.clear();
      engine.trackFxChainEnabled.clear();
      engine.masterFxChainEnabled = null;

      repo.startEngine(const EngineConfig());

      expect(engine.trackFx[(0, 0)]?.name, 'delay');
      expect(engine.trackFxCount[0], 1);
      expect(engine.masterFx[0]?.name, 'reverb');
      expect(engine.masterFxCount, 1);
      expect(engine.laneFxChainEnabled[(0, 0)], isFalse);
      expect(engine.monitorFxChainEnabled[1], isFalse);
      expect(engine.trackFxChainEnabled[0], isFalse);
      expect(engine.masterFxChainEnabled, isFalse);
    });
  });

  group('bus-stage granular params', () {
    test('a track param write pokes the one param, not the whole chain', () {
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setTrackEffects(
          channel: 0,
          effects: [
            BuiltInEffect(type: TrackEffectType.reverb),
            BuiltInEffect(type: TrackEffectType.delay),
          ],
        );
      addTearDown(repo.dispose);
      engine.calls.clear();

      expect(
        repo.setTrackEffectParam(
          channel: 0,
          index: 1,
          param: 0,
          value: 0.75,
        ),
        EngineResult.ok,
      );

      // Re-pushing the chain would re-send every slot's TYPE, and the engine
      // resets a slot's DSP state on every type push — the audible cost this
      // setter exists to avoid.
      expect(engine.calls, contains('setTrackFxParam'));
      expect(engine.calls, isNot(contains('setTrackFx')));
      expect(
        (repo.trackEffects(0)[1] as BuiltInEffect).params[0],
        0.75,
      );
      // The untouched sibling keeps its params.
      expect(
        (repo.trackEffects(0)[0] as BuiltInEffect).params,
        BuiltInEffect(type: TrackEffectType.reverb).params,
      );
    });

    test('a master param write behaves the same', () {
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setMasterEffects(
          effects: [BuiltInEffect(type: TrackEffectType.delay)],
        );
      addTearDown(repo.dispose);
      engine.calls.clear();

      expect(
        repo.setMasterEffectParam(index: 0, param: 0, value: 0.4),
        EngineResult.ok,
      );

      expect(engine.calls, contains('setMasterFxParam'));
      expect(engine.calls, isNot(contains('setMasterFx')));
      expect((repo.masterEffects.single as BuiltInEffect).params[0], 0.4);
    });

    test('an out-of-range bus param write is rejected', () {
      final repo = buildRepo()..startEngine(const EngineConfig());
      addTearDown(repo.dispose);

      expect(
        repo.setTrackEffectParam(channel: 0, index: 0, param: 0, value: 1),
        EngineResult.invalid,
      );
      expect(
        repo.setMasterEffectParam(index: 4, param: 0, value: 1),
        EngineResult.invalid,
      );
    });

    test('a track PLUGIN param write remembers the value and pushes no '
        'chain', () {
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setTrackEffects(
          channel: 0,
          effects: [
            BuiltInEffect(type: TrackEffectType.reverb),
            const PluginEffect(
              ref: PluginRef(format: PluginFormat.vst3, id: 'p'),
            ),
          ],
        );
      addTearDown(repo.dispose);
      engine.calls.clear();

      expect(
        repo.setTrackPluginParam(
          channel: 0,
          index: 1,
          paramId: 42,
          value: 0.3,
        ),
        EngineResult.ok,
      );

      // No slot type re-push, so the reverb sharing the bus keeps its tail...
      expect(engine.calls, isNot(contains('setTrackFx')));
      // ...and a bus plugin has no live slot, so nothing reaches the RT queue.
      expect(engine.pluginParamSets, isEmpty);
      // The value is remembered against the day a bus slot ABI lands.
      expect(
        (repo.trackEffects(0)[1] as PluginEffect).paramValues[42],
        0.3,
      );
    });

    test('a master PLUGIN param write behaves the same', () {
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setMasterEffects(
          effects: const [
            PluginEffect(
              ref: PluginRef(format: PluginFormat.clap, id: 'm'),
            ),
          ],
        );
      addTearDown(repo.dispose);
      engine.calls.clear();

      expect(
        repo.setMasterPluginParam(index: 0, paramId: 7, value: 0.9),
        EngineResult.ok,
      );

      expect(engine.calls, isNot(contains('setMasterFx')));
      expect(engine.pluginParamSets, isEmpty);
      expect((repo.masterEffects.single as PluginEffect).paramValues[7], 0.9);
    });

    test('a bus plugin param write on a built-in entry is rejected', () {
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setTrackEffects(
          channel: 0,
          effects: [BuiltInEffect(type: TrackEffectType.drive)],
        )
        ..setMasterEffects(
          effects: [BuiltInEffect(type: TrackEffectType.drive)],
        );
      addTearDown(repo.dispose);

      expect(
        repo.setTrackPluginParam(
          channel: 0,
          index: 0,
          paramId: 1,
          value: 0.5,
        ),
        EngineResult.invalid,
      );
      expect(
        repo.setMasterPluginParam(index: 0, paramId: 1, value: 0.5),
        EngineResult.invalid,
      );
      // ...and an out-of-range index too.
      expect(
        repo.setTrackPluginParam(
          channel: 0,
          index: 9,
          paramId: 1,
          value: 0.5,
        ),
        EngineResult.invalid,
      );
      expect(
        repo.setMasterPluginParam(index: 9, paramId: 1, value: 0.5),
        EngineResult.invalid,
      );
    });
  });

  group('inheritance rules (R13/R18/A7/A8)', () {
    EngineSnapshot emptyTrackSnapshot() => const EngineSnapshot(
      isRunning: true,
      sampleRate: 48000,
      bufferFrames: 128,
      framesProcessed: 0,
      xrunCount: 0,
      inputRms: 0,
      inputPeak: 0,
      outputRms: 0,
      latencyState: le.LatencyState.idle,
      measuredLatencyMs: -1,
      tracks: [TrackSnapshot.empty()],
    );

    test('re-sync re-copies the routed input chain with a fresh stamp, '
        'and touches nothing else (A6)', () {
      engine.nextSnapshot = emptyTrackSnapshot();
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setMonitorEffects(
          input: 0,
          effects: [BuiltInEffect(type: TrackEffectType.delay)],
        )
        ..record();
      addTearDown(repo.dispose);

      // The take drifts from its input: the input chain is re-shaped after it.
      repo.setMonitorEffects(
        input: 0,
        effects: [BuiltInEffect(type: TrackEffectType.reverb)],
      );
      expect(
        (repo.laneEffects(0, 0).single as BuiltInEffect).type,
        TrackEffectType.delay,
      );

      expect(repo.resyncLaneChainFromInput(channel: 0, lane: 0), isTrue);

      // By value, with a fresh provenance stamp — and fresh slot ids, since
      // the take's entries are new identities (A9).
      expect(
        (repo.laneEffects(0, 0).single as BuiltInEffect).type,
        TrackEffectType.reverb,
      );
      expect(repo.laneChainInheritedFrom(0, 0), [0]);
      expect(repo.laneEffects(0, 0).single.slotId, isNotNull);
      expect(
        repo.laneEffects(0, 0).single.slotId,
        isNot(repo.monitorEffects(0).single.slotId),
      );
    });

    test(
      're-sync restores the chain flag of an intentionally silenced take',
      () {
        engine.nextSnapshot = emptyTrackSnapshot();
        final repo = buildRepo()
          ..startEngine(const EngineConfig())
          ..setMonitorEffects(
            input: 0,
            effects: [BuiltInEffect(type: TrackEffectType.delay)],
          )
          ..record()
          ..setLaneChainEnabled(channel: 0, lane: 0, enabled: false);
        addTearDown(repo.dispose);

        repo.resyncLaneChainFromInput(channel: 0, lane: 0);

        // The copy is by value, and the source chain was engaged.
        expect(repo.laneChainEnabled(0, 0), isTrue);
      },
    );

    test('re-sync declines on both dry input shapes, leaving the take alone '
        '(R18)', () {
      engine.nextSnapshot = emptyTrackSnapshot();
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setMonitorEffects(
          input: 0,
          effects: [BuiltInEffect(type: TrackEffectType.delay)],
        )
        ..record();
      addTearDown(repo.dispose);
      final take = repo.laneEffects(0, 0);

      // Dry shape 1: an empty input chain.
      repo.setMonitorEffects(input: 0, effects: const []);
      expect(repo.laneCanInheritFromInput(0, 0), isFalse);
      expect(repo.resyncLaneChainFromInput(channel: 0, lane: 0), isFalse);
      expect(repo.laneEffects(0, 0), take);

      // Dry shape 2: a chain-disabled input chain.
      repo
        ..setMonitorEffects(
          input: 0,
          effects: [BuiltInEffect(type: TrackEffectType.reverb)],
        )
        ..setMonitorChainEnabled(input: 0, enabled: false);
      expect(repo.laneCanInheritFromInput(0, 0), isFalse);
      expect(repo.resyncLaneChainFromInput(channel: 0, lane: 0), isFalse);
      expect(repo.laneEffects(0, 0), take);
    });

    test('re-sync notifies so the fresh envelope is persisted (F3)', () {
      engine.nextSnapshot = emptyTrackSnapshot();
      final changed = <(int, int)>[];
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setMonitorEffects(
          input: 0,
          effects: [BuiltInEffect(type: TrackEffectType.delay)],
        )
        ..record();
      addTearDown(repo.dispose);

      repo
        ..onLaneChainChanged = ((c, l) => changed.add((c, l)))
        ..resyncLaneChainFromInput(channel: 0, lane: 0);

      expect(changed, [(0, 0)]);
    });

    test('record copies by value with provenance: editing the input chain '
        'afterwards never alters the take (R13)', () {
      engine.nextSnapshot = emptyTrackSnapshot();
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setMonitorEffects(
          input: 0,
          effects: [BuiltInEffect(type: TrackEffectType.delay)],
        )
        ..record();
      addTearDown(repo.dispose);

      final take = repo.laneEffects(0, 0);
      expect((take.single as BuiltInEffect).type, TrackEffectType.delay);
      expect(repo.laneChainInheritedFrom(0, 0), [0]);

      // Edit the input chain post-record — the take must be byte-identical.
      repo.setMonitorEffects(
        input: 0,
        effects: [BuiltInEffect(type: TrackEffectType.reverb)],
      );
      expect(repo.laneEffects(0, 0), take);
    });

    test('copied entries carry FRESH slot ids — bindings on the input chain '
        'never follow the copy (A9)', () {
      engine.nextSnapshot = emptyTrackSnapshot();
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setMonitorEffects(
          input: 0,
          effects: [BuiltInEffect(type: TrackEffectType.delay)],
        );
      addTearDown(repo.dispose);
      final sourceId = repo.monitorEffects(0).single.slotId;

      repo.record();

      final copiedId = repo.laneEffects(0, 0).single.slotId;
      expect(copiedId, isNotNull);
      expect(copiedId, isNot(sourceId));
    });

    test('a disabled monitor slot inherits disabled — the take reproduces '
        'the monitored sound (R18)', () {
      engine.nextSnapshot = emptyTrackSnapshot();
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setMonitorEffects(
          input: 0,
          effects: [
            BuiltInEffect(type: TrackEffectType.drive, enabled: false),
            BuiltInEffect(type: TrackEffectType.reverb),
          ],
        )
        ..record();
      addTearDown(repo.dispose);

      final take = repo.laneEffects(0, 0);
      expect(take[0].enabled, isFalse);
      expect(take[1].enabled, isTrue);
    });

    test('D-CHAINDIS: a chain-disabled monitor chain is treated as dry — the '
        'lane keeps its prior chain (R18)', () {
      engine.nextSnapshot = emptyTrackSnapshot();
      final prior = [BuiltInEffect(type: TrackEffectType.echo)];
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setLaneEffects(channel: 0, lane: 0, effects: prior)
        ..setMonitorEffects(
          input: 0,
          effects: [BuiltInEffect(type: TrackEffectType.drive)],
        )
        ..setMonitorChainEnabled(input: 0, enabled: false)
        ..record();
      addTearDown(repo.dispose);

      // Both dry shapes bail: the lane's chain is untouched.
      expect(
        (repo.laneEffects(0, 0).single as BuiltInEffect).type,
        TrackEffectType.echo,
      );
      expect(repo.laneChainInheritedFrom(0, 0), isEmpty);
    });

    test('overdub never re-inherits (A7): a record on a non-empty track '
        'leaves the take chain and provenance alone', () {
      engine.nextSnapshot = emptyTrackSnapshot();
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setMonitorEffects(
          input: 0,
          effects: [BuiltInEffect(type: TrackEffectType.delay)],
        )
        ..record();
      addTearDown(repo.dispose);
      final take = repo.laneEffects(0, 0);

      // The take exists; a later record press is an overdub (track PLAYING).
      engine.nextSnapshot = _playingSnapshot;
      repo
        ..setMonitorEffects(
          input: 0,
          effects: [BuiltInEffect(type: TrackEffectType.reverb)],
        )
        ..record();

      expect(repo.laneEffects(0, 0), take);
      expect(repo.laneChainInheritedFrom(0, 0), [0]);
    });

    test('divergence query flips when the input chain drifts from the take '
        'chain (A7)', () {
      engine.nextSnapshot = emptyTrackSnapshot();
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setMonitorEffects(
          input: 0,
          effects: [BuiltInEffect(type: TrackEffectType.delay)],
        )
        ..record();
      addTearDown(repo.dispose);

      // Right after the copy the two chains sound identical.
      expect(repo.laneChainDivergesFromInput(0, 0), isFalse);

      repo.setMonitorEffects(
        input: 0,
        effects: [BuiltInEffect(type: TrackEffectType.reverb)],
      );
      expect(repo.laneChainDivergesFromInput(0, 0), isTrue);
    });

    test('divergence compares AUDIBLE shapes: dry vs dry never diverges, '
        'dry vs audible always does (D-CHAINDIS)', () {
      final repo = buildRepo()..startEngine(const EngineConfig());
      addTearDown(repo.dispose);

      // Chain-disabled monitor chain + empty lane chain: both dry — even
      // though their raw fingerprints differ, nothing audibly diverges.
      repo
        ..setMonitorEffects(
          input: 0,
          effects: [BuiltInEffect(type: TrackEffectType.drive)],
        )
        ..setMonitorChainEnabled(input: 0, enabled: false)
        ..setLaneInput(channel: 0, lane: 0, inputChannel: 0);
      expect(repo.laneChainDivergesFromInput(0, 0), isFalse);

      // A dry monitor vs an audible lane chain: genuinely different sounds.
      repo.setLaneEffects(
        channel: 0,
        lane: 0,
        effects: [BuiltInEffect(type: TrackEffectType.reverb)],
      );
      expect(repo.laneChainDivergesFromInput(0, 0), isTrue);

      // Chain-disabling the lane too makes both sides dry again.
      repo.setLaneChainEnabled(channel: 0, lane: 0, enabled: false);
      expect(repo.laneChainDivergesFromInput(0, 0), isFalse);
    });

    test('the THIRD dry shape — every slot individually disabled — also '
        'never diverges from a dry chain (R16)', () {
      final repo = buildRepo()..startEngine(const EngineConfig());
      addTearDown(repo.dispose);

      // Lane holds one per-slot-disabled effect (bit-exact passthrough);
      // routed input's monitor chain is empty. Both are audibly dry.
      repo
        ..setLaneInput(channel: 0, lane: 0, inputChannel: 0)
        ..setLaneEffects(
          channel: 0,
          lane: 0,
          effects: [
            BuiltInEffect(type: TrackEffectType.reverb, enabled: false),
          ],
        );
      expect(repo.laneChainDivergesFromInput(0, 0), isFalse);

      // Two all-disabled chains of DIFFERENT types: still dry vs dry.
      repo.setMonitorEffects(
        input: 0,
        effects: [
          BuiltInEffect(type: TrackEffectType.drive, enabled: false),
        ],
      );
      expect(repo.laneChainDivergesFromInput(0, 0), isFalse);

      // Re-enabling the lane's slot makes it audible again → diverges.
      repo.setLaneEffectEnabled(channel: 0, lane: 0, index: 0, enabled: true);
      expect(repo.laneChainDivergesFromInput(0, 0), isTrue);
    });

    test('a WHOLESALE chain replacement drops the stale inheritedFrom '
        'marker; edits and reorders keep it (A9)', () {
      engine.nextSnapshot = emptyTrackSnapshot();
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setMonitorEffects(
          input: 0,
          effects: [
            BuiltInEffect(type: TrackEffectType.delay),
            BuiltInEffect(type: TrackEffectType.reverb),
          ],
        )
        ..record();
      addTearDown(repo.dispose);
      expect(repo.laneChainInheritedFrom(0, 0), [0]);

      // An edit that keeps entries (reorder + param change) keeps the marker.
      repo
        ..setLaneEffects(
          channel: 0,
          lane: 0,
          effects: repo.laneEffects(0, 0).reversed.toList(),
        )
        ..setLaneEffectParam(
          channel: 0,
          lane: 0,
          index: 0,
          param: 0,
          value: 0.9,
        );
      expect(repo.laneChainInheritedFrom(0, 0), [0]);

      // Replacing the chain with entries sharing NO slot ids (fresh, id-less
      // input entries get new ids minted) is a wholesale replacement — the
      // marker describes nothing that survived and drops.
      repo.setLaneEffects(
        channel: 0,
        lane: 0,
        effects: [BuiltInEffect(type: TrackEffectType.echo)],
      );
      expect(repo.laneChainInheritedFrom(0, 0), isEmpty);
    });

    test('clear-restore carries a DISABLED flag even on a lane with an '
        'empty chain (snapshot key union)', () {
      engine.nextSnapshot = emptyTrackSnapshot();
      final repo = buildRepo()..startEngine(const EngineConfig());
      addTearDown(repo.dispose);

      engine.undoRestoresClearResult = true;
      repo
        ..setLaneChainEnabled(channel: 0, lane: 0, enabled: false)
        ..clear()
        ..undo();

      expect(repo.laneChainEnabled(0, 0), isFalse);
    });

    test('clear-restore carries the chain flag and provenance: disable → '
        'clear → undo ⇒ still disabled, still inherited (R15)', () {
      engine.nextSnapshot = emptyTrackSnapshot();
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setMonitorEffects(
          input: 0,
          effects: [BuiltInEffect(type: TrackEffectType.delay)],
        )
        ..record();
      addTearDown(repo.dispose);
      repo.setLaneChainEnabled(channel: 0, lane: 0, enabled: false);

      engine.undoRestoresClearResult = true;
      repo
        ..clear()
        ..undo();

      expect(repo.laneChainEnabled(0, 0), isFalse);
      expect(repo.laneChainInheritedFrom(0, 0), [0]);
      expect(
        (repo.laneEffects(0, 0).single as BuiltInEffect).type,
        TrackEffectType.delay,
      );
    });

    test('clear without undo resets the lane chain flag and provenance to '
        'the dry defaults', () {
      engine.nextSnapshot = emptyTrackSnapshot();
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setMonitorEffects(
          input: 0,
          effects: [BuiltInEffect(type: TrackEffectType.delay)],
        )
        ..record();
      addTearDown(repo.dispose);
      repo
        ..setLaneChainEnabled(channel: 0, lane: 0, enabled: false)
        ..clear();

      expect(repo.laneEffects(0, 0), isEmpty);
      expect(repo.laneChainEnabled(0, 0), isTrue);
      expect(repo.laneChainInheritedFrom(0, 0), isEmpty);
    });
  });

  group('monitorChanges', () {
    test('every monitor write announces its input', () async {
      final repo = buildRepo()..startEngine(const EngineConfig());
      addTearDown(repo.dispose);
      final seen = <int>[];
      final sub = repo.monitorChanges.listen(seen.add);
      addTearDown(sub.cancel);

      // Monitor state is the one part of the rig that is not projected onto
      // LooperState, so a cache of it (MonitorCubit) has no other way to
      // notice a writer that went straight to the repository.
      repo
        ..setMonitorInputMode(input: 0, mode: MonitorMode.on)
        ..setMonitorOutput(input: 1, mask: 0x2)
        ..setMonitorVolume(input: 2, volume: 0.5)
        ..setMonitorMute(input: 3, muted: true)
        ..setMonitorEffects(
          input: 4,
          effects: [BuiltInEffect(type: TrackEffectType.drive)],
        )
        ..setMonitorEffectEnabled(input: 4, index: 0, enabled: false)
        ..setMonitorChainEnabled(input: 5, enabled: false);
      await Future<void>.delayed(Duration.zero);

      expect(seen, [0, 1, 2, 3, 4, 4, 5]);
    });

    test('a disposed repository announces nothing', () async {
      final repo = buildRepo()..startEngine(const EngineConfig());
      final seen = <int>[];
      final sub = repo.monitorChanges.listen(seen.add);
      addTearDown(sub.cancel);
      // A chain whose plugin cannot bind, which arms the cold-start recovery
      // scan — the ordinary "quit while the plugin scan is running" path.
      repo.setMonitorEffects(
        input: 0,
        effects: const [
          PluginEffect(
            ref: PluginRef(format: PluginFormat.vst3, id: 'gone'),
          ),
        ],
      );

      await repo.dispose();
      // The scan outlives the dispose, and `dispose` does not clear the
      // running intent — only `stopEngine` does — so its continuation
      // re-applies the chain and announces into a closed controller.
      await repo.pluginCatalog.scan();
      await Future<void>.delayed(Duration.zero);
      // And a plain write after the close, which applySession and the
      // reconnect path can both still make on the way down.
      repo.setMonitorMute(input: 0, muted: true);
      await Future<void>.delayed(Duration.zero);

      expect(seen, [0]); // the one before the dispose, and nothing after
    });

    test('a parameter write does not announce', () async {
      final repo = buildRepo()..startEngine(const EngineConfig());
      addTearDown(repo.dispose);
      repo.setMonitorEffects(
        input: 0,
        effects: [BuiltInEffect(type: TrackEffectType.drive)],
      );
      final seen = <int>[];
      final sub = repo.monitorChanges.listen(seen.add);
      addTearDown(sub.cancel);

      // Deliberate, and load-bearing: these arrive at controller rate from a
      // mapped CC, and the listener persists what it reads — announcing would
      // write five settings keys per frame of a sweep. Param writes announce
      // on their own throttled stream instead: `monitorParamChanges` (#605).
      repo.setMonitorEffectParam(input: 0, index: 0, param: 0, value: 0.4);
      await Future<void>.delayed(Duration.zero);

      expect(seen, isEmpty);
    });

    test('a relink announces', () async {
      final repo = buildRepo()..startEngine(const EngineConfig());
      addTearDown(repo.dispose);
      repo.setMonitorEffects(
        input: 0,
        effects: const [
          PluginEffect(
            ref: PluginRef(format: PluginFormat.vst3, id: 'old'),
          ),
        ],
      );
      final seen = <int>[];
      final sub = repo.monitorChanges.listen(seen.add);
      addTearDown(sub.cancel);

      // Re-identifying an entry changes what the console draws as much as
      // replacing it does — and this is the ONE action a placeholder offers.
      repo.relinkMonitorPlugin(
        input: 0,
        index: 0,
        ref: const PluginRef(format: PluginFormat.vst3, id: 'new'),
      );
      await Future<void>.delayed(Duration.zero);

      expect(seen, [0]);
    });

    test(
      'a rebind that rewrites the chain announces, with no setter called',
      () async {
        engine.pluginScanResults = const [
          le.PluginDescriptor(
            id: 'verb',
            name: 'Catalog Reverb',
            vendor: 'Acme',
            path: '/Library/Audio/Plug-Ins/VST3/verb.vst3',
            format: le.PluginFormat.vst3,
            version: 0,
          ),
        ];
        final repo = buildRepo()..startEngine(const EngineConfig());
        addTearDown(repo.dispose);
        await repo.pluginCatalog.scan();
        final seen = <int>[];
        final sub = repo.monitorChanges.listen(seen.add);
        addTearDown(sub.cancel);

        repo.setMonitorEffects(
          input: 0,
          effects: const [
            PluginEffect(
              ref: PluginRef(format: PluginFormat.vst3, id: 'verb'),
            ),
          ],
        );
        await Future<void>.delayed(Duration.zero);

        // TWO: the write itself, and the apply behind it rewriting the entry
        // with what the bind resolved — here the display name. That second one
        // is the only announce a device reconnect makes, since `_reapplyAll`
        // rebinds every slot without anyone calling a setter, and a plugin that
        // comes back fine would otherwise read "loading…" forever.
        expect(seen, [0, 0]);
        expect(
          (repo.monitorEffects(0).single as PluginEffect).name,
          'Catalog Reverb',
        );
      },
    );
  });

  group('monitorParamChanges', () {
    // The throttle is a real Timer, so these run under fake time: `elapse`
    // is the only honest way to cross the 100 ms window without a wall-clock
    // wait, and `flushMicrotasks` is what delivers a broadcast add.
    LooperRepository buildWithChain(FakeAsync async) {
      final repo = buildRepo()
        ..startEngine(const EngineConfig())
        ..setMonitorEffects(
          input: 0,
          effects: [BuiltInEffect(type: TrackEffectType.drive)],
        );
      async.flushMicrotasks();
      return repo;
    }

    test('a param write announces its input', () {
      fakeAsync((async) {
        final repo = buildWithChain(async);
        final seen = <int>[];
        repo.monitorParamChanges.listen(seen.add);

        repo.setMonitorEffectParam(input: 0, index: 0, param: 0, value: 0.4);
        async.flushMicrotasks();

        // Immediately — the knob starts moving on the sweep's first frame,
        // not one throttle window late.
        expect(seen, [0]);
        unawaited(repo.dispose());
        async.flushMicrotasks();
      });
    });

    test('a burst inside the window coalesces to first plus trailing', () {
      fakeAsync((async) {
        final repo = buildWithChain(async);
        final seen = <int>[];
        repo.monitorParamChanges.listen(seen.add);

        // A sweep: many controller frames inside one throttle window.
        for (var i = 0; i < 20; i++) {
          repo.setMonitorEffectParam(
            input: 0,
            index: 0,
            param: 0,
            value: i / 20,
          );
        }
        async.flushMicrotasks();
        expect(seen, [0], reason: 'the window holds everything after the 1st');

        async
          ..elapse(LooperRepository.monitorParamAnnounceInterval)
          ..flushMicrotasks();
        // One trailing announce carries the sweep's last value; a listener
        // re-reads the chain, so the announce needs no payload.
        expect(seen, [0, 0]);
        expect(
          (repo.monitorEffects(0).single as BuiltInEffect).params.first,
          closeTo(19 / 20, 1e-9),
        );

        // And a clean window ends silent — no announce without a write.
        async
          ..elapse(LooperRepository.monitorParamAnnounceInterval * 2)
          ..flushMicrotasks();
        expect(seen, [0, 0]);
        unawaited(repo.dispose());
        async.flushMicrotasks();
      });
    });

    test('a sweep longer than one window announces at the cadence', () {
      fakeAsync((async) {
        final repo = buildWithChain(async);
        final seen = <int>[];
        repo.monitorParamChanges.listen(seen.add);

        // 350 ms of continuous sweeping at ~100 fps.
        for (var t = 0; t < 35; t++) {
          repo.setMonitorEffectParam(
            input: 0,
            index: 0,
            param: 0,
            value: t / 35,
          );
          async
            ..elapse(const Duration(milliseconds: 10))
            ..flushMicrotasks();
        }

        // ≤10 Hz: the leading announce plus one per full window — never one
        // per write.
        expect(seen.length, inInclusiveRange(3, 5));
        unawaited(repo.dispose());
        async.flushMicrotasks();
      });
    });

    test('windows are per input, and rejected writes stay silent', () {
      fakeAsync((async) {
        final repo = buildWithChain(async)
          ..setMonitorEffects(
            input: 3,
            effects: [BuiltInEffect(type: TrackEffectType.delay)],
          );
        async.flushMicrotasks();
        final seen = <int>[];
        repo.monitorParamChanges.listen(seen.add);

        repo
          ..setMonitorEffectParam(input: 0, index: 0, param: 0, value: 0.1)
          // Input 3's window is its own — input 0's open one must not hold it.
          ..setMonitorEffectParam(input: 3, index: 0, param: 0, value: 0.2)
          // Out of range: the write did nothing, so nothing to announce.
          ..setMonitorEffectParam(input: 0, index: 9, param: 0, value: 0.3)
          ..setMonitorEffectParam(input: 7, index: 0, param: 0, value: 0.3);
        async.flushMicrotasks();

        expect(seen, [0, 3]);
        unawaited(repo.dispose());
        async.flushMicrotasks();
      });
    });

    test('a structural write does not announce on the param stream', () {
      fakeAsync((async) {
        final repo = buildWithChain(async);
        final seen = <int>[];
        repo.monitorParamChanges.listen(seen.add);

        repo
          ..setMonitorMute(input: 0, muted: true)
          ..setMonitorChainEnabled(input: 0, enabled: false)
          ..setMonitorEffects(
            input: 0,
            effects: [BuiltInEffect(type: TrackEffectType.delay)],
          );
        async.flushMicrotasks();

        expect(seen, isEmpty);
        unawaited(repo.dispose());
        async.flushMicrotasks();
      });
    });

    test('a disposed repository announces nothing, even mid-window', () {
      fakeAsync((async) {
        final repo = buildWithChain(async);
        final seen = <int>[];
        repo.monitorParamChanges.listen(seen.add);

        // Leave a dirty window open across the dispose: the trailing timer
        // must be cancelled, not left to fire into a closed controller.
        repo
          ..setMonitorEffectParam(input: 0, index: 0, param: 0, value: 0.1)
          ..setMonitorEffectParam(input: 0, index: 0, param: 0, value: 0.2);
        unawaited(repo.dispose());
        async
          ..elapse(LooperRepository.monitorParamAnnounceInterval * 2)
          ..flushMicrotasks();

        expect(seen, [0]); // the leading announce, and nothing after
      });
    });
  });

  group('monitor mode (tri-state)', () {
    EngineSnapshot snapshotWith({
      required TrackState state,
      required bool pending,
      int laneInput = 0,
    }) => EngineSnapshot(
      isRunning: true,
      sampleRate: 48000,
      bufferFrames: 128,
      framesProcessed: 0,
      xrunCount: 0,
      inputRms: 0,
      inputPeak: 0,
      outputRms: 0,
      latencyState: le.LatencyState.idle,
      measuredLatencyMs: -1,
      tracks: [
        TrackSnapshot(
          state: state,
          pending: pending,
          volume: 1,
          muted: false,
          lengthFrames: 0,
          undoDepth: 0,
          rms: 0,
          peak: 0,
          lanes: [
            LaneSnapshot(
              inputChannel: laneInput,
              outputMask: 0x3,
              volume: 1,
              muted: false,
              lengthFrames: 0,
              rms: 0,
              peak: 0,
            ),
          ],
        ),
      ],
    );

    int monitorPushes() =>
        engine.calls.where((c) => c == 'setMonitorInputEnabled').length;

    test('off and on ignore the arm state entirely', () async {
      engine.nextSnapshot = snapshotWith(
        state: TrackState.recording,
        pending: false,
      );
      final repo = buildRepo()..startEngine(const EngineConfig());
      addTearDown(repo.dispose);
      final sub = repo.looperState.listen((_) {});
      addTearDown(sub.cancel);
      ticker.add(null);
      await Future<void>.delayed(Duration.zero);

      repo.setMonitorInputMode(input: 0, mode: MonitorMode.off);
      expect(repo.monitorResolved(0), isFalse);
      repo.setMonitorInputMode(input: 0, mode: MonitorMode.on);
      expect(repo.monitorResolved(0), isTrue);
    });

    test('auto is closed while nothing is armed', () async {
      engine.nextSnapshot = snapshotWith(
        state: TrackState.playing,
        pending: false,
      );
      final repo = buildRepo()..startEngine(const EngineConfig());
      addTearDown(repo.dispose);
      final sub = repo.looperState.listen((_) {});
      addTearDown(sub.cancel);
      ticker.add(null);
      await Future<void>.delayed(Duration.zero);

      repo.setMonitorInputMode(input: 0, mode: MonitorMode.auto);
      expect(repo.monitorMode(0), MonitorMode.auto);
      expect(repo.monitorResolved(0), isFalse);
    });

    test('auto opens while a track fed by the input is capturing', () async {
      engine.nextSnapshot = snapshotWith(
        state: TrackState.recording,
        pending: false,
      );
      final repo = buildRepo()..startEngine(const EngineConfig());
      addTearDown(repo.dispose);
      final sub = repo.looperState.listen((_) {});
      addTearDown(sub.cancel);
      ticker.add(null);
      await Future<void>.delayed(Duration.zero);

      repo.setMonitorInputMode(input: 0, mode: MonitorMode.auto);
      expect(repo.monitorResolved(0), isTrue);
    });

    test('auto opens on a PENDING arm, not only once audio flows', () async {
      engine.nextSnapshot = snapshotWith(
        state: TrackState.empty,
        pending: true,
      );
      final repo = buildRepo()..startEngine(const EngineConfig());
      addTearDown(repo.dispose);
      final sub = repo.looperState.listen((_) {});
      addTearDown(sub.cancel);
      ticker.add(null);
      await Future<void>.delayed(Duration.zero);

      repo.setMonitorInputMode(input: 0, mode: MonitorMode.auto);
      expect(repo.monitorResolved(0), isTrue);
    });

    test("auto is a fan-in: another input's arm does not open it", () async {
      engine.nextSnapshot = snapshotWith(
        state: TrackState.recording,
        pending: false,
      );
      final repo = buildRepo()..startEngine(const EngineConfig());
      addTearDown(repo.dispose);
      final sub = repo.looperState.listen((_) {});
      addTearDown(sub.cancel);
      ticker.add(null);
      await Future<void>.delayed(Duration.zero);

      // The armed track's lane records input 0, so input 1 stays closed.
      repo.setMonitorInputMode(input: 1, mode: MonitorMode.auto);
      expect(repo.monitorResolved(1), isFalse);
    });

    test('an arm that starts and stops opens then closes the gate', () async {
      engine.nextSnapshot = snapshotWith(
        state: TrackState.playing,
        pending: false,
      );
      final repo = buildRepo()..startEngine(const EngineConfig());
      addTearDown(repo.dispose);
      final sub = repo.looperState.listen((_) {});
      addTearDown(sub.cancel);
      ticker.add(null);
      await Future<void>.delayed(Duration.zero);

      repo.setMonitorInputMode(input: 0, mode: MonitorMode.auto);
      expect(repo.monitorResolved(0), isFalse);

      engine.nextSnapshot = snapshotWith(
        state: TrackState.recording,
        pending: false,
      );
      ticker.add(null);
      await Future<void>.delayed(Duration.zero);
      expect(repo.monitorResolved(0), isTrue);

      engine.nextSnapshot = snapshotWith(
        state: TrackState.playing,
        pending: false,
      );
      ticker.add(null);
      await Future<void>.delayed(Duration.zero);
      expect(repo.monitorResolved(0), isFalse);
    });

    test('an idle auto input costs no engine writes per tick', () async {
      engine.nextSnapshot = snapshotWith(
        state: TrackState.playing,
        pending: false,
      );
      final repo = buildRepo()..startEngine(const EngineConfig());
      addTearDown(repo.dispose);
      final sub = repo.looperState.listen((_) {});
      addTearDown(sub.cancel);
      ticker.add(null);
      await Future<void>.delayed(Duration.zero);

      repo.setMonitorInputMode(input: 0, mode: MonitorMode.auto);
      final after = monitorPushes();

      // Several projections that do not move the arm state.
      for (var i = 0; i < 3; i++) {
        engine.nextSnapshot = snapshotWith(
          state: TrackState.playing,
          pending: false,
        );
        ticker.add(null);
        await Future<void>.delayed(Duration.zero);
      }

      expect(monitorPushes(), after);
    });
  });
}

/// The instance fields `class [classHeader]` declares in the library at
/// [relativePath] (relative to this package's root), read from source.
///
/// Source-level rather than reflective because `dart:mirrors` does not exist
/// under `flutter test` and `Isolate.resolvePackageUri` throws there, while the
/// property being guarded is a property of the DECLARATION, not of any
/// instance — no runtime value can reveal a field that is simply absent.
Set<String> _declaredFinalFields(String relativePath, String classHeader) {
  final file = _packageFile(relativePath);
  final source = file.readAsStringSync();

  final start = source.indexOf('\nclass $classHeader {');
  expect(start, isNot(-1), reason: '$classHeader not found in ${file.path}');
  final end = source.indexOf('\n}\n', start);
  expect(end, isNot(-1), reason: '$classHeader has no closing brace');

  final body = source.substring(start, end);
  // `final <type> name;` and `final <type> name = <init>;`, where `<type>` may
  // be absent (inferred), prefixed (`ffi.Pointer<Int32>`), a function type
  // (`void Function(int)`) or a record (`(int, String)`).
  //
  // The type is "anything up to the name that is not `;`, `=` or a newline"
  // rather than an identifier character class, and the initializer arm is
  // optional, because both narrower forms leave the guard with a HOLE: a class
  // of `[\w<>,?\s]` silently skips any field whose type contains `.`, `(` or
  // `)`, and a pattern with no `=` arm silently skips every field carrying a
  // declaration initializer — `final int x = 0;` used to leave this golden
  // green. A field the golden cannot see is a field it cannot guard, and a
  // golden with a hole is worse than none because it is trusted.
  return RegExp(
    r'^  final\s+(?:[^;=\n]+?\s)?(\w+)\s*(?:=[^;]*)?;',
    multiLine: true,
  ).allMatches(body).map((m) => m.group(1)!).toSet();
}

/// Locates [relativePath] whether the suite was started from this package's
/// root (what `flutter test` and CI do) or from an ancestor of it.
File _packageFile(String relativePath) {
  for (var dir = Directory.current; ; dir = dir.parent) {
    for (final prefix in const ['', 'packages/looper_repository/']) {
      final candidate = File('${dir.path}/$prefix$relativePath');
      if (candidate.existsSync()) return candidate;
    }
    if (dir.path == dir.parent.path) {
      fail('could not locate $relativePath from ${Directory.current.path}');
    }
  }
}
