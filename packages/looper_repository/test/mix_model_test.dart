import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno_engine/segno_engine.dart'
    show EngineSnapshot, TrackSnapshot;
import 'package:segno_engine/segno_engine.dart' as le show LatencyState;

import 'helpers/fake_audio_engine.dart';

/// A running two-input, two-output rig with [count] empty tracks.
EngineSnapshot _rig(int count) => EngineSnapshot(
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
  tracks: [for (var i = 0; i < count; i++) const TrackSnapshot.empty()],
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
      expect(engine.trackSolo, {1: true});
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

    test('is pushed while stopped and replayed on start', () {
      final repo = LooperRepository(engine: engine, ticker: ticker.stream)
        ..setInputTrimDb(input: 0, db: 6);
      addTearDown(repo.dispose);
      expect(engine.inputTrim[0], closeTo(1.995, 1e-3));
      engine.inputTrim.clear();
      repo.startEngine(const EngineConfig());
      expect(engine.inputTrim[0], closeTo(1.995, 1e-3));
    });
  });

  group('input pan and pairs', () {
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
      expect(repo.state.tracks[0].volume, isNotNull);
    });
  });

  group('applySession', () {
    test('restores track pans, lane images and the input setup', () async {
      final repo = start()
        ..setTrackPan(0.9, channel: 1)
        ..setTrackSolo(channel: 1, solo: true)
        ..setInputPan(input: 1, pan: 0.2);
      await repo.applySession(
        const SessionRig(
          baseLengthFrames: 4,
          tracks: [
            SessionRigTrack(
              channel: 0,
              pan: -0.25,
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
          inputSetup: InputSetup(trimDb: {0: -3}, pairs: {0: 0.5}),
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
        const InputSetup(trimDb: {0: -3}, pairs: {0: 0.5}),
      );
      expect(engine.inputTrim[0], closeTo(0.7079, 1e-3));
      expect(engine.inputTrim[1], 1.0);
      expect(engine.monitorPan[0], -1.0);
      expect(engine.monitorPan[1], 1.0);
      expect(engine.monitorVolume[0], closeTo(0.70710678, 1e-6));
    });
  });

  group('MixTarget', () {
    test('round-trips through its canonical string', () {
      const target = MixTarget.pairBalance(4);
      expect(target.canonicalString, '{"target":"pairBalance","index":4}');
      expect(MixTarget.parse(target.canonicalString), target);
      expect(MixTarget.parse('{"target":"nothing","index":1}'), isNull);
      expect(MixTarget.parse('{"target":"trackPan","index":"x"}'), isNull);
      expect(MixTarget.parse('not json'), isNull);
      expect(
        MixTarget.fromJson({'target': 'trackLevel', 'index': 2, 'extra': 1}),
        const MixTarget.trackLevel(2),
      );
    });
  });

  group('InputSetup', () {
    test('answers the image and the balance gain per input', () {
      const setup = InputSetup(pan: {2: 0.4}, pairs: {0: 1});
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
      expect(inputTrimDbOfGain(inputTrimGainOfDb(-12)), closeTo(-12, 1e-9));
      expect(inputTrimDbOfGain(0), kMinInputTrimDb);
    });
  });
}
