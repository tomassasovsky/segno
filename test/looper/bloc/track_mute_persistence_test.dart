import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/app/audio_bootstrap.dart';
import 'package:segno/app/fx_chain_persistence.dart';
import 'package:segno/app/track_mute.dart';
import 'package:segno/looper/looper.dart';
import 'package:segno_engine/segno_engine.dart' as le;
import 'package:session_repository/session_repository.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

class _MuteEngine extends FakeAudioEngine {
  int? refuseLane;

  @override
  EngineResult setLaneMute({
    required bool muted,
    int channel = 0,
    int lane = 0,
  }) => lane == refuseLane
      ? EngineResult.invalid
      : super.setLaneMute(muted: muted, channel: channel, lane: lane);
}

class _MuteStore extends FakeKeyValueStore {
  Completer<void>? blocked;
  final entered = Completer<void>();
  bool failAfterWrite = false;
  int muteWrites = 0;
  Completer<void>? blockedEffects;
  final effectsEntered = Completer<void>();

  @override
  Future<void> setString(String key, String value) async {
    if (key == 'lane_effects.0.0' && !effectsEntered.isCompleted) {
      effectsEntered.complete();
      await blockedEffects?.future;
    }
    await super.setString(key, value);
  }

  @override
  Future<void> setBool(String key, {required bool value}) async {
    if (key == 'lane_mute.0.0') {
      muteWrites++;
      if (!entered.isCompleted) entered.complete();
      await blocked?.future;
      await super.setBool(key, value: value);
      if (failAfterWrite) throw StateError('mute wrote then failed');
      return;
    }
    await super.setBool(key, value: value);
  }
}

class _RecordedMuteEngine extends FakeAudioEngine {
  _RecordedMuteEngine() {
    laneExports[(0, 0)] = Float32List.fromList([0.1, 0.2, 0.3, 0.4]);
    _publishMute(false);
  }

  void _publishMute(bool muted) {
    nextSnapshot = nextSnapshot.copyWith(
      tracks: [
        le.TrackSnapshot(
          state: le.TrackState.playing,
          volume: 1,
          muted: muted,
          lengthFrames: 4,
          undoDepth: 0,
          rms: 0,
          peak: 0,
          lanes: [
            le.LaneSnapshot(
              inputChannel: 0,
              outputMask: 3,
              volume: 1,
              muted: muted,
              lengthFrames: 4,
              rms: 0,
              peak: 0,
            ),
          ],
        ),
        for (var i = 1; i < 8; i++) const le.TrackSnapshot.empty(),
      ],
    );
  }

  @override
  EngineResult setLaneMute({
    required bool muted,
    int channel = 0,
    int lane = 0,
  }) {
    final result = super.setLaneMute(
      muted: muted,
      channel: channel,
      lane: lane,
    );
    if (channel == 0 && lane == 0 && result.isOk) _publishMute(muted);
    return result;
  }
}

void main() {
  group('shared track mute operation', () {
    late _MuteEngine engine;
    late LooperRepository repository;
    late _MuteStore store;
    late SettingsRepository settings;
    late FxChainPersistence fx;
    late List<Object> errors;
    var closeFailureExpected = false;

    setUp(() {
      engine = _MuteEngine();
      repository = LooperRepository(
        engine: engine,
        ticker: const Stream<void>.empty(),
      )..startEngine(const EngineConfig());
      store = _MuteStore();
      settings = SettingsRepository(store: store);
      fx = FxChainPersistence(looper: repository);
      errors = [];
      closeFailureExpected = false;
    });

    tearDown(() async {
      store.failAfterWrite = false;
      if (closeFailureExpected) {
        await expectLater(fx.close(), throwsStateError);
      } else {
        await fx.close();
      }
      await repository.dispose();
    });

    EngineResult mute({required bool muted, int? lane}) => applyTrackMute(
      looper: repository,
      settings: settings,
      persistence: fx,
      channel: 0,
      lane: lane,
      muted: muted,
      onError: (error, _) => errors.add(error),
    );

    Future<void> coldMute({required bool expected, String? effects}) async {
      await settings.saveAudioConfig(
        const StoredAudioConfig(sampleRate: 48000, bufferFrames: 128),
      );
      final freshEngine = FakeAudioEngine();
      final fresh = LooperRepository(
        engine: freshEngine,
        ticker: const Stream<void>.empty(),
      );
      final freshMix = testMixSettings(fresh, settings: settings);
      addTearDown(() async {
        await freshMix.close();
        await fresh.dispose();
      });
      final boot = await tryAutoStartEngine(
        repository: fresh,
        settings: settings,
        mixSettings: freshMix,
      );
      expect(boot.started, isTrue);
      expect(freshEngine.laneMute[(0, 0)], expected);
      if (effects != null) {
        expect(encodeFxChain(fresh.allLaneChains()[(0, 0)]!), effects);
      }
    }

    LooperBloc attachLooper() {
      final mix = testMixSettings(repository, settings: settings);
      final bloc = LooperBloc(
        repository: repository,
        settings: settings,
        mixSettings: mix,
        fxPersistence: fx,
        decayControl: FakeDecayControl(),
        oneShotControl: FakeOneShotControl(),
        recordLengthControl: FakeRecordLengthControl(),
        recordTimingControl: FakeRecordTimingControl(),
      );
      addTearDown(() async {
        await bloc.close();
        await mix.close();
      });
      return bloc;
    }

    test('mute after failed startup preserves unrestored lane FX', () async {
      repository.stopEngine();
      engine.startResult = EngineResult.invalid;
      final encoded = encodeFxChain(
        FxChainEnvelope(
          entries: [
            BuiltInEffect(
              type: TrackEffectType.drive,
              slotId: 'saved-drive',
              params: const [.8, .4, .5, 0],
            ),
          ],
          chainEnabled: false,
          meta: const FxChainMeta(inheritedFrom: [2]),
        ),
      );
      await settings.saveLaneEffects(0, 0, encoded);
      await settings.saveAudioConfig(
        const StoredAudioConfig(sampleRate: 48000, bufferFrames: 128),
      );
      final mix = testMixSettings(repository, settings: settings);
      addTearDown(mix.close);
      final boot = await tryAutoStartEngine(
        repository: repository,
        settings: settings,
        mixSettings: mix,
      );
      expect(boot.started, isFalse);
      expect(repository.laneEffects(0, 0), isEmpty);
      expect(mute(muted: true), EngineResult.ok);
      await fx.flush();
      expect(await settings.loadLaneMute(0, 0), isTrue);
      expect(await settings.loadLaneEffects(0, 0), encoded);
      await coldMute(expected: true, effects: encoded);
      expect(await settings.loadLaneEffects(0, 0), encoded);
      expect(errors, isEmpty);
    });

    for (final fxFirst in [true, false]) {
      test('queued FX survives mute coalescing (FX first: $fxFirst)', () async {
        final effect = BuiltInEffect(
          type: TrackEffectType.drive,
          slotId: 'queued-drive',
          params: const [.6, .4, .5, 0],
        );
        expect(
          repository.setLaneEffects(channel: 0, lane: 0, effects: [effect]),
          EngineResult.ok,
        );
        final ticket = fx.beginPending();
        const address = FxAddress(stage: FxStage.loop, lane: 0);
        void queueFx() => fx.retainConfirmed(address, settings);
        if (fxFirst) queueFx();
        expect(mute(muted: true), EngineResult.ok);
        if (!fxFirst) queueFx();
        fx.finishPending(ticket);
        await fx.flush();
        final saved = decodeFxChain(await settings.loadLaneEffects(0, 0));
        expect(saved.entries.single, effect);
        expect(await settings.loadLaneMute(0, 0), isTrue);
        expect(errors, isEmpty);
      });
    }

    for (final redo in [false, true]) {
      test(
        '${redo ? 'redo' : 'new capture'} persists its accepted mute reset',
        () async {
          attachLooper();
          expect(mute(muted: true), EngineResult.ok);
          await fx.flush();
          expect(await settings.loadLaneMute(0, 0), isTrue);
          expect(
            redo ? repository.redo() : repository.record(),
            EngineResult.ok,
          );
          // A published record image, rather than command admission, retires
          // the old take's remembered mute.
          repository.state;
          await fx.flush();
          expect(repository.laneMuted(0, 0), isFalse);
          expect(await settings.loadLaneMute(0, 0), isFalse);
          await coldMute(expected: false);
        },
      );
    }

    test('multi-lane clear persists every active lane reset', () async {
      final bloc = attachLooper();
      repository.setLaneCount(channel: 0, count: 3);
      await repository.settleMixSettings();
      expect(mute(muted: true), EngineResult.ok);
      await fx.flush();
      bloc.add(const LooperClearPressed(0));
      await pumpEventQueue();
      await fx.flush();
      expect(repository.laneCount(0), 3);
      expect(
        [
          for (var lane = 0; lane < 3; lane++)
            await settings.loadLaneMute(0, lane),
        ],
        [false, false, false],
      );
      await coldMute(expected: false);
    });

    test('Session apply and boot sync survive a fresh bootstrap', () async {
      await settings.saveLaneMute(7, kMaxLanes - 1, muted: true);
      fx.reserveSessionLoad();
      await fx.beginSessionLoad();
      await repository.applySession(
        SessionRig(
          baseLengthFrames: 4,
          tracks: [
            SessionRigTrack(
              channel: 0,
              lanes: [
                SessionRigLane(
                  lane: 0,
                  layers: [
                    Float32List.fromList([1, 1, 1, 1]),
                  ],
                  volume: 1,
                  muted: true,
                  outputMask: 3,
                  inputChannel: 0,
                ),
              ],
            ),
          ],
        ),
        clearPollInterval: Duration.zero,
      );
      await fx.persistLoadedSession(settings);
      expect(await settings.loadLaneMute(7, kMaxLanes - 1), isFalse);
      fx.completeSessionBoot();
      await coldMute(expected: true);
    });

    test(
      'partial native admission persists each actual lane; retry completes',
      () async {
        repository.setLaneCount(channel: 0, count: 3);
        await repository.settleMixSettings();
        engine.refuseLane = 1;
        expect(mute(muted: true), EngineResult.invalid);
        await fx.flush();
        expect(
          [for (var lane = 0; lane < 3; lane++) repository.laneMuted(0, lane)],
          [true, false, true],
        );
        expect(
          [
            for (var lane = 0; lane < 3; lane++)
              await settings.loadLaneMute(0, lane),
          ],
          [true, false, true],
        );
        expect(repository.trackMuted(0), isFalse);
        expect(errors, [isA<StateError>()]);
        engine.refuseLane = null;
        expect(mute(muted: true), EngineResult.ok);
        await fx.flush();
        expect(repository.trackMuted(0), isTrue);
        expect(await settings.loadLaneMute(0, 1), isTrue);
      },
    );

    test(
      'controller FX save and a superseding mute both finish during close',
      () async {
        store.blockedEffects = Completer<void>();
        final prior = saveFxOwner(
          settings: settings,
          projection: fx,
          address: const FxAddress(stage: FxStage.loop, lane: 0),
        );
        await store.effectsEntered.future;
        expect(mute(muted: true), EngineResult.ok);
        await pumpEventQueue();
        final closing = fx.close();
        store.blockedEffects!.complete();
        await prior;
        await closing;
        expect(await settings.loadLaneMute(0, 0), isTrue);
        await coldMute(expected: true);
      },
    );

    test(
      'lane storage failure during close reaches caller and disposal',
      () async {
        store
          ..blocked = Completer<void>()
          ..failAfterWrite = true;
        final saving = saveFxOwner(
          settings: settings,
          projection: fx,
          address: const FxAddress(stage: FxStage.loop, lane: 0),
        );
        await store.entered.future;
        closeFailureExpected = true;
        final closing = fx.close();
        final failedSave = expectLater(saving, throwsStateError);
        final failedClose = expectLater(closing, throwsStateError);
        store.blocked!.complete();
        await Future.wait([failedSave, failedClose]);
        expect(store.values['lane_mute.0.0'], isFalse);
      },
    );

    test(
      'a failed controller save leaves no sticky disposal obligation',
      () async {
        store.failAfterWrite = true;
        await expectLater(
          saveFxOwner(
            settings: settings,
            projection: fx,
            address: const FxAddress(stage: FxStage.loop, lane: 0),
          ),
          throwsStateError,
        );
        store.failAfterWrite = false;
        final writes = store.muteWrites;
        final ticket = fx.beginPending();
        expect(mute(muted: true), EngineResult.ok);
        final closing = fx.close();
        fx.finishPending(ticket);
        await closing;
        expect(store.muteWrites, writes);
        expect(store.values['lane_mute.0.0'], isFalse);
      },
    );

    test(
      'Session reservation rejects ordinary mute before native or storage',
      () async {
        fx.reserveSessionLoad();
        expect(mute(muted: true), EngineResult.invalid);
        expect(engine.laneMute, isEmpty);
        expect(repository.laneMuted(0, 0), isFalse);
        expect(store.values, isEmpty);
        expect(errors, [isA<StateError>()]);
        fx.cancelSessionLoad();
      },
    );

    test(
      'rapid toggle during blocked save ends with latest admitted mute',
      () async {
        store.blocked = Completer<void>();
        expect(mute(muted: true, lane: 0), EngineResult.ok);
        await store.entered.future;
        expect(
          mute(muted: !repository.laneMuted(0, 0), lane: 0),
          EngineResult.ok,
        );
        store.blocked!.complete();
        await fx.flush();
        expect(engine.laneMute[(0, 0)], isFalse);
        expect(await settings.loadLaneMute(0, 0), isFalse);
        await coldMute(expected: false);
        expect(errors, isEmpty);
      },
    );

    test(
      'mutation then storage error stays failed until explicit retry',
      () async {
        store.failAfterWrite = true;
        expect(mute(muted: true), EngineResult.ok);
        await pumpEventQueue();
        expect(store.values['lane_mute.0.0'], isTrue);
        expect(engine.laneMute[(0, 0)], isTrue);
        expect(errors, [isA<StateError>()]);
        await expectLater(fx.flush(), throwsStateError);
        store.failAfterWrite = false;
        await fx.flush();
        expect(await settings.loadLaneMute(0, 0), isTrue);
      },
    );

    test('pending FX delays shared lane save without losing mute', () async {
      final ticket = fx.beginPending();
      expect(mute(muted: true), EngineResult.ok);
      await pumpEventQueue();
      expect(store.values['lane_mute.0.0'], isNull);
      fx.finishPending(ticket);
      await fx.flush();
      expect(await settings.loadLaneMute(0, 0), isTrue);
      expect(errors, isEmpty);
    });

    test('Session image saves imported mute and resets absent slots', () async {
      await settings.saveLaneMute(7, kMaxLanes - 1, muted: true);
      repository.setLaneMute(channel: 0, lane: 0, muted: true);
      fx.reserveSessionLoad();
      await fx.beginSessionLoad();
      await fx.persistLoadedSession(settings);
      expect(fx.sessionTransitionActive, isTrue);
      expect(await settings.loadLaneMute(0, 0), isTrue);
      expect(await settings.loadLaneMute(7, kMaxLanes - 1), isFalse);
      fx.completeSessionBoot();
      expect(fx.sessionTransitionActive, isFalse);
    });

    test(
      'failed immutable Session mute image retries original accepted value',
      () async {
        repository.setLaneMute(channel: 0, lane: 0, muted: true);
        store.failAfterWrite = true;
        fx.reserveSessionLoad();
        await fx.beginSessionLoad();
        await expectLater(fx.persistLoadedSession(settings), throwsStateError);
        expect(fx.sessionTransitionActive, isTrue);
        expect(mute(muted: false), EngineResult.invalid);
        expect(repository.laneMuted(0, 0), isTrue);
        store.failAfterWrite = false;
        await fx.retrySessionBoot();
        expect(await settings.loadLaneMute(0, 0), isTrue);
        fx.completeSessionBoot();
      },
    );
  });

  for (final wholeTrack in [false, true]) {
    test(
      '${wholeTrack ? 'whole-track mute' : 'lane mute control'} '
      'survives cold boot',
      () async {
        final engine = _RecordedMuteEngine();
        final repository = LooperRepository(
          engine: engine,
          ticker: const Stream<void>.empty(),
        )..startEngine(const EngineConfig());
        final settings = SettingsRepository(store: FakeKeyValueStore());
        await settings.saveAudioConfig(
          const StoredAudioConfig(sampleRate: 48000, bufferFrames: 128),
        );
        await settings.saveLaneMute(0, 0, muted: false);
        final mix = testMixSettings(repository, settings: settings);
        final fx = FxChainPersistence(looper: repository);
        final bloc = LooperBloc(
          repository: repository,
          settings: settings,
          mixSettings: mix,
          fxPersistence: fx,
          decayControl: FakeDecayControl(),
          oneShotControl: FakeOneShotControl(),
          recordLengthControl: FakeRecordLengthControl(),
          recordTimingControl: FakeRecordTimingControl(),
        );
        addTearDown(() async {
          await bloc.close();
          await fx.close();
          await mix.close();
          await repository.dispose();
        });
        if (wholeTrack) {
          bloc.add(const LooperMuteToggled(0));
        } else {
          bloc.add(const LooperLaneMuteToggled(0, 0));
        }
        await pumpEventQueue();
        expect(repository.trackMuted(0), isTrue);
        expect(engine.laneMute[(0, 0)], isTrue);
        final stored = await settings.loadLaneMute(0, 0);
        final sessionDirectory = await Directory.systemTemp.createTemp(
          'segno-mute-probe-',
        );
        addTearDown(() => sessionDirectory.delete(recursive: true));
        final sessions = SessionRepository(engine: engine);
        await sessions.save(
          sessionDirectory.path,
          settings: const SessionSettings(),
        );
        final bundle = await sessions.read(sessionDirectory.path);
        expect(bundle.session.tracks.single.lanes.single.muted, isTrue);
        final rebootEngine = FakeAudioEngine();
        final rebooted = LooperRepository(
          engine: rebootEngine,
          ticker: const Stream<void>.empty(),
        );
        final rebootMix = testMixSettings(rebooted, settings: settings);
        addTearDown(() async {
          await rebootMix.close();
          await rebooted.dispose();
        });
        final result = await tryAutoStartEngine(
          repository: rebooted,
          settings: settings,
          mixSettings: rebootMix,
        );
        expect(result.started, isTrue);
        expect((stored, rebootEngine.laneMute[(0, 0)]), (true, true));
      },
    );
  }
}
