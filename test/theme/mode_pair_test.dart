import 'package:flutter_test/flutter_test.dart';
import 'package:segno/looper/model/interaction_mode.dart';
import 'package:segno/theme/theme.dart';

void main() {
  test('every mode has a distinct pair', () {
    // The mapping's whole job is telling the three modes apart at a glance
    // (rec red, mute green, FX blue — owner's call, 2026-08-20). Two modes
    // resolving to one colour would satisfy every "reads the resolver" check
    // above while making the chip say nothing.
    for (final surface in [SurfaceTheme.dark, SurfaceTheme.highContrast]) {
      final outlines = InteractionMode.values
          .map((m) => surface.modePair(m).outline)
          .toSet();
      final fills = InteractionMode.values
          .map((m) => surface.modePair(m).fill)
          .toSet();
      expect(outlines, hasLength(InteractionMode.values.length));
      expect(fills, hasLength(InteractionMode.values.length));
    }
  });
}
