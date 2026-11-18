@Tags(['fuzz'])
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno_engine/segno_engine.dart'
    show LaneSource, PumpedNativeEngine;

/// A take recorded through the input's effects plays what was heard, on the
/// native engine (#1713): the repository arms it heard, the engine captures
/// the image, and an edit of the take's chain re-amps the clean take.
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
          maxLoopFrames: 48000,
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

  test('a take through a delay records its image, plays it, and re-amps once '
      'its chain is edited', () async {
    final subscription = repository.looperState.listen((_) {});
    addTearDown(subscription.cancel);
    await Future<void>.delayed(Duration.zero);
    expect(
      repository.setMonitorEffects(
        input: 0,
        effects: [
          BuiltInEffect(
            type: TrackEffectType.delay,
            placement: FxPlacement.pre,
          ),
        ],
      ),
      EngineResult.ok,
    );
    // The settings receipts land with the callback.
    final driver = Timer.periodic(
      const Duration(milliseconds: 1),
      (_) => engine.pump(frames: 0),
    );
    expect(await repository.settleRecordTimingSettings(), EngineResult.ok);
    expect(await repository.settleRecordStartSettings(), EngineResult.ok);
    expect(await repository.settleMixSettings(), EngineResult.ok);
    expect(await repository.settleFxRecipes(), EngineResult.ok);
    driver.cancel();
    expect(repository.record(), EngineResult.ok);
    engine.pump(frames: 256, input: .5);
    expect(repository.record(), EngineResult.ok); // close into play
    engine.pump(frames: 256);
    ticks.add(null);

    final lane = engine.snapshot().tracks[0].lanes[0];
    expect(lane.heard, isTrue);
    expect(lane.source, LaneSource.heard);
    expect(repository.laneEffects(0, 0), hasLength(1));
    expect(engine.exportTrackLaneHeard(0, 0), isNotEmpty);

    // The take's chain edited: it plays its clean take through it.
    expect(
      repository.setLaneEffects(
        channel: 0,
        lane: 0,
        effects: [BuiltInEffect(type: TrackEffectType.reverb)],
      ),
      EngineResult.ok,
    );
    engine.pump(frames: 0);
    ticks.add(null);
    expect(engine.snapshot().tracks[0].lanes[0].source, LaneSource.clean);
  });
}
