import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno_engine/segno_engine.dart'
    show EngineSnapshot, LaneSnapshot, TrackSnapshot;
import 'package:segno_engine/segno_engine.dart' as le show LatencyState;

import 'helpers/fake_audio_engine.dart';

/// A fixed-eight-track rig with [count] tracks in the authored state.
EngineSnapshot _rig(
  int count, {
  TrackState state = TrackState.empty,
  int framesProcessed = 0,
}) => EngineSnapshot(
  isRunning: true,
  devicePresent: true,
  sampleRate: 48000,
  bufferFrames: 128,
  inputChannels: 2,
  outputChannels: 2,
  framesProcessed: framesProcessed,
  xrunCount: 0,
  inputRms: 0,
  inputPeak: 0,
  outputRms: 0,
  latencyState: le.LatencyState.idle,
  measuredLatencyMs: -1,
  tracks: [
    for (var i = 0; i < count; i++)
      TrackSnapshot(
        state: state,
        volume: 1,
        muted: false,
        lengthFrames: state == TrackState.empty ? 0 : 48000,
        undoDepth: 0,
        rms: 0,
        peak: 0,
        lanes: const [
          LaneSnapshot(
            inputChannel: 0,
            outputMask: 3,
            volume: 1,
            muted: false,
            lengthFrames: 0,
            rms: 0,
            peak: 0,
          ),
        ],
      ),
    for (var i = count; i < 8; i++) const TrackSnapshot.empty(),
  ],
);

/// #1146: a fresh capture the engine refuses with notReady sits in the
/// one-block window after an Undo-to-empty, Clear or cancelled take. The
/// repository owes the press exactly one retry after a further callback block
/// has published; a second refusal is reported instead of dropped.
void main() {
  late FakeAudioEngine engine;
  late StreamController<void> ticker;
  late List<int> refusals;

  setUp(() {
    engine = FakeAudioEngine();
    ticker = StreamController<void>.broadcast();
    engine.nextSnapshot = _rig(2);
    refusals = [];
  });

  tearDown(() => ticker.close());

  LooperRepository start() {
    final repo = LooperRepository(engine: engine, ticker: ticker.stream)
      ..startEngine(const EngineConfig());
    addTearDown(repo.dispose);
    final states = repo.looperState.listen((_) {});
    addTearDown(states.cancel);
    final reported = repo.recordRefusals.listen(refusals.add);
    addTearDown(reported.cancel);
    return repo;
  }

  int recordCalls() => engine.calls.where((call) => call == 'record').length;

  Future<void> poll() async {
    ticker.add(null);
    await Future<void>.delayed(Duration.zero);
  }

  group('a fresh capture the engine refused', () {
    test(
      'is retried once after the next published block and lands quietly',
      () async {
        final repo = start();
        engine.recordResult = EngineResult.notReady;

        expect(repo.record(), EngineResult.notReady);
        expect(recordCalls(), 1);
        expect(repo.recordRetryPending(0), isTrue);

        // No further block has published: the retry waits.
        engine.commandsAreSettled = false;
        await poll();
        expect(recordCalls(), 1);
        expect(repo.recordRetryPending(0), isTrue);

        // The block that emptied the track has published: the one retry lands.
        engine
          ..recordResult = EngineResult.ok
          ..nextSnapshot = _rig(2, framesProcessed: 128);
        await poll();
        expect(recordCalls(), 2);
        expect(repo.recordRetryPending(0), isFalse);
        expect(engine.imageRevisions.keys, [0], reason: 'the capture started');
        expect(refusals, isEmpty);

        await poll();
        expect(recordCalls(), 2, reason: 'exactly one retry');
      },
    );

    test(
      'refused twice reports the lost press and starts no capture',
      () async {
        final repo = start();
        engine.recordResult = EngineResult.notReady;

        expect(repo.record(), EngineResult.notReady);
        engine.nextSnapshot = _rig(2, framesProcessed: 128);
        await poll();

        expect(recordCalls(), 2);
        expect(refusals, [0]);
        expect(repo.recordRetryPending(0), isFalse);
        expect(engine.imageRevisions, isEmpty);

        await poll();
        expect(recordCalls(), 2, reason: 'no third attempt');
        expect(refusals, [0]);
      },
    );

    test(
      'waits a bounded number of polls for publication, then retries',
      () async {
        final repo = start();
        engine
          ..recordResult = EngineResult.notReady
          ..commandsAreSettled = false;

        expect(repo.record(), EngineResult.notReady);
        for (var i = 0; i < 3; i++) {
          await poll();
          expect(recordCalls(), 1);
        }
        await poll();
        expect(recordCalls(), 2);
        expect(refusals, [0]);
      },
    );

    test(
      'is superseded quietly when the track is no longer a fresh target',
      () async {
        final repo = start();
        engine.recordResult = EngineResult.notReady;

        expect(repo.record(), EngineResult.notReady);
        // A later press landed (or a redo): the track records already.
        engine.nextSnapshot = _rig(
          2,
          state: TrackState.recording,
          framesProcessed: 128,
        );
        await poll();

        expect(recordCalls(), 1, reason: 'the retry would finish that take');
        expect(refusals, isEmpty);
        expect(repo.recordRetryPending(0), isFalse);
      },
    );

    test('a refusal that is not a fresh capture is neither retried nor '
        'reported', () async {
      engine.nextSnapshot = _rig(2, state: TrackState.playing);
      final repo = start();
      engine.recordResult = EngineResult.notReady;

      expect(repo.record(), EngineResult.notReady);
      expect(repo.recordRetryPending(0), isFalse);
      engine.nextSnapshot = _rig(
        2,
        state: TrackState.playing,
        framesProcessed: 128,
      );
      await poll();

      expect(recordCalls(), 1);
      expect(refusals, isEmpty);
    });
  });
}
