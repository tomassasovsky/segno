import 'dart:io';
import 'dart:typed_data';

import 'package:daw_export/src/wav_info.dart';
import 'package:test/test.dart';

/// A RIFF/WAVE file as `engine_wav.c` writes it: a 16-byte `fmt ` chunk
/// (IEEE float), an optional chunk before `data`, then [frames] frames.
Uint8List _wav({
  required int sampleRate,
  required int channels,
  required int frames,
  int? dataSizeField,
  bool extraChunk = false,
}) {
  final blockAlign = channels * 4;
  final dataBytes = frames * blockAlign;
  final out = BytesBuilder()..add('RIFF'.codeUnits);
  final u32 = ByteData(4);
  out
    ..add((u32..setUint32(0, 0, Endian.little)).buffer.asUint8List())
    ..add('WAVEfmt '.codeUnits);
  final fmt = ByteData(20)
    ..setUint32(0, 16, Endian.little)
    ..setUint16(4, 3, Endian.little)
    ..setUint16(6, channels, Endian.little)
    ..setUint32(8, sampleRate, Endian.little)
    ..setUint32(12, sampleRate * blockAlign, Endian.little)
    ..setUint16(16, blockAlign, Endian.little)
    ..setUint16(18, 32, Endian.little);
  out.add(fmt.buffer.asUint8List());
  if (extraChunk) {
    out.add('LIST'.codeUnits);
    final size = ByteData(4)..setUint32(0, 3, Endian.little);
    out
      ..add(size.buffer.asUint8List())
      ..add([1, 2, 3, 0]);
  }
  out.add('data'.codeUnits);
  final size = ByteData(4)
    ..setUint32(0, dataSizeField ?? dataBytes, Endian.little);
  out
    ..add(size.buffer.asUint8List())
    ..add(Uint8List(dataBytes));
  return out.toBytes();
}

void main() {
  group('readWavInfo', () {
    late Directory dir;

    setUp(() => dir = Directory.systemTemp.createTempSync('wav_info_test_'));
    tearDown(() => dir.deleteSync(recursive: true));

    String write(Uint8List bytes) {
      final path = '${dir.path}/a.wav';
      File(path).writeAsBytesSync(bytes);
      return path;
    }

    test('reads the rate and frame count of a mono float file', () {
      final path = write(_wav(sampleRate: 96000, channels: 1, frames: 1234));
      expect(readWavInfo(path), (sampleRate: 96000, frames: 1234));
    });

    test('divides by the block size for a stereo file', () {
      final path = write(_wav(sampleRate: 48000, channels: 2, frames: 500));
      expect(readWavInfo(path), (sampleRate: 48000, frames: 500));
    });

    test('skips a chunk between fmt and data, with its pad byte', () {
      final path = write(
        _wav(sampleRate: 44100, channels: 1, frames: 10, extraChunk: true),
      );
      expect(readWavInfo(path), (sampleRate: 44100, frames: 10));
    });

    test('a data size never patched (0) reads the bytes the file holds', () {
      final path = write(
        _wav(sampleRate: 48000, channels: 1, frames: 64, dataSizeField: 0),
      );
      expect(readWavInfo(path), (sampleRate: 48000, frames: 64));
    });

    test('a data size past the end of the file reads what is there', () {
      final path = write(
        _wav(
          sampleRate: 48000,
          channels: 1,
          frames: 64,
          dataSizeField: 0xFFFFFFFF,
        ),
      );
      expect(readWavInfo(path), (sampleRate: 48000, frames: 64));
    });

    test('returns null for a missing file or one that is not a WAV', () {
      expect(readWavInfo('${dir.path}/missing.wav'), isNull);
      expect(readWavInfo(write(Uint8List.fromList([0, 1, 2]))), isNull);
      expect(
        readWavInfo(write(Uint8List.fromList('RIFF....AVI '.codeUnits))),
        isNull,
      );
    });
  });
}
