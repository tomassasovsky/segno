@Tags(['fuzz'])
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno_engine/segno_engine.dart' show PumpedNativeEngine;

/// One 4/4 bar at 120 BPM at 8 kHz; 21333 frames at 90 BPM.
const _rate = 8000;
const _bar = 16000;

void main() {
  final library = Platform.environment['SEGNO_ENGINE_LIB'];
  final skip = library == null || library.isEmpty
      ? 'Build packages/segno_engine/tool/build_test_lib.sh and set SEGNO_ENGINE_LIB'
      : null;
  late PumpedNativeEngine engine;
  late LooperRepository repository;
  late StreamController<void> ticks;

  setUp(() {
    engine = PumpedNativeEngine();
    ticks = StreamController<void>.broadcast(sync: true);
    repository = LooperRepository(engine: engine, ticker: ticks.stream);
    expect(
      repository.startEngine(
        const EngineConfig(
          sampleRate: _rate,
          inputChannels: 1,
          outputChannels: 1,
          maxLoopFrames: 4 * _bar,
        ),
      ),
      EngineResult.ok,
    );
    engine.pump(frames: 0);
    expect(
      engine.importTrack(
        0,
        Float32List.fromList(
          List.generate(
            _bar,
            (i) => 0.5 * math.sin(2 * math.pi * 220 * i / _rate),
          ),
        ),
      ),
      EngineResult.ok,
    );
    expect(engine.commitSession(_bar, loopBars: 1), EngineResult.ok);
    expect(
      engine.restoreTempo(bpm: 120, source: TempoSource.manual),
      EngineResult.ok,
    );
    expect(engine.play(), EngineResult.ok);
    engine.pump(frames: 0);
  });
  tearDown(() async {
    await repository.dispose();
    await ticks.close();
  });

  /// Pumps one block and polls, so receipts and renders are collected.
  Future<void> step() async {
    engine.pump(frames: 256);
    ticks.add(null);
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }

  test(
    'Follow tempo and Pitch reach the engine through receipts; a retime '
    'projects the recorded tempo, the follow state and the pitch truthfully',
    () async {
      final subscription = repository.looperState.listen((_) {});
      addTearDown(subscription.cancel);
      await step();
      expect(repository.state.recordedTempoBpm, 120);
      expect(repository.state.tempoFollow, TempoFollowState.noFollower);
      expect(
        repository.setFollowTempoSettings(
          defaultFollow: true,
          trackOverrides: const {},
        ),
        EngineResult.ok,
      );
      final follow = repository.settleFollowTempo();
      await step();
      expect(await follow, EngineResult.ok);
      // Pitch follows the speed on track 0 for now: no render.
      expect(
        repository.setPitchModeSettings(
          defaultMode: PitchMode.unchanged,
          trackOverrides: const {0: PitchMode.followsSpeed},
        ),
        EngineResult.ok,
      );
      final pitch = repository.settlePitchMode();
      await step();
      expect(await pitch, EngineResult.ok);
      ticks.add(null);
      expect(repository.state.defaultFollowTempo, isTrue);
      expect(repository.state.tempoFollow, TempoFollowState.retimes);
      expect(
        repository.state.tracks[0].pitchModeOverride,
        PitchMode.followsSpeed,
      );
      expect(engine.snapshot().followTempo, isTrue);
      expect(
        engine.snapshot().tracks[0].pitchModeOverride,
        PitchMode.followsSpeed,
      );
      expect(repository.setTempo(90), EngineResult.ok);
      await step();
      expect(engine.snapshot().masterLengthFrames, 21333);
      expect(repository.state.tracks[0].pitchEffectiveCents, -498);
      // Unchanged: the stretch render lands and the pitch is its own again.
      expect(
        repository.setPitchModeSettings(
          defaultMode: PitchMode.unchanged,
          trackOverrides: const {},
        ),
        EngineResult.ok,
      );
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (repository.state.tracks[0].pitchEffectiveCents != 0 &&
          DateTime.now().isBefore(deadline)) {
        await step();
      }
      expect(repository.state.tracks[0].pitchEffectiveCents, 0);
      expect(repository.state.tracks[0].pitchModeOverride, isNull);
      expect(repository.state.recordedTempoBpm, 120);
    },
    skip: skip,
  );

  test(
    'a Session recall of a retimed rig (#1179 Part 4b) commits the takes on '
    'the recorded master, retimes to the saved tempo, and installs the '
    'saved Follow vector even when it has no follower',
    () async {
      SessionRigTrack rigTrack(int channel, int frames, {int span = 0}) =>
          SessionRigTrack(
            channel: channel,
            fadeAmount: 1,
            reversed: false,
            spanFrames: span,
            lanes: [
              SessionRigLane(
                lane: 0,
                layers: [
                  Float32List.fromList(
                    List.generate(
                      frames,
                      (i) => 0.25 * math.sin(2 * math.pi * 220 * i / _rate),
                    ),
                  ),
                ],
                volume: 1,
                muted: false,
                outputMask: 1,
                inputChannel: 0,
              ),
            ],
          );
      // Recorded at 120 on one bar (16000); retimed to 90 (21333); track 1
      // laid down at 90, so its span is the retimed master.
      final rig = SessionRig(
        baseLengthFrames: 21333,
        loopBars: 1,
        tempoBpm: 90,
        tempoSource: TempoSource.manual,
        recordedTempoBpm: 120,
        recordedLengthFrames: _bar,
        defaultFollowTempo: false,
        trackPitchModeOverrides: const {1: PitchMode.followsSpeed},
        tracks: [rigTrack(0, _bar), rigTrack(1, 21333, span: 21333)],
      );
      final callback = Timer.periodic(
        const Duration(milliseconds: 1),
        (_) => engine.pump(frames: 0),
      );
      try {
        await repository.applySession(rig);
      } finally {
        callback.cancel();
      }
      final recalled = engine.snapshot();
      expect(recalled.masterLengthFrames, 21333);
      expect(recalled.tempoBpm, 90);
      expect(recalled.recordedTempoBpm, 120);
      expect(recalled.recordedLengthFrames, _bar);
      expect(recalled.tracks[0].spanFrames, _bar);
      expect(recalled.tracks[1].spanFrames, 21333);
      expect(recalled.tracks[0].lengthFrames, _bar);
      expect(recalled.tracks[1].lengthFrames, 21333);
      // The saved vector: nothing follows now. The takes keep the spans the
      // retime gave them, so turning Follow on reads each at its ratio.
      expect(recalled.followTempo, isFalse);
      expect(repository.defaultFollowTempo, isFalse);
      expect(recalled.tracks[1].pitchModeOverride, PitchMode.followsSpeed);
      expect(
        repository.setFollowTempoSettings(
          defaultFollow: true,
          trackOverrides: const {},
        ),
        EngineResult.ok,
      );
      await step();
      await step();
      expect(engine.snapshot().tracks[0].headRate, closeTo(0.75, 1e-3));
      expect(engine.snapshot().tracks[1].headRate, 1);
    },
    skip: skip,
  );
}
