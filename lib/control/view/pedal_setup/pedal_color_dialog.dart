import 'package:flutter/material.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/common/pedal_color_display.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_frame.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/theme/theme.dart';

/// Mixes one reusable LED colour: Hue, Saturation and Brightness over a live
/// preview of the hue itself.
///
/// Returns the chosen colour, or `null` when the editor is dismissed. The
/// caller decides what the colour becomes — a new palette entry, or a change
/// to one every footswitch using it follows — because only the caller knows
/// which.
///
/// HSV rather than three RGB channels: the thing a performer is choosing is a
/// hue, and "more red" is not how anyone asks for one. Brightness is a real
/// control rather than a nicety, because it is how hard the LED is driven.
Future<PedalColor?> showPedalColorDialog(
  BuildContext context, {
  required PedalColor initial,
  required bool editing,
}) async {
  final surface = context.surface;
  return showDialog<PedalColor>(
    context: context,
    barrierColor: surface.scrim.withValues(alpha: 0.86),
    builder: (context) => _PedalColorDialog(initial: initial, editing: editing),
  );
}

class _PedalColorDialog extends StatefulWidget {
  const _PedalColorDialog({required this.initial, required this.editing});

  /// The colour the editor opens on.
  final PedalColor initial;

  /// Whether this is a change to a colour the palette already has, which is
  /// the only thing that differs: what the title and the commit are called.
  final bool editing;

  @override
  State<_PedalColorDialog> createState() => _PedalColorDialogState();
}

class _PedalColorDialogState extends State<_PedalColorDialog> {
  late HSVColor _value = _toHsv(widget.initial);

  /// The pen's panel.
  static const double _panelWidth = 1060;
  static const double _pad = 40;

  /// The pen's preview column and the fields beside it.
  static const double _previewWidth = 220;
  static const double _fieldsWidth = 710;
  static const double _columnGap = 48;
  static const double _bodyHeight = 404;

  /// The pen's swatch: a 164 circle with the hex under it.
  static const double _swatchSize = 164;

  /// The pen's control block: a label row, then the rail.
  static const double _railHeight = 64;
  static const double _controlHeight = 100;
  static const double _controlGap = 28;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    return Center(
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: SizedBox.fromSize(
          size: kLoopPenSize,
          child: Center(
            child: Semantics(
              container: true,
              label: l10n.pedalColorDialogLabel,
              child: Material(
                key: const Key('pedal_color_dialog'),
                color: surface.card,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18),
                  side: BorderSide(color: surface.borderStrong),
                ),
                clipBehavior: Clip.antiAlias,
                child: SizedBox(
                  width: _panelWidth,
                  child: Padding(
                    padding: const EdgeInsets.all(_pad),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        AppText(
                          widget.editing
                              ? l10n.pedalColorEditTitle
                              : l10n.pedalColorAddTitle,
                          style: TextStyle(
                            color: surface.textPrimary,
                            fontSize: 32,
                            height: 1,
                          ),
                        ),
                        const SizedBox(height: 24),
                        SizedBox(height: _bodyHeight, child: _body(context)),
                        const SizedBox(height: 24),
                        _actions(context),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _body(BuildContext context) => Row(
    children: [
      SizedBox(width: _previewWidth, child: _preview(context)),
      const SizedBox(width: _columnGap),
      SizedBox(width: _fieldsWidth, child: _fields(context)),
    ],
  );

  /// The hue, the size it will never be on the hardware, and its hex.
  ///
  /// The number is shown because it is the only part of a colour a performer
  /// can write down or say out loud.
  Widget _preview(BuildContext context) {
    final surface = context.surface;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          key: const Key('pedal_color_preview'),
          width: _swatchSize,
          height: _swatchSize,
          decoration: BoxDecoration(
            color: _swatchColor,
            shape: BoxShape.circle,
            border: Border.all(color: surface.borderStrong),
          ),
        ),
        const SizedBox(height: 24),
        AppText(
          _hex,
          key: const Key('pedal_color_hex'),
          style: TextStyle(
            color: surface.textPrimary,
            fontFamily: SurfaceTheme.monoFont,
            fontSize: 24,
            height: 1,
          ),
        ),
      ],
    );
  }

  Widget _fields(BuildContext context) {
    final l10n = context.l10n;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _control(
          context,
          id: 'hue',
          label: l10n.pedalColorHue,
          readout: l10n.pedalColorDegrees(_value.hue.round()),
          value: _value.hue / 360,
          onChanged: (v) =>
              setState(() => _value = _value.withHue((v * 360).clamp(0, 360))),
        ),
        const SizedBox(height: _controlGap),
        _control(
          context,
          id: 'saturation',
          label: l10n.pedalColorSaturation,
          readout: l10n.pedalColorPercent((_value.saturation * 100).round()),
          value: _value.saturation,
          onChanged: (v) => setState(() => _value = _value.withSaturation(v)),
        ),
        const SizedBox(height: _controlGap),
        _control(
          context,
          id: 'brightness',
          label: l10n.pedalColorBrightness,
          readout: l10n.pedalColorPercent((_value.value * 100).round()),
          value: _value.value,
          onChanged: (v) => setState(() => _value = _value.withValue(v)),
        ),
      ],
    );
  }

  Widget _control(
    BuildContext context, {
    required String id,
    required String label,
    required String readout,
    required double value,
    required ValueChanged<double> onChanged,
  }) {
    final surface = context.surface;
    return SizedBox(
      height: _controlHeight,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 28,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                // The field's own name leads at reading weight and its value
                // trails quieter: three of these stack, and the column reads
                // as a list of controls rather than a list of numbers.
                AppText(
                  label,
                  style: TextStyle(
                    color: surface.textPrimary,
                    fontSize: 24,
                    height: 1,
                  ),
                ),
                AppText(
                  readout,
                  key: Key('pedal_color_readout_$id'),
                  style: TextStyle(
                    color: surface.textSecondary,
                    fontSize: 20,
                    height: 1,
                  ),
                ),
              ],
            ),
          ),
          const Spacer(),
          LoopSlider(
            key: Key('pedal_color_slider_$id'),
            value: value,
            width: _fieldsWidth,
            height: _railHeight,
            semanticLabel: label,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }

  Widget _actions(BuildContext context) {
    final l10n = context.l10n;
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        LoopOutlinedButton(
          key: const Key('pedal_color_cancel'),
          width: 125,
          label: l10n.pedalSetupCancel,
          onTap: () => Navigator.of(context).pop(),
        ),
        const SizedBox(width: 16),
        LoopOutlinedButton(
          key: const Key('pedal_color_done'),
          width: 200,
          tone: LoopButtonTone.accent,
          label: widget.editing
              ? l10n.pedalColorEditConfirm
              : l10n.pedalColorAddConfirm,
          onTap: () => Navigator.of(context).pop(_chosen),
        ),
      ],
    );
  }

  /// What the sliders currently name, as the wire would carry it.
  PedalColor get _chosen => pedalColorFromHsv(_value);

  Color get _swatchColor => _chosen.display;

  String get _hex => _chosen.toString();

  static HSVColor _toHsv(PedalColor color) => HSVColor.fromColor(color.display);
}

/// The wire colour an [HSVColor] names, rounded to the three bytes the LED can
/// actually be driven at.
PedalColor pedalColorFromHsv(HSVColor value) {
  final color = value.toColor();
  return PedalColor(
    (color.r * 0xFF).round(),
    (color.g * 0xFF).round(),
    (color.b * 0xFF).round(),
  );
}
