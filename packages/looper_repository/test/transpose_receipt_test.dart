import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno_engine/segno_engine.dart' show TrackSnapshot;

import 'helpers/fake_audio_engine.dart';

TrackSnapshot _playing(TransposePitch transpose) => TrackSnapshot(
  state: TrackState.playing,
  volume: 1,
  muted: false,
  lengthFrames: 48000,
  undoDepth: 0,
  rms: 0,
  peak: 0,
  transpose: transpose,
);

void main() {
  group('LooperRepository Transpose (#1179)', () {
    late FakeAudioEngine engine;
    late LooperRepository repository;
    late StreamController<void> ticks;

    setUp(() {
      engine = FakeAudioEngine();
      ticks = StreamController<void>.broadcast(sync: true);
      repository = LooperRepository(engine: engine, ticker: ticks.stream)
        ..startEngine(const EngineConfig());
    });
    tearDown(() async {
      await repository.dispose();
      await ticks.close();
    });

    test(
      'a step completes with the callback receipt, the limit included',
      () async {
        expect(
          await repository.transposeTrack(channel: 2, delta: -1),
          EngineResult.ok,
        );
        expect(engine.lastTransposeStep, (channel: 2, delta: -1));
        engine.transposeResult = EngineResult.capacity; // at +-12
        expect(
          await repository.transposeTrack(channel: 2, delta: 1),
          EngineResult.capacity,
        );
        expect(engine.lastTransposeStep, (channel: 2, delta: 1));
      },
    );

    test(
      'install and bypass post their arguments and await receipts',
      () async {
        expect(
          await repository.installTranspose(channel: 1, semitones: -7),
          EngineResult.ok,
        );
        expect(engine.lastTransposeInstall, (channel: 1, semitones: -7));
        engine.transposeResult = EngineResult.notReady;
        expect(
          await repository.setTransposeBypass(bypassed: true),
          EngineResult.notReady,
        );
        expect(engine.lastTransposeBypass, isTrue);
      },
    );

    test('an admission refusal completes at once and posts nothing', () async {
      engine.transposeAdmission = EngineResult.invalid; // e.g. an empty track
      expect(
        await repository.transposeTrack(channel: 0, delta: 1),
        EngineResult.invalid,
      );
      expect(
        await repository.installTranspose(channel: 0, semitones: 2),
        EngineResult.invalid,
      );
      expect(
        await repository.setTransposeBypass(bypassed: false),
        EngineResult.invalid,
      );
      expect(engine.lastTransposeStep, isNull);
      expect(engine.lastTransposeInstall, isNull);
      expect(engine.lastTransposeBypass, isNull);
    });

    test('projects stored and sounding pitches and the bypass', () async {
      // What the stream published, so a change the dedupe swallows fails.
      LooperState? published;
      final subscription = repository.looperState.listen((s) => published = s);
      addTearDown(subscription.cancel);
      Future<LooperState> tick() async {
        ticks.add(null);
        await Future<void>.delayed(Duration.zero);
        return published!;
      }

      expect(repository.state.tracks[0].transpose, (stored: 0, effective: 0));
      expect(repository.state.transposeBypass, isFalse);
      // The bypass alone is a change worth publishing, even with no track
      // transposed.
      engine.nextSnapshot = engine.nextSnapshot.copyWith(transposeBypass: true);
      expect((await tick()).transposeBypass, isTrue);
      engine.nextSnapshot = engine.nextSnapshot.copyWith(
        transposeBypass: false,
      );
      expect((await tick()).transposeBypass, isFalse);
      // Stored but pending: the face must not claim the pitch yet.
      engine.nextSnapshot = engine.nextSnapshot.copyWith(
        tracks: [
          _playing((stored: 5, effective: 0)),
          ...engine.nextSnapshot.tracks.skip(1),
        ],
      );
      expect((await tick()).tracks[0].transpose, (stored: 5, effective: 0));
      engine.nextSnapshot = engine.nextSnapshot.copyWith(
        tracks: [
          _playing((stored: 5, effective: 5)),
          ...engine.nextSnapshot.tracks.skip(1),
        ],
      );
      expect((await tick()).tracks[0].transpose, (stored: 5, effective: 5));
      engine.nextSnapshot = engine.nextSnapshot.copyWith(
        transposeBypass: true,
        tracks: [
          _playing((stored: 5, effective: 0)),
          ...engine.nextSnapshot.tracks.skip(1),
        ],
      );
      expect((await tick()).transposeBypass, isTrue);
      expect(published!.tracks[0].transpose, (stored: 5, effective: 0));
    });
  });
}
