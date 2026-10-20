@Tags(['fuzz'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:segno_engine/segno_engine.dart';

// FIPS 180-2 / NIST example vectors: the oracle is the standard, not the
// implementation.
const _empty =
    'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';
const _abc = 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad';
const _m448 =
    '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1';
const _millionA =
    'cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0';

void main() {
  final lib = Platform.environment['SEGNO_ENGINE_LIB'];
  final skip = lib == null || lib.isEmpty
      ? 'SEGNO_ENGINE_LIB not set — run tool/build_test_lib.sh'
      : null;

  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('storage_io_test'));
  tearDown(() => dir.deleteSync(recursive: true));

  Uint8List ascii(String s) => Uint8List.fromList(utf8.encode(s));

  group('NativeStorageIo', () {
    test('digestBytes matches the NIST vectors', () {
      final io = NativeStorageIo();
      expect(io.digestBytes(Uint8List(0)), _empty);
      expect(io.digestBytes(ascii('abc')), _abc);
      expect(
        io.digestBytes(
          ascii('abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq'),
        ),
        _m448,
      );
      expect(
        io.digestBytes(Uint8List(1000000)..fillRange(0, 1000000, 0x61)),
        _millionA,
      );
    }, skip: skip);

    test('digestFile reads exactly the requested range', () {
      final io = NativeStorageIo();
      final file = File('${dir.path}/range.bin')
        ..writeAsBytesSync(ascii('xyzabcdef'));
      expect(
        io.digestFile(file.path, offset: 3, length: 3),
        const FileDigested(_abc),
      );
      expect(
        io.digestFile(file.path),
        FileDigested(io.digestBytes(ascii('xyzabcdef'))),
      );
      expect(
        io.digestFile(file.path, offset: 6),
        FileDigested(io.digestBytes(ascii('def'))),
      );
      expect(
        io.digestFile(file.path, offset: 9, length: 0),
        const FileDigested(_empty),
      );
    }, skip: skip);

    test('digestFile tells missing from damaged from unreadable', () {
      final io = NativeStorageIo();
      final file = File('${dir.path}/short.bin')
        ..writeAsBytesSync(ascii('xyzabcdef'));
      expect(
        io.digestFile(file.path, offset: 3, length: 7),
        isA<FileTruncated>(),
      );
      expect(io.digestFile(file.path, offset: 10), isA<FileTruncated>());
      expect(io.digestFile('${dir.path}/missing.bin'), isA<FileMissing>());
      expect(
        io.digestFile('${dir.path}/missing/deeper.bin'),
        isA<FileMissing>(),
      );
      expect(io.digestFile(dir.path), isA<FileUnreadable>());
      expect(() => io.digestFile(''), throwsArgumentError);
      expect(() => io.digestFile(file.path, offset: -1), throwsArgumentError);
      expect(() => io.digestFile(file.path, length: -1), throwsArgumentError);
    }, skip: skip);

    test('digestBytes crosses its native window without changing the '
        'digest', () {
      final io = NativeStorageIo();
      // Two and a half windows of a byte pattern, against the digest of the
      // same bytes read from a file (one native pass, no window).
      const n = NativeStorageIo.windowBytes * 5 ~/ 2;
      final bytes = Uint8List(n);
      for (var i = 0; i < n; i++) {
        bytes[i] = (i * 31 + 7) & 255;
      }
      final file = File('${dir.path}/window.bin')..writeAsBytesSync(bytes);
      expect(FileDigested(io.digestBytes(bytes)), io.digestFile(file.path));
      // And a window-sized buffer exactly.
      final exact = Uint8List.sublistView(
        bytes,
        0,
        NativeStorageIo.windowBytes,
      );
      File('${dir.path}/exact.bin').writeAsBytesSync(exact);
      expect(
        FileDigested(io.digestBytes(exact)),
        io.digestFile('${dir.path}/exact.bin'),
      );
    }, skip: skip);

    test('digestFile runs in a background isolate', () async {
      final path = '${dir.path}/big.bin';
      File(path).writeAsBytesSync(
        Uint8List(1000000)..fillRange(0, 1000000, 0x61),
      );
      final digest = await Isolate.run(
        () => NativeStorageIo().digestFile(path),
      );
      expect(digest, const FileDigested(_millionA));
    }, skip: skip);

    test('syncDirectory syncs an existing directory and throws otherwise', () {
      final io = NativeStorageIo()..syncDirectory(dir.path);
      expect(
        () => io.syncDirectory('${dir.path}/missing'),
        throwsA(
          isA<FileSystemException>().having(
            (e) => e.osError?.errorCode,
            'errno, so a pulled drive can be told apart (#1177)',
            2,
          ),
        ),
      );
      expect(() => io.syncDirectory(''), throwsA(isA<FileSystemException>()));
    }, skip: skip);

    test('renameWithoutReplacing moves to a free name and refuses a taken '
        'one, leaving both files', () {
      final io = NativeStorageIo();
      final from = File('${dir.path}/from')..writeAsStringSync('new');
      final to = '${dir.path}/to';

      expect(io.renameWithoutReplacing(from.path, to), RenameOutcome.renamed);
      expect(File(to).readAsStringSync(), 'new');
      expect(from.existsSync(), isFalse);

      final other = File('${dir.path}/other')..writeAsStringSync('other');
      expect(
        io.renameWithoutReplacing(other.path, to),
        RenameOutcome.nameTaken,
      );
      expect(File(to).readAsStringSync(), 'new');
      expect(other.readAsStringSync(), 'other');

      expect(
        () => io.renameWithoutReplacing('${dir.path}/missing', '$to-2'),
        throwsA(
          isA<FileSystemException>().having(
            (e) => e.osError?.errorCode,
            'errno',
            2,
          ),
        ),
      );
      expect(
        () => io.renameWithoutReplacing('', to),
        throwsA(isA<FileSystemException>()),
      );
    }, skip: skip);
  });
}
