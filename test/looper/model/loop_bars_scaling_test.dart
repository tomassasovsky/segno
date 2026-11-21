import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/looper/model/loop_bars_scaling.dart';

void main() {
  group('loopBarsScaling (#1936)', () {
    LooperState state({
      TempoSource source = TempoSource.derived,
      double bpm = 120,
      double recorded = 120,
      int bars = 4,
      LooperMode mode = LooperMode.multi,
      TrackState trackState = TrackState.playing,
    }) => LooperState(
      recordedTempoBpm: recorded,
      transport: TransportState(
        masterLengthFrames: 96000,
        tempoBpm: bpm,
        tempoSource: source,
        loopBars: bars,
        looperMode: mode,
      ),
      tracks: [Track(state: trackState, lengthFrames: 96000)],
    );

    test('a derived tempo halves an even count and doubles in range', () {
      expect(loopBarsScaling(state()), (halve: true, double: true));
    });

    test('an odd count does not halve', () {
      expect(loopBarsScaling(state(bars: 3)).halve, isFalse);
    });

    test('the tempo stays in range', () {
      expect(loopBarsScaling(state(bpm: 200, recorded: 200)).double, isFalse);
      expect(loopBarsScaling(state(bpm: 50, recorded: 50)).halve, isFalse);
    });

    test('nothing applies to a set tempo, a retimed loop, Free or Song, or '
        'a take in flight', () {
      const none = (halve: false, double: false);
      expect(loopBarsScaling(state(source: TempoSource.manual)), none);
      expect(loopBarsScaling(state(recorded: 100)), none);
      expect(loopBarsScaling(state(mode: LooperMode.free)), none);
      expect(loopBarsScaling(state(mode: LooperMode.song)), none);
      expect(loopBarsScaling(state(trackState: TrackState.recording)), none);
      expect(loopBarsScaling(state(bars: 0)), none);
    });
  });
}
