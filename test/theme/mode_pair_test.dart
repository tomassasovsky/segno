import 'package:flutter_test/flutter_test.dart';
import 'package:segno/looper/model/interaction_mode.dart';
import 'package:segno/theme/theme.dart';

void main() {
  test('physical pedal modes have distinct pairs; Mixer stays in Custom', () {
    // The mapping's whole job is telling the three modes apart at a glance
    // (rec red, mute green, FX blue — owner's call, 2026-08-20). Two modes
    // resolving to one colour would satisfy every "reads the resolver" check
    // above while making the chip say nothing.
    const physicalModes = [
      InteractionMode.record,
      InteractionMode.mute,
      InteractionMode.fx,
      InteractionMode.custom,
    ];
    for (final surface in [SurfaceTheme.dark, SurfaceTheme.highContrast]) {
      final outlines = physicalModes
          .map((m) => surface.modePair(m).outline)
          .toSet();
      final fills = physicalModes.map((m) => surface.modePair(m).fill).toSet();
      expect(outlines, hasLength(physicalModes.length));
      expect(fills, hasLength(physicalModes.length));
      // Mixer is a Custom performance function on the physical pedal wire.
      expect(
        surface.modePair(InteractionMode.mixer),
        surface.modePair(InteractionMode.custom),
      );
    }
  });
}
