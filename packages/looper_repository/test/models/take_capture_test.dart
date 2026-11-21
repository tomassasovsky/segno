import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';

void main() {
  group('TakeCapture (#1936)', () {
    test('is no take by default', () {
      expect(TakeCapture.none.recording, isFalse);
      expect(TakeCapture.none.progress, 0);
    });

    test('reports its share of the target', () {
      const capture = TakeCapture(frames: 2000, targetFrames: 8000);
      expect(capture.recording, isTrue);
      expect(capture.progress, 0.25);
    });

    test('has no progress without a target', () {
      const capture = TakeCapture(frames: 2000);
      expect(capture.recording, isTrue);
      expect(capture.progress, 0);
    });

    test('caps the progress at the target through the seam', () {
      const capture = TakeCapture(frames: 8010, targetFrames: 8000);
      expect(capture.progress, 1);
    });
  });

  group('Playhead.capture', () {
    test("reads a channel's take, and none past the rig", () {
      const playhead = Playhead(
        captures: [TakeCapture.none, TakeCapture(frames: 10)],
      );
      expect(playhead.capture(1), const TakeCapture(frames: 10));
      expect(playhead.capture(0), TakeCapture.none);
      expect(playhead.capture(5), TakeCapture.none);
      expect(playhead.capture(-1), TakeCapture.none);
    });
  });

  group('TransportState.framesPerBeat', () {
    test("is the master grid's own beat when one exists", () {
      const transport = TransportState(
        masterLengthFrames: 96000,
        loopBeats: 8,
        tempoBpm: 100,
        tempoSource: TempoSource.derived,
      );
      expect(transport.framesPerBeat(48000), 12000);
    });

    test("is the nominal tempo's before any loop", () {
      const transport = TransportState(
        tempoBpm: 120,
        tempoSource: TempoSource.manual,
      );
      expect(transport.framesPerBeat(48000), 24000);
    });

    test('is null with no grid and no tempo', () {
      expect(const TransportState().framesPerBeat(48000), isNull);
    });
  });
}
