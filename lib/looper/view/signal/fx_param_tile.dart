import 'package:flutter/material.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/looper/view/signal_graph/signal_style.dart';
import 'package:segno/theme/theme.dart';

/// Geometry of the FX parameter grid, from `DS / 06 FX parameter — spec`.
///
/// Every parameter kind — continuous, switch, enum, read-only — wears the same
/// skeleton, so a dense strip reads as one grid rather than a row of unlike
/// controls. The tile is an **overview**, never the live surface: it commits
/// nothing on touch, it opens the editor sheet. Mid-take control belongs to the
/// foot pedal, so no drag on this screen can change audio by accident.
abstract final class FxParamTileMetrics {
  /// Tile width. 78 on a [gutter] of 7 fills a 1738px panel at 20 columns.
  static const double width = 78;

  /// Space between tiles, horizontally and between rows.
  static const double gutter = 7;

  /// The value box at text scale 1 — the only part that differs between
  /// kinds, and the part that absorbs any growth in the two text lines.
  static const double boxHeight = 36;

  /// The value-position readout under the box. A readout, not a handle.
  static const double indicatorHeight = 3;

  /// Name + box + indicator, with the two 5px gaps between them.
  static const double height = 59;

  /// The floor the name line's auto-shrink stops at, as a fraction of mono 9.
  ///
  /// A name wider than the tile scales down until it fits rather than
  /// ellipsizing — "RETROALIMENTACIÓN" (the Spanish `Feedback`, #500) is 17
  /// mono characters against a [width] that seats 14, and a legend whose job
  /// is to say which knob this is cannot do it cut off mid-word. The floor
  /// keeps the shrink honest: past it (a plugin reporting a paragraph as a
  /// parameter name) the name ellipsizes at the floor size instead of scaling
  /// into an unreadable smear, and the sheet header still carries it whole.
  static const double nameMinScale = 0.75;

  static const double _gap = 5;
  static const double _boxRadius = 7;
}

/// [name] as the grid prints it: upper case, with camel-case run back apart.
///
/// Plugins name parameters however they like, and plenty report `OutputMode`
/// or `dryWet` with no space in them. Upper-casing those gives `OUTPUTMODE`,
/// which reads as one long word at mono 9pt in a 78px tile. Only touched when
/// the name has no space of its own — a plugin that punctuates its own names
/// gets left alone, acronyms included.
String spacedParamName(String name) {
  if (name.contains(' ')) return name.toUpperCase();
  return name
      .replaceAllMapped(
        RegExp('([a-z0-9])([A-Z])'),
        (m) => '${m[1]} ${m[2]}',
      )
      .toUpperCase();
}

/// The shared name / control / indicator skeleton every parameter cell wears.
///
/// Nothing here states in words what the control already shows — a switch's
/// position is its value, and the indicator carries an enum's step.
class _FxParamCell extends StatelessWidget {
  const _FxParamCell({
    required this.name,
    required this.control,
    required this.fill,
    this.muted = false,
  });

  /// The parameter's name. Auto-shrinks (to [FxParamTileMetrics.nameMinScale]
  /// at most) when it outgrows the tile, and only past that ellipsizes; the
  /// full name is in the sheet header, which is where you are when you need to
  /// read it at length.
  final String name;

  /// The 36px control body.
  final Widget control;

  /// Indicator fill in `0..1`, or null for a cell with no position to report.
  final double? fill;

  /// Whether this cell reports rather than sets. The indicator loses the
  /// accent with it: accent means "this is live", and a meter is not.
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final style = signalMono(color: surface.textSecondary, size: 9);
    final scaler = MediaQuery.textScalerOf(context);
    // Exactly what one line of [style] measures: with a `height` multiplier
    // set, a line is `height x fontSize`, scaled. Stated rather than measured
    // so the name row's height is the same number on every font and engine
    // version — the row must never claim more than the single line the
    // pre-#500 layout reserved, or the value box below loses the slack it
    // absorbs at raised text scales and overflows.
    final nameLineHeight = scaler.scale(style.fontSize!) * style.height!;
    return SizedBox(
      width: FxParamTileMetrics.width,
      height: FxParamTileMetrics.height,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Excluded here rather than at each of the four call sites: every
          // cell's wrapper already announces the name, so left in, a reader
          // hears "VINTAGE" and then "Vintage of Octaver".
          ExcludeSemantics(
            // A name wider than the tile shrinks to fit instead of truncating
            // (#500): the Spanish built-in names run to 17 mono characters
            // against a width that seats 14, and maxLines: 1 + ellipsis cut
            // them mid-word. `scaleDown` never enlarges, so a fitting name
            // renders at mono 9 exactly as before; the ConstrainedBox caps how
            // far the shrink can go — text past the cap ellipsizes rather than
            // scaling below [FxParamTileMetrics.nameMinScale] of the face. The
            // cap scales with the text so the fits-whole set is the same set
            // of names at every text scale. The SizedBox pins the row to the
            // one-line height the layout has always reserved: the fit box can
            // only shrink its child into that box, never grow the row and
            // squeeze the value box below.
            child: SizedBox(
              height: nameLineHeight,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: scaler.scale(
                      FxParamTileMetrics.width /
                          FxParamTileMetrics.nameMinScale,
                    ),
                  ),
                  child: Text(
                    // Uppercased for the same reason the DS specimens are, and
                    // the rotary caption was before it: at mono 9 in 78px this
                    // is a legend, and caps keep a dense grid's names scanning
                    // as one row.
                    spacedParamName(name),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: style,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: FxParamTileMetrics._gap),
          // The box takes the slack, so the tile's own height stays exactly
          // [FxParamTileMetrics.height] whatever the text does. It was a fixed
          // 36 under a fixed 59, which left the name and the readout no room
          // to grow: at a system text scale of 1.2 every tile in the grid
          // overflowed its bottom, one red bar per parameter across the whole
          // strip. [FxParamTileMetrics.boxHeight] is what it measures at
          // scale 1, and now a floor to fall from rather than a promise.
          Expanded(child: control),
          const SizedBox(height: FxParamTileMetrics._gap),
          _FxParamIndicator(fill: fill, muted: muted),
        ],
      ),
    );
  }
}

/// The 3px value-position bar under a cell.
class _FxParamIndicator extends StatelessWidget {
  const _FxParamIndicator({required this.fill, this.muted = false});

  final double? fill;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return SizedBox(
      height: FxParamTileMetrics.indicatorHeight,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: surface.borderStrong,
          borderRadius: BorderRadius.circular(999),
        ),
        child: fill == null
            ? null
            : FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: fill!.clamp(0.0, 1.0),
                child: DecoratedBox(
                  key: const Key('fx_param_indicator_fill'),
                  decoration: BoxDecoration(
                    // `textTertiary`, not `textMuted`: muted lands at 1.1:1
                    // against the track in the high-contrast theme — the
                    // meter's position bar disappears in the one theme people
                    // choose because things were hard to see.
                    color: muted ? surface.textTertiary : surface.accent,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
      ),
    );
  }
}

/// The boxed value readout shared by the continuous tile and the enum cell.
class _FxParamBox extends StatelessWidget {
  const _FxParamBox({required this.children, this.bordered = true});

  final List<Widget> children;

  /// A read-only cell drops the box entirely — borderless is what tells a
  /// finger not to bother, and a meter that looks like every other tile is a
  /// control that ignores you.
  final bool bordered;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: bordered ? context.surface.cardHigh : null,
        borderRadius: BorderRadius.circular(FxParamTileMetrics._boxRadius),
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: children,
        ),
      ),
    );
  }
}

/// A continuous or many-stepped plugin parameter: name, its value in the
/// plugin's own words, and a position indicator. Tapping opens the editor
/// sheet — [onTap] is null for a read-only parameter, which reports a value but
/// takes none (meters land here).
class FxParamTile extends StatelessWidget {
  /// Creates an [FxParamTile].
  const FxParamTile({
    required this.spec,
    required this.value,
    required this.valueText,
    required this.onTap,
    this.semanticLabel,
    super.key,
  });

  /// The parameter this tile reports.
  final PluginParamInfo spec;

  /// The current plain value, in `[spec.min, spec.max]`.
  final double value;

  /// The plugin's own rendering of [value] ("-6.0 dB"), or null when it offers
  /// none — the tile then falls back to the number plus [PluginParamInfo.unit].
  final String? valueText;

  /// Opens the editor sheet. Null for a read-only parameter.
  final VoidCallback? onTap;

  /// What a screen reader hears instead of the bare parameter name — "MIX of
  /// Reverb". A tile is 78px of mono at 9pt, so what it can PRINT is a
  /// truncated name; what it says out loud has no such limit, and "MIX" alone
  /// does not say whose.
  final String? semanticLabel;

  /// [value] as a `0..1` position within the parameter's range.
  double get _fraction {
    final span = spec.max - spec.min;
    if (span == 0) return 0;
    return ((value - spec.min) / span).clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    // The plugin hands value and unit over as one preformatted string, so they
    // live together in the box. Splitting them would mean parsing the plugin's
    // own formatting apart. Only the fallback path has a separate unit.
    final fromPlugin = valueText != null && valueText!.isNotEmpty;
    final text = fromPlugin
        ? valueText!
        : (spec.stepCount > 0
              ? value.round().toString()
              : value.toStringAsFixed(2));

    final readOnly = onTap == null;
    final cell = _FxParamCell(
      name: spec.name,
      fill: _fraction,
      muted: readOnly,
      control: _FxParamBox(
        bordered: !readOnly,
        children: [
          Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: signalMono(
              color: readOnly ? surface.textTertiary : surface.textPrimary,
              size: 10,
            ),
          ),
          if (!fromPlugin && spec.unit.isNotEmpty)
            Text(
              spec.unit,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: signalMono(color: surface.textTertiary, size: 9),
            ),
        ],
      ),
    );

    if (onTap == null) {
      return Semantics(
        readOnly: true,
        label: semanticLabel ?? spec.name,
        value: text,
        child: ExcludeSemantics(child: cell),
      );
    }
    return Semantics(
      button: true,
      label: semanticLabel ?? spec.name,
      value: text,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(FxParamTileMetrics._boxRadius),
        child: ExcludeSemantics(child: cell),
      ),
    );
  }
}
