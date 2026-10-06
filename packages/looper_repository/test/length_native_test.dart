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
