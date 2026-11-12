import 'dart:math' as math;

import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:material_ui/material_ui.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_frame.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/theme/theme.dart';

/// The pen's `source-grid` card: an ordinal over a name, 264 x 112, used to
/// pick the input being set up and the source being routed.
///
/// A source with no ordinal — the click, which is one thing rather than one of
/// several numbered jacks — draws the pen's shorter 264 x 64 card instead of
/// leaving a gap where the number would be.
class RoutingSourceCard extends StatelessWidget {
  /// Creates a [RoutingSourceCard].
  const RoutingSourceCard({
    required this.ordinal,
    required this.name,
    required this.selected,
    required this.onTap,
    this.width = 264,
    this.status,
    this.tags = const [],
    this.ordinalLine = false,
    this.tagLine = false,
    super.key,
  });

  /// The line above the name ("Input 3", "Outputs 1–2"), or null for a source
  /// that has no number.
  final String? ordinal;

  /// The alias or the fallback label.
  final String name;

  /// Whether this is the card being edited.
  final bool selected;

  /// Picks this card.
  final VoidCallback onTap;

  /// The pen's card width.
  final double width;

  /// A warning about this source under its name, or `null` (the Effects
  /// page's "Effects off", #1452).
  final String? status;

  /// Short labels under the name for what the interface has set on this
  /// input ("Inst", "48 V", #1646).
  final List<String> tags;

  /// Whether the card keeps the ordinal line when its name is its ordinal:
  /// set on every card of a row where any card shows an ordinal over a
  /// name, so the names stay on one line across the row (#1672).
  final bool ordinalLine;

  /// Whether the card keeps the tag line when it has no tags: set on every
  /// card of a row where any card has tags (#1672).
  final bool tagLine;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Semantics(
      button: true,
      selected: selected,
      label: name,
      value: ordinal ?? '',
      child: LoopFocusable(
        onActivate: onTap,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Container(
            width: width,
            height: ordinal == null ? 64 : 112,
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
                // A card whose name is its ordinal keeps the ordinal's line
                // empty when the row keeps it, so its name sits on the other
                // cards' name line.
                if (ordinal case final ordinal?
                    when ordinal != name || ordinalLine) ...[
                  _KeptLine(
                    visible: ordinal != name,
                    child: AppText(
                      // The kept line's height, without a second copy of
                      // the name for a finder or a reader to meet.
                      ordinal != name ? ordinal : ' ',
                      style: TextStyle(
                        color: selected
                            ? surface.textSecondary
                            : surface.textTertiary,
                        fontSize: 18,
                        height: 1,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
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
                if (status case final status?) ...[
                  const SizedBox(height: 6),
                  AppText(
                    status,
                    key: const Key('routing_source_status'),
                    style: TextStyle(
                      color: surface.warning,
                      fontSize: 16,
                      height: 1,
                    ),
                  ),
                ],
                if (tags.isNotEmpty || tagLine) ...[
                  const SizedBox(height: 8),
                  _KeptLine(
                    visible: tags.isNotEmpty,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (tags.isEmpty) const RoutingTag(''),
                        for (var i = 0; i < tags.length; i++) ...[
                          if (i > 0) const SizedBox(width: 8),
                          RoutingTag(
                            tags[i],
                            key: Key('routing_source_tag_$i'),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A card line that keeps its height when hidden, so the lines under and
/// over it stay where the other cards draw them.
class _KeptLine extends StatelessWidget {
  const _KeptLine({required this.visible, required this.child});

  final bool visible;
  final Widget child;

  @override
  Widget build(BuildContext context) => Visibility(
    visible: visible,
    maintainSize: true,
    maintainAnimation: true,
    maintainState: true,
    child: child,
  );
}

/// A short label on a source card for a setting the interface holds on that
/// input ("Inst", "48 V", #1646): an outlined pill in the card's secondary
/// text.
class RoutingTag extends StatelessWidget {
  /// Creates a [RoutingTag].
  const RoutingTag(this.text, {super.key});

  /// The label.
  final String text;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        border: Border.all(color: surface.borderStrong),
        borderRadius: BorderRadius.circular(4),
      ),
      child: AppText(
        text,
        style: TextStyle(
          color: surface.textSecondary,
          fontSize: 18,
          height: 1,
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

/// The reading beside a routing meter: the peak in dBFS, or a word for
/// silence below the meter's floor.
///
/// Below the floor there is no reading to give, and a large negative number
/// would read as a level rather than as nothing coming out.
String routingDbfsLabel(AppLocalizations l10n, double peak) {
  if (peak <= 0) return l10n.routingOutputSilent;
  final db = 20 * (math.log(peak) / math.ln10);
  if (db < kMeterFloorDb) return l10n.routingOutputSilent;
  return l10n.routingOutputDbfs(db.toStringAsFixed(1));
}

/// Where a level sits on a routing meter, `0..1`.
///
/// NOT [peakMeterFill]. The two meters print different scales: the stage's is
/// linear in decibels over [kMeterFloorDb]..0, while [RoutingMeterScale]
/// spaces its four ticks evenly, which puts -24 a third of the way along and
/// -12 two thirds. A routing meter filled by the stage's map would light
/// cells that disagree with the scale drawn directly under them.
double routingMeterPosition(double level) {
  if (level <= 0) return 0;
  return routingMeterPositionOfDb(20 * (math.log(level) / math.ln10));
}

/// [routingMeterPosition] for a level already in dBFS.
double routingMeterPositionOfDb(double db) {
  if (db <= kMeterFloorDb) return 0;
  if (db >= 0) return 1;
  if (db <= -24) return (db - kMeterFloorDb) / (-24 - kMeterFloorDb) / 3;
  return (1 + (db + 24) / 12) / 3;
}

/// Where the loudest playing should peak on an input's meter, in dBFS
/// (#1646): low enough to leave headroom over a 32-bit capture, high enough
/// to keep the source well above the converter's noise. The player sets the
/// interface's gain knob against it.
const ({double low, double high}) kInputGainTargetDb = (low: -18, high: -6);

/// The pen's `input-meter-segments`: a segmented level meter over a dBFS
/// scale. [level] is the block peak in `0..1`; [clipping] lights the tail
/// whatever the level, so a clip that has already decayed is still visible
/// for as long as the engine holds the flag. A [target] band shades the cells
/// between its two levels that the level has not reached, and a line under
/// the cells marks it whatever the level.
class RoutingInputMeter extends StatelessWidget {
  /// Creates a [RoutingInputMeter].
  const RoutingInputMeter({
    required this.level,
    required this.clipping,
    required this.width,
    required this.semanticLabel,
    this.segments = 41,
    this.tail = 2,
    this.height = 28,
    this.target,
    super.key,
  });

  /// The block peak, `0..1`.
  final double level;

  /// The band, in dBFS, where the loudest playing should peak, or null.
  final ({double low, double high})? target;

  /// The gap between the cells and the band's line.
  static const double markerGap = 3;

  /// The band line's thickness.
  static const double markerHeight = 3;

  /// Whether the engine is holding a clip on this input.
  final bool clipping;

  /// The pen's meter width.
  final double width;

  /// The accessible name.
  final String semanticLabel;

  /// How many cells the pen draws.
  final int segments;

  /// How many cells at the end are the clip tail.
  final int tail;

  /// The pen's cell height.
  final double height;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final step = width / segments;
    final cell = step - 2.4;
    final lit = (routingMeterPosition(level) * segments).round();
    final band = targetCells;
    return Semantics(
      label: semanticLabel,
      value: '${(routingMeterPosition(level) * 100).round()}%',
      child: SizedBox(
        width: width,
        height: band == null ? height : height + markerGap + markerHeight,
        child: Stack(
          children: [
            if (band != null)
              Positioned(
                key: const Key('routing_meter_target'),
                left: band.first * step,
                top: height + markerGap,
                width: (band.last - band.first) * step - 2.4,
                height: markerHeight,
                child: ColoredBox(color: surface.textSecondary),
              ),
            for (var i = 0; i < segments; i++)
              Positioned(
                left: i * step,
                top: 0,
                child: Container(
                  width: cell,
                  height: height,
                  key: band != null && i >= band.first && i < band.last
                      ? const Key('routing_meter_target_cell')
                      : null,
                  color: _cellColor(surface, i, lit, band),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// The cells [target] covers, `first` inclusive to `last` exclusive: the
  /// cells that light at a level inside it. Cell `i` lights once the level
  /// reaches position `(i + 0.5) / segments` (the fill rounds), so a peak at
  /// the band's low edge lights its first cell. Null without a target.
  ({int first, int last})? get targetCells {
    final target = this.target;
    if (target == null) return null;
    double at(double db) => routingMeterPositionOfDb(db) * segments - 0.5;
    return (first: at(target.low).ceil(), last: at(target.high).floor() + 1);
  }

  Color _cellColor(
    SurfaceTheme surface,
    int index,
    int lit,
    ({int first, int last})? band,
  ) {
    // The last cells are the clip tail: they light on the engine's held clip
    // flag, not on the level, because a clip is a fact about the source that a
    // decayed meter would hide.
    final isTail = index >= segments - tail;
    if (isTail && clipping) return surface.rec;
    if (index < lit) return surface.accent;
    if (band != null && index >= band.first && index < band.last) {
      return surface.accentSurface;
    }
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
    return SizedBox(
      height: 40,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _PairMember(name: leftName, tag: leftTag),
          Container(
            width: 44,
            height: 2,
            margin: const EdgeInsets.symmetric(horizontal: 20),
            color: surface.borderStrong,
          ),
          _PairMember(name: rightName, tag: rightTag),
        ],
      ),
    );
  }
}

/// One jack of a linked pair: its label and its side tag.
class _PairMember extends StatelessWidget {
  const _PairMember({required this.name, required this.tag});

  final String name;
  final String tag;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Row(
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

/// The pen's `route:output:*` card: a destination's jacks over its name, with
/// a check that says whether the chosen source reaches it. 684 x 144.
class RoutingDestinationCard extends StatelessWidget {
  /// Creates a [RoutingDestinationCard].
  const RoutingDestinationCard({
    required this.jacks,
    required this.name,
    required this.selected,
    required this.onTap,
    this.available = true,
    super.key,
  });

  /// The jacks this destination drives ("Outputs 1-2").
  final String jacks;

  /// The name the player gave it, or its short jack form.
  final String name;

  /// Whether the chosen source reaches it.
  final bool selected;

  /// Whether this destination has a physical jack on the open device.
  final bool available;

  /// Adds or removes this destination.
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final displayName = available
        ? name
        : '$name · ${context.l10n.routingDestinationUnavailable}';
    return Semantics(
      button: true,
      selected: selected,
      label: name,
      value: available
          ? jacks
          : '$jacks, ${context.l10n.routingDestinationUnavailable}',
      child: LoopFocusable(
        enabled: available || selected,
        onActivate: onTap,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: available || selected ? onTap : null,
          // Its width is the row's share, set where the row is laid out.
          child: Container(
            height: 144,
            padding: const EdgeInsets.symmetric(horizontal: 31),
            decoration: BoxDecoration(
              color: selected ? surface.accentSurface : surface.card,
              border: Border.all(
                color: selected ? surface.borderStrong : surface.borderSubtle,
              ),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (name != jacks) ...[
                        AppText(
                          jacks,
                          style: TextStyle(
                            color: surface.textTertiary,
                            fontSize: 22,
                            height: 1,
                          ),
                        ),
                        const SizedBox(height: 16),
                      ],
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: AppText(
                          displayName,
                          style: TextStyle(
                            color: selected
                                ? surface.textPrimary
                                : surface.textSecondary,
                            fontSize: 33,
                            height: 1,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 24),
                RoutingCheck(selected: selected),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The pen's `scope-controls`: the tracks as numbered buttons with the chosen
/// one's name beside them, shared by the two track-scoped routing tasks.
class RoutingTrackScope extends StatelessWidget {
  /// Creates a [RoutingTrackScope].
  const RoutingTrackScope({
    required this.heading,
    required this.count,
    required this.selected,
    required this.names,
    required this.onSelected,
    super.key,
  });

  /// The row's h2.
  final String heading;

  /// How many tracks the rig has.
  final int count;

  /// The track in scope.
  final int selected;

  /// Every track's display name.
  final List<String> names;

  /// Called with the track tapped.
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return SizedBox(
      width: LoopSettingsFrame.contentWidthOf(context),
      height: 76,
      child: Stack(
        children: [
          Positioned(left: 0, top: 22, child: LoopSectionLabel(heading)),
          for (var i = 0; i < count; i++)
            Positioned(
              left: 328 + 76.0 * i,
              top: 6,
              child: Semantics(
                label: l10n.loopScopeTrack(i + 1),
                child: LoopChoiceButton(
                  key: Key('routing_track_$i'),
                  label: '${i + 1}',
                  selected: i == selected,
                  onTap: () => onSelected(i),
                  width: 64,
                  height: 64,
                ),
              ),
            ),
          if (selected < names.length)
            Positioned(
              right: 0,
              top: 22,
              width: 400,
              child: Align(
                alignment: Alignment.centerRight,
                child: AppText(
                  names[selected],
                  key: const Key('routing_track_name'),
                  style: TextStyle(
                    color: context.surface.textSecondary,
                    fontSize: 28,
                    height: 1,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
