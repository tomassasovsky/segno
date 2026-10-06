@Tags(['fuzz'])
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno_engine/segno_engine.dart' show PumpedNativeEngine;

/// One actual-native Peel journey through the repository (#1164 Part 1):
/// the fixture of fade_native_test plus one overdub pass, so the track holds
/// an original (0.5) and one layer (0.75).
void main() {
  final library = Platform.environment['SEGNO_ENGINE_LIB'];
  final skip = library == null || library.isEmpty
      ? 'Build packages/segno_engine/tool/build_test_lib.sh and set SEGNO_ENGINE_LIB'
      : null;
  late PumpedNativeEngine engine;
  late LooperRepository repository;
  late StreamController<void> ticks;

  /// Pumps whole loops until the retired pass has landed on the history.
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
    expect(engine.record(), EngineResult.ok); // punch in
    engine.pump(frames: 128, input: .25); // one complete pass
    expect(engine.record(), EngineResult.ok); // punch out
    engine.pump(frames: 0);
    settleLayer();
  });
  tearDown(() async {
    await repository.dispose();
    await ticks.close();
  });

  test(
    'peel removes the newest layer synchronously; the projection and Undo '
    'follow',
    () async {
      final subscription = repository.looperState.listen((_) {});
      addTearDown(subscription.cancel);
      await Future<void>.delayed(Duration.zero);
      ticks.add(null);
      var track = repository.state.tracks[0];
      expect(track.undoDepth, 1);
      expect(track.peelDepth, 1);
      expect(track.canPeel, isTrue);
      expect(track.layers, 2);
      expect(engine.exportTrack(0), everyElement(closeTo(.75, 1e-6)));

      expect(repository.peel(), EngineResult.ok);
      // The swap is complete when the call returns: no callback needed.
      expect(engine.exportTrack(0), everyElement(closeTo(.5, 1e-6)));
      ticks.add(null);
      track = repository.state.tracks[0];
      expect(track.undoDepth, 1); // the PEEL entry keeps the undo depth
      expect(track.peelDepth, 0);
      expect(track.canPeel, isFalse);
      expect(track.layers, 1);
      expect(track.redoDepth, 0);
      expect(track.state, TrackState.playing);

      // The original is protected: nothing remains to peel.
      expect(repository.peel(), EngineResult.invalid);
      expect(engine.exportTrack(0), everyElement(closeTo(.5, 1e-6)));

      // Undo restores the layer; the badge follows.
      expect(repository.undo(), EngineResult.ok);
      expect(engine.exportTrack(0), everyElement(closeTo(.75, 1e-6)));
      ticks.add(null);
      track = repository.state.tracks[0];
      expect(track.peelDepth, 1);
      expect(track.canPeel, isTrue);
      expect(track.layers, 2);
      expect(track.redoDepth, 1);

      // Redo re-peels.
      expect(repository.redo(), EngineResult.ok);
      expect(engine.exportTrack(0), everyElement(closeTo(.5, 1e-6)));
      ticks.add(null);
      expect(repository.state.tracks[0].layers, 1);
    },
    skip: skip,
  );

  test(
    'an undone peel survives save and stopped recall: Redo re-peels and Undo '
    'restores the layer (#1164 Part 2)',
    () async {
      expect(repository.peel(), EngineResult.ok); // live .5, [PEEL(.75)]
      expect(repository.undo(), EngineResult.ok); // live .75, [L(.5)], [M]

      // Save: what the Session capture reads. The redo-side marker holds no
      // image, so two images carry three positions of history.
      final saved = engine.snapshot().tracks[0];
      expect(saved.undoDepth, 1);
      expect(saved.redoDepth, 1);
      final history = engine.exportHistory(0);
      expect(
        history,
        const TrackHistory([
          HistoryEntry(HistoryKind.layer),
          HistoryEntry(HistoryKind.peel),
        ], undoCount: 1),
      );
      final images = history.imageCount;
      expect(images, 2);
      final layers = [
        for (var o = 0; o < images; o++) engine.exportLayer(0, 0, o),
      ];
      expect(engine.exportLayer(0, 0, images), isEmpty);
      final original = layers[0];
      final layered = layers[1];
      expect(original.first, .5);
      expect(layered.first, .75);

      // Recall, stopped, into the same engine (the Session load replaces the
      // material).
      final rig = SessionRig(
        baseLengthFrames: 128,
        tracks: [
          SessionRigTrack(
            fadeAmount: 1,
            channel: 0,
            lanes: [
              SessionRigLane(
                lane: 0,
                layers: layers,
                volume: 1,
                muted: false,
                outputMask: 1,
                inputChannel: 0,
                history: history,
              ),
            ],
          ),
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
      var recalled = engine.snapshot().tracks[0];
      expect(recalled.state, TrackState.stopped);
      expect(recalled.undoDepth, 1);
      expect(recalled.redoDepth, 1);
      expect(recalled.peelDepth, 1);
      expect(engine.exportHistory(0), history);
      expect(engine.exportTrack(0).first, layered.first);
      expect(engine.exportTrack(0), layered);

      // Redo re-peels: the original plays and nothing remains to peel.
      expect(repository.redo(), EngineResult.ok);
      expect(engine.exportTrack(0).first, original.first);
      expect(engine.exportTrack(0), original);
      recalled = engine.snapshot().tracks[0];
      expect(recalled.peelDepth, 0);
      expect(recalled.redoDepth, 0);
      expect(recalled.state, TrackState.stopped);
      expect(repository.peel(), EngineResult.invalid);

      // Undo restores the peeled layer.
      expect(repository.undo(), EngineResult.ok);
      expect(engine.exportTrack(0).first, layered.first);
      expect(engine.exportTrack(0), layered);
      recalled = engine.snapshot().tracks[0];
      expect(recalled.peelDepth, 1);
      expect(recalled.redoDepth, 1);
    },
    skip: skip,
  );

  test('peel is refused while the track overdubs and while a Session is '
      'being applied', () async {
    expect(engine.record(), EngineResult.ok); // punch in again
    engine.pump(frames: 4, input: .25);
    expect(repository.peel(), EngineResult.notReady);
    expect(engine.record(), EngineResult.ok); // punch out
    engine.pump(frames: 0);
    settleLayer();
    expect(engine.snapshot().tracks[0].peelDepth, 2);

    final rig = SessionRig(
      baseLengthFrames: 128,
      tracks: [
        SessionRigTrack(
          fadeAmount: 1,
          channel: 0,
          lanes: [
            SessionRigLane(
              lane: 0,
              layers: [Float32List.fromList(List.filled(128, .5))],
              volume: 1,
              muted: false,
              outputMask: 1,
              inputChannel: 0,
            ),
          ],
        ),
      ],
    );
    final callback = Timer.periodic(
      const Duration(milliseconds: 1),
      (_) => engine.pump(frames: 0),
    );
    try {
      final replaced = repository.applySession(rig);
      expect(repository.peel(), EngineResult.notReady);
      await replaced;
    } finally {
      callback.cancel();
    }
    // The loaded session has one layer and no history to peel.
    expect(repository.peel(), EngineResult.invalid);
  }, skip: skip);
}
