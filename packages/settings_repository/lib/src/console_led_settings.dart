import 'package:flutter/foundation.dart';

/// How bright the console's LEDs (the pills and the ring) are, and how the
/// automatic brightness reads the light sensor (#1564).
///
/// [brightness] is on a perceptual scale, `0..1` of the LEDs' full output as
/// the eye sees it; the app converts it to the board's linear level. The
/// calibration points are light-sensor readings in the board's units
/// (`PedalAmbientLight.level`: 16 steps per doubling of the raw ADC count),
/// captured by the owner in a dark and a bright room, because the sensor's
/// own gain is not known.
@immutable
class ConsoleLedSettings {
  /// Creates a [ConsoleLedSettings].
  const new({
    this.brightness = maxBrightness,
    this.automatic = false,
    this.offset = 0,
    this.darkReading = defaultDarkReading,
    this.brightReading = defaultBrightReading,
  });

  /// The dimmest a manual or automatic brightness can be.
  static const double minBrightness = 0.2;

  /// Full output: the brightness every console showed before there was a
  /// setting, and the default.
  static const double maxBrightness = 1;

  /// The calibration points before the owner captures any. They assume the
  /// sanded TEPT5600 and the 2.2 k load read about 6 counts (level 41) on a
  /// dark stage and about 1100 (level 161) in a bright room, which is a
  /// guess: calibrating replaces it.
  static const int defaultDarkReading = 41;

  /// See [defaultDarkReading].
  static const int defaultBrightReading = 161;

  /// How far apart the two calibration points must be: one doubling of the
  /// reading.
  static const int minCalibrationSpan = 16;

  /// The manual brightness, and the one automatic brightness falls back to
  /// while no sensor reports. In `[minBrightness, maxBrightness]`.
  final double brightness;

  /// Whether the brightness follows the light sensor.
  final bool automatic;

  /// The player's brighter (+) or darker (-) shift of the automatic
  /// brightness, `-1..1`.
  final double offset;

  /// The reading the owner captured in a dark room: automatic brightness is
  /// at its floor at and below it.
  final int darkReading;

  /// The reading the owner captured in a bright room: automatic brightness is
  /// at full at and above it. At least [minCalibrationSpan] above
  /// [darkReading].
  final int brightReading;

  /// A copy with the given fields replaced.
  ConsoleLedSettings copyWith({
    double? brightness,
    bool? automatic,
    double? offset,
    int? darkReading,
    int? brightReading,
  }) => ConsoleLedSettings(
    brightness: brightness ?? this.brightness,
    automatic: automatic ?? this.automatic,
    offset: offset ?? this.offset,
    darkReading: darkReading ?? this.darkReading,
    brightReading: brightReading ?? this.brightReading,
  );

  @override
  bool operator ==(Object other) =>
      other is ConsoleLedSettings &&
      other.brightness == brightness &&
      other.automatic == automatic &&
      other.offset == offset &&
      other.darkReading == darkReading &&
      other.brightReading == brightReading;

  @override
  int get hashCode =>
      Object.hash(brightness, automatic, offset, darkReading, brightReading);

  @override
  String toString() =>
      'ConsoleLedSettings($brightness, automatic: $automatic, '
      'offset: $offset, dark: $darkReading, bright: $brightReading)';
}
