@Tags(['fuzz'])
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
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
          maxLoopFrames: 10000,
        ),
      ),
      EngineResult.ok,
    );
    engine.pump(frames: 0);
    // 0.1 s of a 220 Hz sine, a whole number of cycles, so the take loops.
    expect(
      engine.importTrack(
        0,
        Float32List.fromList(
          List.generate(
            4800,
            (i) => 0.5 * math.sin(2 * math.pi * 220 * i / 48000),
          ),
        ),
      ),
      EngineResult.ok,
    );
    expect(engine.commitSession(4800, loopBeats: 0), EngineResult.ok);
    expect(engine.play(), EngineResult.ok);
    engine.pump(frames: 0);
  });
  tearDown(() async {
    await repository.dispose();
    await ticks.close();
  });

  /// Completes [request] by pumping one block while its receipt is polled.
  Future<EngineResult> settle(Future<EngineResult> request) async {
    await Future<void>.delayed(Duration.zero);
    engine.pump(frames: 64);
    final result = await request;
    ticks.add(null);
    return result;
  }

  /// Plays (pumping and polling, so the cache worker's render is collected)
  /// until track 0 sounds [effective] semitones; false after five seconds.
  Future<bool> soundsAt(int effective) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (DateTime.now().isBefore(deadline)) {
      engine.pump(frames: 64);
      ticks.add(null);
      if (repository.state.tracks[0].transpose.effective == effective) {
        return true;
      }
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    return false;
  }

  test(
    'transposeTrack confirms the receipt, projects the pending dry pitch '
    'until the render lands, bypasses with the pitch kept, reports the limit '
    'and refuses punch-ins while transposed',
    () async {
      final subscription = repository.looperState.listen((_) {});
      addTearDown(subscription.cancel);
      await Future<void>.delayed(Duration.zero);
      engine.pump(frames: 64);
      final step = repository.transposeTrack(channel: 0, delta: 1);
      var completed = false;
      unawaited(step.then((_) => completed = true));
      await Future<void>.delayed(Duration.zero);
      expect(completed, isFalse); // queue acceptance is not the outcome
      expect(await settle(step), EngineResult.ok);
      // Stored at once; dry until the worker's render lands (100 ms settle).
      expect(repository.state.tracks[0].transpose, (stored: 1, effective: 0));
      expect(repository.record(), EngineResult.transformed);
      expect(engine.snapshot().tracks[0].state, TrackState.playing);
      expect(await soundsAt(1), isTrue);
      expect(repository.state.tracks[0].transpose, (stored: 1, effective: 1));
      // An empty track has nothing to transpose.
      expect(
        await settle(repository.transposeTrack(channel: 1, delta: 1)),
        EngineResult.invalid,
      );

      // Bypass plays dry with the pitch kept, and lifts the capture guard
      // only while it holds.
      expect(
        await settle(repository.setTransposeBypass(bypassed: true)),
        EngineResult.ok,
      );
      expect(repository.state.transposeBypass, isTrue);
      expect(repository.state.tracks[0].transpose, (stored: 1, effective: 0));
      expect(
        await settle(repository.setTransposeBypass(bypassed: false)),
        EngineResult.ok,
      );
      expect(repository.state.transposeBypass, isFalse);
      expect(await soundsAt(1), isTrue); // the render is still cached

      // The limit is a receipt, and nothing changes.
      expect(
        await settle(repository.installTranspose(channel: 0, semitones: 12)),
        EngineResult.ok,
      );
      expect(
        await settle(repository.transposeTrack(channel: 0, delta: 1)),
        EngineResult.capacity,
      );
      expect(repository.state.tracks[0].transpose.stored, 12);

      expect(
        await settle(repository.setTransposeBypass(bypassed: true)),
        EngineResult.ok,
      );
      expect(repository.record(), EngineResult.ok);
      engine.pump(frames: 1);
      expect(engine.snapshot().tracks[0].state, TrackState.overdubbing);
    },
    skip: skip,
  );
}
