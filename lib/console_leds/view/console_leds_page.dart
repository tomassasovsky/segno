import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/app/app_toasts.dart';
import 'package:segno/console_leds/ambient_brightness.dart';
import 'package:segno/console_leds/cubit/console_leds_cubit.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/view/loop_settings/loop_edit_scope.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_frame.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/settings/view/settings_fact_panel.dart';
import 'package:segno/theme/theme.dart';
import 'package:settings_repository/settings_repository.dart';
import 'package:toastification/toastification.dart';

/// The toast that says a console LED change was not saved.
const String consoleLedsSaveFailedToast = 'console_leds_save_failed';

/// Settings > Displays > Console LEDs (#1564): how bright the pedal pills and
/// the ring are, Manual or Automatic from the light sensor, and the sensor's
/// reading and calibration.
///
/// Built from the Settings pages' existing parts (choice row, slider, notes,
/// fact panel, outlined buttons) on the Displays page's two columns. The
/// design file has no frame for it yet.
class ConsoleLedsPage extends StatefulWidget {
  /// Creates a [ConsoleLedsPage].
  const ConsoleLedsPage({super.key});

  /// The page as a route.
  static Route<void> route() =>
      MaterialPageRoute<void>(builder: (_) => const ConsoleLedsPage());

  /// The two columns' left edges in the frame's main area.
  static const List<double> columns = [100, 972];

  /// Each column's width.
  static const double columnWidth = 848;

  /// The columns' top in the frame's main area, under the title row.
  static const double top = 120;

  @override
  State<ConsoleLedsPage> createState() => _ConsoleLedsPageState();
}

class _ConsoleLedsPageState extends State<ConsoleLedsPage> {
  final _edits = LoopEditCoordinator();

  /// Back first discards an unfinished slider edit, then leaves.
  void _back() {
    if (_edits.cancel()) return;
    Navigator.maybePop(context);
  }

  void _stage() {
    _edits.cancel();
    Navigator.popUntil(context, (route) => route.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return LoopEditScope(
      coordinator: _edits,
      child: CallbackShortcuts(
        bindings: {const SingleActivator(LogicalKeyboardKey.escape): _back},
        child: Focus(
          autofocus: true,
          child: Scaffold(
            body: LoopSettingsFrame(
              crumb: l10n.settingsCrumb(
                '${l10n.settingsDisplaysTitle} / ${l10n.consoleLedsTitle}',
              ),
              title: l10n.consoleLedsTitle,
              titleLeft: 100,
              onBack: _back,
              onStage: _stage,
              children: [
                Positioned(
                  left: ConsoleLedsPage.columns[0],
                  top: ConsoleLedsPage.top,
                  child: const _BrightnessColumn(),
                ),
                Positioned(
                  left: ConsoleLedsPage.columns[1],
                  top: ConsoleLedsPage.top,
                  child: const _SensorColumn(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Runs a console LED change; a failed save says so in a toast, cleared by
/// the next change that does save. The change applies either way.
void _edit(
  BuildContext context,
  Future<void> Function(ConsoleLedsCubit cubit) change,
) {
  final cubit = context.read<ConsoleLedsCubit>();
  final l10n = context.l10n;
  unawaited(() async {
    try {
      await change(cubit);
      if (!context.mounted) return;
      dismissAppToast(consoleLedsSaveFailedToast);
    } on Object {
      if (!context.mounted) return;
      showAppSnackToast(
        id: consoleLedsSaveFailedToast,
        type: ToastificationType.error,
        icon: const Icon(Icons.error_outline),
        title: Text(l10n.displayBrightnessSaveFailed),
      );
    }
  }());
}

/// Manual or Automatic, the slider for the one that applies, a note on what
/// it does or why Automatic is unavailable, and the two calibration buttons.
class _BrightnessColumn extends StatelessWidget {
  const _BrightnessColumn();

  static const double _width = ConsoleLedsPage.columnWidth;
  static const double _range =
      ConsoleLedSettings.maxBrightness - ConsoleLedSettings.minBrightness;

  /// The manual slider's position for [brightness].
  static double travelOf(double brightness) =>
      ((brightness - ConsoleLedSettings.minBrightness) / _range).clamp(
        0.0,
        1.0,
      );

  /// The manual brightness at slider position [travel], to the whole percent.
  static double brightnessAt(double travel) =>
      ((ConsoleLedSettings.minBrightness + travel.clamp(0.0, 1.0) * _range) *
              100)
          .round() /
      100;

  /// Brightness points a full offset moves.
  static final int _offsetPoints = (consoleLedCurve.offsetSpan * 100).round();

  /// The offset at slider position [travel], in whole points of brightness.
  static double offsetAt(double travel) =>
      ((travel.clamp(0.0, 1.0) * 2 - 1) * _offsetPoints).round() /
      _offsetPoints;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final state = context.watch<ConsoleLedsCubit>().state;
    final settings = state.settings;
    final automatic = settings.automatic;
    // The slider sets what the LEDs follow now: the offset while Automatic
    // follows the sensor, else the manual brightness in force.
    final offsetSlider = state.followingLight;
    String percent(double travel) =>
        l10n.trayBrightnessPercent((brightnessAt(travel) * 100).round());
    String shift(double travel) {
      final points = (offsetAt(travel) * _offsetPoints).round();
      return l10n.consoleLedsOffsetPercent(
        points > 0 ? '+$points' : '$points',
      );
    }

    final note = switch (state.light?.sensor) {
      null => l10n.consoleLedsNoteNotReported,
      PedalLightSensor.none => l10n.consoleLedsNoteNoSensor,
      PedalLightSensor.aboveRange => l10n.consoleLedsNoteAboveRange,
      PedalLightSensor.reading =>
        automatic ? l10n.consoleLedsNoteAutomatic : l10n.consoleLedsNoteManual,
    };
    final noteTone = state.light?.sensor == PedalLightSensor.aboveRange
        ? LoopNoteTone.error
        : LoopNoteTone.plain;
    final travel = offsetSlider
        ? (settings.offset + 1) / 2
        : travelOf(settings.brightness);
    final readout = offsetSlider ? shift(travel) : percent(travel);
    final label = offsetSlider
        ? l10n.consoleLedsOffset
        : l10n.trayBrightnessLabel;
    // Dragging or turning previews; a release or Enter saves; Back restores.
    void preview(double travel) {
      final cubit = context.read<ConsoleLedsCubit>();
      offsetSlider
          ? cubit.previewOffset(offsetAt(travel))
          : cubit.previewBrightness(brightnessAt(travel));
    }

    void commit(double travel) => _edit(
      context,
      (cubit) => offsetSlider
          ? cubit.setOffset(offsetAt(travel))
          : cubit.setBrightness(brightnessAt(travel)),
    );
    return SizedBox(
      width: _width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LoopChoiceRow<bool>(
            key: const Key('console_leds_mode'),
            values: const [false, true],
            labelOf: (value) =>
                value ? l10n.consoleLedsAutomatic : l10n.consoleLedsManual,
            keyOf: (value) =>
                Key('console_leds_${value ? 'automatic' : 'manual'}'),
            selected: automatic,
            // Without a sensor Automatic cannot be chosen; a console left on
            // it can still go back to Manual.
            enabled: state.sensorFitted || automatic,
            onSelected: (value) => _edit(
              context,
              (cubit) => cubit.setAutomatic(automatic: value),
            ),
            width: _width,
            height: 80,
          ),
          const SizedBox(height: 40),
          Row(
            children: [
              Expanded(
                child: AppText(
                  label,
                  style: TextStyle(
                    color: surface.textPrimary,
                    fontSize: 24,
                    height: 1,
                  ),
                ),
              ),
              AppText(
                readout,
                key: const Key('console_leds_readout'),
                style: TextStyle(
                  color: surface.textSecondary,
                  fontSize: 24,
                  fontFamily: SurfaceTheme.monoFont,
                  height: 1,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          LoopSlider(
            key: Key('console_leds_${offsetSlider ? 'offset' : 'brightness'}'),
            width: _width,
            value: travel,
            keyboardStep: offsetSlider ? 1 / (2 * _offsetPoints) : 0.0125,
            semanticLabel: label,
            semanticValueBuilder: offsetSlider ? shift : percent,
            onChanged: preview,
            onChangeEnd: commit,
            onEditCancel: preview,
            onDoubleTap: () => _edit(
              context,
              (cubit) => offsetSlider
                  ? cubit.setOffset(0)
                  : cubit.setBrightness(ConsoleLedSettings.maxBrightness),
            ),
          ),
          const SizedBox(height: 32),
          LoopNote(note, key: const Key('console_leds_note'), tone: noteTone),
          const SizedBox(height: 56),
          LoopSectionLabel(l10n.consoleLedsCalibrate),
          const SizedBox(height: 16),
          LoopNote(l10n.consoleLedsCalibrateNote),
          const SizedBox(height: 24),
          Row(
            children: [
              LoopOutlinedButton(
                key: const Key('console_leds_set_dark'),
                width: 300,
                label: l10n.consoleLedsDarkRow,
                onTap: state.canSetDark
                    ? () => _edit(context, (cubit) => cubit.setDarkReading())
                    : null,
              ),
              const SizedBox(width: 24),
              LoopOutlinedButton(
                key: const Key('console_leds_set_bright'),
                width: 300,
                label: l10n.consoleLedsBrightRow,
                onTap: state.canSetBright
                    ? () => _edit(context, (cubit) => cubit.setBrightReading())
                    : null,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// What the sensor reads, where the calibration points are, and the
/// brightness the LEDs show.
class _SensorColumn extends StatelessWidget {
  const _SensorColumn();

  static const double _width = ConsoleLedsPage.columnWidth;

  static int _countsOf(int level) => PedalAmbientLight(
    sensor: PedalLightSensor.reading,
    level: level,
  ).counts;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final state = context.watch<ConsoleLedsCubit>().state;
    final light = state.light;
    final settings = state.settings;
    final fitted = state.sensorFitted;
    String reading(int level) => l10n.consoleLedsReadingValue(_countsOf(level));
    return SizedBox(
      width: _width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SettingsFactPanel(
            key: const Key('console_leds_sensor'),
            title: l10n.consoleLedsSensorPanel,
            width: _width,
            rows: [
              SettingsFactRow(
                key: const Key('console_leds_sensor_state'),
                label: l10n.consoleLedsSensorRow,
                value: switch (light?.sensor) {
                  null => l10n.aboutNotReported,
                  PedalLightSensor.none => l10n.consoleLedsSensorNone,
                  PedalLightSensor.reading => l10n.consoleLedsSensorFitted,
                  PedalLightSensor.aboveRange =>
                    l10n.consoleLedsSensorAboveRange,
                },
              ),
              if (light != null && fitted)
                SettingsFactRow(
                  key: const Key('console_leds_reading'),
                  label: l10n.consoleLedsReadingRow,
                  value: l10n.consoleLedsReadingValue(light.counts),
                ),
              SettingsFactRow(
                key: const Key('console_leds_dark'),
                label: l10n.consoleLedsDarkRow,
                value: reading(settings.darkReading),
              ),
              SettingsFactRow(
                key: const Key('console_leds_bright'),
                label: l10n.consoleLedsBrightRow,
                value: reading(settings.brightReading),
              ),
              SettingsFactRow(
                key: const Key('console_leds_now'),
                label: l10n.consoleLedsNowRow,
                value: l10n.trayBrightnessPercent(
                  (state.brightness * 100).round(),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
