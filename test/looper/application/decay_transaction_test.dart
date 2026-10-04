import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/looper/application/playback_settings.dart';
import 'package:segno/looper/model/overdub_decay.dart';
import 'package:segno_engine/segno_engine.dart'
    show EngineSnapshot, TrackSnapshot;
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/fake_audio_engine.dart';
import '../../helpers/fake_key_value_store.dart';

class _Engine extends FakeAudioEngine {
  bool refuse = false;
  int writes = 0;
  double? lastOverdubFeedback;
  @override
  EngineResult setOverdubFeedback(double feedback) {
    writes++;
    if (!refuse) lastOverdubFeedback = feedback;
    return refuse ? EngineResult.notReady : super.setOverdubFeedback(feedback);
  }

  @override
  EngineResult setTrackOverdubFeedback({
    required int channel,
    required double? feedback,
  }) {
    writes++;
    return refuse
        ? EngineResult.notReady
        : super.setTrackOverdubFeedback(channel: channel, feedback: feedback);
  }
}

class _Store extends FakeKeyValueStore {
  Completer<void>? writeGate;
  Completer<void>? onceGate;
  Completer<void>? readGate;
  bool failDefaultRead = false;
  @override
  Future<int?> getInt(String key) async {
    if (key.contains('overdub_decay')) await readGate?.future;
    if (key == 'looper.overdub_decay' && failDefaultRead) {
      throw StateError('old startup read failed');
    }
    return super.getInt(key);
  }

  int failures = 0;
  int writes = 0;
  @override
  Future<void> setInt(String key, int value) async {
    if (key.contains('overdub_decay')) {
      writes++;
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

  @override
  Future<bool?> getBool(String key) async {
    if (key == 'looper.default_one_shot') await onceGate?.future;
    return super.getBool(key);
  }
}

void main() {
  group('PlaybackSettings decay transaction', () {
    late _Engine engine;
    late _Store store;
    late LooperRepository repository;
    late SettingsRepository settings;
    setUp(() {
      engine = _Engine()
        ..nextSnapshot = const EngineSnapshot.initial().copyWith(
          tracks: List.generate(8, (_) => const TrackSnapshot.empty()),
        );
      store = _Store();
      repository = LooperRepository(
        engine: engine,
        ticker: const Stream.empty(),
      );
      settings = SettingsRepository(store: store);
    });
    tearDown(() => repository.dispose());
    PlaybackSettings build() =>
        PlaybackSettings(repository: repository, settings: settings);

    test(
      'publishes accepted zero and all eight override memberships',
      () async {
        (() => store.values['track_overdub_decay.7'] = 0)();
        final owner = build();
        addTearDown(owner.close);
        await ((PlaybackSettings owner) async {
          expect(owner.decaySnapshot, isNull);
          await owner.load();
          expect(owner.state.decayReady, isTrue);
          expect(owner.decaySnapshot!.trackOverrides, {7: 0});
          expect((await owner.flushDecay()).isOk, isTrue);
        })(owner);
        await Future<void>.delayed(Duration.zero);
        await owner.close();
      },
    );

    for (final bad in <Object>[101, -1, 'broken']) {
      test(
        'rejects malformed $bad before any partial startup application',
        () async {
          (() => store.values.addAll({
            'looper.overdub_decay': 40,
            'track_overdub_decay.7': bad,
          }))();
          final owner = build();
          addTearDown(owner.close);
          await ((PlaybackSettings owner) async {
            await owner.load();
            expect(owner.decaySnapshot, isNull);
            expect(repository.defaultOverdubDecay, 0);
            expect(repository.trackOverdubDecayOverrides, isEmpty);
            expect((await owner.flushDecay()).isOk, isFalse);
            expect(store.values['track_overdub_decay.7'], bad);
            expect(engine.writes, 0);
          })(owner);
          await Future<void>.delayed(Duration.zero);
          await owner.close();
        },
      );
    }

    test(
      'Decay becomes ready while unrelated Once restoration remains pending',
      () async {
        final owner = build();
        addTearDown(owner.close);
        await ((PlaybackSettings owner) async {
          store.onceGate = Completer<void>();
          final loaded = owner.load();
          for (var i = 0; i < 30 && !owner.state.decayReady; i++) {
            await Future<void>.delayed(Duration.zero);
          }
          expect(owner.state.decayReady, isTrue);
          expect((await owner.flushDecay()).isOk, isTrue);
          store.onceGate!.complete();
          await loaded;
        })(owner);
        await Future<void>.delayed(Duration.zero);
        await owner.close();
      },
    );

    test('pending storage cannot publish held audio or acceptance', () async {
      final owner = build();
      addTearDown(owner.close);
      await ((PlaybackSettings owner) async {
        await owner.load();
        store.writeGate = Completer<void>();
        final pending = owner.setControllerDecay(
          const DecayAddress.track(0),
          75,
          lifetime: owner.decayLifetime,
          revision: 0,
          releasedPercent: 20,
        );
        await Future<void>.delayed(Duration.zero);
        expect(owner.decaySnapshot!.trackOverrides, isEmpty);
        expect(repository.trackOverdubDecayOverrides, isEmpty);
        store.writeGate!.complete();
        expect((await pending).isOk, isTrue);
        expect(owner.decaySnapshot!.trackOverrides, {0: 75});
        expect(owner.durableDecaySnapshot.trackOverrides, {0: 20});
        expect(store.values['track_overdub_decay.0'], 20);
      })(owner);
      await Future<void>.delayed(Duration.zero);
      await owner.close();
    });

    test(
      'superseded stored write cannot poison the replacement flush',
      () async {
        final owner = build();
        addTearDown(owner.close);
        await ((PlaybackSettings owner) async {
          await owner.load();
          store.writeGate = Completer<void>();
          final pending = owner.setOverdubDecay(75);
          await Future<void>.delayed(Duration.zero);
          repository
            ..setOverdubDecay(60)
            ..startEngine(const EngineConfig());
          await Future<void>.delayed(Duration.zero);
          store.writeGate!.complete();
          expect((await pending).status, DecayStatus.superseded);
          expect(owner.decaySnapshot!.defaultPercent, 60);
          expect(owner.durableDecaySnapshot.defaultPercent, 60);
          expect(store.values.containsKey('looper.overdub_decay'), isFalse);
          expect((await owner.flushDecay()).isOk, isTrue);
        })(owner);
        await Future<void>.delayed(Duration.zero);
        await owner.close();
      },
    );

    test(
      'obsolete startup read failure cannot poison the replacement flush',
      () async {
        final owner = build();
        addTearDown(owner.close);
        await ((PlaybackSettings owner) async {
          store
            ..readGate = Completer<void>()
            ..failDefaultRead = true;
          final pending = owner.load();
          await Future<void>.delayed(Duration.zero);
          repository
            ..setOverdubDecay(60)
            ..startEngine(const EngineConfig());
          await Future<void>.delayed(Duration.zero);
          store.readGate!.complete();
          await pending;
          expect(owner.decaySnapshot!.defaultPercent, 60);
          expect(owner.durableDecaySnapshot.defaultPercent, 60);
          expect((await owner.flushDecay()).isOk, isTrue);
        })(owner);
        await Future<void>.delayed(Duration.zero);
        await owner.close();
      },
    );

    test(
      'explicit zero remains Custom and Use default supersedes an old revision',
      () async {
        final owner = build();
        addTearDown(owner.close);
        await ((PlaybackSettings owner) async {
          await owner.load();
          expect((await owner.setOverdubDecay(40)).isOk, isTrue);
          expect(
            (await owner.setTrackOverdubDecay(channel: 0, percent: 0)).isOk,
            isTrue,
          );
          expect((await owner.setOverdubDecay(80)).isOk, isTrue);
          expect(
            owner.decaySnapshot!.effectivePercent(const DecayAddress.track(0)),
            0,
          );
          final oldRevision = owner.decayRevision(const DecayAddress.track(0));
          expect(
            (await owner.setTrackOverdubDecay(channel: 0, percent: null)).isOk,
            isTrue,
          );
          final writes = store.writes;
          final old = await owner.setControllerDecay(
            const DecayAddress.track(0),
            0,
            lifetime: owner.decayLifetime,
            revision: oldRevision,
          );
          expect(old.status, DecayStatus.superseded);
          expect(store.writes, writes);
          expect(owner.durableDecaySnapshot.trackOverrides, isEmpty);
          expect(store.values.containsKey('track_overdub_decay.0'), isFalse);
          expect(
            owner.decaySnapshot!.effectivePercent(const DecayAddress.track(0)),
            80,
          );
        })(owner);
        await Future<void>.delayed(Duration.zero);
        await owner.close();
      },
    );

    test(
      'failed compensation blocks mutation and capture until explicit recovery',
      () async {
        (() => store.values['looper.overdub_decay'] = 40)();
        final owner = build();
        addTearDown(owner.close);
        await ((PlaybackSettings owner) async {
          await owner.load();
          store.failures = 2;
          expect(
            (await owner.setOverdubDecay(75)).status,
            DecayStatus.recoveryRequired,
          );
          final writes = store.writes;
          expect(
            (await owner.setOverdubDecay(60)).status,
            DecayStatus.recoveryRequired,
          );
          expect(store.writes, writes);
          expect(owner.decaySnapshot!.defaultPercent, 40);
          await expectLater(
            owner.runPlaybackExclusive(() async {}),
            throwsStateError,
          );
          expect((await owner.recoverDecay()).isOk, isTrue);
          expect(store.values['looper.overdub_decay'], 40);
          expect((await owner.setOverdubDecay(60)).isOk, isTrue);
        })(owner);
        await Future<void>.delayed(Duration.zero);
        await owner.close();
      },
    );

    test(
      'atomic native refusal restores absent storage and older restart intent',
      () async {
        final owner = build();
        addTearDown(owner.close);
        await ((PlaybackSettings owner) async {
          repository.startEngine(const EngineConfig());
          await owner.load();
          engine.refuse = true;
          final result = await owner.setControllerDecay(
            const DecayAddress.track(0),
            75,
            lifetime: owner.decayLifetime,
            revision: 0,
            releasedPercent: 0,
          );
          expect(result.isOk, isFalse);
          expect(store.values.containsKey('track_overdub_decay.0'), isFalse);
          expect(owner.decaySnapshot!.trackOverrides, isEmpty);
          expect(owner.durableDecaySnapshot.trackOverrides, isEmpty);
          engine.refuse = false;
        })(owner);
        await Future<void>.delayed(Duration.zero);
        await owner.close();
      },
    );

    test(
      'failed restart recovery preserves recalled intent until normal start',
      () async {
        final owner = build();
        addTearDown(owner.close);
        await ((PlaybackSettings owner) async {
          await owner.load();
          repository.setOverdubDecay(60);
          engine.refuse = true;
          expect(repository.startEngine(const EngineConfig()).isOk, isFalse);
          await Future<void>.delayed(Duration.zero);
          expect(owner.decaySnapshot, isNull);
          expect((await owner.recoverDecay()).isOk, isFalse);
          expect(owner.durableDecaySnapshot.defaultPercent, 60);
          expect(owner.decaySnapshot, isNull);
          engine.refuse = false;
          expect(repository.startEngine(const EngineConfig()).isOk, isTrue);
          await Future<void>.delayed(Duration.zero);
          expect(owner.decaySnapshot!.defaultPercent, 60);
          expect((await owner.flushDecay()).isOk, isTrue);
        })(owner);
        await Future<void>.delayed(Duration.zero);
        await owner.close();
      },
    );

    test('restart replays Released default and explicit track zero, '
        'never held high', () async {
      final owner = build();
      addTearDown(owner.close);
      await ((PlaybackSettings owner) async {
        repository.startEngine(const EngineConfig());
        await owner.load();
        await owner.setControllerDecay(
          const DecayAddress.defaults(),
          80,
          lifetime: owner.decayLifetime,
          revision: 0,
          releasedPercent: 20,
        );
        await owner.setControllerDecay(
          const DecayAddress.track(0),
          75,
          lifetime: owner.decayLifetime,
          revision: 0,
          releasedPercent: 0,
        );
        repository.stopEngine();
        expect(repository.startEngine(const EngineConfig()), EngineResult.ok);
        expect(repository.defaultOverdubDecay, 20);
        expect(repository.trackOverdubDecayOverrides, {0: 0});
        expect(engine.lastOverdubFeedback, .8);
        expect(engine.trackOverdubFeedback[0], 1);
      })(owner);
      await Future<void>.delayed(Duration.zero);
      await owner.close();
    });
  });
}
