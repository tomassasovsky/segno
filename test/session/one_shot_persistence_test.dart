import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:performance_repository/performance_repository.dart';
import 'package:segno/app/fx_chain_persistence.dart';
import 'package:segno/app/mix_settings_coordinator.dart';
import 'package:segno/app/settings_mix_persistence.dart';
import 'package:segno/looper/application/fade_settings.dart';
import 'package:segno/looper/application/playback_settings.dart';
import 'package:segno/looper/application/record_settings.dart';
import 'package:segno/looper/application/record_timing_settings.dart';
import 'package:segno/looper/application/settings_owners.dart';
import 'package:segno/looper/application/tempo_settings.dart';
import 'package:segno/looper/model/one_shot.dart';
import 'package:segno/session/application/session_settings_coordinator.dart';
import 'package:segno/session/session.dart';
import 'package:segno_engine/segno_engine.dart' show PumpedNativeEngine;
import 'package:session_repository/session_repository.dart';
import 'package:settings_repository/settings_repository.dart';

import '../helpers/fake_key_value_store.dart';

class _OnceSaveStore extends FakeKeyValueStore {
  Completer<void>? blocked;
  bool entered = false;

  @override
  Future<void> setBool(String key, {required bool value}) async {
    if (key.startsWith('track_one_shot.') || key == 'looper.default_one_shot') {
      entered = true;
      await blocked?.future;
    }
    await super.setBool(key, value: value);
  }
}

void main() {
  group(
    'durable Playback session capture',
    skip: !Platform.environment.containsKey('SEGNO_ENGINE_LIB'),
    () {
      late PumpedNativeEngine engine;
      late LooperRepository looper;
      late TempoSettings tempo;
      late PlaybackSettings playback;
      late RecordSettings record;
      late RecordTimingSettings timing;
      late FxChainPersistence projection;
      late SessionCubit session;
      late SessionRepository sessions;
      late PerformanceRepository performance;
      late MixSettingsCoordinator mix;
      late _OnceSaveStore store;
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
        directory = Directory.systemTemp.createTempSync('segno-once-save-');
        store = _OnceSaveStore();
        final settings = SettingsRepository(store: store);
        tempo = TempoSettings(repository: looper, settings: settings);
        await tempo.load();
        expect((await tempo.recordStartControl.setCountInBars(0)).isOk, isTrue);
        playback = PlaybackSettings(repository: looper, settings: settings);
        await playback.load();
        record = RecordSettings(repository: looper, settings: settings);
        await record.load();
        timing = RecordTimingSettings(repository: looper, settings: settings);
        await timing.load();
        final fade = FadeSettings(
          settings: settings,
          blocked: () => false,
          sessionBlocked: () => false,
        );
        await fade.load();
        addTearDown(fade.close);
        projection = FxChainPersistence(looper: looper);
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
          settings: settings,
          repository: sessions,
          looper: looper,
          performance: performance,
          mixSettings: mix,
          mixPersistence: SettingsMixPersistence(settings),
          fxPersistence: projection,
          captureSettings: SessionSettingsCoordinator(
            fade: fade,
            looper: looper,
            mix: mix,
            fx: projection,
            owners: SettingsOwners(tempo.owners),
            tempo: tempo,
            playback: playback,
            record: record,
            timing: timing,
          ),
          exportDirectory: () async => directory.path,
        );
        expect(looper.record(), EngineResult.ok);
        engine.pump(frames: 256, input: .5);
        expect(looper.record(), EngineResult.ok);
        engine.pump(frames: 0);
      });

      tearDown(() async {
        if (store.blocked case final block? when !block.isCompleted) {
          block.complete();
        }
        await session.close();
        await timing.close();
        await record.close();
        await playback.close();
        await tempo.close();
        await mix.close();
        await projection.close();
        performance.dispose();
        pump.cancel();
        await looper.dispose();
        directory.deleteSync(recursive: true);
      });

      test(
        'Save As and Save capture Released while live choices stay Held',
        () async {
          for (final pair in [
            (const OneShotAddress.defaults(), true, false),
            (const OneShotAddress.track(0), false, true),
          ]) {
            expect(
              (await playback.setControllerOneShot(
                pair.$1,
                oneShot: pair.$2,
                lifetime: playback.oneShotLifetime,
                revision: playback.oneShotRevision(pair.$1),
                releasedOneShot: pair.$3,
              )).isOk,
              isTrue,
            );
          }
          await session.saveAs('Playback held');
          expect(session.state.status, SessionStatus.success);
          for (var pass = 0; pass < 2; pass++) {
            if (pass == 1) await session.save();
            final bundle = await sessions.read(
              await sessions.bundlePath('Playback held'),
            );
            expect(bundle.session.defaultOneShot, isFalse);
            expect(bundle.session.trackOneShotOverrides, {0: true});
            expect(playback.state.defaultOneShot, isTrue);
            expect(playback.state.trackOneShotOverrides, {0: false});
            expect(engine.snapshot().tracks[0].oneShot, isFalse);
            expect(engine.snapshot().tracks[1].oneShot, isTrue);
          }
        },
      );

      test(
        'Save waits for a blocked ordinary choice before taking its snapshot',
        () async {
          store.blocked = Completer<void>();
          final write = playback.setTrackOneShot(channel: 7, oneShot: false);
          while (!store.entered) {
            await Future<void>.delayed(Duration.zero);
          }
          var saved = false;
          final save = session
              .saveAs('Playback pending')
              .then((_) => saved = true);
          await Future<void>.delayed(const Duration(milliseconds: 20));
          expect(saved, isFalse);
          store.blocked!.complete();
          expect((await write).isOk, isTrue);
          await save;
          final bundle = await sessions.read(
            await sessions.bundlePath('Playback pending'),
          );
          expect(bundle.session.trackOneShotOverrides, {7: false});
        },
      );
    },
  );
}
