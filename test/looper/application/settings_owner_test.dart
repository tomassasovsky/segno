import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/looper/application/settings_owner.dart';
import 'package:segno/looper/application/tempo_settings.dart';
import 'package:segno/looper/model/owned_setting.dart';
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
}

class _Store extends FakeKeyValueStore {
  static const keys = {'tempo.click_volume', 'tempo.click_mode'};
  final writes = <String, int>{};
  int failingWrites = 0;

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
  Future<void> remove(String key) => _write(key, () => super.remove(key));
}

/// One owned family seen through literal oracles: the store key, the fake
/// engine's own published value, and the repository's restart intent.
final class _Case<V extends Object> {
  const _Case({
    required this.name,
    required this.key,
    required this.stored,
    required this.next,
    required this.owner,
    required this.encode,
    required this.withhold,
    required this.deliver,
    required this.audible,
    required this.restart,
  });
  final String name;
  final String key;

  /// What the store holds before each case.
  final Object stored;
  final V next;
  final SettingsOwner<V, Object?> Function(TempoSettings) owner;
  final Object Function(V) encode;
  final void Function(_Engine) withhold;
  final void Function(_Engine) deliver;
  final V Function(_Engine) audible;
  final V Function(LooperRepository) restart;
}

final _clickVolume = _Case<double>(
  name: 'Click volume',
  key: 'tempo.click_volume',
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
);

final _hearClick = _Case<ClickMode>(
  name: 'Hear click',
  key: 'tempo.click_mode',
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
);

class _Rig {
  _Rig(this.clock, {Object? clickVolume = .5, Object? clickMode = 0}) {
    if (clickVolume != null) store.values['tempo.click_volume'] = clickVolume;
    if (clickMode != null) store.values['tempo.click_mode'] = clickMode;
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
    Object? clickVolume = .5,
    Object? clickMode = 0,
  }) {
    test(
      name,
      () => fakeAsync((clock) {
        final rig = _Rig(clock, clickVolume: clickVolume, clickMode: clickMode);
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
        expect(r.store.values[c.key], c.encode(c.next));
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
        expect(r.store.values[c.key], c.encode(c.next));
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
        expect(r.store.values[c.key], c.encode(c.next));
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
        expect(r.store.values[c.key], c.encode(c.next));
      });

      check('a native refusal rolls storage back to the exact checkpoint', (r) {
        final owner = c.owner(r.tempo);
        r.engine
          ..refuseClick = true
          ..refuseMode = true;
        expect(r.run(owner.set(c.next))?.status, SettingStatus.rejected);
        expect(r.store.values[c.key], c.stored);
        expect(r.run(owner.flush())?.status, SettingStatus.applied);
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
        expect(r.store.values[c.key], c.stored);
        expect(r.engine.stopCalls, 0);
      });
    });
  }

  contract(_clickVolume);
  contract(_hearClick);

  group('unreadable storage', () {
    for (final (c, invalid, repaired, value)
        in <(_Case<Object>, Object, Object?, Object)>[
          (_hearClick, 9, ClickMode.off.code, ClickMode.off),
          (_clickVolume, 5.0, null, 1.0),
        ]) {
      check(
        '${c.name} ${c.key}=$invalid: audio keeps running, Session '
        'capture proceeds, and Retry repairs the key',
        (r) {
          final owner = c.owner(r.tempo);
          expect(r.looper.sessionTransport.isRunning, isTrue);
          expect(r.engine.stopCalls, 0);
          expect(owner.ready, isFalse);
          expect(owner.value, isNull);
          Object? captured;
          Object? refusal;
          unawaited(
            r.tempo
                .runTempoExclusive(() async => captured = owner.durable)
                .catchError((Object error) => refusal = error),
          );
          r.pump();
          expect(refusal, isNull);
          expect(captured, isNotNull);
          expect(r.store.values[c.key], invalid);
          expect(r.run(owner.recover())?.status, SettingStatus.applied);
          expect(r.store.values.containsKey(c.key), repaired != null);
          expect(r.store.values[c.key], repaired);
          expect(owner.ready, isTrue);
          expect(owner.value, value);
        },
        clickVolume: c == _clickVolume ? invalid : .5,
        clickMode: c == _hearClick ? invalid : 0,
      );
    }
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
    }, clickVolume: null);
  });

  group('Hear click family', () {
    check('an absent preference loads First recording without a key', (r) {
      expect(r.tempo.clickModeOwner.value, ClickMode.recFirst);
      expect(r.store.values.containsKey('tempo.click_mode'), isFalse);
    }, clickMode: null);

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
