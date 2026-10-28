import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:segno/looper/view/fx/stomp/fx_stomp_textures.dart';

void main() {
  test('every tile the app paints is one the tool writes, at its scale', () {
    final tool = File('tool/stomp_textures.py').readAsStringSync();
    final scales = {
      for (final m in RegExp(r"'(\w+)': (\d+(?:\.\d+)?)").allMatches(
        RegExp(r'SCALES = \{([^}]*)\}').firstMatch(tool)!.group(1)!,
      ))
        m.group(1)!: double.parse(m.group(2)!),
    };
    final finishes =
        RegExp(
              r"'(\w+)'",
            )
            .allMatches(
              RegExp(r'FINISHES = \(([^)]*)\)').firstMatch(tool)!.group(1)!,
            )
            .map((m) => m.group(1)!)
            .toSet();

    expect(FxStompTextures.assets.keys.toSet(), finishes);
    expect(FxStompTextures.scales, scales);
    for (final asset in FxStompTextures.assets.values) {
      expect(File(asset).existsSync(), isTrue, reason: asset);
    }
  });
}
