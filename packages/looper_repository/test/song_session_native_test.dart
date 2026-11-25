@Tags(['fuzz'])
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno_engine/segno_engine.dart' show PumpedNativeEngine;

/// A saved Free or Song session opens on the actual native engine (SEG-108):
/// each track keeps its own length, and no shared loop is established.
void main() {
  late PumpedNativeEngine engine;
  late LooperRepository repository;
  late StreamController<void> ticks;
  late Timer callback;

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

  Float32List take(int frames, double level) =>
      Float32List.fromList(List.filled(frames, level));

  SessionRigLane lane(int index, Float32List pcm, {bool muted = false}) =>
      SessionRigLane(
        lane: index,
        layers: [pcm],
        volume: 1,
        muted: muted,
        outputMask: 1,
        inputChannel: index,
      );

  // The shape of the console's "New session 5" (s-20261124-221825): two
  // sections of unrelated lengths, two lanes each, the second one's muted.
  SessionRig rig(LooperMode mode) => SessionRig(
    looperMode: mode,
    primaryTrack: 0,
    defaultMultiple: 1,
    tracks: [
      SessionRigTrack(
        fadeAmount: 1,
        reversed: false,
        channel: 0,
        lanes: [lane(0, take(144, .25)), lane(1, take(144, .5))],
      ),
      SessionRigTrack(
        fadeAmount: 1,
        reversed: false,
        channel: 1,
        lanes: [
          lane(0, take(313, .5), muted: true),
          lane(1, take(313, .75), muted: true),
        ],
      ),
    ],
  );

  test('a Song session that kept a recorded tempo pair from before a mode '
      'switch opens on its own clocks, not on that pair', () async {
    // The shape of the console's "t" (s-20261124-183112): recorded in Multi
    // at a derived tempo, then switched to Song and saved.
    await repository.applySession(
      SessionRig(
        looperMode: LooperMode.song,
        primaryTrack: 0,
        defaultMultiple: 1,
        tempoBpm: 137.93,
        tempoSource: TempoSource.derived,
        recordedTempoBpm: 137.93,
        recordedLengthFrames: 453,
        tracks: [
          SessionRigTrack(
            fadeAmount: 1,
            reversed: false,
            channel: 0,
            lanes: [lane(0, take(453, .25))],
          ),
          SessionRigTrack(
            fadeAmount: 1,
            reversed: false,
            channel: 1,
            lanes: [lane(0, take(435, .5))],
          ),
        ],
      ),
    );

    final snapshot = engine.snapshot();
    expect(snapshot.masterLengthFrames, 0);
    expect(snapshot.tracks[0].state, TrackState.stopped);
    expect(snapshot.tracks[0].lengthFrames, 453);
    expect(snapshot.tracks[1].state, TrackState.stopped);
    expect(snapshot.tracks[1].lengthFrames, 435);
    expect(snapshot.tempoBpm, closeTo(137.93, 1e-3));
  });

  for (final mode in [LooperMode.song, LooperMode.free]) {
    test('a ${mode.name} session with two tracks of different lengths opens '
        'with each track stopped on its own length', () async {
      await repository.applySession(rig(mode));

      final snapshot = engine.snapshot();
      expect(snapshot.masterLengthFrames, 0);
      expect(snapshot.tracks[0].state, TrackState.stopped);
      expect(snapshot.tracks[0].lengthFrames, 144);
      expect(snapshot.tracks[1].state, TrackState.stopped);
      expect(snapshot.tracks[1].lengthFrames, 313);
      expect(engine.exportTrackLane(1, 1), take(313, .75));
      expect(repository.sessionTransport.looperMode, mode);

      // The opened take plays on its own clock: it laps at its own length.
      expect(engine.play(), EngineResult.ok);
      engine
        ..pump(frames: 0)
        ..pump(frames: 200);
      final playing = engine.snapshot();
      expect(playing.masterLengthFrames, 0);
      expect(playing.tracks[0].state, TrackState.playing);
      // The 200th frame played sits at index 199 of the take, once lapped.
      expect(playing.tracks[0].positionFrames, 199 - 144);
    });
  }
}
