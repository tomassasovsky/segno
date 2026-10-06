import 'dart:async';
import 'dart:convert';
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
import 'package:segno/looper/model/record_start.dart';
import 'package:segno/session/application/session_settings_coordinator.dart';
import 'package:segno/session/session.dart';
import 'package:segno_engine/segno_engine.dart' show PumpedNativeEngine;
import 'package:session_repository/session_repository.dart';
import 'package:settings_repository/settings_repository.dart';

import '../helpers/fake_key_value_store.dart';

class _RecordStartSaveStore extends FakeKeyValueStore {
  Completer<void>? pendingWrite;
  bool writeEntered = false;
  bool refuseWrite = false;

  @override
  Future<void> setBool(String key, {required bool value}) async {
    if (key == 'looper.auto_record') {
      writeEntered = true;
      await pendingWrite?.future;
    }
    await super.setBool(key, value: value);
    if (key == 'looper.auto_record' && refuseWrite) {
      throw StateError('Sound preference failed after write');
    }
  }

  @override
  Future<void> setInt(String key, int value) async {
    if (key == 'tempo.count_in_bars' && refuseWrite) {
      throw StateError('Count-in compensation unavailable');
    }
    await super.setInt(key, value);
  }
}

void main() {
  final nativeAvailable = Platform.environment.containsKey('SEGNO_ENGINE_LIB');
  group(
    'confirmed recording-start session capture',
    skip: !nativeAvailable,
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

      /// The id the catalog gave the session saved as [name].
      Future<SessionId> idOf(String name) async =>
          (await sessions.listSessions()).singleWhere((s) => s.name == name).id;
      late PerformanceRepository performance;
      late MixSettingsCoordinator mix;
      late SettingsRepository settings;
      late _RecordStartSaveStore store;
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
        directory = Directory.systemTemp.createTempSync(
          'segno-record-start-session-',
        );
        store = _RecordStartSaveStore();
        settings = SettingsRepository(store: store);
        tempo = TempoSettings(repository: looper, settings: settings);
        await tempo.load();
        expect((await tempo.recordStartControl.setCountInBars(0)).isOk, isTrue);
        playback = PlaybackSettings(
          repository: looper,
          settings: settings,
        );
        await playback.load();
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
        );
        expect(looper.record(), EngineResult.ok);
        engine.pump(frames: 256, input: .5);
        expect(looper.record(), EngineResult.ok);
        engine.pump();
        expect(engine.snapshot().tracks.first.state, TrackState.playing);
      });

      tearDown(() async {
        if (store.pendingWrite case final pending? when !pending.isCompleted) {
          pending.complete();
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
        'Save As and Save preserve both members of the confirmed pair',
        () async {
          expect(
            (await tempo.recordStartControl.setSoundStart(enabled: true)).isOk,
            isTrue,
          );
          await session.saveAs('Start pair');
          expect(session.state.status, SessionStatus.success);
          var bundle = await sessions.read(
            await sessions.bundlePathOf(await idOf('Start pair')),
          );
          expect(bundle.session.countInBars, 0);
          expect(bundle.session.autoRecord, isTrue);
          expect(bundle.session.tracks, hasLength(1));

          expect(
            (await tempo.recordStartControl.setCountInBars(4)).isOk,
            isTrue,
          );
          await session.save();
          expect(session.state.status, SessionStatus.success);
          bundle = await sessions.read(
            await sessions.bundlePathOf(await idOf('Start pair')),
          );
          expect(bundle.session.countInBars, 4);
          expect(bundle.session.autoRecord, isFalse);
          expect(engine.snapshot().countInBars, 4);
          expect(engine.snapshot().autoRecord, isFalse);
        },
      );

      test(
        'Save waits for the second preference before writing a file',
        () async {
          store
            ..writeEntered = false
            ..pendingWrite = Completer<void>();
          final edit = tempo.recordStartControl.setSoundStart(enabled: true);
          for (
            var attempt = 0;
            attempt < 50 && !store.writeEntered;
            attempt++
          ) {
            await Future<void>.delayed(const Duration(milliseconds: 1));
          }
          expect(store.writeEntered, isTrue);
          var saved = false;
          final save = session.saveAs('Pending pair').then((_) => saved = true);
          await Future<void>.delayed(const Duration(milliseconds: 10));
          expect(saved, isFalse);
          expect(await sessions.listSessions(), isEmpty);
          store.pendingWrite!.complete();
          expect((await edit).isOk, isTrue);
          await save;
          expect(session.state.status, SessionStatus.success);
          final bundle = await sessions.read(
            await sessions.bundlePathOf(await idOf('Pending pair')),
          );
          expect(bundle.session.countInBars, 0);
          expect(bundle.session.autoRecord, isTrue);
        },
      );

      test(
        'recall restores the saved pair without rewriting startup preferences',
        () async {
          expect(
            (await tempo.recordStartControl.setCountInBars(2)).isOk,
            isTrue,
          );
          await session.saveAs('Two bars');
          expect(session.state.status, SessionStatus.success);
          expect(
            (await tempo.recordStartControl.setSoundStart(enabled: true)).isOk,
            isTrue,
          );
          await session.open(await idOf('Two bars'));
          expect(session.state.status, SessionStatus.success);
          expect(
            tempo.recordStartControl.recordStartSnapshot?.settings.countInBars,
            2,
          );
          expect(
            tempo.recordStartControl.recordStartSnapshot?.settings.soundStart,
            isFalse,
          );
          expect(engine.snapshot().countInBars, 2);
          expect(engine.snapshot().autoRecord, isFalse);
          expect(await settings.readRecordStartCheckpoint(), (
            countInBars: 0,
            soundStart: true,
          ));
        },
      );

      test(
        'a Sound edit refused at storage leaves the stored pair, and Save '
        'keeps it while Count-in is unavailable',
        () async {
          await session.saveAs('Protected');
          expect(session.state.status, SessionStatus.success);
          final manifest = File(
            '${await sessions.bundlePathOf(await idOf('Protected'))}/${Session.manifestName}',
          );
          final before = await manifest.readAsBytes();
          // Both keys were explicitly Off before the attempted Sound edit. The
          // first write now fails and its compensation is also unavailable.
          store.refuseWrite = true;
          final edit = await tempo.recordStartControl.setSoundStart(
            enabled: true,
          );
          expect(edit.status, RecordStartStatus.recoveryRequired);
          // Session capture uses the confirmed durable pair, so Save proceeds
          // while Count-in is unavailable and never writes Sound on.
          expect(
            tempo.recordStartOwner.durable,
            RecordStartSettings(countInBars: 0, soundStart: false),
          );
          await session.save();
          expect(session.state.status, SessionStatus.success);
          expect(await manifest.readAsBytes(), before);
          final saved = await sessions.read(
            await sessions.bundlePathOf(await idOf('Protected')),
          );
          expect(saved.session.countInBars, 0);
          expect(saved.session.autoRecord, isFalse);
          store.refuseWrite = false;
          expect((await tempo.recordStartOwner.recover()).isOk, isTrue);
          await session.save();
          expect(session.state.status, SessionStatus.success);
          final bundle = await sessions.read(
            await sessions.bundlePathOf(await idOf('Protected')),
          );
          expect(bundle.session.countInBars, 0);
          expect(bundle.session.autoRecord, isFalse);
        },
      );

      test(
        'an owed pair is saved as requested, and recall re-applies it with '
        'a receipt',
        () async {
          // Withhold the receipt: an unpumped engine consumes no command.
          pump.cancel();
          final edit = await tempo.recordStartControl.setCountInBars(4);
          expect(edit.status, RecordStartStatus.recoveryRequired);
          expect(looper.recordStartRecoveryRequired, isTrue);
          expect(
            tempo.recordStartOwner.durable,
            RecordStartSettings(countInBars: 4, soundStart: false),
          );
          pump = Timer.periodic(
            const Duration(milliseconds: 1),
            (_) => engine.pump(frames: 0),
          );
          await session.saveAs('Owed pair');
          expect(session.state.status, SessionStatus.success);
          final bundle = await sessions.read(
            await sessions.bundlePathOf(await idOf('Owed pair')),
          );
          expect(bundle.session.countInBars, 4);
          expect(bundle.session.autoRecord, isFalse);

          // Settle the obligation, then move away from the saved pair.
          expect((await tempo.recordStartOwner.recover()).isOk, isTrue);
          expect(
            (await tempo.recordStartControl.setCountInBars(1)).isOk,
            isTrue,
          );
          expect(engine.snapshot().countInBars, 1);
          await session.open(await idOf('Owed pair'));
          expect(session.state.status, SessionStatus.success);
          expect(looper.recordStartRecoveryRequired, isFalse);
          expect(looper.recordStartSettingsSettled, isTrue);
          expect(engine.snapshot().countInBars, 4);
          expect(
            tempo.recordStartControl.recordStartSnapshot?.settings.countInBars,
            4,
          );
        },
      );

      for (final bad in [
        (field: 'countInBars', value: 3 as Object),
        (field: 'trackLengthPresetOverrides', value: {'8': 4} as Object),
      ]) {
        test(
          'a Session with ${bad.field} ${bad.value} is refused before the rig '
          'is cleared',
          () async {
            await session.saveAs('Bad');
            expect(session.state.status, SessionStatus.success);
            final manifest = File(
              '${await sessions.bundlePathOf(await idOf('Bad'))}/${Session.manifestName}',
            );
            final json =
                jsonDecode(await manifest.readAsString())
                    as Map<String, dynamic>;
            json[bad.field] = bad.value;
            await manifest.writeAsString(jsonEncode(json));
            final before = engine.snapshot().tracks.first;
            expect(before.state, TrackState.playing);
            await session.open(await idOf('Bad'));
            expect(session.state.status, isNot(SessionStatus.success));
            // The live take is untouched: the decode refused the file.
            final after = engine.snapshot().tracks.first;
            expect(after.state, TrackState.playing);
            expect(after.lengthFrames, before.lengthFrames);
          },
        );
      }
    },
  );
}
