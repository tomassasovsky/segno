@Tags(['fuzz'])
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:backing_repository/backing_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno_engine/segno_engine.dart';

/// The repository over the real library: the native SHA-256 (#1198's
/// `le_digest_file`), the native decoder in a background isolate, and the
/// engine through the device-free pump, where a load applies at the next
/// block rather than at once. Self-skips when `SEGNO_ENGINE_LIB` is unset:
///   export SEGNO_ENGINE_LIB="$(bash ../segno_engine/tool/build_test_lib.sh)"
void main() {
  final lib = Platform.environment['SEGNO_ENGINE_LIB'];
  final skip = lib == null || lib.isEmpty
      ? 'SEGNO_ENGINE_LIB not set — run tool/build_test_lib.sh'
      : null;

  late Directory temp;
  setUp(() => temp = Directory.systemTemp.createTempSync('native_backing'));
  tearDown(() => temp.deleteSync(recursive: true));

  double left(int k) => (k + 1) / 4096;

  String writeWav(String name, int frames) {
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
      ..setUint32(24, 48000, Endian.little)
      ..setUint32(28, 48000 * 8, Endian.little)
      ..setUint16(32, 8, Endian.little)
      ..setUint16(34, 32, Endian.little);
    ascii(36, 'data');
    data.setUint32(40, frames * 8, Endian.little);
    for (var k = 0; k < frames; k++) {
      data
        ..setFloat32(44 + 8 * k, left(k), Endian.little)
        ..setFloat32(48 + 8 * k, -left(k), Endian.little);
    }
    final path = '${temp.path}/$name';
    File(path).writeAsBytesSync(data.buffer.asUint8List());
    return path;
  }

  test(
    'imports with the full SHA-256, loads, and plays what the file holds',
    () async {
      final root = '${temp.path}/exports';
      final store = BackingAssetStore(
        root: () async => root,
        decoder: NativeAudioDecoder(),
        copier: (source, relative) async {
          final target = File('$root/$relative')
            ..parent.createSync(recursive: true);
          return File(source).copySync(target.path).path;
        },
      );
      final source = writeWav('Evening lights.wav', 1000);
      final asset = await store.import(source);
      final native = NativeStorageIo().digestFile(source) as FileDigested;
      expect(asset.digest, 'sha256:${native.sha256}');
      expect(asset.sourceFrames, 1000);
      expect(asset.peaks.last, left(999));
      expect(
        File('$root/Backing tracks/${asset.id}/info.json').existsSync(),
        isTrue,
      );

      final engine = PumpedNativeEngine()
        ..start(const EngineConfig(outputChannels: 2, maxLoopFrames: 48000))
        ..setBackingOutput(3);
      addTearDown(engine.dispose);
      final repo = BackingRepository(
        engine: engine,
        metering: engine,
        decoder: NativeAudioDecoder(),
        store: store,
      );
      addTearDown(repo.dispose);

      expect(await repo.load(asset.digest, play: true), isTrue);
      // Accepted but not applied until the next block: the token must
      // survive the read the load itself made.
      final out = Float32List(256 * 2);
      engine.pump(frames: 256, output: out);
      repo.refresh();
      expect(repo.state.loaded, asset.digest);
      expect(repo.state.playing, isTrue);
      expect(repo.state.position, 256);
      for (var k = 0; k < 256; k++) {
        expect(out[2 * k], left(k));
      }
    },
    skip: skip,
  );
}
