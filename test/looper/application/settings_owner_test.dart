import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/looper/application/settings_owner.dart';
import 'package:segno/looper/application/settings_owners.dart';
import 'package:segno/looper/application/tempo_settings.dart';
import 'package:segno/looper/model/owned_setting.dart';
import 'package:segno/looper/model/record_start.dart';
import 'package:segno_engine/segno_engine.dart' as le;
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

const _pinned = le.AudioDevice(
  id: 'out-1',
  name: 'Scarlett 2i2',
  isDefault: false,
  isInput: false,
);

class _Engine extends FakeAudioEngine {
  bool refuseClick = false;
  bool refuseMode = false;
  bool refuseOnce = false;
  final clickWrites = <double>[];

  /// Runs once, from the first snapshot read after it is armed and returns
  /// true; the repository reads a snapshot while it publishes a receipt.
  bool Function()? onSnapshot;

  @override
  le.EngineSnapshot snapshot() {
    final hook = onSnapshot;
    onSnapshot = null;
    if (hook != null && !hook()) onSnapshot = hook;
    return super.snapshot();
  }

  @override
  EngineResult setClickVolume(double volume) {
    clickWrites.add(volume);
    return refuseClick ? EngineResult.notReady : super.setClickVolume(volume);
  }

  @override
  EngineResult setClickMode(ClickMode mode) =>
      refuseMode ? EngineResult.notReady : super.setClickMode(mode);

  /// Once replays after both Click families, so refusing it fails a start
  /// after their replays were admitted.
  @override
  EngineResult setOneShotMask({required int channels, required bool oneShot}) =>
      refuseOnce
      ? EngineResult.invalid
      : super.setOneShotMask(channels: channels, oneShot: oneShot);
}

class _Store extends FakeKeyValueStore {
  static const keys = {
    'tempo.click_volume',
    'tempo.click_mode',
    'tempo.count_in_bars',
    'looper.auto_record',
  };
  final writes = <String, int>{};
  int failingWrites = 0;
  Completer<void>? modeReadGate;
  bool failModeRead = false;

  @override
  Future<int?> getInt(String key) async {
    if (key == 'tempo.click_mode') {
      await modeReadGate?.future;
      if (failModeRead) throw StateError('Hear click read failed');
    }
    return super.getInt(key);
  }

  Future<void> _write(String key, Future<void> Function() write) async {
    if (!keys.contains(key)) return write();
    writes[key] = (writes[key] ?? 0) + 1;
    await write();
    if (failingWrites > 0) {
      failingWrites--;
      throw StateError('$key mutated then refused');
    }
  }

  @override
  Future<void> setDouble(String key, double value) =>
      _write(key, () => super.setDouble(key, value));

  @override
  Future<void> setInt(String key, int value) =>
      _write(key, () => super.setInt(key, value));

  @override
  Future<void> setBool(String key, {required bool value}) =>
      _write(key, () => super.setBool(key, value: value));

  @override
  Future<void> remove(String key) => _write(key, () => super.remove(key));
}

/// One owned family seen through literal oracles: its store keys, the fake
/// engine's own published value, and the repository's restart intent.
final class _Case<V extends Object> {
  _Case({
    required this.name,
    required this.keys,
    required this.stored,
    required this.next,
    required this.owner,
    required this.encode,
    required this.withhold,
    required this.deliver,
    required this.audible,
    required this.restart,
    required this.invalid,
    required this.repaired,
    required this.repairedValue,
    required this.recalled,
    required this.recalledValue,
  });
  final String name;
  final List<String> keys;

  /// What the store holds before each case, in [read]'s shape.
  final Object stored;
  final V next;

  /// Unreadable stored data, what Retry stores over it and then plays.
  final Map<String, Object> invalid;
  final Object? repaired;
  final V repairedValue;

  /// A Session holding another value, and that value.
  final SessionRig recalled;
  final V recalledValue;

  /// The stored data, one value per key.
  Object? read(_Store store) => keys.length == 1
      ? store.values[keys.single]
      : [for (final key in keys) store.values[key]];
  final SettingsOwner<V, Object?> Function(TempoSettings) owner;
  final Object Function(V) encode;
  final void Function(_Engine) withhold;
  final void Function(_Engine) deliver;
  final V Function(_Engine) audible;
  final V Function(LooperRepository) restart;
}

final _clickVolume = _Case<double>(
  name: 'Click volume',
  keys: ['tempo.click_volume'],
  stored: .5,
  next: 1.5,
  owner: (tempo) => tempo.clickVolumeOwner,
  encode: (value) => value,
  withhold: (engine) => engine
    ..publishClickCommands = false
    ..commandsAreSettled = false,
  deliver: (engine) => engine
    ..publishClickCommands = true
    ..commandsAreSettled = true,
  audible: (engine) => engine.nextSnapshot.clickVolume,
  restart: (repository) => repository.clickVolumeRestartIntent,
  invalid: {'tempo.click_volume': 5.0},
  repaired: null,
  repairedValue: 1,
  recalled: const SessionRig(clickVolume: 1.25),
  recalledValue: 1.25,
);

final _hearClick = _Case<ClickMode>(
  name: 'Hear click',
  keys: ['tempo.click_mode'],
  stored: ClickMode.off.code,
  next: ClickMode.playRec,
  owner: (tempo) => tempo.clickModeOwner,
  encode: (value) => value.code,
  withhold: (engine) => engine
    ..publishClickModeCommands = false
    ..commandsAreSettled = false,
  deliver: (engine) => engine
    ..publishClickModeCommands = true
    ..commandsAreSettled = true,
  audible: (engine) => engine.nextSnapshot.clickMode,
  restart: (repository) => repository.clickModeRestartIntent,
  invalid: {'tempo.click_mode': 9},
  repaired: ClickMode.off.code,
  repairedValue: ClickMode.off,
  recalled: const SessionRig(clickMode: ClickMode.playRec),
  recalledValue: ClickMode.playRec,
);

RecordStartSettings _pair(({int countInBars, bool soundStart}) pair) =>
    RecordStartSettings(
      countInBars: pair.countInBars,
      soundStart: pair.soundStart,
    );

final _recordStart = _Case<RecordStartSettings>(
  name: 'Count-in',
  keys: ['tempo.count_in_bars', 'looper.auto_record'],
  stored: [0, false],
  next: RecordStartSettings(countInBars: 2, soundStart: false),
  owner: (tempo) => tempo.recordStartOwner,
  encode: (value) => [value.countInBars, value.soundStart],
  withhold: (engine) => engine
    ..publishRecordStartCommands = false
    ..commandsAreSettled = false,
  deliver: (engine) => engine
    ..publishRecordStartCommands = true
    ..commandsAreSettled = true,
  audible: (engine) => RecordStartSettings(
    countInBars: engine.nextSnapshot.countInBars,
    soundStart: engine.nextSnapshot.autoRecord,
  ),
  restart: (repository) => _pair(repository.recordStartRestartIntent),
  invalid: {'tempo.count_in_bars': 2, 'looper.auto_record': true},
  repaired: [0, false],
  repairedValue: RecordStartSettings(countInBars: 0, soundStart: false),
  recalled: const SessionRig(countInBars: 2),
  recalledValue: RecordStartSettings(countInBars: 2, soundStart: false),
);

const _defaults = <String, Object>{
  'tempo.click_volume': .5,
  'tempo.click_mode': 0,
  'tempo.count_in_bars': 0,
  'looper.auto_record': false,
};

class _Rig {
  _Rig(
    this.clock, {
    Map<String, Object?> stored = const {},
    void Function(_Store)? prepare,
  }) {
    prepare?.call(store);
    for (final entry in {..._defaults, ...stored}.entries) {
      if (entry.value case final value?) store.values[entry.key] = value;
    }
    engine.nextSnapshot = engine.nextSnapshot.copyWith(devicePresent: true);
    looper = LooperRepository(
      engine: engine,
      ticker: ticker.stream,
      reconnectTicker: reconnect.stream,
    );
    subscription = looper.looperState.listen((_) {});
    expect(
      looper.startEngine(const EngineConfig(playbackDeviceId: 'out-1')),
      EngineResult.ok,
    );
    tempo = TempoSettings(
      repository: looper,
      settings: SettingsRepository(store: store),
    );
    unawaited(tempo.load());
    pump();
  }

  final FakeAsync clock;
  final engine = _Engine();
  final store = _Store();
  final ticker = StreamController<void>.broadcast();
  final reconnect = StreamController<void>.broadcast();
  late final LooperRepository looper;
  late final StreamSubscription<LooperState> subscription;
  late final TempoSettings tempo;

  void pump() {
    clock
      ..flushMicrotasks()
      ..elapse(const Duration(milliseconds: 20))
      ..flushMicrotasks();
  }

  void expire() {
    clock
      ..elapse(const Duration(milliseconds: 510))
      ..flushMicrotasks();
  }

  SettingOutcome? run(Future<SettingOutcome> operation) {
    SettingOutcome? outcome;
    unawaited(operation.then((value) => outcome = value));
    pump();
    return outcome;
  }

  void close() {
    engine
      ..publishClickCommands = true
      ..publishClickModeCommands = true
      ..publishRecordStartCommands = true
      ..commandsAreSettled = true;
    unawaited(tempo.close());
    clock.elapse(const Duration(seconds: 1));
    unawaited(subscription.cancel());
    unawaited(looper.dispose());
    unawaited(ticker.close());
    unawaited(reconnect.close());
    clock.flushMicrotasks();
  }
}

void main() {
  void check(
    String name,
    void Function(_Rig) body, {
    Map<String, Object?> stored = const {},
    void Function(_Store)? prepare,
  }) {
    test(
      name,
      () => fakeAsync((clock) {
        final rig = _Rig(clock, stored: stored, prepare: prepare);
        try {
          body(rig);
        } finally {
          rig.close();
        }
      }),
    );
  }

  void contract<V extends Object>(_Case<V> c) {
    group('${c.name} owner', () {
      check('device absent: the write owes its value, audio keeps running, '
          'and reconnect lands it', (r) {
        final owner = c.owner(r.tempo);
        expect(owner.ready, isTrue);
        c.withhold(r.engine);
        SettingOutcome? outcome;
        unawaited(owner.set(c.next).then((value) => outcome = value));
        r.expire();
        expect(outcome?.status, SettingStatus.recoveryRequired);
        expect(r.engine.stopCalls, 0);
        expect(r.looper.sessionTransport.isRunning, isTrue);
        // Storage keeps the value Retry and a restart owe.
        expect(c.read(r.store), c.encode(c.next));
        expect(c.restart(r.looper), c.next);
        expect(owner.ready, isFalse);

        r.engine.nextSnapshot = r.engine.nextSnapshot.copyWith(
          devicePresent: false,
        );
        r.ticker.add(null);
        r.clock.flushMicrotasks();
        r.engine.devices = const [_pinned];
        c.deliver(r.engine);
        r.reconnect.add(null);
        r.pump();
        expect(r.engine.startCalls, 2);
        expect(r.run(owner.flush())?.status, SettingStatus.applied);
        expect(owner.value, c.next);
        expect(c.audible(r.engine), c.next);
        expect(c.read(r.store), c.encode(c.next));
      });

      check('a late receipt then Retry ends applied without a stop', (r) {
        final owner = c.owner(r.tempo);
        c.withhold(r.engine);
        unawaited(owner.set(c.next));
        r.expire();
        expect(owner.ready, isFalse);
        c.deliver(r.engine);
        expect(r.run(owner.recover())?.status, SettingStatus.applied);
        expect(owner.value, c.next);
        expect(c.audible(r.engine), c.next);
        expect(c.read(r.store), c.encode(c.next));
        expect(r.engine.stopCalls, 0);
      });

      check('startEngine is not refused while the value is owed', (r) {
        final owner = c.owner(r.tempo);
        c.withhold(r.engine);
        unawaited(owner.set(c.next));
        r.expire();
        r.looper.stopEngine();
        c.deliver(r.engine);
        expect(r.looper.startEngine(const EngineConfig()), EngineResult.ok);
        r.pump();
        expect(r.run(owner.flush())?.status, SettingStatus.applied);
        expect(owner.value, c.next);
      });

      check('an accepted receipt commits even when the lifetime moves on '
          'before the owner resumes', (r) {
        final owner = c.owner(r.tempo);
        // The engine publishes the value; only the command fence is held.
        r.engine.commandsAreSettled = false;
        r.engine.onSnapshot = () {
          if (c.restart(r.looper) != c.next) return false;
          r.looper.stopEngine();
          return true;
        };
        SettingOutcome? outcome;
        unawaited(owner.set(c.next).then((value) => outcome = value));
        r.clock.flushMicrotasks();
        expect(c.audible(r.engine), c.next);
        r.engine.commandsAreSettled = true;
        r.pump();
        expect(r.engine.onSnapshot, isNull);
        expect(r.looper.sessionTransport.isRunning, isFalse);
        expect(outcome?.status, SettingStatus.applied);
        expect(c.restart(r.looper), c.next);
        expect(c.read(r.store), c.encode(c.next));
      });

      check('a native refusal rolls storage back to the exact checkpoint', (r) {
        final owner = c.owner(r.tempo);
        r.engine
          ..refuseClick = true
          ..refuseMode = true
          ..recordStartResult = EngineResult.invalid;
        expect(r.run(owner.set(c.next))?.status, SettingStatus.rejected);
        expect(c.read(r.store), c.stored);
        expect(r.run(owner.flush())?.status, SettingStatus.applied);
      });

      check('Retry stopped inside its receipt window still owes the value', (
        r,
      ) {
        final owner = c.owner(r.tempo);
        c.withhold(r.engine);
        unawaited(owner.set(c.next));
        r.expire();
        SettingOutcome? retry;
        unawaited(owner.recover().then((value) => retry = value));
        r.clock.flushMicrotasks();
        r.looper.stopEngine();
        r.pump();
        expect(retry?.status, SettingStatus.recoveryRequired);
        expect(owner.ready, isFalse);
        expect(c.restart(r.looper), c.next);
        c.deliver(r.engine);
        expect(r.looper.startEngine(const EngineConfig()), EngineResult.ok);
        r.pump();
        expect(c.audible(r.engine), c.next);
        expect(r.run(owner.flush())?.status, SettingStatus.applied);
        expect(owner.value, c.next);
        expect(c.read(r.store), c.encode(c.next));
      });

      check('a failed start after an owed replay still owes the value', (r) {
        final owner = c.owner(r.tempo);
        c.withhold(r.engine);
        unawaited(owner.set(c.next));
        r.expire();
        r.looper.stopEngine();
        c.deliver(r.engine);
        r.engine.refuseOnce = true;
        expect(
          r.looper.startEngine(const EngineConfig()),
          isNot(EngineResult.ok),
        );
        r.pump();
        expect(owner.ready, isFalse);
        expect(c.restart(r.looper), c.next);
        r.engine.refuseOnce = false;
        expect(r.looper.startEngine(const EngineConfig()), EngineResult.ok);
        r.pump();
        expect(c.audible(r.engine), c.next);
        expect(c.read(r.store), c.encode(c.next));
        expect(r.run(owner.flush())?.status, SettingStatus.applied);
      });

      check('a timeout during a write is reported once', (r) {
        final owner = c.owner(r.tempo);
        final failures = <SettingOutcome>[];
        final subscription = owner.failures.listen(failures.add);
        c.withhold(r.engine);
        unawaited(owner.set(c.next));
        r
          ..expire()
          ..pump();
        expect(failures.map((f) => f.status), [SettingStatus.recoveryRequired]);
        unawaited(subscription.cancel());
      });

      check('a failed rollback owes the checkpoint until Retry', (r) {
        final owner = c.owner(r.tempo);
        r.store.failingWrites = 2;
        expect(
          r.run(owner.set(c.next))?.status,
          SettingStatus.recoveryRequired,
        );
        expect(owner.ready, isFalse);
        expect(
          r.run(owner.set(c.next))?.status,
          SettingStatus.recoveryRequired,
        );
        expect(r.run(owner.recover())?.status, SettingStatus.applied);
        expect(c.read(r.store), c.stored);
        expect(r.engine.stopCalls, 0);
      });
    });
  }

  contract(_clickVolume);
  contract(_hearClick);
  contract(_recordStart);

  void unreadable<V extends Object>(_Case<V> c) {
    check(
      '${c.name} ${c.invalid}: audio keeps running, Session capture '
      'proceeds, and Retry repairs the stored data',
      (r) {
        final owner = c.owner(r.tempo);
        expect(r.looper.sessionTransport.isRunning, isTrue);
        expect(r.engine.stopCalls, 0);
        expect(owner.ready, isFalse);
        expect(owner.value, isNull);
        Object? captured;
        Object? refusal;
        unawaited(
          SettingsOwners(r.tempo.owners)
              .runExclusive<void>(() async => captured = owner.durable)
              .catchError((Object error) => refusal = error),
        );
        r.pump();
        expect(refusal, isNull);
        expect(captured, isNotNull);
        expect(
          r.store.values,
          containsPair(c.keys.first, c.invalid[c.keys.first]),
        );
        expect(r.run(owner.recover())?.status, SettingStatus.applied);
        expect(c.read(r.store), c.repaired);
        expect(owner.ready, isTrue);
        expect(owner.value, c.repairedValue);
      },
      stored: c.invalid,
    );

    check('${c.name}: unreadable data, Session load, then Retry', (r) {
      final owner = c.owner(r.tempo);
      expect(owner.ready, isFalse);
      r.looper.stopEngine();
      unawaited(r.looper.applySession(c.recalled));
      r.pump();
      expect(r.looper.startEngine(const EngineConfig()), EngineResult.ok);
      r.pump();
      expect(c.audible(r.engine), c.recalledValue);
      expect(r.run(owner.recover())?.status, SettingStatus.applied);
      expect(c.read(r.store), c.repaired);
      expect(owner.value, c.recalledValue);
      expect(c.audible(r.engine), c.recalledValue);
      Object? captured;
      unawaited(
        SettingsOwners(
          r.tempo.owners,
        ).runExclusive(() async => captured = owner.durable),
      );
      r.pump();
      expect(captured, c.recalledValue);
    }, stored: c.invalid);
  }

  group('unreadable storage', () {
    unreadable(_hearClick);
    unreadable(_clickVolume);
    unreadable(_recordStart);
  });

  group('Click volume coalescing', () {
    check('twenty rapid ordinary writes store at most twice; the last wins', (
      r,
    ) {
      final owner = r.tempo.clickVolumeOwner;
      r.store.writes.clear();
      final outcomes = <SettingOutcome>[];
      for (var i = 1; i <= 20; i++) {
        unawaited(owner.set(i / 10).then(outcomes.add));
      }
      r.pump();
      expect(outcomes, hasLength(20));
      expect(r.store.writes['tempo.click_volume'], lessThanOrEqualTo(2));
      expect(r.store.values['tempo.click_volume'], 2.0);
      expect(r.engine.nextSnapshot.clickVolume, 2.0);
      expect(owner.value, 2.0);
      expect(outcomes.last.isOk, isTrue);
    });
  });

  group('Click volume family', () {
    check('held admission waits native publication and stores Released', (
      r,
    ) {
      final owner = r.tempo.clickVolumeOwner;
      r.engine
        ..publishClickCommands = false
        ..commandsAreSettled = false;
      SettingOutcome? outcome;
      unawaited(
        owner
            .setController(1.5, lifetime: owner.lifetime, released: .25)
            .then((value) => outcome = value),
      );
      r.pump();
      expect(r.store.values['tempo.click_volume'], .25);
      expect(owner.value, .5);
      expect(outcome, isNull);
      r.engine
        ..nextSnapshot = r.engine.nextSnapshot.copyWith(clickVolume: 1.5)
        ..commandsAreSettled = true;
      r.pump();
      expect(outcome?.isOk, isTrue);
      expect(owner.value, 1.5);
      expect(owner.durable, .25);
    });

    for (final gain in [double.nan, double.infinity, -.1, 2.1]) {
      check('invalid gain $gain is rejected before storage or audio', (r) {
        final writes = r.engine.clickWrites.length;
        expect(
          r.run(r.tempo.clickVolumeOwner.set(gain))?.status,
          SettingStatus.rejected,
        );
        expect(r.engine.clickWrites, hasLength(writes));
        expect(r.store.values['tempo.click_volume'], .5);
      });
    }

    check('an edit while an owed replay is admitted waits and applies', (r) {
      final owner = r.tempo.clickVolumeOwner;
      _clickVolume.withhold(r.engine);
      unawaited(owner.set(1.5));
      r.expire();
      expect(owner.ready, isFalse);
      r.looper.stopEngine();
      // The restart replays the owed 1.5; its receipt is not published yet.
      r.engine.publishClickCommands = true;
      expect(r.looper.startEngine(const EngineConfig()), EngineResult.ok);
      final failures = <SettingOutcome>[];
      final subscription = owner.failures.listen(failures.add);
      SettingOutcome? outcome;
      unawaited(owner.set(.75).then((value) => outcome = value));
      r.clock.flushMicrotasks();
      r.engine.commandsAreSettled = true;
      r
        ..pump()
        ..pump();
      expect(outcome?.status, SettingStatus.applied);
      expect(failures, isEmpty);
      expect(owner.value, .75);
      expect(r.engine.nextSnapshot.clickVolume, .75);
      expect(r.store.values['tempo.click_volume'], .75);
      unawaited(subscription.cancel());
    });

    check('an ordinary same-value edit removes the held Released value', (r) {
      final owner = r.tempo.clickVolumeOwner;
      unawaited(
        owner.setController(1.5, lifetime: owner.lifetime, released: .25),
      );
      r.pump();
      expect(owner.durable, .25);
      final ordinary = <double>[];
      final subscription = owner.ordinaryChanges.listen(ordinary.add);
      expect(r.run(owner.set(1.5))?.isOk, isTrue);
      expect(owner.durable, 1.5);
      expect(r.store.values['tempo.click_volume'], 1.5);
      expect(ordinary, [1.5]);
      unawaited(subscription.cancel());
    });

    check('a stopped edit is deferred and the next start replays it', (r) {
      r.looper.stopEngine();
      final outcome = r.run(r.tempo.clickVolumeOwner.set(1.5));
      expect(outcome?.isOk, isTrue);
      expect(outcome?.deferred, isTrue);
      expect(r.store.values['tempo.click_volume'], 1.5);
      expect(r.looper.startEngine(const EngineConfig()), EngineResult.ok);
      r.pump();
      expect(r.engine.nextSnapshot.clickVolume, 1.5);
    });

    check('a device restart retires a temporary high to Released', (r) {
      final owner = r.tempo.clickVolumeOwner;
      unawaited(
        owner.setController(1.5, lifetime: owner.lifetime, released: .25),
      );
      r.pump();
      expect(owner.value, 1.5);
      r.looper.stopEngine();
      expect(r.looper.startEngine(const EngineConfig()), EngineResult.ok);
      r.pump();
      expect(owner.value, .25);
      expect(r.engine.nextSnapshot.clickVolume, .25);
      expect(r.store.values['tempo.click_volume'], .25);
    });

    check('an absent preference loads unity without writing a key', (r) {
      expect(r.tempo.clickVolumeOwner.value, 1);
      expect(r.store.values.containsKey('tempo.click_volume'), isFalse);
    }, stored: const {'tempo.click_volume': null});
  });

  group('Count-in family', () {
    for (final entry in [
      (stored: <String, Object?>{}, bars: 1, sound: false),
      (
        stored: <String, Object?>{'tempo.count_in_bars': 0},
        bars: 0,
        sound: false,
      ),
      (
        stored: <String, Object?>{'looper.auto_record': true},
        bars: 0,
        sound: true,
      ),
      (
        stored: <String, Object?>{'tempo.count_in_bars': 4},
        bars: 4,
        sound: false,
      ),
    ]) {
      check(
        'load keeps exact stored membership ${entry.stored}',
        (r) {
          expect(
            r.tempo.recordStartOwner.value,
            RecordStartSettings(
              countInBars: entry.bars,
              soundStart: entry.sound,
            ),
          );
          expect(
            r.store.values['tempo.count_in_bars'],
            entry.stored['tempo.count_in_bars'],
          );
          expect(
            r.store.values['looper.auto_record'],
            entry.stored['looper.auto_record'],
          );
        },
        stored: {
          'tempo.count_in_bars': null,
          'looper.auto_record': null,
          ...entry.stored,
        },
      );
    }

    check('sequential edits keep Count Off versus Sound off intent', (r) {
      final control = r.tempo.recordStartControl;
      RecordStartOutcome? run(Future<RecordStartOutcome> edit) {
        RecordStartOutcome? outcome;
        unawaited(edit.then((value) => outcome = value));
        r.pump();
        return outcome;
      }

      final before = r.engine.recordStartRequests.length;
      expect(run(control.setSoundStart(enabled: true))?.isOk, isTrue);
      expect(run(control.setCountInBars(0))?.isOk, isTrue);
      expect(
        r.tempo.recordStartOwner.value,
        RecordStartSettings(countInBars: 0, soundStart: true),
      );
      expect(run(control.setCountInBars(2))?.isOk, isTrue);
      expect(run(control.setSoundStart(enabled: false))?.isOk, isTrue);
      expect(
        r.tempo.recordStartOwner.value,
        RecordStartSettings(countInBars: 2, soundStart: false),
      );
      expect(
        r.engine.recordStartRequests.skip(before).map((v) => v.editKind),
        [
          RecordStartEditKind.sound,
          RecordStartEditKind.countIn,
          RecordStartEditKind.countIn,
          RecordStartEditKind.sound,
        ],
      );
      expect(
        run(control.setCountInBars(-1))?.status,
        RecordStartStatus.rejected,
      );
      expect(r.store.values['tempo.count_in_bars'], 2);
      expect(r.store.values['looper.auto_record'], false);
    });

    check('queued edits of different kinds both apply, in order', (r) {
      final control = r.tempo.recordStartControl;
      r.engine.commandsAreSettled = false;
      final outcomes = <RecordStartStatus>[];
      unawaited(
        control
            .setSoundStart(enabled: true)
            .then((o) => outcomes.add(o.status)),
      );
      r.clock.flushMicrotasks();
      // In flight: Sound on. Waiting: two Count-in edits, then Sound off.
      unawaited(control.setCountInBars(1).then((o) => outcomes.add(o.status)));
      unawaited(control.setCountInBars(4).then((o) => outcomes.add(o.status)));
      unawaited(
        control
            .setSoundStart(enabled: false)
            .then((o) => outcomes.add(o.status)),
      );
      r.clock.flushMicrotasks();
      r.engine.commandsAreSettled = true;
      for (var i = 0; i < 4; i++) {
        r.pump();
      }
      expect(outcomes, [
        RecordStartStatus.superseded,
        RecordStartStatus.applied,
        RecordStartStatus.applied,
        RecordStartStatus.applied,
      ]);
      expect(
        r.tempo.recordStartOwner.value,
        RecordStartSettings(countInBars: 4, soundStart: false),
      );
      expect(
        r.engine.recordStartRequests.reversed
            .take(3)
            .toList()
            .reversed
            .map((v) => v.editKind),
        [
          RecordStartEditKind.sound,
          RecordStartEditKind.countIn,
          RecordStartEditKind.sound,
        ],
      );
      expect(r.store.values['tempo.count_in_bars'], 4);
      expect(r.store.values['looper.auto_record'], false);
    });
  });

  group('Hear click family', () {
    check('a refused Retry stays owed', (r) {
      final owner = r.tempo.clickModeOwner;
      _hearClick.withhold(r.engine);
      unawaited(owner.set(ClickMode.playRec));
      r.expire();
      r.engine.commandsAreSettled = true;
      final revision = r.engine.nextSnapshot.clickModeRevision;
      SettingOutcome? retry;
      unawaited(owner.recover().then((value) => retry = value));
      r.clock.flushMicrotasks();
      r.engine.nextSnapshot = r.engine.nextSnapshot.copyWith(
        clickModeRevision: revision + 1,
        clickModeResult: -1,
      );
      r.pump();
      expect(retry?.status, SettingStatus.recoveryRequired);
      expect(owner.ready, isFalse);
      expect(r.looper.clickModeRecoveryRequired, isTrue);
      expect(owner.durable, ClickMode.playRec);
      expect(r.store.values['tempo.click_mode'], ClickMode.playRec.code);
      expect(r.engine.stopCalls, 0);
    });

    check('a stale release cannot replace the waiting ordinary choice', (r) {
      final owner = r.tempo.clickModeOwner;
      final origin = owner.lifetime;
      final revision = owner.revision;
      r.engine.commandsAreSettled = false;
      SettingOutcome? first;
      SettingOutcome? latest;
      SettingOutcome? release;
      unawaited(owner.set(ClickMode.rec).then((value) => first = value));
      r.clock.flushMicrotasks();
      unawaited(owner.set(ClickMode.playRec).then((value) => latest = value));
      unawaited(
        owner
            .setController(
              ClickMode.off,
              lifetime: origin,
              revision: revision,
            )
            .then((value) => release = value),
      );
      r.clock.flushMicrotasks();
      r.engine.commandsAreSettled = true;
      r
        ..pump()
        ..pump();
      expect(first?.status, SettingStatus.applied);
      expect(latest?.status, SettingStatus.applied);
      expect(release?.status, SettingStatus.superseded);
      expect(owner.value, ClickMode.playRec);
      expect(r.store.values['tempo.click_mode'], ClickMode.playRec.code);
    });

    check(
      'an obsolete failed load adopts an accepted replacement Session',
      (r) {
        final owner = r.tempo.clickModeOwner;
        expect(owner.initialized, isFalse);
        r.looper.stopEngine();
        unawaited(r.looper.applySession(const SessionRig()));
        r.pump();
        r.store
          ..failModeRead = true
          ..modeReadGate!.complete();
        r.pump();
        expect(owner.ready, isTrue);
        expect(owner.value, ClickMode.off);
        expect(owner.durable, ClickMode.off);
      },
      stored: {'tempo.click_mode': ClickMode.playRec.code},
      prepare: (store) => store.modeReadGate = Completer<void>(),
    );

    check('an absent preference loads First recording without a key', (r) {
      expect(r.tempo.clickModeOwner.value, ClickMode.recFirst);
      expect(r.store.values.containsKey('tempo.click_mode'), isFalse);
    }, stored: const {'tempo.click_mode': null});

    check('a callback refusal keeps audio and rolls storage back', (r) {
      final owner = r.tempo.clickModeOwner;
      r.engine.publishClickModeCommands = false;
      final revision = r.engine.nextSnapshot.clickModeRevision;
      SettingOutcome? outcome;
      unawaited(
        owner.set(ClickMode.rec).then((value) => outcome = value),
      );
      r.clock.flushMicrotasks();
      r.engine.nextSnapshot = r.engine.nextSnapshot.copyWith(
        clickModeRevision: revision + 1,
        clickModeResult: -1,
      );
      r.pump();
      expect(outcome?.status, SettingStatus.rejected);
      expect(r.store.values['tempo.click_mode'], 0);
      expect(owner.value, ClickMode.off);
      expect(r.looper.sessionTransport.isRunning, isTrue);
    });

    check('an active take refuses the edit before storage', (r) {
      r.engine.nextSnapshot = r.engine.nextSnapshot.copyWith(
        tracks: [
          const le.TrackSnapshot(
            state: TrackState.recording,
            volume: 1,
            muted: false,
            lengthFrames: 0,
            undoDepth: 0,
            rms: 0,
            peak: 0,
          ),
          for (var i = 1; i < 8; i++) const le.TrackSnapshot.empty(),
        ],
      );
      r.store.writes.clear();
      expect(
        r.run(r.tempo.clickModeOwner.set(ClickMode.rec))?.status,
        SettingStatus.rejected,
      );
      expect(r.store.writes, isEmpty);
      expect(r.run(r.tempo.clickModeOwner.flush())?.isOk, isTrue);
    });

    check('Held stores Released and a newer ordinary choice supersedes it', (
      r,
    ) {
      final owner = r.tempo.clickModeOwner;
      final origin = owner.lifetime;
      final revision = owner.revision;
      expect(
        r
            .run(
              owner.setController(
                ClickMode.playRec,
                lifetime: origin,
                revision: revision,
                released: ClickMode.off,
              ),
            )
            ?.isOk,
        isTrue,
      );
      expect(owner.value, ClickMode.playRec);
      expect(owner.durable, ClickMode.off);
      expect(r.store.values['tempo.click_mode'], 0);
      expect(r.run(owner.set(ClickMode.rec))?.isOk, isTrue);
      expect(
        r
            .run(
              owner.setController(
                ClickMode.off,
                lifetime: origin,
                revision: revision,
              ),
            )
            ?.status,
        SettingStatus.superseded,
      );
      expect(owner.value, ClickMode.rec);
    });
  });

  test('close waits for an admitted native write before disposal', () async {
    final engine = _Engine();
    final looper = LooperRepository(engine: engine);
    expect(looper.startEngine(const EngineConfig()), EngineResult.ok);
    final store = _Store();
    final tempo = TempoSettings(
      repository: looper,
      settings: SettingsRepository(store: store),
    );
    await tempo.load();
    engine
      ..publishClickCommands = false
      ..commandsAreSettled = false;
    final writes = engine.clickWrites.length;
    final result = tempo.clickVolumeOwner.set(1.5);
    for (var i = 0; i < 20 && engine.clickWrites.length == writes; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(engine.clickWrites.last, 1.5);
    var closed = false;
    final closing = tempo.close().then((_) => closed = true);
    await Future<void>.delayed(Duration.zero);
    expect(closed, isFalse);
    engine
      ..nextSnapshot = engine.nextSnapshot.copyWith(clickVolume: 1.5)
      ..commandsAreSettled = true;
    expect((await result).isOk, isTrue);
    await closing.timeout(const Duration(seconds: 2));
    expect(closed, isTrue);
    expect(store.values['tempo.click_volume'], 1.5);
    await looper.dispose();
  });
}
