import 'dart:io';

import 'package:backing_repository/backing_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('internalBackingCopier', () {
    late Directory temp;
    late BackingCopier copy;
    setUp(() {
      temp = Directory.systemTemp.createTempSync('backing_copier');
      copy = internalBackingCopier(() async => '${temp.path}/root');
    });
    tearDown(() => temp.deleteSync(recursive: true));

    test('copies the bytes into place and leaves no part file', () async {
      final source = File('${temp.path}/song.wav')
        ..writeAsBytesSync(List.generate(70000, (i) => i % 251));
      final path = await copy(source.path, 'Backing tracks/abc/song.wav');
      expect(path, '${temp.path}/root/Backing tracks/abc/song.wav');
      expect(File(path).readAsBytesSync(), source.readAsBytesSync());
      expect(File('$path.part').existsSync(), isFalse);
    });

    test('a failed copy leaves nothing behind', () async {
      await expectLater(
        copy('${temp.path}/absent.wav', 'Backing tracks/abc/absent.wav'),
        throwsA(isA<FileSystemException>()),
      );
      final dir = Directory('${temp.path}/root/Backing tracks/abc');
      expect(dir.listSync(), isEmpty);
    });

    test('refuses a path that leaves the root', () async {
      await expectLater(
        copy('${temp.path}/x', '../x'),
        throwsArgumentError,
      );
    });
  });
}
