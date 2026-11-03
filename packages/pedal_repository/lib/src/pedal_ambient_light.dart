import 'dart:math' as math;

import 'package:equatable/equatable.dart';

/// What the console board says about its light sensor (`PEDAL_AMBIENT_*`).
/// Declaration order is the wire value.
enum PedalLightSensor {
  /// Nothing on J22: the pin follows the pad's own pulls, or sits at ground.
  none,

  /// The sensor is fitted and [PedalAmbientLight.level] is its reading.
  reading,

  /// The sensor is at the top of its range: a smaller load resistor would
  /// read this light. [PedalAmbientLight.level] is that top.
  aboveRange,
}

/// The light at the console's plate, as the board reports it once a second
/// (`AmbientLightMessage`, #1564).
///
/// [level] is the board's smoothed ADC reading on a log scale, not lux: the
/// sensor's gain is unknown to the board (the parts' bins span 9x and the
/// lens is sanded flat), so the app calibrates it against a dark and a
/// bright reading the owner captures.
class PedalAmbientLight extends Equatable {
  /// Creates a [PedalAmbientLight].
  const PedalAmbientLight({required this.sensor, this.level = 0})
    : assert(level >= 0 && level <= 255, 'level must fit a byte'),
      assert(
        sensor != PedalLightSensor.none || level == 0,
        'no level without a sensor',
      );

  /// No sensor fitted.
  static const PedalAmbientLight none = PedalAmbientLight(
    sensor: PedalLightSensor.none,
  );

  /// Level steps per doubling of the reading
  /// (`PEDAL_AMBIENT_STEPS_PER_DOUBLING`).
  static const int stepsPerDoubling = 16;

  /// Whether the board has a sensor.
  final PedalLightSensor sensor;

  /// The reading on a log scale: `counts = 2^(level / 16)`, 0 for one count
  /// or less and without a sensor.
  final int level;

  /// Whether a sensor is fitted.
  bool get fitted => sensor != PedalLightSensor.none;

  /// The reading in ADC counts (of 4095), to within 3 %: what the
  /// owner reads in Settings to calibrate. 0 without a sensor.
  int get counts => fitted ? math.pow(2, level / stepsPerDoubling).round() : 0;

  @override
  List<Object?> get props => [sensor, level];

  @override
  String toString() => 'PedalAmbientLight(${sensor.name}, $level)';
}
