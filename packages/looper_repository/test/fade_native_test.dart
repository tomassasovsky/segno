@Tags(['fuzz'])
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno_engine/segno_engine.dart' show PumpedNativeEngine;

void main() {
  final library = Platform.environment['SEGNO_ENGINE_LIB'];
  final skip = library == null || library.isEmpty
      ? 'Build packages/segno_engine/tool/build_test_lib.sh and set SEGNO_ENGINE_LIB'
      : null;
  late PumpedNativeEngine engine;
  late LooperRepository repository;

  setUp(() {
    engine = PumpedNativeEngine();
    repository = LooperRepository(engine: engine, ticker: const Stream.empty());
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
    expect(engine.commitSession(128, loopBars: 0), EngineResult.ok);
    expect(engine.play(), EngineResult.ok);
    engine.pump(frames: 0);
  });
  tearDown(() => repository.dispose());

  test(
    'rapid requests retain exact native outcomes and coherent projection',
    () async {
      final first = repository.toggleFade(channel: 0, seconds: .5);
      final second = repository.toggleFade(channel: 0, seconds: 2);
      final empty = repository.toggleFade(channel: 1, seconds: 1);
      var completed = false;
      final completion = first.then((_) {
        completed = true;
      });
      await Future<void>.delayed(Duration.zero);
      expect(completed, isFalse);
      engine.pump(frames: 128);
      expect(await first, EngineResult.ok);
      expect(await second, EngineResult.ok);
      expect(await empty, EngineResult.invalid);
      await completion;
      final image = engine.snapshot().tracks[0].fade;
      expect(image.amount, 1);
      expect(image.target, 1);
      expect(image.fullTravelSeconds, 2);
      expect(repository.state.tracks[0].fade, image);
      final installed = repository.installFade(
        channel: 0,
        image: FadeImage(
          amount: .25,
          target: .25,
          lifetime: image.lifetime,
          generation: image.generation,
        ),
      );
      engine.pump(frames: 1);
      expect(await installed, EngineResult.ok);
      expect(engine.snapshot().outputPeaks[0], closeTo(.125, 1e-6));
      expect(repository.state.tracks[0].volume, 1);
      expect(engine.exportTrack(0), everyElement(.5));
    },
    skip: skip,
  );

  test(
    'timed-out claims drain before admission without UI subscriptions',
    () async {
      final requests = [
        for (var i = 0; i < 255; i++)
          repository.toggleFade(channel: 0, seconds: 1),
      ];
      expect(await Future.wait(requests), everyElement(EngineResult.notReady));
      // The original callback can still apply: timeout is uncertainty, not
      // cancellation. No UI subscription or poll timer exists in this test.
      engine.pump(frames: 0);
      final next = repository.toggleFade(channel: 0, seconds: 1);
      engine.pump(frames: 0);
      expect(await next, EngineResult.ok);
      expect(engine.snapshot().tracks[0].fade.target, 1);
    },
    skip: skip,
  );

  test(
    'Session replacement drains retired claims in the same native lifetime',
    () async {
      final lifetime = engine.snapshot().tracks[0].fade.lifetime;
      final rig = SessionRig(
        baseLengthFrames: 128,
        tracks: [
          SessionRigTrack(
            fadeAmount: 1,
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
      final callback = Timer.periodic(
        const Duration(milliseconds: 1),
        (_) => engine.pump(frames: 0),
      );
      try {
        for (var replacement = 0; replacement < 9; replacement++) {
          final pending = [
            for (var i = 0; i < 32; i++)
              repository.toggleFade(channel: 0, seconds: 1),
          ];
          final replaced = repository.applySession(rig);
          expect(
            await Future.wait(pending),
            everyElement(EngineResult.notReady),
          );
          await replaced;
          expect(engine.snapshot().tracks[0].fade.lifetime, lifetime);
        }
        final next = repository.toggleFade(channel: 0, seconds: 1);
        expect(await next, EngineResult.ok);
      } finally {
        callback.cancel();
      }
    },
    skip: skip,
  );

  test(
    'engine retirement completes pending request without stale success',
    () async {
      final pending = repository.toggleFade(channel: 0, seconds: 1);
      repository.stopEngine();
      expect(await pending, EngineResult.notReady);
      expect(
        repository.startEngine(const EngineConfig(maxLoopFrames: 1000)),
        EngineResult.ok,
      );
      engine.pump(frames: 0);
      expect(engine.snapshot().tracks[0].fade.amount, 1);
    },
    skip: skip,
  );
}
