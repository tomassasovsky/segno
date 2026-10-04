import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/looper/application/playback_settings.dart';
import 'package:segno/looper/model/one_shot.dart';
import 'package:segno_engine/segno_engine.dart'
    show EngineSnapshot, TrackSnapshot;
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/fake_audio_engine.dart';
import '../../helpers/fake_key_value_store.dart';

class _Engine extends FakeAudioEngine {
  bool wrongBits = false;
  void Function()? beforeStalledOnce;
  @override
  EngineResult setOneShotMask({required int channels, required bool oneShot}) {
    final beforeStall = beforeStalledOnce;
    beforeStall?.call();
    final result = wrongBits
        ? EngineResult.ok
        : super.setOneShotMask(channels: channels, oneShot: oneShot);
    if (beforeStall != null) commandsAreSettled = false;
    return result;
  }
}

class _Store extends FakeKeyValueStore {
  Completer<void>? readGate;
  Completer<void>? writeGate;
  bool writeEntered = false;
  int failures = 0;
  bool failRead = false;
  @override
  Future<bool?> getBool(String key) async {
    if (key.contains('one_shot')) {
      await readGate?.future;
      if (failRead) throw StateError('read refused');
    }
    return super.getBool(key);
  }

  @override
  Future<void> setBool(String key, {required bool value}) async {
    if (key.contains('one_shot')) {
      writeEntered = true;
      await writeGate?.future;
      await super.setBool(key, value: value);
      if (failures > 0) {
        failures--;
        throw StateError('mutated then refused');
      }
    } else {
      await super.setBool(key, value: value);
    }
  }
}

void main() {
  group('PlaybackSettings Once transaction', () {
    late _Engine engine;
    late LooperRepository repository;
    late _Store store;
    late SettingsRepository settings;
    setUp(() {
      engine = _Engine()
        ..nextSnapshot = const EngineSnapshot.initial().copyWith(
          tracks: List.generate(8, (_) => const TrackSnapshot.empty()),
        );
      repository = LooperRepository(
        engine: engine,
        ticker: const Stream.empty(),
      );
      store = _Store();
      settings = SettingsRepository(store: store);
    });
    tearDown(() => repository.dispose());
    PlaybackSettings build() =>
        PlaybackSettings(repository: repository, settings: settings);

    test(
      'blocked Once reads do not publish provisional false during Decay init',
      () async {
        final owner = build();
        addTearDown(owner.close);
        await ((PlaybackSettings owner) async {
          store.readGate = Completer<void>();
          final loading = owner.load();
          await Future<void>.delayed(Duration.zero);
          expect(owner.decaySnapshot, isNotNull);
          expect(owner.oneShotSnapshot, isNull);
          repository.setOverdubDecay(20);
          expect(owner.oneShotSnapshot, isNull);
          store.readGate!.complete();
          await loading;
          expect(owner.oneShotSnapshot!.defaultOneShot, isFalse);
          expect(owner.state.oneShotReady, isTrue);
        })(owner);
        await Future<void>.delayed(Duration.zero);
        await owner.close();
      },
    );
    test(
      'malformed last slot refuses all Once restore while Decay stays ready',
      () async {
        final owner = build();
        addTearDown(owner.close);
        await ((PlaybackSettings owner) async {
          store.values.addAll({
            'looper.default_one_shot': true,
            'track_one_shot.7': 'broken',
          });
          await owner.load();
          repository.setOverdubDecay(20);
          expect(owner.oneShotSnapshot, isNull);
          expect(repository.defaultOneShot, isFalse);
          expect(owner.decaySnapshot, isNotNull);
          expect(store.values['track_one_shot.7'], 'broken');
        })(owner);
        await Future<void>.delayed(Duration.zero);
        await owner.close();
      },
    );
    test(
      'native enqueue and storage do not confirm while callback is withheld',
      () async {
        final owner = build();
        addTearDown(owner.close);
        await ((PlaybackSettings owner) async {
          expect(repository.startEngine(const EngineConfig()).isOk, isTrue);
          await owner.load();
          engine.commandsAreSettled = false;
          var complete = false;
          final write = owner.setDefaultOneShot(value: true).then((value) {
            complete = true;
            return value;
          });
          await Future<void>.delayed(const Duration(milliseconds: 20));
          expect(store.values['looper.default_one_shot'], isTrue);
          expect(complete, isFalse);
          expect(owner.oneShotSnapshot!.defaultOneShot, isFalse);
          engine.commandsAreSettled = true;
          expect((await write).isOk, isTrue);
          expect(owner.oneShotSnapshot!.defaultOneShot, isTrue);
        })(owner);
        await Future<void>.delayed(Duration.zero);
        await owner.close();
      },
    );
    test('explicit false and inherited membership remain separate', () async {
      final owner = build();
      addTearDown(owner.close);
      await ((PlaybackSettings owner) async {
        await owner.load();
        await owner.setTrackOneShot(channel: 0, oneShot: false);
        await owner.setDefaultOneShot(value: true);
        expect(owner.oneShotSnapshot!.trackOverrides, {0: false});
        final revision = owner.oneShotRevision(const OneShotAddress.track(0));
        await owner.setTrackOneShot(channel: 0, oneShot: null);
        expect(owner.oneShotSnapshot!.trackOverrides, isEmpty);
        expect(store.values.containsKey('track_one_shot.0'), isFalse);
        expect(
          (await owner.setControllerOneShot(
            const OneShotAddress.track(0),
            oneShot: false,
            lifetime: owner.oneShotLifetime,
            revision: revision,
          )).status,
          OneShotStatus.superseded,
        );
      })(owner);
      await Future<void>.delayed(Duration.zero);
      await owner.close();
    });
    test('held choices keep authored Released in restart projection', () async {
      final owner = build();
      addTearDown(owner.close);
      await ((PlaybackSettings owner) async {
        await owner.load();
        await owner.setControllerOneShot(
          const OneShotAddress.defaults(),
          oneShot: true,
          lifetime: owner.oneShotLifetime,
          revision: 0,
          releasedOneShot: false,
        );
        await owner.setControllerOneShot(
          const OneShotAddress.track(0),
          oneShot: false,
          lifetime: owner.oneShotLifetime,
          revision: 0,
          releasedOneShot: true,
        );
        expect(owner.oneShotSnapshot!.defaultOneShot, isTrue);
        expect(owner.oneShotSnapshot!.trackOverrides, {0: false});
        expect(owner.durableOneShotSnapshot.defaultOneShot, isFalse);
        expect(owner.durableOneShotSnapshot.trackOverrides, {0: true});
        expect(repository.startEngine(const EngineConfig()).isOk, isTrue);
        await repository.settleOneShot();
        expect(repository.defaultOneShot, isFalse);
        expect(repository.trackOneShotOverrides, {0: true});
      })(owner);
      await Future<void>.delayed(Duration.zero);
      await owner.close();
    });
    test(
      'shared queue orders Decay behind a pending Once write without deadlock',
      () async {
        final owner = build();
        addTearDown(owner.close);
        await ((PlaybackSettings owner) async {
          await owner.load();
          store.writeGate = Completer<void>();
          final once = owner.setDefaultOneShot(value: true);
          await Future<void>.delayed(Duration.zero);
          final decay = owner.setOverdubDecay(50);
          var captured = false;
          final capture = owner.runPlaybackExclusive(() async {
            captured = true;
          });
          await Future<void>.delayed(Duration.zero);
          expect(captured, isFalse);
          expect(owner.state.overdubDecay, 0);
          store.writeGate!.complete();
          expect((await once).isOk, isTrue);
          expect((await decay).isOk, isTrue);
          await capture;
          expect(captured, isTrue);
        })(owner);
        await Future<void>.delayed(Duration.zero);
        await owner.close();
      },
    );
    test(
      'wrong callback bits stop uncertain audio and require explicit recovery',
      () async {
        final owner = build();
        addTearDown(owner.close);
        await ((PlaybackSettings owner) async {
          repository.startEngine(const EngineConfig());
          await owner.load();
          engine.wrongBits = true;
          final result = await owner.setDefaultOneShot(value: true);
          expect(result.status, OneShotStatus.recoveryRequired);
          expect(repository.oneShotRecoveryRequired, isTrue);
          expect(owner.oneShotSnapshot!.defaultOneShot, isFalse);
          expect(store.values.containsKey('looper.default_one_shot'), isFalse);
          expect((await owner.setDefaultOneShot(value: true)).isOk, isFalse);
          expect(
            repository.startEngine(const EngineConfig()),
            EngineResult.notReady,
          );
          expect((await owner.recoverOneShot()).isOk, isTrue);
          engine.wrongBits = false;
          expect(repository.startEngine(const EngineConfig()).isOk, isTrue);
          await repository.settleOneShot();
          expect((await owner.setDefaultOneShot(value: true)).isOk, isTrue);
        })(owner);
        await Future<void>.delayed(Duration.zero);
        await owner.close();
      },
    );
    test(
      'autonomous reconnect times out without another owner write or flush',
      () async {
        final owner = build();
        addTearDown(owner.close);
        await ((PlaybackSettings owner) async {
          await owner.load();
          // Let the earlier healthy Length replay reach its receipt before
          // stalling only the subsequent Once command. A globally stalled
          // startup would time out Length first and cancel the Once request.
          late Future<EngineResult> lengthReceipt;
          engine.beforeStalledOnce = () {
            lengthReceipt = repository.settleLengthSettings();
            expect(repository.lengthSettingsSettled, isTrue);
            expect(repository.lengthRecoveryRequired, isFalse);
          };
          final failure = owner.oneShotFailures.first;
          repository.startEngine(const EngineConfig());
          expect(await lengthReceipt, EngineResult.ok);
          expect(
            (await failure.timeout(const Duration(seconds: 5))).status,
            OneShotStatus.recoveryRequired,
          );
          expect(repository.oneShotRecoveryRequired, isTrue);
          expect(engine.stopCalls, greaterThan(0));
          expect((await owner.flushOneShot()).isOk, isFalse);
          expect((await owner.recoverOneShot()).isOk, isTrue);
          engine
            ..beforeStalledOnce = null
            ..commandsAreSettled = true;
          expect(repository.startEngine(const EngineConfig()).isOk, isTrue);
          await repository.settleOneShot();
          expect((await owner.flushOneShot()).isOk, isTrue);
        })(owner);
        await Future<void>.delayed(Duration.zero);
        await owner.close();
      },
    );
    test(
      'failed exact compensation blocks both session gate and new choice',
      () async {
        final owner = build();
        addTearDown(owner.close);
        await ((PlaybackSettings owner) async {
          store.values['looper.default_one_shot'] = false;
          await owner.load();
          store.failures = 2;
          expect(
            (await owner.setDefaultOneShot(value: true)).status,
            OneShotStatus.recoveryRequired,
          );
          expect(
            (await owner.setTrackOneShot(channel: 0, oneShot: true)).isOk,
            isFalse,
          );
          await expectLater(
            owner.runPlaybackExclusive(() async {}),
            throwsStateError,
          );
          expect((await owner.recoverOneShot()).isOk, isTrue);
          expect(store.values['looper.default_one_shot'], false);
          expect((await owner.setDefaultOneShot(value: true)).isOk, isTrue);
        })(owner);
        await Future<void>.delayed(Duration.zero);
        await owner.close();
      },
    );
    test(
      'obsolete failed storage read does not poison the replacement owner',
      () async {
        final owner = build();
        addTearDown(owner.close);
        await ((PlaybackSettings owner) async {
          await owner.load();
          store.readGate = Completer<void>();
          final edit = owner.setDefaultOneShot(value: true);
          await Future<void>.delayed(Duration.zero);
          repository
            ..stopEngine()
            ..setOneShotSnapshot(
              defaultOneShot: true,
              trackOverrides: {0: false},
            );
          store.failRead = true;
          store.readGate!.complete();
          expect((await edit).status, OneShotStatus.superseded);
          store.failRead = false;
          expect((await owner.flushOneShot()).isOk, isTrue);
          expect(owner.oneShotSnapshot!.defaultOneShot, isTrue);
          expect(owner.oneShotSnapshot!.trackOverrides, {0: false});
        })(owner);
        await Future<void>.delayed(Duration.zero);
        await owner.close();
      },
    );
    test(
      'close awaits admitted storage and restores without late publication',
      () async {
        final owner = build();
        addTearDown(owner.close);
        await ((PlaybackSettings owner) async {
          await owner.load();
          store.writeGate = Completer<void>();
          final edit = owner.setDefaultOneShot(value: true);
          await Future<void>.delayed(Duration.zero);
          expect(store.writeEntered, isTrue);
          var closed = false;
          final closing = owner.close().then((_) => closed = true);
          await Future<void>.delayed(Duration.zero);
          expect(closed, isFalse);
          store.writeGate!.complete();
          expect((await edit).status, OneShotStatus.superseded);
          await closing;
          expect(await owner.stream.isEmpty, isTrue);
          expect(store.values.containsKey('looper.default_one_shot'), isFalse);
          expect(repository.defaultOneShot, isFalse);
        })(owner);
        await Future<void>.delayed(Duration.zero);
        await owner.close();
      },
    );
    test(
      'reconnect during initial reads still initializes accepted Once',
      () async {
        final owner = build();
        addTearDown(owner.close);
        await ((PlaybackSettings owner) async {
          store.values['looper.default_one_shot'] = true;
          store.readGate = Completer<void>();
          final loading = owner.load();
          await Future<void>.delayed(Duration.zero);
          repository
            ..stopEngine()
            ..startEngine(const EngineConfig());
          store.readGate!.complete();
          await loading;
          expect(owner.oneShotSnapshot, isNotNull);
          expect(owner.oneShotSnapshot!.defaultOneShot, isTrue);
          expect(engine.trackOneShot.values, everyElement(isTrue));
        })(owner);
        await Future<void>.delayed(Duration.zero);
        await owner.close();
      },
    );
    test(
      'session replacing initial reads keeps its authoritative Once vector',
      () async {
        final owner = build();
        addTearDown(owner.close);
        await ((PlaybackSettings owner) async {
          store.values['looper.default_one_shot'] = true;
          store.readGate = Completer<void>();
          final loading = owner.load();
          await Future<void>.delayed(Duration.zero);
          await repository.applySession(
            const SessionRig(trackOneShotOverrides: {7: true}),
          );
          store.readGate!.complete();
          await loading;
          expect(owner.oneShotSnapshot!.defaultOneShot, isFalse);
          expect(owner.oneShotSnapshot!.trackOverrides, {7: true});
          expect(store.values['looper.default_one_shot'], isTrue);
        })(owner);
        await Future<void>.delayed(Duration.zero);
        await owner.close();
      },
    );
    test('native recovery cannot bypass malformed startup storage', () async {
      final owner = build();
      addTearDown(owner.close);
      await ((PlaybackSettings owner) async {
        store.values['track_one_shot.7'] = 'broken';
        await owner.load();
        expect(owner.oneShotSnapshot, isNull);
        repository.setOneShotSnapshot(
          defaultOneShot: true,
          trackOverrides: {},
        );
        engine.wrongBits = true;
        repository.startEngine(const EngineConfig());
        expect((await repository.settleOneShot()).isOk, isFalse);
        expect(repository.oneShotRecoveryRequired, isTrue);
        expect((await owner.recoverOneShot()).isOk, isFalse);
        expect(owner.oneShotSnapshot, isNull);
        expect(store.values['track_one_shot.7'], 'broken');
        store.values['track_one_shot.7'] = false;
        engine.wrongBits = false;
        expect((await owner.recoverOneShot()).isOk, isTrue);
        expect(owner.oneShotSnapshot!.trackOverrides, {7: false});
      })(owner);
      await Future<void>.delayed(Duration.zero);
      await owner.close();
    });
    test(
      'explicit retry initializes after external repair of malformed storage',
      () async {
        final owner = build();
        addTearDown(owner.close);
        await ((PlaybackSettings owner) async {
          store.values['track_one_shot.7'] = 'broken';
          await owner.load();
          expect(owner.oneShotSnapshot, isNull);
          store.values.remove('track_one_shot.7');
          expect((await owner.recoverOneShot()).isOk, isTrue);
          expect(owner.oneShotSnapshot!.defaultOneShot, false);
        })(owner);
        await Future<void>.delayed(Duration.zero);
        await owner.close();
      },
    );
  });
}
