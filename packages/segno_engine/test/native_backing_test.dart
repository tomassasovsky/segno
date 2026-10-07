@Tags(['fuzz'])
library;

import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:segno_engine/segno_engine.dart';
import 'package:segno_engine/src/native_audio_decoder.dart'
    show NativeDecodedAudioPayload;

/// The backing seam through the real native library (#1200 Part 3): the
/// decoder in a background isolate, and the voice through the device-free
/// pump. Self-skips when `SEGNO_ENGINE_LIB` is unset; build it first:
///   export SEGNO_ENGINE_LIB="$(bash tool/build_test_lib.sh)"
void main() {
  final lib = Platform.environment['SEGNO_ENGINE_LIB'];
  final skip = lib == null || lib.isEmpty
      ? 'SEGNO_ENGINE_LIB not set — run tool/build_test_lib.sh'
      : null;

  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('native_backing'));
  tearDown(() => dir.deleteSync(recursive: true));

  /// L = (k + 1) / 4096, R = -L, exact in float32.
  double left(int k) => (k + 1) / 4096;

  /// Writes a 32-bit float stereo WAV of [frames] frames of the ramp.
  String writeWav(String name, int frames, {int rate = 48000}) {
    final data = ByteData(44 + frames * 8);
    void ascii(int at, String s) {
      for (var i = 0; i < s.length; i++) {
        data.setUint8(at + i, s.codeUnitAt(i));
      }
    }

    ascii(0, 'RIFF');
    data.setUint32(4, 36 + frames * 8, Endian.little);
    ascii(8, 'WAVEfmt ');
    data
      ..setUint32(16, 16, Endian.little)
      ..setUint16(20, 3, Endian.little)
      ..setUint16(22, 2, Endian.little)
      ..setUint32(24, rate, Endian.little)
      ..setUint32(28, rate * 8, Endian.little)
      ..setUint16(32, 8, Endian.little)
      ..setUint16(34, 32, Endian.little);
    ascii(36, 'data');
    data.setUint32(40, frames * 8, Endian.little);
    for (var k = 0; k < frames; k++) {
      data
        ..setFloat32(44 + 8 * k, left(k), Endian.little)
        ..setFloat32(48 + 8 * k, -left(k), Endian.little);
    }
    final path = '${dir.path}/$name';
    File(path).writeAsBytesSync(data.buffer.asUint8List());
    return path;
  }

  group('NativeAudioDecoder', () {
    test(
      'decodes off the calling isolate, exactly at the engine rate',
      () async {
        // Every decode goes through the runner (Isolate.run by default), so
        // the calling isolate never runs the native decode itself.
        var runs = 0;
        final decoder = NativeAudioDecoder(
          runner: <R>(R Function() work) {
            runs++;
            return Isolate.run(work);
          },
        );
        final audio = await decoder.decode(
          writeWav('a.wav', 1000),
          sampleRate: 48000,
        );
        expect(runs, 1);
        expect(audio.frames, 1000);
        expect(
          audio.info,
          const AudioFileInfo(
            sourceRate: 48000,
            sourceChannels: 2,
            sourceFrames: 1000,
          ),
        );
        final pcm = audio.copySamples();
        for (var k = 0; k < 1000; k++) {
          expect(pcm[2 * k], left(k));
          expect(pcm[2 * k + 1], -left(k));
        }
        expect(audio.peaks(1).single, left(999));
        audio.dispose();
        expect(audio.ownership, DecodedAudioOwnership.disposed);
      },
      skip: skip,
    );

    test(
      'a bounded read keeps what it asked for and says it stopped',
      () async {
        final audio = await NativeAudioDecoder().decode(
          writeWav('b.wav', 1000),
          sampleRate: 48000,
          startFrame: 100,
          maxFrames: 50,
        );
        expect(audio.frames, 50);
        expect(audio.info.truncated, isTrue);
        expect(audio.copySamples()[0], left(100));
        audio.dispose();
      },
      skip: skip,
    );

    test('converts another rate by the native length rule', () async {
      final audio = await NativeAudioDecoder().decode(
        writeWav('c.wav', 44100, rate: 44100),
        sampleRate: 48000,
      );
      expect(audio.frames, 48000);
      expect(audio.info.sourceRate, 44100);
      audio.dispose();
    }, skip: skip);

    test('probes without keeping samples', () async {
      final probe = await NativeAudioDecoder().probe(
        writeWav('d.wav', 1000),
        buckets: 2,
      );
      expect(probe.info.sourceFrames, 1000);
      expect(probe.peaks, [left(499), left(999)]);
    }, skip: skip);

    test('refusals throw their reason', () async {
      // Not a format the decoder accepts: refused before any decoder runs.
      File('${dir.path}/text.wav').writeAsStringSync('not audio');
      await expectLater(
        NativeAudioDecoder().decode('${dir.path}/text.wav', sampleRate: 48000),
        throwsA(
          isA<EngineException>().having(
            (e) => e.result,
            'result',
            EngineResult.unsupported,
          ),
        ),
      );
      // A WAV header with no chunks: damaged.
      File(
        '${dir.path}/empty.wav',
      ).writeAsStringSync('RIFF\x00\x00\x00\x00WAVE');
      await expectLater(
        NativeAudioDecoder().probe('${dir.path}/empty.wav'),
        throwsA(
          isA<EngineException>().having(
            (e) => e.result,
            'result',
            EngineResult.invalid,
          ),
        ),
      );
      await expectLater(
        NativeAudioDecoder().probe('${dir.path}/absent.wav'),
        throwsA(isA<EngineException>()),
      );
    }, skip: skip);
  });

  group('PumpedNativeEngine backing', () {
    late PumpedNativeEngine engine;
    setUp(() {
      engine = PumpedNativeEngine()
        ..start(const EngineConfig(outputChannels: 2, maxLoopFrames: 48000));
    });
    tearDown(() => engine.dispose());

    test('plays the decoded samples on its routed outputs', () async {
      final audio = await NativeAudioDecoder().decode(
        writeWav('p.wav', 300),
        sampleRate: 48000,
      );
      expect(engine.setBackingOutput(3), EngineResult.ok);
      expect(engine.backingLoad(audio, item: 5, play: true), EngineResult.ok);
      expect(audio.ownership, DecodedAudioOwnership.transferred);
      final out = Float32List(256 * 2);
      engine.pump(frames: 256, output: out);
      for (var k = 0; k < 256; k++) {
        expect(out[2 * k], left(k));
        expect(out[2 * k + 1], -left(k));
      }
      var s = engine.backingState();
      expect(s.item, 5);
      expect(s.transport, BackingTransport.playing);
      expect(s.position, 256);
      expect(s.frames, 300);
      expect(s.owned, 1);
      expect(s.ownedBytes, 300 * 8);
      engine.pump(frames: 100);
      s = engine.backingState();
      expect(s.transport, BackingTransport.stopped);
      expect(s.lastEnd, BackingEndEvent.stopped);
      expect(s.endCount, 1);
    }, skip: skip);

    test('End = Next continues into the staged file', () async {
      final decoder = NativeAudioDecoder();
      final a = await decoder.decode(writeWav('a.wav', 100), sampleRate: 48000);
      final b = await decoder.decode(writeWav('b.wav', 100), sampleRate: 48000);
      engine
        ..setBackingOutput(3)
        ..setBackingEnd(BackingEnd.next);
      expect(engine.backingLoad(a, item: 1, play: true), EngineResult.ok);
      expect(engine.backingStageNext(b, item: 2), EngineResult.ok);
      engine.pump(frames: 150);
      final s = engine.backingState();
      expect(s.item, 2);
      expect(s.nextItem, -1);
      expect(s.position, 50);
      expect(s.lastEnd, BackingEndEvent.advanced);
      expect(s.owned, 1); // the finished file came back and was freed
    }, skip: skip);

    test('the finalizer guards a decode until the engine takes it or it is '
        'disposed (review of P3, L2)', () async {
      final decoder = NativeAudioDecoder();
      final kept = await decoder.decode(
        writeWav('f1.wav', 100),
        sampleRate: 48000,
      );
      final dropped = await decoder.decode(
        writeWav('f2.wav', 100),
        sampleRate: 48000,
      );
      bool guarded(DecodedAudio audio) =>
          (audio.payload as NativeDecodedAudioPayload).finalizerAttached;
      expect(guarded(kept), isTrue);
      expect(guarded(dropped), isTrue);
      expect(engine.backingLoad(kept, item: 1, play: false), EngineResult.ok);
      expect(guarded(kept), isFalse);
      dropped.dispose();
      expect(guarded(dropped), isFalse);
    }, skip: skip);

    test('a bounded read past the last output frame is empty and the voice '
        'refuses it', () async {
      final empty = await NativeAudioDecoder().decode(
        writeWav('t.wav', 100, rate: 96000),
        sampleRate: 48000,
        startFrame: 99,
        maxFrames: 10,
      );
      expect(empty.frames, 0);
      expect(
        engine.backingLoad(empty, item: 1, play: false),
        EngineResult.invalid,
      );
      empty.dispose();
    }, skip: skip);

    test("refusals leave the audio the caller's", () async {
      final at44 = await NativeAudioDecoder().decode(
        writeWav('r.wav', 100),
        sampleRate: 44100,
      );
      expect(
        engine.backingLoad(at44, item: 1, play: true),
        EngineResult.invalid,
      );
      expect(at44.isOwned, isTrue);
      at44.dispose();
      final mock = await MockAudioDecoder(
        files: {'m': const MockAudioFile(sourceRate: 48000, sourceFrames: 10)},
      ).decode('m', sampleRate: 48000);
      expect(
        engine.backingLoad(mock, item: 1, play: true),
        EngineResult.invalid,
      );
      mock.dispose();
    }, skip: skip);

    test('settings and the transport round-trip through the state', () async {
      engine
        ..setBackingEnd(BackingEnd.repeat)
        ..setBackingLevel(0.5)
        ..setBackingPan(-0.25)
        ..setClickPan(1);
      final audio = await NativeAudioDecoder().decode(
        writeWav('s.wav', 1000),
        sampleRate: 48000,
      );
      engine
        ..backingLoad(audio, item: 1, play: false)
        ..pump(frames: 0)
        ..backingSeek(600)
        ..backingTransport(BackingTransportOp.play)
        ..pump(frames: 64)
        ..backingTransport(BackingTransportOp.pause)
        ..pump();
      final s = engine.backingState();
      expect(s.endMode, BackingEnd.repeat);
      expect(s.level, 0.5);
      expect(s.pan, -0.25);
      expect(s.clickPan, 1);
      expect(s.transport, BackingTransport.paused);
      expect(s.position, 664);
      expect(engine.backingClear(), EngineResult.ok);
      engine.pump();
      expect(engine.backingState().loaded, isFalse);
      expect(engine.backingState().owned, 0);
    }, skip: skip);
  });
}
