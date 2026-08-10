import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:segno/theme/surface_theme.dart';

/// Shared visual language carried over from the Signal surface #533 replaced
/// — deliberately calm and native. Monospace is reserved for genuine numerics
/// (dB, `%`, counts, channel ids); section labels and prose use the app's sans
/// face ([signalLabel]); and colour signals **state** (accent = live/active,
/// neutral = at rest) rather than decoration. Every hue resolves from
/// [SurfaceTheme] tokens — nothing here hardcodes a colour, so what is left
/// honours the high-contrast variant like the rest.

/// The mix-knob ceiling: 2.0 linear gain ≈ +6 dB (matches the engine's
/// `LE_MAX_GAIN`), so a quiet take/input can be boosted, not only attenuated.
const double kSignalMaxGain = 2;

/// A linear gain [v] as a signed dB readout, to one decimal (`+6.0 dB`,
/// `0.0 dB`, `−3.5 dB`, `−∞`).
///
/// Lives here rather than inside a widget because two surfaces read the same
/// number: the knob on the surface #533 replaces, and the level row on the
/// Signal panel that replaces it. One mapping, one place — a second copy is a
/// second answer to "how loud is this" the moment either is touched.
String signalGainReadout(double v) {
  if (v <= 0.001) return '−∞';
  final db = 20 * (math.log(v) / math.ln10);
  if (db.abs() < 0.05) return '0.0 dB';
  return '${db >= 0 ? '+' : '−'}${db.abs().toStringAsFixed(1)} dB';
}

/// A monospace text style ([SurfaceTheme.monoFont]) for **numerics and
/// machine readouts only** — dB values, `%`, counts, channel ids. Section
/// labels and prose use [signalLabel] instead.
TextStyle signalMono({
  required Color color,
  double size = 11,
  FontWeight weight = FontWeight.w400,
}) => TextStyle(
  fontFamily: SurfaceTheme.monoFont,
  color: color,
  fontSize: size,
  fontWeight: weight,
  height: 1.1,
);

/// A sans text style (the app's display face) for section labels, captions, and
/// prose on the Signal surface — the calm counterpart to [signalMono]. No
/// letter-spacing, no forced uppercasing.
TextStyle signalLabel({
  required Color color,
  double size = 11,
  FontWeight weight = FontWeight.w400,
}) => TextStyle(
  fontFamily: SurfaceTheme.displayFont,
  color: color,
  fontSize: size,
  fontWeight: weight,
  height: 1.2,
);
