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
        lengthPresetBars: 4,
        quantizeOverride: true,
        oneShot: true,
        chainEnabled: false,
      );
      expect(track.props, [...track.steadyProps, track.peak]);
    });

    test('a moving peak leaves steadyProps unchanged', () {
      const still = Track(channel: 1, state: TrackState.playing);
      const loud = Track(channel: 1, state: TrackState.playing, peak: 0.9);
      expect(loud.steadyProps, still.steadyProps);
      expect(loud, isNot(still));
    });
  });
}
