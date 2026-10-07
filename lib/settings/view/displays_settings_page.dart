import 'dart:async';

import 'package:brightness_client/brightness_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:segno/app/app_toasts.dart';
import 'package:segno/appliance/display_brightness_cubit.dart';
import 'package:segno/appliance/display_brightness_edit.dart';
import 'package:segno/appliance/display_presence_cubit.dart';
import 'package:segno/appliance/idle_dim_cubit.dart';
import 'package:segno/appliance/software_brightness.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/cubit/high_contrast_cubit.dart';
import 'package:segno/looper/cubit/refresh_rate_cubit.dart';
import 'package:segno/looper/view/loop_settings/loop_edit_scope.dart';
import 'package:segno/looper/view/loop_settings/loop_select.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_frame.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/looper/view/shortcuts_help_sheet.dart';
import 'package:segno/theme/theme.dart';
import 'package:segno/visualizer/cubit/waveform_window_cubit.dart';
import 'package:settings_repository/settings_repository.dart';
import 'package:toastification/toastification.dart';

/// The toast that says an idle-dim choice was not saved.
const String idleDimSaveFailedToast = 'idle_dim_save_failed';

/// Settings > Displays (pen 30): a card per panel, Track display first, each
/// with its own brightness; Dim while idle under them; and the screen
/// settings the console already had in one Display options row.
///
/// Presence is read while the page is open, so a panel unplugged in front of
/// the player says so here.
class DisplaysSettingsPage extends StatefulWidget {
  /// Creates a [DisplaysSettingsPage].
  const DisplaysSettingsPage({super.key});

  /// The two cards' left edges in the frame's main area: the pen's 100 px
  /// page margin, then a 24 px gutter.
  static const List<double> columns = [100, 972];

  /// Each card's width.
  static const double cardWidth = 848;

  /// The cards' top in the frame's main area, under the title row.
  static const double top = 120;

  /// The full content width.
  static const double contentWidth = 1720;

  /// Where Dim while idle starts.
  static const double dimTop = 556;

  /// Where Display options starts.
  static const double optionsTop = 716;

  @override
  State<DisplaysSettingsPage> createState() => _DisplaysSettingsPageState();
}

class _DisplaysSettingsPageState extends State<DisplaysSettingsPage> {
  final _edits = LoopEditCoordinator();

  /// Back first discards an unfinished brightness edit, then leaves.
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
    return BlocProvider(
      create: (context) =>
          DisplayPresenceCubit(outputs: context.read<DisplayOutputs>())
            ..watch(),
      child: LoopEditScope(
        coordinator: _edits,
        child: CallbackShortcuts(
          bindings: {const SingleActivator(LogicalKeyboardKey.escape): _back},
          child: Focus(
            autofocus: true,
            child: Scaffold(
              body: LoopSettingsFrame(
                crumb: l10n.settingsCrumb(l10n.settingsDisplaysTitle),
                title: l10n.settingsDisplaysTitle,
                titleLeft: 100,
                onBack: _back,
                onStage: _stage,
                children: const [
                  Positioned(
                    left: 100,
                    top: DisplaysSettingsPage.top,
                    child: _DisplayCards(),
                  ),
                  Positioned(
                    left: 100,
                    top: DisplaysSettingsPage.dimTop,
                    child: _DimWhileIdle(),
                  ),
                  Positioned(
                    left: 100,
                    top: DisplaysSettingsPage.optionsTop,
                    child: _DisplayOptions(),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DisplayCards extends StatelessWidget {
  const _DisplayCards();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final unplugged = context.watch<DisplayPresenceCubit>().state;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DisplayCard(
          key: const Key('displays_card_track'),
          role: DisplayRole.track,
          title: l10n.displaysTrackDisplay,
          roleLabel: l10n.displaysTrackRole,
          panelLabel: l10n.displaysTrackPanel,
          connected: !unplugged.contains(DisplayRole.track),
        ),
        const SizedBox(
          width:
              DisplaysSettingsPage.contentWidth -
              2 * DisplaysSettingsPage.cardWidth,
        ),
        DisplayCard(
          key: const Key('displays_card_main'),
          role: DisplayRole.main,
          title: l10n.displaysMainDisplay,
          roleLabel: l10n.displaysMainRole,
          panelLabel: l10n.displaysMainPanel,
          connected: !unplugged.contains(DisplayRole.main),
        ),
      ],
    );
  }
}

/// One panel's card: its preview, what it shows, whether it is plugged in,
/// its brightness and, when touch calibration is offered, Calibrate touch.
class DisplayCard extends StatelessWidget {
  /// Creates a [DisplayCard].
  const DisplayCard({
    required this.role,
    required this.title,
    required this.roleLabel,
    required this.panelLabel,
    required this.connected,
    this.onCalibrate,
    super.key,
  });

  /// The panel.
  final DisplayRole role;

  /// The card's heading.
  final String title;

  /// What the panel shows.
  final String roleLabel;

  /// The panel's size, drawn in the preview.
  final String panelLabel;

  /// Whether the panel is plugged in. Unknown counts as plugged in.
  final bool connected;

  /// Starts touch calibration for this panel; null leaves the button out.
  /// Unavailable while the panel is unplugged.
  final VoidCallback? onCalibrate;

  /// The card's height.
  static const double height = 416;

  static const double _inset = 32;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final calibrate = onCalibrate;
    return Container(
      width: DisplaysSettingsPage.cardWidth,
      height: height,
      padding: const EdgeInsets.all(_inset),
      decoration: BoxDecoration(
        color: surface.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: surface.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _DisplayPreview(label: panelLabel, connected: connected),
              const SizedBox(width: 32),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Semantics(header: true, child: LoopSectionLabel(title)),
                    const SizedBox(height: 12),
                    AppText(
                      roleLabel,
                      style: TextStyle(
                        color: surface.textSecondary,
                        fontSize: 24,
                        height: 1.2,
                      ),
                    ),
                    const SizedBox(height: 12),
                    AppText(
                      connected
                          ? l10n.displaysConnected
                          : l10n.displaysNotConnected,
                      key: Key('displays_status_${role.name}'),
                      style: TextStyle(
                        color: connected ? surface.success : surface.warning,
                        fontSize: 20,
                        height: 1.2,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 40),
          DisplayBrightnessSlider(
            role: role,
            width: DisplaysSettingsPage.cardWidth - 2 * _inset,
          ),
          if (calibrate != null) ...[
            const Spacer(),
            LoopOutlinedButton(
              key: Key('displays_calibrate_${role.name}'),
              width: 280,
              label: l10n.displaysCalibrateTouch,
              onTap: connected ? calibrate : null,
            ),
          ],
        ],
      ),
    );
  }
}

/// A small drawing of the panel: its outline with its size inside, dimmed
/// out while it is unplugged.
class _DisplayPreview extends StatelessWidget {
  const _DisplayPreview({required this.label, required this.connected});

  final String label;
  final bool connected;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return ExcludeSemantics(
      child: Opacity(
        opacity: connected ? 1 : surface.disabledOpacity,
        child: Container(
          width: 208,
          height: 128,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: surface.surface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: surface.borderStrong, width: 3),
          ),
          child: AppText(
            label,
            style: TextStyle(
              color: surface.textSecondary,
              fontSize: 28,
              fontFamily: SurfaceTheme.monoFont,
              height: 1,
            ),
          ),
        ),
      ),
    );
  }
}

/// One panel's brightness: the Loop settings slider, so touch, the encoder's
/// draft grammar (Enter, turn, Enter; Back cancels) and a screen reader's
/// increase and decrease all adjust it.
///
/// The whole travel covers the range a panel can be set to,
/// [kMinDisplayBrightness] to full, and each encoder detent is 5 points of
/// brightness. A double tap returns to [kDefaultDisplayBrightness].
class DisplayBrightnessSlider extends StatelessWidget {
  /// Creates a [DisplayBrightnessSlider] for [role]'s panel.
  const DisplayBrightnessSlider({
    required this.role,
    required this.width,
    super.key,
  });

  /// The panel.
  final DisplayRole role;

  /// The slider's width.
  final double width;

  static const double _range = 1 - kMinDisplayBrightness;

  /// One encoder detent or arrow press: 5 points of brightness.
  static const double step = 0.05 / _range;

  /// The slider position for [brightness].
  static double travelOf(double brightness) =>
      ((brightness - kMinDisplayBrightness) / _range).clamp(0.0, 1.0);

  /// The brightness at slider position [travel], to the whole percent.
  static double brightnessAt(double travel) =>
      ((kMinDisplayBrightness + travel.clamp(0.0, 1.0) * _range) * 100)
          .round() /
      100;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final brightness = context.select<DisplayBrightnessCubit, double>(
      (cubit) => cubit.state.levelOf(role),
    );
    String percent(double travel) =>
        l10n.trayBrightnessPercent((brightnessAt(travel) * 100).round());
    void apply(double travel) =>
        editDisplayBrightness(context, role, brightnessAt(travel));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: width,
          child: Row(
            children: [
              Expanded(
                child: AppText(
                  l10n.trayBrightnessLabel,
                  style: TextStyle(
                    color: surface.textPrimary,
                    fontSize: 24,
                    height: 1,
                  ),
                ),
              ),
              AppText(
                percent(travelOf(brightness)),
                key: Key('displays_brightness_readout_${role.name}'),
                style: TextStyle(
                  color: surface.textSecondary,
                  fontSize: 24,
                  fontFamily: SurfaceTheme.monoFont,
                  height: 1,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        LoopSlider(
          key: Key('displays_brightness_${role.name}'),
          width: width,
          value: travelOf(brightness),
          keyboardStep: step,
          semanticLabel: l10n.trayBrightnessLabel,
          semanticValueBuilder: percent,
          onChanged: apply,
          onEditCancel: apply,
          onDoubleTap: () =>
              editDisplayBrightness(context, role, kDefaultDisplayBrightness),
        ),
      ],
    );
  }
}

class _DimWhileIdle extends StatelessWidget {
  const _DimWhileIdle();

  void _choose(BuildContext context, int seconds) {
    final cubit = context.read<IdleDimCubit>();
    final l10n = context.l10n;
    unawaited(() async {
      try {
        await cubit.setSeconds(seconds);
        if (!context.mounted) return;
        dismissAppToast(idleDimSaveFailedToast);
      } on Object {
        if (!context.mounted) return;
        showAppSnackToast(
          id: idleDimSaveFailedToast,
          type: ToastificationType.error,
          icon: const Icon(Icons.error_outline),
          title: Text(l10n.powerOffSaveFailedTitle),
        );
      }
    }());
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final seconds = context.select<IdleDimCubit, int>(
      (cubit) => cubit.state.seconds,
    );
    return SizedBox(
      width: DisplaysSettingsPage.contentWidth,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LoopSectionLabel(l10n.displaysDimWhileIdle),
          const SizedBox(height: 20),
          Row(
            children: [
              LoopChoiceRow<int>(
                values: SettingsRepository.idleDimChoices,
                labelOf: (value) => value == 0
                    ? l10n.displaysDimNever
                    : l10n.displaysDimMinutes(value ~/ 60),
                keyOf: (value) => Key('displays_dim_$value'),
                selected: seconds,
                onSelected: (value) => _choose(context, value),
                width: 848,
                height: 80,
              ),
              const SizedBox(width: 48),
              Expanded(child: LoopNote(l10n.displaysDimNote)),
            ],
          ),
        ],
      ),
    );
  }
}

/// The screen settings the console had before the accepted Displays page,
/// kept in one row under Dim while idle (open question Q4's default).
class _DisplayOptions extends StatelessWidget {
  const _DisplayOptions();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final waveform = context.watch<WaveformWindowCubit>().state;
    final highContrast = context.watch<HighContrastCubit>().state;
    final refreshHz = context.watch<RefreshRateCubit>().state;
    return SizedBox(
      width: DisplaysSettingsPage.contentWidth,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              LoopSectionLabel(l10n.displaysOptions),
              if (waveform.openFailed) ...[
                const SizedBox(width: 48),
                Expanded(
                  child: LoopNote(
                    l10n.waveformWindowFailedBanner,
                    key: const Key('displays_waveform_failed'),
                    tone: LoopNoteTone.error,
                  ),
                ),
                const SizedBox(width: 24),
                LoopOutlinedButton(
                  key: const Key('displays_waveform_retry'),
                  width: 180,
                  height: 56,
                  label: l10n.consoleTryAgain,
                  onTap: context.read<WaveformWindowCubit>().retryOpen,
                ),
              ],
            ],
          ),
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            decoration: BoxDecoration(
              color: surface.card,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: surface.line),
            ),
            child: Column(
              children: [
                _OptionsRow(
                  first: LoopSwitch(
                    key: const Key('displays_waveform_switch'),
                    label: l10n.displaysTrackWindow,
                    semanticLabel: l10n.displaysTrackWindow,
                    value: waveform.enabled,
                    onChanged: (on) => unawaited(
                      context.read<WaveformWindowCubit>().setEnabled(
                        value: on,
                      ),
                    ),
                  ),
                  second: LoopSwitch(
                    key: const Key('displays_high_contrast_switch'),
                    label: l10n.highContrastTitle,
                    semanticLabel: l10n.highContrastTitle,
                    value: highContrast,
                    onChanged: (on) => unawaited(
                      context.read<HighContrastCubit>().setEnabled(value: on),
                    ),
                  ),
                ),
                Divider(height: 1, color: surface.line),
                _OptionsRow(
                  first: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(width: 12),
                      AppText(
                        l10n.systemRefreshRateTitle,
                        style: TextStyle(
                          color: surface.textPrimary,
                          fontSize: 26,
                          height: 1,
                        ),
                      ),
                      const SizedBox(width: 26),
                      LoopSelect<int>(
                        key: const Key('displays_refresh_rate'),
                        width: 160,
                        value: refreshHz,
                        items: [
                          for (final hz in RefreshRateCubit.options)
                            LoopSelectItem(
                              value: hz,
                              label: l10n.refreshRateHz(hz),
                              key: Key('displays_refresh_rate_$hz'),
                            ),
                        ],
                        onSelected: (hz) => unawaited(
                          context.read<RefreshRateCubit>().setHz(hz),
                        ),
                      ),
                    ],
                  ),
                  second: Padding(
                    padding: const EdgeInsets.only(left: 12),
                    child: LoopOutlinedButton(
                      key: const Key('displays_shortcuts'),
                      width: 360,
                      label: l10n.a11yShortcutsHelp,
                      onTap: () => unawaited(showShortcutsHelp(context)),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One row of the Display options panel: two controls, each in half the
/// width, left-aligned.
class _OptionsRow extends StatelessWidget {
  const _OptionsRow({required this.first, required this.second});

  final Widget first;
  final Widget second;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 72,
    child: Row(
      children: [
        Expanded(
          child: Align(alignment: Alignment.centerLeft, child: first),
        ),
        Expanded(
          child: Align(alignment: Alignment.centerLeft, child: second),
        ),
      ],
    ),
  );
}
