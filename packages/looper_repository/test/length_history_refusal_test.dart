import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno_engine/segno_engine.dart' show TrackSnapshot;

import 'helpers/fake_audio_engine.dart';

/// #1168 Part 3: the engine counts Undo and Redo taps on a length edit that
/// did nothing; the repository reports each increase once per track.
void main() {
  late FakeAudioEngine engine;
  late StreamController<void> ticks;
  late LooperRepository repository;

  void publish(List<int> counts) =>
      engine.nextSnapshot = engine.nextSnapshot.copyWith(
        tracks: [
          for (final count in counts)
            TrackSnapshot(
              state: TrackState.playing,
              volume: 1,
              muted: false,
              lengthFrames: 48000,
              undoDepth: 1,
              rms: 0,
              peak: 0,
              lengthHistoryRefusals: count,
            ),
        ],
      );

  Future<void> poll() async {
    ticks.add(null);
    await Future<void>.delayed(Duration.zero);
  }

  setUp(() {
    engine = FakeAudioEngine();
    ticks = StreamController<void>.broadcast(sync: true);
    repository = LooperRepository(engine: engine, ticker: ticks.stream);
  });
  tearDown(() async {
    await repository.dispose();
    await ticks.close();
  });

  test('reports each rise once per track; the first read is the '
      'baseline', () async {
    final reported = <int>[];
    final sub = repository.lengthHistoryRefusals.listen(reported.add);
    addTearDown(sub.cancel);
    // The poll runs while the state is observed.
    final state = repository.looperState.listen((_) {});
    addTearDown(state.cancel);
    // A count already standing when the repository first looks (a reopened
    // engine) is not news.
    publish([3, 0]);
    expect(repository.startEngine(const EngineConfig()).isOk, isTrue);
    await poll();
    expect(reported, isEmpty);
    publish([4, 0]);
    await poll();
    expect(reported, [0]);
    // An unchanged count reports nothing on the next poll.
    await poll();
    expect(reported, [0]);
    publish([4, 2]);
    await poll();
    expect(reported, [0, 1]);
    // A lower count is a new engine: only the baseline moves.
    publish([0, 2]);
    await poll();
    expect(reported, [0, 1]);
    publish([1, 2]);
    await poll();
    expect(reported, [0, 1, 0]);
  });
}
