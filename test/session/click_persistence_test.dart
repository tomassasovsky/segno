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
import 'package:segno/session/session.dart';
import 'package:segno_engine/segno_engine.dart' show PumpedNativeEngine;
import 'package:session_repository/session_repository.dart';
import 'package:settings_repository/settings_repository.dart';

import '../helpers/fake_key_value_store.dart';

class _ClickStore extends FakeKeyValueStore {
  Completer<void>? pendingWrite;
  bool writeEntered = false;

  @override
  Future<void> setDouble(String key, double value) async {
    if (key == 'tempo.click_volume' && pendingWrite != null) {
      writeEntered = true;
      await pendingWrite!.future;
    }
    await super.setDouble(key, value);
  }
}

void main() {
  final nativeAvailable = Platform.environment.containsKey('SEGNO_ENGINE_LIB');
  group('durable Click session capture', skip: !nativeAvailable, () {
    late PumpedNativeEngine engine;
    late LooperRepository looper;
    late TempoCubit tempo;
    late PlaybackOptionsCubit playback;
    late SessionCubit session;
    late SessionRepository sessions;
    late PerformanceRepository performance;
    late MixSettingsCoordinator mix;
    late SettingsRepository settings;
    late _ClickStore store;
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
      directory = Directory.systemTemp.createTempSync('segno-click-session-');
      store = _ClickStore();
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
        currentDurableDecay: () => playback.durableDecaySnapshot,
        currentDurableOneShot: () => playback.durableOneShotSnapshot,
        currentDurableClickVolume: () => tempo.durableClickVolume,
        exportDirectory: () async => directory.path,
      );
      expect((await tempo.setClickVolume(.4)).isOk, isTrue);
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
      'Save As and Save capture Released without changing held audio',
      () async {
        expect(
          (await tempo.setControllerClickVolume(
            1.6,
            releasedVolume: .4,
            lifetime: tempo.clickVolumeLifetime,
          )).isOk,
          isTrue,
        );
        await session.saveAs('Click held');
        expect(session.state.status, SessionStatus.success);
        var bundle = await sessions.read(
          await sessions.bundlePath('Click held'),
        );
        expect(bundle.session.clickVolume, closeTo(.4, 1e-6));
        expect(tempo.clickVolume, closeTo(1.6, 1e-6));
        expect(looper.sessionTransport.clickVolume, closeTo(1.6, 1e-6));
        await session.save();
        bundle = await sessions.read(await sessions.bundlePath('Click held'));
        expect(bundle.session.clickVolume, closeTo(.4, 1e-6));
        expect(tempo.clickVolume, closeTo(1.6, 1e-6));
        expect(await settings.loadClickVolume(), closeTo(.4, 1e-6));
      },
    );

    test('Save waits for an earlier ordinary Click write', () async {
      store.pendingWrite = Completer<void>();
      final edit = tempo.setClickVolume(1.2);
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
      final bundle = await sessions.read(await sessions.bundlePath('Pending'));
      expect(bundle.session.clickVolume, closeTo(1.2, 1e-6));
    });

    test(
      'recall restores saved Click without rewriting startup gain',
      () async {
        await session.saveAs('Quiet');
        expect((await tempo.setClickVolume(1.4)).isOk, isTrue);
        await session.loadNamed('Quiet');
        expect(session.state.status, SessionStatus.success);
        expect(tempo.clickVolume, closeTo(.4, 1e-6));
        expect(tempo.durableClickVolume, closeTo(.4, 1e-6));
        expect(await settings.loadClickVolume(), closeTo(1.4, 1e-6));
      },
    );
  });
}
