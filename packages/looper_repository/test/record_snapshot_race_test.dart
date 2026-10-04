@Tags(['fuzz'])
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
// The REAL native engine (device-free pump) is what makes the command-ring
// drain timing observable; only it and the effect models come from the engine
// package — every other name is the domain type from the looper_repository
// barrel.
import 'package:segno_engine/segno_engine.dart'
    show EngineSnapshot, FxFingerprint, PumpedNativeEngine, RecordImage;

class _CaptureImageEngine extends PumpedNativeEngine {
  RecordImage? lastImage;
  final imageChannels = <int>[];
  bool interleaveNextImage = false;
  void Function()? afterSnapshot;

  @override
  EngineSnapshot snapshot() {
    final result = super.snapshot();
    final callback = afterSnapshot;
    afterSnapshot = null;
    callback?.call();
    return result;
  }

  @override
  EngineResult recordWithImage(RecordImage image, {int channel = 0}) {
    lastImage = image;
    imageChannels.add(channel);
    final result = super.recordWithImage(image, channel: channel);
    if (interleaveNextImage && result.isOk) {
      interleaveNextImage = false;
      // Drain the actual join after the snapshot was captured, before the
      // repository can make a terminal cancellation decision from it.
      afterSnapshot = () => pump(frames: 0);
    }
    return result;
  }
}

/// The record-time snapshot race, pinned against the REAL native engine.
///
/// The bug: recording an input that has monitor FX yielded a DRY take because
/// the engine self-snapshotted from its own ring-deferred monitor state — if
/// record fired before the audio thread drained the FX write, it copied
/// nothing. The fix makes the repository the single record-time snapshot
/// authority: it computes the snapshot from its synchronous cache and pushes it
/// to the engine like any other lane edit, so the take's chain lands regardless
/// of drain timing. This test sets a monitor chain and records WITHOUT a drain
/// in between (the widest race window) and asserts the take's lane chain equals
/// the monitored one after a single drain.
///
/// Self-skips when `SEGNO_ENGINE_LIB` is unset; build it first:
///   export SEGNO_ENGINE_LIB="$(bash packages/segno_engine/tool/build_test_lib.sh)"
void main() {
  final lib = Platform.environment['SEGNO_ENGINE_LIB'];
  final skip = lib == null || lib.isEmpty
      ? 'SEGNO_ENGINE_LIB not set — run tool/build_test_lib.sh'
      : null;

  late _CaptureImageEngine engine;
  late LooperRepository repo;
  late StreamController<void> ticker;
  late StreamSubscription<LooperState> subscription;

  setUp(() async {
    engine = _CaptureImageEngine();
    ticker = StreamController<void>.broadcast();
    repo = LooperRepository(engine: engine, ticker: ticker.stream)
      ..startEngine(
        const EngineConfig(
          sampleRate: 48000,
          inputChannels: 1,
          outputChannels: 1,
          maxLoopFrames: 48000,
        ),
      );
    subscription = repo.looperState.listen((_) {});
    // Startup mix must be confirmed before a take can be admitted. Keep this
    // outside the monitor-edit -> Record race window exercised below.
    expect(repo.record(), EngineResult.notReady);
    engine.pump(frames: 0);
    expect(await repo.settleMixSettings(), EngineResult.ok);
  });

  tearDown(() async {
    await subscription.cancel();
    await repo.dispose();
    await ticker.close();
  });

  group('record-time snapshot race (real engine)', () {
    for (final interleaved in [false, true]) {
      test('shared Count-in joins prepare their own images and cancellation '
          'retains the surviving image until its original deadline '
          '(interleaved=$interleaved)', () async {
        expect(engine.setTempo(120), EngineResult.ok);
        engine.pump(frames: 0);
        expect(
          repo.setRecordStartSettings(
            countInBars: 1,
            soundStart: false,
            editKind: RecordStartEditKind.countIn,
          ),
          EngineResult.ok,
        );
        engine.pump(frames: 0);
        expect(await repo.settleRecordStartSettings(), EngineResult.ok);
        expect(
          repo.setMonitorEffects(
            input: 0,
            effects: [BuiltInEffect(type: TrackEffectType.drive)],
          ),
          EngineResult.ok,
        );
        engine.pump(frames: 0);
        expect(repo.record(channel: 6), EngineResult.ok);
        engine
          ..pump(frames: 36000)
          ..interleaveNextImage = interleaved;
        expect(repo.record(channel: 1), EngineResult.ok);
        engine.pump(frames: 0);
        expect(engine.imageChannels, [6, 1]);
        expect(
          engine.snapshot().tracks[6].pendingLaunch,
          PendingLaunchAction.record,
        );
        expect(
          engine.snapshot().tracks[1].pendingLaunch,
          PendingLaunchAction.record,
        );
        expect(repo.record(channel: 6), EngineResult.ok);
        engine.pump(frames: 0);
        ticker.add(null);
        await Future<void>.delayed(Duration.zero);
        expect(engine.imageChannels, [6, 1]); // cancel prepares nothing
        engine.pump(frames: 59999);
        expect(engine.snapshot().tracks[1].state, TrackState.empty);
        engine.pump(frames: 1);
        ticker.add(null);
        await Future<void>.delayed(Duration.zero);
        expect(engine.snapshot().tracks[1].state, TrackState.recording);
        expect(engine.snapshot().tracks[6].state, TrackState.empty);
        expect(
          engine.snapshot().tracks[1].imageRevision,
          engine.lastImage!.revision,
        );
        expect(repo.laneEffects(1, 0), isNotEmpty);
        expect(
          repo.laneEffects(1, 0).single,
          isA<BuiltInEffect>().having(
            (effect) => effect.type,
            'type',
            TrackEffectType.drive,
          ),
        );
        expect(repo.laneEffects(6, 0), isEmpty);
        expect(
          repo.laneChainFingerprint(1, 0),
          engine.laneFxFingerprint(channel: 1, lane: 0),
        );
      });
    }

    test(
      'a live Pre effect submits zero monitor split and a Pre take recipe',
      () async {
        expect(
          repo.setMonitorEffects(
            input: 0,
            effects: [
              BuiltInEffect(
                type: TrackEffectType.drive,
                placement: FxPlacement.pre,
                rack: const FxRack(id: 'input-rack', name: 'Captured rack'),
                module: 'Overdrive',
              ),
            ],
          ),
          EngineResult.ok,
        );
        expect(repo.monitorEffects(0).single.placement, FxPlacement.pre);
        expect(repo.record(), EngineResult.ok);
        expect(engine.lastImage!.laneFx[0]!.preCount, 1);
        engine.pump(frames: 128);
        expect(engine.snapshot().tracks[0].imageRevision, 1);
        ticker.add(null);
        await Future<void>.delayed(Duration.zero);
        final source = repo.monitorEffects(0).single;
        final captured = repo.laneEffects(0, 0).single;
        expect(captured.placement, FxPlacement.pre);
        expect(captured.rack, source.rack);
        expect(captured.module, source.module);
        expect(captured.slotId, isNot(source.slotId));
        expect(
          decodeTrackEffects(encodeTrackEffects([captured])).single,
          captured,
        );
        expect(
          repo.laneChainFingerprint(0, 0),
          engine.laneFxFingerprint(channel: 0, lane: 0),
        );
      },
    );

    test('monitor FX set then record-from-EMPTY with NO drain between still '
        'lands on the take lane, cache == engine', () async {
      // Push a monitor chain on input 0 but DO NOT pump — the FX write is still
      // in flight on the command ring (the monitor count is unpublished). Then
      // record from EMPTY in the SAME turn (no drain) — the ordering the old
      // engine self-snapshot lost the race on. The repo computes the snapshot
      // from its synchronous cache and pushes it; nothing reads ring-deferred
      // engine state.
      expect(
        repo.setMonitorEffects(
          input: 0,
          effects: [
            BuiltInEffect(
              type: TrackEffectType.delay,
              params: const [0.3, 0.4, 0.5, 0],
            ),
            BuiltInEffect(type: TrackEffectType.reverb),
          ],
        ),
        EngineResult.ok,
      );
      expect(repo.record(), EngineResult.ok);

      // One callback accepts the monitor recipe and the armed take image.
      engine.pump(frames: 128);
      expect(engine.snapshot().tracks[0].imageRevision, 1);

      // The take's lane chain equals what was monitored — not dry.
      expect(
        engine.laneFxFingerprint(channel: 0, lane: 0),
        engine.monitorFxFingerprint(input: 0),
      );
      ticker.add(null);
      await Future<void>.delayed(Duration.zero);
      // ...and the repo cache agrees with the engine — the single enforced
      // contract (the pure-sink guarantee).
      expect(
        repo.laneChainFingerprint(0, 0),
        engine.laneFxFingerprint(channel: 0, lane: 0),
      );
      expect(repo.laneEffects(0, 0), hasLength(2));
    });

    test('a dry input leaves a staged lane chain untouched after record '
        '(non-clobber, cache == engine)', () {
      // Stage a lane chain and drain it in; input 0's monitor stays clean.
      repo.setLaneEffects(
        channel: 0,
        lane: 0,
        effects: [BuiltInEffect(type: TrackEffectType.filter)],
      );
      engine.pump(frames: 0);
      final staged = engine.laneFxFingerprint(channel: 0, lane: 0);
      expect(staged, isNot(FxFingerprint.offset)); // the stage actually landed

      // Record over a dry monitor: the snapshot copies nothing, so the staged
      // lane chain must survive (never a count=0 clobber).
      expect(repo.record(), EngineResult.ok);
      engine.pump(frames: 0);

      expect(engine.laneFxFingerprint(channel: 0, lane: 0), staged);
      expect(repo.laneChainFingerprint(0, 0), staged);
      expect(repo.laneEffects(0, 0), hasLength(1));
    });
  }, skip: skip);
}
