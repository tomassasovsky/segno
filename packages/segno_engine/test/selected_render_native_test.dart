@Tags(['fuzz'])
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:segno_engine/segno_engine.dart';

/// The shared render recipe (#1202) through the real engine: two literal
/// loops (`A[i] = i + 1` over 16 frames, `B[i] = 100 (i + 1)` over 24)
/// render their 48-frame common cycle as `A[f % 16] + B[f % 24]` on both
/// sides.
///
/// Self-skips when `SEGNO_ENGINE_LIB` is unset; build it first:
///   export SEGNO_ENGINE_LIB="$(bash tool/build_test_lib.sh)"
void main() {
  final lib = Platform.environment['SEGNO_ENGINE_LIB'];
  final skip = lib == null || lib.isEmpty
      ? 'SEGNO_ENGINE_LIB not set — run tool/build_test_lib.sh'
      : null;

  PumpedNativeEngine fixture() {
    final engine = PumpedNativeEngine();
    addTearDown(engine.dispose);
    expect(
      engine.start(
        const EngineConfig(inputChannels: 1, outputChannels: 2),
      ),
      EngineResult.ok,
    );
    engine.pump(frames: 0);
    expect(
      engine.importTrack(
        0,
        Float32List.fromList([for (var i = 0; i < 16; i++) i + 1.0]),
      ),
      EngineResult.ok,
    );
    expect(
      engine.importTrack(
        1,
        Float32List.fromList([for (var i = 0; i < 24; i++) 100.0 * (i + 1)]),
      ),
      EngineResult.ok,
    );
    expect(engine.commitSession(8, loopBars: 0), EngineResult.ok);
    engine.pump(frames: 0);
    return engine;
  }

  double expected(int f) => (f % 16 + 1) + 100.0 * (f % 24 + 1);

  Future<RenderJobStatus> finish(PumpedNativeEngine engine, int job) async {
    engine.pump(frames: 0); // the callback freezes the sources here
    for (var i = 0; i < 5000; i++) {
      final status = engine.pollRender(job)!;
      if (status.state.isTerminal) return status;
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    fail('render did not finish');
  }

  test('names a Once track longer than the chosen length', () {
    final engine = PumpedNativeEngine();
    addTearDown(engine.dispose);
    expect(
      engine.start(const EngineConfig(inputChannels: 1, outputChannels: 2)),
      EngineResult.ok,
    );
    engine.pump(frames: 0);
    // 60,000 frames against one bar of 38,400 at 300 BPM and 48 kHz.
    expect(engine.importTrack(0, Float32List(60000)), EngineResult.ok);
    expect(engine.commitSession(60000, loopBars: 0), EngineResult.ok);
    expect(engine.setTempo(300), EngineResult.ok);
    engine.pump(frames: 0);
    const request = RenderRequest(sources: {0}, lengthBars: 1);
    expect(engine.measureRender(request).plan!.onceCutTracks, isEmpty);
    expect(
      engine.setOneShotMask(channels: 1, oneShot: true),
      EngineResult.ok,
    );
    engine.pump(frames: 0);
    final measured = engine.measureRender(request);
    expect(measured.result, EngineResult.ok);
    expect(measured.plan!.frames, 38400);
    expect(measured.plan!.onceCutTracks, {0});
  }, skip: skip);

  test('measures and renders the common cycle into memory', () async {
    final engine = fixture();
    const request = RenderRequest(sources: {0, 1}, tails: RenderTails.cut);
    final measured = engine.measureRender(request);
    expect(measured.result, EngineResult.ok);
    expect(measured.plan!.frames, 48);
    expect(measured.plan!.method, RenderMethod.commonCycle);
    expect(measured.plan!.tempoSet, isFalse);
    final begun = engine.beginRender(request);
    expect(begun.result, EngineResult.ok);
    expect(engine.beginRender(request).result, EngineResult.alreadyRunning);
    final status = await finish(engine, begun.job);
    expect(status.state, RenderJobState.done);
    expect(status.permille, 1000);
    final samples = engine.copyRender(begun.job, maxFrames: 64)!;
    expect(samples.length, 96);
    for (var f = 0; f < 48; f++) {
      expect(samples[2 * f], expected(f));
      expect(samples[2 * f + 1], expected(f));
    }
    expect(engine.cancelRender(begun.job), EngineResult.ok);
    expect(engine.pollRender(begun.job), isNull);
  }, skip: skip);

  test('writes a stereo float WAV for a file render', () async {
    final engine = fixture();
    final dir = Directory.systemTemp.createTempSync('render_native');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/mix.wav';
    final begun = engine.beginRender(
      RenderRequest(
        sources: const {0, 1},
        target: RenderTarget.file,
        path: path,
      ),
    );
    expect(begun.result, EngineResult.ok);
    expect((await finish(engine, begun.job)).state, RenderJobState.done);
    final bytes = File(path).readAsBytesSync();
    expect(bytes.length, 44 + 48 * 8);
    final data = ByteData.sublistView(bytes);
    expect(data.getUint16(20, Endian.little), 3); // IEEE float
    expect(data.getUint16(22, Endian.little), 2); // stereo
    for (var f = 0; f < 48; f++) {
      expect(data.getFloat32(44 + 8 * f, Endian.little), expected(f));
    }
    expect(File('$path.part').existsSync(), isFalse);
  }, skip: skip);

  test('maps the recipe refusals and failures', () async {
    final engine = fixture();
    expect(
      engine.measureRender(const RenderRequest(sources: {})).result,
      EngineResult.invalid,
    );
    expect(
      engine
          .measureRender(const RenderRequest(sources: {0, 1}, maxFrames: 47))
          .result,
      EngineResult.capacity,
    );
    expect(
      engine
          .measureRender(const RenderRequest(sources: {0}, lengthBars: 2))
          .result,
      EngineResult.invalid, // no bars without a tempo
    );
    final begun = engine.beginRender(const RenderRequest(sources: {0, 1}));
    // The freeze and the Clear apply in the same callback, freeze first, so
    // the material changes after it is frozen and before it is staged.
    engine
      ..clear()
      ..pump(frames: 0);
    RenderJobStatus? status;
    for (var i = 0; i < 2000; i++) {
      status = engine.pollRender(begun.job);
      if (status!.state.isTerminal) break;
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(status!.state, RenderJobState.failed);
    expect(status.failure, EngineResult.tracksChanged);
  }, skip: skip);
}
