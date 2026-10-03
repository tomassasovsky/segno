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
  check(
    'same-value stale revision is not completion and deadline is autonomous',
    (clock, engine, repository) {
      engine.publishClickModeCommands = false;
      expect(repository.setClickMode(ClickMode.off), EngineResult.ok);
      clock.elapse(const Duration(milliseconds: 510));
      expect(repository.clickModeRecoveryRequired, isTrue);
      expect(repository.sessionTransport.isRunning, isFalse);
      expect(
        repository.startEngine(const EngineConfig()),
        EngineResult.notReady,
      );
      expect(repository.recoverClickMode(), EngineResult.ok);
      expect(repository.clickModeRecoveryRequired, isFalse);
    },
  );
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
}
