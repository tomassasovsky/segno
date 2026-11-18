@Tags(['fuzz'])
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno_engine/segno_engine.dart'
    show LaneSource, PumpedNativeEngine;

/// A take's effect moved between Pre and Post on the native engine (#1741):
/// at Post it runs live on the take's clean signal and rings out past Stop;
/// back at Pre the take plays what was heard again, and Stop cuts it.
void main() {
  late PumpedNativeEngine engine;
  late LooperRepository repository;
  late StreamController<void> ticks;

  setUp(() {
    engine = PumpedNativeEngine();
    ticks = StreamController<void>.broadcast(sync: true);
    repository = LooperRepository(engine: engine, ticker: ticks.stream);
    expect(
      repository.startEngine(
        const EngineConfig(
          inputChannels: 1,
          outputChannels: 2,
          maxLoopFrames: 96000,
        ),
      ),
      EngineResult.ok,
    );
    engine.pump(frames: 0);
  });
  tearDown(() async {
    await repository.dispose();
    await ticks.close();
  });

  Future<void> settle() async {
    final driver = Timer.periodic(
      const Duration(milliseconds: 1),
      (_) => engine.pump(frames: 0),
    );
    expect(await repository.settleRecordTimingSettings(), EngineResult.ok);
    expect(await repository.settleRecordStartSettings(), EngineResult.ok);
    expect(await repository.settleMixSettings(), EngineResult.ok);
    expect(await repository.settleFxRecipes(), EngineResult.ok);
    driver.cancel();
    ticks.add(null);
  }

  /// The loudest sample of [frames] frames played with no input.
  double peakOver(int frames) {
    final out = Float32List(2 * 256);
    var peak = 0.0;
    for (var done = 0; done < frames; done += 256) {
      engine.pump(frames: 256, output: out);
      for (final v in out) {
        if (v.abs() > peak) peak = v.abs();
      }
    }
    return peak;
  }

  /// Plays half a second, presses Stop, and returns the loudest sample
  /// from 0.1 s to 0.3 s after it: past the Stop fade, inside a reverb tail.
  double tailAfterStop() {
    engine.pump(frames: 24000);
    expect(repository.stopTrack(), EngineResult.ok);
    engine.pump(frames: 4800);
    return peakOver(9600);
  }

  LaneSource source() => engine.snapshot().tracks[0].lanes[0].source;

  test(
    'a take recorded through a reverb at Pre rings out past Stop once the '
    'reverb is moved to Post, and plays what was heard again back at Pre',
    () async {
      final subscription = repository.looperState.listen((_) {});
      addTearDown(subscription.cancel);
      await Future<void>.delayed(Duration.zero);
      repository
        ..setMonitorEffects(
          input: 0,
          effects: [
            BuiltInEffect(
              type: TrackEffectType.reverb,
              placement: FxPlacement.pre,
            ),
          ],
        )
        ..setMonitorMute(input: 0, muted: true);
      await settle();
      expect(repository.record(), EngineResult.ok);
      engine
        ..pump(frames: 2400, input: .5)
        ..pump(frames: 21600);
      expect(repository.record(), EngineResult.ok); // close into play
      engine.pump(frames: 24000);
      ticks.add(null);
      expect(source(), LaneSource.heard);
      final slotId = repository.laneEffects(0, 0).single.slotId!;

      // Printed: Stop cuts it.
      expect(tailAfterStop(), 0);
      expect(repository.play(), EngineResult.ok);

      // At Post it runs live and rings out past Stop.
      expect(
        repository.setLaneEffectPlacement(
          channel: 0,
          lane: 0,
          slotId: slotId,
          placement: FxPlacement.post,
        ),
        EngineResult.ok,
      );
      await settle();
      expect(source(), LaneSource.clean);
      expect(tailAfterStop(), greaterThan(1e-3));
      expect(repository.play(), EngineResult.ok);

      // Back at Pre: what was heard, cut at Stop.
      expect(
        repository.setLaneEffectPlacement(
          channel: 0,
          lane: 0,
          slotId: slotId,
          placement: FxPlacement.pre,
        ),
        EngineResult.ok,
      );
      await settle();
      expect(source(), LaneSource.heard);
      expect(tailAfterStop(), 0);
    },
  );

  for (final (placement, outcome) in [
    (FxPlacement.post, 'rings out past Stop on its lane'),
    (FxPlacement.pre, 'plays what was heard, cut at Stop'),
  ]) {
    test('a take recorded through an input reverb at ${placement.name} '
        '$outcome (#1741)', () async {
      final subscription = repository.looperState.listen((_) {});
      addTearDown(subscription.cancel);
      await Future<void>.delayed(Duration.zero);
      repository
        ..setMonitorEffects(
          input: 0,
          effects: [
            BuiltInEffect(type: TrackEffectType.reverb, placement: placement),
          ],
        )
        ..setMonitorMute(input: 0, muted: true);
      await settle();
      expect(repository.record(), EngineResult.ok);
      engine
        ..pump(frames: 2400, input: .5)
        ..pump(frames: 21600);
      expect(repository.record(), EngineResult.ok); // close into play
      engine.pump(frames: 24000);
      ticks.add(null);
      final lane = engine.snapshot().tracks[0].lanes[0];
      expect(repository.laneEffects(0, 0).single.placement, placement);
      if (placement == FxPlacement.post) {
        // Nothing of the input chain is Pre: recorded clean, the reverb
        // live on the lane.
        expect(lane.heard, isFalse);
        expect(tailAfterStop(), greaterThan(1e-3));
      } else {
        expect(lane.heard, isTrue);
        expect(lane.source, LaneSource.heard);
        expect(tailAfterStop(), 0);
      }
    });
  }
}
