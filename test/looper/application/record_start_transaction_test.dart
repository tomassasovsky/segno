import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/looper/application/tempo_settings.dart';
import 'package:segno/looper/model/record_start.dart';
import 'package:segno_engine/segno_engine.dart' show TrackSnapshot;
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

class _Store extends FakeKeyValueStore {
  Completer<void>? readGate;
  Completer<void>? writeGate;
  bool failRead = false;
  int failWrites = 0;
  @override
  Future<int?> getInt(String key) async {
    if (key == 'tempo.count_in_bars') {
      await readGate?.future;
      if (failRead) throw StateError('checkpoint unavailable');
    }
    return super.getInt(key);
  }

  @override
  Future<void> setBool(String key, {required bool value}) async {
    await super.setBool(key, value: value);
    if (key == 'looper.auto_record') {
      await writeGate?.future;
      if (failWrites > 0) {
        failWrites--;
        throw StateError('second scalar mutated then failed');
      }
    }
  }
}

class _Rig {
  _Rig(this.clock, {Map<String, Object> saved = const {}}) {
    store.values.addAll(saved);
    repository = LooperRepository(engine: engine);
    expect(repository.startEngine(const EngineConfig()), EngineResult.ok);
    owner = TempoSettings(
      repository: repository,
      settings: SettingsRepository(store: store),
    );
  }
  final FakeAsync clock;
  final engine = FakeAudioEngine();
  final store = _Store();
  late final LooperRepository repository;
  late final TempoSettings owner;
  void pump() {
    clock
      ..flushMicrotasks()
      ..elapse(const Duration(milliseconds: 20))
      ..flushMicrotasks();
  }

  void load() {
    unawaited(owner.loadRecordStart());
    pump();
  }

  RecordStartOutcome? edit(Future<RecordStartOutcome> future) {
    RecordStartOutcome? result;
    unawaited(future.then((value) => result = value));
    pump();
    return result;
  }

  void close() {
    engine.commandsAreSettled = true;
    store.readGate?.completeIfPending();
    store.writeGate?.completeIfPending();
    unawaited(owner.close());
    pump();
    unawaited(repository.dispose());
    clock.flushMicrotasks();
  }
}

extension on Completer<void> {
  void completeIfPending() {
    if (!isCompleted) complete();
  }
}

void main() {
  void check(
    String name,
    void Function(_Rig) body, {
    Map<String, Object> saved = const {},
  }) {
    test(
      name,
      () => fakeAsync((clock) {
        final rig = _Rig(clock, saved: saved);
        try {
          body(rig);
        } finally {
          rig.close();
        }
      }),
    );
  }

  for (final entry in [
    (saved: <String, Object>{}, bars: 1, sound: false),
    (saved: <String, Object>{'tempo.count_in_bars': 0}, bars: 0, sound: false),
    (saved: <String, Object>{'looper.auto_record': true}, bars: 0, sound: true),
    (saved: <String, Object>{'tempo.count_in_bars': 4}, bars: 4, sound: false),
  ]) {
    check('strict startup preserves exact membership ${entry.saved}', (r) {
      expect(r.owner.recordStartSnapshot, isNull);
      expect(r.owner.confirmedRecordStart, isNull);
      r.load();
      expect(
        r.owner.recordStartSnapshot?.settings,
        RecordStartSettings(countInBars: entry.bars, soundStart: entry.sound),
      );
      expect(r.store.values, entry.saved);
    }, saved: entry.saved);
  }

  for (final choice in [
    (held: 2, released: 0, liveSound: false, savedSound: false),
    (held: 0, released: 2, liveSound: true, savedSound: false),
  ]) {
    check(
      'controller pair projects Released from accepted Held ${choice.held}',
      (
        r,
      ) {
        r.load();
        final lifetime = r.owner.recordStartLifetime;
        final revision = r.owner.recordStartRevision;
        expect(
          r
              .edit(
                r.owner.setControllerCountIn(
                  choice.held,
                  lifetime: lifetime,
                  revision: revision,
                  releasedBars: choice.released,
                ),
              )
              ?.isOk,
          isTrue,
        );
        expect(
          r.owner.confirmedRecordStart,
          RecordStartSettings(
            countInBars: choice.held,
            soundStart: choice.liveSound,
          ),
        );
        expect(
          r.owner.durableRecordStartSettings,
          RecordStartSettings(
            countInBars: choice.released,
            soundStart: choice.savedSound,
          ),
        );
        expect(r.store.values, {
          'tempo.count_in_bars': choice.released,
          'looper.auto_record': choice.savedSound,
        });
        expect(r.owner.recordStartRevision, revision);
        expect(
          r
              .edit(
                r.owner.setControllerCountIn(
                  choice.released,
                  lifetime: lifetime,
                  revision: revision,
                ),
              )
              ?.isOk,
          isTrue,
        );
        expect(
          r.owner.confirmedRecordStart,
          r.owner.durableRecordStartSettings,
        );
      },
      saved: {'looper.auto_record': true},
    );
  }

  check(
    'ordinary Sound at the same zero count supersedes old controller revision',
    (r) {
      r.load();
      final changes = <RecordStartSettings>[];
      final subscription = r.owner.ordinaryRecordStartChanges.listen(
        changes.add,
      );
      final lifetime = r.owner.recordStartLifetime;
      final revision = r.owner.recordStartRevision;
      expect(
        r
            .edit(
              r.owner.setControllerCountIn(
                0,
                lifetime: lifetime,
                revision: revision,
                releasedBars: 2,
              ),
            )
            ?.isOk,
        isTrue,
      );
      expect(changes, isEmpty);
      expect(r.edit(r.owner.setSoundStart(enabled: true))?.isOk, isTrue);
      expect(r.owner.recordStartRevision, revision + 1);
      expect(changes, [RecordStartSettings(countInBars: 0, soundStart: true)]);
      final requests = r.engine.recordStartRequests.length;
      expect(
        r
            .edit(
              r.owner.setControllerCountIn(
                2,
                lifetime: lifetime,
                revision: revision,
              ),
            )
            ?.status,
        RecordStartStatus.superseded,
      );
      expect(r.engine.recordStartRequests.length, requests);
      expect(
        r.owner.durableRecordStartSettings,
        RecordStartSettings(countInBars: 0, soundStart: true),
      );
      unawaited(subscription.cancel());
    },
    saved: {'looper.auto_record': true},
  );

  check('refused ordinary Sound leaves original controller release eligible', (
    r,
  ) {
    r.load();
    final lifetime = r.owner.recordStartLifetime;
    final revision = r.owner.recordStartRevision;
    expect(
      r
          .edit(
            r.owner.setControllerCountIn(
              0,
              lifetime: lifetime,
              revision: revision,
              releasedBars: 2,
            ),
          )
          ?.isOk,
      isTrue,
    );
    r.engine.recordStartResult = EngineResult.invalid;
    expect(
      r.edit(r.owner.setSoundStart(enabled: true))?.status,
      RecordStartStatus.rejected,
    );
    expect(r.owner.recordStartRevision, revision);
    expect(
      r.owner.durableRecordStartSettings,
      RecordStartSettings(countInBars: 2, soundStart: false),
    );
    r.engine.recordStartResult = EngineResult.ok;
    expect(
      r
          .edit(
            r.owner.setControllerCountIn(
              2,
              lifetime: lifetime,
              revision: revision,
            ),
          )
          ?.isOk,
      isTrue,
    );
    expect(
      r.owner.confirmedRecordStart,
      RecordStartSettings(countInBars: 2, soundStart: false),
    );
  }, saved: {'looper.auto_record': true});

  check(
    'controller failure preserves older Held and exact Released checkpoint',
    (r) {
      r.load();
      final lifetime = r.owner.recordStartLifetime;
      final revision = r.owner.recordStartRevision;
      expect(
        r
            .edit(
              r.owner.setControllerCountIn(
                2,
                lifetime: lifetime,
                revision: revision,
                releasedBars: 0,
              ),
            )
            ?.isOk,
        isTrue,
      );
      r.store.failWrites = 1;
      expect(
        r
            .edit(
              r.owner.setControllerCountIn(
                4,
                lifetime: lifetime,
                revision: revision,
                releasedBars: 1,
              ),
            )
            ?.status,
        RecordStartStatus.rejected,
      );
      expect(
        r.owner.confirmedRecordStart,
        RecordStartSettings(countInBars: 2, soundStart: false),
      );
      expect(
        r.owner.durableRecordStartSettings,
        RecordStartSettings(countInBars: 0, soundStart: false),
      );
      expect(r.store.values, {
        'tempo.count_in_bars': 0,
        'looper.auto_record': false,
      });
      expect(r.owner.recordStartRevision, revision);
    },
  );

  check('device restart applies Released and refuses the retired lifetime', (
    r,
  ) {
    r.load();
    final lifetime = r.owner.recordStartLifetime;
    final revision = r.owner.recordStartRevision;
    expect(
      r
          .edit(
            r.owner.setControllerCountIn(
              2,
              lifetime: lifetime,
              revision: revision,
              releasedBars: 0,
            ),
          )
          ?.isOk,
      isTrue,
    );
    r.repository.stopEngine();
    expect(r.repository.startEngine(const EngineConfig()), EngineResult.ok);
    r.pump();
    expect(
      r.owner.confirmedRecordStart,
      RecordStartSettings(countInBars: 0, soundStart: false),
    );
    final requests = r.engine.recordStartRequests.length;
    expect(
      r
          .edit(
            r.owner.setControllerCountIn(
              4,
              lifetime: lifetime,
              revision: revision,
            ),
          )
          ?.status,
      RecordStartStatus.superseded,
    );
    expect(r.engine.recordStartRequests.length, requests);
  });

  check('capture refusal retains Released until same-origin release succeeds', (
    r,
  ) {
    r.load();
    final lifetime = r.owner.recordStartLifetime;
    final revision = r.owner.recordStartRevision;
    expect(
      r
          .edit(
            r.owner.setControllerCountIn(
              2,
              lifetime: lifetime,
              revision: revision,
              releasedBars: 0,
            ),
          )
          ?.isOk,
      isTrue,
    );
    final prior = r.engine.nextSnapshot;
    r.engine.nextSnapshot = prior.copyWith(
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
        ...prior.tracks.skip(1),
      ],
    );
    final stops = r.engine.stopCalls;
    expect(
      r
          .edit(
            r.owner.setControllerCountIn(
              0,
              lifetime: lifetime,
              revision: revision,
            ),
          )
          ?.status,
      RecordStartStatus.rejected,
    );
    expect(r.engine.stopCalls, stops);
    expect(r.owner.confirmedRecordStart?.countInBars, 2);
    expect(r.owner.durableRecordStartSettings.countInBars, 0);
    r.engine.nextSnapshot = prior;
    expect(
      r
          .edit(
            r.owner.setControllerCountIn(
              0,
              lifetime: lifetime,
              revision: revision,
            ),
          )
          ?.isOk,
      isTrue,
    );
    expect(r.owner.confirmedRecordStart?.countInBars, 0);
  });

  check(
    'blocked controller write compensates storage without crossing session',
    (r) {
      r.load();
      final lifetime = r.owner.recordStartLifetime;
      final revision = r.owner.recordStartRevision;
      r.store.writeGate = Completer<void>();
      RecordStartOutcome? outcome;
      unawaited(
        r.owner
            .setControllerCountIn(
              2,
              lifetime: lifetime,
              revision: revision,
              releasedBars: 0,
            )
            .then((value) => outcome = value),
      );
      r.pump();
      expect(outcome, isNull);
      r.repository.stopEngine();
      var replaced = false;
      unawaited(
        r.repository
            .applySession(
              const SessionRig(
                countInBars: 4,
              ),
            )
            .then((_) => replaced = true),
      );
      r.pump();
      expect(replaced, isTrue);
      r.store.writeGate!.complete();
      r.pump();
      expect(outcome?.status, RecordStartStatus.superseded);
      expect(
        r.owner.confirmedRecordStart,
        RecordStartSettings(countInBars: 4, soundStart: false),
      );
      expect(
        r.owner.durableRecordStartSettings,
        RecordStartSettings(countInBars: 4, soundStart: false),
      );
      expect(r.store.values, {'looper.auto_record': true});
      final requests = r.engine.recordStartRequests.length;
      expect(
        r
            .edit(
              r.owner.setControllerCountIn(
                0,
                lifetime: lifetime,
                revision: revision,
              ),
            )
            ?.status,
        RecordStartStatus.superseded,
      );
      expect(r.engine.recordStartRequests.length, requests);
    },
    saved: {'looper.auto_record': true},
  );

  check('non-held controller acceptance replaces older durable Released', (r) {
    r.load();
    final lifetime = r.owner.recordStartLifetime;
    final revision = r.owner.recordStartRevision;
    expect(
      r
          .edit(
            r.owner.setControllerCountIn(
              2,
              lifetime: lifetime,
              revision: revision,
              releasedBars: 0,
            ),
          )
          ?.isOk,
      isTrue,
    );
    expect(
      r
          .edit(
            r.owner.setControllerCountIn(
              4,
              lifetime: lifetime,
              revision: revision,
            ),
          )
          ?.isOk,
      isTrue,
    );
    expect(r.owner.confirmedRecordStart?.countInBars, 4);
    expect(r.owner.durableRecordStartSettings.countInBars, 4);
    expect(r.store.values['tempo.count_in_bars'], 4);
  });

  check('ordinary pair edits preserve Count Off versus Sound off intent', (r) {
    r.load();
    expect(r.edit(r.owner.setSoundStart(enabled: true))?.isOk, isTrue);
    expect(r.edit(r.owner.setCountInBars(0))?.isOk, isTrue);
    expect(
      r.owner.confirmedRecordStart,
      RecordStartSettings(countInBars: 0, soundStart: true),
    );
    expect(r.edit(r.owner.setCountInBars(2))?.isOk, isTrue);
    expect(r.edit(r.owner.setSoundStart(enabled: false))?.isOk, isTrue);
    expect(
      r.owner.confirmedRecordStart,
      RecordStartSettings(countInBars: 2, soundStart: false),
    );
    expect(r.engine.recordStartRequests.takeLast(4).map((v) => v.editKind), [
      RecordStartEditKind.sound,
      RecordStartEditKind.countIn,
      RecordStartEditKind.countIn,
      RecordStartEditKind.sound,
    ]);
    expect(
      r.edit(r.owner.setCountInBars(-1))?.status,
      RecordStartStatus.rejected,
    );
    expect(r.store.values, {
      'tempo.count_in_bars': 2,
      'looper.auto_record': false,
    });
  });

  check('native refusal restores independent absence and healthy flush', (r) {
    r.load();
    r.engine.recordStartResult = EngineResult.invalid;
    expect(
      r.edit(r.owner.setCountInBars(4))?.status,
      RecordStartStatus.rejected,
    );
    expect(r.store.values, isEmpty);
    expect(r.owner.confirmedRecordStart?.countInBars, 1);
    expect(r.repository.recordStartRecoveryRequired, isFalse);
    expect(r.edit(r.owner.flushRecordStart())?.isOk, isTrue);
  });

  check('partial second scalar write restores complete checkpoint', (r) {
    r.load();
    r.store.failWrites = 1;
    expect(
      r.edit(r.owner.setCountInBars(4))?.status,
      RecordStartStatus.rejected,
    );
    expect(r.store.values, {'looper.auto_record': true});
    expect(
      r.owner.confirmedRecordStart,
      RecordStartSettings(countInBars: 0, soundStart: true),
    );
    expect(r.edit(r.owner.flushRecordStart())?.isOk, isTrue);
  }, saved: {'looper.auto_record': true});

  check('failed rollback retains repair obligation until explicit retry', (r) {
    r.load();
    r.store.failWrites = 2;
    expect(
      r.edit(r.owner.setCountInBars(4))?.status,
      RecordStartStatus.recoveryRequired,
    );
    expect(r.owner.recordStartSnapshot, isNull);
    expect(r.owner.confirmedRecordStart?.soundStart, isTrue);
    expect(r.edit(r.owner.flushRecordStart())?.isOk, isFalse);
    expect(r.edit(r.owner.recoverRecordStart())?.isOk, isTrue);
    expect(r.store.values, {'looper.auto_record': true});
    expect(r.owner.recordStartSnapshot?.settings.soundStart, isTrue);
  }, saved: {'looper.auto_record': true});

  check('store barrier precedes native pair and confirmed publication', (r) {
    r.load();
    final requests = r.engine.recordStartRequests.length;
    r.store.writeGate = Completer<void>();
    RecordStartOutcome? result;
    unawaited(r.owner.setCountInBars(4).then((value) => result = value));
    r.pump();
    expect(result, isNull);
    expect(r.engine.recordStartRequests.length, requests);
    expect(r.owner.confirmedRecordStart?.countInBars, 1);
    r.store.writeGate!.complete();
    r.pump();
    expect(result?.isOk, isTrue);
    expect(r.owner.confirmedRecordStart?.countInBars, 4);
  });

  check('raw pair publication cannot precede acquired receipt', (r) {
    r.load();
    final revision = r.owner.recordStartRevision;
    final changes = <RecordStartSettings>[];
    final subscription = r.owner.ordinaryRecordStartChanges.listen(changes.add);
    r.engine.commandsAreSettled = false;
    RecordStartOutcome? result;
    unawaited(r.owner.setCountInBars(4).then((value) => result = value));
    r.pump();
    expect(result, isNull);
    expect(changes, isEmpty);
    expect(r.owner.recordStartRevision, revision);
    expect(r.engine.nextSnapshot.countInBars, 4);
    expect(r.repository.state.transport.countInBars, 1);
    expect(r.owner.confirmedRecordStart?.countInBars, 1);
    r.engine.commandsAreSettled = true;
    r.pump();
    expect(result?.isOk, isTrue);
    expect(r.owner.recordStartRevision, revision + 1);
    expect(changes, [RecordStartSettings(countInBars: 4, soundStart: false)]);
    unawaited(subscription.cancel());
    expect(r.owner.confirmedRecordStart?.countInBars, 4);
  });

  check('same-value timeout blocks flush and offers persistent recovery', (r) {
    r.load();
    r.engine.publishRecordStartCommands = false;
    final failures = <RecordStartOutcome>[];
    final subscription = r.owner.recordStartFailures.listen(failures.add);
    unawaited(r.owner.setCountInBars(1));
    r.pump();
    r.clock.elapse(const Duration(milliseconds: 550));
    r.pump();
    expect(r.repository.recordStartRecoveryRequired, isTrue);
    expect(r.owner.recordStartSnapshot, isNull);
    expect(
      failures.any((v) => v.status == RecordStartStatus.recoveryRequired),
      isTrue,
    );
    expect(r.edit(r.owner.flushRecordStart())?.isOk, isFalse);
    unawaited(subscription.cancel());
  });

  check('malformed pair remains unready and raw data survives retry', (r) {
    r.load();
    expect(r.owner.recordStartSnapshot, isNull);
    expect(
      r.edit(r.owner.recoverRecordStart())?.status,
      RecordStartStatus.recoveryRequired,
    );
    expect(r.store.values, {
      'tempo.count_in_bars': 2,
      'looper.auto_record': true,
    });
  }, saved: {'tempo.count_in_bars': 2, 'looper.auto_record': true});

  check('old failed write repairs storage without replaying into replacement', (
    r,
  ) {
    r.load();
    r.store
      ..writeGate = Completer<void>()
      ..failWrites = 2;
    RecordStartOutcome? outcome;
    unawaited(r.owner.setCountInBars(4).then((value) => outcome = value));
    r.pump();
    expect(outcome, isNull);
    r.repository.stopEngine();
    var replaced = false;
    unawaited(
      r.repository
          .applySession(const SessionRig())
          .then((_) => replaced = true),
    );
    r.pump();
    expect(replaced, isTrue);
    r.store.writeGate!.complete();
    r.pump();
    expect(outcome?.status, RecordStartStatus.recoveryRequired);
    expect(r.repository.recordStartSettings, (
      countInBars: 0,
      soundStart: false,
    ));
    expect(r.repository.recordStartRecoveryRequired, isFalse);
    expect(r.owner.recordStartSnapshot, isNull);
    expect(r.edit(r.owner.recoverRecordStart())?.isOk, isTrue);
    expect(r.store.values, {'looper.auto_record': true});
    expect(
      r.owner.recordStartSnapshot?.settings,
      RecordStartSettings(countInBars: 0, soundStart: false),
    );
    expect(r.repository.recordStartRestartIntent, (
      countInBars: 0,
      soundStart: false,
    ));
  }, saved: {'looper.auto_record': true});

  check('obsolete failed startup adopts accepted replacement session', (r) {
    r.store.readGate = Completer<void>();
    unawaited(r.owner.loadRecordStart());
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
    r.store.readGate!.complete();
    r.pump();
    expect(
      r.owner.recordStartSnapshot?.settings,
      RecordStartSettings(countInBars: 0, soundStart: false),
    );
  });
}

extension<T> on List<T> {
  Iterable<T> takeLast(int count) => skip(length - count);
}
