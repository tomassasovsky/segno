import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:segno/app/fx_chain_persistence.dart';
import 'package:segno/control/binding/control_value_target.dart';
import 'package:segno/control/binding/fx_binding_target.dart';
import 'package:settings_repository/settings_repository.dart';

import '../helpers/fake_key_value_store.dart';

class _Looper extends Mock implements LooperRepository {}

class _ControlledStore extends FakeKeyValueStore {
  bool refuse = false;
  int writes = 0;
  Completer<void>? blocked;
  final entered = Completer<void>();

  @override
  Future<void> setString(String key, String value) async {
    if (key == 'track_fx_chain.0') {
      writes++;
      if (!entered.isCompleted) entered.complete();
      await blocked?.future;
      if (refuse) throw StateError('Storage refused');
    }
    await super.setString(key, value);
  }
}

class _BootStore extends FakeKeyValueStore {
  bool failAfterTrackWrite = false;
  Completer<void>? blockedTrack;
  final trackEntered = Completer<void>();

  @override
  Future<void> setString(String key, String value) async {
    await super.setString(key, value);
    if (key == 'track_fx_chain.0' && failAfterTrackWrite) {
      if (!trackEntered.isCompleted) trackEntered.complete();
      await blockedTrack?.future;
      failAfterTrackWrite = false;
      throw StateError('boot write reached storage before refusal');
    }
  }
}

void main() {
  const address = FxAddress(stage: FxStage.track);
  const target = FxParamTarget(address: address, slotId: 'drive', param: 0);
  late _Looper looper;
  late FxChainPersistence projection;
  late SettingsRepository settings;
  late BuiltInEffect held;
  setUp(() {
    looper = _Looper();
    when(() => looper.sessionRevision).thenReturn(1);
    when(() => looper.mixGeneration).thenReturn(1);
    when(() => looper.fxRecipesSettled).thenReturn(true);
    when(
      () => looper.fxReplayConfirmed,
    ).thenAnswer((_) => const Stream.empty());
    held = BuiltInEffect(
      type: TrackEffectType.drive,
      slotId: 'drive',
      params: const [.8, .4, .5],
    );
    when(() => looper.trackEffects(0)).thenReturn([held]);
    when(() => looper.trackChainEnabled(0)).thenReturn(true);
    projection = FxChainPersistence(looper: looper);
    settings = SettingsRepository(store: FakeKeyValueStore());
  });

  tearDown(() => projection.close());

  void stubLoadedRig({bool withTrackFx = false}) {
    when(() => looper.state).thenReturn(
      const LooperState(tracks: [Track()]),
    );
    when(looper.allLaneChains).thenReturn(const {});
    when(looper.allTrackChains).thenReturn(
      withTrackFx
          ? {
              0: FxChainEnvelope(entries: [held]),
            }
          : const {},
    );
    when(looper.allOutputChains).thenReturn(const {});
    when(looper.allTracksChainEnvelope).thenReturn(const FxChainEnvelope());
    when(looper.allMonitors).thenReturn(const {});
  }

  test(
    'session boot image clears absent FX and monitor keys before unlock',
    () async {
      stubLoadedRig();
      await settings.saveLaneEffects(0, 0, 'old lane');
      await settings.saveLaneEffects(7, 0, 'old high lane');
      await settings.saveTrackFxChain(0, 'old track');
      await settings.saveTrackFxChain(7, 'old high track');
      await settings.saveOutputFxChain(0, 'old output');
      await settings.saveMonitorInputMode(2, mode: 'on');
      await settings.saveMonitorOutput(2, 2);
      await settings.saveMonitorMute(2, muted: true);
      await settings.saveMonitorEffects(2, 'old monitor FX');

      projection.reserveSessionLoad();
      expect(projection.sessionTransitionActive, isTrue);
      await projection.beginSessionLoad();
      await projection.persistLoadedSession(settings);
      expect(projection.sessionBootRecoveryRequired, isTrue);
      expect(await settings.loadLaneEffects(0, 0), isNull);
      expect(await settings.loadLaneEffects(7, 0), isNull);
      expect(await settings.loadTrackFxChain(0), isNull);
      expect(await settings.loadTrackFxChain(7), isNull);
      expect(await settings.loadOutputFxChain(0), isNull);
      expect(await settings.loadMonitorInputMode(2), 'off');
      expect(await settings.loadMonitorOutput(2), 3);
      expect(await settings.loadMonitorMute(2), isFalse);
      expect(
        await settings.loadMonitorEffects(2),
        encodeFxChain(const FxChainEnvelope()),
      );
      projection.completeSessionBoot();
      expect(projection.sessionTransitionActive, isFalse);
    },
  );

  test('mutated boot write retains the exact image for retry', () async {
    stubLoadedRig(withTrackFx: true);
    final store = _BootStore()..failAfterTrackWrite = true;
    final bootSettings = SettingsRepository(store: store);
    projection.reserveSessionLoad();
    await projection.beginSessionLoad();
    await expectLater(
      projection.persistLoadedSession(bootSettings),
      throwsStateError,
    );
    expect(projection.sessionBootRecoveryRequired, isTrue);
    expect(projection.sessionTransitionActive, isTrue);
    expect(await bootSettings.loadTrackFxChain(0), isNotNull);
    when(looper.allTrackChains).thenReturn(const {});

    await projection.retrySessionBoot();
    final recovered = decodeFxChain(await bootSettings.loadTrackFxChain(0));
    final effect = recovered.entries.single as BuiltInEffect;
    expect(effect.slotId, 'drive');
    expect(effect.params.first, .8);
    projection.completeSessionBoot();
    expect(projection.sessionBootRecoveryRequired, isFalse);
  });

  test(
    'flush waiting before a boot refusal receives recovery failure',
    () async {
      stubLoadedRig(withTrackFx: true);
      final store = _BootStore()
        ..failAfterTrackWrite = true
        ..blockedTrack = Completer<void>();
      final bootSettings = SettingsRepository(store: store);
      projection.reserveSessionLoad();
      await projection.beginSessionLoad();
      var flushSettled = false;
      final flush = expectLater(
        projection.flush().whenComplete(() => flushSettled = true),
        throwsStateError,
      );
      await Future<void>.delayed(Duration.zero);
      expect(flushSettled, isFalse);
      final boot = projection.persistLoadedSession(bootSettings);
      await store.trackEntered.future;
      store.blockedTrack!.complete();
      await expectLater(boot, throwsStateError);
      projection.markSessionBootFailed();
      await flush;
      expect(projection.sessionTransitionActive, isTrue);
      expect(projection.sessionBootRecoveryRequired, isTrue);
    },
  );

  test('scheduled edits coalesce and flush before the timer fires', () async {
    final store = _ControlledStore();
    final settings = SettingsRepository(store: store);
    projection.scheduleSave(address, settings);
    held = held.copyWith(params: const [.3, .4, .5]);
    when(() => looper.trackEffects(0)).thenReturn([held]);
    projection.scheduleSave(address, settings);
    expect(store.writes, 0);
    await projection.flush();
    expect(store.writes, 1);
    final saved = decodeFxChain(await settings.loadTrackFxChain(0));
    expect((saved.entries.single as BuiltInEffect).params.first, .3);
  });

  test('closing a UI owner starts saves but retains storage failure', () async {
    final store = _ControlledStore()..refuse = true;
    final settings = SettingsRepository(store: store);
    projection
      ..scheduleSave(
        address,
        settings,
        debounce: const Duration(minutes: 1),
      )
      ..flushScheduled();
    await pumpEventQueue();
    expect(store.writes, 1);
    await expectLater(projection.flush(), throwsStateError);
    store.refuse = false;
    await projection.flush();
    expect(store.writes, 3);
    expect(await settings.loadTrackFxChain(0), isNotNull);
  });

  test('session replacement retires scheduled old-session edits', () async {
    final store = _ControlledStore();
    projection.scheduleSave(address, SettingsRepository(store: store));
    when(() => looper.sessionRevision).thenReturn(2);
    await projection.flush();
    expect(store.writes, 0);
  });

  test('scheduled failure is retained and flush retries it', () async {
    final store = _ControlledStore()..refuse = true;
    projection.scheduleSave(address, SettingsRepository(store: store));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(store.writes, 1);
    await expectLater(projection.flush(), throwsStateError);
    store.refuse = false;
    await projection.flush();
    expect(store.writes, 3);
  });

  test(
    'settings wait for accepted projection and retain unrelated fields',
    () async {
      final ticket = projection.beginPending();
      final saving = saveTrackFxChain(
        settings: settings,
        looper: looper,
        projection: projection,
        channel: 0,
      );
      await Future<void>.delayed(Duration.zero);
      expect(await settings.loadTrackFxChain(0), isNull);
      projection
        ..replace(
          powers: {const FxChainTarget(address): false},
          parameters: {target: .2},
        )
        ..finishPending(ticket);
      await saving;
      final saved = decodeFxChain(await settings.loadTrackFxChain(0));
      expect(saved.chainEnabled, isFalse);
      final effect = saved.entries.single as BuiltInEffect;
      expect(effect.params, [.2, .4, .5, 0]);
      expect(effect.slotId, 'drive');
      expect(held.params.first, .8);
    },
  );

  test('refused pending recipe leaves accepted projection intact', () async {
    projection.replace(powers: const {}, parameters: {target: .2});
    final ticket = projection.beginPending();
    final saving = saveTrackFxChain(
      settings: settings,
      looper: looper,
      projection: projection,
      channel: 0,
    );
    projection.finishPending(ticket);
    await saving;
    expect(
      (decodeFxChain(await settings.loadTrackFxChain(0)).entries.single
              as BuiltInEffect)
          .params
          .first,
      .2,
    );
  });

  test('ordinary equal target supersedes only its explicit override', () {
    projection
      ..replace(
        powers: {const FxChainTarget(address): false},
        parameters: {target: .2},
      )
      ..ordinaryWrite(target, .8);
    final result = projection.project(
      address,
      FxChainEnvelope(entries: [held]),
    );
    expect(result.chainEnabled, isFalse);
    expect((result.entries.single as BuiltInEffect).params.first, .8);
  });

  test('session replacement cancels stale awaited settings capture', () async {
    final ticket = projection.beginPending();
    final saving = saveTrackFxChain(
      settings: settings,
      looper: looper,
      projection: projection,
      channel: 0,
    );
    when(() => looper.sessionRevision).thenReturn(2);
    projection.finishPending(ticket);
    await saving;
    expect(await settings.loadTrackFxChain(0), isNull);
  });

  for (final bootBlocked in [false, true]) {
    test('close drains tracked saves without releasing receipts '
        '(boot blocked $bootBlocked)', () async {
      if (bootBlocked) {
        projection.reserveSessionLoad();
        await projection.beginSessionLoad();
        projection.markSessionBootFailed();
        await expectLater(projection.flush(), throwsStateError);
      }
      final ticket = projection.beginPending();
      final store = _ControlledStore()..blocked = Completer<void>();
      final settings = SettingsRepository(store: store);
      if (bootBlocked) {
        // This drain is already waiting on the owner's own boot barrier.
        projection.scheduleSave(address, settings, debounce: Duration.zero);
      }
      final saving = saveTrackFxChain(
        settings: settings,
        looper: looper,
        projection: projection,
        channel: 0,
      );
      var closed = false;
      final closing = projection.close().then((_) => closed = true);
      await pumpEventQueue();
      final writesBeforeReceipt = store.writes;
      final closedBeforeReceipt = closed;
      projection.finishPending(ticket);
      await store.entered.future;
      await pumpEventQueue();
      final closedBeforeStorage = closed;
      store.blocked!.complete();
      await saving;
      await closing;
      expect(writesBeforeReceipt, 0);
      expect(closedBeforeReceipt, isFalse);
      expect(closedBeforeStorage, isFalse);
      expect(store.writes, 1);
      expect(await settings.loadTrackFxChain(0), isNotNull);
    });
  }

  test('close drains another admitted save even when one fails', () async {
    final owner = FxChainPersistence(looper: looper);
    final failed = Completer<void>();
    final failure = expectLater(
      owner.trackSave(failed.future),
      throwsStateError,
    );
    final store = _ControlledStore()..blocked = Completer<void>();
    final saving = saveTrackFxChain(
      settings: SettingsRepository(store: store),
      looper: looper,
      projection: owner,
      channel: 0,
    );
    await store.entered.future;
    var closed = false;
    final closing = expectLater(
      owner.close().whenComplete(() => closed = true),
      throwsStateError,
    );
    failed.completeError(StateError('first save failed'));
    await failure;
    await pumpEventQueue();
    final closedBeforeStorage = closed;
    store.blocked!.complete();
    await saving;
    await closing;
    expect(closedBeforeStorage, isFalse);
    expect(store.writes, 1);
  });

  test('a disposed owner rejects a newly submitted FX save', () async {
    final store = _ControlledStore();
    await projection.close();
    await saveTrackFxChain(
      settings: SettingsRepository(store: store),
      looper: looper,
      projection: projection,
      channel: 0,
    );
    expect(store.writes, 0);
  });

  test('shutdown waits for projection and delayed durable save', () async {
    final ticket = projection.beginPending();
    final storage = Completer<void>();
    final save = projection.trackSave(() async {
      await projection.settlePending();
      await storage.future;
    }());
    var halted = false;
    final flush = projection.flush().then((_) => halted = true);
    await Future<void>.delayed(Duration.zero);
    expect(halted, isFalse);
    projection.finishPending(ticket);
    await Future<void>.delayed(Duration.zero);
    expect(halted, isFalse);
    storage.complete();
    await save;
    await flush;
    expect(halted, isTrue);
  });
  test(
    'failed chain stays dirty and shutdown refuses until retry saves it',
    () async {
      final store = _ControlledStore()..refuse = true;
      settings = SettingsRepository(store: store);
      await expectLater(
        projection.saveConfirmed(address, settings),
        throwsStateError,
      );
      await expectLater(projection.flush(), throwsStateError);
      expect(await settings.loadTrackFxChain(0), isNull);
      store.refuse = false;
      await projection.flush();
      expect(
        (decodeFxChain(await settings.loadTrackFxChain(0)).entries.single
                as BuiltInEffect)
            .params,
        [.8, .4, .5, 0],
      );
    },
  );

  test('a newer edit during a blocked write saves the latest chain', () async {
    final store = _ControlledStore()..blocked = Completer<void>();
    settings = SettingsRepository(store: store);
    final first = projection.saveConfirmed(address, settings);
    await store.entered.future;
    final next = held.copyWith(params: [.3, .4, .5]);
    when(() => looper.trackEffects(0)).thenReturn([next]);
    final second = projection.saveConfirmed(address, settings);
    store.blocked!.complete();
    await Future.wait([first, second]);
    await projection.flush();
    expect(
      (decodeFxChain(await settings.loadTrackFxChain(0)).entries.single
              as BuiltInEffect)
          .params,
      [.3, .4, .5, 0],
    );
  });

  test(
    'old session dirty writes cannot overwrite a replacement session',
    () async {
      final store = _ControlledStore()..refuse = true;
      settings = SettingsRepository(store: store);
      await expectLater(
        projection.saveConfirmed(address, settings),
        throwsStateError,
      );
      when(() => looper.sessionRevision).thenReturn(2);
      store.refuse = false;
      await projection.flush();
      expect(await settings.loadTrackFxChain(0), isNull);
    },
  );

  test(
    'input save preserves routing and mute with Released parameters',
    () async {
      const input = FxAddress(stage: FxStage.input, index: 2);
      when(looper.allMonitors).thenReturn({
        2: InputMonitor(
          input: 2,
          mode: MonitorMode.on,
          outputMask: 4,
          muted: true,
          effects: [held],
        ),
      });
      when(() => looper.monitorEffects(2)).thenReturn([held]);
      when(() => looper.monitorChainEnabled(2)).thenReturn(true);
      projection.replace(
        powers: {},
        parameters: {
          const FxParamTarget(address: input, slotId: 'drive', param: 0): .25,
        },
      );
      await projection.saveConfirmed(input, settings);
      expect(await settings.loadMonitorInputMode(2), 'on');
      expect(await settings.loadMonitorOutput(2), 4);
      expect(await settings.loadMonitorMute(2), isTrue);
      final saved = decodeFxChain(await settings.loadMonitorEffects(2));
      expect((saved.entries.single as BuiltInEffect).params.first, .25);
      expect(held.params.first, .8);
    },
  );
  test('replacement session edit survives an old pending receipt', () async {
    final oldReceipt = Completer<EngineResult>();
    when(() => looper.fxRecipesSettled).thenReturn(false);
    when(
      () => looper.settleFxRecipes(
        waitForCallback: true,
        cancelled: any(named: 'cancelled'),
      ),
    ).thenAnswer((_) => oldReceipt.future);
    final oldSave = projection.saveConfirmed(address, settings);
    await Future<void>.delayed(Duration.zero);
    when(() => looper.sessionRevision).thenReturn(2);
    when(() => looper.fxRecipesSettled).thenReturn(true);
    when(() => looper.trackEffects(0)).thenReturn([
      held.copyWith(params: [.1, .4, .5]),
    ]);
    final newSave = projection.saveConfirmed(address, settings);
    oldReceipt.complete(EngineResult.ok);
    await Future.wait([oldSave, newSave]);
    expect(
      (decodeFxChain(await settings.loadTrackFxChain(0)).entries.single
              as BuiltInEffect)
          .params,
      [.1, .4, .5, 0],
    );
  });

  test(
    'confirmed replay retries storage failure without another editor write',
    () async {
      final replays =
          StreamController<
            ({int mixGeneration, int sessionRevision})
          >.broadcast();
      when(() => looper.fxReplayConfirmed).thenAnswer((_) => replays.stream);
      final store = _ControlledStore()..refuse = true;
      settings = SettingsRepository(store: store);
      await expectLater(
        projection.saveConfirmed(address, settings),
        throwsStateError,
      );
      store.refuse = false;
      replays.add((mixGeneration: 1, sessionRevision: 1));
      await Future<void>.delayed(Duration.zero);
      expect(
        (decodeFxChain(await settings.loadTrackFxChain(0)).entries.single
                as BuiltInEffect)
            .params,
        [.8, .4, .5, 0],
      );
      await projection.close();
      expect(replays.hasListener, isFalse);
      await replays.close();
    },
  );
  test('edits waiting for one receipt persist only the final chain', () async {
    final receipt = Completer<EngineResult>();
    when(() => looper.fxRecipesSettled).thenReturn(false);
    when(
      () => looper.settleFxRecipes(
        waitForCallback: true,
        cancelled: any(named: 'cancelled'),
      ),
    ).thenAnswer((_) => receipt.future);
    final store = _ControlledStore();
    settings = SettingsRepository(store: store);
    final first = projection.saveConfirmed(address, settings);
    when(() => looper.trackEffects(0)).thenReturn([
      held.copyWith(params: [.6, .4, .5]),
    ]);
    final second = projection.saveConfirmed(address, settings);
    expect(store.writes, 0);
    when(() => looper.fxRecipesSettled).thenReturn(true);
    receipt.complete(EngineResult.ok);
    await Future.wait([first, second]);
    expect(store.writes, 1);
    expect(
      (decodeFxChain(await settings.loadTrackFxChain(0)).entries.single
              as BuiltInEffect)
          .params,
      [.6, .4, .5, 0],
    );
  });
}
