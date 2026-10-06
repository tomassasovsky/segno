import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:operation_guards/operation_guards.dart';
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
import 'package:segno/looper/model/record_length.dart';
import 'package:segno/session/application/session_settings_coordinator.dart';
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
      late TempoSettings tempo;
      late PlaybackSettings playback;
      late RecordSettings record;
      late RecordTimingSettings timing;
      late FxChainPersistence projection;
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
        tempo = TempoSettings(repository: looper, settings: settings);
        await tempo.load();
        expect((await tempo.recordStartControl.setCountInBars(0)).isOk, isTrue);
        playback = PlaybackSettings(repository: looper, settings: settings);
        await playback.load();
        await settings.saveLooperMode(LooperMode.free.code);
        record = RecordSettings(repository: looper, settings: settings);
        await record.load();
        timing = RecordTimingSettings(repository: looper, settings: settings);
        await timing.load();
        final fade = FadeSettings(
          repository: looper,
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
          guards: GuardRegistry(),
          engine: engine,
          sessionsRoot: () async => directory.path,
        );
        performance = PerformanceRepository(
          guards: GuardRegistry(),
          engine: engine,
          exportsRoot: () async => directory.path,
        );
        session = SessionCubit(
          guards: GuardRegistry(),
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
            owners: SettingsOwners([
              ...tempo.owners,
              ...playback.owners,
              ...record.owners,
              ...timing.owners,
              ...fade.owners,
            ]),
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
        await timing.close();
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

      test(
        'an owed length is saved as requested, and recall re-applies it '
        'with a receipt',
        () async {
          // A Session load cannot re-import this rig's free-mode take; the
          // case is about settings, so it runs on an empty rig.
          expect(looper.clear(), EngineResult.ok);
          await Future<void>.delayed(const Duration(milliseconds: 20));
          // Withhold the receipt: an unpumped engine consumes no command.
          pump.cancel();
          final edit = await record.setTrackRecordLength(channel: 2, bars: 4);
          expect(edit.status, RecordLengthStatus.recoveryRequired);
          expect(looper.lengthRecoveryRequired, isTrue);
          expect(record.durableRecordLengthSnapshot.trackOverrides, {2: 4});
          pump = Timer.periodic(
            const Duration(milliseconds: 1),
            (_) => engine.pump(frames: 0),
          );
          await session.saveAs('Owed length');
          expect(session.state.status, SessionStatus.success);
          final bundle = await sessions.read(
            await sessions.bundlePath('Owed length'),
          );
          expect(bundle.session.trackLengthPresetOverrides, {2: 4});

          // Settle the obligation, then move away from the saved value.
          expect((await record.owner.recover()).isOk, isTrue);
          expect(
            (await record.setTrackRecordLength(channel: 2, bars: 8)).isOk,
            isTrue,
          );
          expect(engine.snapshot().tracks[2].lengthPresetBars, 8);
          await session.loadNamed('Owed length');
          expect(session.state.status, SessionStatus.success);
          expect(looper.lengthRecoveryRequired, isFalse);
          expect(looper.lengthSettingsSettled, isTrue);
          expect(engine.snapshot().tracks[2].lengthPresetBars, 4);
          expect(record.state.trackLengthPresetOverrides, {2: 4});
        },
      );
    },
  );
}
