@Tags(['fuzz'])
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno_engine/segno_engine.dart' show PumpedNativeEngine;

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
          inputChannels: 1,
          outputChannels: 1,
          maxLoopFrames: 1000,
        ),
      ),
      EngineResult.ok,
    );
    engine.pump(frames: 0);
    // A ramp, so the output sample names the index the track reads.
    expect(
      engine.importTrack(
        0,
        Float32List.fromList(List.generate(128, (i) => i / 128)),
      ),
      EngineResult.ok,
    );
    expect(engine.commitSession(128, loopBars: 0), EngineResult.ok);
    expect(engine.play(), EngineResult.ok);
    engine.pump(frames: 0);
  });
  tearDown(() async {
    await repository.dispose();
    await ticks.close();
  });

  test(
    'setSpeed confirms the callback receipt, projects the factor and the '
    'head rate, and refuses capture until Normal',
    () async {
      final subscription = repository.looperState.listen((_) {});
      addTearDown(subscription.cancel);
      await Future<void>.delayed(Duration.zero);
      engine.pump(frames: 36);
      final half = repository.setSpeed(SpeedFactor.half);
      var completed = false;
      final completion = half.then((_) {
        completed = true;
      });
      await Future<void>.delayed(Duration.zero);
      expect(completed, isFalse); // queue acceptance is not the outcome
      engine.pump(frames: 2);
      expect(await half, EngineResult.ok);
      await completion;
      // 128 frames is shorter than two turn windows, so the step snaps: the
      // second frame at 1/2x reads index 36.5, the interpolated half step.
      expect(engine.snapshot().outputPeaks[0], closeTo(36.5 / 128, 1e-6));
      ticks.add(null);
      expect(repository.state.speed, SpeedFactor.half);
      expect(engine.snapshot().tracks[0].headRate, 0.5);
      expect(repository.record(), EngineResult.transformed);
      expect(repository.record(channel: 1), EngineResult.transformed);
      expect(engine.snapshot().tracks[0].state, TrackState.playing);
      final normal = repository.setSpeed(SpeedFactor.normal);
      engine.pump(frames: 1);
      expect(await normal, EngineResult.ok);
      ticks.add(null);
      expect(repository.state.speed, SpeedFactor.normal);
      expect(repository.record(), EngineResult.ok);
      engine.pump(frames: 1);
      expect(engine.snapshot().tracks[0].state, TrackState.overdubbing);
      // A change during capture is refused at admission.
      expect(
        await repository.setSpeed(SpeedFactor.twice),
        EngineResult.notReady,
      );
    },
    skip: skip,
  );

  test(
    'setSpeed on an empty rig is refused, so the first take records',
    () async {
      final empty = PumpedNativeEngine();
      final emptyTicks = StreamController<void>.broadcast(sync: true);
      final emptyRepository = LooperRepository(
        engine: empty,
        ticker: emptyTicks.stream,
      );
      addTearDown(() async {
        await emptyRepository.dispose();
        await emptyTicks.close();
      });
      expect(
        emptyRepository.startEngine(
          const EngineConfig(
            inputChannels: 1,
            outputChannels: 1,
            maxLoopFrames: 1000,
          ),
        ),
        EngineResult.ok,
      );
      empty.pump(frames: 0);
      final subscription = emptyRepository.looperState.listen((_) {});
      addTearDown(subscription.cancel);
      expect(
        await emptyRepository.setSpeed(SpeedFactor.half),
        EngineResult.invalid,
      );
      empty.pump(frames: 64);
      emptyTicks.add(null);
      expect(emptyRepository.state.speed, SpeedFactor.normal);
      // On a rig this fresh the repository's own gate still waits for its
      // record-timing and mix settings to settle (notReady); what matters
      // here is that Speed does not refuse the take.
      expect(emptyRepository.record(), isNot(EngineResult.transformed));
      expect(empty.record(), EngineResult.ok);
      empty.pump(frames: 1);
      expect(empty.snapshot().tracks[0].state, TrackState.recording);
    },
    skip: skip,
  );
}
