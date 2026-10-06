import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno_engine/segno_engine.dart' as le;

import 'helpers/fake_audio_engine.dart';

const _pinned = le.AudioDevice(
  id: 'out-1',
  name: 'Scarlett 2i2',
  isDefault: false,
  isInput: false,
);
const _config = EngineConfig(playbackDeviceId: 'out-1');

/// One receipt family driven through the repository's public surface, with
/// the engine-side switches that withhold or deliver its callback receipt.
final class _Family<T> {
  const _Family({
    required this.name,
    required this.prior,
    required this.next,
    required this.request,
    required this.settle,
    required this.recover,
    required this.owes,
    required this.live,
    required this.restart,
    required this.withhold,
    required this.deliver,
    required this.audible,
  });
  final String name;
  final T prior;
  final T next;
  final EngineResult Function(LooperRepository, T) request;
  final Future<EngineResult> Function(LooperRepository) settle;
  final EngineResult Function(LooperRepository) recover;
  final bool Function(LooperRepository) owes;
  final T Function(LooperRepository) live;
  final T Function(LooperRepository) restart;

  /// The device is absent: commands are accepted and never published.
  final void Function(FakeAudioEngine) withhold;

  /// The device publishes again, including a late receipt for the value.
  final void Function(FakeAudioEngine, T value) deliver;

  /// What the engine itself plays now.
  final T Function(FakeAudioEngine) audible;
}

final _clickVolume = _Family<double>(
  name: 'Click volume',
  prior: 1,
  next: 1.5,
  request: (repository, value) => repository.setClickVolume(value),
  settle: (repository) => repository.settleClickVolume(),
  recover: (repository) => repository.recoverClickVolume(),
  owes: (repository) => repository.clickVolumeRecoveryRequired,
  live: (repository) => repository.sessionTransport.clickVolume,
  restart: (repository) => repository.clickVolumeRestartIntent,
  withhold: (engine) => engine
    ..publishClickCommands = false
    ..commandsAreSettled = false,
  deliver: (engine, value) {
    engine
      ..nextSnapshot = engine.nextSnapshot.copyWith(clickVolume: value)
      ..publishClickCommands = true
      ..commandsAreSettled = true;
  },
  audible: (engine) => engine.nextSnapshot.clickVolume,
);

final _hearClick = _Family<ClickMode>(
  name: 'Hear click',
  prior: ClickMode.off,
  next: ClickMode.playRec,
  request: (repository, value) => repository.setClickMode(value),
  settle: (repository) => repository.settleClickMode(),
  recover: (repository) => repository.recoverClickMode(),
  owes: (repository) => repository.clickModeRecoveryRequired,
  live: (repository) => repository.sessionTransport.clickMode,
  restart: (repository) => repository.clickModeRestartIntent,
  withhold: (engine) => engine
    ..publishClickModeCommands = false
    ..commandsAreSettled = false,
  deliver: (engine, value) {
    final snapshot = engine.nextSnapshot;
    engine
      ..nextSnapshot = snapshot.copyWith(
        clickMode: value,
        clickModeRevision: (snapshot.clickModeRevision + 1) & 0xffffffff,
        clickModeResult: 0,
      )
      ..publishClickModeCommands = true
      ..commandsAreSettled = true;
  },
  audible: (engine) => engine.nextSnapshot.clickMode,
);

final _recordStart = _Family<({int countInBars, bool soundStart})>(
  name: 'Count-in',
  prior: (countInBars: 0, soundStart: false),
  next: (countInBars: 2, soundStart: false),
  request: (repository, value) => repository.setRecordStartSettings(
    countInBars: value.countInBars,
    soundStart: value.soundStart,
    editKind: RecordStartEditKind.countIn,
  ),
  settle: (repository) => repository.settleRecordStartSettings(),
  recover: (repository) => repository.recoverRecordStartSettings(),
  owes: (repository) => repository.recordStartRecoveryRequired,
  live: (repository) => repository.recordStartSettings,
  restart: (repository) => repository.recordStartRestartIntent,
  withhold: (engine) => engine
    ..publishRecordStartCommands = false
    ..commandsAreSettled = false,
  deliver: (engine, value) {
    final snapshot = engine.nextSnapshot;
    engine
      ..nextSnapshot = snapshot.copyWith(
        countInBars: value.countInBars,
        autoRecord: value.soundStart,
        recordStartRevision: (snapshot.recordStartRevision + 1) & 0xffffffff,
        recordStartResult: 0,
      )
      ..publishRecordStartCommands = true
      ..commandsAreSettled = true;
  },
  audible: (engine) => (
    countInBars: engine.nextSnapshot.countInBars,
    soundStart: engine.nextSnapshot.autoRecord,
  ),
);

void main() {
  int count(FakeAudioEngine engine, String call) =>
      engine.calls.where((c) => c == call).length;

  void check(
    String name,
    void Function(FakeAsync, FakeAudioEngine, LooperRepository) body,
  ) {
    test(
      name,
      () => fakeAsync((clock) {
        final engine = FakeAudioEngine();
        final repository = LooperRepository(engine: engine);
        expect(repository.startEngine(const EngineConfig()), EngineResult.ok);
        unawaited(repository.settleClickMode());
        clock.flushMicrotasks();
        try {
          body(clock, engine, repository);
        } finally {
          unawaited(repository.dispose());
          clock.flushMicrotasks();
        }
      }),
    );
  }

  void contract<T extends Object>(_Family<T> family) {
    group('${family.name} receipt', () {
      test('device absent: the timeout owes the value and never stops audio; '
          'reconnect replays it', () {
        fakeAsync((clock) {
          final engine = FakeAudioEngine()
            ..nextSnapshot = FakeAudioEngine().nextSnapshot.copyWith(
              isRunning: true,
              devicePresent: true,
            );
          final ticker = StreamController<void>.broadcast();
          final reconnect = StreamController<void>.broadcast();
          final repository = LooperRepository(
            engine: engine,
            ticker: ticker.stream,
            reconnectTicker: reconnect.stream,
          );
          final subscription = repository.looperState.listen((_) {});
          expect(repository.startEngine(_config), EngineResult.ok);
          clock.elapse(const Duration(milliseconds: 20));
          expect(family.owes(repository), isFalse);

          family.withhold(engine);
          expect(family.request(repository, family.next), EngineResult.ok);
          clock.elapse(const Duration(milliseconds: 510));
          expect(family.owes(repository), isTrue);
          expect(family.live(repository), family.prior);
          expect(family.restart(repository), family.next);
          expect(count(engine, 'stop'), 0);
          expect(repository.sessionTransport.isRunning, isTrue);

          // The device is gone; supervision is still armed and reopens it.
          engine.nextSnapshot = engine.nextSnapshot.copyWith(
            devicePresent: false,
          );
          ticker.add(null);
          clock.flushMicrotasks();
          engine.devices = const [_pinned];
          family.deliver(engine, family.prior);
          reconnect.add(null);
          clock.flushMicrotasks();
          expect(count(engine, 'start'), 2);
          // Only the supervisor's raw release of the dead device.
          expect(count(engine, 'stop'), 1);
          clock.elapse(const Duration(milliseconds: 20));
          expect(family.owes(repository), isFalse);
          expect(family.live(repository), family.next);
          expect(family.audible(engine), family.next);

          unawaited(subscription.cancel());
          unawaited(repository.dispose());
          unawaited(ticker.close());
          unawaited(reconnect.close());
          clock.flushMicrotasks();
        });
      });

      check('a late receipt then Retry lands the owed value without a stop', (
        clock,
        engine,
        repository,
      ) {
        family.withhold(engine);
        expect(family.request(repository, family.next), EngineResult.ok);
        clock.elapse(const Duration(milliseconds: 510));
        expect(family.owes(repository), isTrue);
        family.deliver(engine, family.next);
        clock.elapse(const Duration(milliseconds: 20));
        expect(family.owes(repository), isTrue);
        expect(family.recover(repository), EngineResult.ok);
        EngineResult? result;
        unawaited(family.settle(repository).then((value) => result = value));
        clock.elapse(const Duration(milliseconds: 20));
        expect(result, EngineResult.ok);
        expect(family.owes(repository), isFalse);
        expect(family.live(repository), family.next);
        expect(family.restart(repository), family.next);
        expect(count(engine, 'stop'), 0);
      });

      check('startEngine is not refused while a value is owed', (
        clock,
        engine,
        repository,
      ) {
        family.withhold(engine);
        expect(family.request(repository, family.next), EngineResult.ok);
        clock.elapse(const Duration(milliseconds: 510));
        repository.stopEngine();
        family.deliver(engine, family.prior);
        expect(repository.startEngine(const EngineConfig()), EngineResult.ok);
        clock.elapse(const Duration(milliseconds: 20));
        expect(family.owes(repository), isFalse);
        expect(family.live(repository), family.next);
        expect(family.audible(engine), family.next);
      });

      check('a Retry cancelled before its receipt keeps the value owed', (
        clock,
        engine,
        repository,
      ) {
        family.withhold(engine);
        expect(family.request(repository, family.next), EngineResult.ok);
        clock.elapse(const Duration(milliseconds: 510));
        expect(family.recover(repository), EngineResult.ok);
        expect(family.owes(repository), isTrue);
        repository.stopEngine();
        clock.flushMicrotasks();
        expect(family.owes(repository), isTrue);
        expect(family.restart(repository), family.next);
        family.deliver(engine, family.prior);
        expect(repository.startEngine(const EngineConfig()), EngineResult.ok);
        clock.elapse(const Duration(milliseconds: 20));
        expect(family.owes(repository), isFalse);
        expect(family.audible(engine), family.next);
      });

      check('Retry while stopped stages the owed value', (
        clock,
        engine,
        repository,
      ) {
        family.withhold(engine);
        expect(family.request(repository, family.next), EngineResult.ok);
        clock.elapse(const Duration(milliseconds: 510));
        repository.stopEngine();
        final calls = engine.calls.length;
        expect(family.recover(repository), EngineResult.ok);
        expect(engine.calls.length, calls);
        expect(family.owes(repository), isFalse);
        expect(family.restart(repository), family.next);
      });

      check('a cancelled waiter completes notReady and keeps the last result', (
        clock,
        engine,
        repository,
      ) {
        family.withhold(engine);
        expect(family.request(repository, family.next), EngineResult.ok);
        EngineResult? waiter;
        unawaited(family.settle(repository).then((value) => waiter = value));
        repository.stopEngine();
        clock.flushMicrotasks();
        expect(waiter, EngineResult.notReady);
        EngineResult? after;
        unawaited(family.settle(repository).then((value) => after = value));
        clock.flushMicrotasks();
        expect(after, EngineResult.ok);
        expect(family.owes(repository), isFalse);
        expect(family.restart(repository), family.prior);
      });
    });
  }

  contract(_clickVolume);
  contract(_hearClick);
  contract(_recordStart);

  group('Hear click receipt', () {
    check(
      'published scalar cannot advance accepted mode before command acquire',
      (clock, engine, repository) {
        engine.commandsAreSettled = false;
        expect(repository.setClickMode(ClickMode.playRec), EngineResult.ok);
        expect(engine.nextSnapshot.clickMode, ClickMode.playRec);
        expect(repository.sessionTransport.clickMode, ClickMode.off);
        expect(repository.state.transport.clickMode, ClickMode.off);
        EngineResult? result;
        unawaited(repository.settleClickMode().then((value) => result = value));
        clock.elapse(const Duration(milliseconds: 20));
        expect(result, isNull);
        expect(repository.state.transport.clickMode, ClickMode.off);
        expect(repository.setClickMode(ClickMode.rec), EngineResult.notReady);
        engine.commandsAreSettled = true;
        clock.elapse(const Duration(milliseconds: 10));
        expect(result, EngineResult.ok);
        expect(repository.sessionTransport.clickMode, ClickMode.playRec);
        expect(repository.state.transport.clickMode, ClickMode.playRec);
      },
    );

    check('a same-value stale revision is not completion', (
      clock,
      engine,
      repository,
    ) {
      engine.publishClickModeCommands = false;
      expect(repository.setClickMode(ClickMode.off), EngineResult.ok);
      clock.elapse(const Duration(milliseconds: 490));
      expect(repository.clickModeSettled, isFalse);
      clock.elapse(const Duration(milliseconds: 20));
      expect(repository.clickModeRecoveryRequired, isTrue);
      expect(repository.sessionTransport.isRunning, isTrue);
    });

    check('callback refusal with exact prior mode keeps audio running', (
      clock,
      engine,
      repository,
    ) {
      engine.publishClickModeCommands = false;
      final revision = engine.nextSnapshot.clickModeRevision;
      expect(repository.setClickMode(ClickMode.rec), EngineResult.ok);
      engine.nextSnapshot = engine.nextSnapshot.copyWith(
        clickModeRevision: revision + 1,
        clickModeResult: -1,
      );
      EngineResult? result;
      unawaited(repository.settleClickMode().then((value) => result = value));
      clock.flushMicrotasks();
      expect(result, EngineResult.invalid);
      expect(repository.clickModeRecoveryRequired, isFalse);
      expect(repository.sessionTransport.isRunning, isTrue);
      expect(repository.sessionTransport.clickMode, ClickMode.off);
    });

    check('Held is live while device restart replays Released', (
      clock,
      engine,
      repository,
    ) {
      expect(
        repository.setClickMode(
          ClickMode.playRec,
          releasedMode: ClickMode.recFirst,
        ),
        EngineResult.ok,
      );
      unawaited(repository.settleClickMode());
      clock.flushMicrotasks();
      expect(repository.sessionTransport.clickMode, ClickMode.playRec);
      expect(repository.clickModeRestartIntent, ClickMode.recFirst);
      repository.stopEngine();
      expect(repository.startEngine(const EngineConfig()), EngineResult.ok);
      unawaited(repository.settleClickMode());
      clock.flushMicrotasks();
      expect(repository.sessionTransport.clickMode, ClickMode.recFirst);
      expect(engine.nextSnapshot.clickMode, ClickMode.recFirst);
    });
  });

  group('Click volume receipt', () {
    check('desired gain and stale same-value snapshot are not receipts', (
      clock,
      engine,
      repository,
    ) {
      engine
        ..publishClickCommands = false
        ..commandsAreSettled = false;
      expect(repository.setClickVolume(1), EngineResult.ok);
      EngineResult? receipt;
      unawaited(
        repository.settleClickVolume().then((value) => receipt = value),
      );
      clock.elapse(const Duration(milliseconds: 20));
      expect(receipt, isNull);
      expect(repository.clickVolumeSettled, isFalse);
      engine.commandsAreSettled = true;
      clock.elapse(const Duration(milliseconds: 10));
      expect(receipt, EngineResult.ok);
    });

    check('published new value advances cache only after callback fence', (
      clock,
      engine,
      repository,
    ) {
      engine
        ..publishClickCommands = false
        ..commandsAreSettled = false;
      expect(repository.setClickVolume(1.5), EngineResult.ok);
      expect(repository.sessionTransport.clickVolume, 1);
      expect(repository.setClickVolume(.5), EngineResult.notReady);
      engine.nextSnapshot = engine.nextSnapshot.copyWith(clickVolume: 1.5);
      expect(repository.clickVolumeSettled, isFalse);
      expect(repository.sessionTransport.clickVolume, 1);
      engine.commandsAreSettled = true;
      // Querying readiness does not consume a receipt or mutate accepted state.
      expect(repository.clickVolumeSettled, isFalse);
      expect(repository.sessionTransport.clickVolume, 1);
      clock.elapse(const Duration(milliseconds: 10));
      expect(repository.clickVolumeSettled, isTrue);
      expect(repository.sessionTransport.clickVolume, 1.5);
    });

    check('a drained queue publishing another gain owes the value, running', (
      clock,
      engine,
      repository,
    ) {
      engine.publishClickCommands = false;
      final result = repository.setClickVolume(1.5);
      expect(result, isNot(EngineResult.ok));
      expect(repository.clickVolumeSettled, isTrue);
      expect(repository.clickVolumeRecoveryRequired, isTrue);
      expect(repository.clickVolumeRestartIntent, 1.5);
      expect(repository.sessionTransport.isRunning, isTrue);
      expect(repository.sessionTransport.clickVolume, 1);
      expect(count(engine, 'stop'), 0);
    });

    check('cancelled high cannot commit its Released restart value', (
      clock,
      engine,
      repository,
    ) {
      engine
        ..publishClickCommands = false
        ..commandsAreSettled = false;
      expect(
        repository.setClickVolume(1.5, releasedVolume: .25),
        EngineResult.ok,
      );
      repository.stopEngine();
      expect(repository.sessionTransport.clickVolume, 1);
      engine
        ..publishClickCommands = true
        ..commandsAreSettled = true;
      expect(repository.startEngine(const EngineConfig()), EngineResult.ok);
      expect(repository.clickVolumeSettled, isTrue);
      expect(engine.nextSnapshot.clickVolume, 1);
    });

    check('stopped edit is deferred and admitted at next start', (
      clock,
      engine,
      repository,
    ) {
      repository.stopEngine();
      final writes = engine.calls.length;
      expect(repository.setClickVolume(1.5), EngineResult.ok);
      expect(engine.calls.length, writes);
      expect(repository.clickVolumeSettled, isTrue);
      expect(repository.startEngine(const EngineConfig()), EngineResult.ok);
      expect(repository.clickVolumeSettled, isTrue);
      expect(engine.nextSnapshot.clickVolume, 1.5);
    });

    for (final invalid in [double.nan, double.infinity, -.1, 2.1]) {
      check('invalid physical gain $invalid never queues native work', (
        clock,
        engine,
        repository,
      ) {
        final writes = engine.calls.length;
        expect(repository.setClickVolume(invalid), EngineResult.invalid);
        expect(engine.calls.length, writes);
        expect(repository.sessionTransport.clickVolume, 1);
      });
    }
  });
}
