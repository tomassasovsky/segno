import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:segno/theme/theme.dart';

/// The pen's `source-grid` card: an ordinal over a name, 264 x 112, used to
/// pick the input being set up and the source being routed.
class RoutingSourceCard extends StatelessWidget {
  /// Creates a [RoutingSourceCard].
  const RoutingSourceCard({
    required this.ordinal,
    required this.name,
    required this.selected,
    required this.onTap,
    this.width = 264,
    super.key,
  });

  /// The line above the name ("Input 3", "Outputs 1–2").
  final String ordinal;

  /// The alias or the fallback label.
  final String name;

  /// Whether this is the card being edited.
  final bool selected;

  /// Picks this card.
  final VoidCallback onTap;

  /// The pen's card width.
  final double width;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Semantics(
      button: true,
      selected: selected,
      label: name,
      value: ordinal,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          width: width,
          height: 112,
          decoration: BoxDecoration(
            color: selected ? surface.accentSurface : null,
            border: Border.all(
              color: selected ? surface.borderStrong : surface.borderSubtle,
            ),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              AppText(
                ordinal,
                style: TextStyle(
                  color: selected
                      ? surface.textSecondary
                      : surface.textTertiary,
                  fontSize: 18,
                  height: 1,
                ),
              ),
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 13),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: AppText(
                    name,
                    style: TextStyle(
                      color: selected
                          ? surface.textPrimary
                          : surface.textSecondary,
                      fontSize: 22,
                      height: 1,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The pen's `inline-control` head: a label on the left and the value it is
/// showing on the right, over the control itself.
class RoutingInlineLabel extends StatelessWidget {
  /// Creates a [RoutingInlineLabel].
  const RoutingInlineLabel({
    required this.label,
    required this.value,
    required this.width,
    super.key,
  });

  /// The control's name.
  final String label;

  /// Its current value, already formatted.
  final String value;

  /// The pen's column width.
  final double width;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return SizedBox(
      width: width,
      height: 28,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          AppText(
            label,
            style: TextStyle(
              color: surface.textSecondary,
              fontSize: 24,
              height: 1,
            ),
          ),
          AppText(
            value,
            style: TextStyle(
              color: surface.textSecondary,
              fontSize: 24,
              height: 1,
            ),
          ),
        ],
      ),
    );
  }
}

/// The pen's `input-pan-ends` row: the two ends of a placement slider.
class RoutingSliderEnds extends StatelessWidget {
  /// Creates a [RoutingSliderEnds].
  const RoutingSliderEnds({
    required this.start,
    required this.end,
    required this.width,
    super.key,
  });

  /// The left end's label.
  final String start;

  /// The right end's label.
  final String end;

  /// The pen's column width.
  final double width;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      color: context.surface.textTertiary,
      fontSize: 22,
      height: 1,
    );
    return SizedBox(
      width: width,
      height: 26,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          AppText(start, style: style),
          AppText(end, style: style),
        ],
      ),
    );
  }
}

/// The pen's `input-meter-segments`: a segmented level meter over a dBFS
/// scale. [level] is the block peak in `0..1`; [clipping] lights the tail
/// whatever the level, so a clip that has already decayed is still visible
/// for as long as the engine holds the flag.
class RoutingInputMeter extends StatelessWidget {
  /// Creates a [RoutingInputMeter].
  const RoutingInputMeter({
    required this.level,
    required this.clipping,
    required this.width,
    required this.semanticLabel,
    this.segments = 41,
    super.key,
  });

  /// The block peak, `0..1`.
  final double level;

  /// Whether the engine is holding a clip on this input.
  final bool clipping;

  /// The pen's meter width.
  final double width;

  /// The accessible name.
  final String semanticLabel;

  /// How many cells the pen draws.
  final int segments;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final step = width / segments;
    final cell = step - 2.4;
    final lit = (level.clamp(0.0, 1.0) * segments).round();
    return Semantics(
      label: semanticLabel,
      value: '${(level.clamp(0.0, 1.0) * 100).round()}%',
      child: SizedBox(
        width: width,
        height: 28,
        child: Stack(
          children: [
            for (var i = 0; i < segments; i++)
              Positioned(
                left: i * step,
                top: 0,
                child: Container(
                  width: cell,
                  height: 28,
                  color: _cellColor(surface, i, lit),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Color _cellColor(SurfaceTheme surface, int index, int lit) {
    // The last four cells are the clip tail: they light on the engine's held
    // clip flag, not on the level, because a clip is a fact about the source
    // that a decayed meter would hide.
    final isTail = index >= segments - 4;
    if (isTail && clipping) return surface.rec;
    if (index < lit) return surface.accent;
    return surface.card;
  }
}

/// The pen's `input-meter-scale`: the dBFS ticks under a meter.
class RoutingMeterScale extends StatelessWidget {
  /// Creates a [RoutingMeterScale].
  const RoutingMeterScale({
    required this.labels,
    required this.width,
    super.key,
  });

  /// The tick labels, left to right.
  final List<String> labels;

  /// The pen's meter width.
  final double width;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      color: context.surface.textTertiary,
      fontSize: 20,
      height: 1,
    );
    return SizedBox(
      width: width,
      height: 21,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [for (final label in labels) AppText(label, style: style)],
      ),
    );
  }
}

/// The pen's stereo `input-pair-members` badge: the two jacks of a linked
/// pair with their ordered left and right identities.
class RoutingPairMembers extends StatelessWidget {
  /// Creates a [RoutingPairMembers].
  const RoutingPairMembers({
    required this.leftName,
    required this.rightName,
    required this.leftTag,
    required this.rightTag,
    super.key,
  });

  /// The lower jack's label.
  final String leftName;

  /// The upper jack's label.
  final String rightName;

  /// The lower jack's side tag.
  final String leftTag;

  /// The upper jack's side tag.
  final String rightTag;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    Widget member(String name, String tag) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        AppText(
          name,
          style: TextStyle(
            color: surface.textSecondary,
            fontSize: 24,
            height: 1,
          ),
        ),
        const SizedBox(width: 12),
        Container(
          width: 40,
          height: 40,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: surface.accentSurface,
            borderRadius: BorderRadius.circular(6),
          ),
          child: AppText(
            tag,
            style: TextStyle(
              color: surface.textPrimary,
              fontSize: 22,
              height: 1,
            ),
          ),
        ),
      ],
    );
    return SizedBox(
      height: 40,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          member(leftName, leftTag),
          Container(
            width: 44,
            height: 2,
            margin: const EdgeInsets.symmetric(horizontal: 20),
            color: surface.borderStrong,
          ),
          member(rightName, rightTag),
        ],
      ),
    );
  }
}

/// The pen's `routing-check` badge on a card that is selected as a source or
/// a destination.
class RoutingCheck extends StatelessWidget {
  /// Creates a [RoutingCheck].
  const RoutingCheck({required this.selected, super.key});

  /// Whether the card is chosen.
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Container(
      width: 32,
      height: 32,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: selected ? surface.accent : null,
        border: Border.all(
          color: selected ? surface.accent : surface.borderSubtle,
        ),
        borderRadius: BorderRadius.circular(6),
      ),
      child: selected
          ? Icon(LucideIcons.check, size: 23, color: surface.onAccent)
          : null,
    );
  }
}
