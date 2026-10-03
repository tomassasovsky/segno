import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/looper/cubit/tempo_cubit.dart';
import 'package:segno/looper/model/click_mode.dart';
import 'package:segno/looper/model/click_volume.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

class _Engine extends FakeAudioEngine {
  bool refuseMode = false;
  bool refuseVolume = false;
  @override
  EngineResult setClickMode(ClickMode mode) =>
      refuseMode ? EngineResult.notReady : super.setClickMode(mode);
  @override
  EngineResult setClickVolume(double volume) =>
      refuseVolume ? EngineResult.notReady : super.setClickVolume(volume);
}

class _Store extends FakeKeyValueStore {
  Completer<void>? gate;
  int fail = 0;
  bool failRead = false;
  @override
  Future<int?> getInt(String key) async {
    if (key == 'tempo.click_mode') {
      await gate?.future;
      if (failRead) throw StateError('obsolete read failed');
    }
    return super.getInt(key);
  }

  @override
  Future<void> setInt(String key, int value) async {
    await super.setInt(key, value);
    if (key == 'tempo.click_mode' && fail > 0) {
      fail--;
      throw StateError('mutated then refused');
    }
  }
}

class _Rig {
  _Rig(this.clock, {Object? saved, bool running = true}) {
    if (saved != null) store.values['tempo.click_mode'] = saved;
    repository = LooperRepository(engine: engine);
    if (running) {
      expect(repository.startEngine(const EngineConfig()), EngineResult.ok);
    }
    owner = TempoCubit(
      repository: repository,
      settings: SettingsRepository(store: store),
    );
  }
  final FakeAsync clock;
  final engine = _Engine();
  final store = _Store();
  late final LooperRepository repository;
  late final TempoCubit owner;
  void pump() {
    clock
      ..flushMicrotasks()
      ..elapse(const Duration(milliseconds: 20))
      ..flushMicrotasks();
  }

  void load() {
    unawaited(owner.load());
    pump();
  }

  void close() {
    engine.commandsAreSettled = true;
    unawaited(owner.close());
    pump();
    unawaited(repository.dispose());
    clock.flushMicrotasks();
  }
}

void main() {
  void check(
    String name,
    void Function(_Rig) body, {
    Object? saved,
    bool running = true,
  }) {
    test(
      name,
      () => fakeAsync((clock) {
        final r = _Rig(clock, saved: saved, running: running);
        try {
          body(r);
        } finally {
          r.close();
        }
      }),
    );
  }

  check(
    'obsolete failed initialization adopts an accepted replacement session',
    (r) {
      r.store.gate = Completer<void>();
      unawaited(r.owner.loadClickMode());
      r.pump();
      r.repository.stopEngine();
      var replaced = false;
      unawaited(
        r.repository
            .applySession(const SessionRig())
            .then((_) => replaced = true),
      );
      r.pump();
      expect(replaced, isTrue);
      r.store.failRead = true;
      r.store.gate!.complete();
      r.pump();
      expect(r.owner.clickModeSnapshot?.mode, ClickMode.off);
      expect(r.owner.durableClickMode, ClickMode.off);
    },
  );
  check('missing choice initializes First without materializing a scalar', (r) {
    expect(r.owner.clickModeSnapshot, isNull);
    expect(r.owner.confirmedClickMode, isNull);
    r.load();
    expect(r.owner.clickModeSnapshot?.mode, ClickMode.recFirst);
    expect(r.store.values.containsKey('tempo.click_mode'), isFalse);
  });
  check('explicit Off stays Off', (r) {
    r.load();
    expect(r.owner.clickModeSnapshot?.mode, ClickMode.off);
    expect(r.store.values['tempo.click_mode'], 0);
  }, saved: 0);
  check('malformed choice remains unavailable and exact value survives Retry', (
    r,
  ) {
    r.load();
    expect(r.owner.clickModeSnapshot, isNull);
    ClickModeOutcome? outcome;
    unawaited(r.owner.recoverClickMode().then((v) => outcome = v));
    r.pump();
    expect(outcome?.status, ClickModeStatus.recoveryRequired);
    expect(r.store.values['tempo.click_mode'], 9);
  }, saved: 9);
  check('mode initialization is independent while its checkpoint is delayed', (
    r,
  ) {
    r.store.gate = Completer<void>();
    unawaited(r.owner.load());
    r.pump();
    expect(r.owner.clickModeSnapshot, isNull);
    expect(r.owner.clickVolume, 1);
    r.store.gate!.complete();
    r.pump();
    expect(r.owner.clickModeSnapshot?.mode, ClickMode.recFirst);
  });
  check('autonomous replay publishes ready after identical scalar snapshot', (
    r,
  ) {
    r.load();
    r.repository.stopEngine();
    r.engine.commandsAreSettled = false;
    expect(r.repository.startEngine(const EngineConfig()), EngineResult.ok);
    r.pump();
    expect(r.owner.clickModeSnapshot, isNull);
    r.engine.commandsAreSettled = true;
    r.pump();
    expect(r.owner.clickModeSnapshot?.mode, ClickMode.recFirst);
  });
  check(
    'confirmed readout survives recovery while admission remains unavailable',
    (r) {
      r.load();
      r.store.fail = 2;
      ClickModeOutcome? result;
      unawaited(
        r.owner.setClickMode(ClickMode.playRec).then((v) => result = v),
      );
      r.pump();
      expect(result?.status, ClickModeStatus.recoveryRequired);
      expect(r.owner.clickModeSnapshot, isNull);
      expect(r.owner.confirmedClickMode, ClickMode.off);
    },
    saved: 0,
  );
  check('known native refusal restores absent scalar and healthy flush', (r) {
    r.load();
    r.engine.refuseMode = true;
    ClickModeOutcome? outcome;
    unawaited(r.owner.setClickMode(ClickMode.playRec).then((v) => outcome = v));
    r.pump();
    expect(outcome?.status, ClickModeStatus.rejected);
    expect(r.store.values.containsKey('tempo.click_mode'), isFalse);
    expect(r.owner.clickModeSnapshot?.mode, ClickMode.recFirst);
    unawaited(r.owner.flushClickMode().then((v) => outcome = v));
    r.pump();
    expect(outcome?.isOk, isTrue);
  });
  check('mutating storage failure rolls back explicit Off exactly', (r) {
    r.load();
    r.store.fail = 1;
    ClickModeOutcome? outcome;
    unawaited(r.owner.setClickMode(ClickMode.rec).then((v) => outcome = v));
    r.pump();
    expect(outcome?.status, ClickModeStatus.rejected);
    expect(r.store.values['tempo.click_mode'], 0);
    expect(r.owner.clickModeSnapshot?.mode, ClickMode.off);
  }, saved: 0);
  check(
    'Held projects Released and ordinary acceptance supersedes old revision',
    (r) {
      r.load();
      final origin = r.owner.clickModeLifetime;
      final revision = r.owner.clickModeRevision;
      ClickModeOutcome? outcome;
      unawaited(
        r.owner
            .setControllerClickMode(
              ClickMode.playRec,
              lifetime: origin,
              revision: revision,
              releasedMode: ClickMode.off,
            )
            .then((v) => outcome = v),
      );
      r.pump();
      expect(outcome?.isOk, isTrue);
      expect(r.owner.clickModeSnapshot?.mode, ClickMode.playRec);
      expect(r.owner.durableClickMode, ClickMode.off);
      expect(r.store.values['tempo.click_mode'], 0);
      unawaited(r.owner.setClickMode(ClickMode.rec));
      r.pump();
      unawaited(
        r.owner
            .setControllerClickMode(
              ClickMode.off,
              lifetime: origin,
              revision: revision,
            )
            .then((v) => outcome = v),
      );
      r.pump();
      expect(outcome?.status, ClickModeStatus.superseded);
      expect(r.owner.clickModeSnapshot?.mode, ClickMode.rec);
    },
  );
  check('compensated volume rejection is not a permanent flush failure', (r) {
    r.load();
    r.engine.refuseVolume = true;
    ClickVolumeOutcome? outcome;
    unawaited(r.owner.setClickVolume(.5).then((v) => outcome = v));
    r.pump();
    expect(outcome?.status, ClickVolumeStatus.rejected);
    expect(r.owner.clickVolume, 1);
    expect(r.repository.clickVolumeRecoveryRequired, isFalse);
    unawaited(r.owner.flushClickVolume().then((v) => outcome = v));
    r.pump();
    expect(outcome?.isOk, isTrue);
  });
}
