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
import 'package:segno/looper/cubit/record_timing_cubit.dart';
import 'package:segno/looper/cubit/tempo_cubit.dart';
import 'package:segno/looper/model/record_timing.dart';
import 'package:segno/session/session.dart';
import 'package:segno_engine/segno_engine.dart' show PumpedNativeEngine;
import 'package:session_repository/session_repository.dart';
import 'package:settings_repository/settings_repository.dart';

import '../helpers/fake_key_value_store.dart';

class _TimingSaveStore extends FakeKeyValueStore {
  Completer<void>? blocked;
  bool entered = false;

  Future<void> _wait(String key) async {
    if (key == 'looper.quantize' ||
        key == 'tempo.quantize_div' ||
        key.startsWith('track_record_timing.')) {
      entered = true;
      await blocked?.future;
    }
  }

  @override
  Future<void> setInt(String key, int value) async {
    await _wait(key);
    await super.setInt(key, value);
  }

  @override
  Future<void> setBool(String key, {required bool value}) async {
    await _wait(key);
    await super.setBool(key, value: value);
  }
}

void main() {
  group(
    'durable Record timing session capture',
    skip: !Platform.environment.containsKey('SEGNO_ENGINE_LIB'),
    () {
      late PumpedNativeEngine engine;
      late LooperRepository looper;
      late TempoCubit tempo;
      late PlaybackOptionsCubit playback;
      late RecordOptionsCubit record;
      late RecordTimingCubit timing;
      late SessionCubit session;
      late SessionRepository sessions;
      late PerformanceRepository performance;
      late MixSettingsCoordinator mix;
      late _TimingSaveStore store;
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
        directory = Directory.systemTemp.createTempSync('segno-timing-save-');
        store = _TimingSaveStore();
        store.values['tempo.quantize_div'] = 3;
        final settings = SettingsRepository(store: store);
        tempo = TempoCubit(repository: looper, settings: settings);
        await tempo.load();
        playback = PlaybackOptionsCubit(repository: looper, settings: settings);
        await playback.load();
        await settings.saveLooperMode(LooperMode.free.code);
        record = RecordOptionsCubit(repository: looper, settings: settings);
        await record.load();
        timing = RecordTimingCubit(repository: looper, settings: settings);
        await timing.load();
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
          runClickExclusive: tempo.runClickExclusive,
          currentDurableClickVolume: () => tempo.durableClickVolume,
          currentDurableClickMode: () => tempo.durableClickMode,
          runPlaybackExclusive: playback.runPlaybackExclusive,
          runRecordExclusive: record.runRecordExclusive,
          runRecordTimingExclusive: timing.runRecordTimingExclusive,
          currentDurableRecordTiming: () => timing.durableRecordTimingSnapshot,
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
        await timing.close();
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
            (
              const RecordTimingAddress.defaults(),
              RecordTiming.sixteenth,
              RecordTiming.immediately,
            ),
            (
              const RecordTimingAddress.track(7),
              RecordTiming.eighth,
              RecordTiming.loopStart,
            ),
          ]) {
            expect(
              (await timing.setControllerTiming(
                pair.$1,
                pair.$2,
                lifetime: timing.recordTimingLifetime,
                revision: timing.recordTimingRevision(pair.$1),
                releasedTiming: pair.$3,
              )).isOk,
              isTrue,
            );
          }
          await session.saveAs('Record timing held');
          expect(session.state.status, SessionStatus.success);
          for (var pass = 0; pass < 2; pass++) {
            if (pass == 1) {
              // A changed field proves Save wrote a new bundle; rereading the
              // earlier Save As file must not pass if the second write fails.
              expect((await tempo.setClickVolume(.4)).isOk, isTrue);
              await session.save();
              expect(session.state.status, SessionStatus.success);
            }
            final bundle = await sessions.read(
              await sessions.bundlePath('Record timing held'),
            );
            expect(bundle.session.clickVolume, pass == 0 ? 1 : .4);
            expect(bundle.session.recordTiming, RecordTiming.immediately);
            expect(bundle.session.quantizeDiv, GridDivision.quarter);
            expect(bundle.session.trackRecordTimingOverrides, {
              7: RecordTiming.loopStart,
            });
            expect(timing.state.defaultTiming, RecordTiming.sixteenth);
            expect(timing.state.trackOverrides, {7: RecordTiming.eighth});
            expect(engine.snapshot().quantize, isTrue);
            expect(engine.snapshot().quantizeDiv, GridDivision.sixteenth);
            expect(
              engine.snapshot().tracks[7].quantizeDivOverride,
              GridDivision.eighth,
            );
          }
        },
      );

      test(
        'Save waits for a blocked ordinary choice before taking its snapshot',
        () async {
          store
            ..entered = false
            ..blocked = Completer<void>();
          final write = timing.setTrackTiming(
            channel: 7,
            timing: RecordTiming.immediately,
          );
          while (!store.entered) {
            await Future<void>.delayed(Duration.zero);
          }
          var saved = false;
          final save = session
              .saveAs('Record timing pending')
              .then((_) => saved = true);
          await Future<void>.delayed(const Duration(milliseconds: 20));
          expect(saved, isFalse);
          store.blocked!.complete();
          expect((await write).isOk, isTrue);
          await save;
          expect(session.state.status, SessionStatus.success);
          final bundle = await sessions.read(
            await sessions.bundlePath('Record timing pending'),
          );
          expect(bundle.session.trackRecordTimingOverrides, {
            7: RecordTiming.immediately,
          });
        },
      );
    },
  );
}
