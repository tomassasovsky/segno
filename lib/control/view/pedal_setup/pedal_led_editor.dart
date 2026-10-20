import 'package:flutter/material.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/common/pedal_color_display.dart';
import 'package:segno/control/binding/pedal_led_labels.dart';
import 'package:segno/control/binding/pedal_led_map.dart';
import 'package:segno/control/view/pedal_setup/pedal_setup_editor.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/theme/theme.dart';

/// The LED colors editor for one pedal group in one mode: a colour field per
/// state the group can show, side by side, so a state is chosen against the
/// others it has to be told apart from.
class PedalLedEditor extends StatelessWidget {
  /// Creates a [PedalLedEditor].
  const PedalLedEditor({
    required this.title,
    required this.colors,
    required this.onEdit,
    super.key,
  });

  /// What the selected group is called.
  final String title;

  /// Each state the group can show, in order, with its current colour.
  final Map<PedalLedState, PedalColor> colors;

  /// Opens the colour editor on one state.
  final ValueChanged<PedalLedState> onEdit;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return PedalSetupEditorFrame(
      title: title,
      top: 46,
      child: Row(
        children: [
          for (final (index, MapEntry(key: state, value: color))
              in colors.entries.indexed) ...[
            if (index > 0) const SizedBox(width: PedalSetupEditor.fieldGap),
            PedalColorField(
              key: Key('pedal_led_state_${state.name}'),
              label: pedalLedStateLabel(l10n, state),
              color: color,
              onTap: () => onEdit(state),
            ),
          ],
        ],
      ),
    );
  }
}

/// One state's colour: its name over a tile showing the hue and its hex.
///
/// The same shape as a gesture field, so a colour sits beside Press and Hold
/// in Custom controls without a second visual language.
class PedalColorField extends StatelessWidget {
  /// Creates a [PedalColorField].
  const PedalColorField({
    required this.label,
    required this.color,
    required this.onTap,
    this.width = defaultWidth,
    super.key,
  });

  /// The state's name.
  final String label;

  /// The colour it lights in.
  final PedalColor color;

  /// Opens the colour editor.
  final VoidCallback onTap;

  /// How wide the field is.
  final double width;

  /// The LED editor's field: five fit beside the group's name.
  static const double defaultWidth = 240;

  /// The field beside Press and Hold in Custom controls.
  static const double compactWidth = 172;

  static const double _buttonHeight = 96;
  static const double _dot = 48;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return SizedBox(
      width: width,
      height: PedalSetupField.height,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppText(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: surface.textSecondary,
              fontSize: 26,
              height: 1,
            ),
          ),
          const Spacer(),
          Semantics(
            button: true,
            label: label,
            value: color.toString(),
            child: LoopFocusable(
              onActivate: onTap,
              radius: 10,
              child: Material(
                color: surface.cardHigh,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                  side: BorderSide(color: surface.borderStrong),
                ),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  canRequestFocus: false,
                  onTap: onTap,
                  child: SizedBox(
                    height: _buttonHeight,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          width: _dot,
                          height: _dot,
                          decoration: BoxDecoration(
                            color: color.display,
                            shape: BoxShape.circle,
                            border: Border.all(color: surface.borderSubtle),
                          ),
                        ),
                        if (width >= defaultWidth) ...[
                          const SizedBox(width: 16),
                          AppText(
                            color.toString(),
                            style: TextStyle(
                              color: surface.textPrimary,
                              fontFamily: SurfaceTheme.monoFont,
                              fontSize: 22,
                              height: 1,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
