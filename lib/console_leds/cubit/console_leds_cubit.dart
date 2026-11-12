import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/console_leds/ambient_brightness.dart';
import 'package:settings_repository/settings_repository.dart';

part 'console_leds_state.dart';

/// How bright the console's pills and ring are (#1564): a manual brightness,
/// or Automatic, which follows the light sensor on J22 through the owner's
/// calibration, shifted by the player's offset.
///
/// Every state carries its LED level to the board through the
/// [PedalRepository]. With the defaults (manual, full) that is the level the
/// board shows anyway, so a console without the setting or the sensor looks
/// as it always has. Automatic with no sensor known holds the manual
/// brightness; over a gap in the link it holds what it last knew.
class ConsoleLedsCubit extends Cubit<ConsoleLedsState> {
  /// Creates a [ConsoleLedsCubit].
  new({
    required this._settings,
    required PedalRepository pedal,
  }) : _pedal = pedal,
       super(const ConsoleLedsState().withLight(pedal.ambientLight)) {
    _lightSub = pedal.ambientLightChanges.listen(_onLight);
  }

  final SettingsRepository _settings;
  final PedalRepository _pedal;
  late final StreamSubscription<PedalAmbientLight?> _lightSub;

  /// Restores the saved settings and the last reading a previous run saw.
  Future<void> load() async {
    final settings = await _settings.loadConsoleLeds();
    final reading = await _settings.loadConsoleLedReading();
    if (isClosed) return;
    _show(state.saved(settings).withLastReading(reading));
  }

  void _onLight(PedalAmbientLight? light) {
    final was = state.held;
    _show(state.withLight(light));
    // Kept for the next launch. The board's hysteresis makes these rare, and
    // a failed write only costs that launch its dim start.
    if (light != null && light.fitted && light != was) {
      unawaited(
        _settings.saveConsoleLedReading(light.level).catchError((_) {}),
      );
    }
  }

  /// Sets the manual brightness, `[ConsoleLedSettings.minBrightness, 1]`,
  /// and saves it. Throws when the save fails; the brightness applies either
  /// way.
  Future<void> setBrightness(double brightness) =>
      _save(_withBrightness(state.settings, brightness));

  /// Shows a manual brightness without saving it: a slider being dragged or
  /// turned. [setBrightness] commits it and [cancelDraft] drops it.
  void previewBrightness(double brightness) =>
      _show(state.drafting(_withBrightness(state.shown, brightness)));

  static ConsoleLedSettings _withBrightness(
    ConsoleLedSettings settings,
    double brightness,
  ) => settings.copyWith(
    brightness: brightness.clamp(
      ConsoleLedSettings.minBrightness,
      ConsoleLedSettings.maxBrightness,
    ),
  );

  /// Turns Automatic on or off. On is refused while no sensor is fitted;
  /// off always works.
  Future<void> setAutomatic({required bool automatic}) async {
    if (automatic && !state.sensorFitted) return;
    await _save(state.settings.copyWith(automatic: automatic));
  }

  /// Sets the automatic brightness's brighter (+) or darker (-) shift,
  /// `-1..1`, and saves it.
  Future<void> setOffset(double offset) =>
      _save(_withOffset(state.settings, offset));

  /// Shows an offset without saving it; [setOffset] commits it and
  /// [cancelDraft] drops it.
  void previewOffset(double offset) =>
      _show(state.drafting(_withOffset(state.shown, offset)));

  static ConsoleLedSettings _withOffset(
    ConsoleLedSettings settings,
    double offset,
  ) => settings.copyWith(offset: offset.clamp(-1.0, 1.0));

  /// Drops a slider draft: the LEDs go back to the saved settings.
  void cancelDraft() => _show(state.drafting(null));

  /// Takes the current reading as the dark calibration point, when
  /// [ConsoleLedsState.canSetDark].
  Future<void> setDarkReading() async {
    final light = state.light;
    if (!state.canSetDark || light == null) return;
    await _save(state.settings.copyWith(darkReading: light.level));
  }

  /// Takes the current reading as the bright calibration point, when
  /// [ConsoleLedsState.canSetBright].
  Future<void> setBrightReading() async {
    final light = state.light;
    if (!state.canSetBright || light == null) return;
    await _save(state.settings.copyWith(brightReading: light.level));
  }

  /// Saves [settings], built on the saved settings (never on a draft), and
  /// drops any draft.
  Future<void> _save(ConsoleLedSettings settings) async {
    _show(state.saved(settings));
    await _settings.saveConsoleLeds(settings);
  }

  void _show(ConsoleLedsState next) {
    if (isClosed) return;
    emit(next);
    _pedal.setLedLevel(next.ledLevel);
  }

  @override
  Future<void> close() async {
    await _lightSub.cancel();
    return await super.close();
  }
}
