@Tags(['fuzz'])
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno_engine/segno_engine.dart' show PumpedNativeEngine;

/// The accepted journey (accepted-behavior.md, verification journeys):
/// Record, overdub passes, Divide, Peel, Undo and Redo, through the
/// repository against the actual native engine (#1168 Part 3). One sole
/// 128-frame take (0.5) with two passes (+0.25 each), no bar grid.
void main() {
  final library = Platform.environment['SEGNO_ENGINE_LIB'];
  final skip = library == null || library.isEmpty
      ? 'Build packages/segno_engine/tool/build_test_lib.sh and set SEGNO_ENGINE_LIB'
      : null;
  late PumpedNativeEngine engine;
  late LooperRepository repository;
  late StreamController<void> ticks;
  late Timer callback;

  void settleLayer() {
    for (var i = 0; i < 16; i++) {
      engine.pump(frames: 128);
      if (!engine.snapshot().tracks[0].layerInFlight) return;
    }
    fail('the overdub pass never retired');
  }

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
    expect(
      engine.importTrack(0, Float32List.fromList(List.filled(128, .5))),
      EngineResult.ok,
    );
    expect(engine.commitSession(128, loopBeats: 0), EngineResult.ok);
    expect(engine.play(), EngineResult.ok);
    engine.pump(frames: 0);
    for (var pass = 0; pass < 2; pass++) {
      expect(engine.record(), EngineResult.ok); // punch in
      engine.pump(frames: 128, input: .25); // one complete pass
      expect(engine.record(), EngineResult.ok); // punch out
      engine.pump(frames: 0);
      settleLayer();
    }
  });
  tearDown(() async {
    callback.cancel();
    await repository.dispose();
    await ticks.close();
  });

  Future<Track> settle(bool Function(Track track) done) async {
    for (var i = 0; i < 100; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
      ticks.add(null);
      if (done(repository.state.tracks[0])) break;
    }
    return repository.state.tracks[0];
  }

  test(
    'Divide bakes the passes into the kept half; Peel then has nothing to '
    'remove until Undo restores the full length and its layers',
    () async {
      callback = Timer.periodic(
        const Duration(milliseconds: 1),
        (_) => engine.pump(frames: 0),
      );
      final subscription = repository.looperState.listen((_) {});
      addTearDown(subscription.cancel);
      var track = await settle((t) => t.layers == 3);
      expect(track.layers, 3);
      expect(engine.exportTrack(0), everyElement(closeTo(1, 1e-6)));

      // Divide: the sole track re-clocks to its last half.
      expect(
        await repository.editLength(channel: 0, edit: LengthEdit.lastHalf),
        EngineResult.ok,
      );
      track = await settle((t) => t.lengthFrames == 64);
      expect(track.lengthFrames, 64);
      expect(engine.snapshot().masterLengthFrames, 64);
      expect(engine.exportTrack(0), everyElement(closeTo(1, 1e-6)));
      // The kept half is one image: no overdub layer sits above the edit.
      expect(track.layers, 1);
      expect(track.canPeel, isFalse);
      expect(repository.peel(), isNot(EngineResult.ok));

      // Undo puts back the full length with both passes.
      expect(repository.undo(), EngineResult.ok);
      track = await settle((t) => t.lengthFrames == 128);
      expect(track.lengthFrames, 128);
      expect(track.layers, 3);
      expect(engine.snapshot().masterLengthFrames, 128);

      // Peel removes the newest pass; Undo and Redo move it like any layer.
      expect(repository.peel(), EngineResult.ok);
      expect(engine.exportTrack(0), everyElement(closeTo(.75, 1e-6)));
      expect(repository.undo(), EngineResult.ok);
      track = await settle((t) => t.layers == 3);
      expect(engine.exportTrack(0), everyElement(closeTo(1, 1e-6)));
      expect(repository.redo(), EngineResult.ok);
      track = await settle((t) => t.layers == 2);
      expect(track.layers, 2);
      expect(engine.exportTrack(0), everyElement(closeTo(.75, 1e-6)));
      // The Divide was retired from Redo by the Peel: Redo has no length to
      // put back, and the track keeps its full length.
      expect(track.lengthFrames, 128);
    },
    skip: skip,
  );
}
