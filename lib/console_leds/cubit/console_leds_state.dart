part of 'console_leds_cubit.dart';

/// The console LEDs' settings, a slider draft over them, and what the light
/// sensor last said.
class ConsoleLedsState extends Equatable {
  /// Creates a [ConsoleLedsState].
  const ConsoleLedsState({
    this.settings = const ConsoleLedSettings(),
    this.draft,
    this.light,
    this.held,
  });

  /// What the player chose and saved.
  final ConsoleLedSettings settings;

  /// A slider position being dragged or turned, shown but not saved; `null`
  /// without one.
  final ConsoleLedSettings? draft;

  /// The light sensor's live report, or `null` while the board says nothing
  /// about one (disconnected, between hellos, or firmware older than 2.7).
  final PedalAmbientLight? light;

  /// The last report there was, kept while [light] is `null` so a link that
  /// drops and comes back changes nothing in between: a reading keeps
  /// Automatic where it was, and "no sensor" keeps the manual brightness. At
  /// launch it is the last reading the console saw, so a console starting on
  /// a dark stage starts dim instead of at full.
  final PedalAmbientLight? held;

  /// What the LEDs show: the draft while there is one, else the settings.
  ConsoleLedSettings get shown => draft ?? settings;

  /// Whether a light sensor is fitted, as the board says now.
  bool get sensorFitted => light?.fitted ?? false;

  /// The reading Automatic follows, `null` when no sensor is known.
  int? get _reading => switch (light ?? held) {
    final known? when known.fitted => known.level,
    _ => null,
  };

  /// Whether the brightness follows the sensor: Automatic is on and a reading
  /// is known. Otherwise the manual brightness holds, and is what the page's
  /// slider sets.
  bool get followingLight => shown.automatic && _reading != null;

  /// Whether Automatic is following a held reading because the board has not
  /// reported yet.
  bool get holding => followingLight && light == null;

  /// The brightness the LEDs show, perceptual, `0..1`.
  double get brightness => followingLight
      ? consoleLedCurve.brightnessAt(
          _reading!,
          dark: settings.darkReading,
          bright: settings.brightReading,
          offset: shown.offset,
        )
      : shown.brightness;

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

  /// The state with [settings] saved, and no draft.
  ConsoleLedsState saved(ConsoleLedSettings settings) =>
      ConsoleLedsState(settings: settings, light: light, held: held);

  /// The state showing [draft] over the saved settings; `null` drops it.
  ConsoleLedsState drafting(ConsoleLedSettings? draft) => ConsoleLedsState(
    settings: settings,
    draft: draft,
    light: light,
    held: held,
  );

  /// The state after the board's report [light] (`null`: it said nothing).
  ConsoleLedsState withLight(PedalAmbientLight? light) => ConsoleLedsState(
    settings: settings,
    draft: draft,
    light: light,
    held: light ?? held,
  );

  /// The state with [reading], the last one a previous run saw, held until
  /// the board reports.
  ConsoleLedsState withLastReading(int? reading) => ConsoleLedsState(
    settings: settings,
    draft: draft,
    light: light,
    held:
        held ??
        (reading == null
            ? null
            : PedalAmbientLight(
                sensor: PedalLightSensor.reading,
                level: reading,
              )),
  );

  @override
  List<Object?> get props => [settings, draft, light, held];
}
