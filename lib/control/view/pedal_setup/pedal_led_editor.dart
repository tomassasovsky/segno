import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/common/pedal_color_display.dart';
import 'package:segno/control/binding/pedal_palette.dart';
import 'package:segno/control/binding/pedal_palette_labels.dart';
import 'package:segno/control/view/pedal_setup/pedal_setup_editor.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/theme/theme.dart';

/// The LED colors editor: which colour the selected footswitch's indicator
/// uses, over the whole palette.
///
/// Every colour is on screen at once rather than behind a picker, because
/// choosing one is comparing it against the others — a list of names would
/// make the performer open and close a dialog nine times to see nine hues.
class PedalLedEditor extends StatelessWidget {
  /// Creates a [PedalLedEditor].
  const PedalLedEditor({
    required this.title,
    required this.palette,
    required this.button,
    required this.onChoose,
    required this.onAdd,
    required this.onEdit,
    super.key,
  });

  /// What the selected footswitch is called.
  final String title;

  /// The palette being edited.
  final PedalPalette palette;

  /// The footswitch being edited.
  final PedalButton button;

  /// Puts an existing palette entry on the footswitch.
  final ValueChanged<PedalPaletteEntry> onChoose;

  /// Mixes a new colour.
  final VoidCallback onAdd;

  /// Changes the custom colour the footswitch currently uses, which moves
  /// every other footswitch using it too.
  final ValueChanged<CustomPaletteEntry> onEdit;

  /// The pen's swatch row.
  static const double _tileTop = 4;
  static const double _tile = 88;
  static const double _tilePitch = 106;
  static const double _dot = 48;

  /// The pen's heading, and the taller one that holds Edit color.
  static const double _headingHeight = 28;
  static const double _editHeadingHeight = 56;
  static const double _headingGap = 16;

  /// Where the heading's text sits, whichever height the row is.
  static const double _headingTextTop = 41.5;

  @override
  Widget build(BuildContext context) {
    final selected = palette.entryFor(button);
    final editable = selected is CustomPaletteEntry ? selected : null;
    final heading = editable == null ? _headingHeight : _editHeadingHeight;
    return PedalSetupEditorFrame(
      title: title,
      // The heading grows downward around its text when Edit color appears, so
      // the label and the name beside it do not jump between a built-in colour
      // and a custom one.
      top: _headingTextTop - (heading - _headingHeight) / 2,
      child: SizedBox(
        width: PedalSetupEditorFrame.fieldsWidth,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: heading,
              child: _heading(context, selected, editable),
            ),
            const SizedBox(height: _headingGap + _tileTop),
            SizedBox(height: _tile, child: _swatches(context, selected)),
          ],
        ),
      ),
    );
  }

  Widget _heading(
    BuildContext context,
    PedalPaletteEntry selected,
    CustomPaletteEntry? editable,
  ) {
    final l10n = context.l10n;
    final surface = context.surface;
    final label = TextStyle(
      color: surface.textSecondary,
      fontSize: 24,
      height: 1,
    );
    return Row(
      children: [
        AppText(l10n.pedalSetupLedColor, style: label),
        const SizedBox(width: 24),
        AppText(
          pedalPaletteLabel(l10n, selected),
          key: const Key('pedal_setup_led_name'),
          style: label,
        ),
        const Spacer(),
        if (editable != null)
          LoopOutlinedButton(
            key: const Key('pedal_setup_led_edit'),
            width: 151,
            label: l10n.pedalSetupLedEdit,
            onTap: () => onEdit(editable),
          ),
      ],
    );
  }

  Widget _swatches(BuildContext context, PedalPaletteEntry selected) {
    final l10n = context.l10n;
    final entries = palette.entries;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      // A palette can grow past the pen's row. It scrolls rather than
      // overflowing; with the shipped nine swatches there is nothing to
      // scroll.
      child: Row(
        children: [
          for (final entry in entries) ...[
            _PedalSwatch(
              key: Key('pedal_setup_swatch_${entry.key}'),
              label: pedalPaletteLabel(l10n, entry),
              color: palette.colorOf(entry),
              selected: entry == selected,
              onTap: () => onChoose(entry),
            ),
            const SizedBox(width: _tilePitch - _tile),
          ],
          _PedalSwatch(
            key: const Key('pedal_setup_swatch_add'),
            label: l10n.pedalSetupLedAdd,
            color: null,
            selected: false,
            onTap: onAdd,
          ),
        ],
      ),
    );
  }
}

/// One palette swatch: the hue itself on a tile that says whether it is the
/// one in use. With no [color] this is the add-a-colour tile.
class _PedalSwatch extends StatelessWidget {
  const _PedalSwatch({
    required this.label,
    required this.color,
    required this.selected,
    required this.onTap,
    super.key,
  });

  final String label;
  final PedalColor? color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: Material(
        color: selected ? surface.accentSurface : surface.cardHigh,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(
            color: selected ? surface.accent : surface.borderSubtle,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            width: PedalLedEditor._tile,
            height: PedalLedEditor._tile,
            child: Center(
              child: color == null
                  ? Icon(
                      LucideIcons.plus,
                      size: 40,
                      color: surface.textPrimary,
                    )
                  : Container(
                      width: PedalLedEditor._dot,
                      height: PedalLedEditor._dot,
                      decoration: BoxDecoration(
                        color: color!.display,
                        shape: BoxShape.circle,
                        border: Border.all(color: surface.borderSubtle),
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
