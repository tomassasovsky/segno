import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wav_codec/wav_codec.dart';

/// The 84-byte header the native drain writes for take id 00..0f, stream 0,
/// part 1, 48 kHz stereo, before any audio (plan Part 2's first criterion).
final _nativeHeader = Uint8List.fromList([
  ...'RIFF'.codeUnits, 0x4C, 0x00, 0x00, 0x00, ...'WAVE'.codeUnits, //
  ...'fmt '.codeUnits, 0x10, 0x00, 0x00, 0x00, //
  0x01, 0x00, 0x02, 0x00, 0x80, 0xBB, 0x00, 0x00, //
  0x00, 0x65, 0x04, 0x00, 0x06, 0x00, 0x18, 0x00, //
  ...'sgno'.codeUnits, 0x20, 0x00, 0x00, 0x00, //
  for (var i = 0; i < 16; i++) i, //
  0x00, 0x00, 0x01, 0x00, //
  for (var i = 0; i < 12; i++) 0, //
  ...'data'.codeUnits, 0x00, 0x00, 0x00, 0x00,
]);

Uint8List _takeId() => Uint8List.fromList([for (var i = 0; i < 16; i++) i]);

Pcm24PartHeader _header({int channels = 2, int dataBytes = 0}) =>
    Pcm24PartHeader(
      sampleRate: 48000,
      channels: channels,
      takeId: _takeId(),
      stream: 0,
      partIndex: 1,
      dataBytes: dataBytes,
    );

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('pcm24_part_test'));
  tearDown(() => dir.deleteSync(recursive: true));

  group('Pcm24PartHeader', () {
    test('encodes the native header byte for byte', () {
      expect(_nativeHeader, hasLength(Pcm24PartHeader.headerBytes));
      expect(_header().encode(), _nativeHeader);
    });

    test('decodes the native header', () {
      final header = Pcm24PartHeader.decode(_nativeHeader);
      expect(header, _header());
      expect(header.hashCode, _header().hashCode);
      expect(header.takeId, _takeId());
      expect(header.frameBytes, 6);
      expect(header.frames, 0);
    });

    test('round-trips stream, part index and payload size', () {
      final header = Pcm24PartHeader(
        sampleRate: 96000,
        channels: 1,
        takeId: _takeId(),
        stream: 4,
        partIndex: 512,
        dataBytes: 3 * 1000,
      );
      final decoded = Pcm24PartHeader.decode(header.encode());
      expect(decoded, header);
      expect(decoded.frames, 1000);
      final bd = ByteData.view(header.encode().buffer);
      expect(bd.getUint32(4, Endian.little), 76 + 3000);
    });

    test('refuses anything that is not a Segno 24-bit part', () {
      Uint8List patched(int offset, List<int> bytes) =>
          Uint8List.fromList(_nativeHeader)
            ..setRange(offset, offset + bytes.length, bytes);
      for (final bad in [
        Uint8List(83),
        patched(0, 'RIFX'.codeUnits),
        patched(8, 'AVI '.codeUnits),
        patched(12, 'junk'.codeUnits),
        patched(16, [18]),
        patched(36, 'LIST'.codeUnits),
        patched(40, [16]),
        patched(76, 'fact'.codeUnits),
      ]) {
        expect(
          () => Pcm24PartHeader.decode(bad),
          throwsFormatException,
          reason: '$bad',
        );
      }
      for (final bad in [
        patched(20, [3]), // IEEE float
        patched(34, [16]), // 16-bit
        patched(22, [0]), // no channels
        patched(32, [4]), // wrong block align
        patched(28, [0x01]), // wrong byte rate
      ]) {
        expect(() => Pcm24PartHeader.decode(bad), throwsFormatException);
      }
      expect(
        () => Pcm24PartHeader.decode(patched(80, [5])),
        throwsFormatException,
      );
    });

    test('rejects out-of-range fields', () {
      Pcm24PartHeader make({
        int sampleRate = 48000,
        int channels = 2,
        int stream = 0,
        int partIndex = 1,
        int dataBytes = 0,
        int idBytes = 16,
      }) => Pcm24PartHeader(
        sampleRate: sampleRate,
        channels: channels,
        takeId: Uint8List(idBytes),
        stream: stream,
        partIndex: partIndex,
        dataBytes: dataBytes,
      );
      expect(() => make(idBytes: 15), throwsArgumentError);
      expect(() => make(channels: 0), throwsArgumentError);
      expect(() => make(channels: 0x10000), throwsArgumentError);
      expect(() => make(sampleRate: 0), throwsArgumentError);
      expect(() => make(sampleRate: 0x7FFFFFFF), throwsArgumentError);
      expect(() => make(stream: -1), throwsArgumentError);
      expect(() => make(stream: 0x10000), throwsArgumentError);
      expect(() => make(partIndex: 0), throwsArgumentError);
      expect(() => make(partIndex: 0x10000), throwsArgumentError);
      expect(() => make(dataBytes: -1), throwsArgumentError);
      expect(
        () => make(dataBytes: Pcm24PartHeader.maxDataBytes + 1),
        throwsArgumentError,
      );
      expect(make(dataBytes: Pcm24PartHeader.maxDataBytes), isNotNull);
    });

    test('copies the take id it is given', () {
      final id = _takeId();
      final header = _header();
      id[0] = 99;
      expect(header.takeId[0], 0);
      expect(header == _header(dataBytes: 6), isFalse);
      expect(
        header ==
            Pcm24PartHeader(
              sampleRate: 48000,
              channels: 2,
              takeId: Uint8List(16),
              stream: 0,
              partIndex: 1,
            ),
        isFalse,
      );
    });
  });

  group('pcm24FromFloat', () {
    test('matches the native conversion', () {
      expect(pcm24FromFloat(0.5), 0x400000);
      expect(pcm24FromFloat(-1), -0x800000);
      expect(pcm24FromFloat(1), 0x7FFFFF);
      expect(pcm24FromFloat(2), 0x7FFFFF);
      expect(pcm24FromFloat(-2), -0x800000);
      expect(pcm24FromFloat(-0.25), -0x200000);
      expect(pcm24FromFloat(0.25), 0x200000);
      expect(pcm24FromFloat(0), 0);
      expect(pcm24FromFloat(double.nan), 0);
      // Half away from zero, like the native writer.
      expect(pcm24FromFloat(0.5 / 8388608), 1);
      expect(pcm24FromFloat(-0.5 / 8388608), -1);
    });
  });

  group('Pcm24Writer', () {
    test('writes 24-bit little-endian samples and seals the sizes', () {
      final path = '${dir.path}/master-001.wav';
      final writer = Pcm24Writer.create(path, _header())
        ..append(Float32List.fromList([0.5, -1, 1, 2, -0.25, 0.25]));
      expect(writer.frames, 3);
      expect(writer.dataBytes, 18);
      final sealed = writer.seal();
      expect(sealed, _header(dataBytes: 18));

      final bytes = File(path).readAsBytesSync();
      expect(bytes, hasLength(84 + 18));
      expect(bytes.sublist(84), [
        0x00, 0x00, 0x40, //
        0x00, 0x00, 0x80, //
        0xFF, 0xFF, 0x7F, //
        0xFF, 0xFF, 0x7F, //
        0x00, 0x00, 0xE0, //
        0x00, 0x00, 0x20,
      ]);
      expect(Pcm24PartHeader.decode(bytes), sealed);
      final bd = ByteData.view(bytes.buffer);
      expect(bd.getUint32(4, Endian.little), bytes.length - 8);
    });

    test('an unsealed part reads its zero size header', () {
      final path = '${dir.path}/open.wav';
      final writer = Pcm24Writer.create(path, _header(dataBytes: 600))
        ..append(Float32List.fromList([0.5, 0.5]));
      expect(
        Pcm24PartHeader.decode(File(path).readAsBytesSync()).dataBytes,
        0,
      );
      writer.seal();
    });

    test('refuses partial frames, oversize payloads and use after seal', () {
      final writer = Pcm24Writer.create('${dir.path}/x.wav', _header());
      expect(
        () => writer.append(Float32List.fromList([0.5])),
        throwsArgumentError,
      );
      writer.seal();
      expect(writer.seal, throwsStateError);
      expect(
        () => writer.append(Float32List.fromList([0.5, 0.5])),
        throwsStateError,
      );
    });

    test('holds at most partBytes, header included', () {
      // 84 + 6 * 1000 bytes: exactly 1000 stereo frames.
      final writer = Pcm24Writer.create(
        '${dir.path}/small.wav',
        _header(),
        partBytes: 84 + 6 * 1000 + 5,
      );
      expect(writer.remainingFrames, 1000);
      writer.append(Float32List(2 * 999));
      expect(writer.remainingFrames, 1);
      expect(() => writer.append(Float32List(4)), throwsArgumentError);
      writer.append(Float32List(2));
      expect(writer.remainingFrames, 0);
      expect(writer.seal().dataBytes, 6000);
      expect(File('${dir.path}/small.wav').lengthSync(), 84 + 6000);
      final full = Pcm24Writer.create('${dir.path}/default.wav', _header());
      expect(full.remainingFrames, 333333319);
      full.seal();
      expect(
        () => Pcm24Writer.create('${dir.path}/t.wav', _header(), partBytes: 89),
        throwsArgumentError,
      );
      expect(
        () => Pcm24Writer.create(
          '${dir.path}/t.wav',
          _header(),
          partBytes: 0x100000000 + 84,
        ),
        throwsArgumentError,
      );
    });

    test('a create that cannot write leaves no open file behind', () {
      expect(
        () => Pcm24Writer.create('${dir.path}/missing/x.wav', _header()),
        throwsA(isA<FileSystemException>()),
      );
    });
  });

  group('readPcm24Frames', () {
    late String path;
    setUp(() {
      path = '${dir.path}/read.wav';
      final samples = Float32List(2000);
      for (var i = 0; i < samples.length; i++) {
        samples[i] = (i - 1000) / 1000;
      }
      Pcm24Writer.create(path, _header())
        ..append(samples)
        ..seal();
    });

    test('reads the requested range within one 24-bit step', () {
      final frames = readPcm24Frames(path, offsetFrames: 10, count: 5);
      expect(frames, hasLength(10));
      for (var i = 0; i < frames.length; i++) {
        expect(frames[i], closeTo((20 + i - 1000) / 1000, 1 / 8388608));
      }
    });

    test('stops at the end of the payload', () {
      expect(readPcm24Frames(path, offsetFrames: 998, count: 10), hasLength(4));
      expect(readPcm24Frames(path, offsetFrames: 5000, count: 10), isEmpty);
    });

    test('reads an unsealed part to its last whole frame', () {
      final open = '${dir.path}/unsealed.wav';
      final writer = Pcm24Writer.create(open, _header())
        ..append(Float32List.fromList([0.5, -0.5, 0.25, -0.25]));
      // Simulate a crash: the header still says 0, the file holds 2 frames
      // plus a torn byte.
      File(open).writeAsBytesSync([0x01], mode: FileMode.append);
      expect(readPcm24Frames(open, offsetFrames: 0, count: 10), [
        0.5,
        -0.5,
        0.25,
        -0.25,
      ]);
      writer.seal();
    });

    test('refuses negative ranges and a file that is not a part', () {
      expect(
        () => readPcm24Frames(path, offsetFrames: -1, count: 1),
        throwsArgumentError,
      );
      expect(
        () => readPcm24Frames(path, offsetFrames: 0, count: -1),
        throwsArgumentError,
      );
      final float = '${dir.path}/float.wav';
      File(float).writeAsBytesSync(
        WavCodec.encodeFloat32(
          samples: Float32List(84),
          sampleRate: 48000,
          channels: 1,
        ),
      );
      expect(
        () => readPcm24Frames(float, offsetFrames: 0, count: 1),
        throwsFormatException,
      );
    });
  });
}
