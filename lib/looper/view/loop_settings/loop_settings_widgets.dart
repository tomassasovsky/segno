import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/theme/theme.dart';

/// The pen's choice button: a rounded box that fills when selected.
///
/// Sizes are the pen's, passed by the page that places the button, since the
/// same box is 232 wide on the timing row, 330 on the click rows and 504 on
/// the recording rows.
class LoopChoiceButton extends StatelessWidget {
  /// Creates a [LoopChoiceButton].
  const LoopChoiceButton({
    required this.label,
    required this.selected,
    required this.onTap,
    required this.width,
    this.height = 96,
    this.icon,
    this.enabled = true,
    this.fontSize = 24,
    super.key,
  });

  /// The choice's name.
  final String label;

  /// Whether this is the current choice.
  final bool selected;

  /// Makes this the choice; ignored while not [enabled].
  final VoidCallback onTap;

  /// The pen's width for this button.
  final double width;

  /// The pen's height for this button.
  final double height;

  /// An optional glyph before the label (the Loop/Once and tempo choices).
  final IconData? icon;

  /// Whether the choice can be taken right now (a lock dims it).
  final bool enabled;

  /// The label size (24 on most rows, 28 on the iconed choices).
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final textColor = selected ? surface.textPrimary : surface.textSecondary;
    return Semantics(
      button: true,
      selected: selected,
      enabled: enabled,
      label: label,
      child: Opacity(
        opacity: enabled ? 1 : surface.disabledOpacity,
        child: Material(
          color: selected ? surface.accentSurface : surface.card,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: BorderSide(
              color: selected ? surface.accent : surface.borderSubtle,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: enabled ? onTap : null,
            child: SizedBox(
              width: width,
              height: height,
              // A label longer than its box scales down rather than
              // overflowing: the pen's boxes fit the English labels, and a
              // translation may not.
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (icon != null) ...[
                        Icon(icon, size: 36, color: textColor),
                        const SizedBox(width: 24),
                      ],
                      AppText(
                        label,
                        style: TextStyle(
                          color: textColor,
                          fontSize: fontSize,
                          height: 1,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A row of equal [LoopChoiceButton]s sharing [width] with [gap] between.
class LoopChoiceRow<T> extends StatelessWidget {
  /// Creates a [LoopChoiceRow].
  const LoopChoiceRow({
    required this.values,
    required this.labelOf,
    required this.keyOf,
    required this.selected,
    required this.onSelected,
    required this.width,
    this.height = 96,
    this.gap = 24,
    this.iconOf,
    this.enabled = true,
    this.fontSize = 24,
    super.key,
  });

  /// The choices, in order.
  final List<T> values;

  /// Each choice's name.
  final String Function(T value) labelOf;

  /// Each button's widget key.
  final Key Function(T value) keyOf;

  /// The current choice.
  final T selected;

  /// Called with the tapped choice.
  final ValueChanged<T> onSelected;

  /// The pen's width of the whole row.
  final double width;

  /// The pen's button height.
  final double height;

  /// The pen's gap between buttons.
  final double gap;

  /// An optional glyph per choice.
  final IconData? Function(T value)? iconOf;

  /// Whether the choices can be taken right now.
  final bool enabled;

  /// The label size.
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final buttonWidth = (width - gap * (values.length - 1)) / values.length;
    return SizedBox(
      width: width,
      height: height,
      child: Row(
        children: [
          for (var i = 0; i < values.length; i++) ...[
            if (i > 0) SizedBox(width: gap),
            LoopChoiceButton(
              key: keyOf(values[i]),
              label: labelOf(values[i]),
              selected: values[i] == selected,
              onTap: () => onSelected(values[i]),
              width: buttonWidth,
              height: height,
              icon: iconOf?.call(values[i]),
              enabled: enabled,
              fontSize: fontSize,
            ),
          ],
        ],
      ),
    );
  }
}

/// A section heading (the pen's h2).
class LoopSectionLabel extends StatelessWidget {
  /// Creates a [LoopSectionLabel].
  const LoopSectionLabel(this.text, {this.fontSize = 28, super.key});

  /// The heading.
  final String text;

  /// 28 on most rows, 32 on the playback and audio fields.
  final double fontSize;

  @override
  Widget build(BuildContext context) => AppText(
    text,
    style: TextStyle(
      color: context.surface.textPrimary,
      fontSize: fontSize,
      height: 1,
    ),
  );
}

/// Where a scoped field's value comes from.
enum LoopFieldOrigin {
  /// The field follows the default.
  isDefault,

  /// The field carries its own value.
  custom,

  /// The field is the shared default in Multi and cannot be overridden.
  sharedInMulti,
}

/// A scoped field's heading with its origin tag under or beside it.
class LoopFieldLabel extends StatelessWidget {
  /// Creates a [LoopFieldLabel].
  const LoopFieldLabel({
    required this.title,
    this.origin,
    this.fontSize = 28,
    this.originBeside = false,
    super.key,
  });

  /// The field's name.
  final String title;

  /// The origin tag; `null` on the defaults scope, where every field is the
  /// default.
  final LoopFieldOrigin? origin;

  /// The heading size.
  final double fontSize;

  /// Draws the tag beside the heading (the record timing heading) rather
  /// than under it.
  final bool originBeside;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final l10n = context.l10n;
    final tag = switch (origin) {
      null => null,
      LoopFieldOrigin.isDefault => l10n.loopOriginDefault,
      LoopFieldOrigin.custom => l10n.loopOriginCustom,
      LoopFieldOrigin.sharedInMulti => l10n.loopSharedInMulti,
    };
    final tagText = tag == null
        ? null
        : AppText(
            tag,
            key: const Key('loop_field_origin'),
            style: TextStyle(
              color: origin == LoopFieldOrigin.custom
                  ? surface.textPrimary
                  : surface.textTertiary,
              fontSize: 20,
              height: 1,
            ),
          );
    final heading = LoopSectionLabel(title, fontSize: fontSize);
    if (tagText == null) return heading;
    if (originBeside) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          heading,
          const SizedBox(width: 24),
          Padding(padding: const EdgeInsets.only(bottom: 2), child: tagText),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        heading,
        const SizedBox(height: 10),
        tagText,
      ],
    );
  }
}

/// The pen's "Use default" button: 172 x 64, outlined.
class LoopUseDefaultButton extends StatelessWidget {
  /// Creates a [LoopUseDefaultButton].
  const LoopUseDefaultButton({required this.onTap, super.key});

  /// Removes the field's override.
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => LoopOutlinedButton(
    width: 172,
    label: context.l10n.loopUseDefault,
    onTap: onTap,
  );
}

/// The pen's outlined action button: 64 high, radius 7.
class LoopOutlinedButton extends StatelessWidget {
  /// Creates a [LoopOutlinedButton].
  const LoopOutlinedButton({
    required this.width,
    required this.onTap,
    this.label,
    this.icon,
    this.semanticLabel,
    this.height = 64,
    this.fontSize = 24,
    super.key,
  });

  /// The pen's width.
  final double width;

  /// The action.
  final VoidCallback? onTap;

  /// The button text, when it has one.
  final String? label;

  /// The button glyph, when it has one.
  final IconData? icon;

  /// The accessible name when the button shows only a glyph.
  final String? semanticLabel;

  /// The pen's height.
  final double height;

  /// The label size.
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Semantics(
      button: true,
      label: semanticLabel ?? label,
      child: Material(
        color: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(7),
          side: BorderSide(color: surface.borderStrong),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            width: width,
            height: height,
            child: Center(
              child: icon != null
                  ? Icon(icon, size: 28, color: surface.textPrimary)
                  : Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: AppText(
                          label ?? '',
                          style: TextStyle(
                            color: surface.textPrimary,
                            fontSize: fontSize,
                            height: 1,
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
}

/// The one-sentence note under a field (the pen's length-note).
class LoopNote extends StatelessWidget {
  /// Creates a [LoopNote].
  const LoopNote(this.text, {super.key});

  /// The sentence.
  final String text;

  @override
  Widget build(BuildContext context) => AppText(
    text,
    style: TextStyle(
      color: context.surface.textSecondary,
      fontSize: 24,
      height: 1.2,
    ),
  );
}

/// The lock banner a capture puts over a page whose settings it freezes:
/// 68 high, a warning edge on the left, one sentence.
class LoopLockBanner extends StatelessWidget {
  /// Creates a [LoopLockBanner].
  const LoopLockBanner({required this.text, required this.width, super.key});

  /// The reason.
  final String text;

  /// The pen's width.
  final double width;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Container(
      key: const Key('loop_lock_banner'),
      width: width,
      height: 68,
      padding: const EdgeInsets.only(left: 27),
      decoration: BoxDecoration(
        color: surface.warning.withValues(alpha: 0.14),
        border: Border(left: BorderSide(color: surface.warning, width: 3)),
      ),
      alignment: Alignment.centerLeft,
      child: AppText(
        text,
        style: TextStyle(
          color: surface.textPrimary,
          fontSize: 24,
          height: 1,
        ),
      ),
    );
  }
}

/// The scoped editors' Tracks / Defaults / 1-8 selector, 1720 wide: the
/// "Tracks" heading, Defaults, one button per track, and the selected track's
/// name at the right.
class LoopScopeSelector extends StatelessWidget {
  /// Creates a [LoopScopeSelector].
  const LoopScopeSelector({
    required this.trackNames,
    required this.selected,
    required this.onSelected,
    super.key,
  });

  /// The tracks' names, in channel order.
  final List<String> trackNames;

  /// The selected channel, or `null` for the defaults.
  final int? selected;

  /// Called with the tapped channel, or `null` for the defaults.
  final ValueChanged<int?> onSelected;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final l10n = context.l10n;
    final name = selected == null || selected! >= trackNames.length
        ? null
        : trackNames[selected!];
    return SizedBox(
      width: 1720,
      height: 64,
      child: Stack(
        children: [
          Positioned(
            left: 0,
            top: 16,
            child: LoopSectionLabel(l10n.loopScopeTracks),
          ),
          Positioned(
            left: 328,
            top: 0,
            child: LoopChoiceButton(
              key: const Key('loop_scope_defaults'),
              label: l10n.loopScopeDefaults,
              selected: selected == null,
              onTap: () => onSelected(null),
              width: 144,
              height: 64,
            ),
          ),
          for (var i = 0; i < trackNames.length; i++)
            Positioned(
              left: 328 + 156 + 76.0 * i,
              top: 0,
              child: Semantics(
                label: l10n.loopScopeTrack(i + 1),
                child: LoopChoiceButton(
                  key: Key('loop_scope_track_$i'),
                  label: '${i + 1}',
                  selected: selected == i,
                  onTap: () => onSelected(i),
                  width: 64,
                  height: 64,
                ),
              ),
            ),
          if (name != null)
            Positioned(
              right: 0,
              top: 18,
              width: 400,
              child: AppText(
                name,
                key: const Key('loop_scope_track_name'),
                textAlign: TextAlign.right,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: surface.textSecondary,
                  fontSize: 24,
                  height: 1,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The bars stepper: minus, the count with its unit, plus. 396 x 112.
class LoopStepper extends StatelessWidget {
  /// Creates a [LoopStepper].
  const LoopStepper({
    required this.value,
    required this.unit,
    required this.onDecrement,
    required this.onIncrement,
    required this.decrementLabel,
    required this.incrementLabel,
    this.enabled = true,
    super.key,
  });

  /// The count.
  final int value;

  /// Its unit, under the count.
  final String unit;

  /// One less; `null` at the floor.
  final VoidCallback? onDecrement;

  /// One more; `null` at the ceiling.
  final VoidCallback? onIncrement;

  /// The minus button's accessible name.
  final String decrementLabel;

  /// The plus button's accessible name.
  final String incrementLabel;

  /// Whether the stepper can be used right now.
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Opacity(
      opacity: enabled ? 1 : surface.disabledOpacity,
      child: SizedBox(
        width: 396,
        height: 112,
        child: Stack(
          children: [
            Positioned(
              left: 0,
              top: 24,
              child: LoopOutlinedButton(
                key: const Key('loop_stepper_minus'),
                width: 64,
                icon: LucideIcons.minus,
                semanticLabel: decrementLabel,
                onTap: enabled ? onDecrement : null,
              ),
            ),
            Positioned(
              left: 88,
              top: 0,
              width: 220,
              height: 112,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  AppText(
                    '$value',
                    key: const Key('loop_stepper_value'),
                    style: TextStyle(
                      color: surface.textPrimary,
                      fontSize: 68,
                      fontFamily: SurfaceTheme.monoFont,
                      height: 1,
                    ),
                  ),
                  const SizedBox(width: 15),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: AppText(
                      unit,
                      style: TextStyle(
                        color: surface.textSecondary,
                        fontSize: 24,
                        height: 1,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Positioned(
              left: 332,
              top: 24,
              child: LoopOutlinedButton(
                key: const Key('loop_stepper_plus'),
                width: 64,
                icon: LucideIcons.plus,
                semanticLabel: incrementLabel,
                onTap: enabled ? onIncrement : null,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The pen's 56 px slider: a rail with the filled part and its edge. Drag or
/// tap sets the value in `0..1`.
class LoopSlider extends StatelessWidget {
  /// Creates a [LoopSlider].
  const LoopSlider({
    required this.value,
    required this.onChanged,
    required this.width,
    required this.semanticLabel,
    this.enabled = true,
    super.key,
  });

  /// The position in `0..1`.
  final double value;

  /// Called with the new position while dragging or on a tap.
  final ValueChanged<double> onChanged;

  /// The pen's width.
  final double width;

  /// The accessible name.
  final String semanticLabel;

  /// Whether the slider can be moved right now.
  final bool enabled;

  void _set(double dx) {
    if (!enabled) return;
    onChanged((dx / width).clamp(0.0, 1.0));
  }

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final clamped = value.clamp(0.0, 1.0);
    return Semantics(
      slider: true,
      label: semanticLabel,
      value: '${(clamped * 100).round()}',
      enabled: enabled,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (d) => _set(d.localPosition.dx),
        onHorizontalDragStart: (d) => _set(d.localPosition.dx),
        onHorizontalDragUpdate: (d) => _set(d.localPosition.dx),
        child: Opacity(
          opacity: enabled ? 1 : surface.disabledOpacity,
          child: Container(
            width: width,
            height: 56,
            decoration: BoxDecoration(
              color: surface.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: surface.borderHairline),
            ),
            clipBehavior: Clip.antiAlias,
            child: Stack(
              children: [
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  width: (width - 2) * clamped,
                  child: ColoredBox(color: surface.controlStrong),
                ),
                Positioned(
                  left: (width - 2) * clamped,
                  top: 0,
                  bottom: 0,
                  width: 2,
                  child: ColoredBox(color: surface.textSecondary),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One row of the Loop settings hub: the submenu's name, its current value
/// and a chevron. 1848 x 100.
class LoopHubRow extends StatelessWidget {
  /// Creates a [LoopHubRow].
  const LoopHubRow({
    required this.title,
    required this.summary,
    required this.onTap,
    super.key,
  });

  /// The submenu.
  final String title;

  /// Its current choice, at the right.
  final String summary;

  /// Opens the submenu.
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Semantics(
      button: true,
      label: title,
      value: summary,
      child: Material(
        color: surface.cardHigh,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: surface.borderSubtle),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            width: 1848,
            height: 100,
            child: Stack(
              children: [
                Positioned(
                  left: 33,
                  top: 32,
                  child: AppText(
                    title,
                    style: TextStyle(
                      color: surface.textPrimary,
                      fontSize: 32,
                      height: 1,
                    ),
                  ),
                ),
                Positioned(
                  right: 85,
                  top: 36,
                  width: 700,
                  child: AppText(
                    summary,
                    textAlign: TextAlign.right,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: surface.textSecondary,
                      fontSize: 24,
                      height: 1,
                    ),
                  ),
                ),
                Positioned(
                  left: 1787,
                  top: 36,
                  child: Icon(
                    LucideIcons.chevronRight,
                    size: 28,
                    color: surface.textPrimary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
