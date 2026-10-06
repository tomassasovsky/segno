import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/common/pen_icons.dart';
import 'package:segno/theme/theme.dart';

/// Bytes as decimal gigabytes, the figure printed on a drive's own label and
/// quoted by every other appliance; a "12.4 GB free" that disagrees with the
/// sticker is a bug report. Handed to l10n as a number, so the separator is
/// the locale's.
double decimalGigabytes(int bytes) => bytes / 1000000000;

/// One volume on the Storage page (pen 31 `storage-volume`): the drive glyph
/// with the volume's name and state, what it holds in the middle, and its
/// actions at the trailing edge.
///
/// The pen draws the page full-screen at 1920; this card sits in the
/// settings tray, so its type and spacing are the tray's own scale with the
/// pen's proportions (title column, capacity, actions) kept.
class StorageVolumeCard extends StatelessWidget {
  /// Creates a [StorageVolumeCard].
  const StorageVolumeCard({
    required this.title,
    required this.subtitle,
    required this.body,
    this.actions = const [],
    super.key,
  });

  /// `Internal`, `USB drive`.
  final String title;

  /// What it is or what is happening to it: `Sessions and audio`, the
  /// drive's label, `Ejecting…`, `Safe to remove`, `Not connected`.
  final String subtitle;

  /// The middle: a [StorageCapacity] or a [StorageCardMessage].
  final Widget body;

  /// The buttons at the trailing edge, in order.
  final List<Widget> actions;

  /// The title column's width: the pen's 340 of 1744, at the tray's scale.
  static const double titleWidth = 250;

  /// The drive glyph's box.
  static const double iconSize = 34;

  /// The actions slot: the pen's 352 of 1744, at the tray's scale.
  static const double actionsWidth = 180;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return ConsoleCard(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: kConsoleRowInset + 4,
            vertical: 30,
          ),
          child: Row(
            children: [
              SizedBox(
                width: titleWidth,
                child: Row(
                  children: [
                    PenIconView(
                      icon: PenIcon.drive,
                      size: iconSize,
                      color: surface.textSecondary,
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          AppText(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: surface.textPrimary,
                              fontSize: 19,
                              height: 1.2,
                            ),
                          ),
                          const SizedBox(height: 6),
                          AppText(
                            subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: surface.textSecondary,
                              fontSize: 14,
                              height: 1.2,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 32),
              Expanded(child: body),
              const SizedBox(width: 64),
              // A slot of one width, as the pen's `storage-volume-actions`:
              // every card's bar ends at the same x whatever buttons it
              // carries. A minimum, not a fixed width, so a longer label (a
              // locale, a larger font) widens the slot instead of overflowing
              // it.
              ConstrainedBox(
                constraints: const BoxConstraints(minWidth: actionsWidth),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    for (final (index, action) in actions.indexed) ...[
                      if (index > 0) const SizedBox(width: 10),
                      action,
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// A volume's capacity: `24.2 GB free`, `of 32 GB`, and a bar of what is
/// used. [low] draws the bar in the warning tone (pen `Low internal space`).
class StorageCapacity extends StatelessWidget {
  /// Creates a [StorageCapacity].
  const StorageCapacity({
    required this.free,
    required this.total,
    required this.usedFraction,
    this.low = false,
    super.key,
  });

  /// The free figure, already worded.
  final String free;

  /// The size, already worded.
  final String total;

  /// How much of the volume is used, 0..1.
  final double usedFraction;

  /// Whether the volume is below its reserve.
  final bool low;

  /// The bar's thickness.
  static const double barHeight = 8;

  /// The bar's own key: a bar has no text to assert on.
  static const Key barKey = Key('storage_capacity_bar');

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Expanded(
              child: AppText(
                free,
                maxLines: 1,
                style: TextStyle(
                  color: surface.textPrimary,
                  fontSize: 18,
                  height: 1.2,
                ),
              ),
            ),
            AppText(
              total,
              style: TextStyle(
                color: surface.textSecondary,
                fontSize: 14,
                height: 1.2,
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        ClipRRect(
          borderRadius: BorderRadius.circular(barHeight / 2),
          child: LinearProgressIndicator(
            key: barKey,
            value: usedFraction.clamp(0.0, 1.0),
            minHeight: barHeight,
            backgroundColor: surface.control,
            valueColor: AlwaysStoppedAnimation(
              low ? surface.warning : surface.accent,
            ),
          ),
        ),
      ],
    );
  }
}

/// What a card says in place of a capacity: a mark and one sentence (pen
/// `Safe to remove` with a check, `No USB drive` with a dash).
class StorageCardMessage extends StatelessWidget {
  /// Creates a [StorageCardMessage].
  const StorageCardMessage({
    required this.icon,
    required this.message,
    super.key,
  });

  /// The mark before the sentence.
  final IconData icon;

  /// The sentence.
  final String message;

  /// A check: the drive is done with.
  static const IconData done = LucideIcons.check;

  /// A dash: nothing is there.
  static const IconData none = LucideIcons.minus;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Row(
      children: [
        Icon(icon, size: 22, color: surface.textSecondary),
        const SizedBox(width: 14),
        Expanded(
          child: AppText(
            message,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: surface.textSecondary,
              fontSize: 15,
              height: 1.2,
            ),
          ),
        ),
      ],
    );
  }
}

/// A card's button: [ConsoleDialogButton], faded when it cannot be pressed
/// (Eject while something writes to the drive).
class StorageCardButton extends StatelessWidget {
  /// Creates a [StorageCardButton].
  const StorageCardButton({
    required this.label,
    required this.onPressed,
    this.tone = ConsoleDialogTone.neutral,
    super.key,
  });

  /// Visible caption, and the announced label.
  final String label;

  /// Tap action; null disables the button.
  final VoidCallback? onPressed;

  /// Which kind of action it is.
  final ConsoleDialogTone tone;

  @override
  Widget build(BuildContext context) {
    final action = onPressed;
    final button = ConsoleDialogButton(
      label: label,
      onPressed: action ?? () {},
      tone: tone,
    );
    if (action != null) return button;
    // Shown, so the action is not a mystery, but neither tappable nor
    // announced as something to press.
    return Semantics(
      enabled: false,
      child: IgnorePointer(
        child: ExcludeFocus(
          child: Opacity(
            opacity: context.surface.disabledOpacity,
            child: ExcludeSemantics(child: button),
          ),
        ),
      ),
    );
  }
}
