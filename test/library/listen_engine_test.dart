import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:operation_guards/operation_guards.dart';
import 'package:segno/app/fx_chain_persistence.dart';
import 'package:segno/looper/model/audio_tempo.dart';
import 'package:segno/looper/model/one_shot.dart';
import 'package:segno/looper/model/overdub_decay.dart';
import 'package:segno/looper/model/record_length.dart';
import 'package:segno/looper/model/record_start.dart';
import 'package:segno/looper/model/record_timing.dart';
import 'package:segno/session/session_mapping.dart';
import 'package:segno_engine/segno_engine.dart' show PumpedNativeEngine;
import 'package:session_repository/session_repository.dart';
import 'package:settings_repository/settings_repository.dart';

/// Listen and the lane peaks against the REAL native engine (plan D10, D11):
/// a saved session's `mixdown.wav` decodes through the engine's decoder and
/// plays on the audition voice, and its live layer reads back as peaks.
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
  late SessionRepository sessions;
  late Directory root;
  late StreamController<void> ticker;
  late StreamSubscription<LooperState> subscription;
  Timer? pumpDriver;

  const loopFrames = 256;

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
          outputChannels: 2,
          maxLoopFrames: 48000,
        ),
      );
    subscription = looper.looperState.listen((_) {});
    await pollingStarted.future;
    engine.pump(frames: 0);
    expect(await looper.settleMixSettings(), EngineResult.ok);
    root = Directory.systemTemp.createTempSync('segno_listen');
    sessions = SessionRepository(
      engine: engine,
      guards: GuardRegistry(),
      sessionsRoot: () async => root.path,
    );
    pumpDriver = Timer.periodic(
      const Duration(milliseconds: 1),
      (_) => engine.pump(frames: 0),
    );
  });

  tearDown(() async {
    pumpDriver?.cancel();
    await subscription.cancel();
    await looper.dispose();
    await ticker.close();
    root.deleteSync(recursive: true);
  });

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
    followTempo: InheritSnapshot(
      defaultValue: looper.defaultFollowTempo,
      trackOverrides: looper.trackFollowTempoOverrides,
    ),
    pitchMode: InheritSnapshot(
      defaultValue: looper.defaultPitchMode,
      trackOverrides: looper.trackPitchModeOverrides,
    ),
  );

  test(
    "a saved session's preview plays on the audition voice and its lane "
    'reads back as peaks',
    () async {
      expect(looper.record(), EngineResult.ok);
      engine.pump(frames: loopFrames, input: 0.5);
      ticker.add(null);
      expect(looper.record(), EngineResult.ok);
      engine.pump(frames: 0);
      ticker.add(null);
      await sessions.save(
        '${root.path}/s-a',
        chains: chainsFromLooper(
          looper,
          projection: FxChainPersistence(looper: looper),
        ),
        settings: settings(),
      );

      final started = await sessions.startAudition('s-a');
      expect(started.result, EngineResult.ok);
      expect(started.frames, loopFrames);
      expect(started.sourceRate, 48000);
      expect(started.rate, 48000);
      expect(started.truncated, isFalse);
      engine
        ..pump(frames: 0)
        ..pump(frames: 64);
      final now = sessions.auditionState();
      expect(now.playing, isTrue);
      expect(now.position, 64);

      expect(sessions.stopAudition(), EngineResult.ok);
      engine.pump(frames: 64);
      expect(sessions.auditionState().playing, isFalse);

      final preview = await sessions.readPreview('s-a');
      final peaks = await sessions.readPeaks(
        's-a',
        preview.tracks.single,
        buckets: 16,
      );
      expect(peaks, hasLength(16));
      expect(peaks!.reduce((a, b) => a > b ? a : b), greaterThan(0.4));
    },
    skip: skip,
  );
}
