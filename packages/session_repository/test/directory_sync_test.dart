import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:session_repository/src/directory_sync.dart';

void main() {
  test('flushes a directory and tolerates one that is gone', () {
    final dir = Directory.systemTemp.createTempSync('segno_sync');
    addTearDown(() => dir.deleteSync(recursive: true));

    expect(() => syncDirectory(dir.path), returnsNormally);
    expect(() => syncDirectory('${dir.path}/absent'), returnsNormally);
  });
}
