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
    this.width = 680,
    this.height = 140,
    this.buttonHeight = 96,
    this.valueFontSize = 30,
    super.key,
  });

  /// The gesture's name — Press or Hold.
  final String label;

  /// What the gesture currently does.
  final String value;

  /// Opens the picker; `null` when this gesture is fixed.
  final VoidCallback? onTap;

  /// The pen's field width. 680 on the built-in map, 506 on the narrower
  /// external-pedal editor.
  final double width;

  /// The pen's field height: the label band plus the value button.
  final double height;

  /// How tall the value button itself is.
  final double buttonHeight;

  /// The size of the value's own text.
  final double valueFontSize;

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
                    height: buttonHeight,
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
                              fontSize: valueFontSize,
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

/// The selected control's name beside whatever the current context edits.
///
/// The pen's `selected-editor`: the name on the left at a fixed place, the
/// fields filling the rest of the row. Shared by both editors so the switch
/// being edited is named in exactly one spot whichever context is open —
/// nothing under the map should move when the context changes.
class PedalSetupEditorFrame extends StatelessWidget {
  /// Creates a [PedalSetupEditorFrame].
  const PedalSetupEditorFrame({
    required this.title,
    required this.top,
    required this.child,
    super.key,
  });

  /// What the selected control is called.
  final String title;

  /// Where the editing area starts inside the box. Its own, because the two
  /// contexts edit blocks of different heights.
  final double top;

  /// The editing area.
  final Widget child;

  /// The pen's box.
  static const Size penSize = Size(1720, 212);

  /// The pen's inset before the fields.
  static const double fieldsLeft = 332;

  /// What is left for them.
  static const double fieldsWidth = 1720 - fieldsLeft;

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
            width: fieldsLeft - 32,
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
          Positioned(left: fieldsLeft, top: top, child: child),
        ],
      ),
    );
  }
}

/// The selected control's name and its two gesture fields.
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

  /// The pen's gap between the two fields.
  static const double _fieldGap = 28;

  @override
  Widget build(BuildContext context) => PedalSetupEditorFrame(
    title: title,
    top: 46,
    child: Row(
      children: [
        press,
        const SizedBox(width: _fieldGap),
        hold,
      ],
    ),
  );
}
