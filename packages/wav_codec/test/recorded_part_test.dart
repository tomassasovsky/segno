import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wav_codec/wav_codec.dart';

/// The 84-byte header the native drain writes for take id 00..0f, stream 0,
/// part 1, 48 kHz stereo float, before any audio (plan Part 2's first
/// criterion).
final _nativeHeader = Uint8List.fromList([
  ...'RIFF'.codeUnits, 0x4C, 0x00, 0x00, 0x00, ...'WAVE'.codeUnits, //
  ...'fmt '.codeUnits, 0x10, 0x00, 0x00, 0x00, //
  0x03, 0x00, 0x02, 0x00, 0x80, 0xBB, 0x00, 0x00, //
  0x00, 0xDC, 0x05, 0x00, 0x08, 0x00, 0x20, 0x00, //
  ...'sgno'.codeUnits, 0x20, 0x00, 0x00, 0x00, //
  for (var i = 0; i < 16; i++) i, //
  0x00, 0x00, 0x01, 0x00, //
  for (var i = 0; i < 12; i++) 0, //
  ...'data'.codeUnits, 0x00, 0x00, 0x00, 0x00,
]);

Uint8List _takeId() => Uint8List.fromList([for (var i = 0; i < 16; i++) i]);

RecordedPartHeader _header({int channels = 2, int dataBytes = 0}) =>
    RecordedPartHeader(
      sampleRate: 48000,
      channels: channels,
      takeId: _takeId(),
      stream: 0,
      partIndex: 1,
      dataBytes: dataBytes,
    );

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('recorded_part_test'));
  tearDown(() => dir.deleteSync(recursive: true));

  group('RecordedPartHeader', () {
    test('encodes the native header byte for byte', () {
      expect(_nativeHeader, hasLength(RecordedPartHeader.headerBytes));
      expect(_header().encode(), _nativeHeader);
    });

    test('decodes the native header', () {
      final header = RecordedPartHeader.decode(_nativeHeader);
      expect(header, _header());
      expect(header.hashCode, _header().hashCode);
      expect(header.takeId, _takeId());
      expect(header.frameBytes, 8);
      expect(header.frames, 0);
    });

    test('round-trips stream, part index and payload size', () {
      final header = RecordedPartHeader(
        sampleRate: 96000,
        channels: 1,
        takeId: _takeId(),
        stream: 4,
        partIndex: 512,
        dataBytes: 4 * 1000,
      );
      final decoded = RecordedPartHeader.decode(header.encode());
      expect(decoded, header);
      expect(decoded.frames, 1000);
      final bd = ByteData.view(header.encode().buffer);
      expect(bd.getUint32(4, Endian.little), 76 + 4000);
    });

    test('refuses anything that is not a Segno float part', () {
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
        patched(20, [1]), // integer PCM
        patched(34, [24]), // 24-bit
        patched(22, [0]), // no channels
        patched(32, [6]), // wrong block align
        patched(28, [0x01]), // wrong byte rate
        patched(80, [5]), // not whole frames
      ]) {
        expect(
          () => RecordedPartHeader.decode(bad),
          throwsFormatException,
          reason: '$bad',
        );
      }
    });

    test('rejects out-of-range fields', () {
      RecordedPartHeader make({
        int sampleRate = 48000,
        int channels = 2,
        int stream = 0,
        int partIndex = 1,
        int dataBytes = 0,
        int idBytes = 16,
      }) => RecordedPartHeader(
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
        () => make(dataBytes: RecordedPartHeader.maxDataBytes + 1),
        throwsArgumentError,
      );
      expect(make(dataBytes: RecordedPartHeader.maxDataBytes), isNotNull);
    });

    test('copies the take id it is given and compares by value', () {
      final id = _takeId();
      final header = RecordedPartHeader(
        sampleRate: 48000,
        channels: 2,
        takeId: id,
        stream: 0,
        partIndex: 1,
      );
      id[0] = 99;
      expect(header.takeId[0], 0);
      expect(header == _header(dataBytes: 8), isFalse);
      expect(
        header ==
            RecordedPartHeader(
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

  test('isOver counts only magnitudes above 1.0', () {
    expect([1.0, -1.0, 0.0, 0.5].where(isOver), isEmpty);
    expect([1.0000001, -1.5, 2.0, double.infinity].where(isOver), hasLength(4));
    expect(isOver(double.nan), isFalse);
  });

  group('RecordedPartWriter', () {
    test('writes samples unchanged, counts overs and seals the sizes', () {
      final path = '${dir.path}/master-001.wav';
      final writer = RecordedPartWriter.create(path, _header())
        ..append(Float32List.fromList([0.5, -1, 1.5, -2]));
      expect(writer.frames, 2);
      expect(writer.dataBytes, 16);
      expect(writer.overs, 2);
      final sealed = writer.seal();
      expect(sealed, _header(dataBytes: 16));

      final bytes = File(path).readAsBytesSync();
      expect(bytes, hasLength(84 + 16));
      expect(bytes.sublist(84), [
        0x00, 0x00, 0x00, 0x3F, //
        0x00, 0x00, 0x80, 0xBF, //
        0x00, 0x00, 0xC0, 0x3F, //
        0x00, 0x00, 0x00, 0xC0,
      ]);
      expect(RecordedPartHeader.decode(bytes), sealed);
      final bd = ByteData.view(bytes.buffer);
      expect(bd.getUint32(4, Endian.little), bytes.length - 8);
    });

    test('an unsealed part reads its zero size header', () {
      final path = '${dir.path}/open.wav';
      final writer = RecordedPartWriter.create(path, _header(dataBytes: 800))
        ..append(Float32List.fromList([0.5, 0.5]));
      expect(
        RecordedPartHeader.decode(File(path).readAsBytesSync()).dataBytes,
        0,
      );
      writer.seal();
    });

    test('refuses partial frames and use after seal', () {
      final writer = RecordedPartWriter.create('${dir.path}/x.wav', _header());
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
      // 84 + 8 * 1000 bytes: exactly 1000 stereo frames.
      final writer = RecordedPartWriter.create(
        '${dir.path}/small.wav',
        _header(),
        partBytes: 84 + 8 * 1000 + 7,
      );
      expect(writer.remainingFrames, 1000);
      writer.append(Float32List(2 * 999));
      expect(writer.remainingFrames, 1);
      expect(() => writer.append(Float32List(4)), throwsArgumentError);
      writer.append(Float32List(2));
      expect(writer.remainingFrames, 0);
      expect(writer.seal().dataBytes, 8000);
      expect(File('${dir.path}/small.wav').lengthSync(), 84 + 8000);
      final full = RecordedPartWriter.create(
        '${dir.path}/default.wav',
        _header(),
      );
      expect(full.remainingFrames, 249999989);
      full.seal();
      expect(
        () => RecordedPartWriter.create(
          '${dir.path}/t.wav',
          _header(),
          partBytes: 91,
        ),
        throwsArgumentError,
      );
      expect(
        () => RecordedPartWriter.create(
          '${dir.path}/t.wav',
          _header(),
          partBytes: 0x100000000 + 84,
        ),
        throwsArgumentError,
      );
    });

    test('a create that cannot open the file throws', () {
      expect(
        () => RecordedPartWriter.create('${dir.path}/missing/x.wav', _header()),
        throwsA(isA<FileSystemException>()),
      );
    });
  });
}
