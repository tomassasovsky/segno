import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno_engine/segno_engine.dart'
    show EngineSnapshot, ReopenOutcome;
import 'package:segno_engine/segno_engine.dart' as le show AudioDevice;

import 'helpers/fake_audio_engine.dart';

const pinnedDevice = le.AudioDevice(
  id: 'out-1',
  name: 'Scarlett 2i2',
  isDefault: false,
  isInput: false,
);
const otherDevice = le.AudioDevice(
  id: 'out-2',
  name: 'Headphones',
  isDefault: false,
  isInput: false,
);

/// `LooperRepository.applyAudioConfig` and `fxRoomAt` (#1270 Part 3a): an
/// audio-settings change reopens the device and keeps the loops, puts the
/// previous config back when the new one is refused, and never replays an
/// offset measured on another profile.
void main() {
  late FakeAudioEngine engine;
  late StreamController<void> ticker;

  const previous = EngineConfig(
    sampleRate: 48000,
    bufferFrames: 128,
    playbackDeviceId: 'out-1',
  );
  const next = EngineConfig(
    sampleRate: 48000,
    bufferFrames: 256,
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
    ticker = StreamController<void>.broadcast();
  });

  tearDown(() => ticker.close());

  LooperRepository running() {
    final repo = LooperRepository(engine: engine, ticker: ticker.stream);
    addTearDown(repo.dispose);
    expect(repo.startEngine(previous), EngineResult.ok);
    engine.calls.clear();
    return repo;
  }

  int count(String call) => engine.calls.where((c) => c == call).length;

  group('applyAudioConfig', () {
    test('a running engine is reopened, not restarted', () {
      final repo = running();

      final outcome = repo.applyAudioConfig(next);

      expect(outcome.status, AudioApplyStatus.applied);
      expect(outcome.reopen?.outcome, ReopenOutcome.retained);
      expect(engine.calls, containsAllInOrder(<String>['stop', 'reopen']));
      expect(count('start'), 0);
      expect(engine.lastConfig?.bufferFrames, 256);
      expect(repo.lastEngineConfig, next);
      // Reported to the caller that asked, not left on the status for a
      // device return that will never come.
      expect(repo.state.status.reopen, isNull);
    });

    test('a reopen that cleared the loops is returned, not hidden', () {
      final repo = running();
      engine.reopenResult = (
        result: EngineResult.ok,
        outcome: ReopenOutcome.clearedRate,
        droppedTracks: 0,
        openedRate: 0,
      );

      final outcome = repo.applyAudioConfig(next);

      expect(outcome.status, AudioApplyStatus.applied);
      expect(outcome.reopen?.outcome, ReopenOutcome.clearedRate);
    });

    test('a partial retention is returned with its dropped tracks', () {
      final repo = running();
      engine.reopenResult = (
        result: EngineResult.ok,
        outcome: ReopenOutcome.retainedPartial,
        droppedTracks: 1 << 2,
        openedRate: 0,
      );

      final outcome = repo.applyAudioConfig(next);

      expect(outcome.reopen?.droppedChannels, [2]);
    });

    test('a refused config reopens the previous one', () {
      final repo = running();
      var reopens = 0;
      engine.reopenResult = (
        result: EngineResult.device,
        outcome: ReopenOutcome.retained,
        droppedTracks: 0,
        openedRate: 0,
      );
      // The second reopen (the previous config) succeeds.
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

      final outcome = repo.applyAudioConfig(next);

      expect(outcome.status, AudioApplyStatus.refused);
      expect(outcome.result, EngineResult.device);
      expect(count('reopen'), 2);
      expect(engine.lastConfig, isNotNull);
      expect(engine.lastConfig?.bufferFrames, 128);
      expect(repo.lastEngineConfig, previous);
      expect(repo.state.status.reopen, isNull);
    });

    test('a failed attempt that cleared the loops is told even when the '
        'previous config comes back', () {
      final repo = running();
      // The new interface negotiated another rate (every loop cleared), then
      // would not start; the previous one reopens with nothing left to keep.
      engine.reopenResult = (
        result: EngineResult.device,
        outcome: ReopenOutcome.clearedRate,
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

      final outcome = repo.applyAudioConfig(next);

      expect(outcome.status, AudioApplyStatus.refused);
      expect(outcome.reopen?.outcome, ReopenOutcome.clearedRate);
      // Told once, here: the next start is an ordinary one.
      expect(repo.state.status.reopen, isNull);
      repo.stopEngine();
      expect(repo.startEngine(previous), EngineResult.ok);
      expect(repo.state.status.reopen, isNull);
    });

    test('a replay that rolls back fails without reopening anything else', () {
      final repo = running();
      engine.mixResult = EngineResult.invalid;

      final outcome = repo.applyAudioConfig(next);

      expect(outcome.status, AudioApplyStatus.failed);
      expect(outcome.reopen?.outcome, ReopenOutcome.retained);
      expect(count('reopen'), 1);
      expect(repo.sessionTransport.deviceRunning, isFalse);
      // Told once, here, not again at the next start.
      engine.mixResult = EngineResult.ok;
      expect(repo.startEngine(previous), EngineResult.ok);
      expect(repo.state.status.reopen, isNull);
    });

    test('a cold engine is started', () {
      final repo = LooperRepository(engine: engine, ticker: ticker.stream);
      addTearDown(repo.dispose);

      final outcome = repo.applyAudioConfig(next);

      expect(outcome.status, AudioApplyStatus.applied);
      expect(outcome.reopen, isNull);
      expect(count('start'), 1);
      expect(count('reopen'), 0);
    });

    test('a cold engine that will not open fails', () {
      final repo = LooperRepository(engine: engine, ticker: ticker.stream);
      addTearDown(repo.dispose);
      engine.startResult = EngineResult.device;

      final outcome = repo.applyAudioConfig(next);

      expect(outcome.status, AudioApplyStatus.failed);
      expect(outcome.result, EngineResult.device);
    });
  });

  group('a reconnect after a failed one', () {
    test('a clear the failed open made is still told when the next one '
        'succeeds', () async {
      final reconnect = StreamController<void>.broadcast();
      addTearDown(reconnect.close);
      final repo = LooperRepository(
        engine: engine,
        ticker: ticker.stream,
        reconnectTicker: reconnect.stream,
      );
      addTearDown(repo.dispose);
      final sub = repo.looperState.listen((_) {});
      addTearDown(sub.cancel);
      expect(repo.startEngine(previous), EngineResult.ok);
      engine.nextSnapshot = engine.nextSnapshot.copyWith(devicePresent: false);
      ticker.add(null);
      await Future<void>.delayed(Duration.zero);

      // The interface returns at another rate (the loops clear) and fails to
      // start; on the next device list it opens, with nothing left to keep.
      engine
        ..devices = const [pinnedDevice]
        ..reopenResult = (
          result: EngineResult.device,
          outcome: ReopenOutcome.clearedRate,
          droppedTracks: 0,
          openedRate: 0,
        );
      reconnect.add(null);
      await Future<void>.delayed(Duration.zero);
      engine
        ..devices = const [pinnedDevice, otherDevice]
        ..reopenResult = (
          result: EngineResult.ok,
          outcome: ReopenOutcome.retained,
          droppedTracks: 0,
          openedRate: 0,
        );
      reconnect.add(null);
      await Future<void>.delayed(Duration.zero);

      expect(repo.state.status.reopen?.outcome, ReopenOutcome.clearedRate);
    });
  });

  group('neither config opens (D17)', () {
    test('a pinned previous config stays pinned and supervised', () async {
      final reconnect = StreamController<void>.broadcast();
      addTearDown(reconnect.close);
      final repo = LooperRepository(
        engine: engine,
        ticker: ticker.stream,
        reconnectTicker: reconnect.stream,
      );
      addTearDown(repo.dispose);
      expect(repo.startEngine(previous), EngineResult.ok);
      engine
        ..calls.clear()
        ..reopenResult = (
          result: EngineResult.device,
          outcome: ReopenOutcome.retained,
          droppedTracks: 0,
          openedRate: 0,
        );

      final outcome = repo.applyAudioConfig(next);

      expect(outcome.status, AudioApplyStatus.waiting);
      expect(repo.lastEngineConfig, previous);
      expect(count('reopen'), 2);

      // The stopped engine reads the interface absent: the poll keeps the
      // supervisor armed rather than standing it down.
      engine.nextSnapshot = engine.nextSnapshot.copyWith(devicePresent: false);
      ticker.add(null);
      await Future<void>.delayed(Duration.zero);

      // The interface answers: the supervisor reopens the previous config,
      // as after an unplug.
      engine
        ..devices = const [pinnedDevice]
        ..reopenResult = (
          result: EngineResult.ok,
          outcome: ReopenOutcome.retained,
          droppedTracks: 0,
          openedRate: 0,
        );
      reconnect.add(null);
      await Future<void>.delayed(Duration.zero);

      expect(count('reopen'), 3);
      expect(engine.lastConfig?.bufferFrames, 128);
      expect(repo.sessionTransport.deviceRunning, isTrue);
    });

    test('an apply during an unplug arms one poll, not a second one', () async {
      final reconnect = StreamController<void>.broadcast();
      addTearDown(reconnect.close);
      final repo = LooperRepository(
        engine: engine,
        ticker: ticker.stream,
        reconnectTicker: reconnect.stream,
      );
      addTearDown(repo.dispose);
      final sub = repo.looperState.listen((_) {});
      addTearDown(sub.cancel);
      expect(repo.startEngine(previous), EngineResult.ok);
      // Unplugged: the supervisor arms.
      engine.nextSnapshot = engine.nextSnapshot.copyWith(devicePresent: false);
      ticker.add(null);
      await Future<void>.delayed(Duration.zero);
      // The player opens setup and applies; nothing opens.
      engine.reopenResult = (
        result: EngineResult.device,
        outcome: ReopenOutcome.retained,
        droppedTracks: 0,
        openedRate: 0,
      );
      expect(repo.applyAudioConfig(next).status, AudioApplyStatus.waiting);
      engine.calls.clear();

      // The interface returns: ONE reopen.
      engine
        ..devices = const [pinnedDevice]
        ..reopenResult = (
          result: EngineResult.ok,
          outcome: ReopenOutcome.retained,
          droppedTracks: 0,
          openedRate: 0,
        )
        ..nextSnapshot = engine.nextSnapshot.copyWith(devicePresent: true);
      reconnect.add(null);
      await Future<void>.delayed(Duration.zero);
      ticker.add(null);
      await Future<void>.delayed(Duration.zero);
      expect(count('reopen'), 1);

      // A later change to the device list reopens nothing: no orphaned
      // poll is left to act on it.
      engine.devices = const [pinnedDevice, otherDevice];
      reconnect.add(null);
      await Future<void>.delayed(Duration.zero);
      expect(count('reopen'), 1);
    });

    test(
      'a clear either attempt made is told when the interface comes back',
      () async {
        final reconnect = StreamController<void>.broadcast();
        addTearDown(reconnect.close);
        final repo = LooperRepository(
          engine: engine,
          ticker: ticker.stream,
          reconnectTicker: reconnect.stream,
        );
        addTearDown(repo.dispose);
        expect(repo.startEngine(previous), EngineResult.ok);
        engine.reopenResult = (
          result: EngineResult.device,
          outcome: ReopenOutcome.clearedRate,
          droppedTracks: 0,
          openedRate: 0,
        );
        expect(repo.applyAudioConfig(next).status, AudioApplyStatus.waiting);

        engine
          ..devices = const [pinnedDevice]
          ..reopenResult = (
            result: EngineResult.ok,
            outcome: ReopenOutcome.retained,
            droppedTracks: 0,
            openedRate: 0,
          );
        reconnect.add(null);
        await Future<void>.delayed(Duration.zero);

        expect(repo.state.status.reopen?.outcome, ReopenOutcome.clearedRate);
      },
    );

    test('a replay that rolls back is not supervised over folded history', () {
      final repo = running();
      // The new config is refused; the previous one opens but its replay
      // rolls back.
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
          engine
            ..reopenResult = (
              result: EngineResult.ok,
              outcome: ReopenOutcome.retained,
              droppedTracks: 0,
              openedRate: 0,
            )
            ..mixResult = EngineResult.invalid;
        }
      };

      final outcome = repo.applyAudioConfig(next);

      expect(outcome.status, AudioApplyStatus.failed);
      expect(repo.sessionTransport.deviceRunning, isFalse);
    });

    test('the system default is not supervised: it fails and stops', () {
      const unpinned = EngineConfig(sampleRate: 48000, bufferFrames: 128);
      final repo = LooperRepository(engine: engine, ticker: ticker.stream);
      addTearDown(repo.dispose);
      expect(repo.startEngine(unpinned), EngineResult.ok);
      engine.reopenResult = (
        result: EngineResult.device,
        outcome: ReopenOutcome.retained,
        droppedTracks: 0,
        openedRate: 0,
      );

      final outcome = repo.applyAudioConfig(
        const EngineConfig(sampleRate: 48000, bufferFrames: 256),
      );

      expect(outcome.status, AudioApplyStatus.failed);
      expect(repo.sessionTransport.deviceRunning, isFalse);
    });
  });

  group('the record offset replay', () {
    test("an offset of 0 is replayed too, so another profile's figure never "
        'comes back', () {
      final repo = running()..setRecordOffset(0);
      engine.lastRecordOffset = null;

      repo.applyAudioConfig(next);

      expect(engine.lastRecordOffset, 0);
    });

    test('the remembered offset is replayed on a reopen', () {
      final repo = running()..setRecordOffset(150);
      engine.lastRecordOffset = null;

      repo.applyAudioConfig(next);

      expect(engine.lastRecordOffset, 150);
    });
  });

  group('the measured-offset mirror', () {
    test('a queued 0 is not undone by a poll that still reads the old '
        'figure', () async {
      final repo = running();
      final sub = repo.looperState.listen((_) {});
      addTearDown(sub.cancel);
      // A profile measured earlier: the engine still reports its figure, and
      // the 0 the audio setup sets has not reached the audio thread yet.
      repo.setRecordOffset(0);
      engine.nextSnapshot = engine.nextSnapshot.copyWith(
        recordOffsetFrames: 150,
      );
      ticker.add(null);
      await Future<void>.delayed(Duration.zero);
      engine.lastRecordOffset = null;

      repo.applyAudioConfig(next);

      expect(engine.lastRecordOffset, 0);
    });
  });

  group('fxRoomAt', () {
    test('is the whole budget with no effects', () {
      final repo = running();
      expect(repo.fxRoomAt(48000, 128), fxBudgetNs(48000, period: 128));
      expect(repo.fxRoomAt(96000, 64), fxBudgetNs(96000));
    });

    test('less what every chain costs at that block length', () {
      final repo = running()
        ..setTrackEffects(
          channel: 0,
          effects: [BuiltInEffect(type: TrackEffectType.reverb)],
        );
      final cost = fxChainCostNs(
        [BuiltInEffect(type: TrackEffectType.reverb)],
        period: 128,
      );
      expect(repo.fxRoomAt(96000, 128), fxBudgetNs(96000, period: 128) - cost);
      // A higher rate leaves less room for the same chains.
      expect(repo.fxRoomAt(96000, 128), lessThan(repo.fxRoomAt(48000, 128)));
    });
  });
}
