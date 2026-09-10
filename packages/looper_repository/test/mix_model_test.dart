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

    test('a fresh take from a balanced pair projects and saves the level', () {
      final repo = start()
        ..setInputPair(input: 0, paired: true)
        ..setPairBalance(input: 0, balance: 0.5)
        ..record();
      expect(engine.laneVol[(0, 0)], closeTo(0.70710678, 1e-6));
      // The projection shows the level the take was given, not the gain.
      expect(repo.state.tracks[0].volume, 1.0);
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
        ..setInputPan(input: 1, pan: 0.2)
        ..setOutputMute(bus: 0, muted: true);
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
          outputSetup: OutputSetup(buses: {1: OutputBus(level: 0.5)}),
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
        const InputSetup(trimDb: {0: -3}, pairs: {0: 0.5}),
      );
      expect(engine.inputTrim[0], closeTo(0.7079, 1e-3));
      expect(engine.inputTrim[1], isNull); // named by neither setup
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

  group('output setup (slice 3b)', () {
    test('pushes only the edited fact, clamps and projects', () {
      final repo = start()
        ..setOutputLevel(bus: 1, level: 2)
        ..setOutputBalance(bus: 1, balance: -3);
      expect(engine.outputLevel[1], 1.0);
      expect(engine.outputBalance[1], -1.0);
      // A level ride must not re-post the mute and Mono behind it.
      expect(engine.outputMuted.containsKey(1), isFalse);
      expect(engine.outputMono.containsKey(1), isFalse);
      expect(engine.outputLevel.containsKey(0), isFalse);
      expect(repo.state.outputSetup.of(1), const OutputBus(balance: -1));
      repo
        ..setOutputMute(bus: 0, muted: true)
        ..setOutputMono(bus: 0, mono: true);
      expect(engine.outputMuted[0], isTrue);
      expect(engine.outputMono[0], isTrue);
      expect(repo.outputSetup.buses.keys, {0, 1});
      // Back to the defaults: the entry goes.
      repo
        ..setOutputBalance(bus: 1, balance: 0)
        ..setOutputMute(bus: 0, muted: false)
        ..setOutputMono(bus: 0, mono: false);
      expect(repo.outputSetup, const OutputSetup());
      expect(engine.outputBalance[1], 0.0);
    });

    test('rejects a destination the engine cannot address', () {
      final repo = start();
      expect(
        repo.setOutputLevel(bus: kMaxOutputBuses, level: 0.5),
        EngineResult.invalid,
      );
      expect(repo.setOutputMute(bus: -1, muted: true), EngineResult.invalid);
      expect(engine.outputLevel, isEmpty);
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
      expect(engine.calls.where((c) => c == 'setOutputLevel'), hasLength(2));
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
        tracks: [for (var i = 0; i < 2; i++) const TrackSnapshot.empty()],
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
      expect(inputTrimGainOfDb(-6), closeTo(0.5012, 1e-3));
      // The same constants the engine's pan law pins in the native
      // test_lane_pan_law (half pan: the far side at cos(pi/4)).
      const half = InputSetup(pairs: {0: 0.5});
      expect(half.balanceGainOf(0), closeTo(0.70710678, 1e-6));
      expect(half.balanceGainOf(1), 1);
      const mirror = InputSetup(pairs: {0: -0.5});
      expect(mirror.balanceGainOf(0), 1);
      expect(mirror.balanceGainOf(1), closeTo(0.70710678, 1e-6));
    });
  });
}
