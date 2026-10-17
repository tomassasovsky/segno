import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart' hide LatencyState;
import 'package:segno_engine/segno_engine.dart'
    show
        EngineResult,
        EngineSnapshot,
        FxOwner,
        LatencyState,
        MockPluginSlotHandle,
        TrackSnapshot;

import 'helpers/fake_audio_engine.dart';

const _playingTrack = EngineSnapshot(
  isRunning: true,
  sampleRate: 48000,
  bufferFrames: 128,
  framesProcessed: 0,
  xrunCount: 0,
  inputRms: 0,
  inputPeak: 0,
  outputRms: 0,
  latencyState: LatencyState.idle,
  measuredLatencyMs: -1,
  tracks: [
    TrackSnapshot(
      state: TrackState.playing,
      volume: 1,
      muted: false,
      lengthFrames: 128,
      undoDepth: 1,
      rms: 0,
      peak: 0,
    ),
  ],
);

void main() {
  late FakeAudioEngine engine;
  late LooperRepository repo;
  late StreamController<void> ticker;
  late StreamSubscription<LooperState> subscription;

  setUp(() {
    engine = FakeAudioEngine();
    ticker = StreamController<void>.broadcast();
    repo = LooperRepository(engine: engine, ticker: ticker.stream);
    subscription = repo.looperState.listen((_) {});
    expect(repo.startEngine(const EngineConfig()), EngineResult.ok);
  });

  tearDown(() async {
    await subscription.cancel();
    await repo.dispose();
    await ticker.close();
  });

  test(
    'a refused replacement keeps the audible recipe and remembered chain',
    () {
      final first = BuiltInEffect(type: TrackEffectType.delay);
      expect(
        repo.setLaneEffects(channel: 0, lane: 0, effects: [first]),
        EngineResult.ok,
      );
      final before = repo.laneEffects(0, 0);
      final audible = engine.recipes[(FxOwner.lane, 0, 0)];
      engine.nextRecipeResult = EngineResult.notReady;

      expect(
        repo.setLaneEffects(
          channel: 0,
          lane: 0,
          effects: [BuiltInEffect(type: TrackEffectType.reverb)],
        ),
        EngineResult.notReady,
      );
      expect(repo.laneEffects(0, 0), before);
      expect(engine.recipes[(FxOwner.lane, 0, 0)], same(audible));
      expect(
        repo.laneEffects(0, 0).single.typeCode,
        TrackEffectType.delay.code,
      );
    },
  );

  test(
    'a queued replacement refuses another edit until its exact revision',
    () async {
      engine.publishRecipes = false;
      final first = BuiltInEffect(type: TrackEffectType.drive);
      expect(
        repo.setTrackEffects(channel: 0, effects: [first]),
        EngineResult.ok,
      );
      final before = repo.trackEffects(0);
      expect(
        repo.setTrackEffects(
          channel: 0,
          effects: [BuiltInEffect(type: TrackEffectType.filter)],
        ),
        EngineResult.notReady,
      );
      expect(repo.trackEffects(0), before);
      expect(
        await repo.settleFxRecipes(attempts: 1, pollInterval: Duration.zero),
        EngineResult.notReady,
      );
      engine.publishRecipe((FxOwner.track, 0, 0));
      expect(await repo.settleFxRecipes(), EngineResult.ok);
      engine.publishRecipes = true;
      expect(
        repo.setTrackEffects(
          channel: 0,
          effects: [BuiltInEffect(type: TrackEffectType.filter)],
        ),
        EngineResult.ok,
      );
    },
  );

  test(
    'editor wait survives a short deadline and cancels on engine lifetime',
    () async {
      engine.publishRecipes = false;
      expect(
        repo.setTrackEffects(
          channel: 0,
          effects: [BuiltInEffect(type: TrackEffectType.filter)],
        ),
        EngineResult.ok,
      );
      var completed = false;
      final late = repo
          .settleFxRecipes(
            attempts: 1,
            pollInterval: const Duration(milliseconds: 2),
            waitForCallback: true,
          )
          .then((result) {
            completed = true;
            return result;
          });
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(completed, isFalse);
      engine.publishRecipe((FxOwner.track, 0, 0));
      expect(await late, EngineResult.ok);

      expect(
        repo.setTrackEffects(
          channel: 0,
          effects: [BuiltInEffect(type: TrackEffectType.drive)],
        ),
        EngineResult.ok,
      );
      final stale = repo.settleFxRecipes(waitForCallback: true);
      repo.stopEngine();
      expect(await stale, EngineResult.notReady);
    },
  );

  test('placement reuses a plugin, changed saved state prepares another', () {
    final originalHandle = MockPluginSlotHandle('original');
    final restoredHandle = MockPluginSlotHandle('restored');
    engine.nextSlotHandle = originalHandle;
    const plugin = PluginEffect(
      ref: PluginRef(format: PluginFormat.clap, id: 'fx'),
      state: 'AQ==',
    );
    expect(
      repo.setLaneEffects(channel: 0, lane: 0, effects: [plugin]),
      EngineResult.ok,
    );
    final stored = repo.laneEffects(0, 0).single as PluginEffect;
    final preparedBefore = engine.calls
        .where((c) => c == 'preparePlugin')
        .length;
    expect(
      repo.setLaneEffectPlacement(
        channel: 0,
        lane: 0,
        slotId: stored.slotId!,
        placement: FxPlacement.pre,
      ),
      EngineResult.ok,
    );
    expect(
      engine.calls.where((c) => c == 'preparePlugin').length,
      preparedBefore,
    );
    expect(
      engine.recipes[(FxOwner.lane, 0, 0)]!.slots.single.plugin,
      same(originalHandle),
    );

    engine.nextSlotHandle = restoredHandle;
    expect(
      repo.setLaneEffects(
        channel: 0,
        lane: 0,
        effects: [stored.copyWith(state: 'Ag==')],
      ),
      EngineResult.ok,
    );
    expect(
      engine.calls.where((c) => c == 'preparePlugin').length,
      preparedBefore + 1,
    );
    expect(
      engine.recipes[(FxOwner.lane, 0, 0)]!.slots.single.plugin,
      same(restoredHandle),
    );
  });

  test('bus plugin remains an explicit unsupported passthrough entry', () {
    const plugin = PluginEffect(
      ref: PluginRef(format: PluginFormat.clap, id: 'bus-fx'),
    );
    expect(
      repo.setTrackEffects(
        channel: 0,
        effects: [
          BuiltInEffect(type: TrackEffectType.drive),
          plugin,
        ],
        allowUnavailable: true,
      ),
      EngineResult.ok,
    );
    final stored = repo.trackEffects(0).last as PluginEffect;
    expect(stored.unsupported, isTrue);
    expect(stored.unavailable, isTrue);
    final slots = engine.recipes[(FxOwner.track, 0, 0)]!.slots;
    expect(slots.map((slot) => slot.type.name), ['drive', 'none']);
    expect(slots.last.plugin, isNull);
    expect(engine.calls, isNot(contains('preparePlugin')));
  });

  test('pending plugin topology refuses live knob and readback until ack', () {
    const plugin = PluginEffect(
      ref: PluginRef(format: PluginFormat.clap, id: 'fx'),
    );
    expect(
      repo.setLaneEffects(
        channel: 0,
        lane: 0,
        effects: [
          BuiltInEffect(type: TrackEffectType.drive),
          plugin,
        ],
      ),
      EngineResult.ok,
    );
    final id = repo.laneEffects(0, 0).last.slotId!;
    engine.publishRecipes = false;
    expect(
      repo.setLaneEffectPlacement(
        channel: 0,
        lane: 0,
        slotId: id,
        placement: FxPlacement.pre,
      ),
      EngineResult.ok,
    );
    expect(
      repo.setLanePluginParam(
        channel: 0,
        lane: 0,
        index: 0,
        paramId: 7,
        value: .4,
      ),
      EngineResult.notReady,
    );
    expect(
      repo.refreshLanePluginParams(channel: 0, lane: 0, index: 0),
      isFalse,
    );
    expect((repo.laneEffects(0, 0).first as PluginEffect).paramValues, isEmpty);
    engine.publishRecipe((FxOwner.lane, 0, 0));
    expect(
      repo.setLanePluginParam(
        channel: 0,
        lane: 0,
        index: 0,
        paramId: 7,
        value: .4,
      ),
      EngineResult.ok,
    );
  });

  test(
    'known missing input plugin is captured dry; fresh clone refusal is not',
    () async {
      engine.nextSnapshot = const EngineSnapshot(
        isRunning: true,
        sampleRate: 48000,
        bufferFrames: 128,
        framesProcessed: 0,
        xrunCount: 0,
        inputRms: 0,
        inputPeak: 0,
        outputRms: 0,
        latencyState: LatencyState.idle,
        measuredLatencyMs: -1,
        tracks: [TrackSnapshot.empty()],
      );
      expect(await repo.settleMixSettings(), EngineResult.ok);
      const plugin = PluginEffect(
        ref: PluginRef(format: PluginFormat.clap, id: 'missing'),
      );
      engine.nextSlotHandle = null;
      expect(
        repo.setMonitorEffects(
          input: 0,
          effects: [
            BuiltInEffect(type: TrackEffectType.drive),
            plugin,
          ],
          allowUnavailable: true,
        ),
        EngineResult.ok,
      );
      expect(repo.record(), EngineResult.ok);
      final captured = engine.lastRecordImage!.laneFx[0]!;
      expect(captured.slots.map((slot) => slot.type.name), ['drive', 'none']);
      ticker.add(null);
      await Future<void>.delayed(Duration.zero);
      final missing = repo.laneEffects(0, 0).last as PluginEffect;
      expect(missing.unavailable, isTrue);
      expect(missing.loading, isFalse);

      // A fresh take from a previously loaded input needs a new frozen host;
      // failure to make that host refuses the arm rather than inventing dry FX.
      engine
        ..nextSlotHandle = MockPluginSlotHandle('working')
        ..nextState = Uint8List.fromList([1]);
      expect(
        repo.setMonitorEffects(input: 0, effects: [plugin]),
        EngineResult.ok,
      );
      engine
        ..nextSlotHandle = null
        ..lastRecordImage = null;
      expect(repo.record(), EngineResult.invalid);
      expect(engine.lastRecordImage, isNull);
    },
  );

  test(
    'Clear keeps the latest Undo FX behind an older lane revision',
    () async {
      engine.nextSnapshot = _playingTrack;
      expect(
        repo.setLaneEffects(
          channel: 0,
          lane: 0,
          effects: [BuiltInEffect(type: TrackEffectType.drive)],
          chainEnabled: false,
        ),
        EngineResult.ok,
      );
      engine.publishRecipes = false;
      expect(
        repo.setLaneEffects(
          channel: 0,
          lane: 0,
          effects: [BuiltInEffect(type: TrackEffectType.delay)],
          chainEnabled: false,
        ),
        EngineResult.ok,
      );
      expect(repo.clear(), EngineResult.ok);
      engine.undoRestoresClearResult = true;
      expect(repo.undo(), EngineResult.ok);
      expect(engine.calls, isNot(contains('undo')));

      engine.publishRecipe((FxOwner.lane, 0, 0));
      ticker.add(null);
      await Future<void>.delayed(Duration.zero);
      expect(engine.calls, isNot(contains('undo')));
      expect(engine.pendingRecipeRevisions[(FxOwner.lane, 0, 0)], isNotNull);

      engine.publishRecipe((FxOwner.lane, 0, 0));
      ticker.add(null);
      await Future<void>.delayed(Duration.zero);
      expect(engine.calls, contains('undo'));
      expect(
        repo.laneEffects(0, 0).single.typeCode,
        TrackEffectType.delay.code,
      );
      expect(repo.laneChainEnabled(0, 0), isFalse);
    },
  );

  test('reentrant FX settlement drains each queued lane only once', () async {
    engine.nextSnapshot = _playingTrack;
    expect(repo.setLaneCount(channel: 0, count: 2), EngineResult.ok);
    engine.publishRecipes = false;
    for (var lane = 0; lane < 2; lane++) {
      expect(
        repo.setLaneEffects(
          channel: 0,
          lane: lane,
          effects: [BuiltInEffect(type: TrackEffectType.delay)],
        ),
        EngineResult.ok,
      );
    }
    expect(repo.clear(), EngineResult.ok);
    for (var lane = 0; lane < 2; lane++) {
      engine.publishRecipe((FxOwner.lane, 0, lane));
    }
    engine.publishRecipes = true;
    final notices = <(int, int)>[];
    final reentrant = <Future<EngineResult>>[];
    repo.onLaneChainChanged = (channel, lane) {
      notices.add((channel, lane));
      reentrant.add(repo.settleFxRecipes());
    };
    final recipesBefore = engine.calls.where((c) => c == 'setFxRecipe').length;

    expect(await repo.settleFxRecipes(), EngineResult.ok);
    expect(await Future.wait(reentrant), everyElement(EngineResult.ok));
    expect(
      engine.calls.where((c) => c == 'setFxRecipe').length - recipesBefore,
      2,
    );
    expect(notices, [(0, 0), (0, 1)]);
    for (var lane = 0; lane < 2; lane++) {
      expect(engine.recipes[(FxOwner.lane, 0, lane)]!.slots, isEmpty);
    }
    expect(repo.fxRecipesSettled, isTrue);
  });

  test('reading FX readiness cannot submit a queued Clear recipe', () async {
    engine.nextSnapshot = _playingTrack;
    expect(
      repo.setLaneEffects(
        channel: 0,
        lane: 0,
        effects: [BuiltInEffect(type: TrackEffectType.drive)],
      ),
      EngineResult.ok,
    );
    engine.publishRecipes = false;
    expect(
      repo.setLaneEffects(
        channel: 0,
        lane: 0,
        effects: [BuiltInEffect(type: TrackEffectType.delay)],
      ),
      EngineResult.ok,
    );
    expect(repo.clear(), EngineResult.ok);
    engine.publishRecipe((FxOwner.lane, 0, 0));
    final callsBeforeRead = engine.calls.length;

    expect(repo.fxRecipesSettled, isFalse);
    expect(engine.calls.length, callsBeforeRead);
    expect(engine.pendingRecipeRevisions, isEmpty);

    engine.publishRecipes = true;
    expect(await repo.settleFxRecipes(), EngineResult.ok);
    expect(engine.recipes[(FxOwner.lane, 0, 0)]!.slots, isEmpty);
    expect(repo.fxRecipesSettled, isTrue);
  });

  test('Clear blocks dry rerecord until its reset recipe applies', () async {
    engine.nextSnapshot = _playingTrack;
    expect(
      repo.setLaneEffects(
        channel: 0,
        lane: 0,
        effects: [BuiltInEffect(type: TrackEffectType.filter)],
      ),
      EngineResult.ok,
    );
    engine.publishRecipes = false;
    expect(repo.clear(), EngineResult.ok);
    engine.nextSnapshot = _playingTrack.copyWith(
      tracks: const [TrackSnapshot.empty()],
    );
    expect(repo.record(), EngineResult.notReady);
    engine.publishRecipe((FxOwner.lane, 0, 0));
    ticker.add(null);
    await Future<void>.delayed(Duration.zero);
    expect(repo.record(), EngineResult.ok);
    expect(repo.laneEffects(0, 0), isEmpty);
  });

  test('refused native Clear preserves FX and emits no chain save', () {
    engine.nextSnapshot = _playingTrack;
    expect(
      repo.setLaneEffects(
        channel: 0,
        lane: 0,
        effects: [BuiltInEffect(type: TrackEffectType.drive)],
        chainEnabled: false,
      ),
      EngineResult.ok,
    );
    final before = repo.laneEffects(0, 0);
    var notices = 0;
    repo.onLaneChainChanged = (_, _) => notices++;
    engine.nextClearUndoableResult = EngineResult.notReady;
    expect(repo.clear(), EngineResult.notReady);
    expect(repo.laneEffects(0, 0), before);
    expect(repo.laneChainEnabled(0, 0), isFalse);
    expect(notices, 0);
  });

  test(
    'refused arm keeps old chain and accepted image waits for capture ack',
    () async {
      engine.nextSnapshot = const EngineSnapshot(
        isRunning: true,
        sampleRate: 48000,
        bufferFrames: 128,
        framesProcessed: 0,
        xrunCount: 0,
        inputRms: 0,
        inputPeak: 0,
        outputRms: 0,
        latencyState: LatencyState.idle,
        measuredLatencyMs: -1,
        tracks: [TrackSnapshot.empty()],
      );
      expect(await repo.settleMixSettings(), EngineResult.ok);
      expect(
        repo.setMonitorEffects(
          input: 0,
          effects: [BuiltInEffect(type: TrackEffectType.delay)],
        ),
        EngineResult.ok,
      );
      var changed = 0;
      repo.onLaneChainChanged = (_, _) => changed++;
      engine.recordResult = EngineResult.invalid;
      expect(repo.record(), EngineResult.invalid);
      expect(
        engine.lastRecordImage!.laneFx[0]!.slots.single.type.name,
        'delay',
      );
      expect(repo.laneEffects(0, 0), isEmpty);
      expect(changed, 0);
      expect(engine.recipes.containsKey((FxOwner.lane, 0, 0)), isFalse);

      engine
        ..recordResult = EngineResult.ok
        ..publishRecordImages = false
        ..commandsAreSettled = false;
      expect(repo.record(), EngineResult.ok);
      expect(repo.laneEffects(0, 0), isEmpty);
      expect(changed, 0);
      engine
        ..publishImage(0)
        ..commandsAreSettled = true;
      ticker.add(null);
      await Future<void>.delayed(Duration.zero);
      expect(
        repo.laneEffects(0, 0).single.typeCode,
        TrackEffectType.delay.code,
      );
      expect(changed, 1);
    },
  );
}
