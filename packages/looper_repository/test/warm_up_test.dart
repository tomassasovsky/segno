import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno_engine/segno_engine.dart'
    show EngineSnapshot, latencyLoopbackInput;
import 'package:segno_engine/segno_engine.dart' as le show AudioDevice;

import 'helpers/fake_audio_engine.dart';

const _scarlett = le.AudioDevice(
  id: 'out-1',
  name: 'Scarlett 4i4',
  isDefault: false,
  isInput: false,
);

/// The audio warm-up (#1533): a start the console makes on its own opens the
/// player's rate with the largest buffer, silent and with the transport
/// closed, and [LooperRepository.finishWarmUp] opens the player's config. What
/// opens then owes its record offset (#1541): still silent and closed until
/// [LooperRepository.setRecordOffset] sets it.
void main() {
  late FakeAudioEngine engine;
  late StreamController<void> ticker;
  late StreamController<void> reconnect;

  const player = EngineConfig(
    sampleRate: 48000,
    bufferFrames: 32,
    playbackDeviceId: 'out-1',
  );

  setUp(() {
    engine = FakeAudioEngine()
      ..nextSnapshot = const EngineSnapshot.initial().copyWith(
        isRunning: true,
        devicePresent: true,
        sampleRate: 48000,
        bufferFrames: kWarmUpBufferFrames,
      );
    ticker = StreamController<void>.broadcast();
    reconnect = StreamController<void>.broadcast();
  });

  tearDown(() async {
    await ticker.close();
    await reconnect.close();
  });

  LooperRepository build() {
    final repo = LooperRepository(
      engine: engine,
      ticker: ticker.stream,
      reconnectTicker: reconnect.stream,
    );
    addTearDown(repo.dispose);
    return repo;
  }

  LooperRepository warm() {
    final repo = build();
    expect(repo.startEngine(player, warmUp: true), EngineResult.ok);
    return repo;
  }

  int count(String call) => engine.calls.where((c) => c == call).length;

  group('a warm start', () {
    test("opens the player's rate with the largest buffer", () {
      final repo = warm();

      expect(engine.lastConfig?.sampleRate, 48000);
      expect(engine.lastConfig?.bufferFrames, kWarmUpBufferFrames);
      expect(engine.lastConfig?.playbackDeviceId, 'out-1');
      expect(repo.state.status.warmingUp, isTrue);
    });

    test("reports the player's config, never the warm-up buffer", () {
      final repo = warm();

      expect(repo.lastEngineConfig, player);
    });

    test('runs silent without forgetting the master gain', () {
      final repo = build()..setMasterGain(0.8);
      expect(repo.startEngine(player, warmUp: true), EngineResult.ok);

      expect(engine.lastMasterGain, 0);
      expect(repo.masterGain, 0.8);

      // A change made meanwhile is remembered, and still not heard.
      repo.setMasterGain(0.6);
      expect(engine.lastMasterGain, 0);
      expect(repo.masterGain, 0.6);
    });

    test('closes the transport', () async {
      final repo = warm();
      engine.calls.clear();

      expect(repo.record(), EngineResult.notReady);
      expect(repo.play(), EngineResult.notReady);
      expect(repo.clear(), EngineResult.notReady);
      expect(repo.clearAll(const [0]), EngineResult.notReady);
      expect(repo.undo(), EngineResult.notReady);
      expect(repo.redo(), EngineResult.notReady);
      expect(repo.peel(), EngineResult.notReady);
      expect(
        await repo.editLength(channel: 0, edit: LengthEdit.doubled),
        EngineResult.notReady,
      );
      expect(count('record'), 0);
      expect(count('play'), 0);
    });

    test('refuses a cable measurement', () async {
      final repo = warm();

      final result = await repo.measureLatency(output: 0, input: 0);

      expect(result.outcome, LatencyOutcome.refused);
      expect(count('measureLatencyPath'), 0);
    });

    test('is skipped when the player already runs the largest buffer, and '
        'the record offset is owed', () {
      final repo = build()..setMasterGain(0.8);
      const large = EngineConfig(
        sampleRate: 48000,
        bufferFrames: kWarmUpBufferFrames,
        playbackDeviceId: 'out-1',
      );

      expect(repo.startEngine(large, warmUp: true), EngineResult.ok);

      expect(engine.lastConfig?.bufferFrames, kWarmUpBufferFrames);
      expect(repo.state.status.warmingUp, isFalse);
      expect(repo.state.status.recordOffsetOwed, isTrue);
      expect(engine.masterGains, everyElement(0));
      expect(repo.record(), EngineResult.notReady);

      repo.setRecordOffset(300);

      expect(repo.state.status.recordOffsetOwed, isFalse);
      expect(engine.lastMasterGain, 0.8);
      expect(repo.record(), isNot(EngineResult.notReady));
    });

    test('a plain start runs the config as given, owing nothing', () {
      final repo = build()..setMasterGain(0.8);

      expect(repo.startEngine(player), EngineResult.ok);

      expect(engine.lastConfig?.bufferFrames, 32);
      expect(repo.state.status.warmingUp, isFalse);
      expect(repo.state.status.recordOffsetOwed, isFalse);
      expect(engine.lastMasterGain, 0.8);
    });

    test('a stop ends it', () {
      final repo = warm()..stopEngine();

      expect(repo.state.status.warmingUp, isFalse);
      expect(repo.lastEngineConfig, player);
    });
  });

  group('finishWarmUp', () {
    test("opens the player's config, keeping the loops, silent until its "
        'record offset is set', () {
      final repo = build()..setMasterGain(0.8);
      expect(repo.startEngine(player, warmUp: true), EngineResult.ok);
      engine
        ..calls.clear()
        ..masterGains.clear()
        // The device opens the buffer asked for.
        ..nextSnapshot = engine.nextSnapshot.copyWith(bufferFrames: 32);

      final outcome = repo.finishWarmUp();

      expect(outcome.status, AudioApplyStatus.applied);
      expect(engine.calls, containsAllInOrder(<String>['stop', 'reopen']));
      expect(count('start'), 0);
      expect(engine.lastConfig?.bufferFrames, 32);
      expect(repo.state.status.warmingUp, isFalse);
      expect(repo.state.status.recordOffsetOwed, isTrue);
      expect(repo.lastEngineConfig, player);
      // Never heard before the offset: not one gain but 0 reached the engine.
      expect(engine.masterGains, everyElement(0));
      expect(repo.record(), EngineResult.notReady);

      repo.setRecordOffset(420);

      expect(engine.lastRecordOffset, 420);
      expect(engine.lastMasterGain, 0.8);
      expect(repo.state.status.recordOffsetOwed, isFalse);
      expect(repo.record(), isNot(EngineResult.notReady));
    });

    test('a buffer the device rounded owes its offset the same way', () {
      final repo = warm();
      // Asked 32, opened 48.
      engine.nextSnapshot = engine.nextSnapshot.copyWith(bufferFrames: 48);

      expect(repo.finishWarmUp().status, AudioApplyStatus.applied);

      expect(repo.state.status.bufferFrames, 48);
      expect(repo.state.status.recordOffsetOwed, isTrue);
    });

    test('replays the record offset set before it', () {
      final repo = warm()..setRecordOffset(300);
      engine.lastRecordOffset = null;

      repo.finishWarmUp();

      expect(engine.lastRecordOffset, 300);
    });

    test('a refused config leaves the warm-up config running, heard', () {
      final repo = build()..setMasterGain(0.8);
      expect(repo.startEngine(player, warmUp: true), EngineResult.ok);
      engine.reopenResult = (
        result: EngineResult.device,
        outcome: ReopenOutcome.retained,
        droppedTracks: 0,
        openedRate: 0,
      );
      var reopens = 0;
      engine.afterSnapshot = () {
        if (count('reopen') > reopens) {
          reopens = count('reopen');
          engine.reopenResult = (
            result: EngineResult.ok,
            outcome: ReopenOutcome.retained,
            droppedTracks: 0,
            openedRate: 0,
          );
        }
      };

      final outcome = repo.finishWarmUp();

      expect(outcome.status, AudioApplyStatus.refused);
      expect(engine.lastConfig?.bufferFrames, kWarmUpBufferFrames);
      expect(repo.state.status.warmingUp, isFalse);
      expect(repo.lastEngineConfig, player.warmUp);
      // It runs as the player's now, so it owes its own offset first.
      expect(repo.state.status.recordOffsetOwed, isTrue);
      expect(engine.lastMasterGain, 0);

      repo.setRecordOffset(0);

      expect(engine.lastMasterGain, 0.8);
    });

    test('a switch that lost loops says so on the status', () {
      final repo = warm();
      engine.reopenResult = (
        result: EngineResult.ok,
        outcome: ReopenOutcome.retainedPartial,
        droppedTracks: 1 << 2,
        openedRate: 0,
      );

      final outcome = repo.finishWarmUp();

      expect(outcome.status, AudioApplyStatus.applied);
      expect(repo.state.status.reopen?.droppedChannels, [2]);
    });

    test('a switch that kept every loop leaves no verdict', () {
      final repo = warm()..finishWarmUp();

      expect(repo.state.status.reopen, isNull);
    });

    test('changes nothing when no warm-up runs', () {
      final repo = build();
      expect(repo.startEngine(player), EngineResult.ok);
      engine.calls.clear();

      final outcome = repo.finishWarmUp();

      expect(outcome.status, AudioApplyStatus.applied);
      expect(engine.calls, isEmpty);
    });
  });

  group("the player's own apply", () {
    test('ends a warm-up', () {
      final repo = build()..setMasterGain(0.8);
      expect(repo.startEngine(player, warmUp: true), EngineResult.ok);
      const other = EngineConfig(
        sampleRate: 48000,
        bufferFrames: 64,
        playbackDeviceId: 'out-1',
      );

      final outcome = repo.applyAudioConfig(other);

      expect(outcome.status, AudioApplyStatus.applied);
      expect(repo.state.status.warmingUp, isFalse);
      expect(repo.state.status.recordOffsetOwed, isTrue);
      expect(repo.lastEngineConfig, other);

      repo.setRecordOffset(0);

      expect(engine.lastMasterGain, 0.8);
    });
  });

  group('a reconnect', () {
    Future<void> unplugAndReturn(LooperRepository repo) async {
      final sub = repo.looperState.listen((_) {});
      addTearDown(sub.cancel);
      engine.nextSnapshot = engine.nextSnapshot.copyWith(devicePresent: false);
      ticker.add(null);
      await Future<void>.delayed(Duration.zero);
      engine
        ..devices = const [_scarlett]
        ..nextSnapshot = engine.nextSnapshot.copyWith(devicePresent: true);
      reconnect.add(null);
      await Future<void>.delayed(Duration.zero);
    }

    test("warms up again after the player's config ran", () async {
      final repo = build()..setMasterGain(0.8);
      expect(repo.startEngine(player), EngineResult.ok);
      engine.calls.clear();

      await unplugAndReturn(repo);

      expect(count('reopen'), 1);
      expect(engine.lastConfig?.bufferFrames, kWarmUpBufferFrames);
      expect(repo.state.status.warmingUp, isTrue);
      expect(repo.lastEngineConfig, player);
      expect(engine.lastMasterGain, 0);

      repo.finishWarmUp();
      expect(engine.lastConfig?.bufferFrames, 32);
      expect(engine.lastMasterGain, 0);
      repo.setRecordOffset(300);
      expect(engine.lastMasterGain, 0.8);
    });

    test("after a refused switch retries the player's config", () async {
      final repo = warm();
      engine.reopenResult = (
        result: EngineResult.device,
        outcome: ReopenOutcome.retained,
        droppedTracks: 0,
        openedRate: 0,
      );
      var reopens = 0;
      engine.afterSnapshot = () {
        if (count('reopen') > reopens) {
          reopens = count('reopen');
          engine.reopenResult = (
            result: EngineResult.ok,
            outcome: ReopenOutcome.retained,
            droppedTracks: 0,
            openedRate: 0,
          );
        }
      };
      expect(repo.finishWarmUp().status, AudioApplyStatus.refused);
      expect(repo.state.status.warmingUp, isFalse);
      engine
        ..afterSnapshot = null
        ..calls.clear();

      await unplugAndReturn(repo);

      // Not the 512 config that ran in its place: a warm-up for the player's.
      expect(count('reopen'), 1);
      expect(engine.lastConfig?.bufferFrames, kWarmUpBufferFrames);
      expect(repo.state.status.warmingUp, isTrue);
      expect(repo.lastEngineConfig, player);
      engine.nextSnapshot = engine.nextSnapshot.copyWith(bufferFrames: 32);
      expect(repo.finishWarmUp().status, AudioApplyStatus.applied);
      expect(engine.lastConfig?.bufferFrames, 32);
    });

    test('of a config that needs no warm-up keeps an owed offset owed '
        '(#1541)', () async {
      const large = EngineConfig(
        sampleRate: 48000,
        bufferFrames: kWarmUpBufferFrames,
        playbackDeviceId: 'out-1',
      );
      final repo = build()..setMasterGain(0.8);
      expect(repo.startEngine(large, warmUp: true), EngineResult.ok);
      engine.calls.clear();

      await unplugAndReturn(repo);

      expect(count('reopen'), 1);
      expect(repo.state.status.recordOffsetOwed, isTrue);
      expect(engine.lastMasterGain, 0);
    });

    test(
      'of a config that needs no warm-up owes nothing once it was set',
      () async {
        const large = EngineConfig(
          sampleRate: 48000,
          bufferFrames: kWarmUpBufferFrames,
          playbackDeviceId: 'out-1',
        );
        final repo = build()..setMasterGain(0.8);
        expect(repo.startEngine(large, warmUp: true), EngineResult.ok);
        repo.setRecordOffset(300);
        engine.calls.clear();

        await unplugAndReturn(repo);

        expect(count('reopen'), 1);
        expect(repo.state.status.recordOffsetOwed, isFalse);
        expect(engine.lastMasterGain, 0.8);
        expect(engine.lastRecordOffset, 300);
      },
    );

    test('during a warm-up keeps its target', () async {
      final repo = warm();
      engine.calls.clear();

      await unplugAndReturn(repo);

      expect(count('reopen'), 1);
      expect(engine.lastConfig?.bufferFrames, kWarmUpBufferFrames);
      expect(repo.lastEngineConfig, player);
      expect(repo.state.status.warmingUp, isTrue);
    });
  });

  group('an owed record offset (#1541)', () {
    LooperRepository playing() {
      final repo = build()..setMasterGain(0.8);
      expect(repo.startEngine(player), EngineResult.ok);
      engine.nextSnapshot = engine.nextSnapshot.copyWith(bufferFrames: 32);
      return repo;
    }

    const other = EngineConfig(
      sampleRate: 48000,
      bufferFrames: 64,
      playbackDeviceId: 'out-1',
    );

    test('follows an applied config: silent and closed until it is set', () {
      final repo = playing();
      engine.masterGains.clear();

      expect(repo.applyAudioConfig(other).status, AudioApplyStatus.applied);

      expect(repo.state.status.recordOffsetOwed, isTrue);
      expect(repo.state.status.starting, isTrue);
      expect(engine.masterGains, everyElement(0));
      expect(repo.record(), EngineResult.notReady);

      repo.setRecordOffset(250);

      expect(repo.state.status.recordOffsetOwed, isFalse);
      expect(repo.state.status.starting, isFalse);
      expect(engine.lastRecordOffset, 250);
      expect(engine.lastMasterGain, 0.8);
      expect(repo.record(), isNot(EngineResult.notReady));
    });

    test('follows a refused config, the previous one put back', () {
      final repo = playing();
      engine.reopenResult = (
        result: EngineResult.device,
        outcome: ReopenOutcome.retained,
        droppedTracks: 0,
        openedRate: 0,
      );
      var reopens = 0;
      engine.afterSnapshot = () {
        if (count('reopen') > reopens) {
          reopens = count('reopen');
          engine.reopenResult = (
            result: EngineResult.ok,
            outcome: ReopenOutcome.retained,
            droppedTracks: 0,
            openedRate: 0,
          );
        }
      };

      expect(repo.applyAudioConfig(other).status, AudioApplyStatus.refused);

      expect(repo.lastEngineConfig, player);
      expect(repo.state.status.recordOffsetOwed, isTrue);
    });

    test('lets the loopback measurement run, quietly, on the loopback', () {
      final repo = playing()..applyAudioConfig(other);

      unawaited(repo.measureLoopbackLatency());

      expect(engine.lastLatencyPath?.output, 0);
      expect(engine.lastLatencyPath?.input, latencyLoopbackInput);
      expect(engine.lastLatencyPath?.amplitude, 1e-4);
      repo.cancelLatency();
    });

    test('ends with a stop', () {
      final repo = playing()
        ..applyAudioConfig(other)
        ..stopEngine();

      expect(repo.state.status.recordOffsetOwed, isFalse);
    });
  });
}
