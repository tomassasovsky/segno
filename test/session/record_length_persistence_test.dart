import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:performance_repository/performance_repository.dart';
import 'package:segno/app/fx_chain_persistence.dart';
import 'package:segno/app/mix_settings_coordinator.dart';
import 'package:segno/app/settings_mix_persistence.dart';
import 'package:segno/looper/cubit/playback_options_cubit.dart';
import 'package:segno/looper/cubit/record_options_cubit.dart';
import 'package:segno/looper/cubit/tempo_cubit.dart';
import 'package:segno/looper/model/record_length.dart';
import 'package:segno/looper/model/record_timing.dart';
import 'package:segno/session/session.dart';
import 'package:segno_engine/segno_engine.dart' show PumpedNativeEngine;
import 'package:session_repository/session_repository.dart';
import 'package:settings_repository/settings_repository.dart';

import '../helpers/fake_key_value_store.dart';

class _LengthSaveStore extends FakeKeyValueStore {
  Completer<void>? blocked;
  bool entered = false;

  @override
  Future<void> setInt(String key, int value) async {
    if (key.startsWith('tempo.length_preset.') ||
        key == 'looper.default_length_bars') {
      entered = true;
      await blocked?.future;
    }
    await super.setInt(key, value);
  }
}

void main() {
  group(
    'durable Record length session capture',
    skip: !Platform.environment.containsKey('SEGNO_ENGINE_LIB'),
    () {
      late PumpedNativeEngine engine;
      late LooperRepository looper;
      late TempoCubit tempo;
      late PlaybackOptionsCubit playback;
      late RecordOptionsCubit record;
      late SessionCubit session;
      late SessionRepository sessions;
      late PerformanceRepository performance;
      late MixSettingsCoordinator mix;
      late _LengthSaveStore store;
      late Directory directory;
      late Timer pump;

      setUp(() async {
        engine = PumpedNativeEngine();
        looper = LooperRepository(engine: engine);
        expect(
          looper.startEngine(
            const EngineConfig(
              sampleRate: 8000,
              inputChannels: 2,
              outputChannels: 2,
              maxLoopFrames: 1024000,
            ),
          ),
          EngineResult.ok,
        );
        pump = Timer.periodic(
          const Duration(milliseconds: 1),
          (_) => engine.pump(frames: 0),
        );
        directory = Directory.systemTemp.createTempSync('segno-length-save-');
        store = _LengthSaveStore();
        final settings = SettingsRepository(store: store);
        tempo = TempoCubit(repository: looper, settings: settings);
        await tempo.load();
        expect((await tempo.setCountInBars(0)).isOk, isTrue);
        playback = PlaybackOptionsCubit(repository: looper, settings: settings);
        await playback.load();
        await settings.saveLooperMode(LooperMode.free.code);
        record = RecordOptionsCubit(repository: looper, settings: settings);
        await record.load();
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
          runTempoExclusive: tempo.runTempoExclusive,
          currentDurableRecordStart: () => tempo.durableRecordStartSettings,
          currentDurableClickVolume: () => tempo.durableClickVolume,
          currentDurableClickMode: () => tempo.durableClickMode,
          runPlaybackExclusive: playback.runPlaybackExclusive,
          runRecordExclusive: record.runRecordExclusive,
          runRecordTimingExclusive: <T>(operation) => operation(),
          currentDurableRecordTiming: () => RecordTimingSnapshot(
            defaultTiming: looper.defaultRecordTiming,
            rememberedDivision: looper.sessionTransport.quantizeDiv,
            trackOverrides: looper.trackRecordTimingOverrides,
            captureLocked: false,
          ),
          currentDurableRecordLength: () => record.durableRecordLengthSnapshot,
          currentDurableDecay: () => playback.durableDecaySnapshot,
          currentDurableOneShot: () => playback.durableOneShotSnapshot,
          exportDirectory: () async => directory.path,
        );
        expect(looper.record(), EngineResult.ok);
        engine.pump(frames: 256, input: .5);
        expect(looper.record(), EngineResult.ok);
        // Free recording closes at the next musical processing boundary.
        // Advance real PCM before attempting to edit presets or save.
        engine.pump(frames: 256, input: .5);
        await looper.settleLengthSettings();
        expect(looper.recordLengthCaptureLocked, isFalse);
      });

      tearDown(() async {
        if (store.blocked case final block? when !block.isCompleted) {
          block.complete();
        }
        await session.close();
        await record.close();
        await playback.close();
        await tempo.close();
        await mix.close();
        performance.dispose();
        pump.cancel();
        await looper.dispose();
        directory.deleteSync(recursive: true);
      });

      test(
        'Save As and Save capture Released while live choices stay Held',
        () async {
          for (final pair in [
            (const RecordLengthAddress.defaults(), 8, 4),
            (const RecordLengthAddress.track(7), 2, 0),
          ]) {
            expect(
              (await record.setControllerRecordLength(
                pair.$1,
                pair.$2,
                lifetime: record.recordLengthLifetime,
                revision: record.recordLengthRevision(pair.$1),
                releasedBars: pair.$3,
              )).isOk,
              isTrue,
            );
          }
          await session.saveAs('Record length held');
          expect(session.state.status, SessionStatus.success);
          for (var pass = 0; pass < 2; pass++) {
            if (pass == 1) await session.save();
            final bundle = await sessions.read(
              await sessions.bundlePath('Record length held'),
            );
            expect(bundle.session.defaultLengthPresetBars, 4);
            expect(bundle.session.trackLengthPresetOverrides, {7: 0});
            expect(record.state.defaultLengthBars, 8);
            expect(record.state.trackLengthPresetOverrides, {7: 2});
            expect(engine.snapshot().tracks[0].lengthPresetBars, 8);
            expect(engine.snapshot().tracks[7].lengthPresetBars, 2);
          }
        },
      );

      test(
        'Save waits for a blocked ordinary choice before taking its snapshot',
        () async {
          store.blocked = Completer<void>();
          final write = record.setTrackRecordLength(channel: 7, bars: 0);
          while (!store.entered) {
            await Future<void>.delayed(Duration.zero);
          }
          var saved = false;
          final save = session
              .saveAs('Record length pending')
              .then((_) => saved = true);
          await Future<void>.delayed(const Duration(milliseconds: 20));
          expect(saved, isFalse);
          store.blocked!.complete();
          expect((await write).isOk, isTrue);
          await save;
          final bundle = await sessions.read(
            await sessions.bundlePath('Record length pending'),
          );
          expect(bundle.session.trackLengthPresetOverrides, {7: 0});
        },
      );
    },
  );
}
