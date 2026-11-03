import 'dart:math' as math;

import 'package:settings_repository/settings_repository.dart';

/// Maps the light sensor's reading to a brightness, on a perceptual scale,
/// between two calibrated readings (#1564).
///
/// The reading is already logarithmic (`PedalAmbientLight.level`, 16 steps
/// per doubling of the light), and the eye judges both the room and the
/// LEDs in ratios, so the brightness runs in a straight line from [floor] at
/// the dark calibration point to [ceiling] at the bright one, flat beyond
/// them. A player's offset shifts the whole line by up to [offsetSpan].
///
/// The console LEDs use [consoleLedCurve]. This is the seam for the screens
/// too: they would take their own curve (their own floor and ceiling) over
/// the same reading and calibration, with no change here.
class AmbientBrightnessCurve {
  /// Creates an [AmbientBrightnessCurve].
  const AmbientBrightnessCurve({
    required this.floor,
    required this.minimum,
    this.ceiling = 1,
    this.offsetSpan = 0.3,
  }) : assert(
         minimum <= floor && floor < ceiling,
         'minimum <= floor < ceiling',
       );

  /// The brightness at and below the dark calibration point.
  final double floor;

  /// The brightness at and above the bright calibration point.
  final double ceiling;

  /// The least a darker offset can take the brightness to.
  final double minimum;

  /// How far a full offset (`-1` or `1`) shifts the brightness.
  final double offsetSpan;

  /// The brightness, `[minimum, ceiling]`, for [reading] with the calibration
  /// points [dark] and [bright] (`dark < bright`) and the player's [offset]
  /// (`-1..1`).
  double brightnessAt(
    int reading, {
    required int dark,
    required int bright,
    double offset = 0,
  }) {
    final t = ((reading - dark) / (bright - dark)).clamp(0.0, 1.0);
    return (floor + (ceiling - floor) * t + offset * offsetSpan).clamp(
      minimum,
      ceiling,
    );
  }
}

/// The console LEDs' curve: about a third of full on a dark stage, full in a
/// bright room, never brighter than the console has always been.
const consoleLedCurve = AmbientBrightnessCurve(
  floor: 0.35,
  minimum: ConsoleLedSettings.minBrightness,
);

/// The board's linear LED level (`1..255`) for a perceptual [brightness]
/// (`0..1`). The LEDs' output is linear in the level and the eye's response
/// to it is about a 2.2 power, the gamma the board already puts on colours,
/// so half the brightness is about a fifth of the level. Full is 255, what
/// the board shows without being told.
int ledLevelOf(double brightness) =>
    math.max(1, (255 * math.pow(brightness.clamp(0.0, 1.0), 2.2)).round());
