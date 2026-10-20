import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/theme/theme.dart';

/// A titled panel of read facts on a Settings page (About, Controller
/// firmware): a card-toned box, the heading, then its rows with a hairline
/// between each.
///
/// The rows are what this build actually read: a caller leaves out the row
/// whose fact is missing rather than passing a placeholder, so the hairlines
/// go between the survivors.
class SettingsFactPanel extends StatelessWidget {
  /// Creates a [SettingsFactPanel] headed [title] around [rows].
  const SettingsFactPanel({
    required this.title,
    required this.rows,
    required this.width,
    super.key,
  });

  /// The panel's heading.
  final String title;

  /// The rows, top to bottom.
  final List<Widget> rows;

  /// The panel's width in pen pixels.
  final double width;

  /// The inset of the heading and rows from the panel's edge.
  static const double inset = 32;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Container(
      width: width,
      padding: const EdgeInsets.fromLTRB(inset, inset, inset, 12),
      decoration: BoxDecoration(
        color: surface.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: surface.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Semantics(header: true, child: LoopSectionLabel(title)),
          const SizedBox(height: 16),
          for (final (index, row) in rows.indexed) ...[
            if (index > 0) Divider(height: 1, color: surface.line),
            row,
          ],
        ],
      ),
    );
  }
}

/// One fact on a [SettingsFactPanel]: its name at the left, the value at the
/// right with an optional caption under it, and, when the row leads
/// somewhere, a chevron and the whole row as one focus stop.
class SettingsFactRow extends StatelessWidget {
  /// Creates a [SettingsFactRow].
  const SettingsFactRow({
    required this.label,
    this.value,
    this.caption,
    this.trailing,
    this.onTap,
    super.key,
  });

  /// What the fact is.
  final String label;

  /// The fact, or null for a row that only leads somewhere.
  final String? value;

  /// A line under [value] saying where it came from or what it means.
  final String? caption;

  /// A control at the row's right edge (the Name row's Rename).
  final Widget? trailing;

  /// Opens what the row leads to; null for a readout.
  final VoidCallback? onTap;

  /// The row's minimum height.
  static const double minHeight = 84;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final value = this.value;
    final caption = this.caption;
    final onTap = this.onTap;
    final row = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: minHeight),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Row(
          children: [
            Expanded(
              child: AppText(
                label,
                style: TextStyle(
                  color: surface.textSecondary,
                  fontSize: 24,
                  height: 1.2,
                ),
              ),
            ),
            const SizedBox(width: 24),
            Flexible(
              flex: 2,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (value != null)
                    AppText(
                      value,
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        color: surface.textPrimary,
                        fontSize: 24,
                        height: 1.2,
                      ),
                    ),
                  if (caption != null) ...[
                    const SizedBox(height: 6),
                    AppText(
                      caption,
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        color: surface.textTertiary,
                        fontSize: 20,
                        height: 1.2,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (trailing case final trailing?) ...[
              const SizedBox(width: 24),
              trailing,
            ],
            if (onTap != null) ...[
              const SizedBox(width: 16),
              Icon(
                LucideIcons.chevronRight,
                size: 28,
                color: surface.textPrimary,
              ),
            ],
          ],
        ),
      ),
    );
    if (onTap == null) {
      // A readout is read as one line; a row with its own control keeps that
      // control a separate button rather than folding it into the fact.
      return trailing == null ? MergeSemantics(child: row) : row;
    }
    return Semantics(
      button: true,
      label: label,
      value: [?value, ?caption].join(', '),
      excludeSemantics: true,
      child: LoopFocusable(
        onActivate: onTap,
        child: InkWell(
          canRequestFocus: false,
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: row,
        ),
      ),
    );
  }
}
