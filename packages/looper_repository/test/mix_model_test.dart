import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno_engine/segno_engine.dart'
    show EngineSnapshot, LaneSnapshot, TrackSnapshot;
import 'package:segno_engine/segno_engine.dart' as le show LatencyState;

import 'helpers/fake_audio_engine.dart';

/// A running two-input, two-output rig with [count] empty tracks.
EngineSnapshot _rig(
  int count, {
  TrackState state = TrackState.empty,
  bool pending = false,
}) => EngineSnapshot(
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
      expect(engine.trackSolo, {0: false, 1: true});
      repo
        ..setTrackSolo(channel: 0, solo: true)
        ..clearSolo();
      expect(engine.trackSolo, {0: false, 1: false});
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
      expect(engine.lanePan[(2, 0)], isNull);
    });

    test('returns levels and pans, keeps mute and solo', () {
      final repo = start()
        ..setVolume(0.4)
        ..setTrackPan(0.7)
        ..setMute(muted: true)
        ..setTrackSolo(channel: 1, solo: true)
        ..resetMixer();
      expect(engine.laneVol[(0, 0)], 1.0);
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
      expect(engine.laneVol[(0, 0)], 0.5);
      expect(engine.laneVol[(0, 1)], 0.0);
      // The track fader keeps the image: both lanes scale together.
      repo.setVolume(1);
      expect(engine.laneVol[(0, 0)], 1.0);
      expect(engine.laneVol[(0, 1)], 0.0);
      // The projection shows the level, not the engine's product.
      expect(repo.state.tracks[0].volume, 1.0);
    });

    test('a fresh balanced take keeps its untouched live fader at unity', () {
      final repo = start()
        ..setInputPair(input: 0, paired: true)
        ..setPairBalance(input: 0, balance: 2 / 3)
        ..record();
      final native = engine.snapshot().tracks[0];
      expect(native.volume, closeTo(0.5, 1e-15));
      expect(native.lanes.single.volume, closeTo(0.5, 1e-15));
      // Save reads the lane projection; both fader projections remain unity.
      expect(repo.state.tracks[0].volume, 1.0);
      expect(repo.state.tracks[0].lanes.single.volume, 1.0);
      expect(repo.state.tracks[0].lanes.single.balance, closeTo(0.5, 1e-15));
      expect(repo.state.tracks[0].lanes.single.imagePan, -1);
    });

    test('a grown lane takes the track level too', () {
      final repo = start()
        ..setVolume(0.3)
        ..setLaneCount(channel: 0, count: 2);
      expect(engine.laneVol[(0, 1)], 0.3);
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
      repo
        ..setLaneCount(channel: 0, count: 1)
        ..setLaneCount(channel: 0, count: 2);
      expect(engine.laneVol[(0, 1)], 1.0);
      expect(engine.lanePan[(0, 1)], 0.0);
    });
  });

  group('applySession', () {
    test('restores track pans, lane images and the input setup', () async {
      final repo = start()
        ..setTrackPan(0.9, channel: 1)
        ..setTrackSolo(channel: 1, solo: true)
        ..setInputPan(input: 1, pan: 0.2);
      await repo.applySession(
        SessionRig(
          baseLengthFrames: 4,
          trackPans: const {0: -0.25},
          tracks: const [
            SessionRigTrack(
              channel: 0,
              lanes: [
                SessionRigLane(
                  lane: 0,
                  layers: [],
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
        ),
        clearPollInterval: Duration.zero,
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
    });

    test(
      'a lane balance the rig carries survives the next fader move',
      () async {
        final repo = start();
        await repo.applySession(
          const SessionRig(
            baseLengthFrames: 4,
            tracks: [
              SessionRigTrack(
                channel: 0,
                lanes: [
                  SessionRigLane(
                    lane: 0,
                    layers: [],
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

  group('MixTarget', () {
    test('round-trips through its canonical string', () {
      const target = MixTarget.pairBalance(4);
      expect(target.canonicalString(), '{"target":"pairBalance","index":4}');
      expect(MixTarget.tryParse(target.canonicalString()), target);
      expect(MixTarget.tryParse('{"target":"nothing","index":1}'), isNull);
      expect(MixTarget.tryParse('{"target":"trackPan","index":"x"}'), isNull);
      expect(MixTarget.tryParse('not json'), isNull);
      expect(
        MixTarget.fromJson({'target': 'trackPan', 'index': 2, 'extra': 1}),
        const MixTarget.trackPan(2),
      );
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
