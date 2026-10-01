import 'dart:async';
import 'dart:typed_data';

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

EngineSnapshot _rig({int trackCount = 1}) => EngineSnapshot(
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
    for (var channel = 0; channel < trackCount; channel++)
      const TrackSnapshot(
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

  test('compound output edits publish one confirmed mix value', () async {
    final level = coordinator.setOutputLevel(bus: 0, level: .4);
    final muted = coordinator.setOutputMute(bus: 0, muted: true);
    final mono = coordinator.setOutputMono(bus: 0, mono: true);
    final balance = coordinator.setOutputBalance(bus: 0, balance: -.25);
    expect((await level).isOk, isTrue);
    await Future.wait([muted, mono, balance]);
    await coordinator.flush();
    expect(
      repository.outputSetup.of(0),
      const OutputBus(level: .4, muted: true, mono: true, balance: -.25),
    );
    expect(
      persistence.candidates.last.outputSetup.of(0),
      repository.outputSetup.of(0),
    );
    expect(
      audio.calls.where((call) => call == 'setMix').length,
      lessThanOrEqualTo(2),
    );
  });

  test('output storage refusal retains the exact old setup', () async {
    persistence.refuseWrite = true;
    final result = await coordinator.setOutputLevel(bus: 0, level: .4);
    expect(result.status, MixSettingsStatus.storageFailed);
    expect(repository.outputSetup, const OutputSetup());
    expect(persistence.durable, 'exact prior durable value');
    expect(audio.calls, isNot(contains('setMix')));
  });

  test('whole-track destination commits future slots in one mix', () async {
    final result = await coordinator.setTrackOutput(channel: 0, mask: 1);
    expect(result.isOk, isTrue);
    for (var lane = 0; lane < 8; lane++) {
      expect(repository.mixSettingsSnapshot.laneOutputs[(0, lane)], 1);
      expect(persistence.candidates.single.laneOutputs[(0, lane)], 1);
    }
    expect(audio.calls.where((call) => call == 'setMix'), hasLength(1));
  });

  test(
    'queued route growth and track fader keep part levels independent',
    () async {
      persistence.writeGate = Completer<void>();
      final first = coordinator.setTrackPan(.2);
      await _turn();
      final route = coordinator.setRecordingInput(
        channel: 0,
        input: 1,
        selected: true,
      );
      final volume = coordinator.setTrackVolume(.25);
      persistence.writeGate!.complete();
      expect((await first).isOk, isTrue);
      expect((await route).isOk, isTrue);
      expect((await volume).isOk, isTrue);
      expect(repository.mixSettingsSnapshot.laneCounts[0], 2);
      expect(repository.mixSettingsSnapshot.trackLevels[0], .25);
      expect(repository.mixSettingsSnapshot.laneLevels, {(0, 1): 1});
      expect(persistence.candidates.last.trackLevels[0], .25);
      expect(persistence.candidates.last.laneLevels, {(0, 1): 1});
    },
  );

  test(
    'routing storage refusal leaves live and durable routes intact',
    () async {
      persistence.throwAfterWrite = true;
      final before = repository.mixSettingsSnapshot;
      final result = await coordinator.setRecordingInput(
        channel: 0,
        input: 1,
        selected: true,
      );
      expect(result.status, MixSettingsStatus.storageFailed);
      expect(repository.mixSettingsSnapshot, before);
      expect(persistence.durable, 'exact prior durable value');
      expect(persistence.restores, 1);
      expect(audio.calls, isNot(contains('setMix')));
    },
  );

  test('output native refusal restores prior durable checkpoint', () async {
    audio.mixResult = EngineResult.notReady;
    final result = await coordinator.setOutputMono(bus: 0, mono: true);
    expect(result.status, MixSettingsStatus.rejected);
    expect(repository.outputSetup, const OutputSetup());
    expect(persistence.durable, 'exact prior durable value');
    expect(persistence.restores, 1);
  });

  test(
    'output native refusal restores a genuinely absent checkpoint',
    () async {
      persistence.durable = null;
      audio.mixResult = EngineResult.notReady;
      final result = await coordinator.setOutputMute(bus: 0, muted: true);
      expect(result.status, MixSettingsStatus.rejected);
      expect(repository.outputSetup, const OutputSetup());
      expect(persistence.durable, isNull);
      expect(persistence.restores, 1);
    },
  );

  test('failed output rollback stops audio until recovery succeeds', () async {
    persistence.refuseRestore = true;
    audio.mixResult = EngineResult.notReady;
    final result = await coordinator.setOutputBalance(bus: 0, balance: .7);
    expect(result.status, MixSettingsStatus.recoveryRequired);
    expect(repository.outputSetup, const OutputSetup());
    expect(audio.calls, contains('stop'));
    expect(repository.startEngine(const EngineConfig()), EngineResult.notReady);
    persistence.refuseRestore = false;
    expect((await coordinator.recover()).isOk, isTrue);
    expect(persistence.durable, 'exact prior durable value');
    audio.mixResult = EngineResult.ok;
    expect(repository.startEngine(const EngineConfig()), EngineResult.ok);
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
      expect(repository.mixSettingsSnapshot.trackLevels[0] ?? 1, 1);
      expect(audio.laneVol[(0, 0)], 1);
      expect(audio.calls, isNot(contains('setMix')));
      persistence.writeGate!.complete();
      expect((await operation).isOk, isTrue);
      expect(repository.mixSettingsSnapshot.trackLevels[0], .25);
      expect(audio.laneVol[(0, 0)], 1);
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

  test(
    'queued temporary Solo survives a neighboring persistent refusal',
    () async {
      persistence.writeGate = Completer<void>();
      final first = coordinator.setTrackPan(.2);
      await _turn();
      final persistent = coordinator.setTrackVolume(.4);
      final solo = coordinator.setTrackSolo(channel: 0, solo: true);
      persistence.refuseWrite = true;
      persistence.writeGate!.complete();
      await Future.wait([first, persistent, solo]);
      expect(repository.trackPan(0), 0);
      expect(repository.state.track.volume, 1);
      expect(repository.trackSoloed(0), isTrue);
      expect(audio.trackSolo[0], isTrue);
      expect(persistence.durable, 'exact prior durable value');
      expect(persistence.candidates, hasLength(2));
    },
  );

  for (final presses in [2, 3, 1000]) {
    test('queued Solo reduces $presses presses while storage awaits', () async {
      persistence.writeGate = Completer<void>();
      final first = coordinator.setTrackPan(.2);
      await _turn();
      for (var press = 0; press < presses; press++) {
        unawaited(coordinator.toggleTrackSolo(channel: 0));
      }
      persistence.writeGate!.complete();
      await first;
      expect(repository.trackSoloed(0), presses.isOdd);
      expect(persistence.candidates, hasLength(1));
      expect(
        audio.calls.where((call) => call == 'setMix').length,
        presses.isOdd ? 2 : 1,
      );
    });
  }

  test(
    'Solo toggle waits for callback then inverts its confirmed result',
    () async {
      audio
        ..publishMixCommands = false
        ..commandsAreSettled = false;
      final first = coordinator.toggleTrackSolo(channel: 0);
      await _turn();
      expect(repository.trackSoloed(0), isFalse);
      final second = coordinator.toggleTrackSolo(channel: 0);
      audio
        ..publishMixCommands = true
        ..publishMix()
        ..commandsAreSettled = true;
      await Future.wait([first, second]);
      expect(repository.trackSoloed(0), isFalse);
      expect(persistence.candidates, isEmpty);
      expect(audio.calls.where((call) => call == 'setMix'), hasLength(2));
    },
  );

  test(
    'queued explicit Solo, toggle and Clear Solo preserve their order',
    () async {
      persistence.writeGate = Completer<void>();
      final first = coordinator.setTrackPan(.2);
      await _turn();
      unawaited(coordinator.setTrackSolo(channel: 0, solo: true));
      unawaited(coordinator.toggleTrackSolo(channel: 0)); // false
      unawaited(coordinator.toggleTrackSolo(channel: 1));
      unawaited(coordinator.clearSolo()); // cancels both preceding edits
      unawaited(coordinator.toggleTrackSolo(channel: 1)); // true after clear
      unawaited(coordinator.setTrackSolo(channel: 2, solo: false));
      unawaited(coordinator.toggleTrackSolo(channel: 2)); // true
      unawaited(coordinator.toggleTrackSolo(channel: 3));
      unawaited(coordinator.setTrackSolo(channel: 3, solo: false));
      persistence.writeGate!.complete();
      await first;
      expect(
        [
          for (var channel = 0; channel < 4; channel++)
            repository.trackSoloed(channel),
        ],
        [false, true, true, false],
      );
      expect(persistence.candidates, hasLength(1));
    },
  );

  test(
    'reset publishes all eight gains and pans atomically, '
    'preserving other facts',
    () async {
      audio.nextSnapshot = _rig(trackCount: 8);
      final seed = MixSettingsSnapshot(
        trackLevels: {
          for (var channel = 0; channel < 8; channel++) channel: .3,
        },
        trackPans: {
          for (var channel = 0; channel < 8; channel++)
            channel: -.7 + channel / 10,
        },
        laneLevels: {
          for (var channel = 0; channel < 8; channel++)
            (channel, 0): .2 + channel / 10,
          (7, 7): .4,
        },
        trackSolos: const {1: true, 6: true},
        laneOutputs: const {(7, 7): 12},
        inputSetup: InputSetup(trimDb: const {0: -6}, pan: const {0: -.25}),
        monitorLevels: const {0: .6},
        outputSetup: const OutputSetup(
          buses: {0: OutputBus(level: .7, muted: true)},
        ),
      );
      expect(repository.applyMixSettings(seed), EngineResult.ok);
      expect(repository.record(), EngineResult.ok);
      final sourceImages = Map.of(audio.sourceImages);
      expect(sourceImages[(0, 0)]!.pan, -.25);
      final pcm = Float32List.fromList([.125, -.375, .5]);
      audio
        ..importLayer(0, 0, 0, pcm)
        ..laneMute[(0, 0)] = true
        ..laneFxParam[(0, 0, 0, 0)] = .35
        ..calls.clear()
        ..publishMixCommands = false
        ..commandsAreSettled = false;
      final reset = coordinator.resetMixer();
      await _turn();
      expect(repository.mixSettingsSnapshot, seed);
      expect(persistence.candidates, hasLength(1));
      for (var channel = 0; channel < 8; channel++) {
        expect(audio.pendingMix!.trackLevels[channel], 1);
        expect(audio.pendingMix!.lanes[(channel, 0)]?.pan ?? 0, 0);
      }
      expect(audio.pendingMix!.lanes[(7, 7)], isNull);
      audio
        ..publishMix()
        ..commandsAreSettled = true;
      expect((await reset).isOk, isTrue);
      for (var channel = 0; channel < 8; channel++) {
        expect(repository.trackPan(channel), 0);
        expect(repository.state.tracks[channel].volume, 1);
        expect(audio.liveMix[(channel, 0)]!.gain, .2 + channel / 10);
      }
      final after = repository.mixSettingsSnapshot;
      expect(after.trackLevels, isEmpty);
      expect(after.laneLevels, seed.laneLevels);
      expect(after.trackSolos, {1: true, 6: true});
      expect(after.laneOutputs, {(7, 7): 12});
      expect(after.inputSetup, seed.inputSetup);
      expect(after.outputSetup, seed.outputSetup);
      expect(after.monitorLevels, {0: .6});
      expect(audio.sourceImages, sourceImages);
      expect(audio.lanePan[(0, 0)], -.25);
      expect(audio.laneMute[(0, 0)], isTrue);
      expect(audio.laneFxParam[(0, 0, 0, 0)], .35);
      expect(audio.importedLayers[(0, 0, 0)], orderedEquals(pcm));
      expect(audio.calls, ['setMix']);
      expect(persistence.candidates.single.trackPans, isEmpty);
      expect(persistence.candidates.single.trackLevels, isEmpty);
      expect(persistence.candidates.single.laneLevels, seed.laneLevels);
    },
  );

  for (final refusal in [
    'storage after write',
    'native admission',
    'callback',
  ]) {
    test(
      'reset $refusal refusal retains exact mix and durable checkpoint',
      () async {
        final seed = MixSettingsSnapshot(
          trackLevels: const {0: .4, 7: 1.5},
          trackPans: const {0: -.5, 7: .7},
          laneLevels: const {(0, 0): .2, (7, 7): .8},
          trackSolos: const {1: true},
        );
        expect(repository.applyMixSettings(seed), EngineResult.ok);
        audio.calls.clear();
        if (refusal == 'storage after write') {
          persistence.throwAfterWrite = true;
        }
        if (refusal == 'native admission') {
          audio.mixResult = EngineResult.notReady;
        }
        if (refusal == 'callback') {
          audio
            ..publishMixCommands = false
            ..commandsAreSettled = false;
        }
        final reset = coordinator.resetMixer();
        await _turn();
        if (refusal == 'callback') {
          audio
            ..pendingMix = null
            ..commandsAreSettled = true;
        }
        expect((await reset).isOk, isFalse);
        expect(repository.mixSettingsSnapshot, seed);
        expect(persistence.durable, 'exact prior durable value');
        expect(persistence.restores, 1);
      },
    );
  }

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

  test(
    'session replacement during reset never publishes the old reset',
    () async {
      expect(
        repository.applyMixSettings(
          MixSettingsSnapshot(
            trackLevels: const {0: .4, 7: 1.5},
            trackPans: const {0: -.5, 7: .7},
            laneLevels: const {(0, 0): .2, (7, 7): .8},
          ),
        ),
        EngineResult.ok,
      );
      persistence.writeGate = Completer<void>();
      final reset = coordinator.resetMixer();
      await _turn();
      await repository.applySession(const SessionRig(trackPans: {0: -.2}));
      audio.calls.clear();
      persistence.writeGate!.complete();
      expect((await reset).status, MixSettingsStatus.superseded);
      expect(audio.calls, isNot(contains('setMix')));
      expect(repository.trackPan(0), -.2);
      expect(persistence.durable, 'exact prior durable value');
    },
  );

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
