import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:operation_guards/operation_guards.dart';
import 'package:segno/app/fx_chain_persistence.dart';
import 'package:segno/looper/model/one_shot.dart';
import 'package:segno/looper/model/overdub_decay.dart';
import 'package:segno/looper/model/record_length.dart';
import 'package:segno/looper/model/record_start.dart';
import 'package:segno/looper/model/record_timing.dart';
import 'package:segno/session/session_mapping.dart';
import 'package:segno_engine/segno_engine.dart' show PumpedNativeEngine;
import 'package:session_repository/session_repository.dart';
import 'package:settings_repository/settings_repository.dart';

/// New loop against the REAL native engine (plan D9, Part 5): the empty rig
/// `SessionCubit.newLoop` applies, built by the same mapping
/// ([SessionRepository.liveSession], [rigForNewLoop]) and applied through
/// the same `applySession`, clears every track with its history and resets
/// the transforms, keeps the tempo and mode, and leaves the outgoing session
/// reloadable byte for byte.
///
/// Self-skips when `SEGNO_ENGINE_LIB` is unset:
///   export SEGNO_ENGINE_LIB="$(bash packages/segno_engine/tool/build_test_lib.sh)"
void main() {
  final lib = Platform.environment['SEGNO_ENGINE_LIB'];
  final skip = lib == null || lib.isEmpty
      ? 'SEGNO_ENGINE_LIB not set — run packages/segno_engine/tool/build_test_lib.sh'
      : null;

  late PumpedNativeEngine engine;
  late LooperRepository looper;
  late SessionRepository session;
  late Directory tempDir;
  late StreamController<void> ticker;
  late StreamSubscription<LooperState> subscription;
  Timer? pumpDriver;

  const loopFrames = 256;
  const poll = Duration(milliseconds: 1);

  setUp(() async {
    engine = PumpedNativeEngine();
    final pollingStarted = Completer<void>();
    ticker = StreamController<void>.broadcast(
      sync: true,
      onListen: pollingStarted.complete,
    );
    looper = LooperRepository(engine: engine, ticker: ticker.stream)
      ..startEngine(
        const EngineConfig(
          sampleRate: 48000,
          inputChannels: 1,
          outputChannels: 1,
          maxLoopFrames: 48000,
        ),
      );
    subscription = looper.looperState.listen((_) {});
    await pollingStarted.future;
    engine.pump(frames: 0);
    expect(await looper.settleMixSettings(), EngineResult.ok);
    session = SessionRepository(engine: engine, guards: GuardRegistry());
    tempDir = Directory.systemTemp.createTempSync('segno_new_loop');
    pumpDriver = Timer.periodic(poll, (_) => engine.pump(frames: 0));
  });

  tearDown(() async {
    pumpDriver?.cancel();
    await subscription.cancel();
    await looper.dispose();
    await ticker.close();
    tempDir.deleteSync(recursive: true);
  });

  void take(int channel, double input) {
    expect(looper.record(channel: channel), EngineResult.ok);
    engine.pump(frames: loopFrames, input: input);
    expect(looper.record(channel: channel), EngineResult.ok);
    engine.pump(frames: 0);
    ticker.add(null);
  }

  List<Float32List> layers(int channel) {
    final t = engine.snapshot().tracks[channel];
    final total = t.undoDepth + 1 + t.redoDepth;
    return [for (var o = 0; o < total; o++) engine.exportLayer(channel, 0, o)];
  }

  SessionSettings settings() => settingsFromLooper(
    looper,
    fade: FadeDurations.defaults,
    recordStart: RecordStartSettings(countInBars: 0, soundStart: false),
    clickMode: looper.sessionTransport.clickMode,
    recordTiming: RecordTimingSnapshot(
      defaultTiming: looper.defaultRecordTiming,
      rememberedDivision: looper.sessionTransport.quantizeDiv,
      trackOverrides: looper.trackRecordTimingOverrides,
      captureLocked: false,
    ),
    recordLength: RecordLengthSnapshot(
      defaultBars: looper.sessionTransport.defaultLengthPresetBars,
      trackOverrides: looper.trackLengthPresetOverrides,
      mode: looper.sessionTransport.looperMode,
      captureLocked: false,
    ),
    clickVolume: 1,
    decay: DecaySnapshot(
      defaultPercent: looper.defaultOverdubDecay,
      trackOverrides: looper.trackOverdubDecayOverrides,
    ),
    oneShot: OneShotSnapshot(
      defaultOneShot: looper.defaultOneShot,
      trackOverrides: looper.trackOneShotOverrides,
    ),
  );

  SessionChains chains() =>
      chainsFromLooper(looper, projection: FxChainPersistence(looper: looper));

  test(
    'New loop empties every track, resets the transforms, keeps tempo and '
    'mode, and the outgoing session reloads byte for byte',
    () async {
      // A tempo of its own, so keeping it is not keeping the default.
      expect(looper.setTempo(96), EngineResult.ok);
      engine.pump(frames: 0);
      take(0, 0.5);
      take(1, 0.25);
      // An overdub, so track 0 carries history New loop must drop.
      expect(looper.record(), EngineResult.ok);
      engine.pump(frames: loopFrames, input: 0.1);
      expect(looper.record(), EngineResult.ok);
      for (var k = 0; k < 128; k++) {
        if (!engine.snapshot().tracks.first.layerInFlight) break;
        engine.pump(frames: loopFrames);
      }
      ticker.add(null);
      expect(
        looper.setLaneMute(muted: true, channel: 1, lane: 0),
        EngineResult.ok,
      );
      expect(await looper.toggleReverse(channel: 0), EngineResult.ok);
      expect(
        await looper.toggleFade(channel: 1, seconds: 10),
        EngineResult.ok,
      );
      engine.pump(frames: 4800);

      final outgoing = engine.snapshot();
      expect(outgoing.tracks[0].reversed, isTrue);
      expect(outgoing.tracks[0].undoDepth, greaterThan(0));
      expect(outgoing.tracks[1].lanes.first.muted, isTrue);
      expect(outgoing.tracks[1].fade.amount, lessThan(1));
      expect(outgoing.masterLengthFrames, greaterThan(0));
      final before = [layers(0), layers(1)];

      // The outgoing session, as New loop's preservation saves it.
      final saved = '${tempDir.path}/outgoing';
      await session.save(saved, chains: chains(), settings: settings());

      // New loop.
      final live = session.liveSession(
        settings: settings(),
        chains: chains(),
      );
      await looper.applySession(rigForNewLoop(live), clearPollInterval: poll);
      engine.pump(frames: 0);

      final fresh = engine.snapshot();
      for (final track in fresh.tracks) {
        expect(track.state, TrackState.empty);
        expect(track.undoDepth, 0);
        expect(track.redoDepth, 0);
        expect(track.reversed, isFalse);
        expect(track.fade.amount, 1);
        for (final lane in track.lanes) {
          expect(lane.muted, isFalse);
        }
      }
      expect(fresh.masterLengthFrames, 0);
      expect(outgoing.tempoBpm, 96);
      expect(fresh.tempoBpm, outgoing.tempoBpm);
      expect(fresh.tempoSource, outgoing.tempoSource);
      expect(fresh.looperMode, outgoing.looperMode);

      // The outgoing session is still whole.
      final bundle = await session.read(saved);
      await looper.applySession(rigFromBundle(bundle), clearPollInterval: poll);
      engine.pump(frames: 0);
      final reloaded = engine.snapshot();
      expect(reloaded.tracks[1].lanes.first.muted, isTrue);
      final after = [layers(0), layers(1)];
      for (var c = 0; c < 2; c++) {
        expect(after[c], hasLength(before[c].length), reason: 'track $c');
        for (var o = 0; o < before[c].length; o++) {
          expect(after[c][o], before[c][o], reason: 'track $c layer $o');
        }
      }
    },
    skip: skip,
  );
}
