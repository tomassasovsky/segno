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
    // A ramp, so the first output sample names the index the track reads.
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
    'toggle confirms the callback receipt, projects direction and refuses '
    'the punch-in',
    () async {
      final subscription = repository.looperState.listen((_) {});
      addTearDown(subscription.cancel);
      await Future<void>.delayed(Duration.zero);
      engine.pump(frames: 37);
      final toggled = repository.toggleReverse(channel: 0);
      final empty = repository.toggleReverse(channel: 1);
      var completed = false;
      final completion = toggled.then((_) {
        completed = true;
      });
      await Future<void>.delayed(Duration.zero);
      expect(completed, isFalse); // queue acceptance is not the outcome
      engine.pump(frames: 1);
      expect(await toggled, EngineResult.ok);
      expect(await empty, EngineResult.invalid);
      await completion;
      // 128 frames is shorter than two turn windows, so the read snaps: the
      // toggle frame itself reads index 37, the index the turn continues from.
      expect(engine.snapshot().outputPeaks[0], closeTo(37 / 128, 1e-6));
      expect(engine.snapshot().tracks[0].reversed, isTrue);
      ticks.add(null);
      expect(repository.state.tracks[0].reversed, isTrue);
      expect(repository.record(), EngineResult.reversed);
      expect(engine.snapshot().tracks[0].state, TrackState.playing);
      final back = repository.toggleReverse(channel: 0);
      engine.pump(frames: 1);
      expect(await back, EngineResult.ok);
      ticks.add(null);
      expect(repository.state.tracks[0].reversed, isFalse);
      expect(repository.record(), EngineResult.ok);
      engine.pump(frames: 1);
      expect(engine.snapshot().tracks[0].state, TrackState.overdubbing);
    },
    skip: skip,
  );
}
