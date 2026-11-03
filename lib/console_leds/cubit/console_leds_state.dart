part of 'console_leds_cubit.dart';

/// The console LEDs' settings and the light sensor's last report.
class ConsoleLedsState extends Equatable {
  /// Creates a [ConsoleLedsState].
  const ConsoleLedsState({
    this.settings = const ConsoleLedSettings(),
    this.light,
  });

  /// What the player chose.
  final ConsoleLedSettings settings;

  /// The light sensor's last report, or `null` while the board says nothing
  /// about one (disconnected, or firmware older than 2.7).
  final PedalAmbientLight? light;

  /// Whether a light sensor is fitted.
  bool get sensorFitted => light?.fitted ?? false;

  /// Whether the brightness follows the sensor now: Automatic is on and a
  /// sensor reports. Otherwise the manual brightness holds.
  bool get followingLight => settings.automatic && sensorFitted;

  /// The brightness the LEDs show, perceptual, `0..1`.
  double get brightness => switch (light) {
    final light? when followingLight => consoleLedCurve.brightnessAt(
      light.level,
      dark: settings.darkReading,
      bright: settings.brightReading,
      offset: settings.offset,
    ),
    _ => settings.brightness,
  };

  /// The board's level for [brightness].
  int get ledLevel => ledLevelOf(brightness);

  /// Whether the current reading can be the dark calibration point: a sensor
  /// reads, and at least a doubling under the bright point.
  bool get canSetDark =>
      sensorFitted &&
      light!.level <=
          settings.brightReading - ConsoleLedSettings.minCalibrationSpan;

  /// Whether the current reading can be the bright calibration point.
  bool get canSetBright =>
      sensorFitted &&
      light!.level >=
          settings.darkReading + ConsoleLedSettings.minCalibrationSpan;

  /// A copy with [settings] or [light] replaced.
  ConsoleLedsState copyWith({
    ConsoleLedSettings? settings,
    PedalAmbientLight? Function()? light,
  }) => ConsoleLedsState(
    settings: settings ?? this.settings,
    light: light != null ? light() : this.light,
  );

  @override
  List<Object?> get props => [settings, light];
}
