import 'dart:ui' show Color;

import 'package:pedal_repository/pedal_repository.dart';

/// The one bridge between the two colour worlds.
///
/// [PedalColor] is three bytes bound for an LED and has no toolkit; `Color` is
/// what a swatch is painted with. Opaque always — an LED has no alpha, and a
/// translucent indicator would be a rendering the hardware could not match.
extension PedalColorDisplay on PedalColor {
  /// This colour as the toolkit draws it.
  Color get display => Color.fromARGB(0xFF, r, g, b);
}
