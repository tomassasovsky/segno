// Regenerates test/fixtures/*.bin from test/helpers/golden_frames.dart.
//
//   cd packages/pedal_repository && flutter test tool/generate_golden_fixtures.dart
//
// A test rather than a script because the package depends on Flutter, which
// `dart run` cannot load. The fixtures are the cross-language contract:
// firmware/test/test_pedal_link.c decodes and re-encodes every one with the
// firmware's own C codec.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pedal_repository/pedal_repository.dart';

import '../test/helpers/golden_frames.dart';

void main() {
  test('regenerate golden fixtures', () {
    final dir = Directory('test/fixtures')..createSync(recursive: true);
    for (final entry in goldenMessages.entries) {
      final file = File('${dir.path}/${entry.key}.bin')
        ..writeAsBytesSync(PedalLinkCodec.encode(entry.value));
      stdout.writeln('wrote ${file.path} (${file.lengthSync()} bytes)');
    }
  });
}
