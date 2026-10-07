import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno_engine/segno_engine.dart'
    show LaneSnapshot, TrackSnapshot;

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

  check('a same-value stale receipt owes the pair at the deadline, running', (
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
    expect(repository.sessionTransport.isRunning, isTrue);
    expect(engine.calls.where((call) => call == 'stop'), isEmpty);
    // An owed pair fences new takes but never playback.
    expect(repository.play(), isNot(EngineResult.notReady));
    engine.publishRecordStartCommands = true;
    expect(repository.recoverRecordStartSettings(), EngineResult.ok);
    clock.elapse(const Duration(milliseconds: 20));
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

  check('Sound start refuses an empty track with no usable input', (
    clock,
    engine,
    repository,
  ) {
    final required = <int>[];
    final sub = repository.recordingInputRequired.listen(required.add);
    expect(
      repository.setRecordStartSettings(
        countInBars: 0,
        soundStart: true,
        editKind: RecordStartEditKind.sound,
      ),
      EngineResult.ok,
    );
    unawaited(repository.settleRecordStartSettings());
    clock.flushMicrotasks();
    expect(repository.recordStartSettings, (countInBars: 0, soundStart: true));
    // Track 0's lane records input 0, but the device opened no input
    // channels: Sound start could never trigger.
    engine.nextSnapshot = engine.nextSnapshot.copyWith(
      inputChannels: 0,
      tracks: [
        const TrackSnapshot(
          state: TrackState.empty,
          volume: 1,
          muted: false,
          lengthFrames: 0,
          undoDepth: 0,
          rms: 0,
          peak: 0,
          lanes: [
            LaneSnapshot(
              inputChannel: 0,
              outputMask: 0x3,
              volume: 1,
              muted: false,
              lengthFrames: 0,
              rms: 0,
              peak: 0,
            ),
          ],
        ),
        ...engine.nextSnapshot.tracks.skip(1),
      ],
    );
    expect(repository.record(), EngineResult.invalid);
    clock.flushMicrotasks();
    expect(required, [0]);
    // Every input the lane could use is excluded: still refused.
    engine.nextSnapshot = engine.nextSnapshot.copyWith(
      inputChannels: 2,
      excludedInputMask: 0x3,
    );
    expect(repository.record(), EngineResult.invalid);
    clock.flushMicrotasks();
    expect(required, [0, 0]);
    // A usable input admits the arm.
    engine.nextSnapshot = engine.nextSnapshot.copyWith(excludedInputMask: 0);
    expect(repository.record(), EngineResult.ok);
    unawaited(sub.cancel());
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
      'failed replacement keeps prior live; uncertain=$uncertain',
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
        expect(repository.recordStartSettings, (
          countInBars: 2,
          soundStart: false,
        ));
        // A refusal keeps the prior Released pair; uncertainty owes the
        // requested one, which Retry and a restart replay.
        expect(
          repository.recordStartRestartIntent,
          uncertain
              ? (countInBars: 1, soundStart: false)
              : (countInBars: 0, soundStart: false),
        );
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
