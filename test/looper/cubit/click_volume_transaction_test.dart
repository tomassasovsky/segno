import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/looper/cubit/tempo_cubit.dart';
import 'package:segno/looper/model/click_volume.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

class _Engine extends FakeAudioEngine {
  bool refuseClick = false;
  final clickWrites = <double>[];
  @override
  EngineResult setClickVolume(double volume) {
    clickWrites.add(volume);
    if (!publishClickCommands && !refuseClick) commandsAreSettled = false;
    return refuseClick ? EngineResult.notReady : super.setClickVolume(volume);
  }
}

class _Store extends FakeKeyValueStore {
  int failingWrites = 0;
  int failingReads = 0;
  int clickStoreWrites = 0;
  void Function()? onReadFailure;
  bool mutateBeforeFailure = false;
  Completer<void>? writeGate;
  Completer<void>? readGate;
  @override
  Future<double?> getDouble(String key) async {
    if (key == 'tempo.click_volume') {
      await readGate?.future;
      if (failingReads > 0) {
        failingReads--;
        onReadFailure?.call();
        throw StateError('Click scalar read refused');
      }
    }
    return super.getDouble(key);
  }

  @override
  Future<void> setDouble(String key, double value) async {
    if (key == 'tempo.click_volume') {
      clickStoreWrites++;
      await writeGate?.future;
      if (failingWrites > 0) {
        failingWrites--;
        if (mutateBeforeFailure) await super.setDouble(key, value);
        throw StateError('Click scalar refused');
      }
    }
    await super.setDouble(key, value);
  }
}

class _Rig {
  _Rig(this.clock, {bool running = true, double? saved = .5}) {
    if (saved != null) store.values['tempo.click_volume'] = saved;
    looper = LooperRepository(engine: engine);
    if (running) {
      expect(looper.startEngine(const EngineConfig()), EngineResult.ok);
    }
    owner = TempoCubit(
      repository: looper,
      settings: SettingsRepository(store: store),
      clickPollAttempts: 3,
    );
  }
  final FakeAsync clock;
  final engine = _Engine();
  final store = _Store();
  late final LooperRepository looper;
  late final TempoCubit owner;
  void load() {
    unawaited(owner.load());
    pump();
  }

  void pump() {
    clock
      ..flushMicrotasks()
      ..elapse(const Duration(milliseconds: 10))
      ..flushMicrotasks();
  }

  void publish(double volume) {
    engine.nextSnapshot = engine.nextSnapshot.copyWith(clickVolume: volume);
    engine.commandsAreSettled = true;
    pump();
  }

  void close() {
    engine.commandsAreSettled = true;
    unawaited(owner.close());
    clock
      ..elapse(const Duration(seconds: 1))
      ..flushMicrotasks();
    unawaited(looper.dispose());
    clock.flushMicrotasks();
  }
}

void main() {
  void check(
    String name,
    void Function(_Rig) body, {
    bool running = true,
    double? saved = .5,
  }) {
    test(
      name,
      () => fakeAsync((clock) {
        final r = _Rig(clock, running: running, saved: saved);
        try {
          body(r);
        } finally {
          r.close();
        }
      }),
    );
  }

  check('startup is unavailable until accepted, including unchanged unity', (
    r,
  ) {
    final gate = Completer<void>();
    r.store.readGate = gate;
    unawaited(r.owner.load());
    double? captured;
    unawaited(
      r.owner.runClickVolumeExclusive(() async {
        captured = r.owner.durableClickVolume;
      }),
    );
    r.clock.flushMicrotasks();
    expect(captured, isNull);
    expect(r.owner.clickVolume, isNull);
    expect(r.owner.state.clickReady, isFalse);
    r.store.readGate = null;
    gate.complete();
    r.pump();
    expect(r.owner.clickVolume, 1);
    expect(r.owner.state.clickReady, isTrue);
    expect(captured, 1);
  }, saved: null);

  check('held admission waits native publication and projects only Released', (
    r,
  ) {
    r.load();
    r.engine
      ..publishClickCommands = false
      ..commandsAreSettled = false;
    ClickVolumeOutcome? result;
    unawaited(
      r.owner
          .setControllerClickVolume(
            1.5,
            releasedVolume: .25,
            lifetime: r.owner.clickVolumeLifetime,
          )
          .then((value) => result = value),
    );
    r.pump();
    expect(r.store.values['tempo.click_volume'], .25);
    expect(r.engine.snapshot().clickVolume, .5);
    expect(r.looper.sessionTransport.clickVolume, .5);
    expect(r.owner.clickVolume, .5);
    expect(result, isNull);
    r.publish(1.5);
    expect(result!.isOk, isTrue);
    expect(r.owner.clickVolume, 1.5);
    expect(r.owner.durableClickVolume, .25);
  });

  check('same value behind pending high cannot complete from stale snapshot', (
    r,
  ) {
    r.load();
    r.engine
      ..publishClickCommands = false
      ..commandsAreSettled = false;
    ClickVolumeOutcome? high;
    ClickVolumeOutcome? low;
    unawaited(r.owner.setClickVolume(1.5).then((value) => high = value));
    unawaited(r.owner.setClickVolume(.5).then((value) => low = value));
    r.pump();
    expect(high, isNull);
    expect(low, isNull);
    r.publish(1.5);
    expect(high!.isOk, isTrue);
    // The fake's publication fence must also represent the second enqueue.
    expect(low?.isOk, isNot(true));
  });

  for (final gain in [double.nan, double.infinity, -.1, 2.1]) {
    check('invalid physical gain $gain is rejected before storage or audio', (
      r,
    ) {
      r.load();
      final before = r.engine.clickWrites.length;
      ClickVolumeOutcome? result;
      unawaited(r.owner.setClickVolume(gain).then((value) => result = value));
      r.pump();
      expect(result!.status, ClickVolumeStatus.rejected);
      expect(r.engine.clickWrites.length, before);
      expect(r.store.values['tempo.click_volume'], .5);
    });
  }

  for (final saved in <double?>[null, 1, .5]) {
    check('native refusal restores exact scalar checkpoint $saved', (r) {
      r.load();
      r.engine.refuseClick = true;
      ClickVolumeOutcome? result;
      unawaited(r.owner.setClickVolume(1.5).then((value) => result = value));
      r.pump();
      expect(result!.status, ClickVolumeStatus.rejected);
      expect(r.store.values.containsKey('tempo.click_volume'), saved != null);
      expect(r.store.values['tempo.click_volume'], saved);
      expect(r.owner.clickVolume, saved ?? 1);
    }, saved: saved);
  }

  check('write then throw restores scalar without an audio command', (r) {
    r.load();
    final before = r.engine.clickWrites.length;
    r.store
      ..failingWrites = 1
      ..mutateBeforeFailure = true;
    ClickVolumeOutcome? result;
    unawaited(r.owner.setClickVolume(1.5).then((value) => result = value));
    r.pump();
    expect(result!.status, ClickVolumeStatus.rejected);
    expect(r.store.values['tempo.click_volume'], .5);
    expect(r.engine.clickWrites.length, before);
    expect(r.owner.clickVolume, .5);
  });

  check('timeout stops late command and explicit recovery keeps prior intent', (
    r,
  ) {
    r.load();
    r.engine
      ..publishClickCommands = false
      ..commandsAreSettled = false;
    ClickVolumeOutcome? result;
    unawaited(r.owner.setClickVolume(1.5).then((value) => result = value));
    r.clock.elapse(const Duration(milliseconds: 100));
    r.clock.flushMicrotasks();
    expect(result!.status, ClickVolumeStatus.recoveryRequired);
    expect(r.engine.stopCalls, 1);
    expect(r.looper.startEngine(const EngineConfig()), EngineResult.notReady);
    expect(r.store.values['tempo.click_volume'], .5);
    r.engine.commandsAreSettled = true;
    unawaited(r.owner.recoverClickVolume().then((value) => result = value));
    r.pump();
    expect(result!.isOk, isTrue);
    expect(result!.deferred, isTrue);
    expect(r.owner.clickVolume, .5);
    expect(r.looper.sessionTransport.clickVolume, .5);
  });

  check('failed rollback is visible and blocks another Click admission', (r) {
    r.load();
    r.store
      ..failingWrites = 2
      ..mutateBeforeFailure = true;
    ClickVolumeOutcome? result;
    unawaited(r.owner.setClickVolume(1.5).then((value) => result = value));
    r.pump();
    expect(result!.status, ClickVolumeStatus.recoveryRequired);
    expect(r.engine.stopCalls, 1);
    unawaited(r.owner.setClickVolume(1).then((value) => result = value));
    r.pump();
    expect(result!.status, ClickVolumeStatus.recoveryRequired);
    unawaited(r.owner.recoverClickVolume().then((value) => result = value));
    r.pump();
    expect(result!.isOk, isTrue);
  });

  check('stopped ordinary edit is durable deferred and start replays it', (r) {
    r.load();
    ClickVolumeOutcome? result;
    unawaited(r.owner.setClickVolume(1.5).then((value) => result = value));
    r.pump();
    expect(result!.deferred, isTrue);
    expect(r.engine.clickWrites, isEmpty);
    expect(r.owner.clickVolume, 1.5);
    expect(r.store.values['tempo.click_volume'], 1.5);
    expect(r.looper.startEngine(const EngineConfig()), EngineResult.ok);
    expect(r.engine.snapshot().clickVolume, 1.5);
  }, running: false);

  check('ordinary accepted same-value edit removes durable held projection', (
    r,
  ) {
    r.load();
    unawaited(
      r.owner.setControllerClickVolume(
        1.5,
        releasedVolume: .25,
        lifetime: r.owner.clickVolumeLifetime,
      ),
    );
    r.pump();
    expect(r.owner.durableClickVolume, .25);
    final ordinary = <double>[];
    final sub = r.owner.ordinaryClickVolumeChanges.listen(ordinary.add);
    unawaited(r.owner.setClickVolume(1.5));
    r.pump();
    expect(r.owner.durableClickVolume, 1.5);
    expect(ordinary, [1.5]);
    unawaited(sub.cancel());
  });
  check('explicit Retry clears safe refusal for flush without another edit', (
    r,
  ) {
    r.load();
    r.engine.refuseClick = true;
    unawaited(r.owner.setClickVolume(1.5));
    r.pump();
    ClickVolumeOutcome? flush;
    unawaited(r.owner.flushClickVolume().then((v) => flush = v));
    r.pump();
    expect(flush!.status, ClickVolumeStatus.rejected);
    unawaited(r.owner.recoverClickVolume());
    r.pump();
    unawaited(r.owner.flushClickVolume().then((v) => flush = v));
    r.pump();
    expect(flush!.isOk, isTrue);
    expect(r.owner.clickVolume, .5);
  });

  test('close waits for an admitted native write before disposal', () async {
    final engine = _Engine();
    final looper = LooperRepository(engine: engine);
    expect(looper.startEngine(const EngineConfig()), EngineResult.ok);
    final store = _Store();
    final owner = TempoCubit(
      repository: looper,
      settings: SettingsRepository(store: store),
    );
    await owner.load();
    engine.publishClickCommands = false;
    final result = owner.setClickVolume(1.5);
    for (var i = 0; i < 10 && engine.commandsAreSettled; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(engine.commandsAreSettled, isFalse);
    var closed = false;
    final closing = owner.close().then((_) => closed = true);
    await Future<void>.delayed(Duration.zero);
    expect(closed, isFalse);
    engine.nextSnapshot = engine.nextSnapshot.copyWith(clickVolume: 1.5);
    engine.commandsAreSettled = true;
    expect((await result).isOk, isTrue);
    await closing.timeout(const Duration(seconds: 2));
    expect(closed, isTrue);
    expect(store.values['tempo.click_volume'], 1.5);
    expect(looper.sessionTransport.clickVolume, 1.5);
    await looper.dispose();
  });

  check('autonomous replay timeout is awaited and surfaced by flush', (r) {
    r.load();
    r.looper.stopEngine();
    r.engine.publishClickCommands = false;
    expect(r.looper.startEngine(const EngineConfig()), EngineResult.ok);
    ClickVolumeOutcome? result;
    unawaited(r.owner.flushClickVolume().then((v) => result = v));
    r.clock.flushMicrotasks();
    expect(result, isNull);
    r.clock.elapse(const Duration(milliseconds: 50));
    r.clock.flushMicrotasks();
    expect(result!.status, ClickVolumeStatus.recoveryRequired);
    expect(r.looper.sessionTransport.isRunning, isFalse);
    expect(r.looper.clickVolumeRecoveryRequired, isTrue);
    unawaited(r.owner.recoverClickVolume().then((v) => result = v));
    r.pump();
    expect(result!.isOk, isTrue);
    expect(r.looper.clickVolumeRecoveryRequired, isFalse);
    expect(r.owner.clickVolume, .5);
  });

  check('autonomous replay mismatch becomes recoverable owner failure', (r) {
    r.load();
    final failures = <ClickVolumeOutcome>[];
    final subscription = r.owner.clickVolumeFailures.listen(failures.add);
    r.looper.stopEngine();
    r.engine.publishClickCommands = false;
    r.engine.nextSnapshot = r.engine.nextSnapshot.copyWith(clickVolume: 1.75);
    expect(r.looper.startEngine(const EngineConfig()), EngineResult.ok);
    r.engine.commandsAreSettled = true;
    r.pump();
    expect(r.looper.clickVolumeRecoveryRequired, isTrue);
    expect(failures.last.status, ClickVolumeStatus.recoveryRequired);
    ClickVolumeOutcome? result;
    unawaited(r.owner.flushClickVolume().then((v) => result = v));
    r.pump();
    expect(result!.status, ClickVolumeStatus.recoveryRequired);
    unawaited(r.owner.recoverClickVolume().then((v) => result = v));
    r.pump();
    expect(result!.isOk, isTrue);
    expect(r.looper.clickVolumeRecoveryRequired, isFalse);
    expect(r.owner.clickVolume, .5);
    expect(r.store.values['tempo.click_volume'], .5);
    unawaited(subscription.cancel());
  });

  for (final controller in [false, true]) {
    check(
      'unreadable recovery rejects '
      '${controller ? "controller" : "ordinary"} admission',
      (r) {
        r.load();
        r.looper.stopEngine();
        r.engine.publishClickCommands = false;
        r.engine.nextSnapshot = r.engine.nextSnapshot.copyWith(
          clickVolume: 1.75,
        );
        expect(r.looper.startEngine(const EngineConfig()), EngineResult.ok);
        r.engine.commandsAreSettled = true;
        final writes = r.engine.clickWrites.length;
        final storedWrites = r.store.clickStoreWrites;
        final deferred = r.looper.sessionTransport.clickVolume;
        final accepted = r.owner.state.clickVolume;
        final durable = r.owner.durableClickVolume;
        ClickVolumeOutcome? outcome;
        r.store
          ..failingReads = 1
          ..onReadFailure = () {
            final edit = controller
                ? r.owner.setControllerClickVolume(
                    1.5,
                    releasedVolume: .25,
                    lifetime: r.owner.clickVolumeLifetime,
                  )
                : r.owner.setClickVolume(1.5);
            unawaited(edit.then((v) => outcome = v));
          };
        r.pump();
        expect(r.store.failingReads, 0);
        expect(r.looper.clickVolumeRecoveryRequired, isTrue);
        expect(outcome!.status, ClickVolumeStatus.recoveryRequired);
        expect(r.owner.state.clickVolume, accepted);
        expect(r.owner.durableClickVolume, durable);
        expect(r.store.values['tempo.click_volume'], .5);
        expect(r.engine.clickWrites.length, writes);
        expect(r.store.clickStoreWrites, storedWrites);
        expect(r.looper.sessionTransport.clickVolume, deferred);
        unawaited(r.owner.recoverClickVolume().then((v) => outcome = v));
        r.pump();
        expect(outcome!.isOk, isTrue);
        expect(r.looper.clickVolumeRecoveryRequired, isFalse);
        expect(r.owner.clickVolume, .5);
        unawaited(r.owner.setClickVolume(1.25).then((v) => outcome = v));
        r.pump();
        expect(outcome!.isOk, isTrue);
        expect(r.owner.clickVolume, 1.25);
      },
    );
  }

  check('unreadable recovery blocks session capture until explicit Retry', (r) {
    r.load();
    r.looper.stopEngine();
    r.engine.publishClickCommands = false;
    r.engine.nextSnapshot = r.engine.nextSnapshot.copyWith(clickVolume: 1.75);
    expect(r.looper.startEngine(const EngineConfig()), EngineResult.ok);
    r.engine.commandsAreSettled = true;
    var captured = false;
    Object? refusal;
    r.store
      ..failingReads = 1
      ..onReadFailure = () {
        unawaited(
          r.owner
              .runClickVolumeExclusive(() async {
                captured = true;
              })
              .catchError((Object error) {
                refusal = error;
              }),
        );
      };
    r.pump();
    expect(refusal, isA<StateError>());
    expect(captured, isFalse);
    expect(r.store.values['tempo.click_volume'], .5);
    expect(r.looper.clickVolumeRecoveryRequired, isTrue);
    unawaited(r.owner.recoverClickVolume());
    r.pump();
    unawaited(
      r.owner.runClickVolumeExclusive(() async {
        captured = true;
      }),
    );
    r.pump();
    expect(captured, isTrue);
  });

  check('old rollback cannot supply gain for replacement replay recovery', (r) {
    r.load();
    final gate = Completer<void>();
    r.store.writeGate = gate;
    ClickVolumeOutcome? oldOutcome;
    unawaited(r.owner.setClickVolume(1.5).then((v) => oldOutcome = v));
    r.clock.flushMicrotasks();
    r.looper.stopEngine();
    var replaced = false;
    unawaited(
      r.looper
          .applySession(const SessionRig(clickVolume: 1.25))
          .then((_) => replaced = true),
    );
    r.pump();
    expect(replaced, isTrue);
    expect(r.looper.sessionTransport.clickVolume, 1.25);
    r.engine.publishClickCommands = false;
    r.engine.nextSnapshot = r.engine.nextSnapshot.copyWith(clickVolume: 1.75);
    expect(r.looper.startEngine(const EngineConfig()), EngineResult.ok);
    r.engine.commandsAreSettled = true;
    r.pump();
    expect(r.looper.clickVolumeSettled, isFalse);
    expect(r.looper.clickVolumeRecoveryRequired, isTrue);
    r.store
      ..failingWrites = 2
      ..mutateBeforeFailure = true
      ..writeGate = null;
    gate.complete();
    r.pump();
    expect(oldOutcome!.status, ClickVolumeStatus.recoveryRequired);
    expect(r.looper.sessionTransport.clickVolume, 1.25);
    ClickVolumeOutcome? recovered;
    unawaited(r.owner.recoverClickVolume().then((v) => recovered = v));
    r.pump();
    expect(recovered!.isOk, isTrue);
    expect(r.store.values['tempo.click_volume'], .5);
    expect(r.looper.sessionTransport.clickVolume, 1.25);
    r.engine.publishClickCommands = true;
    expect(r.looper.startEngine(const EngineConfig()), EngineResult.ok);
    r.pump();
    expect(r.owner.clickVolume, 1.25);
  });

  check('device restart retires temporary high to authored Released gain', (r) {
    r.load();
    unawaited(
      r.owner.setControllerClickVolume(
        1.5,
        releasedVolume: .25,
        lifetime: r.owner.clickVolumeLifetime,
      ),
    );
    r.pump();
    expect(r.owner.clickVolume, 1.5);
    expect(r.owner.durableClickVolume, .25);
    r.looper.stopEngine();
    expect(r.looper.startEngine(const EngineConfig()), EngineResult.ok);
    r.pump();
    expect(r.looper.sessionTransport.clickVolume, .25);
    expect(r.owner.clickVolume, .25);
    expect(r.owner.durableClickVolume, .25);
    expect(r.store.values['tempo.click_volume'], .25);
  });

  check('superseded rollback failure cannot stop replacement device', (r) {
    r.load();
    final gate = Completer<void>();
    r.store.writeGate = gate;
    ClickVolumeOutcome? result;
    unawaited(r.owner.setClickVolume(1.5).then((v) => result = v));
    r.clock.flushMicrotasks();
    r.looper.stopEngine();
    expect(r.looper.startEngine(const EngineConfig()), EngineResult.ok);
    final stops = r.engine.stopCalls;
    r.store
      ..failingWrites = 3
      ..mutateBeforeFailure = true
      ..writeGate = null;
    gate.complete();
    r.pump();
    expect(result!.status, ClickVolumeStatus.recoveryRequired);
    expect(r.engine.stopCalls, stops);
    expect(r.looper.clickVolumeRecoveryRequired, isFalse);
    r.store.failingWrites = 0;
    unawaited(r.owner.recoverClickVolume().then((v) => result = v));
    r.pump();
    expect(result!.isOk, isTrue);
    expect(r.engine.stopCalls, stops);
    unawaited(r.owner.setClickVolume(1.25).then((v) => result = v));
    r.pump();
    expect(result!.isOk, isTrue);
    expect(r.owner.clickVolume, 1.25);
    expect(r.owner.durableClickVolume, 1.25);
  });
}
