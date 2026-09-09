import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';

void main() {
  group('Track equality', () {
    // The whole meter path rests on these two facts, and neither of them is
    // visible from any widget test: a meter that stops moving renders exactly
    // like a meter that has nothing to show. So they are asserted here, at the
    // definition, where a change to `props` cannot slip past.

    test('peak is part of value equality', () {
      // Load-bearing: `LooperRepository`'s poll only publishes a projection
      // that differs from the last one, so a level outside equality is a level
      // that never leaves the repository. Dropping `peak` from `props` — the
      // obvious way to make a poll tick produce an identical `LooperState` for
      // anything gating on identity — silently flattens every meter in the
      // console. Gate on `steadyProps` instead.
      expect(const Track(peak: 0.5), isNot(const Track()));
      expect(const Track(peak: 0.5), const Track(peak: 0.5));
    });

    test('steadyProps is props without the live peak', () {
      // The two lists are written out separately so neither is built twice per
      // comparison; this is what keeps them from drifting apart. A field added
      // to one and forgotten in the other fails here rather than becoming a
      // tile that never rebuilds (if it is missing from `steadyProps`) or a
      // level the engine never publishes (if it is missing from `props`).
      const track = Track(
        channel: 3,
        state: TrackState.playing,
        volume: 0.7,
        muted: true,
        lengthFrames: 96000,
        peak: 0.42,
        undoDepth: 2,
        clearRestore: true,
        redoDepth: 1,
        multiple: 2,
        inputMask: 0x2,
        outputMask: 0x5,
        layerInFlight: true,
        pending: true,
        pendingTrigger: ArmTrigger.sound,
        lengthPresetBars: 4,
        quantizeOverride: true,
        oneShot: true,
        chainEnabled: false,
        positionFrames: 4800,
      );
      expect(track.props, [
        ...track.steadyProps,
        track.peak,
        track.positionFrames,
      ]);
    });

    test('a moving peak leaves steadyProps unchanged', () {
      const still = Track(channel: 1, state: TrackState.playing);
      const loud = Track(channel: 1, state: TrackState.playing, peak: 0.9);
      expect(loud.steadyProps, still.steadyProps);
      expect(loud, isNot(still));
    });

    test('a moving playhead leaves steadyProps unchanged too', () {
      const still = Track(channel: 1, state: TrackState.playing);
      const later = Track(
        channel: 1,
        state: TrackState.playing,
        positionFrames: 960,
      );
      expect(later.steadyProps, still.steadyProps);
      expect(later, isNot(still));
    });

    test('progress is the playhead over the length, 0 without a length', () {
      const playing = Track(
        state: TrackState.playing,
        lengthFrames: 1000,
        positionFrames: 250,
      );
      expect(playing.progress, 0.25);
      // The engine publishes the growing write head as both position and
      // length while recording, so a take in progress reads 0, not 100%.
      const recording = Track(
        state: TrackState.recording,
        lengthFrames: 250,
        positionFrames: 250,
      );
      expect(recording.progress, 0);
    });

    test('layers count the base take plus every retired pass', () {
      expect(const Track().layers, 0);
      expect(
        const Track(
          state: TrackState.playing,
          lengthFrames: 10,
        ).layers,
        1,
      );
      expect(
        const Track(
          state: TrackState.playing,
          lengthFrames: 10,
          undoDepth: 2,
        ).layers,
        3,
      );
    });
  });

  group('ArmTrigger', () {
    test("decodes the snapshot's pending_trigger codes", () {
      expect(ArmTrigger.fromCode(0), ArmTrigger.grid);
      expect(ArmTrigger.fromCode(1), ArmTrigger.sound);
      expect(ArmTrigger.fromCode(2), ArmTrigger.section);
      expect(ArmTrigger.fromCode(-1), isNull);
      expect(ArmTrigger.fromCode(7), isNull);
    });
  });
}
