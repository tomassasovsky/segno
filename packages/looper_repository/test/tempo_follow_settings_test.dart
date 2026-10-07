import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno_engine/segno_engine.dart' show TrackSnapshot;

import 'helpers/fake_audio_engine.dart';

void main() {
  group('Follow tempo and Pitch settings (#1179)', () {
    late FakeAudioEngine engine;
    late LooperRepository repository;
    late StreamController<void> ticks;

    setUp(() {
      engine = FakeAudioEngine();
      ticks = StreamController<void>.broadcast(sync: true);
      repository = LooperRepository(engine: engine, ticker: ticks.stream);
    });
    tearDown(() async {
      await repository.dispose();
      await ticks.close();
    });

    test('a Session with an override past the eighth track is refused '
        'before anything is cleared (Part 4b)', () async {
      repository.startEngine(const EngineConfig());
      engine.calls.clear();
      for (final rig in [
        const SessionRig(trackFollowTempoOverrides: {8: true}),
        const SessionRig(trackPitchModeOverrides: {-1: PitchMode.unchanged}),
      ]) {
        await expectLater(repository.applySession(rig), throwsStateError);
      }
      expect(engine.calls, isEmpty);
    });

    test('a vector sends only what the engine does not hold and is accepted '
        'on every receipt', () async {
      repository.startEngine(const EngineConfig());
      expect(
        repository.setFollowTempoSettings(
          defaultFollow: true,
          trackOverrides: const {2: false},
        ),
        EngineResult.ok,
      );
      expect(engine.settingCalls, [
        (kind: 'follow', channel: null, value: true),
        (kind: 'follow', channel: 2, value: false),
      ]);
      // The fake answers at once: the repository's own poll settles it.
      expect(await repository.settleFollowTempo(), EngineResult.ok);
      expect(repository.followTempoSettingsSettled, isTrue);
      expect(repository.defaultFollowTempo, isTrue);
      expect(repository.state.defaultFollowTempo, isTrue);
      expect(repository.state.tracks[2].followTempoOverride, isFalse);
      expect(repository.state.tracks[0].followTempoOverride, isNull);
      expect(repository.followTempoRestartIntent.defaultFollow, isTrue);
      expect(repository.followTempoRestartIntent.trackOverrides, {2: false});
      engine.settingCalls.clear();
      expect(
        repository.setPitchModeSettings(
          defaultMode: PitchMode.followsSpeed,
          trackOverrides: const {1: PitchMode.unchanged},
        ),
        EngineResult.ok,
      );
      expect(engine.settingCalls, [
        (kind: 'pitch', channel: null, value: PitchMode.followsSpeed),
        (kind: 'pitch', channel: 1, value: PitchMode.unchanged),
      ]);
      expect(await repository.settlePitchMode(), EngineResult.ok);
      expect(repository.state.defaultPitchMode, PitchMode.followsSpeed);
      expect(
        repository.state.tracks[1].pitchModeOverride,
        PitchMode.unchanged,
      );
    });

    test('an admission refusal sends nothing more; a failed receipt leaves '
        'the vector owed until Retry', () async {
      repository.startEngine(const EngineConfig());
      engine.settingAdmission = EngineResult.invalid;
      expect(
        repository.setFollowTempoSettings(
          defaultFollow: true,
          trackOverrides: const {},
        ),
        EngineResult.invalid,
      );
      expect(repository.followTempoRecoveryRequired, isFalse);
      expect(repository.defaultFollowTempo, isFalse);
      engine
        ..settingAdmission = EngineResult.ok
        ..settingResult = EngineResult.notReady;
      final failures = <EngineResult>[];
      final sub = repository.followTempoFailures.listen(failures.add);
      addTearDown(sub.cancel);
      // The receipt fails as soon as it is read: the vector is owed.
      expect(
        repository.setFollowTempoSettings(
          defaultFollow: true,
          trackOverrides: const {},
        ),
        EngineResult.invalid,
      );
      expect(await repository.settleFollowTempo(), EngineResult.invalid);
      expect(repository.followTempoRecoveryRequired, isTrue);
      expect(failures, [EngineResult.invalid]);
      expect(
        repository.setFollowTempoSettings(
          defaultFollow: false,
          trackOverrides: const {},
        ),
        EngineResult.notReady, // owed: Retry first
      );
      engine.settingResult = EngineResult.ok;
      expect(repository.recoverFollowTempoSettings(), EngineResult.ok);
      expect(await repository.settleFollowTempo(), EngineResult.ok);
      expect(repository.followTempoRecoveryRequired, isFalse);
      expect(repository.defaultFollowTempo, isTrue);
      expect(
        repository.setPitchModeSettings(
          defaultMode: PitchMode.unchanged,
          trackOverrides: const {9: PitchMode.unchanged},
        ),
        EngineResult.invalid,
      );
    });

    test('a stopped engine stages the vector and a start replays it', () {
      expect(
        repository.setPitchModeSettings(
          defaultMode: PitchMode.followsSpeed,
          trackOverrides: const {3: PitchMode.unchanged},
        ),
        EngineResult.ok,
      );
      expect(engine.settingCalls, isEmpty);
      expect(repository.pitchModeSettingsSettled, isTrue);
      expect(
        repository.pitchModeRestartIntent.defaultMode,
        PitchMode.followsSpeed,
      );
      expect(repository.pitchModeRestartIntent.trackOverrides, {
        3: PitchMode.unchanged,
      });
      expect(repository.startEngine(const EngineConfig()), EngineResult.ok);
      expect(engine.settingCalls, [
        (kind: 'pitch', channel: null, value: PitchMode.followsSpeed),
        (kind: 'pitch', channel: 3, value: PitchMode.unchanged),
      ]);
    });

    test('projects the recorded tempo, the follow state and the cents', () {
      repository.startEngine(const EngineConfig());
      final subscription = repository.looperState.listen((_) {});
      addTearDown(subscription.cancel);
      expect(repository.state.tempoFollow, TempoFollowState.free);
      engine.nextSnapshot = engine.nextSnapshot.copyWith(
        recordedTempoBpm: 120,
        tempoFollow: TempoFollowState.noFollower,
        tracks: [
          const TrackSnapshot(
            state: TrackState.playing,
            volume: 1,
            muted: false,
            lengthFrames: 8000,
            undoDepth: 0,
            rms: 0,
            peak: 0,
            pitchEffectiveCents: -498,
          ),
          ...engine.nextSnapshot.tracks.skip(1),
        ],
      );
      ticks.add(null);
      expect(repository.state.recordedTempoBpm, 120);
      expect(repository.state.tempoFollow, TempoFollowState.noFollower);
      expect(repository.state.tracks[0].pitchEffectiveCents, -498);
    });
  });
}
