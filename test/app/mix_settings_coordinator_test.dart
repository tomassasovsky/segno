import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/app/mix_settings_coordinator.dart';
import 'package:segno_engine/segno_engine.dart'
    show EngineMixSettings, EngineSnapshot, TrackSnapshot;
import 'package:segno_engine/segno_engine.dart' as engine show LatencyState;

import '../../packages/looper_repository/test/helpers/fake_audio_engine.dart';

class _Persistence implements MixSettingsPersistence {
  String? durable = 'exact prior durable value';
  final candidates = <MixSettingsSnapshot>[];
  Completer<void>? writeGate;
  bool refuseWrite = false;
  bool throwAfterWrite = false;
  bool refuseRestore = false;
  int restores = 0;

  @override
  Future<String?> read(String device) async => durable;

  @override
  Future<void> write(String device, MixSettingsSnapshot candidate) async {
    candidates.add(candidate);
    await writeGate?.future;
    if (refuseWrite) throw StateError('storage refused');
    durable = 'candidate ${candidates.length} for $device';
    if (throwAfterWrite) {
      throw StateError('storage reported failure after write');
    }
  }

  @override
  Future<void> restore(String device, String? checkpoint) async {
    restores++;
    if (refuseRestore) throw StateError('rollback refused');
    durable = checkpoint;
  }
}

EngineSnapshot _rig() => const EngineSnapshot(
  isRunning: true,
  sampleRate: 48000,
  bufferFrames: 128,
  inputChannels: 2,
  outputChannels: 2,
  framesProcessed: 0,
  xrunCount: 0,
  inputRms: 0,
  inputPeak: 0,
  outputRms: 0,
  latencyState: engine.LatencyState.idle,
  measuredLatencyMs: -1,
  tracks: [
    TrackSnapshot(
      state: TrackState.empty,
      volume: 1,
      muted: false,
      lengthFrames: 0,
      undoDepth: 0,
      rms: 0,
      peak: 0,
    ),
  ],
);

Future<void> _turn() => Future<void>.delayed(Duration.zero);

class _LifecycleAudio extends FakeAudioEngine {
  void Function()? afterMix;

  @override
  EngineResult setMix(EngineMixSettings value) {
    final result = super.setMix(value);
    final action = afterMix;
    afterMix = null;
    if (action != null) scheduleMicrotask(action);
    return result;
  }
}

void main() {
  late _LifecycleAudio audio;
  late LooperRepository repository;
  late _Persistence persistence;
  late MixSettingsCoordinator coordinator;
  late StreamController<void> ticker;
  late String device;

  setUp(() {
    audio = _LifecycleAudio()..nextSnapshot = _rig();
    ticker = StreamController<void>.broadcast();
    repository = LooperRepository(engine: audio, ticker: ticker.stream)
      ..startEngine(const EngineConfig());
    persistence = _Persistence();
    device = 'rig A';
    coordinator = MixSettingsCoordinator(
      repository: repository,
      persistence: persistence,
      device: () => device,
    );
    audio.calls.clear();
  });

  tearDown(() async {
    await coordinator.close();
    await repository.dispose();
    await ticker.close();
  });

  test('retains the final same-target and distinct-target values', () async {
    audio
      ..publishMixCommands = false
      ..commandsAreSettled = false;
    final first = coordinator.setTrackPan(.1);
    await _turn();
    expect(audio.calls.where((call) => call == 'setMix'), hasLength(1));
    for (var i = 0; i < 100; i++) {
      unawaited(coordinator.setTrackPan(i / 100));
      unawaited(coordinator.setInputTrimDb(input: 0, db: i / 10));
    }
    unawaited(coordinator.setMonitorVolume(input: 1, volume: .4));
    expect(audio.calls.where((call) => call == 'setMix'), hasLength(1));
    audio
      ..publishMixCommands = true
      ..publishMix()
      ..commandsAreSettled = true;
    expect((await first).isOk, isTrue);
    await coordinator.flush();
    expect(repository.trackPan(0), .99);
    expect(repository.inputSetup.trimDbOf(0), 9.9);
    expect(audio.monitorVolume[1], .4);
    expect(persistence.candidates.last.trackPans[0], .99);
    expect(persistence.candidates.last.inputSetup.trimDbOf(0), 9.9);
    expect(audio.calls.where((call) => call == 'setMix'), hasLength(2));
  });

  test(
    'storage refusal leaves actual controls and durable value unchanged',
    () async {
      persistence.refuseWrite = true;
      final result = await coordinator.setInputTrimDb(input: 0, db: 6);
      expect(result.status, MixSettingsStatus.storageFailed);
      expect(repository.inputSetup.trimDbOf(0), 0);
      expect(audio.inputTrim[0], 1);
      expect(audio.calls, isNot(contains('setMix')));
      expect(persistence.durable, 'exact prior durable value');
    },
  );

  test('write-then-throw restores the exact durable checkpoint', () async {
    persistence.throwAfterWrite = true;
    final result = await coordinator.setTrackPan(.6);
    expect(result.status, MixSettingsStatus.storageFailed);
    expect(repository.trackPan(0), 0);
    expect(persistence.durable, 'exact prior durable value');
    expect(persistence.restores, 1);
    expect(audio.calls, isNot(contains('setMix')));
  });

  test('write-then-throw with failed restore requires recovery', () async {
    persistence
      ..throwAfterWrite = true
      ..refuseRestore = true;
    final result = await coordinator.setTrackPan(.6);
    expect(result.status, MixSettingsStatus.recoveryRequired);
    expect(repository.trackPan(0), 0);
    expect(audio.calls, contains('stop'));
    expect(persistence.durable, 'candidate 1 for rig A');
    audio.calls.clear();
    final generation = repository.mixGeneration;
    expect(repository.startEngine(const EngineConfig()), EngineResult.notReady);
    expect(repository.mixGeneration, generation);
    expect(audio.calls, isNot(contains('start')));
    persistence.refuseRestore = false;
    expect((await coordinator.recover()).isOk, isTrue);
    expect(persistence.durable, 'exact prior durable value');
    expect(repository.startEngine(const EngineConfig()), EngineResult.ok);
  });

  test(
    'old audio remains active throughout an awaited durable write',
    () async {
      persistence.writeGate = Completer<void>();
      final operation = coordinator.setTrackVolume(.25);
      await _turn();
      expect(repository.mixSettingsSnapshot.laneLevels[(0, 0)] ?? 1, 1);
      expect(audio.laneVol[(0, 0)], 1);
      expect(audio.calls, isNot(contains('setMix')));
      persistence.writeGate!.complete();
      expect((await operation).isOk, isTrue);
      expect(audio.laneVol[(0, 0)], .25);
    },
  );

  test(
    'native admission refusal restores the exact previous durable value',
    () async {
      audio.mixResult = EngineResult.notReady;
      final result = await coordinator.setInputPan(input: 0, pan: .8);
      expect(result.status, MixSettingsStatus.rejected);
      expect(persistence.restores, 1);
      expect(persistence.durable, 'exact prior durable value');
      expect(repository.inputSetup.panOf(0), 0);
      expect(audio.monitorPan[0], 0);
    },
  );

  test(
    'late native refusal restores storage without compensation commands',
    () async {
      audio
        ..publishMixCommands = false
        ..commandsAreSettled = false;
      final operation = coordinator.setTrackPan(.7);
      await _turn();
      audio
        ..pendingMix = null
        ..commandsAreSettled = true;
      final result = await operation;
      expect(result.status, MixSettingsStatus.rejected);
      expect(repository.trackPan(0), 0);
      expect(persistence.durable, 'exact prior durable value');
      expect(audio.calls.where((call) => call == 'setMix'), hasLength(1));
    },
  );

  test('rollback failure reports recovery and stops audio', () async {
    persistence.refuseRestore = true;
    audio.mixResult = EngineResult.notReady;
    final errors = <MixSettingsOutcome>[];
    final watch = coordinator.failures.listen(errors.add);
    addTearDown(watch.cancel);
    final result = await coordinator.setTrackPan(.7);
    await _turn();
    expect(result.status, MixSettingsStatus.recoveryRequired);
    expect(errors.single.status, MixSettingsStatus.recoveryRequired);
    expect(audio.calls, contains('stop'));
    expect(persistence.durable, isNot('exact prior durable value'));
    expect(
      (await coordinator.setTrackPan(.2)).status,
      MixSettingsStatus.recoveryRequired,
    );
    await expectLater(
      coordinator.runExclusive(() async => fail('must remain fenced')),
      throwsA(isA<MixSettingsRecoveryException>()),
    );
    persistence.refuseRestore = false;
    expect((await coordinator.recover()).isOk, isTrue);
    expect(persistence.durable, 'exact prior durable value');
    expect((await coordinator.setTrackPan(.2)).isOk, isTrue);
  });

  test('temporary Solo works when durable storage refuses writes', () async {
    persistence.refuseWrite = true;
    expect(
      (await coordinator.setTrackSolo(channel: 0, solo: true)).isOk,
      isTrue,
    );
    expect(repository.trackSoloed(0), isTrue);
    expect(audio.trackSolo[0], isTrue);
    expect(persistence.candidates, isEmpty);
    expect(
      (await coordinator.setTrackPan(.7)).status,
      MixSettingsStatus.storageFailed,
    );
    expect((await coordinator.clearSolo()).isOk, isTrue);
    expect(repository.trackSoloed(0), isFalse);
  });

  test(
    'session rollback shares recovery state and exact retry checkpoint',
    () async {
      persistence
        ..durable = 'unconfirmed incoming session'
        ..refuseRestore = true;
      final outcome = await coordinator.runExclusive(
        () => coordinator.rollbackExclusive(
          device: device,
          checkpoint: 'exact prior session',
        ),
      );
      expect(outcome.status, MixSettingsStatus.recoveryRequired);
      expect(audio.calls, contains('stop'));
      expect(
        (await coordinator.setTrackPan(.8)).status,
        MixSettingsStatus.recoveryRequired,
      );
      persistence.refuseRestore = false;
      expect((await coordinator.recover()).isOk, isTrue);
      expect(persistence.durable, 'exact prior session');
    },
  );

  test('a failed callback does not poison a later valid retry', () async {
    audio
      ..publishMixCommands = false
      ..commandsAreSettled = false;
    final refused = coordinator.setTrackPan(.7);
    await _turn();
    audio
      ..pendingMix = null
      ..commandsAreSettled = true;
    expect((await refused).status, MixSettingsStatus.rejected);
    audio.publishMixCommands = true;
    expect((await coordinator.setTrackPan(.3)).isOk, isTrue);
    expect(repository.trackPan(0), .3);
    expect(audio.lanePan[(0, 0)], .3);
  });

  test('a confirmed mix remains durable when the engine then stops', () async {
    audio.afterMix = repository.stopEngine;

    final outcome = await coordinator.setTrackPan(.6);

    expect(outcome.status, MixSettingsStatus.applied);
    expect(repository.trackPan(0), .6);
    expect(persistence.durable, 'candidate 1 for rig A');
    expect(persistence.restores, 0);

    repository.startEngine(const EngineConfig());
    await repository.settleMixSettings();
    expect(repository.trackPan(0), .6);
    expect(audio.lanePan[(0, 0)], .6);
    expect(persistence.durable, 'candidate 1 for rig A');
  });

  test('empty device refuses input setup edits before applying', () async {
    device = '';
    final refused = await coordinator.setInputTrimDb(input: 0, db: 6);
    expect(refused.status, MixSettingsStatus.rejected);
    expect(repository.inputSetup.trimDbOf(0), 0);
    expect(persistence.candidates, isEmpty);
    expect(audio.calls, isNot(contains('setMix')));

    expect((await coordinator.setTrackPan(.4)).isOk, isTrue);
    expect(repository.trackPan(0), .4);
  });

  test('session replacement during storage fences the stale edit', () async {
    persistence.writeGate = Completer<void>();
    final operation = coordinator.setTrackPan(.6);
    await _turn();
    await repository.applySession(const SessionRig(trackPans: {0: -.2}));
    audio.calls.clear();
    persistence.writeGate!.complete();
    expect((await operation).status, MixSettingsStatus.superseded);
    expect(audio.calls, isNot(contains('setMix')));
    expect(repository.trackPan(0), -.2);
    expect(persistence.durable, 'exact prior durable value');
  });

  test(
    'device switch during storage never applies into the new lifetime',
    () async {
      persistence.writeGate = Completer<void>();
      final operation = coordinator.setTrackPan(.6);
      await _turn();
      repository
        ..stopEngine()
        ..startEngine(const EngineConfig());
      device = 'rig B';
      audio.calls.clear();
      persistence.writeGate!.complete();
      expect((await operation).status, MixSettingsStatus.superseded);
      expect(audio.calls, isNot(contains('setMix')));
      expect(repository.trackPan(0), 0);
      expect(persistence.durable, 'exact prior durable value');
    },
  );

  test(
    'exclusive session work waits for the pending durable transaction',
    () async {
      persistence.writeGate = Completer<void>();
      final edit = coordinator.setTrackPan(.6);
      await _turn();
      var entered = false;
      final session = coordinator.runExclusive(() async {
        entered = true;
        expect(repository.trackPan(0), .6);
      });
      await _turn();
      expect(entered, isFalse);
      persistence.writeGate!.complete();
      await edit;
      await session;
      expect(entered, isTrue);
    },
  );
}
