@Tags(['fuzz'])
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno_engine/segno_engine.dart'
    as le
    show AudioDevice, PumpedNativeEngine;

/// The reconnect supervisor against the REAL native engine (#1140): a pinned
/// device is lost, reappears in enumeration, and the repository reopens it
/// through `le_engine_reopen_configured` with the recorded loops intact.
///
/// Self-skips when `SEGNO_ENGINE_LIB` is unset; build it first:
///   export SEGNO_ENGINE_LIB="$(bash packages/segno_engine/tool/build_test_lib.sh)"
void main() {
  final library = Platform.environment['SEGNO_ENGINE_LIB'];
  final skip = library == null || library.isEmpty
      ? 'Build packages/segno_engine/tool/build_test_lib.sh and set SEGNO_ENGINE_LIB'
      : null;

  const pinnedId = 'out-1';
  const pinnedDevice = le.AudioDevice(
    id: pinnedId,
    name: 'Scarlett 2i2',
    isDefault: false,
    isInput: false,
  );
  const config = EngineConfig(
    sampleRate: 48000,
    inputChannels: 1,
    outputChannels: 1,
    maxLoopFrames: 1000,
    playbackDeviceId: pinnedId,
  );

  late le.PumpedNativeEngine engine;
  late LooperRepository repository;
  late StreamController<void> ticks;
  late StreamController<void> reconnectTicks;

  /// Records a 64-frame loop of [value] on [channel] and lets it play.
  void recordLoop(int channel, double value) {
    expect(engine.record(channel: channel), EngineResult.ok);
    engine.pump(frames: 64, input: value);
    expect(engine.record(channel: channel), EngineResult.ok);
    engine.pump(frames: 0);
    expect(engine.snapshot().tracks[channel].state, TrackState.playing);
  }

  /// One repository poll on the current native snapshot.
  Future<void> tick() async {
    ticks.add(null);
    await Future<void>.delayed(Duration.zero);
  }

  /// The device goes away: the pump reports it absent and the supervisor
  /// starts polling enumeration, which finds nothing.
  Future<void> loseDevice() async {
    engine
      ..simulateDeviceLoss()
      ..simulatedDevices = const [];
    await tick();
    expect(repository.state.status.devicePresent, isFalse);
  }

  /// The device returns to enumeration; the supervisor's next tick reopens.
  Future<void> replugDevice() async {
    engine.simulatedDevices = const [pinnedDevice];
    reconnectTicks.add(null);
    await Future<void>.delayed(Duration.zero);
    // The replayed rig sits in the command ring until the callback runs.
    engine.pump(frames: 0);
    await tick();
  }

  setUp(() {
    engine = le.PumpedNativeEngine()..simulatedDevices = const [pinnedDevice];
    ticks = StreamController<void>.broadcast(sync: true);
    reconnectTicks = StreamController<void>.broadcast(sync: true);
    repository = LooperRepository(
      engine: engine,
      ticker: ticks.stream,
      reconnectTicker: reconnectTicks.stream,
    );
    expect(repository.startEngine(config), EngineResult.ok);
    engine.pump(frames: 0);
  });
  tearDown(() async {
    await repository.dispose();
    await ticks.close();
    await reconnectTicks.close();
  });

  group('reconnect through the real engine', () {
    test(
      'a replugged pinned device brings the loops back stopped, with history, '
      'under one new mix generation and the unchanged session revision',
      () async {
        final states = <LooperState>[];
        final subscription = repository.looperState.listen(states.add);
        addTearDown(subscription.cancel);
        final confirmations = <({int mixGeneration, int sessionRevision})>[];
        final confirmed = repository.fxReplayConfirmed.listen(
          confirmations.add,
        );
        addTearDown(confirmed.cancel);
        await tick();

        recordLoop(0, .5);
        // One overdub pass: a committed layer the reopen must keep peelable.
        expect(engine.record(), EngineResult.ok);
        engine.pump(frames: 64, input: .25);
        expect(engine.record(), EngineResult.ok);
        engine
          ..pump(frames: 0)
          ..pump(frames: 1)
          ..pump(frames: 0);
        recordLoop(1, .3);
        // A remembered lane mute and a Fade in flight ride the reopen too.
        expect(
          repository.setLaneMute(channel: 1, lane: 0, muted: true),
          EngineResult.ok,
        );
        engine.pump(frames: 0);
        final identity = engine.snapshot().tracks[0].fade;
        final installed = repository.installFade(
          channel: 0,
          image: FadeImage(
            target: 0,
            fullTravelSeconds: 1,
            lifetime: identity.lifetime,
            generation: identity.generation,
          ),
        );
        engine.pump(frames: 0);
        expect(await installed, EngineResult.ok);
        engine.pump(frames: 12000); // a quarter of the way down
        await tick();
        final before = repository.state;
        expect(before.tracks[0].undoDepth, 1);
        expect(before.tracks[0].state, TrackState.playing);
        final pcm0 = engine.exportTrack(0);
        final pcm1 = engine.exportTrack(1);
        final mixGeneration = before.mixGeneration;
        final sessionRevision = repository.sessionRevision;

        await loseDevice();
        // A Fade admitted while the device is away can never apply: its waiter
        // completes notReady when the reopen retires the lifetime.
        final pendingFade = repository.toggleFade(channel: 0, seconds: 1);

        await replugDevice();
        expect(await pendingFade, EngineResult.notReady);
        final after = repository.state;
        expect(after.status.devicePresent, isTrue);
        expect(after.status.isConnected, isTrue);
        expect(
          after.status.reopen,
          const EngineReopened(
            outcome: ReopenOutcome.retained,
            droppedTracks: 0,
            previousSampleRate: 48000,
            sampleRate: 48000,
          ),
        );
        // Loops: stopped at the head, content and history intact, byte-exact.
        expect(after.tracks[0].state, TrackState.stopped);
        expect(after.tracks[1].state, TrackState.stopped);
        expect(after.tracks[0].lengthFrames, 64);
        expect(after.tracks[0].undoDepth, 1);
        expect(after.tracks[0].positionFrames, 0);
        expect(engine.exportTrack(0), pcm0);
        expect(engine.exportTrack(1), pcm1);
        // The Fade froze where the last callback left it (1 - 12000/48000).
        expect(after.tracks[0].fade.amount, closeTo(.75, 1e-6));
        expect(after.tracks[0].fade.target, 0);
        expect(after.tracks[0].fade.lifetime, identity.lifetime + 1);
        // The remembered rig was replayed onto the reopened engine.
        expect(after.tracks[1].muted, isTrue);
        expect(engine.snapshot().tracks[1].lanes[0].muted, isTrue);
        // One lifetime boundary, no session boundary.
        expect(after.mixGeneration, mixGeneration + 1);
        expect(repository.sessionRevision, sessionRevision);
        // The replayed recipes confirm under that lifetime.
        final settled = await repository.settleFxRecipes(waitForCallback: true);
        expect(settled, EngineResult.ok);
        await Future<void>.delayed(Duration.zero);
        expect(confirmations, [
          (mixGeneration: mixGeneration + 1, sessionRevision: sessionRevision),
        ]);
        // The supervisor stood down: a later tick reopens nothing.
        reconnectTicks.add(null);
        await tick();
        expect(repository.state.mixGeneration, mixGeneration + 1);
      },
    );

    test(
      'an undo pressed while the device was away drops only its track, '
      'and the verdict names it',
      () async {
        final subscription = repository.looperState.listen((_) {});
        addTearDown(subscription.cancel);
        await tick();
        recordLoop(0, .5);
        recordLoop(1, .3);
        final pcm0 = engine.exportTrack(0);
        await tick();

        await loseDevice();
        // The press is accepted (the ring is configured-gated) but no callback
        // ever applies it.
        expect(repository.undo(channel: 1), EngineResult.ok);

        await replugDevice();
        final after = repository.state;
        expect(
          after.status.reopen,
          const EngineReopened(
            outcome: ReopenOutcome.retainedPartial,
            droppedTracks: 1 << 1,
            previousSampleRate: 48000,
            sampleRate: 48000,
          ),
        );
        expect(after.tracks[0].state, TrackState.stopped);
        expect(after.tracks[0].lengthFrames, 64);
        expect(engine.exportTrack(0), pcm0);
        expect(after.tracks[1].state, TrackState.empty);
        expect(after.tracks[1].lengthFrames, 0);
        expect(after.tracks[1].undoDepth, 0);
        expect(after.tracks[1].redoDepth, 0);
      },
    );

    test(
      'a device that comes back at another sample rate clears the loops and '
      'the verdict names both rates',
      () async {
        final subscription = repository.looperState.listen((_) {});
        addTearDown(subscription.cancel);
        await tick();
        recordLoop(0, .5);
        await tick();
        expect(repository.state.status.sampleRate, 48000);

        await loseDevice();
        engine.simulatedSampleRate = 44100;
        await replugDevice();
        final after = repository.state;
        expect(
          after.status.reopen,
          const EngineReopened(
            outcome: ReopenOutcome.clearedRate,
            droppedTracks: 0,
            previousSampleRate: 48000,
            sampleRate: 44100,
          ),
        );
        expect(after.status.sampleRate, 44100);
        expect(after.tracks[0].state, TrackState.empty);
        expect(after.tracks[0].lengthFrames, 0);
        expect(after.status.reopen!.keepsMaterial, isFalse);
        // Recording works again on the new clock.
        recordLoop(0, .4);
        expect(
          engine.exportTrack(0),
          Float32List.fromList(List.filled(64, .4)),
        );
      },
    );

    test('a device still absent from enumeration reopens nothing', () async {
      final subscription = repository.looperState.listen((_) {});
      addTearDown(subscription.cancel);
      await tick();
      recordLoop(0, .5);
      final mixGeneration = repository.state.mixGeneration;
      await loseDevice();
      reconnectTicks.add(null);
      await tick();
      expect(repository.state.mixGeneration, mixGeneration);
      expect(repository.state.status.devicePresent, isFalse);
      expect(repository.state.status.reopen, isNull);
      expect(engine.snapshot().tracks[0].state, TrackState.playing);
    });
  }, skip: skip);
}
