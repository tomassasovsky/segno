import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

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
import 'package:segno/session/application/session_settings_coordinator.dart';
import 'package:segno/session/session.dart';
import 'package:segno_engine/segno_engine.dart' show PumpedNativeEngine;
import 'package:session_repository/session_repository.dart';
import 'package:settings_repository/settings_repository.dart';

import '../helpers/fake_key_value_store.dart';

/// A Save that writes a rig with no audio over a session that held some
/// (SEG-110), through a real [SessionCubit] on the real engine: the Save goes
/// through, and its Undo puts the takes back and saves them again.
void main() {
  group('A Save that drops the audio, on the real engine', () {
    late PumpedNativeEngine engine;
    late GuardRegistry guards;
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
    late Directory directory;
    late Timer pump;

    /// Records a 256-frame take of [level] on [channel] and leaves it
    /// playing.
    void take(int channel, double level) {
      expect(looper.record(channel: channel), EngineResult.ok);
      engine.pump(frames: 256, input: level);
      expect(looper.record(channel: channel), EngineResult.ok);
      engine.pump();
    }

    setUp(() async {
      engine = PumpedNativeEngine();
      guards = GuardRegistry();
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
        (_) => engine.pump(frames: 64),
      );
      directory = Directory.systemTemp.createTempSync('segno-save-undo-');
      final settings = SettingsRepository(store: FakeKeyValueStore());
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
        guards: guards,
        engine: engine,
        sessionsRoot: () async => directory.path,
      );
      performance = PerformanceRepository(
        guards: guards,
        engine: engine,
        exportsRoot: () async => directory.path,
      );
      session = SessionCubit(
        guards: guards,
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
      take(0, .5);
    });

    tearDown(() async {
      SessionRepository.debugOnSaveWrite = null;
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

    Float32List track(int channel) => engine.exportTrack(channel);

    /// The bundle's audio files: its layer WAVs and its mixdown.
    Future<List<String>> audioOf(SessionId id) async => [
      for (final file in await sessions.bundleFiles(id))
        if (file.endsWith('.wav')) file,
    ];

    Future<List<int>> mixdownOf(SessionId id) async => File(
      '${await sessions.bundlePathOf(id)}/${SessionRepository.mixdownName}',
    ).readAsBytesSync();

    /// Waits until the engine has published [done].
    Future<void> until(bool Function() done) async {
      final waited = Stopwatch()..start();
      while (!done()) {
        if (waited.elapsed > const Duration(seconds: 2)) {
          fail('timed out');
        }
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
    }

    /// Clears every track, as the pedal's Clear all does.
    Future<void> clearAll() async {
      expect(looper.clearAll([0, 1]), EngineResult.ok);
      await until(
        () =>
            looper.state.clearAllUndoable &&
            !looper.state.tracks.any((t) => t.hasContent),
      );
    }

    Future<SessionId> savedWithAudio() async {
      take(1, .25);
      await session.saveAs('Kept');
      final id = session.state.currentSessionId!;
      expect(await audioOf(id), contains(SessionRepository.mixdownName));
      return id;
    }

    test('Clear all, Save, then Undo gives the bundle its WAVs and mixdown '
        'back', () async {
      final id = await savedWithAudio();
      final audio = await audioOf(id);
      final stems = (await sessions.read(await sessions.bundlePathOf(id)))
          .laneStems;
      final mixdown = await mixdownOf(id);
      await clearAll();

      await session.save();

      // The Save goes through: the session keeps its settings, without audio.
      expect(session.state.status, SessionStatus.success);
      expect(session.state.outcome, SessionOutcome.saved);
      expect(session.state.droppedAudio, DroppedAudio.undoable);
      expect(await audioOf(id), isEmpty);

      await session.undoDroppedAudio();

      expect(session.state.status, SessionStatus.success);
      expect(session.state.outcome, SessionOutcome.saved);
      expect(session.state.droppedAudio, isNull);
      expect(session.state.currentSessionId, id);
      // The takes are back as they were; each track also keeps the clear as
      // a Redo, as the Undo of a Clear all leaves it.
      final restored = await sessions.read(await sessions.bundlePathOf(id));
      expect(restored.session.tracks.map((t) => t.channel), [0, 1]);
      expect(restored.laneStems.keys, stems.keys);
      for (final key in stems.keys) {
        expect(
          restored.laneStems[key]!.first,
          stems[key]!.single,
          reason: '$key',
        );
      }
      expect(await audioOf(id), containsAll(audio));
      expect(await mixdownOf(id), mixdown);
    });

    test('a track cleared on its own is not restored: the Save offers no '
        'Undo', () async {
      final id = await savedWithAudio();
      expect(looper.clear(), EngineResult.ok);
      expect(looper.clear(channel: 1), EngineResult.ok);
      await until(() => !looper.state.tracks.any((t) => t.hasContent));
      expect(looper.state.clearAllUndoable, isFalse);

      await session.save();

      expect(session.state.outcome, SessionOutcome.saved);
      expect(session.state.droppedAudio, DroppedAudio.gone);
      await session.undoDroppedAudio();
      expect(await audioOf(id), isEmpty);
      expect(looper.state.tracks.any((t) => t.hasContent), isFalse);
    });

    test('opening another session ends the Undo', () async {
      await session.saveAs('Other');
      final id = await savedWithAudio();
      await clearAll();
      await session.save();
      expect(session.state.droppedAudio, DroppedAudio.undoable);

      await session.open(
        (await sessions.listSessions())
            .singleWhere((s) => s.name == 'Other')
            .id,
      );
      expect(session.state.outcome, SessionOutcome.loaded);
      await session.undoDroppedAudio();

      expect(session.state.outcome, SessionOutcome.loaded);
      expect(await audioOf(id), isEmpty);
    });

    test('a Save of an empty rig over a session with no audio drops '
        'nothing', () async {
      await clearAll();
      await session.saveAs('Setup');
      await session.save();

      expect(session.state.outcome, SessionOutcome.saved);
      expect(session.state.droppedAudio, isNull);
    });

    test('a Save that keeps audio drops nothing', () async {
      await savedWithAudio();
      await session.save();

      expect(session.state.outcome, SessionOutcome.saved);
      expect(session.state.droppedAudio, isNull);
    });
  });
}
