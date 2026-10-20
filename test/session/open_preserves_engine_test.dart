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

/// Open's preservation (plan D7, D8) through a real [SessionCubit] on the
/// real engine, with the real fingerprint: nothing stubbed between the
/// press and the bundle on disk (Part 4 review, findings 1 to 3).
void main() {
  final nativeAvailable = Platform.environment.containsKey('SEGNO_ENGINE_LIB');
  group('Open on the real engine', skip: !nativeAvailable, () {
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

    Future<SessionId> idOf(String name) async =>
        (await sessions.listSessions()).singleWhere((s) => s.name == name).id;

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
      directory = Directory.systemTemp.createTempSync('segno-open-engine-');
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

    test('the first session plays back exactly after another one was '
        'recorded, preserved and left', () async {
      await session.saveAs('First');
      final first = track(0);
      await session.saveAs('Second');
      take(1, .25);
      final second = track(1);
      expect(second, isNotEmpty);

      await session.open(await idOf('First'));
      expect(session.state.status, SessionStatus.success);
      expect(session.state.currentSessionName, 'First');
      expect(looper.play(), EngineResult.ok);
      engine.pump();
      expect(track(0), first);
      expect(track(1), isEmpty);

      // The second session was saved with its new take before it was left.
      final saved = await sessions.read(
        await sessions.bundlePathOf(await idOf('Second')),
      );
      expect(saved.session.tracks.map((t) => t.channel), [0, 1]);
      expect(saved.laneStems[(1, 0)]!.last, second);
    });

    test(
      'a session that was only played and stopped is not saved again',
      () async {
        await session.saveAs('Other');
        await session.saveAs('Played');
        // Saved while playing; left stopped.
        expect(looper.stopTrack(), EngineResult.ok);
        engine.pump();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(looper.state.tracks.first.state, TrackState.stopped);
        var writes = 0;
        SessionRepository.debugOnSaveWrite = (_) => writes++;

        await session.open(await idOf('Other'));

        expect(session.state.status, SessionStatus.success);
        expect(writes, 0);
      },
    );

    test('a take still recording is finished and saved, not lost', () async {
      await session.saveAs('Target');
      await session.saveAs('Recording');
      expect(looper.record(channel: 1), EngineResult.ok);
      engine
        ..pump(frames: 256, input: .25)
        ..pump();
      expect(engine.snapshot().tracks[1].state, TrackState.recording);

      await session.open(await idOf('Target'));

      expect(session.state.status, SessionStatus.success);
      final saved = await sessions.read(
        await sessions.bundlePathOf(await idOf('Recording')),
      );
      expect(saved.session.tracks.map((t) => t.channel), [0, 1]);
      expect(saved.laneStems[(1, 0)]!.last, isNotEmpty);
    });

    test('a track armed for the loop top is withdrawn before the outgoing '
        'rig is saved: no take starts, and the bundle holds only what was '
        'there (#1178 Part 4 lows review, 2)', () async {
      await session.saveAs('Target');
      await session.saveAs('Armed');
      // Commands still apply, but time stands still: the loop top the arm
      // waits for never comes unless the Open fails to withdraw it.
      pump.cancel();
      pump = Timer.periodic(
        const Duration(milliseconds: 1),
        (_) => engine.pump(frames: 0),
      );
      expect(
        looper.setTrackRecordTiming(
          channel: 1,
          timing: RecordTiming.loopStart,
        ),
        EngineResult.ok,
      );
      engine.pump(frames: 64);
      // Let the timing edit settle before the press, as a player's would.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(looper.record(channel: 1), EngineResult.ok);
      engine.pump(frames: 0);
      expect(engine.snapshot().tracks[1].pending, isTrue);

      await session.open(await idOf('Target'));

      expect(session.state.status, SessionStatus.success);
      final armed = engine.snapshot().tracks[1];
      expect(armed.pending, isFalse);
      expect(armed.state, isNot(TrackState.recording));
      final saved = await sessions.read(
        await sessions.bundlePathOf(await idOf('Armed')),
      );
      expect(saved.session.tracks.map((t) => t.channel), [0]);
    });

    test(
      'an overdub in progress is punched out and saved, not refused',
      () async {
        await session.saveAs('Target');
        await session.saveAs('Overdub');
        // Let the repository observe the published take before punching in.
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(looper.record(), EngineResult.ok);
        engine
          ..pump(frames: 128, input: .25)
          ..pump();
        expect(engine.snapshot().tracks[0].state, TrackState.overdubbing);

        await session.open(await idOf('Target'));

        expect(session.state.status, SessionStatus.success);
        final saved = await sessions.read(
          await sessions.bundlePathOf(await idOf('Overdub')),
        );
        // The overdub is kept: layers over the first take.
        expect(saved.laneStems[(0, 0)]!.length, greaterThan(1));
      },
    );

    test('New loop from a session that was only played and stopped saves '
        'nothing of it and empties every track', () async {
      await session.saveAs('Played');
      final played = await sessions.bundlePathOf(await idOf('Played'));
      expect(looper.stopTrack(), EngineResult.ok);
      engine.pump();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final writes = <String>[];
      SessionRepository.debugOnSaveWrite = writes.add;

      await session.newLoop();

      expect(session.state.status, SessionStatus.success);
      expect(session.state.currentSessionName, 'New loop 1');
      expect(
        writes.where(
          (path) =>
              path == played ||
              path.startsWith('$played/') ||
              path.startsWith('$played.'),
        ),
        isEmpty,
      );
      for (final track in engine.snapshot().tracks) {
        expect(track.state, TrackState.empty);
      }
    });

    test('New loop while a take records keeps the take', () async {
      await session.saveAs('Recording');
      expect(looper.record(channel: 1), EngineResult.ok);
      engine
        ..pump(frames: 256, input: .25)
        ..pump();

      await session.newLoop();

      expect(session.state.status, SessionStatus.success);
      final saved = await sessions.read(
        await sessions.bundlePathOf(await idOf('Recording')),
      );
      expect(saved.session.tracks.map((t) => t.channel), [0, 1]);
      expect(engine.snapshot().tracks[1].state, TrackState.empty);
    });
  });
}
