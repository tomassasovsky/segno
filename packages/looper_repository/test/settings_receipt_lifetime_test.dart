import 'dart:async';

import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';

import 'helpers/fake_audio_engine.dart';
import 'helpers/one_shot_edits.dart';

void main() {
  void check(
    String name,
    void Function(FakeAsync, FakeAudioEngine, LooperRepository) body,
  ) {
    test(name, () {
      fakeAsync((time) {
        final engine = FakeAudioEngine();
        final repository = LooperRepository(
          engine: engine,
          ticker: const Stream.empty(),
        );
        expect(repository.startEngine(const EngineConfig()), EngineResult.ok);
        try {
          body(time, engine, repository);
        } finally {
          unawaited(repository.dispose());
          time.flushMicrotasks();
        }
      });
    });
  }

  check('querying Click mismatch cannot classify it; the observer does', (
    time,
    engine,
    repository,
  ) {
    engine
      ..commandsAreSettled = false
      ..publishClickCommands = false;
    expect(repository.setClickVolume(1.5), EngineResult.ok);
    engine.commandsAreSettled = true;
    expect(repository.clickVolumeSettled, isFalse);
    expect(repository.clickVolumeRecoveryRequired, isFalse);
    expect(engine.calls.where((call) => call == 'stop'), isEmpty);
    time.elapse(const Duration(milliseconds: 10));
    expect(repository.clickVolumeRecoveryRequired, isTrue);
    expect(repository.sessionTransport.clickVolume, 1);
    // Uncertainty owes the value; it never stops audio.
    expect(engine.calls.where((call) => call == 'stop'), isEmpty);
  });

  check('Once readiness query cannot accept a newly published vector', (
    time,
    engine,
    repository,
  ) {
    engine.commandsAreSettled = false;
    expect(repository.setOneShot(channel: 2, oneShot: true), EngineResult.ok);
    engine.commandsAreSettled = true;
    expect(repository.oneShotSettingsSettled, isFalse);
    expect(repository.trackOneShotOverrides, isEmpty);
    time.elapse(const Duration(milliseconds: 10));
    expect(repository.oneShotSettingsSettled, isTrue);
    expect(repository.trackOneShotOverrides, {2: true});
  });

  check('Mix confirms autonomously without a listener or awaiting caller', (
    time,
    engine,
    repository,
  ) {
    engine.commandsAreSettled = false;
    expect(repository.setTrackPan(.6, channel: 2), EngineResult.ok);
    expect(repository.mixSettingsSettled, isFalse);
    engine.commandsAreSettled = true;
    time.elapse(const Duration(milliseconds: 10));
    expect(repository.mixSettingsSettled, isTrue);
    expect(repository.trackPans, {2: .6});
  });

  check('later receipt waiter cannot extend an admitted deadline', (
    time,
    engine,
    repository,
  ) {
    engine.commandsAreSettled = false;
    expect(repository.setClickVolume(1.5), EngineResult.ok);
    time.elapse(const Duration(milliseconds: 450));
    EngineResult? later;
    unawaited(
      repository.settleClickVolume().then((result) => later = result),
    );
    time.elapse(const Duration(milliseconds: 49));
    expect(later, isNull);
    time.elapse(const Duration(milliseconds: 1));
    expect(later, EngineResult.notReady);
    expect(repository.clickVolumeRecoveryRequired, isTrue);
    expect(engine.calls.where((call) => call == 'stop'), isEmpty);
  });

  check('a shorter caller budget stays bounded when another waiter arrives', (
    time,
    engine,
    repository,
  ) {
    engine.commandsAreSettled = false;
    expect(repository.setClickVolume(1.5), EngineResult.ok);
    time.elapse(const Duration(milliseconds: 255));
    EngineResult? early;
    EngineResult? later;
    unawaited(
      repository
          .settleClickVolume(
            pollInterval: const Duration(milliseconds: 8),
            attempts: 2,
          )
          .then((result) => early = result),
    );
    time.elapse(const Duration(milliseconds: 5));
    unawaited(repository.settleClickVolume().then((result) => later = result));
    time.elapse(const Duration(milliseconds: 5));
    expect(early, isNull);
    expect(later, isNull);
    time.elapse(const Duration(milliseconds: 10));
    expect(early, EngineResult.notReady);
    expect(later, EngineResult.notReady);
    expect(engine.calls.where((call) => call == 'stop'), isEmpty);
  });

  check('a new short budget does not consume undelivered earlier ticks', (
    time,
    engine,
    repository,
  ) {
    engine.commandsAreSettled = false;
    expect(repository.setClickVolume(1.5), EngineResult.ok);
    time
      ..elapse(const Duration(milliseconds: 10))
      ..elapseBlocking(const Duration(milliseconds: 190));
    EngineResult? result;
    unawaited(
      repository
          .settleClickVolume(attempts: 10)
          .then((value) => result = value),
    );
    time.elapse(Duration.zero);
    expect(result, isNull);
    time.elapse(const Duration(milliseconds: 99));
    expect(result, isNull);
    time.elapse(const Duration(milliseconds: 1));
    expect(result, EngineResult.notReady);
    expect(engine.calls.where((call) => call == 'stop'), isEmpty);
  });

  for (final jump in [const Duration(days: 1), const Duration(days: -1)]) {
    check('wall-clock jump $jump cannot move the admitted deadline', (
      time,
      engine,
      repository,
    ) {
      var offset = Duration.zero;
      withClock(Clock(() => DateTime.utc(2026).add(time.elapsed + offset)), () {
        engine.commandsAreSettled = false;
        expect(repository.setClickVolume(1.5), EngineResult.ok);
        time.elapse(const Duration(milliseconds: 250));
        offset = jump;
        time.elapse(const Duration(milliseconds: 249));
        expect(repository.clickVolumeRecoveryRequired, isFalse);
        time.elapse(const Duration(milliseconds: 1));
        expect(repository.clickVolumeRecoveryRequired, isTrue);
        expect(repository.sessionTransport.clickVolume, 1);
        expect(engine.calls.where((call) => call == 'stop'), isEmpty);
      });
    });
  }

  check('replacement retires every old settings waiter and deadline', (
    time,
    engine,
    repository,
  ) {
    engine.commandsAreSettled = false;
    expect(repository.setTrackPan(.6), EngineResult.ok);
    expect(repository.setClickVolume(1.5), EngineResult.ok);
    expect(repository.setClickMode(ClickMode.rec), EngineResult.ok);
    expect(repository.setDefaultOneShot(oneShot: true), EngineResult.ok);
    expect(repository.setDefaultLengthPreset(4), EngineResult.ok);
    expect(
      repository.setRecordTimingSettings(
        defaultTiming: RecordTiming.quarter,
        rememberedDivision: GridDivision.quarter,
        trackOverrides: {},
      ),
      EngineResult.ok,
    );
    expect(
      repository.setRecordStartSettings(
        countInBars: 4,
        soundStart: false,
        editKind: RecordStartEditKind.countIn,
      ),
      EngineResult.ok,
    );
    final outcomes = <EngineResult>[];
    for (final pending in [
      repository.settleMixSettings(),
      repository.settleClickVolume(),
      repository.settleClickMode(),
      repository.settleOneShot(),
      repository.settleLengthSettings(),
      repository.settleRecordTimingSettings(),
      repository.settleRecordStartSettings(),
    ]) {
      unawaited(pending.then(outcomes.add));
    }
    // Reconfiguration replaces ownership without a preceding public Stop.
    engine.commandsAreSettled = true;
    expect(repository.startEngine(const EngineConfig()), EngineResult.ok);
    time.flushMicrotasks();
    expect(outcomes, List.filled(7, EngineResult.notReady));
    expect(repository.trackPans, isEmpty);
    expect(repository.sessionTransport.clickVolume, 1);
    expect(repository.sessionTransport.clickMode, ClickMode.off);
    expect(repository.defaultOneShot, isFalse);
    expect(repository.recordStartSettings, (countInBars: 0, soundStart: false));
    final stops = engine.calls.where((call) => call == 'stop').length;
    time.elapse(const Duration(seconds: 1));
    expect(engine.calls.where((call) => call == 'stop').length, stops);
    expect(repository.recordTimingRecoveryRequired, isFalse);
    expect(repository.clickVolumeRecoveryRequired, isFalse);
    expect(repository.lengthRecoveryRequired, isFalse);
  });
}
