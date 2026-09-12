import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:segno/control/binding/control_value_target.dart';
import 'package:segno/control/binding/expression_catalogue.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/model/fx_destination.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/theme/theme.dart';

/// Pick a destination.
///
/// A whole view rather than a panel over the page, unlike this screen's action
/// chooser: the list behind it is every chain the rig has, which is as long as
/// the rig is, and the accepted design gives it the room.
class ExpressionDestinationPicker extends StatelessWidget {
  /// Creates an [ExpressionDestinationPicker].
  const ExpressionDestinationPicker({
    required this.destinations,
    required this.kind,
    required this.onKind,
    required this.onOpen,
    super.key,
  });

  /// Every destination the rig offers, in reading order.
  final List<ExpressionDestination> destinations;

  /// Which tab is open.
  final FxDestinationKind kind;

  /// Opens another tab.
  final ValueChanged<FxDestinationKind> onKind;

  /// Opens a destination's controls.
  final ValueChanged<ExpressionDestination> onOpen;

  /// The pen's geometry: two columns of rows under a row of tabs.
  static const double _rowWidth = 844;
  static const double _rowHeight = 96;
  static const double _columnGap = 24;
  static const double _rowGap = 18;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final shown = [
      for (final d in destinations)
        if (d.kind == kind) d,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 64,
          child: Row(
            children: [
              for (final (index, value)
                  in FxDestinationKind.values.indexed) ...[
                if (index > 0) const SizedBox(width: 9),
                LoopChoiceButton(
                  key: Key('expression_kind_${value.name}'),
                  label: expressionKindLabel(l10n, value),
                  selected: value == kind,
                  onTap: () => onKind(value),
                  width: switch (value) {
                    FxDestinationKind.liveInput => 177,
                    FxDestinationKind.recordedTrack => 237,
                    FxDestinationKind.output => 147,
                  },
                  height: 64,
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 32),
        Expanded(
          child: shown.isEmpty
              ? Align(
                  alignment: Alignment.topLeft,
                  child: AppText(
                    l10n.expressionNoControls,
                    key: const Key('expression_no_destinations'),
                    style: TextStyle(
                      color: surface.textSecondary,
                      fontSize: 26,
                      height: 1.3,
                    ),
                  ),
                )
              : GridView.builder(
                  padding: const EdgeInsets.all(4),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    crossAxisSpacing: _columnGap,
                    mainAxisSpacing: _rowGap,
                    mainAxisExtent: _rowHeight,
                  ),
                  itemCount: shown.length,
                  itemBuilder: (context, index) => _row(context, shown[index]),
                ),
        ),
      ],
    );
  }

  Widget _row(BuildContext context, ExpressionDestination destination) {
    final surface = context.surface;
    return Semantics(
      button: true,
      label: destination.label,
      child: GestureDetector(
        onTap: () => onOpen(destination),
        behavior: HitTestBehavior.opaque,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: surface.card,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: surface.borderSubtle),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 29),
            child: Row(
              children: [
                Expanded(
                  child: ExcludeSemantics(
                    child: AppText(
                      destination.label,
                      key: Key('expression_destination_${destination.id}'),
                      maxLines: 1,
                      style: TextStyle(
                        color: surface.textPrimary,
                        fontSize: 29,
                        height: 1.15,
                      ),
                    ),
                  ),
                ),
                Icon(
                  LucideIcons.chevronRight,
                  size: 28,
                  color: surface.textSecondary,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The pen's width for the two columns and their gap, so the page can size
  /// the view it puts this in.
  static double get penWidth => _rowWidth * 2 + _columnGap + 8;
}

/// Pick a control on one destination.
class ExpressionControlPicker extends StatelessWidget {
  /// Creates an [ExpressionControlPicker].
  const ExpressionControlPicker({
    required this.destination,
    required this.taken,
    required this.onPick,
    super.key,
  });

  /// The destination whose controls these are.
  final ExpressionDestination destination;

  /// The targets this pedal already sweeps. They are shown and refused rather
  /// than hidden: one pedal drives each control once, and a control that
  /// vanished from the list would read as a rig that does not have it.
  final Set<ControlValueTarget> taken;

  /// Chooses a control.
  final ValueChanged<ControlValueTarget> onPick;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    if (destination.groups.isEmpty) {
      return Align(
        alignment: Alignment.topLeft,
        child: AppText(
          l10n.expressionNoControls,
          key: const Key('expression_no_controls'),
          style: TextStyle(
            color: surface.textSecondary,
            fontSize: 26,
            height: 1.3,
          ),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.all(6),
      children: [
        for (final (index, group) in destination.groups.indexed) ...[
          if (index > 0) const SizedBox(height: 32),
          SizedBox(
            height: 31,
            child: AppText(
              group.label,
              maxLines: 1,
              style: TextStyle(
                color: surface.textSecondary,
                fontSize: 26,
                height: 1.15,
              ),
            ),
          ),
          const SizedBox(height: 18),
          _grid(context, group),
        ],
      ],
    );
  }

  /// The pen's three-across grid of control buttons.
  Widget _grid(BuildContext context, ExpressionControlGroup group) => Wrap(
    spacing: _gridGap,
    runSpacing: _gridGap,
    children: [for (final control in group.controls) _button(context, control)],
  );

  Widget _button(BuildContext context, ExpressionControl control) {
    final surface = context.surface;
    final already = taken.contains(control.target);
    return SizedBox(
      width: _buttonWidth,
      height: _buttonHeight,
      child: Semantics(
        button: true,
        enabled: !already,
        label: control.label,
        child: GestureDetector(
          onTap: already ? null : () => onPick(control.target),
          behavior: HitTestBehavior.opaque,
          child: Opacity(
            opacity: already ? surface.disabledOpacity : 1,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: surface.card,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: surface.borderSubtle),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 23),
                child: Row(
                  children: [
                    Expanded(
                      child: ExcludeSemantics(
                        child: AppText(
                          control.label,
                          // Keyed by the canonical form itself: it IS the
                          // target's identity, and two hashes that collided
                          // would be two rows of one list sharing a key.
                          key: Key(
                            'expression_target_'
                            '${control.target.canonicalString()}',
                          ),
                          maxLines: 1,
                          style: TextStyle(
                            color: surface.textPrimary,
                            fontSize: 25,
                            height: 1.15,
                          ),
                        ),
                      ),
                    ),
                    if (already)
                      Icon(
                        LucideIcons.check,
                        size: 24,
                        color: surface.textSecondary,
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The pen's grid: three buttons across the workspace.
  static const double _buttonWidth = 560;
  static const double _buttonHeight = 90;
  static const double _gridGap = 14;
}
