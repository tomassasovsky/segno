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
}
