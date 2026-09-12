import 'package:equatable/equatable.dart';

/// One indicator hue, as the wire carries it (protocol v4, #763).
///
/// Full 8-bit RGB, matching the WS2812 the console's pills and the V1 pedal's
/// indicators are built from, so a colour a user picked reaches the LED
/// unquantised. A palette index would have been three bytes cheaper per pedal
/// and would have given the pedal a second thing to hold — and to hold a
/// stale copy of across a reboot the app did not see.
///
/// Deliberately not Flutter's `Color`: this package is the wire, and the wire
/// has no toolkit. The app converts at its own edge.
class PedalColor extends Equatable {
  /// Creates a [PedalColor] from its three channels, each `0..255`.
  const PedalColor(this.r, this.g, this.b)
    : assert(r >= 0 && r <= 255, 'r must be 0..255'),
      assert(g >= 0 && g <= 255, 'g must be 0..255'),
      assert(b >= 0 && b <= 255, 'b must be 0..255');

  /// Rebuilds a colour from a `0xRRGGBB` integer.
  factory PedalColor.fromRgb(int rgb) =>
      PedalColor((rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF, rgb & 0xFF);

  /// The eight built-in indicator hues, in the order the palette lists them.
  ///
  /// These are the values the LED is driven at, not swatch paint: the app
  /// shows the same number it sends. They are deliberately short of full
  /// saturation — a WS2812 run flat out washes its own hue out at the
  /// distance a foot reads it from, and the pair a performer has to tell
  /// apart eyes-free is two hues, not two brightnesses.
  static const PedalColor white = PedalColor(0xE6, 0xEE, 0xF9);

  /// Built-in amber.
  static const PedalColor amber = PedalColor(0xEF, 0xBC, 0x72);

  /// Built-in red.
  static const PedalColor red = PedalColor(0xEE, 0x6B, 0x70);

  /// Built-in orange.
  static const PedalColor orange = PedalColor(0xEF, 0x96, 0x66);

  /// Built-in green.
  static const PedalColor green = PedalColor(0x7A, 0xCB, 0x9E);

  /// Built-in cyan.
  static const PedalColor cyan = PedalColor(0x73, 0xCF, 0xDF);

  /// Built-in blue.
  static const PedalColor blue = PedalColor(0x82, 0xAA, 0xFF);

  /// Built-in violet.
  static const PedalColor violet = PedalColor(0xB1, 0x9A, 0xFA);

  /// What a pedal's indicator uses when nothing has chosen a colour for it.
  ///
  /// [white], which is also what the palette assigns to all ten before a user
  /// opens the editor, so the default is ONE number rather than one on each
  /// side. A frame below protocol v4 has no bytes for the colours at all, so
  /// it decodes to this for every pedal rather than to a colour nothing sent.
  static const PedalColor defaultColor = white;

  /// Red channel, `0..255`.
  final int r;

  /// Green channel, `0..255`.
  final int g;

  /// Blue channel, `0..255`.
  final int b;

  /// This colour as a `0xRRGGBB` integer.
  int get rgb => (r << 16) | (g << 8) | b;

  @override
  List<Object?> get props => [r, g, b];

  @override
  String toString() =>
      '#${rgb.toRadixString(16).padLeft(6, '0').toUpperCase()}';
}
