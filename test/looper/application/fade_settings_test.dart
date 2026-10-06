import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/looper/application/fade_settings.dart';
import 'package:segno/looper/model/owned_setting.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/fake_audio_engine.dart';
import '../../helpers/fake_key_value_store.dart';

class _Store extends FakeKeyValueStore {
  bool throwAfterWrite = false;
  bool discardWrite = false;
  bool refuseRepair = false;
  bool refuseRead = false;
  Completer<void>? gate;
  final entered = Completer<void>();

  @override
  Future<String?> getString(String key) async {
    if (refuseRead) throw StateError('read refused');
    return super.getString(key);
  }

  @override
  Future<void> setString(String key, String value) async {
    if (refuseRepair && !throwAfterWrite) throw StateError('repair refused');
    if (!entered.isCompleted) entered.complete();
    await gate?.future;
    if (discardWrite) {
      discardWrite = false;
      return;
    }
    await super.setString(key, value);
    if (throwAfterWrite) {
      throwAfterWrite = false;
      throw StateError('wrote before reporting failure');
    }
  }

  @override
  Future<void> remove(String key) async {
    if (refuseRepair) throw StateError('remove refused');
    await super.remove(key);
  }
}

void main() {
  group(FadeSettings, () {
    late _Store store;
    late FadeSettings owner;
    late LooperRepository repository;
    late bool blocked;
    const key = 'looper.fade_durations';
    setUp(() async {
      store = _Store();
      blocked = false;
      repository = LooperRepository(
        engine: FakeAudioEngine(),
        ticker: const Stream.empty(),
      );
      owner = FadeSettings(
        repository: repository,
        settings: SettingsRepository(store: store),
        blocked: () => blocked,
        sessionBlocked: () => blocked,
      );
      await owner.load();
    });
    tearDown(() async {
      store
        ..refuseRead = false
        ..refuseRepair = false;
      blocked = false;
      await owner.recover();
      await owner.close();
      await repository.dispose();
    });

    test(
      'keeps equal Custom through Default edits and explicit reset',
      () async {
        await owner.setOverride(0, 4000);
        await owner.setDefault(8000);
        expect(owner.confirmed.effectiveMs(0), 4000);
        expect(owner.confirmed.effectiveMs(1), 8000);
        await owner.setOverride(0, null);
        await owner.setOverride(7, 30000);
        await owner.setDefault(4000);
        expect(owner.confirmed, FadeDurations(overrides: const {7: 30000}));
        expect(
          FadeDurations.fromJson(jsonDecode(store.values[key]! as String)),
          owner.confirmed,
        );
        await expectLater(owner.setDefault(501), throwsFormatException);
        await expectLater(owner.setOverride(8, null), throwsFormatException);
        expect(owner.confirmed.defaultMs, 4000);
      },
    );

    for (final old in [null, '{ "overrides": {"0":4000}, "defaultMs":4000 }']) {
      for (final discard in [false, true]) {
        test(
          'restores exact $old after '
          '${discard ? 'mismatch' : 'write then throw'}',
          () async {
            if (old != null) store.values[key] = old;
            store
              ..throwAfterWrite = !discard
              ..discardWrite = discard;
            await expectLater(owner.setDefault(8000), throwsStateError);
            expect(store.values[key], old);
            expect(owner.confirmed.defaultMs, 4000);
            expect(owner.needsRecovery, isFalse);
            await owner.setDefault(6000);
            expect(owner.confirmed.defaultMs, 6000);
          },
        );
      }
    }

    test(
      'retains an owed removal and explicitly repairs before another edit',
      () async {
        store
          ..throwAfterWrite = true
          ..refuseRepair = true;
        await expectLater(owner.setDefault(8000), throwsStateError);
        expect(owner.needsRecovery, isTrue);
        await expectLater(owner.setDefault(9000), throwsStateError);
        expect((await owner.owner.flush()).isOk, isFalse);
        expect(await owner.recover(), isFalse);
        store.refuseRepair = false;
        expect(await owner.recover(), isTrue);
        expect(store.values.containsKey(key), isFalse);
        expect(owner.confirmed.defaultMs, 4000);
      },
    );

    test(
      'Session capture waits for admitted edits; a later edit applies after it',
      () async {
        store.gate = Completer<void>();
        final first = owner.setDefault(6000);
        await store.entered.future;
        final second = owner.setOverride(0, 6000);
        FadeDurations? captured;
        Future<void>? later;
        final capture = owner.owner.runExclusive(() async {
          captured = owner.confirmed;
          // Queued behind the Session operation, not refused by it.
          later = owner.setDefault(8000);
          await pumpEventQueue();
          expect(owner.confirmed.defaultMs, 6000);
        });
        store.gate!.complete();
        await Future.wait([first, second, capture]);
        await later;
        expect(
          captured,
          FadeDurations(defaultMs: 6000, overrides: const {0: 6000}),
        );
        expect(owner.confirmed.defaultMs, 8000);
      },
    );

    test('a Session install outside Session exclusion is refused', () async {
      await expectLater(
        owner.installSession(FadeDurations(defaultMs: 12000)),
        throwsStateError,
      );
      expect(owner.confirmed, FadeDurations.defaults);
      expect(store.values.containsKey(key), isFalse);
    });

    test(
      'accepted Session completes incoming vector after ordinary repair debt',
      () async {
        store
          ..throwAfterWrite = true
          ..refuseRepair = true;
        await expectLater(owner.setDefault(8000), throwsStateError);
        blocked = true;
        expect(await owner.recover(), isFalse);
        store.refuseRepair = false;
        await owner.owner.runExclusive(
          () => owner.installSession(FadeDurations(defaultMs: 12000)),
        );
        expect(owner.needsRecovery, isFalse);
        expect(owner.confirmed.defaultMs, 12000);
        expect(owner.confirmed.overrides, isEmpty);
      },
    );

    test(
      'a refused Session scope cannot detach a prior write from close',
      () async {
        store.gate = Completer<void>();
        Object? writeError;
        final write = owner.setDefault(6000).catchError((Object error) {
          writeError = error;
        });
        await store.entered.future;
        final refusal = owner.owner.runExclusive<void>(() async {
          throw StateError('other owner recovery');
        });
        final refused = expectLater(refusal, throwsStateError);
        var closed = false;
        final closing = owner.close().then((_) => closed = true);
        await pumpEventQueue();
        final closedBeforeWrite = closed;
        store.gate!.complete();
        await Future.wait([write, refused, closing]);
        expect(closedBeforeWrite, isFalse);
        expect(writeError, isNull);
        // Close superseded the write it waited for; storage was restored.
        expect(owner.confirmed.defaultMs, 4000);
        expect(store.values.containsKey(key), isFalse);
      },
    );

    test(
      'throwing scope releases exclusion; repeated scopes drain before close',
      () async {
        await expectLater(
          owner.owner.runExclusive<void>(
            () => throw StateError('scope refused'),
          ),
          throwsStateError,
        );
        await owner.setDefault(6000);
        final release = Completer<void>();
        final order = <int>[];
        final first = owner.owner.runExclusive(() async {
          order.add(1);
          await release.future;
        });
        final second = owner.owner.runExclusive(() async {
          order.add(2);
        });
        var closed = false;
        final closing = owner.close().then((_) => closed = true);
        await pumpEventQueue();
        expect(order, [1]);
        expect(closed, isFalse);
        release.complete();
        await Future.wait([first, second, closing]);
        expect(order, [1, 2]);
        expect(closed, isTrue);
      },
    );

    test(
      'close supersedes the admitted write, restores storage and rejects '
      'new work',
      () async {
        store.gate = Completer<void>();
        final write = owner.setDefault(6000);
        await store.entered.future;
        final closing = owner.close();
        await expectLater(owner.setDefault(8000), throwsStateError);
        store.gate!.complete();
        await Future.wait([write, closing]);
        // As every owner: a write still in flight at close is superseded and
        // its storage rolled back, so nothing half-applied stays behind.
        expect(owner.confirmed.defaultMs, 4000);
        expect(store.values.containsKey(key), isFalse);
      },
    );

    test(
      'startup queued during a canceled Session still restores local setup',
      () async {
        await owner.close();
        store.values[key] = '{"defaultMs":8000,"overrides":{}}';
        owner = FadeSettings(
          repository: repository,
          settings: SettingsRepository(store: store),
          blocked: () => false,
          sessionBlocked: () => false,
        );
        final release = Completer<void>();
        final scope = owner.owner.runExclusive(() => release.future);
        final loaded = owner.load();
        release.complete();
        await Future.wait([scope, loaded]);
        expect(owner.confirmed.defaultMs, 8000);
      },
    );

    group('controller writes', () {
      FadeDurations stored() =>
          FadeDurations.fromJson(jsonDecode(store.values[key]! as String));
      Future<bool> write(
        int? channel,
        int milliseconds, {
        int? released,
        SettingLifetime? lifetime,
        int? revision,
      }) => owner.setControllerDuration(
        channel,
        milliseconds,
        lifetime: lifetime ?? owner.lifetime,
        revision: revision ?? owner.revision(channel),
        releasedMilliseconds: released,
      );

      test('a held value is live while only Released is stored', () async {
        expect(await write(null, 10000, released: 6000), isTrue);
        expect(owner.live.defaultMs, 10000);
        expect(owner.confirmed.defaultMs, 6000);
        expect(stored().defaultMs, 6000);
        // The Released write makes live and durable agree again.
        expect(await write(null, 6000), isTrue);
        expect(owner.live, owner.confirmed);
        // A value without an authored Released is itself durable.
        expect(await write(null, 2500), isTrue);
        expect((owner.live.defaultMs, stored().defaultMs), (2500, 2500));
      });

      test('writing an inherited track creates its override', () async {
        await owner.setDefault(8000);
        expect(owner.confirmed.overrides, isEmpty);
        expect(await write(2, 12000, released: 8000), isTrue);
        expect(owner.live.overrides, {2: 12000});
        expect(owner.live.effectiveMs(3), 8000);
        // Released equal to Default is still Custom, not inheritance.
        expect(stored().overrides, {2: 8000});
      });

      test('the next gesture steps from the live held value', () async {
        expect(await write(1, 10000, released: 4000), isTrue);
        await owner.step(deltaMs: 500, channel: 1);
        expect(owner.live.overrides, {1: 10500});
        expect(stored().overrides, {1: 10500});
      });

      test(
        'an ordinary edit supersedes older intent at its address only',
        () async {
          final changes = <({int? channel, int? milliseconds})>[];
          final sub = owner.ordinaryChanges.listen(changes.add);
          final defaultRevision = owner.revision(null);
          final trackRevision = owner.revision(0);
          expect(await write(null, 10000, released: 4000), isTrue);
          // Equal to the stored value, but it replaces the held live value.
          await owner.setDefault(4000);
          expect(owner.live.defaultMs, 4000);
          expect(changes, [(channel: null, milliseconds: 4000)]);
          expect(owner.revision(null), defaultRevision + 1);
          expect(owner.revision(0), trackRevision);
          expect(
            await write(null, 20000, revision: defaultRevision),
            isFalse,
          );
          expect(owner.live.defaultMs, 4000);
          expect(await write(0, 20000, revision: trackRevision), isTrue);
          await owner.setOverride(0, null);
          expect(changes.last, (channel: 0, milliseconds: null));
          expect(owner.live.overrides, isEmpty);
          expect(stored().overrides, isEmpty);
          await sub.cancel();
        },
      );

      test(
        'a Session load supersedes queued intent; its install replaces the '
        'held value',
        () async {
          final lifetime = owner.lifetime;
          expect(await write(null, 10000, released: 6000), isTrue);
          late Future<bool> queued;
          await owner.owner.runExclusive(() async {
            // Queued behind the Session operation, not refused by it.
            queued = write(null, 20000, lifetime: lifetime);
            await repository.applySession(
              const SessionRig(),
              clearPollInterval: Duration.zero,
            );
            await owner.installSession(FadeDurations(defaultMs: 12000));
          });
          expect(await queued, isFalse);
          expect(owner.lifetime, isNot(lifetime));
          expect(owner.live, owner.confirmed);
          expect(owner.live.defaultMs, 12000);
          expect(
            FadeDurations.fromJson(jsonDecode(store.values[key]! as String)),
            FadeDurations(defaultMs: 12000),
          );
        },
      );

      test(
        'a Session save stores Released and applies queued work after',
        () async {
          expect(await write(null, 10000, released: 6000), isTrue);
          FadeDurations? captured;
          late Future<bool> release;
          await owner.owner.runExclusive(() async {
            release = write(null, 6000);
            captured = owner.confirmed;
          });
          expect(captured!.defaultMs, 6000);
          expect(await release, isTrue);
          expect(owner.live.defaultMs, 6000);
        },
      );

      test(
        'refuses out of range; a write before load starts the load',
        () async {
          await owner.close();
          owner = FadeSettings(
            repository: repository,
            settings: SettingsRepository(store: store),
            blocked: () => false,
            sessionBlocked: () => false,
          );
          expect(await write(null, 30500), isFalse);
          expect(await write(8, 8000), isFalse);
          expect(store.values.containsKey(key), isFalse);
          expect(owner.live, FadeDurations.defaults);
          expect(await write(null, 8000), isTrue);
          expect(owner.needsRecovery, isFalse);
          expect(owner.live.defaultMs, 8000);
        },
      );
    });

    test(
      'malformed startup never defaults silently; explicit Retry repairs it',
      () async {
        await owner.close();
        store.values[key] = '{"defaultMs":500.5,"overrides":{}}';
        owner = FadeSettings(
          repository: repository,
          settings: SettingsRepository(store: store),
          blocked: () => false,
          sessionBlocked: () => false,
        );
        await owner.load();
        expect(owner.needsRecovery, isTrue);
        expect(store.values[key], '{"defaultMs":500.5,"overrides":{}}');
        expect(await owner.recover(), isTrue);
        expect(owner.needsRecovery, isFalse);
        expect(owner.confirmed, FadeDurations.defaults);
        expect(
          FadeDurations.fromJson(jsonDecode(store.values[key]! as String)),
          FadeDurations.defaults,
        );
      },
    );
  });
}
