import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno_engine/segno_engine.dart'
    show EngineSnapshot, ReopenOutcome, TrackSnapshot, TrackState;
import 'package:segno_engine/segno_engine.dart' as le show LatencyState;

import 'helpers/fake_audio_engine.dart';

/// `LooperRepository.measureLatency` and the keep-material apply (#1270 Part
/// 3b): a cable measurement completes on its own request only, ends on the
/// signals the engine's single latency word leaves, and an audio-settings
/// change never clears the loops.
void main() {
  late FakeAudioEngine engine;
  late StreamController<void> ticker;

  const config = EngineConfig(
    sampleRate: 48000,
    bufferFrames: 128,
    playbackDeviceId: 'out-1',
  );

  setUp(() {
    engine = FakeAudioEngine()
      ..nextSnapshot = const EngineSnapshot.initial().copyWith(
        isRunning: true,
        devicePresent: true,
        sampleRate: 48000,
        bufferFrames: 128,
      );
    ticker = StreamController<void>.broadcast(sync: true);
  });

  tearDown(() => ticker.close());

  LooperRepository running() {
    final repo = LooperRepository(engine: engine, ticker: ticker.stream);
    addTearDown(repo.dispose);
    expect(repo.startEngine(config), EngineResult.ok);
    // The poll runs while someone listens.
    final sub = repo.looperState.listen((_) {});
    addTearDown(sub.cancel);
    engine.calls.clear();
    return repo;
  }

  void publish(le.LatencyState state, int request, {int offset = 0}) {
    engine.nextSnapshot = engine.nextSnapshot.copyWith(
      latencyState: state,
      latencyRequest: request,
      recordOffsetFrames: offset,
      measuredLatencyMs: offset / 48,
    );
    ticker.add(null);
  }

  group('measureLatency', () {
    test('posts the path at -12 dBFS under a new request', () {
      final repo = running();
      unawaited(repo.measureLatency(output: 2, input: 1));
      unawaited(repo.measureLatency(output: 2, input: 1));
      expect(engine.lastLatencyPath, (
        output: 2,
        input: 1,
        amplitude: 0.25,
        request: 2,
      ));
    });

    test("completes on its own DONE, never on a previous request's", () async {
      final repo = running();
      LatencyResult? result;
      unawaited(
        repo
            .measureLatency(output: 0, input: 0)
            .then((value) => result = value),
      );
      final request = engine.lastLatencyPath!.request;
      publish(le.LatencyState.done, request - 1, offset: 90);
      await Future<void>.delayed(Duration.zero);
      expect(result, isNull);
      publish(le.LatencyState.measuring, request);
      publish(le.LatencyState.done, request, offset: 240);
      await Future<void>.delayed(Duration.zero);
      expect(result, const LatencyResult.done(offsetFrames: 240, latencyMs: 5));
      // Remembered, so a reopen replays the measured figure.
      engine.lastRecordOffset = null;
      repo.applyAudioConfig(
        const EngineConfig(
          sampleRate: 48000,
          bufferFrames: 256,
          playbackDeviceId: 'out-1',
        ),
      );
      expect(engine.lastRecordOffset, 240);
    });

    test('a timeout on its request is no return', () async {
      final repo = running();
      final result = repo.measureLatency(output: 0, input: 0);
      publish(le.LatencyState.timeout, engine.lastLatencyPath!.request);
      expect(await result, const LatencyResult(LatencyOutcome.noReturn));
    });

    test('idle under its request, another request after its own, or the '
        'device leaving end it cancelled', () async {
      final repo = running();

      var result = repo.measureLatency(output: 0, input: 0);
      publish(le.LatencyState.idle, engine.lastLatencyPath!.request);
      expect(await result, const LatencyResult(LatencyOutcome.cancelled));

      result = repo.measureLatency(output: 0, input: 0);
      publish(le.LatencyState.measuring, engine.lastLatencyPath!.request);
      publish(le.LatencyState.done, 0, offset: 77);
      expect(await result, const LatencyResult(LatencyOutcome.cancelled));

      result = repo.measureLatency(output: 0, input: 0);
      engine.nextSnapshot = engine.nextSnapshot.copyWith(devicePresent: false);
      ticker.add(null);
      expect(await result, const LatencyResult(LatencyOutcome.cancelled));
    });

    test('cancelLatency posts the cancel and ends the wait', () async {
      final repo = running();
      final result = repo.measureLatency(output: 0, input: 0);
      repo.cancelLatency();
      expect(engine.lastCancelledLatency, engine.lastLatencyPath!.request);
      expect(await result, const LatencyResult(LatencyOutcome.cancelled));
    });

    test('a DONE that lands after the cancel is undone', () async {
      final repo = running()..setRecordOffset(77);
      final result = repo.measureLatency(output: 0, input: 0);
      final request = engine.lastLatencyPath!.request;
      repo.cancelLatency();
      expect(await result, const LatencyResult(LatencyOutcome.cancelled));
      // The engine had resolved it in the block the cancel arrived in.
      engine.lastRecordOffset = null;
      publish(le.LatencyState.done, request, offset: 240);
      await Future<void>.delayed(Duration.zero);
      expect(engine.lastRecordOffset, 77);
      // Once: the next poll leaves the offset alone.
      engine.lastRecordOffset = null;
      ticker.add(null);
      await Future<void>.delayed(Duration.zero);
      expect(engine.lastRecordOffset, isNull);
    });

    test('after the timeout it cancels and completes timedOut', () {
      fakeAsync((async) {
        final repo = LooperRepository(engine: engine, ticker: ticker.stream);
        expect(repo.startEngine(config), EngineResult.ok);
        LatencyResult? result;
        unawaited(
          repo
              .measureLatency(output: 0, input: 0)
              .then((value) => result = value),
        );
        async.elapse(const Duration(milliseconds: 1999));
        expect(result, isNull);
        async.elapse(const Duration(milliseconds: 1));
        expect(result, const LatencyResult(LatencyOutcome.timedOut));
        expect(engine.lastCancelledLatency, engine.lastLatencyPath!.request);
        unawaited(repo.dispose());
        async.flushMicrotasks();
      });
    });

    test('a refused request completes refused', () async {
      final repo = running();
      engine.measureLatencyResult = EngineResult.invalid;
      expect(
        await repo.measureLatency(output: 9, input: 0),
        const LatencyResult.refused(EngineResult.invalid),
      );
    });
  });

  group('applyAudioConfig with material', () {
    test('asks the reopen to keep the loops, and a refusal reopens the '
        'previous config naming the rate', () {
      final repo = running();
      engine.nextSnapshot = engine.nextSnapshot.copyWith(
        tracks: const [
          TrackSnapshot(
            state: TrackState.playing,
            volume: 1,
            muted: false,
            lengthFrames: 48000,
            undoDepth: 1,
            rms: 0,
            peak: 0,
          ),
        ],
      );
      ticker.add(null);
      expect(repo.state.hasContent, isTrue);
      engine.reopenResult = (
        result: EngineResult.wouldClear,
        outcome: ReopenOutcome.clearedRate,
        droppedTracks: 0,
        openedRate: 44100,
      );
      final keepFlags = <bool>[];
      var reopens = 0;
      engine.afterSnapshot = () {
        final calls = engine.calls.where((c) => c == 'reopen').length;
        if (calls > reopens) {
          reopens = calls;
          keepFlags.add(engine.lastConfig!.keepMaterial);
          engine.reopenResult = (
            result: EngineResult.ok,
            outcome: ReopenOutcome.retained,
            droppedTracks: 0,
            openedRate: 48000,
          );
        }
      };

      final outcome = repo.applyAudioConfig(
        const EngineConfig(
          sampleRate: 48000,
          bufferFrames: 128,
          playbackDeviceId: 'out-2',
        ),
      );

      expect(outcome.status, AudioApplyStatus.refused);
      expect(outcome.result, EngineResult.wouldClear);
      expect(outcome.refusedRate, 44100);
      expect(outcome.reopen?.outcome, ReopenOutcome.retained);
      expect(keepFlags, [true, true]);
      expect(repo.lastEngineConfig, config);
    });

    test('an empty rig reopens without the flag', () {
      running().applyAudioConfig(config);
      expect(engine.lastConfig?.keepMaterial, isFalse);
    });
  });
}
