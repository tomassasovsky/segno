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
/// as it always has. Automatic without a reporting sensor holds the manual
/// brightness.
class ConsoleLedsCubit extends Cubit<ConsoleLedsState> {
  /// Creates a [ConsoleLedsCubit].
  ConsoleLedsCubit({
    required SettingsRepository settings,
    required PedalRepository pedal,
  }) : _settings = settings,
       _pedal = pedal,
       super(ConsoleLedsState(light: pedal.ambientLight)) {
    _lightSub = pedal.ambientLightChanges.listen(
      (light) => _show(state.copyWith(light: () => light)),
    );
  }

  final SettingsRepository _settings;
  final PedalRepository _pedal;
  late final StreamSubscription<PedalAmbientLight?> _lightSub;

  /// Restores the saved settings.
  Future<void> load() async {
    final settings = await _settings.loadConsoleLeds();
    if (isClosed) return;
    _show(state.copyWith(settings: settings));
  }

  /// Sets the manual brightness, `[ConsoleLedSettings.minBrightness, 1]`.
  /// Throws when the save fails; the brightness applies either way.
  Future<void> setBrightness(double brightness) => _save(
    state.settings.copyWith(
      brightness: brightness.clamp(
        ConsoleLedSettings.minBrightness,
        ConsoleLedSettings.maxBrightness,
      ),
    ),
  );

  /// Turns Automatic on or off. On is refused while no sensor is fitted;
  /// off always works.
  Future<void> setAutomatic({required bool automatic}) async {
    if (automatic && !state.sensorFitted) return;
    await _save(state.settings.copyWith(automatic: automatic));
  }

  /// Sets the automatic brightness's brighter (+) or darker (-) shift,
  /// `-1..1`.
  Future<void> setOffset(double offset) =>
      _save(state.settings.copyWith(offset: offset.clamp(-1.0, 1.0)));

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

  Future<void> _save(ConsoleLedSettings settings) async {
    _show(state.copyWith(settings: settings));
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
    return super.close();
  }
}
