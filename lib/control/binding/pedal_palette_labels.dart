import 'package:segno/control/binding/pedal_palette.dart';
import 'package:segno/l10n/l10n.dart';

/// How a palette entry is NAMED, in one place: the swatch's accessible name,
/// the heading beside the field, and the colour editor's own title all say the
/// same word for the same colour.
String pedalPaletteLabel(AppLocalizations l10n, PedalPaletteEntry entry) =>
    switch (entry) {
      BuiltInPaletteEntry(:final color) => switch (color) {
        PedalPaletteColor.white => l10n.pedalColorWhite,
        PedalPaletteColor.amber => l10n.pedalColorAmber,
        PedalPaletteColor.red => l10n.pedalColorRed,
        PedalPaletteColor.orange => l10n.pedalColorOrange,
        PedalPaletteColor.green => l10n.pedalColorGreen,
        PedalPaletteColor.cyan => l10n.pedalColorCyan,
        PedalPaletteColor.blue => l10n.pedalColorBlue,
        PedalPaletteColor.violet => l10n.pedalColorViolet,
      },
      CustomPaletteEntry(:final number) => l10n.pedalColorCustom(number),
    };
