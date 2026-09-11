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

  /// What a pedal's indicator uses when the frame carries no colour for it.
  ///
  /// White, the palette default on both sides. A frame below protocol v4 has
  /// no bytes for the colours at all, so it decodes to this for every pedal
  /// rather than to a colour nothing sent.
  static const PedalColor defaultColor = PedalColor(0xFF, 0xFF, 0xFF);

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
