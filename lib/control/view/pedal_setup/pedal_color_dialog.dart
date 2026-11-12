import 'package:material_ui/material_ui.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/common/pedal_color_display.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_frame.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/theme/theme.dart';

/// Mixes one LED colour: Hue, Saturation and Brightness over a live preview
/// of the hue itself.
///
/// Returns the chosen colour, or `null` when the editor is dismissed. The
/// caller decides which state of which pedal the colour lands on.
///
/// HSV rather than three RGB channels: the thing a performer is choosing is a
/// hue, and "more red" is not how anyone asks for one. Brightness is a real
/// control; the hardware renderer applies its own brightness limits.
Future<PedalColor?> showPedalColorDialog(
  BuildContext context, {
  required PedalColor initial,
}) async {
  final surface = context.surface;
  return await showDialog<PedalColor>(
    context: context,
    barrierColor: surface.scrim.withValues(alpha: 0.86),
    builder: (context) => _PedalColorDialog(initial: initial),
  );
}

class _PedalColorDialog extends StatefulWidget {
  const new({required this.initial});

  /// The colour the editor opens on.
  final PedalColor initial;

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
                          l10n.pedalColorEditTitle,
                          style: TextStyle(
                            color: surface.textPrimary,
                            fontSize: 32,
                            height: 1,
                          ),
                        ),
                        const SizedBox(height: 24),
                        SizedBox(
                          height: _bodyHeight,
                          child: Row(
                            children: [
                              SizedBox(
                                width: _previewWidth,
                                child: _ColorPreview(color: _chosen),
                              ),
                              const SizedBox(width: _columnGap),
                              SizedBox(
                                width: _fieldsWidth,
                                child: _ColorFields(
                                  value: _value,
                                  onChanged: (value) =>
                                      setState(() => _value = value),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 24),
                        _ColorActions(chosen: _chosen),
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

  /// What the sliders currently name, as the wire would carry it.
  PedalColor get _chosen => pedalColorFromHsv(_value);

  static HSVColor _toHsv(PedalColor color) => HSVColor.fromColor(color.display);
}

/// The hue, the size it will never be on the hardware, and its hex.
///
/// The number is shown because it is the only part of a colour a performer
/// can write down or say out loud.
class _ColorPreview extends StatelessWidget {
  const new({required this.color});

  /// The colour the sliders currently name.
  final PedalColor color;

  /// The pen's swatch: a 164 circle with the hex under it.
  static const double _swatchSize = 164;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          key: const Key('pedal_color_preview'),
          width: _swatchSize,
          height: _swatchSize,
          decoration: BoxDecoration(
            color: color.display,
            shape: BoxShape.circle,
            border: Border.all(color: surface.borderStrong),
          ),
        ),
        const SizedBox(height: 24),
        AppText(
          color.toString(),
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
}

/// Hue, Saturation and Brightness, one control each.
class _ColorFields extends StatelessWidget {
  const new({required this.value, required this.onChanged});

  /// The colour being mixed.
  final HSVColor value;

  /// Takes the colour with one of its three parts moved.
  final ValueChanged<HSVColor> onChanged;

  /// The pen's gap between two controls.
  static const double _controlGap = 28;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _ColorControl(
          id: 'hue',
          label: l10n.pedalColorHue,
          readout: l10n.pedalColorDegrees(value.hue.round()),
          value: value.hue / 360,
          onChanged: (v) => onChanged(value.withHue((v * 360).clamp(0, 360))),
        ),
        const SizedBox(height: _controlGap),
        _ColorControl(
          id: 'saturation',
          label: l10n.pedalColorSaturation,
          readout: l10n.pedalColorPercent((value.saturation * 100).round()),
          value: value.saturation,
          onChanged: (v) => onChanged(value.withSaturation(v)),
        ),
        const SizedBox(height: _controlGap),
        _ColorControl(
          id: 'brightness',
          label: l10n.pedalColorBrightness,
          readout: l10n.pedalColorPercent((value.value * 100).round()),
          value: value.value,
          onChanged: (v) => onChanged(value.withValue(v)),
        ),
      ],
    );
  }
}

/// One of the three: its name and readout over its rail.
class _ColorControl extends StatelessWidget {
  const new({
    required this.id,
    required this.label,
    required this.readout,
    required this.value,
    required this.onChanged,
  });

  /// The control's key fragment.
  final String id;

  /// The control's name.
  final String label;

  /// Its value, as read out.
  final String readout;

  /// Its value along the rail, 0 to 1.
  final double value;

  /// Moves it.
  final ValueChanged<double> onChanged;

  /// The pen's control block: a label row, then the rail.
  static const double _controlHeight = 100;

  @override
  Widget build(BuildContext context) {
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
            width: _PedalColorDialogState._fieldsWidth,
            semanticLabel: label,
            onChanged: onChanged,
            onEditCancel: onChanged,
          ),
        ],
      ),
    );
  }
}

/// Cancel and Done.
class _ColorActions extends StatelessWidget {
  const new({required this.chosen});

  /// The colour Done returns.
  final PedalColor chosen;

  @override
  Widget build(BuildContext context) {
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
          label: l10n.pedalColorEditConfirm,
          onTap: () => Navigator.of(context).pop(chosen),
        ),
      ],
    );
  }
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
