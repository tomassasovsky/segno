part of 'console_leds_cubit.dart';

/// The console LEDs' settings and the light sensor's last report.
class ConsoleLedsState extends Equatable {
  /// Creates a [ConsoleLedsState].
  const ConsoleLedsState({
    this.settings = const ConsoleLedSettings(),
    this.light,
    this.heldReading,
  });

  /// What the player chose.
  final ConsoleLedSettings settings;

  /// The light sensor's last report, or `null` while the board says nothing
  /// about one (disconnected, between hellos, or firmware older than 2.7).
  final PedalAmbientLight? light;

  /// The last reading a fitted sensor gave, kept while [light] is `null` so a
  /// link that drops and comes back does not take Automatic to the manual
  /// brightness in between; forgotten when the board reports no sensor.
  final int? heldReading;

  /// Whether a light sensor is fitted.
  bool get sensorFitted => light?.fitted ?? false;

  /// The reading Automatic follows: the live one, else the one held over a
  /// gap in the link, else (nothing heard since launch) the dark calibration
  /// point, so a console starting on a dark stage starts dim, not at full.
  /// `null` when the board reports no sensor.
  int? get _automaticReading => switch (light) {
    null => heldReading ?? settings.darkReading,
    final light when light.fitted => light.level,
    _ => null,
  };

  /// Whether the brightness follows the sensor now: Automatic is on and the
  /// board has not said there is no sensor. Otherwise the manual brightness
  /// holds, and is what the page's slider sets.
  bool get followingLight => settings.automatic && _automaticReading != null;

  /// The brightness the LEDs show, perceptual, `0..1`.
  double get brightness => switch (_automaticReading) {
    final reading? when settings.automatic => consoleLedCurve.brightnessAt(
      reading,
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

  /// A copy with [settings] replaced.
  ConsoleLedsState copyWith({ConsoleLedSettings? settings}) => ConsoleLedsState(
    settings: settings ?? this.settings,
    light: light,
    heldReading: heldReading,
  );

  /// The state after the board's report [light] (`null`: it said nothing).
  ConsoleLedsState withLight(PedalAmbientLight? light) => ConsoleLedsState(
    settings: settings,
    light: light,
    heldReading: switch (light) {
      null => heldReading,
      final light when light.fitted => light.level,
      _ => null,
    },
  );

  @override
  List<Object?> get props => [settings, light, heldReading];
}
