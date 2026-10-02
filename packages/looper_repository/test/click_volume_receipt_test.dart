import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';

import 'helpers/fake_audio_engine.dart';

void main() {
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
        try {
          body(clock, engine, repository);
        } finally {
          unawaited(repository.dispose());
          clock.flushMicrotasks();
        }
      }),
    );
  }

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
    unawaited(repository.settleClickVolume().then((value) => receipt = value));
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
    expect(repository.clickVolumeSettled, isTrue);
    expect(repository.sessionTransport.clickVolume, 1.5);
  });

  check('mismatched callback gain stops uncertain audio and blocks restart', (
    clock,
    engine,
    repository,
  ) {
    engine.publishClickCommands = false;
    expect(repository.setClickVolume(1.5), EngineResult.ok);
    expect(repository.clickVolumeSettled, isFalse);
    expect(repository.clickVolumeRecoveryRequired, isTrue);
    expect(repository.sessionTransport.isRunning, isFalse);
    expect(repository.sessionTransport.clickVolume, 1);
    expect(repository.startEngine(const EngineConfig()), EngineResult.notReady);
  });

  check('timeout stops pending audio and keeps prior accepted gain', (
    clock,
    engine,
    repository,
  ) {
    engine
      ..publishClickCommands = false
      ..commandsAreSettled = false;
    expect(repository.setClickVolume(1.5), EngineResult.ok);
    EngineResult? receipt;
    unawaited(
      repository
          .settleClickVolume(attempts: 2)
          .then((value) => receipt = value),
    );
    clock.elapse(const Duration(milliseconds: 30));
    expect(receipt, EngineResult.notReady);
    expect(repository.clickVolumeRecoveryRequired, isTrue);
    expect(repository.sessionTransport.isRunning, isFalse);
    expect(repository.sessionTransport.clickVolume, 1);
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
}
