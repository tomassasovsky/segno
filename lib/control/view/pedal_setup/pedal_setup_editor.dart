import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:segno/theme/theme.dart';

/// One gesture's assignment: its name over the action it carries.
///
/// The pen's `editor-field`: a 680-wide column, the label on top, and a 96
/// tall value button under it. A field the context cannot edit is drawn
/// dimmed with no chevron and refuses the tap — the accepted design is
/// explicit that a fixed control shows what it does rather than hiding it.
class PedalSetupField extends StatelessWidget {
  /// Creates a [PedalSetupField].
  const PedalSetupField({
    required this.label,
    required this.value,
    required this.onTap,
    super.key,
  });

  /// The gesture's name — Press or Hold.
  final String label;

  /// What the gesture currently does.
  final String value;

  /// Opens the picker; `null` when this gesture is fixed.
  final VoidCallback? onTap;

  /// The pen's field.
  static const double width = 680;

  /// The pen's field height: the label band plus the value button.
  static const double height = 140;

  static const double _buttonHeight = 96;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return SizedBox(
      width: width,
      height: height,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppText(
            label,
            style: TextStyle(
              color: surface.textSecondary,
              fontSize: 26,
              height: 1,
            ),
          ),
          const Spacer(),
          Semantics(
            button: onTap != null,
            enabled: onTap != null,
            label: label,
            value: value,
            child: Opacity(
              opacity: onTap == null ? surface.disabledOpacity : 1,
              child: Material(
                color: surface.cardHigh,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                  side: BorderSide(color: surface.borderStrong),
                ),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: onTap,
                  child: SizedBox(
                    height: _buttonHeight,
                    child: Row(
                      children: [
                        const SizedBox(width: 25),
                        Expanded(
                          child: AppText(
                            value,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: surface.textPrimary,
                              fontSize: 30,
                              height: 1,
                            ),
                          ),
                        ),
                        if (onTap != null) ...[
                          Icon(
                            LucideIcons.chevronDown,
                            size: 28,
                            color: surface.textSecondary,
                          ),
                          const SizedBox(width: 25),
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

/// The selected control's name and its two gesture fields.
///
/// The pen's `selected-editor`: the name on the left, the fields filling the
/// rest of the row.
class PedalSetupEditor extends StatelessWidget {
  /// Creates a [PedalSetupEditor].
  const PedalSetupEditor({
    required this.title,
    required this.press,
    required this.hold,
    super.key,
  });

  /// What the selected control is called.
  final String title;

  /// The Press field.
  final Widget press;

  /// The Hold field.
  final Widget hold;

  /// The pen's box.
  static const Size penSize = Size(1720, 212);

  /// The pen's inset before the fields.
  static const double _fieldsLeft = 332;

  /// The pen's gap between the two fields.
  static const double _fieldGap = 28;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return SizedBox.fromSize(
      size: penSize,
      child: Stack(
        children: [
          Positioned(
            left: 0,
            top: 96,
            width: _fieldsLeft - 32,
            child: AppText(
              title,
              key: const Key('pedal_setup_selected'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: surface.textPrimary,
                fontSize: 34,
                height: 1,
              ),
            ),
          ),
          Positioned(
            left: _fieldsLeft,
            top: 46,
            child: Row(
              children: [
                press,
                const SizedBox(width: _fieldGap),
                hold,
              ],
            ),
          ),
        ],
      ),
    );
  }
}
