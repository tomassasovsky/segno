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
        unawaited(repository.settleRecordStartSettings());
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

  check('raw pair cannot advance accepted transport before acquired receipt', (
    clock,
    engine,
    repository,
  ) {
    engine.commandsAreSettled = false;
    expect(
      repository.setRecordStartSettings(
        countInBars: 4,
        soundStart: false,
        editKind: RecordStartEditKind.countIn,
      ),
      EngineResult.ok,
    );
    expect(engine.nextSnapshot.countInBars, 4);
    expect(repository.sessionTransport.countInBars, 0);
    expect(repository.state.transport.countInBars, 0);
    EngineResult? result;
    unawaited(
      repository.settleRecordStartSettings().then((value) => result = value),
    );
    clock.elapse(const Duration(milliseconds: 20));
    expect(result, isNull);
    expect(repository.record(), EngineResult.notReady);
    expect(repository.play(), EngineResult.notReady);
    expect(
      repository.setRecordStartSettings(
        countInBars: 0,
        soundStart: true,
        editKind: RecordStartEditKind.sound,
      ),
      EngineResult.notReady,
    );
    engine.commandsAreSettled = true;
    clock.elapse(const Duration(milliseconds: 10));
    expect(result, EngineResult.ok);
    expect(repository.state.transport.countInBars, 4);
    expect(repository.recordStartRestartIntent, (
      countInBars: 4,
      soundStart: false,
    ));
  });

  check('same-value stale receipt reaches autonomous recovery deadline', (
    clock,
    engine,
    repository,
  ) {
    engine.publishRecordStartCommands = false;
    expect(
      repository.setRecordStartSettings(
        countInBars: 0,
        soundStart: false,
        editKind: RecordStartEditKind.countIn,
      ),
      EngineResult.ok,
    );
    clock.elapse(const Duration(milliseconds: 510));
    expect(repository.recordStartRecoveryRequired, isTrue);
    expect(repository.sessionTransport.isRunning, isFalse);
    expect(repository.startEngine(const EngineConfig()), EngineResult.notReady);
    expect(repository.recoverRecordStartSettings(), EngineResult.ok);
    expect(repository.recordStartRecoveryRequired, isFalse);
  });

  check('callback refusal with exact prior pair does not stop healthy audio', (
    clock,
    engine,
    repository,
  ) {
    engine.publishRecordStartCommands = false;
    final revision = engine.nextSnapshot.recordStartRevision;
    expect(
      repository.setRecordStartSettings(
        countInBars: 0,
        soundStart: true,
        editKind: RecordStartEditKind.sound,
      ),
      EngineResult.ok,
    );
    engine.nextSnapshot = engine.nextSnapshot.copyWith(
      recordStartRevision: revision + 1,
      recordStartResult: -1,
    );
    EngineResult? result;
    unawaited(
      repository.settleRecordStartSettings().then((value) => result = value),
    );
    clock.flushMicrotasks();
    expect(result, EngineResult.invalid);
    expect(repository.recordStartRecoveryRequired, isFalse);
    expect(repository.sessionTransport.isRunning, isTrue);
    expect(repository.recordStartSettings, (countInBars: 0, soundStart: false));
  });

  check('accepted stopped pair and restart keep the exact Sound choice', (
    clock,
    engine,
    repository,
  ) {
    repository.stopEngine();
    expect(
      repository.setRecordStartSettings(
        countInBars: 0,
        soundStart: true,
        editKind: RecordStartEditKind.sound,
      ),
      EngineResult.ok,
    );
    expect(repository.recordStartSettings, (countInBars: 0, soundStart: true));
    expect(repository.startEngine(const EngineConfig()), EngineResult.ok);
    unawaited(repository.settleRecordStartSettings());
    clock.flushMicrotasks();
    expect(repository.sessionTransport.autoRecord, isTrue);
    expect(repository.sessionTransport.countInBars, 0);
    expect(engine.nextSnapshot.autoRecord, isTrue);
  });

  check('Held and Released commit together only after acquired receipt', (
    clock,
    engine,
    repository,
  ) {
    engine.commandsAreSettled = false;
    expect(
      repository.setRecordStartSettings(
        countInBars: 2,
        soundStart: false,
        editKind: RecordStartEditKind.countIn,
        releasedSettings: (countInBars: 0, soundStart: false),
      ),
      EngineResult.ok,
    );
    clock.elapse(const Duration(milliseconds: 20));
    expect(engine.nextSnapshot.countInBars, 2);
    expect(repository.recordStartSettings, (countInBars: 0, soundStart: false));
    expect(repository.recordStartRestartIntent, (
      countInBars: 0,
      soundStart: false,
    ));
    engine.commandsAreSettled = true;
    clock.elapse(const Duration(milliseconds: 20));
    expect(repository.recordStartSettings, (countInBars: 2, soundStart: false));
    expect(repository.recordStartRestartIntent, (
      countInBars: 0,
      soundStart: false,
    ));
    repository.stopEngine();
    expect(repository.startEngine(const EngineConfig()), EngineResult.ok);
    unawaited(repository.settleRecordStartSettings());
    clock.flushMicrotasks();
    expect(repository.recordStartSettings, (countInBars: 0, soundStart: false));
    expect(engine.nextSnapshot.countInBars, 0);
  });

  for (final uncertain in [false, true]) {
    check(
      'failed replacement preserves prior live and Released: '
      'uncertain=$uncertain',
      (
        clock,
        engine,
        repository,
      ) {
        expect(
          repository.setRecordStartSettings(
            countInBars: 2,
            soundStart: false,
            editKind: RecordStartEditKind.countIn,
            releasedSettings: (countInBars: 0, soundStart: false),
          ),
          EngineResult.ok,
        );
        unawaited(repository.settleRecordStartSettings());
        clock.flushMicrotasks();
        engine.publishRecordStartCommands = false;
        final revision = engine.nextSnapshot.recordStartRevision;
        expect(
          repository.setRecordStartSettings(
            countInBars: 4,
            soundStart: false,
            editKind: RecordStartEditKind.countIn,
            releasedSettings: (countInBars: 1, soundStart: false),
          ),
          EngineResult.ok,
        );
        if (!uncertain) {
          engine.nextSnapshot = engine.nextSnapshot.copyWith(
            recordStartRevision: revision + 1,
            recordStartResult: -1,
          );
        }
        clock.elapse(const Duration(milliseconds: 510));
        expect(repository.recordStartRecoveryRequired, uncertain);
        if (uncertain) {
          expect(repository.recoverRecordStartSettings(), EngineResult.ok);
        }
        expect(repository.recordStartSettings, (
          countInBars: 2,
          soundStart: false,
        ));
        expect(repository.recordStartRestartIntent, (
          countInBars: 0,
          soundStart: false,
        ));
      },
    );
  }

  check('invalid Released pair is refused before either intent changes', (
    clock,
    engine,
    repository,
  ) {
    final calls = engine.calls.length;
    expect(
      repository.setRecordStartSettings(
        countInBars: 2,
        soundStart: false,
        editKind: RecordStartEditKind.countIn,
        releasedSettings: (countInBars: 1, soundStart: true),
      ),
      EngineResult.invalid,
    );
    expect(engine.calls.length, calls);
    expect(repository.recordStartSettings, (countInBars: 0, soundStart: false));
    expect(repository.recordStartRestartIntent, (
      countInBars: 0,
      soundStart: false,
    ));
  });

  check('malformed pair never changes restart or reaches the engine', (
    clock,
    engine,
    repository,
  ) {
    final count = engine.calls
        .where((value) => value == 'setRecordStartSettings')
        .length;
    expect(
      repository.setRecordStartSettings(
        countInBars: 3,
        soundStart: false,
        editKind: RecordStartEditKind.countIn,
      ),
      EngineResult.invalid,
    );
    expect(
      repository.setRecordStartSettings(
        countInBars: 2,
        soundStart: true,
        editKind: RecordStartEditKind.restore,
      ),
      EngineResult.invalid,
    );
    expect(
      engine.calls.where((value) => value == 'setRecordStartSettings').length,
      count,
    );
    expect(repository.recordStartRestartIntent, (
      countInBars: 0,
      soundStart: false,
    ));
  });
}
