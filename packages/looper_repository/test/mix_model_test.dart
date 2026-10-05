import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno_engine/segno_engine.dart'
    show EngineSnapshot, LaneSnapshot, TrackSnapshot;
import 'package:segno_engine/segno_engine.dart' as le show LatencyState;

import 'helpers/fake_audio_engine.dart';

/// A fixed-eight-track rig with [count] tracks in the authored state.
EngineSnapshot _rig(
  int count, {
  TrackState state = TrackState.empty,
  bool pending = false,
  int outputBusCount = 0,
}) => EngineSnapshot(
  isRunning: true,
  devicePresent: true,
  sampleRate: 48000,
  bufferFrames: 128,
  inputChannels: 2,
  outputChannels: 2,
  outputBusCount: outputBusCount,
  framesProcessed: 0,
  xrunCount: 0,
  inputRms: 0,
  inputPeak: 0,
  outputRms: 0,
  latencyState: le.LatencyState.idle,
  measuredLatencyMs: -1,
  tracks: [
    for (var i = 0; i < count; i++)
      TrackSnapshot(
        state: state,
        pending: pending,
        volume: 1,
        muted: false,
        lengthFrames: 0,
        undoDepth: 0,
        rms: 0,
        peak: 0,
        lanes: const [
          LaneSnapshot(
            inputChannel: 0,
            outputMask: 3,
            volume: 1,
            muted: false,
            lengthFrames: 0,
            rms: 0,
            peak: 0,
          ),
        ],
      ),
    for (var i = count; i < 8; i++) const TrackSnapshot.empty(),
  ],
);

void main() {
  late FakeAudioEngine engine;
  late StreamController<void> ticker;

  setUp(() {
    engine = FakeAudioEngine();
    ticker = StreamController<void>.broadcast();
    engine.nextSnapshot = _rig(2);
  });

  tearDown(() => ticker.close());

  LooperRepository start() {
    final repo = LooperRepository(engine: engine, ticker: ticker.stream)
      ..startEngine(const EngineConfig());
    addTearDown(repo.dispose);
    return repo;
  }

  group('shared FX lookup', () {
    test('missing owners never retarget an existing chain', () {
      final repo = start();
      final effect = BuiltInEffect(
        type: TrackEffectType.delay,
        slotId: 'lookup-delay',
      );
      expect(
        repo.setLaneEffects(channel: 0, lane: 0, effects: [effect]),
        EngineResult.ok,
      );
      expect(
        repo.chainEntriesAt(const FxAddress(stage: FxStage.loop, lane: 0)),
        [effect],
      );
      for (final address in const [
        FxAddress(stage: FxStage.loop),
        FxAddress(stage: FxStage.loop, lane: 1),
        FxAddress(stage: FxStage.track, index: 1),
        FxAddress(stage: FxStage.input, index: 1),
        FxAddress(stage: FxStage.allTracks, index: 1),
        FxAddress(stage: FxStage.output, index: 9),
        FxAddress(stage: FxStage.track, index: -1),
      ]) {
        expect(repo.chainEntriesAt(address), isNull);
      }
    });

    test('configured empty owners remain available to bindings', () {
      engine.nextSnapshot = _rig(2, outputBusCount: 1);
      final repo = start();
      expect(
        repo.setMonitorEffects(input: 0, effects: [], chainEnabled: false),
        EngineResult.ok,
      );
      expect(
        repo.setTrackEffects(channel: 0, effects: [], chainEnabled: false),
        EngineResult.ok,
      );
      for (final address in const [
        FxAddress(stage: FxStage.input),
        FxAddress(stage: FxStage.track),
        FxAddress(stage: FxStage.allTracks),
        FxAddress(stage: FxStage.output),
      ]) {
        expect(
          repo.chainEntriesAt(address),
          isEmpty,
          reason: address.toString(),
        );
      }
    });
  });

  group('confirmed mix transactions', () {
    test(
      'second refusal does not poison accepted pair or its settlement',
      () async {
        final repo = start();
        final failures = <EngineResult>[];
        final subscription = repo.mixSettingsFailures.listen(failures.add);
        addTearDown(subscription.cancel);
        engine
          ..publishMixCommands = false
          ..commandsAreSettled = false;
        expect(repo.setInputPair(input: 0, paired: true), EngineResult.ok);
        expect(repo.inputSetup.isPairLeft(0), isFalse);
        expect(repo.setTrackPan(.5), EngineResult.notReady);
        expect(repo.trackPan(0), 0);
        engine
          ..publishMix()
          ..commandsAreSettled = true;
        expect(await repo.settleMixSettings(), EngineResult.ok);
        await Future<void>.delayed(Duration.zero);
        expect(repo.inputSetup.isPairLeft(0), isTrue);
        expect(failures, [EngineResult.notReady]);
        expect(engine.monitorPan[0], -1);
        expect(engine.monitorPan[1], 1);
      },
    );

    test(
      'late refusal leaves confirmed intent and reports exactly once',
      () async {
        final repo = start()..setTrackPan(.25);
        final failures = <EngineResult>[];
        final subscription = repo.mixSettingsFailures.listen(failures.add);
        addTearDown(subscription.cancel);
        engine
          ..publishMixCommands = false
          ..commandsAreSettled = false;
        expect(repo.setTrackPan(-.5), EngineResult.ok);
        expect(repo.trackPan(0), .25);
        // Callback rejected it; the old revision remains.
        engine
          ..pendingMix = null
          ..commandsAreSettled = true;
        expect(await repo.settleMixSettings(), EngineResult.invalid);
        await Future<void>.delayed(Duration.zero);
        expect(repo.trackPan(0), .25);
        expect(engine.lanePan[(0, 0)], .25);
        expect(failures, [EngineResult.invalid]);
        expect(engine.calls.last, isNot('stop'));
      },
    );

    test('finalize and armed cancellation remain usable during held mix', () {
      final repo = start();
      engine
        ..publishMixCommands = false
        ..commandsAreSettled = false;
      expect(repo.setMonitorVolume(input: 0, volume: .5), EngineResult.ok);
      engine.nextSnapshot = _rig(2, state: TrackState.recording);
      expect(repo.record(), EngineResult.ok);
      engine.nextSnapshot = _rig(2, pending: true);
      expect(repo.record(), EngineResult.ok);
      expect(engine.calls.where((c) => c == 'record'), hasLength(2));
      engine.nextSnapshot = _rig(2);
      expect(
        repo.record(),
        EngineResult.notReady,
      ); // a new image depends on mix
    });

    test('armed source survives live fader and later input edits', () async {
      final repo = start()..setInputPan(input: 0, pan: -.75);
      engine
        ..publishRecordImages = false
        ..commandsAreSettled = false;
      expect(repo.record(), EngineResult.ok);
      engine.nextSnapshot = _rig(2, pending: true);
      expect(
        repo.setMixSettings(
          trackPans: {0: .25},
          inputSetup: repo.inputSetup,
          laneLevels: {(0, 0): .4},
        ),
        EngineResult.ok,
      );
      engine.commandsAreSettled = true;
      expect(await repo.settleMixSettings(), EngineResult.ok);
      expect(engine.lanePan[(0, 0)], .25); // old playback while armed
      engine
        ..publishMixCommands = false
        ..commandsAreSettled = false;
      expect(repo.setInputPan(input: 0, pan: 1), EngineResult.ok);
      engine
        ..publishImage(0)
        ..nextSnapshot = _rig(2, state: TrackState.playing);
      ticker.add(null); // image published while a later mix command is held
      await Future<void>.delayed(Duration.zero);
      expect(repo.trackPan(0), .25);
      engine
        ..publishMix()
        ..commandsAreSettled = true;
      expect(await repo.settleMixSettings(), EngineResult.ok);
      expect(engine.lanePan[(0, 0)], -.5);
      expect(engine.laneVol[(0, 0)], .4);
      expect(repo.inputSetup.panOf(0), 1);
      // A later fader change and restart must retain that take's source image.
      engine.publishMixCommands = true;
      expect(repo.setTrackPan(.5), EngineResult.ok);
      expect(engine.lanePan[(0, 0)], -.25);
      repo
        ..stopEngine()
        ..startEngine(const EngineConfig());
      expect(engine.lanePan[(0, 0)], -.25);
    });

    test('stop consumes a published short take before the first poll', () {
      final repo = start()..setInputPan(input: 0, pan: -.6);
      engine
        ..publishRecordImages = false
        ..commandsAreSettled = false;
      expect(repo.record(), EngineResult.ok);
      engine.publishImage(0);
      // No ticker/settlement call observes the take before device stop.
      repo.stopEngine();
      engine.commandsAreSettled = true;
      repo.startEngine(const EngineConfig());
      expect(engine.lanePan[(0, 0)], -.6);
    });

    test('refused record cannot seed an image', () {
      final repo = start()..setInputPan(input: 0, pan: -1);
      engine.recordResult = EngineResult.notReady;
      expect(repo.record(), EngineResult.notReady);
      expect(engine.imageRevisions, isEmpty);
      repo
        ..stopEngine()
        ..startEngine(const EngineConfig());
      expect(engine.lanePan[(0, 0)], 0);
    });

    test('timeout stops and restart replays only confirmed intent', () async {
      final repo = start()..setTrackPan(.25);
      engine
        ..publishMixCommands = false
        ..commandsAreSettled = false;
      expect(repo.setTrackPan(-.5), EngineResult.ok);
      expect(
        await repo.settleMixSettings(
          attempts: 1,
          pollInterval: Duration.zero,
        ),
        EngineResult.notReady,
      );
      expect(engine.calls.last, 'stop');
      expect(repo.trackPan(0), .25);
      engine
        ..publishMixCommands = true
        ..commandsAreSettled = true;
      repo.startEngine(const EngineConfig());
      expect(engine.pendingMix, isNull);
      expect(engine.lanePan[(0, 0)], .25);
    });
  });

  group('track pan', () {
    test('moves every lane by the track pan and projects it', () {
      final repo = start()
        ..setLaneCount(channel: 0, count: 2)
        ..setTrackPan(0.25);
      expect(engine.lanePan[(0, 0)], 0.25);
      expect(engine.lanePan[(0, 1)], 0.25);
      expect(repo.state.tracks[0].pan, 0.25);
      expect(repo.trackPan(0), 0.25);
    });

    test('clamps, and a lane image plus the track pan clamps too', () {
      final repo = start()
        ..setInputPan(input: 0, pan: -0.5)
        ..record();
      expect(engine.lanePan[(0, 0)], -0.5);
      repo.setTrackPan(-0.9);
      expect(engine.lanePan[(0, 0)], -1.0);
      repo.setTrackPan(7);
      expect(repo.trackPan(0), 1.0);
      expect(engine.lanePan[(0, 0)], 0.5);
    });

    test('is held while stopped and replayed on start', () {
      final repo = LooperRepository(engine: engine, ticker: ticker.stream)
        ..setTrackPan(-0.3, channel: 1);
      addTearDown(repo.dispose);
      expect(engine.lanePan, isEmpty);
      repo.startEngine(const EngineConfig());
      expect(engine.lanePan[(1, 0)], -0.3);
    });
  });

  group('solo', () {
    test('pushes, projects, clears and replays', () {
      final repo = start()..setTrackSolo(channel: 1, solo: true);
      expect(engine.trackSolo[1], isTrue);
      expect(repo.trackSoloed(1), isTrue);
      expect(repo.trackSoloed(0), isFalse);
      engine.trackSolo.clear();
      repo
        ..stopEngine()
        ..startEngine(const EngineConfig());
      expect(repo.trackSoloed(1), isTrue);
      expect(repo.trackSoloed(0), isFalse);
      expect(engine.trackSolo, {for (var c = 0; c < 8; c++) c: c == 1});
      repo
        ..setTrackSolo(channel: 0, solo: true)
        ..clearSolo();
      expect(engine.trackSolo, {for (var c = 0; c < 8; c++) c: false});
      expect(repo.trackSoloed(1), isFalse);
    });

    test('never writes the mute', () {
      final repo = start()
        ..setMute(muted: true)
        ..setTrackSolo(channel: 0, solo: true)
        ..clearSolo();
      expect(repo.trackMuted(0), isTrue);
    });
  });

  group('reset mixer', () {
    test('while stopped clears the remembered pans the start would replay', () {
      final repo = LooperRepository(engine: engine, ticker: ticker.stream)
        ..setTrackPan(0.4, channel: 2);
      addTearDown(repo.dispose);
      expect(repo.resetMixer(), EngineResult.ok);
      expect(repo.trackPan(2), 0);
      repo.startEngine(const EngineConfig());
      // Slot2 exists in the fixed native rig and replays centered.
      expect(engine.lanePan[(2, 0)], 0);
    });

    test('resets track gain and pan, keeps part level, mute and solo', () {
      final repo = start()
        ..setLaneVolume(0.6, channel: 0, lane: 0)
        ..setVolume(0.4)
        ..setTrackPan(0.7)
        ..setMute(muted: true)
        ..setTrackSolo(channel: 1, solo: true)
        ..resetMixer();
      expect(engine.trackLevels[0], 1.0);
      expect(engine.laneVol[(0, 0)], 0.6);
      expect(engine.lanePan[(0, 0)], 0.0);
      expect(repo.trackMuted(0), isTrue);
      expect(repo.trackSoloed(1), isTrue);
    });
  });

  group('input trim', () {
    test('accepts both trim endpoints through the mix payload', () {
      final repo = start();
      expect(repo.setInputTrimDb(input: 0, db: -24), EngineResult.ok);
      expect(repo.setInputTrimDb(input: 1, db: 12), EngineResult.ok);
      expect(engine.inputTrim[0], closeTo(0.06309573444801933, 1e-16));
      expect(engine.inputTrim[1], closeTo(3.9810717055349722, 1e-15));
      expect(repo.inputSetup.trimDb, {0: -24, 1: 12});
    });

    test('pushes the linear gain, clamps and projects in dB', () {
      final repo = start()..setInputTrimDb(input: 0, db: -6);
      expect(engine.inputTrim[0], closeTo(0.5012, 1e-3));
      expect(repo.state.inputSetup.trimDbOf(0), -6);
      repo.setInputTrimDb(input: 1, db: 40);
      expect(repo.inputSetup.trimDbOf(1), kMaxInputTrimDb);
      repo.setInputTrimDb(input: 0, db: 0);
      expect(engine.inputTrim[0], 1.0);
      expect(repo.inputSetup.trimDb.containsKey(0), isFalse);
    });

    test('retains stopped intent and replays it on start', () {
      final repo = LooperRepository(engine: engine, ticker: ticker.stream)
        ..setInputTrimDb(input: 0, db: 6);
      addTearDown(repo.dispose);
      expect(repo.inputSetup.trimDbOf(0), 6);
      expect(engine.inputTrim, isEmpty);
      engine.inputTrim.clear();
      repo.startEngine(const EngineConfig());
      expect(engine.inputTrim[0], closeTo(1.995, 1e-3));
    });
  });

  group('input pan and pairs', () {
    test('accepted record locks source pair before callback publication', () {
      final repo = start();
      engine
        ..publishRecordImages = false
        ..commandsAreSettled = false;
      expect(repo.record(), EngineResult.ok);
      final image = engine.pendingImages[0];
      expect(repo.setInputPair(input: 0, paired: true), EngineResult.invalid);
      expect(
        repo.applyMixSettings(
          repo.mixSettingsSnapshot.copyWith(
            inputSetup: InputSetup(pairs: const {0: 0}),
          ),
        ),
        EngineResult.invalid,
      );
      expect(repo.inputSetup.pairs, isEmpty);
      expect(engine.pendingImages[0], same(image));
      expect(engine.monitorPan[0], 0);
      expect(engine.monitorPan[1], 0);
    });

    test('stop changes mix lifetime without changing session revision', () {
      final repo = start();
      final revision = repo.sessionRevision;
      final generation = repo.mixGeneration;
      repo.stopEngine();
      expect(repo.mixGeneration, greaterThan(generation));
      expect(repo.sessionRevision, revision);
      final stoppedGeneration = repo.mixGeneration;
      repo.startEngine(const EngineConfig());
      expect(repo.mixGeneration, greaterThan(stoppedGeneration));
    });

    test('a mono pan moves the monitor; a pair sits hard on its sides', () {
      final repo = start()
        ..setMonitorVolume(input: 0, volume: 0.8)
        ..setInputPan(input: 0, pan: -0.5);
      expect(engine.monitorPan[0], -0.5);
      expect(engine.monitorVolume[0], 0.8);
      repo.setInputPair(input: 0, paired: true);
      expect(engine.monitorPan[0], -1.0);
      expect(engine.monitorPan[1], 1.0);
      expect(repo.inputSetup.pairOf(1), 0);
      // The balance favours Right: Left falls, Right stays at unity.
      repo.setPairBalance(input: 0, balance: 0.5);
      expect(engine.monitorVolume[0], closeTo(0.8 * 0.70710678, 1e-6));
      expect(engine.monitorVolume[1], 1.0);
      // Unlinking restores the mono pan.
      repo.setInputPair(input: 0, paired: false);
      expect(engine.monitorPan[0], -0.5);
      expect(engine.monitorPan[1], 0.0);
      expect(engine.monitorVolume[0], 0.8);
      expect(repo.inputSetup.pairs, isEmpty);
    });

    test('rejects an odd lower member and a balance on a mono input', () {
      final repo = start();
      expect(
        repo.setInputPair(input: kMaxChannels - 1, paired: true),
        EngineResult.invalid,
      );
      expect(
        repo.setInputPair(input: 1, paired: true),
        EngineResult.invalid,
      );
      expect(
        repo.setPairBalance(input: 0, balance: 0.5),
        EngineResult.invalid,
      );
    });

    test('the monitors carry the pan', () {
      final repo = start()
        ..setMonitorInputMode(input: 0, mode: MonitorMode.on)
        ..setInputPan(input: 0, pan: 0.3);
      expect(repo.allMonitors()[0]!.pan, 0.3);
    });
  });

  group('the recorded image', () {
    test('a take fixes its input image; later input edits leave it', () {
      final repo = start()
        ..setMonitorVolume(input: 0, volume: 0.5)
        ..setInputPan(input: 0, pan: -0.25)
        ..record();
      expect(engine.lanePan[(0, 0)], -0.25);
      expect(engine.laneVol[(0, 0)], 1.0); // a mono input has no balance
      repo.setInputPan(input: 0, pan: 0.75);
      expect(engine.lanePan[(0, 0)], -0.25);
      expect(engine.monitorPan[0], 0.75);
    });

    test('a pair member records hard on its side at the balance gain', () {
      final repo = start()
        ..setLaneCount(channel: 0, count: 2)
        ..setLaneInput(channel: 0, lane: 1, inputChannel: 1)
        ..setInputPair(input: 0, paired: true)
        ..setPairBalance(input: 0, balance: -1)
        ..setVolume(0.5)
        ..record();
      expect(engine.lanePan[(0, 0)], -1.0);
      expect(engine.lanePan[(0, 1)], 1.0);
      expect(engine.laneVol[(0, 0)], 1.0);
      expect(engine.laneVol[(0, 1)], 0.0);
      // The whole-track gain is independent of both part levels and the
      // captured left/right image, so it is applied once after the part sum.
      expect(engine.trackLevels[0], 0.5);
      repo.setVolume(1);
      expect(engine.laneVol[(0, 0)], 1.0);
      expect(engine.laneVol[(0, 1)], 0.0);
      expect(engine.trackLevels[0], 1.0);
      // The projection shows the level, not the engine's product.
      expect(repo.state.tracks[0].volume, 1.0);
    });

    test('a fresh balanced take keeps its untouched live fader at unity', () {
      final repo = start()
        ..setInputPair(input: 0, paired: true)
        ..setPairBalance(input: 0, balance: 2 / 3)
        ..record();
      final native = engine.snapshot().tracks[0];
      expect(native.volume, 1.0);
      expect(native.lanes.single.volume, closeTo(0.5, 1e-15));
      // Save reads the lane projection; both fader projections remain unity.
      expect(repo.state.tracks[0].volume, 1.0);
      expect(repo.state.tracks[0].lanes.single.volume, 1.0);
      expect(repo.state.tracks[0].lanes.single.balance, closeTo(0.5, 1e-15));
      expect(repo.state.tracks[0].lanes.single.imagePan, -1);
    });

    test('a grown lane keeps its part level under independent track gain', () {
      final repo = start()
        ..setVolume(0.3)
        ..setLaneCount(channel: 0, count: 2);
      expect(engine.laneVol[(0, 1)], 1.0);
      expect(engine.trackLevels[0], 0.3);
      expect(repo.state.tracks[0].volume, 0.3);
    });

    test(
      'a lane added after the take gets the track pan and its own image',
      () {
        final repo = start()
          ..setTrackPan(-0.5)
          ..record();
        expect(engine.lanePan[(0, 0)], -0.5);
        repo
          ..setInputPan(input: 1, pan: 1)
          ..setLaneCount(channel: 0, count: 2)
          ..setLaneInput(channel: 0, lane: 1, inputChannel: 1);
        // Grown: the track pan lands on the new lane at once.
        expect(engine.lanePan[(0, 1)], -0.5);
        // Its first take (an overdub) fixes its image: 1 + (-0.5).
        repo.record();
        expect(engine.lanePan[(0, 1)], 0.5);
        // Lane 0 kept its own image.
        expect(engine.lanePan[(0, 0)], -0.5);
      },
    );

    test('a shrunk then regrown lane index carries no old image', () {
      final repo = start()
        ..setLaneCount(channel: 0, count: 2)
        ..setLaneInput(channel: 0, lane: 1, inputChannel: 1)
        ..setInputPair(input: 0, paired: true)
        ..setPairBalance(input: 0, balance: 1)
        ..record();
      expect(engine.laneVol[(0, 0)], 0.0); // Left silenced by the balance
      // Unlink future sources before shrinking to one side. The saved image
      // still carries its original pair balance until the lane is removed.
      expect(repo.setInputPair(input: 0, paired: false), EngineResult.ok);
      expect(engine.laneVol[(0, 0)], 0.0);
      expect(repo.setLaneCount(channel: 0, count: 1), EngineResult.ok);
      expect(repo.setLaneCount(channel: 0, count: 2), EngineResult.ok);
      expect(engine.laneVol[(0, 1)], 1.0);
      expect(engine.lanePan[(0, 1)], 0.0);
    });
  });

  test(
    'monitor gain refuses invalid intent without changing native or mix',
    () {
      final repo = start();
      final before = repo.mixSettingsSnapshot;
      engine.calls.clear();
      for (final value in [-0.1, 1.01, double.nan, double.infinity]) {
        expect(
          repo.setMonitorVolume(input: 0, volume: value),
          EngineResult.invalid,
        );
        expect(
          repo.applyMixSettings(before.copyWith(monitorLevels: {0: value})),
          EngineResult.invalid,
        );
      }
      expect(engine.calls, isEmpty);
      expect(repo.mixSettingsSnapshot, before);
    },
  );

  test('invalid session monitor gain cannot mutate the current rig', () async {
    final repo = start();
    final before = repo.mixSettingsSnapshot;
    final generation = repo.mixGeneration;
    final revision = repo.sessionRevision;
    engine.calls.clear();
    for (final value in [-0.1, 1.01, double.nan, double.infinity]) {
      await expectLater(
        repo.applySession(
          SessionRig(
            monitors: [
              SessionRigMonitor(
                input: 0,
                mode: MonitorMode.on,
                outputMask: 3,
                volume: value,
                muted: false,
                effects: const [],
              ),
            ],
          ),
        ),
        throwsStateError,
      );
    }
    expect(engine.calls, isEmpty);
    expect(repo.mixSettingsSnapshot, before);
    expect(repo.mixGeneration, generation);
    expect(repo.sessionRevision, revision);
  });

  group('applySession', () {
    test(
      'contradictory saved count refuses before replacing live audio',
      () async {
        final repo = start();
        final oldPcm = Float32List.fromList([.125, -.375, .5]);
        engine.importLayer(0, 0, 0, oldPcm);
        final before = repo.mixSettingsSnapshot;
        final generation = repo.mixGeneration;
        final revision = repo.sessionRevision;
        final rig = SessionRig(
          laneCounts: const {0: 1},
          tracks: [
            SessionRigTrack(
              channel: 0,
              lanes: [
                SessionRigLane(
                  lane: 1,
                  layers: [
                    Float32List.fromList([.75, -.25]),
                  ],
                  volume: 1,
                  muted: false,
                  outputMask: 3,
                  inputChannel: 1,
                ),
              ],
            ),
          ],
        );
        expect(() => MixSettingsSnapshot.fromRig(rig), throwsStateError);
        engine.calls.clear();
        await expectLater(repo.applySession(rig), throwsStateError);
        expect(engine.calls, isEmpty);
        expect(repo.mixSettingsSnapshot, before);
        expect(repo.mixGeneration, generation);
        expect(repo.sessionRevision, revision);
        expect(engine.importedLanes[(0, 0)], orderedEquals(oldPcm));
        expect(engine.importedLanes.keys, [(0, 0)]);
        // A matching explicit count, or an omitted count, remains restorable.
        expect(
          MixSettingsSnapshot.fromRig(
            SessionRig(tracks: rig.tracks, laneCounts: const {0: 2}),
          ).laneCounts[0],
          2,
        );
        expect(
          MixSettingsSnapshot.fromRig(
            SessionRig(tracks: rig.tracks),
          ).laneCounts[0],
          2,
        );
      },
    );

    test('empty-track gain stays separate from future lane levels', () {
      final fromRig = MixSettingsSnapshot.fromRig(
        const SessionRig(trackLevels: {7: .65}),
      );
      final withLane = fromRig.copyWith(laneLevels: const {(7, 0): .4});
      expect(fromRig.trackLevels, {7: .65});
      expect(fromRig.laneLevels, isEmpty);
      expect(withLane.trackLevels, {7: .65});
      expect(withLane.laneLevels, {(7, 0): .4});
      expect(withLane.isValid, isTrue);
      expect(MixSettingsSnapshot(trackLevels: const {7: 2.1}).isValid, isFalse);
    });

    test('restores track pans, lane images and the input setup', () async {
      final repo = start()
        ..setTrackPan(0.9, channel: 1)
        ..setTrackSolo(channel: 1, solo: true)
        ..setInputPan(input: 1, pan: 0.2)
        ..setOutputMute(bus: 0, muted: true);
      await repo.applySession(
        SessionRig(
          baseLengthFrames: 4,
          trackPans: const {0: -0.25},
          tracks: [
            SessionRigTrack(
              channel: 0,
              lanes: [
                SessionRigLane(
                  lane: 0,
                  layers: [
                    Float32List.fromList([.25, .25, .25, .25]),
                  ],
                  volume: 1,
                  muted: false,
                  outputMask: 0x3,
                  inputChannel: 0,
                  pan: -0.5,
                ),
              ],
            ),
          ],
          inputSetup: InputSetup(trimDb: const {0: -3}, pairs: const {0: 0.5}),
          outputSetup: const OutputSetup(buses: {1: OutputBus(level: 0.5)}),
        ),
        clearPollInterval: Duration.zero,
      );
      // The output setup is the rig's: bus 1's level in, the old mute gone.
      expect(engine.outputLevel[1], 0.5);
      expect(engine.outputMuted[0], isFalse);
      expect(
        repo.outputSetup,
        const OutputSetup(buses: {1: OutputBus(level: 0.5)}),
      );
      // The lane's saved image plus the restored track pan.
      expect(engine.lanePan[(0, 0)], -0.75);
      expect(repo.trackPan(0), -0.25);
      // Track 1's pan and solo went with the old rig.
      expect(repo.trackPan(1), 0);
      expect(repo.trackSoloed(1), isFalse);
      expect(engine.trackSolo[1], isFalse);
      // The input setup is the rig's: the trim to the engine, the pair onto
      // the monitors, the old mono pan gone.
      expect(
        repo.inputSetup,
        InputSetup(trimDb: const {0: -3}, pairs: const {0: 0.5}),
      );
      expect(engine.inputTrim[0], closeTo(0.7079, 1e-3));
      expect(engine.inputTrim[1], 1); // full recall clears old trim intent
      expect(engine.monitorPan[0], -1.0);
      expect(engine.monitorPan[1], 1.0);
      expect(engine.monitorVolume[0], closeTo(0.70710678, 1e-6));
      // Imported source facts need not match today's link settings. An
      // unrelated fader edit preserves them; a new source edit must be valid.
      expect(repo.setVolume(.7), EngineResult.ok);
      expect(repo.laneCount(0), 1);
      expect(repo.inputSetup.isPairLeft(0), isTrue);
    });

    test(
      'a lane balance the rig carries survives the next fader move',
      () async {
        final repo = start();
        await repo.applySession(
          SessionRig(
            baseLengthFrames: 4,
            tracks: [
              SessionRigTrack(
                channel: 0,
                lanes: [
                  SessionRigLane(
                    lane: 0,
                    layers: [
                      Float32List.fromList([.25, .25, .25, .25]),
                    ],
                    volume: 1,
                    muted: false,
                    outputMask: 0x3,
                    inputChannel: 0,
                    pan: -1,
                    balance: 0,
                  ),
                ],
              ),
            ],
          ),
          clearPollInterval: Duration.zero,
        );
        expect(engine.laneVol[(0, 0)], 0.0);
        expect(repo.state.tracks[0].volume, 1.0);
        repo
          ..setVolume(0.8)
          ..resetMixer();
        expect(engine.laneVol[(0, 0)], 0.0);
      },
    );
  });

  group('output setup (slice 3b)', () {
    test('publishes complete destination and retains hidden controls', () {
      final repo = start()
        ..setOutputLevel(bus: 1, level: .5)
        ..setOutputBalance(bus: 1, balance: -1)
        ..setOutputMute(bus: 1, muted: true)
        ..setOutputMono(bus: 1, mono: true);
      expect(
        repo.outputSetup.of(1),
        const OutputBus(
          level: .5,
          balance: -1,
          muted: true,
          mono: true,
        ),
      );
      expect(engine.outputLevel[1], .5);
      expect(engine.outputBalance[1], -1);
      repo
        ..setOutputMute(bus: 1, muted: false)
        ..setOutputMono(bus: 1, mono: false);
      expect(repo.outputSetup.of(1), const OutputBus(level: .5, balance: -1));
    });

    test('rejects invalid destination and values without publishing', () {
      final repo = start();
      final before = repo.mixSettingsSnapshot;
      engine.calls.clear();
      expect(
        repo.setOutputLevel(bus: kMaxOutputBuses, level: .5),
        EngineResult.invalid,
      );
      expect(repo.setOutputMute(bus: -1, muted: true), EngineResult.invalid);
      expect(repo.setOutputLevel(bus: 1, level: 2), EngineResult.invalid);
      expect(
        repo.setOutputBalance(bus: 1, balance: double.nan),
        EngineResult.invalid,
      );
      expect(repo.mixSettingsSnapshot, before);
      expect(engine.calls, isEmpty);
    });

    test('compound output controls remain confirmed until one ack', () async {
      final repo = start();
      engine
        ..publishMixCommands = false
        ..commandsAreSettled = false;
      const next = OutputSetup(
        buses: {
          1: OutputBus(
            level: .4,
            muted: true,
            mono: true,
            balance: -.7,
          ),
        },
      );
      expect(repo.setOutputSetup(next), EngineResult.ok);
      expect(repo.outputSetup, const OutputSetup());
      expect(repo.mixSettingsSnapshot.outputSetup, const OutputSetup());
      engine
        ..publishMix()
        ..commandsAreSettled = true;
      expect(await repo.settleMixSettings(), EngineResult.ok);
      expect(repo.outputSetup, next);
      expect(repo.mixSettingsSnapshot.outputSetup, next);
      engine.mixResult = EngineResult.invalid;
      expect(repo.setOutputSetup(const OutputSetup()), EngineResult.invalid);
      expect(repo.outputSetup, next);
    });

    test('is held while stopped and replayed on start', () {
      final repo = LooperRepository(engine: engine, ticker: ticker.stream)
        ..setOutputLevel(bus: 1, level: 0.5)
        ..setOutputMute(bus: 0, muted: true);
      addTearDown(repo.dispose);
      expect(engine.outputLevel, isEmpty);
      expect(repo.outputSetup.of(1).level, 0.5);
      repo.startEngine(const EngineConfig());
      expect(engine.outputLevel[1], 0.5);
      expect(engine.outputMuted[0], isTrue);
      expect(engine.outputMuted[1], isFalse);
    });

    test('setOutputSetup replaces the whole setup, resetting the '
        'destinations only the old one named', () {
      final repo = start()..setOutputMono(bus: 2, mono: true);
      engine.calls.clear();
      repo.setOutputSetup(const OutputSetup(buses: {1: OutputBus(level: 0.5)}));
      expect(engine.outputLevel[1], 0.5);
      expect(engine.outputMono[2], isFalse);
      // The whole-setup path pushes every fact of both setups' destinations,
      // so the one the new setup drops goes back to its defaults.
      expect(engine.outputLevel[2], 1.0);
      expect(engine.calls.where((c) => c == 'setMix'), hasLength(1));
      expect(repo.state.outputSetup.buses.keys, {1});
    });

    test('projects the destination count and the tail revision from the '
        'engine', () {
      final repo = start();
      engine.nextSnapshot = EngineSnapshot(
        isRunning: true,
        sampleRate: 48000,
        bufferFrames: 128,
        inputChannels: 2,
        outputChannels: 3,
        framesProcessed: 0,
        xrunCount: 0,
        inputRms: 0,
        inputPeak: 0,
        outputRms: 0,
        latencyState: le.LatencyState.idle,
        measuredLatencyMs: -1,
        outputBusCount: 2,
        tailResetRev: 3,
        tracks: [for (var i = 0; i < 8; i++) const TrackSnapshot.empty()],
      );
      ticker.add(null);
      expect(repo.state.outputBusCount, 2);
      expect(repo.state.tailResetRev, 3);
    });
  });

  group('destination masks (slice 3c)', () {
    test('a destination is the pair of jacks it drives', () {
      expect(outputBusMask(0, channels: 4), 0x3);
      expect(outputBusMask(1, channels: 4), 0xC);
      expect(outputBusMask(2, channels: 8), 0x30);
    });

    test('an odd-channel device ends on a single jack', () {
      // A five-out interface has no output 6, and a mask that claimed one
      // would ask the engine to drive a socket the rig has not got.
      expect(outputBusMask(2, channels: 5), 0x10);
      expect(outputBusMask(2, channels: 4), 0);
    });

    test('a destination past the rig drives nothing', () {
      expect(outputBusMask(9, channels: 4), 0);
      expect(outputBusMask(-1, channels: 4), 0);
    });

    test('what a route SETS is not what it CLEARS', () {
      // Setting must not claim a socket the interface has not got; clearing
      // must reach both jacks, or a route saved on a wider rig can never be
      // switched off on a narrower one.
      expect(outputBusMask(2, channels: 5), 0x10);
      expect(outputBusBits(2), 0x30);
      expect(0x30 & ~outputBusBits(2), 0);
      expect(0x30 & ~outputBusMask(2, channels: 5), 0x20);
      expect(outputBusBits(-1), 0);
    });

    test('EITHER jack of a pair means the destination is reached', () {
      // A mask that reaches half a pair still reaches the destination; read
      // as unselected, a card would offer to switch on what is already on.
      expect(outputMaskDrivesBus(0x1, 0), isTrue);
      expect(outputMaskDrivesBus(0x2, 0), isTrue);
      expect(outputMaskDrivesBus(0x3, 0), isTrue);
      expect(outputMaskDrivesBus(0x4, 0), isFalse);
      expect(outputMaskDrivesBus(0x8, 1), isTrue);
      expect(outputMaskDrivesBus(0x3, 1), isFalse);
      expect(outputMaskDrivesBus(0x3, -1), isFalse);
    });
  });

  group('OutputSetup maps (slice 3b)', () {
    test('round-trip through the one-map-per-fact form drops the '
        'destinations at their defaults', () {
      const setup = OutputSetup(
        buses: {
          1: OutputBus(level: 0.5, muted: true),
          0: OutputBus(mono: true, balance: -0.25),
        },
      );
      final maps = setup.toMaps();
      expect(maps.level, {1: 0.5});
      expect(maps.muted, {1: true});
      expect(maps.mono, {0: true});
      expect(maps.balance, {0: -0.25});
      expect(
        OutputSetup.fromMaps(
          level: maps.level,
          muted: maps.muted,
          mono: maps.mono,
          balance: maps.balance,
        ),
        setup,
      );
      expect(const OutputSetup().toMaps().level, isEmpty);
      expect(OutputSetup.fromMaps(), const OutputSetup());
    });
  });

  group('cut all sound (slice 3b)', () {
    test('reaches the engine while running and is a no-op while stopped', () {
      final stopped = LooperRepository(engine: engine, ticker: ticker.stream);
      addTearDown(stopped.dispose);
      expect(stopped.cutSound(), EngineResult.ok);
      expect(engine.cutSoundCalls, 0);
      final repo = start();
      expect(repo.cutSound(), EngineResult.ok);
      expect(engine.cutSoundCalls, 1);
    });
  });

  group('atomic routing proposals', () {
    test('public source and count edits cannot split an existing pair', () {
      final repo = start();
      expect(repo.setInputPair(input: 0, paired: true), EngineResult.ok);
      final before = repo.mixSettingsSnapshot;
      final revision = engine.mixRevision;
      engine.calls.clear();
      expect(
        repo.setLaneInput(channel: 0, lane: 1, inputChannel: -1),
        EngineResult.invalid,
      );
      expect(repo.setLaneCount(channel: 0, count: 1), EngineResult.invalid);
      expect(
        repo.applyMixSettings(
          before.copyWith(laneInputs: {...before.laneInputs, (0, 0): -1}),
        ),
        EngineResult.invalid,
      );
      expect(repo.mixSettingsSnapshot, before);
      expect(engine.mixRevision, revision);
      expect(engine.calls, isEmpty);
      // Removing the whole pair is valid and keeps the global link setting.
      expect(
        repo.applyMixSettings(
          before.copyWith(
            laneInputs: {...before.laneInputs, (0, 0): -1, (0, 1): -1},
          ),
        ),
        EngineResult.ok,
      );
      expect(repo.inputSetup.isPairLeft(0), isTrue);
    });

    test('either member expands the explicit pair with ordered identities', () {
      final repo = start();
      final base = repo.mixSettingsSnapshot.copyWith(
        inputSetup: InputSetup(pairs: const {0: 0}),
        laneInputs: const {(0, 0): -1},
      );
      for (final selected in [0, 1]) {
        final proposal = repo.prepareRecordingInputs(
          base,
          channel: 0,
          input: selected,
          selected: true,
        )!;
        expect(proposal.laneInputs[(0, 0)], 0);
        expect(proposal.laneInputs[(0, 1)], 1);
        expect(proposal.laneCounts[0], 2);
        expect(base.laneInputs[(0, 0)], -1);
      }
    });

    test('pair capacity refusal changes no track or pair fact', () {
      final repo = start();
      final before = repo.mixSettingsSnapshot.copyWith(
        laneCounts: const {1: 8},
        laneInputs: {
          (0, 0): 0,
          for (var lane = 0; lane < 8; lane++)
            (1, lane): lane == 0 ? 0 : lane + 1,
        },
      );
      expect(repo.prepareInputPair(before, input: 0, paired: true), isNull);
      expect(before.inputSetup.pairs, isEmpty);
      expect(before.laneCounts[1], 8);
      expect(repo.mixSettingsSnapshot.laneCounts, isEmpty);
    });

    test('a freed middle slot admits a missing partner without compaction', () {
      final repo = start();
      final before = repo.mixSettingsSnapshot.copyWith(
        laneCounts: const {0: 8},
        laneInputs: {
          for (var lane = 0; lane < 8; lane++)
            (0, lane): lane == 3
                ? -1
                : lane == 0
                ? 0
                : lane + 1,
        },
      );
      final proposal = repo.prepareInputPair(before, input: 0, paired: true)!;
      expect(proposal.laneCounts[0], 8);
      expect(proposal.laneInputs[(0, 3)], 1);
      expect(proposal.laneInputs[(0, 4)], 5);
      expect(before.laneInputs[(0, 3)], -1);
    });

    test('unpair keeps assignments and each saved mono pan', () {
      final repo = start();
      final before = repo.mixSettingsSnapshot.copyWith(
        inputSetup: InputSetup(
          pan: const {0: -.3, 1: .6},
          pairs: const {0: .2},
        ),
        laneCounts: const {0: 2},
        laneInputs: const {(0, 0): 0, (0, 1): 1},
      );
      final proposal = repo.prepareInputPair(before, input: 0, paired: false)!;
      expect(proposal.laneInputs, before.laneInputs);
      expect(proposal.inputSetup.effectivePanOf(0), -.3);
      expect(proposal.inputSetup.effectivePanOf(1), .6);
    });

    test('pending arm locks its track before any callback publication', () {
      final repo = start();
      engine
        ..publishRecordImages = false
        ..commandsAreSettled = false;
      expect(repo.record(), EngineResult.ok);
      final before = repo.mixSettingsSnapshot;
      expect(
        repo.prepareRecordingInputs(
          before,
          channel: 0,
          input: 1,
          selected: true,
        ),
        isNull,
      );
      expect(repo.prepareInputPair(before, input: 0, paired: true), isNull);
      expect(
        repo.prepareRecordingInputs(
          before,
          channel: 1,
          input: 1,
          selected: true,
        ),
        isNotNull,
      );
    });

    test(
      'route edit seeds every future lane and preserves detached intent',
      () {
        final repo = start();
        final before = repo.mixSettingsSnapshot.copyWith(
          laneOutputs: const {(0, 0): 1, (0, 1): 2},
        );
        final proposal = repo.prepareTrackOutput(before, channel: 0, mask: 2)!;
        for (var lane = 0; lane < 8; lane++) {
          expect(proposal.laneOutputs[(0, lane)], 2);
        }
        expect(before.laneOutputs[(0, 0)], 1);
        expect(proposal.laneCounts, before.laneCounts);
      },
    );

    test('missing destinations retain intent but cannot be newly selected', () {
      final repo = start();
      final before = repo.mixSettingsSnapshot.copyWith(
        laneOutputs: {
          for (var lane = 0; lane < 8; lane++) (0, lane): 0x81,
        },
      );
      expect(
        repo.prepareTrackOutput(before, channel: 0, mask: 0x80),
        isNotNull,
      );
      expect(repo.prepareTrackOutput(before, channel: 0, mask: 1), isNotNull);
      expect(repo.prepareTrackOutput(before, channel: 0, mask: 0x85), isNull);
    });

    test('missing source may be removed but cannot be re-added or paired', () {
      final repo = start();
      final before = repo.mixSettingsSnapshot.copyWith(
        laneInputs: const {(0, 0): 30},
      );
      final removed = repo.prepareRecordingInputs(
        before,
        channel: 0,
        input: 30,
        selected: false,
      )!;
      expect(removed.laneInputs[(0, 0)], -1);
      expect(
        repo.prepareRecordingInputs(
          removed,
          channel: 0,
          input: 30,
          selected: true,
        ),
        isNull,
      );
      expect(repo.prepareInputPair(before, input: 30, paired: true), isNull);
    });
  });

  group('InputSetup', () {
    test('answers the image and the balance gain per input', () {
      final setup = InputSetup(pan: const {2: 0.4}, pairs: const {0: 1});
      expect(setup.pairOf(0), 0);
      expect(setup.pairOf(1), 0);
      expect(setup.pairOf(2), isNull);
      expect(setup.isPairLeft(0), isTrue);
      expect(setup.isPairRight(1), isTrue);
      expect(setup.effectivePanOf(0), -1);
      expect(setup.effectivePanOf(1), 1);
      expect(setup.effectivePanOf(2), 0.4);
      expect(setup.balanceGainOf(0), 0); // balance 1 = Right only
      expect(setup.balanceGainOf(1), 1);
      expect(setup.balanceGainOf(2), 1);
      expect(inputTrimGainOfDb(-6), closeTo(0.5012, 1e-3));
      // The same constants the engine's pan law pins in the native
      // test_lane_pan_law (half pan: the far side at cos(pi/4)).
      final half = InputSetup(pairs: const {0: 0.5});
      expect(half.balanceGainOf(0), closeTo(0.70710678, 1e-6));
      expect(half.balanceGainOf(1), 1);
      final mirror = InputSetup(pairs: const {0: -0.5});
      expect(mirror.balanceGainOf(0), 1);
      expect(mirror.balanceGainOf(1), closeTo(0.70710678, 1e-6));
    });
  });
}
