import 'package:equatable/equatable.dart';

/// An indicator hue transported as three full 8-bit channels by UART v8.
///
/// Independent of activation. Physical rendering applies the diffuser curve,
/// color gamma and current limit; this value has no Flutter dependency.
class PedalColor extends Equatable {
  /// Creates a [PedalColor] from its three channels, each `0..255`.
  const PedalColor(this.r, this.g, this.b)
    : assert(r >= 0 && r <= 255, 'r must be 0..255'),
      assert(g >= 0 && g <= 255, 'g must be 0..255'),
      assert(b >= 0 && b <= 255, 'b must be 0..255');

  /// Rebuilds a colour from a `0xRRGGBB` integer.
  factory PedalColor.fromRgb(int rgb) =>
      PedalColor((rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF, rgb & 0xFF);

  /// The fresh default hue: white. This never implies an active indicator.
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
