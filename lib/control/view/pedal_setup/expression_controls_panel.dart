import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:segno/control/binding/control_value_target.dart';
import 'package:segno/control/binding/external_expression.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/theme/theme.dart';

/// How one mapping reads: what it points at, and whether the rig still has it.
class ExpressionRow {
  /// Creates an [ExpressionRow].
  const ExpressionRow({
    required this.mapping,
    required this.destination,
    required this.control,
    required this.available,
  });

  /// The mapping itself.
  final ExpressionMapping mapping;

  /// Where it points — shown above the control's own name.
  final String destination;

  /// What it sweeps there.
  final String control;

  /// Whether the rig still has it. A mapping that lost its effect keeps its
  /// row and says so; it is never quietly repointed at whatever replaced it.
  final bool available;
}

/// Everything an expression pedal sweeps, and the endpoints of the one being
/// edited.
class ExpressionControlsPanel extends StatelessWidget {
  /// Creates an [ExpressionControlsPanel].
  const ExpressionControlsPanel({
    required this.rows,
    required this.selected,
    required this.position,
    required this.onSelect,
    required this.onAdd,
    required this.onChange,
    required this.onRemove,
    required this.onEndpoint,
    super.key,
  });

  /// The mappings, in the order they were added.
  final List<ExpressionRow> rows;

  /// The target whose range is open, or `null` when the list is empty.
  final ControlValueTarget? selected;

  /// Where the pedal is in its taught travel, or `null` when that is not known
  /// — which is what decides whether a row can show a live value.
  final double? position;

  /// Opens a row's range.
  final ValueChanged<ControlValueTarget> onSelect;

  /// Starts choosing something to add.
  final VoidCallback onAdd;

  /// Repoints the open row at something else.
  final VoidCallback onChange;

  /// Drops the open row.
  final VoidCallback onRemove;

  /// Moves one endpoint of the open row. `true` is the heel.
  final void Function({required bool isHeel, required double value}) onEndpoint;

  /// The pen's column width.
  static const double penWidth = 1290;

  /// The pen's list geometry: rows this tall, this far apart, inside a region
  /// that never grows past this.
  static const double _rowHeight = 96;
  static const double _rowGap = 12;
  static const double _listPadding = 4;
  static const double _listMax = 318;
  static const double _rangeHeight = 213;

  /// The region's height: tall enough for the rows it has, capped so a long
  /// list scrolls rather than pushing the range off the screen. An empty list
  /// takes the full height, because that is where its invitation sits.
  double get _listHeight {
    if (rows.isEmpty) return _listMax;
    final wanted = rows.length * (_rowHeight + _rowGap) + _listPadding * 2;
    return wanted < _listMax ? wanted : _listMax;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final open = _openRow;
    return SizedBox(
      width: penWidth,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 64,
            child: Row(
              children: [
                AppText(
                  l10n.expressionControls,
                  style: TextStyle(
                    color: surface.textPrimary,
                    fontSize: 32,
                    height: 1.15,
                  ),
                ),
                const Spacer(),
                LoopOutlinedButton(
                  key: const Key('expression_add'),
                  width: 212,
                  leadingIcon: LucideIcons.plus,
                  label: l10n.expressionAddControl,
                  onTap: onAdd,
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          SizedBox(height: _listHeight, child: _list(context)),
          if (open != null) ...[
            const SizedBox(height: 24),
            SizedBox(height: _rangeHeight, child: _range(context, open)),
          ],
        ],
      ),
    );
  }

  ExpressionRow? get _openRow {
    for (final row in rows) {
      if (row.mapping.target == selected) return row;
    }
    return null;
  }

  Widget _list(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    if (rows.isEmpty) {
      return Center(
        child: AppText(
          l10n.expressionEmpty,
          key: const Key('expression_empty'),
          style: TextStyle(
            color: surface.textSecondary,
            fontSize: 26,
            height: 1.3,
          ),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.all(_listPadding),
      itemCount: rows.length,
      separatorBuilder: (_, _) => const SizedBox(height: _rowGap),
      itemBuilder: (context, index) => _row(context, rows[index]),
    );
  }

  Widget _row(BuildContext context, ExpressionRow row) {
    final l10n = context.l10n;
    final surface = context.surface;
    final open = row.mapping.target == selected;
    final at = position;
    return Semantics(
      button: true,
      selected: open,
      label: '${row.destination} ${row.control}',
      child: GestureDetector(
        onTap: () => onSelect(row.mapping.target),
        behavior: HitTestBehavior.opaque,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: open ? surface.accentSurface : surface.card,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: open ? surface.accent : surface.borderSubtle,
            ),
          ),
          child: SizedBox(
            height: _rowHeight,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 25),
              child: Row(
                children: [
                  Expanded(
                    child: ExcludeSemantics(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          AppText(
                            row.destination,
                            maxLines: 1,
                            style: TextStyle(
                              color: surface.textSecondary,
                              fontSize: 20,
                              height: 1.15,
                            ),
                          ),
                          const SizedBox(height: 6),
                          AppText(
                            row.control,
                            maxLines: 1,
                            style: TextStyle(
                              color: surface.textPrimary,
                              fontSize: 27,
                              height: 1.15,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 24),
                  AppText(
                    !row.available
                        ? l10n.expressionUnavailable
                        : at == null
                        ? l10n.expressionNoReading
                        : _percent(row.mapping.valueAt(at)),
                    key: Key(
                      'expression_value_'
                      '${row.mapping.target.canonicalString()}',
                    ),
                    style: TextStyle(
                      color: row.available
                          ? surface.textPrimary
                          : surface.textTertiary,
                      fontSize: 27,
                      height: 1.15,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _range(BuildContext context, ExpressionRow row) {
    final l10n = context.l10n;
    final surface = context.surface;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 27),
        SizedBox(
          height: 58,
          child: Row(
            children: [
              Expanded(
                child: AppText(
                  row.available
                      ? l10n.expressionRange
                      : l10n.expressionUnavailableNote,
                  key: const Key('expression_range_title'),
                  maxLines: 1,
                  style: TextStyle(
                    color: surface.textSecondary,
                    fontSize: 24,
                    height: 1.15,
                  ),
                ),
              ),
              LoopOutlinedButton(
                key: const Key('expression_change'),
                width: 188,
                height: 58,
                label: l10n.expressionChangeControl,
                onTap: onChange,
              ),
              const SizedBox(width: 11),
              LoopOutlinedButton(
                key: const Key('expression_remove'),
                width: 120,
                height: 58,
                label: l10n.expressionRemoveControl,
                onTap: onRemove,
              ),
            ],
          ),
        ),
        const SizedBox(height: 30),
        Row(
          children: [
            _endpoint(context, row, isHeel: true),
            const SizedBox(width: 40),
            _endpoint(context, row, isHeel: false),
          ],
        ),
      ],
    );
  }

  Widget _endpoint(
    BuildContext context,
    ExpressionRow row, {
    required bool isHeel,
  }) {
    final l10n = context.l10n;
    final surface = context.surface;
    final value = isHeel ? row.mapping.heel : row.mapping.toe;
    final name = isHeel ? l10n.expressionHeel : l10n.expressionToe;
    return SizedBox(
      width: 625,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 28,
            child: Row(
              children: [
                AppText(
                  name,
                  style: TextStyle(
                    color: surface.textPrimary,
                    fontSize: 28,
                    height: 1,
                  ),
                ),
                const Spacer(),
                AppText(
                  _percent(value),
                  key: Key(
                    'expression_endpoint_${isHeel ? 'heel' : 'toe'}_value',
                  ),
                  style: TextStyle(
                    color: surface.textSecondary,
                    fontSize: 20,
                    height: 1,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          LoopSlider(
            key: Key('expression_endpoint_${isHeel ? 'heel' : 'toe'}'),
            value: value,
            width: 625,
            semanticLabel: '${row.control} $name',
            // A control the rig no longer has cannot be auditioned, so its
            // endpoints are shown and not movable: the row is there to be
            // repointed or removed, not tuned.
            enabled: row.available,
            onChanged: (next) => onEndpoint(isHeel: isHeel, value: next),
          ),
        ],
      ),
    );
  }

  static String _percent(double value) => '${(value * 100).round()}%';
}
