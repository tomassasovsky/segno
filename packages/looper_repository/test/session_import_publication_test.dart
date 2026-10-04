@Tags(['fuzz'])
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno_engine/segno_engine.dart'
    show PumpedNativeEngine, TrackSnapshot;

import 'helpers/fake_audio_engine.dart';

class _ImportEngine extends PumpedNativeEngine {
  bool holdCommit = false;
  bool holdSettings = false;
  bool settingsPosted = false;
  bool dropCommit = false;
  bool committed = false;
  bool staged = false;
  bool refuseCleanup = false;
  int? failedChannel;
  int stops = 0;

  bool get canPump =>
      (!holdCommit || !committed) && (!holdSettings || !settingsPosted);

  @override
  EngineResult setRecordStartSettings({
    required int countInBars,
    required bool soundStart,
    required RecordStartEditKind editKind,
  }) {
    final result = super.setRecordStartSettings(
      countInBars: countInBars,
      soundStart: soundStart,
      editKind: editKind,
    );
    if (result.isOk) settingsPosted = true;
    return result;
  }

  @override
  EngineResult importLayer(
    int channel,
    int lane,
    int ordinal,
    Float32List pcm,
  ) {
    if (channel == failedChannel) return EngineResult.invalid;
    final result = super.importLayer(channel, lane, ordinal, pcm);
    if (result.isOk) staged = true;
    return result;
  }

  @override
  EngineResult commitSession(int baseFrames, {required int loopBars}) {
    if (dropCommit) return EngineResult.ok;
    final result = super.commitSession(baseFrames, loopBars: loopBars);
    if (result.isOk) committed = true;
    return result;
  }

  @override
  EngineResult clear({int channel = 0}) {
    if (staged && refuseCleanup) return EngineResult.notReady;
    return super.clear(channel: channel);
  }

  @override
  EngineResult stop() {
    stops++;
    return super.stop();
  }
}

SessionRig _rig({bool secondTrack = false}) => SessionRig(
  baseLengthFrames: 256,
  tracks: [
    for (final channel in [0, if (secondTrack) 1])
      SessionRigTrack(
        channel: channel,
        lanes: [
          SessionRigLane(
            lane: 0,
            layers: [Float32List.fromList(List.filled(256, .25))],
            volume: 1,
            muted: false,
            outputMask: 1,
            inputChannel: 0,
          ),
        ],
      ),
  ],
);

Future<void> _until(bool Function() done) async {
  for (var i = 0; i < 1000 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  expect(done(), isTrue);
}

void _coherent(LooperState state) {
  for (final track in state.tracks) {
    if (track.state == TrackState.empty) {
      expect(track.lengthFrames, 0);
      expect(track.undoDepth, 0);
      expect(track.lanes.every((lane) => lane.lengthFrames == 0), isTrue);
    }
  }
}

void main() {
  test('stop supersedes apply before its first wait returns', () async {
    final engine = FakeAudioEngine();
    final repository = LooperRepository(engine: engine);
    addTearDown(repository.dispose);
    expect(repository.startEngine(const EngineConfig()), EngineResult.ok);
    await repository.settleMixSettings();
    final loading = repository.applySession(const SessionRig());
    repository.stopEngine();
    final calls = engine.calls.length;
    await expectLater(loading, throwsStateError);
    expect(engine.calls.length, calls);
  });

  test(
    'ordinary empty redo and invalid raw states are not normalized',
    () async {
      final engine = FakeAudioEngine();
      final repository = LooperRepository(engine: engine);
      addTearDown(repository.dispose);
      engine.nextSnapshot = engine.nextSnapshot.copyWith(
        tracks: const [
          TrackSnapshot(
            state: TrackState.empty,
            volume: 1,
            muted: false,
            lengthFrames: 0,
            undoDepth: 0,
            redoDepth: 2,
            rms: 0,
            peak: 0,
          ),
          TrackSnapshot(
            state: TrackState.empty,
            volume: 1,
            muted: false,
            lengthFrames: 256,
            undoDepth: 1,
            rms: 0,
            peak: 0,
          ),
        ],
      );
      expect(repository.state.tracks[0].redoDepth, 2);
      expect(repository.state.tracks[1].lengthFrames, 256);
      expect(repository.state.tracks[1].undoDepth, 1);
    },
  );
  group('session import publication', () {
    late _ImportEngine engine;
    late LooperRepository repository;
    late Timer pump;
    late StreamSubscription<LooperState> subscription;
    late List<LooperState> states;

    setUp(() async {
      engine = _ImportEngine();
      repository = LooperRepository(engine: engine);
      states = [];
      subscription = repository.looperState.listen(states.add);
      expect(
        repository.startEngine(
          const EngineConfig(
            sampleRate: 8000,
            inputChannels: 1,
            outputChannels: 1,
            maxLoopFrames: 8192,
          ),
        ),
        EngineResult.ok,
      );
      pump = Timer.periodic(const Duration(milliseconds: 1), (_) {
        if (engine.canPump) engine.pump(frames: 0);
      });
      expect(await repository.settleMixSettings(), EngineResult.ok);
    });

    tearDown(() async {
      pump.cancel();
      await subscription.cancel();
      await repository.dispose();
    });

    test(
      'apply reserves native acquisition and history before importing',
      () async {
        engine
          ..settingsPosted = false
          ..holdSettings = true;
        final loading = repository.applySession(_rig());
        await _until(() => engine.settingsPosted);
        expect(engine.staged, isFalse);
        final generation = repository.mixGeneration;
        expect(repository.play(), EngineResult.notReady);
        expect(repository.record(), EngineResult.notReady);
        expect(repository.undo(), EngineResult.notReady);
        expect(repository.redo(), EngineResult.notReady);
        expect(repository.clear(), EngineResult.notReady);
        expect(repository.clearAll([0, 1]), EngineResult.notReady);
        expect(repository.undoClearAll(), EngineResult.notReady);
        expect(
          repository.startEngine(const EngineConfig()),
          EngineResult.notReady,
        );
        expect(repository.mixGeneration, generation);
        expect(engine.stops, 0);
        engine.holdSettings = false;
        await loading;
        expect(repository.state.tracks[0].lengthFrames, 256);
      },
    );

    test(
      'an accepted command without an actual commit is refused and cleaned',
      () async {
        engine.dropCommit = true;
        await expectLater(repository.applySession(_rig()), throwsStateError);
        expect(engine.snapshot().tracks[0].lengthFrames, 0);
        _coherent(repository.state);
        engine.dropCommit = false;
        await repository.applySession(_rig());
        expect(repository.state.tracks[0].lengthFrames, 256);
      },
    );

    test(
      'a commit deadline cannot release partial content after failed cleanup',
      () async {
        engine.holdCommit = true;
        await expectLater(
          repository.applySession(
            _rig(),
            clearPollInterval: const Duration(milliseconds: 2),
            clearPollAttempts: 30,
          ),
          throwsStateError,
        );
        expect(engine.stops, greaterThan(0));
        _coherent(repository.state);
        expect(repository.record(), EngineResult.notReady);
        expect(repository.play(), EngineResult.notReady);
        states.forEach(_coherent);
        engine.holdCommit = false;
        expect(repository.startEngine(const EngineConfig()), EngineResult.ok);
        await repository.applySession(_rig());
        expect(repository.state.tracks[0].lengthFrames, 256);
      },
    );

    test('staged audio stays private until the real commit callback', () async {
      engine.holdCommit = true;
      var completed = false;
      final loading = repository.applySession(_rig()).then((_) {
        completed = true;
      });
      await _until(() => engine.committed);
      expect(engine.commandsSettled, isFalse);
      expect(engine.snapshot().tracks[0].lengthFrames, 256);
      expect(engine.snapshot().tracks[0].state, TrackState.empty);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      _coherent(repository.state);
      states.forEach(_coherent);
      expect(completed, isFalse);
      engine.holdCommit = false;
      await loading;
      expect(repository.state.tracks[0].state, TrackState.playing);
      expect(repository.state.tracks[0].lengthFrames, 256);
      expect(engine.exportTrack(0).first, closeTo(.25, .00001));
    });

    test(
      'partial import failure clears staged content before returning',
      () async {
        engine.failedChannel = 1;
        await expectLater(
          repository.applySession(_rig(secondTrack: true)),
          throwsStateError,
        );
        expect(engine.staged, isTrue);
        expect(engine.snapshot().tracks[0].lengthFrames, 0);
        _coherent(repository.state);
        states.forEach(_coherent);
        engine.failedChannel = null;
        await repository.applySession(_rig());
        expect(repository.state.tracks[0].lengthFrames, 256);
      },
    );

    test(
      'refused cleanup stays hidden and stopped until a successful retry',
      () async {
        engine
          ..failedChannel = 1
          ..refuseCleanup = true;
        await expectLater(
          repository.applySession(_rig(secondTrack: true)),
          throwsStateError,
        );
        expect(engine.stops, greaterThan(0));
        _coherent(repository.state);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        states.forEach(_coherent);
        engine
          ..failedChannel = null
          ..refuseCleanup = false;
        expect(repository.startEngine(const EngineConfig()), EngineResult.ok);
        await repository.applySession(_rig());
        expect(repository.state.tracks[0].lengthFrames, 256);
      },
    );

    test('a superseded commit wait never clears the replacement rig', () async {
      engine.holdCommit = true;
      final first = repository.applySession(_rig());
      final rejected = expectLater(first, throwsStateError);
      await _until(() => engine.committed);
      engine.holdCommit = false;
      await repository.applySession(_rig(secondTrack: true));
      await rejected;
      expect(repository.state.tracks[0].lengthFrames, 256);
      expect(repository.state.tracks[1].lengthFrames, 256);
      expect(engine.stops, 0);
      states.forEach(_coherent);
    });
  }, skip: !Platform.environment.containsKey('SEGNO_ENGINE_LIB'));
}
