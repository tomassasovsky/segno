import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno_engine/segno_engine.dart'
    as le
    show EngineSnapshot, FxOwner, LatencyState, TrackSnapshot, TrackState;
import 'package:segno_engine/segno_engine.dart' show LaneSource;

import 'helpers/fake_audio_engine.dart';

/// Ed's Rack, the plan's unit: 3,407 ns a frame at 96 kHz / 64 frames on the
/// console's own table (#1508, #1724; 2,665 in the plan). The budget there is
/// 6,834, so two fit on the callback and a third does not, and three fit the
/// inputs with two workers and a fourth does not.
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

/// Every track playing a take, so a record press overdubs.
final _playing = le.EngineSnapshot(
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
  tracks: [
    for (var t = 0; t < 8; t++)
      const le.TrackSnapshot(
        state: le.TrackState.playing,
        volume: 1,
        muted: false,
        lengthFrames: 96000,
        undoDepth: 0,
        rms: 0,
        peak: 0,
      ),
  ],
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
    expect(fxChainCostNs(_rack()), 3407);
    expect(fxBudgetNs(96000), 6834);
  });

  group('a take plays what was heard (#1713)', () {
    test('a take records its input chain heard, keeps the chain by value and '
        'charges nothing for it', () {
      repo.setMonitorEffects(input: 0, effects: _rack());
      final input = repo.fxCostNs;
      repo.record();
      expect(engine.lastRecordImage!.heardLanes, {0});
      expect(repo.laneEffects(0, 0), hasLength(9));
      expect(repo.fxChainHeld(_lane(0)), isFalse);
      expect(repo.fxCostNs, input);
      expect(engine.laneSources[(0, 0)], LaneSource.heard);
    });

    test('takes never come in switched off, however many there are', () {
      repo.setMonitorEffects(input: 0, effects: _rack());
      for (var channel = 0; channel < 4; channel++) {
        repo.record(channel: channel);
      }
      for (var channel = 0; channel < 4; channel++) {
        expect(repo.laneEffects(channel, 0), hasLength(9));
        expect(engine.recipes[(le.FxOwner.lane, channel, 0)]!.enabled, isTrue);
      }
      expect(repo.state.fxHeld, isEmpty);
      expect(repo.state.fxHoldNotice, isEmpty);
      expect(repo.fxRoomNs, greaterThanOrEqualTo(0));
    });

    test('takes started together are each heard', () {
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
      expect(repo.fxChainHeld(_lane(0)), isFalse);
      expect(repo.fxChainHeld(_lane(1)), isFalse);
      expect(engine.heardLanes, {(0, 0), (1, 0)});
    });

    test("editing a take's chain re-amps it, charged like any chain, and "
        'editing it back plays what was heard again', () {
      repo
        ..setMonitorEffects(input: 0, effects: _rack())
        ..record();
      final printed = repo.laneEffects(0, 0);
      final before = repo.fxCostNs;
      expect(
        repo.setLaneEffects(
          channel: 0,
          lane: 0,
          effects: printed.sublist(1),
        ),
        EngineResult.ok,
      );
      expect(engine.laneSources[(0, 0)], LaneSource.clean);
      expect(repo.fxCostNs, greaterThan(before));
      expect(repo.lanePrintedWhenEdited(0, 0), printed);
      expect(repo.allLaneChains()[(0, 0)]!.meta!.printed, printed);
      expect(
        repo.setLaneEffects(channel: 0, lane: 0, effects: printed),
        EngineResult.ok,
      );
      expect(engine.laneSources[(0, 0)], LaneSource.heard);
      expect(repo.fxCostNs, before);
      expect(repo.lanePrintedWhenEdited(0, 0), isNull);
    });

    test('a fresh take recorded dry forgets what an earlier take was '
        'printed with', () {
      repo
        ..setMonitorEffects(input: 0, effects: _rack())
        ..record()
        ..setLaneEffects(
          channel: 0,
          lane: 0,
          effects: [BuiltInEffect(type: TrackEffectType.eq)],
        );
      expect(repo.lanePrintedWhenEdited(0, 0), isNotNull);
      engine.heardLanes.clear();
      repo
        ..setMonitorEffects(input: 0, effects: const [])
        ..record();
      expect(engine.lastRecordImage!.heardLanes, isEmpty);
      expect(repo.lanePrintedWhenEdited(0, 0), isNull);
      expect(repo.allLaneChains()[(0, 0)]?.meta?.printed, isNull);
    });

    test("switching a take's chain off plays it clean and dry", () {
      repo
        ..setMonitorEffects(input: 0, effects: _rack())
        ..record()
        ..setLaneChainEnabled(channel: 0, lane: 0, enabled: false);
      expect(engine.laneSources[(0, 0)], LaneSource.clean);
      repo.setLaneChainEnabled(channel: 0, lane: 0, enabled: true);
      expect(engine.laneSources[(0, 0)], LaneSource.heard);
    });

    test('a re-amped take whose chain the rig cannot run falls back to what '
        'was heard, never to dry', () {
      repo
        ..setMonitorEffects(input: 0, effects: _rack())
        ..record();
      repo.setLaneEffects(
        channel: 0,
        lane: 0,
        effects: repo.laneEffects(0, 0).sublist(1),
      );
      expect(engine.laneSources[(0, 0)], LaneSource.clean);
      // A second input rack: the re-amped lane, the newest stage, is held.
      repo.setMonitorEffects(input: 1, effects: _rack());
      expect(repo.fxChainHeld(_lane(0)), isTrue);
      expect(engine.laneSources[(0, 0)], LaneSource.heard);
    });

    test('a take the engine could not give an image plays its chain live, '
        'weighed as a rig is', () {
      engine.refuseHeardImages = true;
      repo
        ..setMonitorEffects(input: 0, effects: _rack())
        ..setMonitorEffects(input: 1, effects: _rack())
        ..record();
      expect(repo.laneEffects(0, 0), hasLength(9));
      expect(repo.fxChainHeld(_lane(0)), isTrue);
      expect(repo.fxRoomNs, greaterThanOrEqualTo(0));
    });

    test("an input chain that is off because it didn't fit is heard dry, "
        'so a take does not copy it or record it heard', () {
      repo
        ..setMonitorEffects(input: 0, effects: _rack())
        ..setMonitorEffects(input: 1, effects: _rack())
        ..setMonitorEffects(input: 2, effects: _rack());
      expect(repo.fxChainHeld(_input(2)), isTrue);
      repo
        ..setLaneInput(channel: 0, lane: 0, inputChannel: 2)
        ..record();
      expect(repo.laneEffects(0, 0), isEmpty);
      expect(engine.lastRecordImage!.heardLanes, isEmpty);
    });

    test('a dry input records clean only', () {
      repo.record();
      expect(repo.laneEffects(0, 0), isEmpty);
      expect(engine.lastRecordImage!.heardLanes, isEmpty);
      expect(repo.state.fxHeld, isEmpty);
    });

    test('an overdub that could not attach an image yet is refused, not '
        'recorded dry', () {
      engine
        ..nextSnapshot = _playing
        ..heardAttachResult = EngineResult.notReady;
      repo.setMonitorEffects(input: 0, effects: _rack());
      engine.calls.clear();
      expect(repo.record(), EngineResult.notReady);
      expect(engine.calls, isNot(contains('record')));
      engine.heardAttachResult = EngineResult.ok;
      expect(repo.record(), EngineResult.ok);
      expect(engine.heardLanes, {(0, 0)});
    });

    test('an overdub over a dry take with no chain of its own records '
        "through the input's effects; one over a take with its own chain "
        'does not', () {
      engine.nextSnapshot = _playing;
      repo
        ..setMonitorEffects(input: 0, effects: _rack())
        ..record();
      expect(engine.calls, contains('heardAttach'));
      expect(engine.heardLanes, {(0, 0)});
      expect(engine.laneSources[(0, 0)], LaneSource.heard);
      // Its take was heard with no chain on the lane: one added re-amps it.
      repo.setLaneEffects(channel: 0, lane: 0, effects: [_rack().first]);
      expect(engine.laneSources[(0, 0)], LaneSource.clean);
      expect(repo.lanePrintedWhenEdited(0, 0), isEmpty);

      engine.calls.clear();
      repo.setLaneEffects(channel: 1, lane: 0, effects: _rack());
      engine.calls.clear();
      repo.record(channel: 1);
      expect(engine.calls, isNot(contains('heardAttach')));
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
      // A control can switch it on, so it is charged though off (#1723).
      repo
        ..setFxReach([
          FxControlReach(whenOn: {FxSwitchKey.chain(_lane(2))}),
        ])
        // Off from the start: switched off just now, its reverb and Mode
        // delay would still be draining (#1733).
        ..setLaneEffects(
          channel: 2,
          lane: 0,
          effects: _rack(),
          chainEnabled: false,
        )
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

    test('a take never joins the standing notice', () {
      repo
        ..setMonitorEffects(input: 0, effects: _rack())
        ..setMonitorEffects(input: 1, effects: _rack())
        ..setMonitorEffects(input: 2, effects: _rack())
        ..record();
      expect(repo.fxChainHeld(_lane(0)), isFalse);
      expect(repo.state.fxHoldNotice, [_input(2)]);
    });

    test('a chain the player has off goes first: holding it changes no '
        'sound', () {
      repo
        ..setFxReach([
          FxControlReach(whenOn: {FxSwitchKey.chain(_input(3))}),
        ])
        ..setMonitorEffects(input: 3, effects: _rack(), chainEnabled: false)
        ..setLaneEffects(channel: 2, lane: 0, effects: _rack())
        ..setMonitorEffects(input: 0, effects: _rack());
      expect(repo.fxChainHeld(_input(3)), isTrue);
      expect(repo.fxChainHeld(_lane(2)), isFalse);
      expect(repo.state.fxHoldNotice, isEmpty);
    });

    test('a chain the player has off that no control reaches charges '
        'nothing, so nothing is held (#1723)', () {
      repo
        ..setMonitorEffects(input: 3, effects: _rack(), chainEnabled: false)
        ..setLaneEffects(channel: 2, lane: 0, effects: _rack())
        ..setMonitorEffects(input: 0, effects: _rack());
      expect(repo.state.fxHeld, isEmpty);
      // A binding that reaches it comes in over budget, as a session's
      // bindings can: it is admitted as a restore is.
      repo.setFxReach([
        FxControlReach(whenOn: {FxSwitchKey.chain(_input(3))}),
      ]);
      expect(repo.fxChainHeld(_input(3)), isTrue);
      expect(repo.fxRoomNs, greaterThanOrEqualTo(0));
      // The binding gone, the hold goes with it.
      repo.setFxReach(const []);
      expect(repo.state.fxHeld, isEmpty);
    });

    test('a chain the player has off that no control reaches is never held: '
        'holding it frees nothing (#1723)', () {
      repo
        ..setMonitorEffects(input: 3, effects: _rack(), chainEnabled: false)
        ..setMonitorEffects(input: 0, effects: _rack())
        ..setMonitorEffects(input: 1, effects: _rack())
        ..setMonitorEffects(input: 2, effects: _rack());
      expect(repo.fxChainHeld(_input(3)), isFalse);
      expect(repo.fxChainHeld(_input(2)), isTrue);
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
      // Three racks on the inputs fit two workers (the per-core rule).
      engine.fxWorkersRunning = 2;
      repo
        ..stopEngine()
        ..startEngine(const EngineConfig(sampleRate: 96000));
      for (var input = 0; input < 3; input++) {
        repo.setMonitorEffects(input: input, effects: _rack());
      }
      expect(repo.state.fxHeld, isEmpty);
      // The workers do not start: the same rig comes up held.
      engine.fxWorkersRunning = 0;
      repo
        ..stopEngine()
        ..startEngine(const EngineConfig(sampleRate: 96000));
      expect(repo.state.fxHeld, {_input(2)});
      expect(repo.state.fxHoldNotice, [_input(2)]);
      expect(repo.monitorChainEnabled(2), isTrue);
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
