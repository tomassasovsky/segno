@Tags(['fuzz'])
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno_engine/segno_engine.dart' show PumpedNativeEngine;

/// One actual-native length edit through the repository (#1168 Part 1): two
/// imported 128-frame tracks (Multi, so neither re-clocks the rig), the
/// second positional so the kept image is identifiable.
void main() {
  final library = Platform.environment['SEGNO_ENGINE_LIB'];
  final skip = library == null || library.isEmpty
      ? 'Build packages/segno_engine/tool/build_test_lib.sh and set SEGNO_ENGINE_LIB'
      : null;
  late PumpedNativeEngine engine;
  late LooperRepository repository;
  late StreamController<void> ticks;
  late Timer callback;
  final positional = Float32List.fromList([
    for (var i = 0; i < 128; i++) (i + 1) / 128,
  ]);

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
    expect(engine.importTrack(1, positional), EngineResult.ok);
    expect(engine.commitSession(128, loopBeats: 0), EngineResult.ok);
    expect(engine.play(), EngineResult.ok);
    engine.pump(frames: 0);
    // The callback answers the receipt while the test awaits it.
    callback = Timer.periodic(
      const Duration(milliseconds: 1),
      (_) => engine.pump(frames: 0),
    );
  });
  tearDown(() async {
    callback.cancel();
    await repository.dispose();
    await ticks.close();
  });

  test(
    'a Double completes with the callback receipt; the projection follows '
    'and undo restores the length',
    () async {
      final subscription = repository.looperState.listen((_) {});
      addTearDown(subscription.cancel);
      await Future<void>.delayed(Duration.zero);

      expect(
        await repository.editLength(channel: 1, edit: LengthEdit.doubled),
        EngineResult.ok,
      );
      ticks.add(null);
      var track = repository.state.tracks[1];
      expect(track.lengthFrames, 256);
      expect(track.multiple, 2);
      expect(track.syncDivisor, 0);
      expect(track.undoDepth, 1);
      expect(track.peelDepth, 0);
      final doubled = engine.exportTrack(1);
      expect(doubled.sublist(0, 128), positional);
      expect(doubled.sublist(128), positional);

      // A half base is not a Multi span next to track 0.
      expect(
        await repository.editLength(channel: 0, edit: LengthEdit.firstHalf),
        EngineResult.modeMismatch,
      );

      expect(
        await repository.editLength(channel: 1, edit: LengthEdit.lastHalf),
        EngineResult.ok,
      );
      ticks.add(null);
      track = repository.state.tracks[1];
      expect(track.lengthFrames, 128);
      expect(track.multiple, 1);
      expect(track.undoDepth, 2);

      // Undo is a posted command: the projection follows once it lands.
      expect(repository.undo(channel: 1), EngineResult.ok);
      for (var i = 0; i < 50; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
        ticks.add(null);
        if (repository.state.tracks[1].lengthFrames == 256) break;
      }
      track = repository.state.tracks[1];
      expect(track.lengthFrames, 256);
      expect(track.multiple, 2);
      expect(track.redoDepth, 1);
      expect(engine.exportTrack(1), doubled);
    },
    skip: skip,
  );

  test(
    'length edits survive save and recall: Redo and Undo put back each '
    'image at its own length (#1168 Part 2)',
    () async {
      final subscription = repository.looperState.listen((_) {});
      addTearDown(subscription.cancel);
      await Future<void>.delayed(Duration.zero);
      Future<void> settle(int lengthFrames) async {
        for (var i = 0; i < 50; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 2));
          ticks.add(null);
          if (engine.snapshot().tracks[1].lengthFrames == lengthFrames) break;
        }
        expect(engine.snapshot().tracks[1].lengthFrames, lengthFrames);
      }

      expect(
        await repository.editLength(channel: 1, edit: LengthEdit.doubled),
        EngineResult.ok,
      );
      final doubled = engine.exportTrack(1);
      expect(
        await repository.editLength(channel: 1, edit: LengthEdit.lastHalf),
        EngineResult.ok,
      );
      expect(repository.undo(channel: 1), EngineResult.ok);
      await settle(256);

      // Save: each image at its own length, each edit with its map.
      final history = engine.exportHistory(1);
      expect(
        history,
        const TrackHistory([
          HistoryEntry(HistoryKind.length),
          HistoryEntry(HistoryKind.length, start: 128),
        ], undoCount: 1),
      );
      final layers = [
        for (var o = 0; o < history.imageCount; o++)
          engine.exportLayer(1, 0, o),
      ];
      expect([for (final l in layers) l.length], [128, 256, 128]);
      expect(history.lengthMalformation([128, 256, 128]), isNull);
      final base = engine.exportTrack(0);

      SessionRigLane lane(List<Float32List> layers, TrackHistory history) =>
          SessionRigLane(
            lane: 0,
            layers: layers,
            volume: 1,
            muted: false,
            outputMask: 1,
            inputChannel: 0,
            history: history,
          );
      await repository.applySession(
        SessionRig(
          baseLengthFrames: 128,
          tracks: [
            SessionRigTrack(
              fadeAmount: 1,
              reversed: false,
              channel: 0,
              lanes: [
                lane([base], TrackHistory.none),
              ],
            ),
            SessionRigTrack(
              fadeAmount: 1,
              reversed: false,
              channel: 1,
              lanes: [lane(layers, history)],
            ),
          ],
        ),
      );
      var recalled = engine.snapshot().tracks[1];
      expect(recalled.state, TrackState.stopped);
      expect(recalled.lengthFrames, 256);
      expect(recalled.multiple, 2);
      expect(recalled.undoDepth, 1);
      expect(recalled.redoDepth, 1);
      expect(engine.exportHistory(1), history);
      expect(engine.exportTrack(1), doubled);

      // Redo re-applies the Last half; two Undos walk back to the original.
      expect(repository.redo(channel: 1), EngineResult.ok);
      await settle(128);
      expect(engine.exportTrack(1), positional);
      expect(repository.undo(channel: 1), EngineResult.ok);
      await settle(256);
      expect(engine.exportTrack(1), doubled);
      expect(repository.undo(channel: 1), EngineResult.ok);
      await settle(128);
      expect(engine.exportTrack(1), positional);
      recalled = engine.snapshot().tracks[1];
      expect(recalled.undoDepth, 0);
      expect(recalled.redoDepth, 2);
      expect(recalled.multiple, 1);
    },
    skip: skip,
  );

  test('a length edit is refused while a Session is being applied', () async {
    final rig = SessionRig(
      baseLengthFrames: 128,
      tracks: [
        SessionRigTrack(
          fadeAmount: 1,
          reversed: false,
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
    final replaced = repository.applySession(rig);
    expect(
      await repository.editLength(channel: 0, edit: LengthEdit.doubled),
      EngineResult.notReady,
    );
    await replaced;
    // The recalled track is the only content: its Double re-clocks the rig.
    expect(
      await repository.editLength(channel: 0, edit: LengthEdit.doubled),
      EngineResult.ok,
    );
    expect(engine.snapshot().masterLengthFrames, 256);
  }, skip: skip);
}
