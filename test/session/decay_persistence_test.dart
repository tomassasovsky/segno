import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:performance_repository/performance_repository.dart';
import 'package:segno/app/fx_chain_persistence.dart';
import 'package:segno/app/mix_settings_coordinator.dart';
import 'package:segno/app/settings_mix_persistence.dart';
import 'package:segno/looper/cubit/playback_options_cubit.dart';
import 'package:segno/looper/cubit/tempo_cubit.dart';
import 'package:segno/looper/model/overdub_decay.dart';
import 'package:segno/looper/model/record_length.dart';
import 'package:segno/looper/model/record_timing.dart';
import 'package:segno/session/session.dart';
import 'package:segno_engine/segno_engine.dart' show PumpedNativeEngine;
import 'package:session_repository/session_repository.dart';
import 'package:settings_repository/settings_repository.dart';

import '../helpers/fake_key_value_store.dart';

class _DecayStore extends FakeKeyValueStore {
  Completer<void>? pendingWrite;
  bool writeEntered = false;

  @override
  Future<void> setInt(String key, int value) async {
    if ((key == 'looper.overdub_decay' ||
            key.startsWith('track_overdub_decay.')) &&
        pendingWrite != null) {
      writeEntered = true;
      await pendingWrite!.future;
    }
    await super.setInt(key, value);
  }
}

void main() {
  final nativeAvailable = Platform.environment.containsKey('SEGNO_ENGINE_LIB');
  group('durable Decay session capture', skip: !nativeAvailable, () {
    late PumpedNativeEngine engine;
    late LooperRepository looper;
    late TempoCubit tempo;
    late PlaybackOptionsCubit playback;
    late SessionCubit session;
    late SessionRepository sessions;
    late PerformanceRepository performance;
    late MixSettingsCoordinator mix;
    late SettingsRepository settings;
    late _DecayStore store;
    late Directory directory;
    late Timer pump;

    setUp(() async {
      engine = PumpedNativeEngine();
      looper = LooperRepository(engine: engine);
      expect(
        looper.startEngine(
          const EngineConfig(
            sampleRate: 48000,
            inputChannels: 2,
            outputChannels: 2,
            maxLoopFrames: 8192,
          ),
        ),
        EngineResult.ok,
      );
      pump = Timer.periodic(
        const Duration(milliseconds: 1),
        (_) => engine.pump(frames: 0),
      );
      directory = Directory.systemTemp.createTempSync('segno-decay-session-');
      store = _DecayStore();
      settings = SettingsRepository(store: store);
      tempo = TempoCubit(repository: looper, settings: settings);
      await tempo.load();
      playback = PlaybackOptionsCubit(
        repository: looper,
        settings: settings,
      );
      await playback.load();
      mix = MixSettingsCoordinator(
        repository: looper,
        persistence: SettingsMixPersistence(settings),
        device: () => looper.state.status.deviceName,
      );
      sessions = SessionRepository(
        engine: engine,
        sessionsRoot: () async => directory.path,
      );
      performance = PerformanceRepository(
        engine: engine,
        exportsRoot: () async => directory.path,
      );
      session = SessionCubit(
        repository: sessions,
        looper: looper,
        performance: performance,
        mixSettings: mix,
        mixPersistence: SettingsMixPersistence(settings),
        fxPersistence: FxChainPersistence(looper: looper),
        runClickVolumeExclusive: tempo.runClickVolumeExclusive,
        runPlaybackExclusive: playback.runPlaybackExclusive,
        runRecordExclusive: <T>(operation) => operation(),
        runRecordTimingExclusive: <T>(operation) => operation(),
        currentDurableRecordTiming: () => RecordTimingSnapshot(
          defaultTiming: looper.defaultRecordTiming,
          rememberedDivision: looper.sessionTransport.quantizeDiv,
          trackOverrides: looper.trackRecordTimingOverrides,
          captureLocked: false,
        ),
        currentDurableRecordLength: () => RecordLengthSnapshot(
          defaultBars: looper.sessionTransport.defaultLengthPresetBars,
          trackOverrides: looper.trackLengthPresetOverrides,
          mode: looper.sessionTransport.looperMode,
          captureLocked: false,
        ),
        currentDurableDecay: () => playback.durableDecaySnapshot,
        currentDurableOneShot: () => playback.durableOneShotSnapshot,
        currentDurableClickVolume: () => tempo.durableClickVolume,
        exportDirectory: () async => directory.path,
      );
      expect((await playback.setOverdubDecay(20)).isOk, isTrue);
      expect(looper.record(), EngineResult.ok);
      engine.pump(frames: 256, input: .5);
      expect(looper.record(), EngineResult.ok);
      engine.pump(frames: 0);
    });

    tearDown(() async {
      if (store.pendingWrite case final pending? when !pending.isCompleted) {
        pending.complete();
      }
      await session.close();
      await playback.close();
      await tempo.close();
      await mix.close();
      performance.dispose();
      pump.cancel();
      await looper.dispose();
      directory.deleteSync(recursive: true);
    });

    test(
      'Save As and Save keep explicit Released zero while live is held',
      () async {
        for (final target in [
          (const DecayAddress.defaults(), 80, 20),
          (const DecayAddress.track(0), 75, 0),
        ]) {
          expect(
            (await playback.setControllerDecay(
              target.$1,
              target.$2,
              lifetime: playback.decayLifetime,
              revision: playback.decayRevision(target.$1),
              releasedPercent: target.$3,
            )).isOk,
            isTrue,
          );
        }
        await session.saveAs('Decay held');
        expect(session.state.status, SessionStatus.success);
        var bundle = await sessions.read(
          await sessions.bundlePath('Decay held'),
        );
        expect(bundle.session.overdubDecay, 20);
        expect(bundle.session.trackOverdubDecayOverrides, {0: 0});
        expect(playback.state.overdubDecay, 80);
        expect(playback.state.trackOverdubDecayOverrides, {0: 75});
        await session.save();
        bundle = await sessions.read(await sessions.bundlePath('Decay held'));
        expect(bundle.session.overdubDecay, 20);
        expect(bundle.session.trackOverdubDecayOverrides, {0: 0});
        expect(playback.state.overdubDecay, 80);
        expect(playback.state.trackOverdubDecayOverrides, {0: 75});
      },
    );

    test(
      'Save waits for an earlier ordinary fixed-track Decay write',
      () async {
        store.pendingWrite = Completer<void>();
        final edit = playback.setTrackOverdubDecay(channel: 7, percent: 45);
        for (var attempt = 0; attempt < 50 && !store.writeEntered; attempt++) {
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
        expect(store.writeEntered, isTrue);
        var saved = false;
        final save = session.saveAs('Pending').then((_) => saved = true);
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(saved, isFalse);
        expect(await sessions.listSessions(), isEmpty);
        store.pendingWrite!.complete();
        expect((await edit).isOk, isTrue);
        await save;
        expect(session.state.status, SessionStatus.success);
        final bundle = await sessions.read(
          await sessions.bundlePath('Pending'),
        );
        expect(bundle.session.trackOverdubDecayOverrides, {7: 45});
      },
    );

    test(
      'recall restores Custom zero without changing startup preference',
      () async {
        await playback.setTrackOverdubDecay(channel: 0, percent: 0);
        await session.saveAs('Inherited and custom');
        await playback.setOverdubDecay(50);
        await playback.setTrackOverdubDecay(channel: 0, percent: null);
        await session.loadNamed('Inherited and custom');
        expect(session.state.status, SessionStatus.success);
        expect(playback.state.overdubDecay, 20);
        expect(playback.state.trackOverdubDecayOverrides, {0: 0});
        expect(
          playback.durableDecaySnapshot,
          DecaySnapshot(defaultPercent: 20, trackOverrides: const {0: 0}),
        );
        expect(await settings.loadOverdubDecay(), 50);
        expect(await settings.loadTrackOverdubDecay(0), isNull);
      },
    );
  });
}
