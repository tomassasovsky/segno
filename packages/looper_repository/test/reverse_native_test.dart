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
    expect(engine.commitSession(128, loopBeats: 0), EngineResult.ok);
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

  Future<void> reverseTrack0() async {
    final result = repository.toggleReverse(channel: 0);
    engine.pump(frames: 1);
    expect(await result, EngineResult.ok);
  }

  /// One block, then the repository's own projection of track 0.
  Track track0() {
    engine.pump(frames: 1);
    ticks.add(null);
    return repository.state.tracks[0];
  }

  test(
    'direction dies with the material: undo to empty, redo from empty, '
    'Clear and its undo all read forward',
    () async {
      final subscription = repository.looperState.listen((_) {});
      addTearDown(subscription.cancel);
      await Future<void>.delayed(Duration.zero);
      await reverseTrack0();
      expect(track0().reversed, isTrue);

      expect(repository.undo(), EngineResult.ok);
      expect(track0().hasContent, isFalse);
      expect(track0().reversed, isFalse);
      expect(repository.redo(), EngineResult.ok);
      expect(track0().hasContent, isTrue);
      expect(track0().reversed, isFalse);

      await reverseTrack0();
      expect(track0().reversed, isTrue);
      expect(repository.clear(), EngineResult.ok);
      expect(track0().hasContent, isFalse);
      expect(track0().reversed, isFalse);
      for (var i = 0; i < 20 && !track0().hasContent; i++) {
        repository.undo();
        await Future<void>.delayed(Duration.zero);
      }
      expect(track0().hasContent, isTrue);
      expect(track0().reversed, isFalse);
    },
    skip: skip,
  );

  test(
    'a Session recall installs direction before the stopped commit: Play '
    'reads the reversed track from its lap start, the forward one from 0',
    () async {
      SessionRigTrack rigTrack(
        int channel,
        List<double> pcm, {
        required bool reversed,
      }) => SessionRigTrack(
        fadeAmount: 1,
        channel: channel,
        reversed: reversed,
        lanes: [
          SessionRigLane(
            lane: 0,
            layers: [Float32List.fromList(pcm)],
            volume: 1,
            muted: false,
            outputMask: 1,
            inputChannel: 0,
          ),
        ],
      );
      final rig = SessionRig(
        baseLengthFrames: 128,
        tracks: [
          rigTrack(0, [for (var i = 0; i < 128; i++) i / 256], reversed: true),
          rigTrack(1, [
            for (var i = 0; i < 128; i++) .25 + i / 1024,
          ], reversed: false),
        ],
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
      final recalled = engine.snapshot().tracks;
      expect(recalled[0].state, TrackState.stopped);
      expect(recalled[1].state, TrackState.stopped);
      expect(recalled[0].reversed, isTrue);
      expect(recalled[1].reversed, isFalse);
      expect(repository.play(), EngineResult.ok);
      engine.pump(frames: 0);
      // Reversed track 0 reads 127, 126, ...; forward track 1 reads 0, 1, ...
      for (var k = 0; k < 3; k++) {
        engine.pump(frames: 1);
        expect(
          engine.snapshot().outputPeaks[0],
          closeTo((127 - k) / 256 + .25 + k / 1024, 1e-5),
          reason: 'frame $k',
        );
      }
    },
    skip: skip,
  );
}
