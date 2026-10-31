import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno_engine/segno_engine.dart'
    as le
    show EngineSnapshot, FxOwner, LatencyState, TrackSnapshot;

import 'helpers/fake_audio_engine.dart';

/// Ed's Rack, the plan's unit: 2,665 ns a frame at 96 kHz / 64 frames. The
/// budget there is 7,192, so two fit on the callback and a third does not.
List<TrackEffect> _rack() => [
  for (final type in [
    TrackEffectType.dualOctaver,
    TrackEffectType.wah,
    TrackEffectType.compressor,
    TrackEffectType.overdrive,
    TrackEffectType.ampCab,
    TrackEffectType.chorus,
    TrackEffectType.roomVerb,
    TrackEffectType.modeDelay,
    TrackEffectType.eq,
  ])
    BuiltInEffect(type: type),
];

const _empty = [
  le.TrackSnapshot.empty(),
  le.TrackSnapshot.empty(),
  le.TrackSnapshot.empty(),
  le.TrackSnapshot.empty(),
  le.TrackSnapshot.empty(),
  le.TrackSnapshot.empty(),
  le.TrackSnapshot.empty(),
  le.TrackSnapshot.empty(),
];

const _running = le.EngineSnapshot(
  isRunning: true,
  sampleRate: 96000,
  bufferFrames: 64,
  inputChannels: 8,
  outputChannels: 4,
  framesProcessed: 0,
  xrunCount: 0,
  inputRms: 0,
  inputPeak: 0,
  outputRms: 0,
  latencyState: le.LatencyState.idle,
  measuredLatencyMs: -1,
  tracks: _empty,
);

FxAddress _input(int index) => FxAddress(stage: FxStage.input, index: index);

FxAddress _lane(int track, [int lane = 0]) =>
    FxAddress(stage: FxStage.loop, index: track, lane: lane);

void main() {
  late FakeAudioEngine engine;
  late LooperRepository repo;

  setUp(() {
    engine = FakeAudioEngine()..nextSnapshot = _running;
    repo = LooperRepository(engine: engine)
      ..startEngine(const EngineConfig(sampleRate: 96000));
    addTearDown(repo.dispose);
  });

  test("Ed's Rack charges what the tests assume", () {
    expect(fxChainCostNs(_rack()), 2665);
    expect(fxBudgetNs(96000), 7192);
  });

  group('R1: a take whose inherited chains do not fit', () {
    test('a take with room keeps its inherited chain on', () {
      repo
        ..setMonitorEffects(input: 0, effects: _rack())
        ..record();
      expect(repo.laneEffects(0, 0), hasLength(9));
      expect(repo.fxChainHeld(_lane(0)), isFalse);
      expect(repo.state.fxHeld, isEmpty);
    });

    test('records, keeps the chain by value switched off, says so once, '
        'and never saves the switch-off', () async {
      final toasts = <int>[];
      final sub = repo.fxTakeHeld.listen(toasts.add);
      addTearDown(sub.cancel);
      repo
        ..setMonitorEffects(input: 0, effects: _rack())
        ..record()
        ..record(channel: 1);
      // The second take's rack would be the third on the callback.
      expect(repo.laneEffects(1, 0), hasLength(9));
      expect(repo.fxChainHeld(_lane(1)), isTrue);
      expect(repo.fxChainHeld(_lane(0)), isFalse);
      expect(repo.state.fxHeld, {_lane(1)});
      // The engine runs it off from its first block: the take's recipe.
      expect(engine.recipes[(le.FxOwner.lane, 1, 0)]!.enabled, isFalse);
      expect(engine.recipes[(le.FxOwner.lane, 0, 0)]!.enabled, isTrue);
      // Its saved switch is the player's: on.
      expect(repo.laneChainEnabled(1, 0), isTrue);
      expect(repo.allLaneChains()[(1, 0)]!.chainEnabled, isTrue);
      // It charges nothing, so the rig fits.
      expect(repo.fxRoomNs, greaterThanOrEqualTo(0));
      await pumpEventQueue();
      expect(toasts, [1]);
      // No standing notice for a take: the toast is its only notice.
      expect(repo.state.fxHoldNotice, isEmpty);
    });

    test('switching it on is refused while the rig has no room, and allowed '
        'once room is made', () {
      repo
        ..setMonitorEffects(input: 0, effects: _rack())
        ..record()
        ..record(channel: 1);
      expect(repo.fxHeldChainFits(_lane(1)), isFalse);
      expect(
        repo.setLaneChainEnabled(channel: 1, lane: 0, enabled: true),
        EngineResult.capacity,
      );
      expect(repo.fxChainHeld(_lane(1)), isTrue);
      // The input's own chain goes: one rack on the callback, room for one.
      repo.setMonitorEffects(input: 0, effects: const []);
      expect(repo.fxHeldChainFits(_lane(1)), isTrue);
      expect(
        repo.setLaneChainEnabled(channel: 1, lane: 0, enabled: true),
        EngineResult.ok,
      );
      expect(repo.fxChainHeld(_lane(1)), isFalse);
      expect(engine.laneFxChainEnabled[(1, 0)], isTrue);
      expect(repo.state.fxHeld, isEmpty);
    });

    test('takes started together are weighed together', () {
      // Neither take has had its first block: each must count the other.
      engine.publishRecordImages = false;
      repo
        ..setMonitorEffects(input: 0, effects: _rack())
        ..record()
        ..record(channel: 1);
      engine
        ..publishImage(0)
        ..publishImage(1);
      // The takes land on the next projection.
      repo.setTrackChainEnabled(channel: 7, enabled: true);
      expect(repo.laneEffects(1, 0), hasLength(9));
      expect(repo.fxChainHeld(_lane(0)), isFalse);
      expect(repo.fxChainHeld(_lane(1)), isTrue);
    });

    test("an input chain that is off because it didn't fit is heard dry, "
        'so a take does not copy it', () {
      repo
        ..setMonitorEffects(input: 0, effects: _rack())
        ..setMonitorEffects(input: 1, effects: _rack())
        ..setMonitorEffects(input: 2, effects: _rack());
      expect(repo.fxChainHeld(_input(2)), isTrue);
      repo
        ..setLaneInput(channel: 0, lane: 0, inputChannel: 2)
        ..record();
      expect(repo.laneEffects(0, 0), isEmpty);
    });

    test('a dry input inherits as before', () {
      repo.record();
      expect(repo.laneEffects(0, 0), isEmpty);
      expect(repo.state.fxHeld, isEmpty);
    });
  });

  group('R2: a rig that comes up over budget', () {
    test('holds the newest stage first, names what was on, and saves '
        'nothing', () {
      // The boot restore lands chain by chain on a running engine: a lane's,
      // then two inputs'. The third rack holds the lane, not the input.
      repo
        ..setLaneEffects(channel: 2, lane: 0, effects: _rack())
        ..setMonitorEffects(input: 0, effects: _rack())
        ..setMonitorEffects(input: 1, effects: _rack());
      expect(repo.fxChainHeld(_lane(2)), isTrue);
      expect(repo.fxChainHeld(_input(0)), isFalse);
      expect(repo.fxChainHeld(_input(1)), isFalse);
      // The live lane is switched off on the engine before the input's
      // recipe goes out; that recipe is on.
      expect(engine.laneFxChainEnabled[(2, 0)], isFalse);
      expect(engine.recipes[(le.FxOwner.monitor, 1, 0)]!.enabled, isTrue);
      expect(repo.state.fxHoldNotice, [_lane(2)]);
      expect(repo.allLaneChains()[(2, 0)]!.chainEnabled, isTrue);
      expect(repo.allLaneChains()[(2, 0)]!.entries, hasLength(9));
      // A fourth: the inputs are next, the highest first.
      repo.setMonitorEffects(input: 3, effects: _rack());
      expect(repo.fxChainHeld(_input(3)), isTrue);
      expect(engine.recipes[(le.FxOwner.monitor, 3, 0)]!.enabled, isFalse);
      expect(repo.state.fxHoldNotice, [_lane(2), _input(3)]);
      expect(repo.monitorChainEnabled(3), isTrue);
      expect(repo.fxRoomNs, greaterThanOrEqualTo(0));
    });

    test('a chain the player had off is held without a notice', () {
      repo
        ..setLaneEffects(channel: 2, lane: 0, effects: _rack())
        ..setLaneChainEnabled(channel: 2, lane: 0, enabled: false)
        ..setMonitorEffects(input: 0, effects: _rack())
        ..setMonitorEffects(input: 1, effects: _rack());
      expect(repo.fxChainHeld(_lane(2)), isTrue);
      expect(repo.state.fxHoldNotice, isEmpty);
    });

    test('emptying a held chain drops its hold, and a new chain there is '
        'weighed afresh', () {
      repo
        ..setMonitorEffects(input: 0, effects: _rack())
        ..setMonitorEffects(input: 1, effects: _rack())
        ..setMonitorEffects(input: 2, effects: _rack())
        ..setMonitorEffects(input: 2, effects: const []);
      expect(repo.state.fxHeld, isEmpty);
      expect(repo.state.fxHoldNotice, isEmpty);
      repo
        ..setMonitorEffects(input: 1, effects: const [])
        ..setMonitorEffects(input: 2, effects: _rack());
      expect(repo.fxChainHeld(_input(2)), isFalse);
    });

    test('a notice left over from a rig that fits no longer swallows a '
        "take's toast", () async {
      final toasts = <int>[];
      final sub = repo.fxTakeHeld.listen(toasts.add);
      addTearDown(sub.cancel);
      repo
        ..setMonitorEffects(input: 0, effects: _rack())
        ..setMonitorEffects(input: 1, effects: _rack())
        ..setMonitorEffects(input: 2, effects: _rack());
      expect(repo.state.fxHoldNotice, [_input(2)]);
      // More room at the next start: everything comes back on.
      engine.fxWorkersRunning = 2;
      repo
        ..stopEngine()
        ..startEngine(const EngineConfig(sampleRate: 96000));
      expect(repo.state.fxHoldNotice, isEmpty);
      // A fourth input rack still fits the workers; a take's copy does not.
      repo
        ..setMonitorEffects(input: 3, effects: _rack())
        ..record();
      expect(repo.state.fxHoldNotice, isEmpty);
      expect(repo.fxChainHeld(_lane(0)), isTrue);
      await pumpEventQueue();
      expect(toasts, [0]);
    });

    test('dismissing the notice keeps the chains off', () {
      repo
        ..setMonitorEffects(input: 0, effects: _rack())
        ..setMonitorEffects(input: 1, effects: _rack())
        ..setMonitorEffects(input: 2, effects: _rack())
        ..dismissFxHoldNotice();
      expect(repo.state.fxHoldNotice, isEmpty);
      expect(repo.fxChainHeld(_input(2)), isTrue);
    });

    test('a take that does not fit while the notice stands joins it '
        'instead of a toast', () async {
      final toasts = <int>[];
      final sub = repo.fxTakeHeld.listen(toasts.add);
      addTearDown(sub.cancel);
      repo
        ..setMonitorEffects(input: 0, effects: _rack())
        ..setMonitorEffects(input: 1, effects: _rack())
        ..setMonitorEffects(input: 2, effects: _rack())
        ..record();
      expect(repo.fxChainHeld(_lane(0)), isTrue);
      expect(repo.state.fxHoldNotice, [_input(2), _lane(0)]);
      await pumpEventQueue();
      expect(toasts, isEmpty);
    });

    test('the notice stands until every chain it names is back on', () {
      repo
        ..setMonitorEffects(input: 0, effects: _rack())
        ..setMonitorEffects(input: 1, effects: _rack())
        ..setMonitorEffects(input: 2, effects: _rack())
        ..setMonitorEffects(input: 0, effects: const []);
      expect(repo.state.fxHoldNotice, [_input(2)]);
      expect(
        repo.setMonitorChainEnabled(input: 2, enabled: true),
        EngineResult.ok,
      );
      expect(repo.state.fxHoldNotice, isEmpty);
      expect(repo.state.fxHeld, isEmpty);
    });

    test('without its workers a rig is held; with them back, everything is '
        'on as saved', () {
      // Four racks on the inputs fit two workers (the per-core rule).
      engine.fxWorkersRunning = 2;
      repo
        ..stopEngine()
        ..startEngine(const EngineConfig(sampleRate: 96000));
      for (var input = 0; input < 4; input++) {
        repo.setMonitorEffects(input: input, effects: _rack());
      }
      expect(repo.state.fxHeld, isEmpty);
      // The workers do not start: the same rig comes up held.
      engine.fxWorkersRunning = 0;
      repo
        ..stopEngine()
        ..startEngine(const EngineConfig(sampleRate: 96000));
      expect(repo.state.fxHeld, {_input(2), _input(3)});
      expect(repo.state.fxHoldNotice, [_input(3), _input(2)]);
      expect(repo.monitorChainEnabled(3), isTrue);
      // They are back: nothing is held.
      engine.fxWorkersRunning = 2;
      repo
        ..stopEngine()
        ..startEngine(const EngineConfig(sampleRate: 96000));
      expect(repo.state.fxHeld, isEmpty);
      expect(repo.state.fxHoldNotice, isEmpty);
    });
  });

  test('an edit that adds processing to a held chain changes no load', () {
    repo
      ..setMonitorEffects(input: 0, effects: _rack())
      ..setMonitorEffects(input: 1, effects: _rack())
      ..setMonitorEffects(input: 2, effects: _rack());
    expect(
      repo.fxGrowthNs({
        _input(2): [..._rack(), ..._rack()],
      }),
      0,
    );
  });
}
