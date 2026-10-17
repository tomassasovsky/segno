import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/looper/application/record_settings.dart';
import 'package:segno/looper/model/owned_setting.dart';
import 'package:segno/looper/model/record_length.dart';
import 'package:segno_engine/segno_engine.dart'
    show EngineSnapshot, TrackSnapshot;
import 'package:segno_engine/segno_engine.dart' as native show EngineConfig;
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/fake_audio_engine.dart';
import '../../helpers/fake_key_value_store.dart';

class _Engine extends FakeAudioEngine {
  bool corruptLength = false;
  bool captureAtEnqueue = false;
  @override
  EngineResult start(native.EngineConfig config) {
    final result = super.start(config);
    if (result.isOk) nextSnapshot = nextSnapshot.copyWith(isRunning: true);
    return result;
  }

  @override
  EngineResult stop() {
    final result = super.stop();
    nextSnapshot = nextSnapshot.copyWith(isRunning: false);
    return result;
  }

  @override
  EngineResult setTrackLengthPresets(List<int> bars) {
    if (captureAtEnqueue) {
      nextSnapshot = nextSnapshot.copyWith(
        looperMode: LooperMode.free,
        tracks: [
          const TrackSnapshot(
            state: TrackState.recording,
            volume: 1,
            muted: false,
            lengthFrames: 0,
            undoDepth: 0,
            rms: 0,
            peak: 0,
          ),
          for (var c = 1; c < 8; c++) const TrackSnapshot.empty(),
        ],
      );
      return EngineResult.ok;
    }
    final result = super.setTrackLengthPresets(bars);
    if (corruptLength) publishedLengths[0] = 37;
    return result;
  }
}

class _Store extends FakeKeyValueStore {
  Completer<void>? readGate;
  Completer<void>? writeGate;
  int failures = 0;
  bool readFailure = false;
  bool writeEntered = false;
  @override
  Future<int?> getInt(String key) async {
    if (key.startsWith('tempo.length_preset')) {
      await readGate?.future;
      if (readFailure) throw StateError('read refused');
    }
    return super.getInt(key);
  }

  @override
  Future<void> setInt(String key, int value) async {
    if (key.contains('length')) {
      writeEntered = true;
      await writeGate?.future;
      await super.setInt(key, value);
      if (failures > 0) {
        failures--;
        throw StateError('mutated then refused');
      }
    } else {
      await super.setInt(key, value);
    }
  }
}

void main() {
  group('Record length owner', () {
    late _Engine engine;
    late LooperRepository repository;
    late _Store store;
    late RecordSettings owner;
    setUp(() {
      engine = _Engine();
      repository = LooperRepository(
        engine: engine,
        ticker: const Stream.empty(),
      );
      store = _Store()..values['looper.mode'] = LooperMode.free.code;
      owner = RecordSettings(
        repository: repository,
        settings: SettingsRepository(store: store),
      );
    });
    tearDown(() async {
      await owner.close();
      await repository.dispose();
    });
    Future<void> start() async {
      expect(repository.startEngine(const EngineConfig()).isOk, isTrue);
      await owner.load();
      expect(owner.recordLengthSnapshot, isNotNull);
    }

    Future<RecordLengthOutcome> hold({int bars = 16, int released = 4}) =>
        owner.setControllerRecordLength(
          const RecordLengthAddress.track(0),
          bars,
          lifetime: owner.recordLengthLifetime,
          revision: owner.recordLengthRevision(
            const RecordLengthAddress.track(0),
          ),
          releasedBars: released,
        );
    void capture(TrackState state) {
      engine.nextSnapshot = const EngineSnapshot.initial().copyWith(
        isRunning: true,
        looperMode: LooperMode.free,
        tracks: [
          TrackSnapshot(
            state: state,
            volume: 1,
            muted: false,
            lengthFrames: 0,
            undoDepth: 0,
            rms: 0,
            peak: 0,
          ),
          for (var c = 1; c < 8; c++) const TrackSnapshot.empty(),
        ],
      );
    }

    test(
      'initial zero readiness publishes independently of other options',
      () async {
        store.readGate = Completer<void>();
        final loading = owner.load();
        await Future<void>.delayed(Duration.zero);
        await owner.setRecDub(value: true);
        expect(owner.state.recDub, isTrue);
        expect(owner.recordLengthSnapshot, isNull);
        store.readGate!.complete();
        await loading;
        expect(owner.recordLengthSnapshot!.defaultBars, 0);
        expect(owner.state.recordLengthReady, isTrue);
      },
    );
    test(
      'malformed last slot prevents every length and mode restore until '
      'Retry repairs it',
      () async {
        store.values.addAll({
          'looper.default_length_bars': 8,
          'tempo.length_preset.7': 65,
        });
        await owner.load();
        expect(owner.recordLengthSnapshot, isNull);
        expect(repository.sessionTransport.defaultLengthPresetBars, 0);
        expect(repository.sessionTransport.looperMode, LooperMode.multi);
        expect(store.values['tempo.length_preset.7'], 65);
        // Retry removes the unreadable key and restores the rest.
        expect((await owner.owner.recover()).isOk, isTrue);
        expect(store.values.containsKey('tempo.length_preset.7'), isFalse);
        expect(owner.recordLengthSnapshot!.defaultBars, 8);
        expect(owner.recordLengthSnapshot!.mode, LooperMode.free);
      },
    );
    test(
      'failed startup exposes persistent Retry and revalidates on recovery',
      () async {
        final failures = <SettingOutcome>[];
        final subscription = owner.owner.failures.listen(failures.add);
        store.readFailure = true;
        await owner.load();
        expect(owner.recordLengthSnapshot, isNull);
        expect(failures.single.status, SettingStatus.recoveryRequired);
        expect((await owner.owner.flush()).isOk, isFalse);
        store.readFailure = false;
        expect((await owner.owner.recover()).isOk, isTrue);
        expect(owner.recordLengthSnapshot!.defaultBars, 0);
        await subscription.cancel();
      },
    );
    test('all eight explicit Auto overrides survive strict startup', () async {
      store.values.addAll({
        for (var c = 0; c < 8; c++) 'tempo.length_preset.$c': 0,
      });
      await owner.load();
      expect(owner.recordLengthSnapshot!.trackOverrides, {
        for (var c = 0; c < 8; c++) c: 0,
      });
    });
    test('matching native vector waits for commandsSettled', () async {
      await start();
      engine.commandsAreSettled = false;
      var completed = false;
      final write = owner.setTrackRecordLength(channel: 0, bars: 0).then((
        value,
      ) {
        completed = true;
        return value;
      });
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(completed, isFalse);
      expect(owner.recordLengthSnapshot!.trackOverrides, isEmpty);
      engine.commandsAreSettled = true;
      expect((await write).isOk, isTrue);
      expect(owner.recordLengthSnapshot!.trackOverrides, {0: 0});
    });
    test(
      'held live value persists Released and reconnect never replays Held',
      () async {
        await start();
        expect((await hold()).isOk, isTrue);
        expect(owner.recordLengthSnapshot!.trackOverrides, {0: 16});
        expect(owner.durableRecordLengthSnapshot.trackOverrides, {0: 4});
        expect(store.values['tempo.length_preset.0'], 4);
        repository
          ..stopEngine()
          ..startEngine(const EngineConfig());
        await repository.settleLengthSettings();
        expect(repository.trackLengthPresetOverrides, {0: 4});
        expect(engine.publishedLengths[0], 4);
      },
    );
    test(
      'Use default removes explicit Auto and supersedes an older cleanup',
      () async {
        await owner.load();
        await owner.setTrackRecordLength(channel: 0, bars: 0);
        final revision = owner.recordLengthRevision(
          const RecordLengthAddress.track(0),
        );
        await owner.setTrackRecordLength(channel: 0, bars: null);
        await owner.setDefaultLengthBars(8);
        final stale = await owner.setControllerRecordLength(
          const RecordLengthAddress.track(0),
          0,
          lifetime: owner.recordLengthLifetime,
          revision: revision,
        );
        expect(stale.status, RecordLengthStatus.superseded);
        expect(owner.recordLengthSnapshot!.trackOverrides, isEmpty);
        expect(
          owner.recordLengthSnapshot!.effectiveBars(
            const RecordLengthAddress.track(0),
          ),
          8,
        );
        expect(store.values.containsKey('tempo.length_preset.0'), isFalse);
      },
    );
    test(
      'capture before or during storage refuses without stopping or claiming',
      () async {
        await start();
        capture(TrackState.recording);
        expect((await hold()).status, RecordLengthStatus.rejected);
        expect(store.values.containsKey('tempo.length_preset.0'), isFalse);
        capture(TrackState.empty);
        store.writeGate = Completer<void>();
        final writing = hold();
        await Future<void>.delayed(Duration.zero);
        expect(store.writeEntered, isTrue);
        capture(TrackState.overdubbing);
        store.writeGate!.complete();
        expect((await writing).status, RecordLengthStatus.rejected);
        expect(repository.state.status.isConnected, isTrue);
        expect(owner.recordLengthSnapshot!.trackOverrides, isEmpty);
        expect(store.values.containsKey('tempo.length_preset.0'), isFalse);
      },
    );
    test(
      'exact old vector refusal rolls back without stopping healthy rig',
      () async {
        await start();
        engine.publishLengthCommands = false;
        expect((await hold()).status, RecordLengthStatus.rejected);
        expect(repository.lengthRecoveryRequired, isFalse);
        expect(repository.state.status.isConnected, isTrue);
        expect(store.values.containsKey('tempo.length_preset.0'), isFalse);
        engine.publishLengthCommands = true;
        expect((await owner.owner.recover()).isOk, isTrue);
        expect((await hold()).isOk, isTrue);
      },
    );
    test(
      'an unknown vector is owed without a stop, and Retry lands the '
      'Released value',
      () async {
        await start();
        engine
          ..publishLengthCommands = false
          ..corruptLength = true;
        expect((await hold()).status, RecordLengthStatus.recoveryRequired);
        expect(repository.sessionTransport.isRunning, isTrue);
        expect(engine.stopCalls, 0);
        // Storage keeps the Released value the receipt owes.
        expect(store.values['tempo.length_preset.0'], 4);
        engine
          ..publishLengthCommands = true
          ..corruptLength = false;
        expect((await owner.owner.recover()).isOk, isTrue);
        expect(owner.recordLengthSnapshot!.trackOverrides, {0: 4});
      },
    );
    test(
      'Multi atomically retires track Held to Released but preserves '
      'default Held',
      () async {
        await start();
        await hold();
        await owner.setControllerRecordLength(
          const RecordLengthAddress.defaults(),
          12,
          releasedBars: 6,
          lifetime: owner.recordLengthLifetime,
          revision: 0,
        );
        final rev = owner.recordLengthRevision(
          const RecordLengthAddress.track(0),
        );
        expect((await owner.setLooperMode(LooperMode.multi)).isOk, isTrue);
        expect(owner.recordLengthSnapshot!.trackOverrides, {0: 4});
        expect(owner.recordLengthSnapshot!.defaultBars, 12);
        expect(owner.durableRecordLengthSnapshot.defaultBars, 6);
        expect(
          owner.recordLengthRevision(const RecordLengthAddress.track(0)),
          rev + 1,
        );
        expect((await hold()).isOk, isFalse);
        expect((await owner.setLooperMode(LooperMode.free)).isOk, isTrue);
        expect(engine.publishedLengths[0], 4);
        expect(engine.publishedLengths[1], 12);
      },
    );
    test(
      'refused Multi preserves Held membership priority and saved mode',
      () async {
        await start();
        await hold();
        engine.modeWithPresetsResult = EngineResult.invalid;
        expect((await owner.setLooperMode(LooperMode.multi)).isOk, isFalse);
        expect(owner.recordLengthSnapshot!.trackOverrides, {0: 16});
        expect(
          owner.recordLengthRevision(const RecordLengthAddress.track(0)),
          0,
        );
        expect(store.values['looper.mode'], LooperMode.free.code);
      },
    );
    test(
      'mutated scalar is exactly rolled back and failed rollback '
      'requires Retry',
      () async {
        await owner.load();
        store.values['tempo.length_preset.0'] = 0;
        store.failures = 2;
        expect((await hold()).status, RecordLengthStatus.recoveryRequired);
        expect((await hold()).isOk, isFalse);
        expect((await owner.owner.recover()).isOk, isTrue);
        expect(store.values['tempo.length_preset.0'], 0);
        expect((await hold()).isOk, isTrue);
      },
    );
    test('Save can project Released while capture keeps live Held', () async {
      await start();
      await hold();
      capture(TrackState.recording);
      expect(
        (await owner.setControllerRecordLength(
          const RecordLengthAddress.track(0),
          4,
          lifetime: owner.recordLengthLifetime,
          revision: 0,
        )).isOk,
        isFalse,
      );
      final saved = await owner.owner.runExclusive(
        () async => owner.durableRecordLengthSnapshot,
      );
      expect(saved.trackOverrides, {0: 4});
      expect(owner.recordLengthSnapshot!.trackOverrides, {0: 16});
      expect(repository.state.status.isConnected, isTrue);
      // The refused release owes nothing: the flush is clean.
      expect((await owner.owner.flush()).isOk, isTrue);
    });
    test('reconnect during initial reads resumes validated startup', () async {
      store.readGate = Completer<void>();
      store.values['looper.default_length_bars'] = 8;
      final loading = owner.load();
      repository
        ..startEngine(const EngineConfig())
        ..stopEngine()
        ..startEngine(const EngineConfig());
      store.readGate!.complete();
      await loading;
      expect(owner.recordLengthSnapshot!.defaultBars, 8);
    });
    test(
      'callback capture rejects same-vector membership without stopping',
      () async {
        await start();
        engine.captureAtEnqueue = true;
        final result = await owner.setTrackRecordLength(channel: 0, bars: 0);
        expect(result.status, RecordLengthStatus.rejected);
        expect(owner.recordLengthSnapshot!.trackOverrides, isEmpty);
        expect(store.values.containsKey('tempo.length_preset.0'), isFalse);
        expect(engine.stopCalls, 0);
      },
    );
    test(
      'late checkpoint read error cannot poison a reconnected owner',
      () async {
        await start();
        store.readGate = Completer<void>();
        final writing = hold();
        await Future<void>.delayed(Duration.zero);
        repository
          ..stopEngine()
          ..startEngine(const EngineConfig());
        await repository.settleLengthSettings();
        store.readFailure = true;
        store.readGate!.complete();
        expect((await writing).status, RecordLengthStatus.superseded);
        expect((await owner.owner.flush()).isOk, isTrue);
        expect(owner.recordLengthSnapshot!.trackOverrides, isEmpty);
      },
    );
    test(
      'a receipt timeout keeps the owed Released value and Retry lands it',
      () async {
        await start();
        engine.commandsAreSettled = false;
        expect((await hold()).status, RecordLengthStatus.recoveryRequired);
        expect(store.values['tempo.length_preset.0'], 4);
        // Owed, not blocking: storage holds the value the next start replays.
        final flushed = await owner.owner.flush();
        expect((flushed.isOk, flushed.deferred), (true, true));
        expect(owner.owner.ready, isFalse);
        expect(engine.stopCalls, 0);
        engine.commandsAreSettled = true;
        expect((await owner.owner.recover()).isOk, isTrue);
        expect(owner.recordLengthSnapshot!.trackOverrides, {0: 4});
      },
    );
    test(
      'pending admitted edit completes superseded when owner closes',
      () async {
        await owner.load();
        store.writeGate = Completer<void>();
        final write = hold();
        await Future<void>.delayed(Duration.zero);
        final closing = owner.close();
        store.writeGate!.complete();
        expect((await write).status, RecordLengthStatus.superseded);
        await closing;
        expect(store.values.containsKey('tempo.length_preset.0'), isFalse);
      },
    );
  });
}
