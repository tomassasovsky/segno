@Tags(['fuzz'])
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno_engine/segno_engine.dart'
    show EngineSnapshot, PumpedNativeEngine, RecordImage;

class _ImageCountingEngine extends PumpedNativeEngine {
  int imagesPrepared = 0;
  void Function()? afterSnapshot;

  @override
  EngineSnapshot snapshot() {
    final result = super.snapshot();
    final callback = afterSnapshot;
    afterSnapshot = null;
    callback?.call();
    return result;
  }

  @override
  EngineResult recordWithImage(RecordImage image, {int channel = 0}) {
    imagesPrepared++;
    return super.recordWithImage(image, channel: channel);
  }
}

void main() {
  final library = Platform.environment['SEGNO_ENGINE_LIB'];
  final skip = library == null || library.isEmpty
      ? 'SEGNO_ENGINE_LIB is required for actual callback ordering'
      : null;

  for (final record in [false, true]) {
    for (final expired in [false, true]) {
      for (final interleaved in [false, true]) {
        if (interleaved && (!record || expired)) continue;
        test(
          '${record ? 'Record' : 'Play'} cancellation under pending pair: '
          'grace expired=$expired interleaved=$interleaved',
          () async {
            final engine = _ImageCountingEngine();
            final ticker = StreamController<void>.broadcast();
            final repository = LooperRepository(
              engine: engine,
              ticker: ticker.stream,
            );
            final subscription = repository.looperState.listen((_) {});
            try {
              expect(
                repository.startEngine(
                  const EngineConfig(
                    sampleRate: 8000,
                    inputChannels: 1,
                    outputChannels: 1,
                    maxLoopFrames: 256000,
                  ),
                ),
                EngineResult.ok,
              );
              engine.pump(frames: 0);
              expect(await repository.settleMixSettings(), EngineResult.ok);
              expect(engine.setTempo(120), EngineResult.ok);
              engine.pump(frames: 0);
              expect(engine.record(channel: 6), EngineResult.ok);
              engine.pump(frames: 800, input: .3);
              expect(engine.stopTrack(channel: 6), EngineResult.ok);
              engine.pump(frames: 256);
              expect(engine.snapshot().tracks[6].state, TrackState.stopped);
              final originalLength = engine.snapshot().tracks[6].lengthFrames;
              expect(originalLength, greaterThan(0));
              expect(
                repository.setRecordStartSettings(
                  countInBars: 1,
                  soundStart: false,
                  editKind: RecordStartEditKind.countIn,
                ),
                EngineResult.ok,
              );
              engine.pump(frames: 0);
              expect(
                await repository.settleRecordStartSettings(),
                EngineResult.ok,
              );
              expect(repository.play(channel: 6), EngineResult.ok);
              engine.pump(frames: 0);
              expect(
                engine.snapshot().tracks[6].pendingLaunch,
                PendingLaunchAction.play,
              );
              if (interleaved) {
                // Return the real pending snapshot, then commit and expire the
                // grace before repository admission resumes on the producer.
                engine.afterSnapshot = () {
                  engine
                    ..pump(frames: 16000)
                    ..pump(frames: 0);
                };
              } else {
                engine.pump(frames: 16000);
                expect(engine.snapshot().tracks[6].state, TrackState.playing);
                expect(engine.snapshot().tracks[6].pendingLaunch, isNull);
                if (expired) engine.pump(frames: 0);
                expect(
                  repository.setRecordStartSettings(
                    countInBars: 1,
                    soundStart: false,
                    editKind: RecordStartEditKind.sound,
                  ),
                  EngineResult.ok,
                );
                expect(repository.recordStartSettingsSettled, isFalse);
              }
              expect(
                record
                    ? repository.record(channel: 6)
                    : repository.play(channel: 6),
                expired ? EngineResult.notReady : EngineResult.ok,
              );
              expect(engine.imagesPrepared, 0);
              engine.pump(frames: 0);
              expect(
                await repository.settleRecordStartSettings(),
                EngineResult.ok,
              );
              expect(
                engine.snapshot().tracks[6].state,
                expired || interleaved
                    ? TrackState.playing
                    : TrackState.stopped,
              );
              expect(engine.snapshot().tracks[6].lengthFrames, originalLength);
            } finally {
              await subscription.cancel();
              await repository.dispose();
              await ticker.close();
            }
          },
          skip: skip,
        );
      }
    }
  }
}
