import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:segno/looper/application/fade_settings.dart';
import 'package:settings_repository/settings_repository.dart';

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
    late bool blocked;
    const key = 'looper.fade_durations';
    setUp(() async {
      store = _Store();
      blocked = false;
      owner = FadeSettings(
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
        await expectLater(owner.flush(), throwsStateError);
        expect(await owner.recover(), isFalse);
        store.refuseRepair = false;
        expect(await owner.recover(), isTrue);
        expect(store.values.containsKey(key), isFalse);
        expect(owner.confirmed.defaultMs, 4000);
      },
    );

    test(
      'drains admitted edits and excludes later edits through Session capture',
      () async {
        store.gate = Completer<void>();
        final first = owner.setDefault(6000);
        await store.entered.future;
        final second = owner.setOverride(0, 6000);
        FadeDurations? captured;
        final capture = owner.runExclusive((admittedEdits) async {
          await admittedEdits;
          captured = owner.confirmed;
        });
        await expectLater(owner.setDefault(8000), throwsStateError);
        expect(owner.confirmed.defaultMs, 4000);
        store.gate!.complete();
        await Future.wait([first, second, capture]);
        expect(
          captured,
          FadeDurations(defaultMs: 6000, overrides: const {0: 6000}),
        );
      },
    );

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
        await owner.runExclusive(
          (admittedEdits) async {
            await admittedEdits;
            await owner.installSession(FadeDurations(defaultMs: 12000));
          },
        );
        expect(owner.confirmed.defaultMs, 12000);
        expect(owner.confirmed.overrides, isEmpty);
      },
    );

    test(
      'early Session owner refusal cannot detach a prior write from close',
      () async {
        store.gate = Completer<void>();
        Object? writeError;
        final write = owner.setDefault(6000).catchError((Object error) {
          writeError = error;
        });
        await store.entered.future;
        // An existing owner (for example Mix recovery) can refuse before it
        // reaches the callback that awaits the admitted Fade edits.
        final refusal = owner.runExclusive<void>((_) async {
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
        expect(owner.confirmed.defaultMs, 6000);
      },
    );

    test(
      'throwing scope releases exclusion; repeated scopes drain before close',
      () async {
        await expectLater(
          owner.runExclusive<void>((_) => throw StateError('scope refused')),
          throwsStateError,
        );
        await owner.setDefault(6000);
        final release = Completer<void>();
        final order = <int>[];
        final first = owner.runExclusive((drain) async {
          await drain;
          order.add(1);
          await release.future;
        });
        final second = owner.runExclusive((drain) async {
          await drain;
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
      'close drains the admitted write and immediately rejects new work',
      () async {
        store.gate = Completer<void>();
        final write = owner.setDefault(6000);
        await store.entered.future;
        final closing = owner.close();
        await expectLater(owner.setDefault(8000), throwsStateError);
        store.gate!.complete();
        await Future.wait([write, closing]);
        expect(owner.confirmed.defaultMs, 6000);
      },
    );

    test(
      'startup queued during a canceled Session still restores local setup',
      () async {
        await owner.close();
        store.values[key] = '{"defaultMs":8000,"overrides":{}}';
        owner = FadeSettings(
          settings: SettingsRepository(store: store),
          blocked: () => false,
          sessionBlocked: () => false,
        );
        final release = Completer<void>();
        final scope = owner.runExclusive((drain) async {
          await drain;
          await release.future;
        });
        final loaded = owner.load();
        release.complete();
        await Future.wait([scope, loaded]);
        expect(owner.confirmed.defaultMs, 8000);
      },
    );

    test(
      'malformed startup remains recoverable without silently defaulting',
      () async {
        await owner.close();
        store.values[key] = '{"defaultMs":500.5,"overrides":{}}';
        owner = FadeSettings(
          settings: SettingsRepository(store: store),
          blocked: () => false,
          sessionBlocked: () => false,
        );
        await expectLater(owner.load(), throwsFormatException);
        expect(owner.needsRecovery, isTrue);
        expect(await owner.recover(), isFalse);
        store.values[key] = '{"defaultMs":500,"overrides":{}}';
        expect(await owner.recover(), isTrue);
        expect(owner.confirmed.defaultMs, 500);
      },
    );
  });
}
