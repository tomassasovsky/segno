@Tags(['fuzz'])
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:segno_engine/segno_engine.dart';

/// The audition voice through the real FFI and the device-free pump (#1178):
/// the file is decoded by the engine's decoder off the test isolate, then
/// started, reported, stopped and retried once on `notReady`.
///
/// Self-skips when `SEGNO_ENGINE_LIB` is unset; build it first:
///   export SEGNO_ENGINE_LIB="$(bash tool/build_test_lib.sh)"
void main() {
  final lib = Platform.environment['SEGNO_ENGINE_LIB'];
  final skip = lib == null || lib.isEmpty
      ? 'SEGNO_ENGINE_LIB not set — run tool/build_test_lib.sh'
      : null;

  late Directory dir;
  late PumpedNativeEngine engine;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('segno_audition');
  });

  tearDown(() {
    engine.dispose();
    dir.deleteSync(recursive: true);
  });

  /// Writes a 16-bit mono WAV of [frames] frames at [rate].
  String wav(String name, int frames, {int rate = 8000}) {
    final data = ByteData(44 + frames * 2)
      ..setUint32(0, 0x46464952, Endian.little) // RIFF
      ..setUint32(4, 36 + frames * 2, Endian.little)
      ..setUint32(8, 0x45564157, Endian.little) // WAVE
      ..setUint32(12, 0x20746d66, Endian.little) // fmt
      ..setUint32(16, 16, Endian.little)
      ..setUint16(20, 1, Endian.little)
      ..setUint16(22, 1, Endian.little)
      ..setUint32(24, rate, Endian.little)
      ..setUint32(28, rate * 2, Endian.little)
      ..setUint16(32, 2, Endian.little)
      ..setUint16(34, 16, Endian.little)
      ..setUint32(36, 0x61746164, Endian.little) // data
      ..setUint32(40, frames * 2, Endian.little);
    for (var i = 0; i < frames; i++) {
      data.setInt16(44 + i * 2, (i % 100) * 100, Endian.little);
    }
    final path = '${dir.path}/$name';
    File(path).writeAsBytesSync(data.buffer.asUint8List());
    return path;
  }

  void start({int sampleRate = 8000}) {
    engine = PumpedNativeEngine()
      ..start(
        EngineConfig(
          sampleRate: sampleRate,
          inputChannels: 1,
          outputChannels: 2,
          maxLoopFrames: sampleRate,
        ),
      )
      ..pump(frames: 0);
  }

  test('decodes off the isolate, plays, reports progress and stops', () async {
    start();
    final started = await engine.auditionStartFile(wav('a.wav', 4000));
    expect(started.result, EngineResult.ok);
    expect(started.frames, 4000);
    expect(started.sourceRate, 8000);
    expect(started.truncated, isFalse);

    engine.pump(frames: 64);
    var state = engine.auditionState();
    expect(state.playing, isTrue);
    expect(state.frames, 4000);
    expect(state.position, 64);
    expect(state.bus, 0);

    expect(engine.auditionStop(), EngineResult.ok);
    engine.pump(frames: 64);
    state = engine.auditionState();
    expect(state.playing, isFalse);
    expect(state.bus, -1);
  }, skip: skip);

  test('the decode runs off the calling isolate', () async {
    start();
    var offloaded = 0;
    engine.offIsolate = <R>(FutureOr<R> Function() computation) {
      offloaded++;
      return Isolate.run(computation);
    };

    final started = await engine.auditionStartFile(wav('a.wav', 4000));

    expect(started.result, EngineResult.ok);
    expect(offloaded, 1);
  }, skip: skip);

  test('a preview ends after its last frame', () async {
    start();
    await engine.auditionStartFile(wav('short.wav', 100));
    engine.pump(frames: 128);
    expect(engine.auditionState().frames, 0);
  }, skip: skip);

  test('another rate is converted to the engine rate', () async {
    start(sampleRate: 16000);
    final started = await engine.auditionStartFile(wav('slow.wav', 4000));
    expect(started.result, EngineResult.ok);
    expect(started.sourceRate, 8000);
    expect(started.frames, 8000);
  }, skip: skip);

  test(
    'a file over two minutes plays its first two minutes and says so',
    () async {
      start();
      final started = await engine.auditionStartFile(
        wav('long.wav', (kAuditionMaxSeconds + 1) * 8000),
      );
      expect(started.result, EngineResult.ok);
      expect(started.truncated, isTrue);
      expect(started.frames, kAuditionMaxSeconds * 8000);
    },
    skip: skip,
  );

  test('an unreadable file is refused', () async {
    start();
    final started = await engine.auditionStartFile('${dir.path}/absent.wav');
    expect(started.result, EngineResult.invalid);
    expect(engine.auditionState().playing, isFalse);
  }, skip: skip);

  test('a busy voice is retried once, a block later', () async {
    start();
    var waits = 0;
    engine.auditionRetryWait = () async {
      waits++;
      engine.pump(frames: 64);
    };
    await engine.auditionStartFile(wav('a.wav', 4000));
    engine.pump(frames: 64);
    // The second replaces the first; the third finds the first not yet
    // handed back.
    await engine.auditionStartFile(wav('b.wav', 4000));
    final third = await engine.auditionStartFile(wav('c.wav', 2000));
    expect(waits, 1);
    expect(third.result, EngineResult.ok);
    engine.pump(frames: 64);
    expect(engine.auditionState().frames, 2000);
  }, skip: skip);

  test('a voice still busy after the retry is refused', () async {
    start();
    engine.auditionRetryWait = () async {};
    await engine.auditionStartFile(wav('a.wav', 4000));
    engine.pump(frames: 64);
    await engine.auditionStartFile(wav('b.wav', 4000));
    final third = await engine.auditionStartFile(wav('c.wav', 2000));
    expect(third.result, EngineResult.notReady);
    engine.pump(frames: 64);
    expect(engine.auditionState().frames, 4000);
  }, skip: skip);
}
