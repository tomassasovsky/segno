import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pedal_repository/pedal_repository.dart';

import 'helpers/golden_frames.dart';

void main() {
  group('golden fixtures', () {
    for (final entry in goldenMessages.entries) {
      final path = 'test/fixtures/${entry.key}.bin';

      test('$path encodes byte-for-byte', () {
        final bytes = File(path).readAsBytesSync();
        expect(
          PedalLinkCodec.encode(entry.value),
          bytes,
          reason: 'regenerate with tool/generate_golden_fixtures.dart',
        );
      });

      test('$path parses back to the golden message', () {
        final bytes = File(path).readAsBytesSync();
        expect(PedalLinkParser().push(bytes), [entry.value]);
      });
    }

    test('every fixture file has a golden message', () {
      final files = Directory('test/fixtures')
          .listSync()
          .whereType<File>()
          .map((f) => f.uri.pathSegments.last)
          .where((name) => name.endsWith('.bin'))
          .map((name) => name.substring(0, name.length - 4))
          .toSet();
      expect(files, goldenMessages.keys.toSet());
    });
  });
}
