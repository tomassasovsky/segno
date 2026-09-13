import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:segno/control/binding/control_value_target.dart';
import 'package:segno/control/binding/expression_catalogue.dart';
import 'package:segno/control/binding/external_controls.dart';
import 'package:segno/control/binding/fx_binding_target.dart';
import 'package:segno/control/view/pedal_setup/control_row_list.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/theme/theme.dart';

/// How one of a button's controls reads in its list.
class ExternalControlRow {
  /// A row for an effect the button turns on and off.
  const ExternalControlRow.activation({
    required ExternalActivation this.activation,
    required this.destination,
    required this.name,
    required this.available,
    this.art,
  }) : parameter = null;

  /// A row for a parameter the button sets.
  const ExternalControlRow.parameter({
    required ExternalParameter this.parameter,
    required this.destination,
    required this.name,
    required this.available,
    this.art,
  }) : activation = null;

  /// The activation, when this row is one.
  final ExternalActivation? activation;

  /// The parameter, when this row is one.
  final ExternalParameter? parameter;

  /// Where the control lives, shown above its name.
  final String destination;

  /// What it is there.
  final String name;

  /// Whether the rig still has it.
  final bool available;

  /// The picture of the pedal or rack, in the catalogue package, or `null`.
  final String? art;

  /// The row's identity: its target.
  Object get target => activation?.target ?? parameter!.target;

  /// A widget key for the row, from its target's canonical form and kind —
  /// the identity itself, never a hash of it.
  String get keyId => externalControlKey(target);
}

/// A button's Controls panel: everything it drives, and the rule of the one
/// being edited.
class ExternalControlsEditor extends StatelessWidget {
  /// Creates an [ExternalControlsEditor].
  const ExternalControlsEditor({
    required this.rows,
    required this.selected,
    required this.latching,
    required this.onSelect,
    required this.onAdd,
    required this.onRemove,
    required this.onCondition,
    required this.onValueCondition,
    required this.onValue,
    super.key,
  });

  /// Activations first, then parameters, each in the order added.
  final List<ExternalControlRow> rows;

  /// The target whose rule is open.
  final Object? selected;

  /// Whether the switch is latching, which has no Held or Released.
  final bool latching;

  /// Opens a row.
  final ValueChanged<Object> onSelect;

  /// Starts choosing something to add.
  final VoidCallback onAdd;

  /// Drops the open row.
  final VoidCallback onRemove;

  /// Changes the open activation's condition.
  final ValueChanged<ExternalCondition> onCondition;

  /// Changes the open parameter's behavior.
  final ValueChanged<ExternalValueCondition> onValueCondition;

  /// Moves one of the open parameter's two values.
  final void Function({required bool active, required double value}) onValue;

  /// The pen's geometry.
  static const double penWidth = 1040;

  ExternalControlRow? get _open {
    for (final row in rows) {
      if (row.target == selected) return row;
    }
    return null;
  }

  /// Tall enough for the rows, never taller than leaves room for the rule
  /// below — which is shorter for an activation than for a parameter's two
  /// values — and never so short an empty list has nowhere to say so.
  double _listHeight(ExternalControlRow? open) {
    final cap = open?.parameter != null ? 208.0 : 320.0;
    final wanted =
        rows.length * (ControlRowTile.height + ControlRowList.gap) +
        ControlRowList.padding * 2;
    return wanted.clamp(160.0, cap);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final open = _open;
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
                  l10n.externalPanelControls,
                  style: TextStyle(
                    color: surface.textPrimary,
                    fontSize: 28,
                    height: 1.15,
                  ),
                ),
                const Spacer(),
                LoopOutlinedButton(
                  key: const Key('external_add_control'),
                  width: 212,
                  leadingIcon: LucideIcons.plus,
                  label: l10n.expressionAddControl,
                  onTap: onAdd,
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          SizedBox(height: _listHeight(open), child: _list(context)),
          if (open != null) ...[
            const SizedBox(height: 20),
            if (open.activation case final activation?)
              _activationRule(context, activation)
            else
              _parameterRule(context, open),
          ],
        ],
      ),
    );
  }

  Widget _list(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    if (rows.isEmpty) {
      return Center(
        child: AppText(
          l10n.externalControlsEmpty,
          key: const Key('external_controls_empty'),
          style: TextStyle(
            color: surface.textSecondary,
            fontSize: 26,
            height: 1.3,
          ),
        ),
      );
    }
    final openIndex = rows.indexWhere((row) => row.target == selected);
    return ControlRowList(
      itemCount: rows.length,
      selectedIndex: openIndex < 0 ? null : openIndex,
      itemBuilder: (context, index) {
        final row = rows[index];
        return ControlRowTile(
          destination: row.destination,
          name: row.name,
          art: row.art,
          selected: row.target == selected,
          available: row.available,
          valueKey: Key('external_control_value_${row.keyId}'),
          value: !row.available
              ? l10n.expressionUnavailable
              : switch (row) {
                  ExternalControlRow(:final ExternalActivation activation) =>
                    conditionLabel(l10n, activation.condition),
                  ExternalControlRow(:final ExternalParameter parameter) =>
                    _percent(parameter.active),
                  _ => '',
                },
          onTap: () => onSelect(row.target),
        );
      },
    );
  }

  Widget _ruleTitle(BuildContext context, String title) {
    final l10n = context.l10n;
    final surface = context.surface;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 21),
        SizedBox(
          height: 58,
          child: Row(
            children: [
              Expanded(
                child: AppText(
                  title,
                  maxLines: 1,
                  style: TextStyle(
                    color: surface.textSecondary,
                    fontSize: 24,
                    height: 1.15,
                  ),
                ),
              ),
              LoopOutlinedButton(
                key: const Key('external_remove_control'),
                width: 120,
                height: 58,
                label: l10n.expressionRemoveControl,
                onTap: onRemove,
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
      ],
    );
  }

  Widget _activationRule(BuildContext context, ExternalActivation activation) {
    final l10n = context.l10n;
    final surface = context.surface;
    final condition = activation.condition;
    final note = latching
        ? l10n.externalConditionLatchingNote
        : switch (condition) {
            ExternalCondition.on ||
            ExternalCondition.off => l10n.externalConditionToggleNote,
            ExternalCondition.held => l10n.externalConditionHeldNote,
            ExternalCondition.released => l10n.externalConditionReleasedNote,
          };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ruleTitle(context, l10n.externalActiveWhen),
        SizedBox(
          height: 64,
          child: Row(
            children: [
              for (final (index, value)
                  in ExternalCondition.values.indexed) ...[
                if (index > 0) const SizedBox(width: 8),
                LoopChoiceButton(
                  key: Key('external_condition_${value.name}'),
                  label: conditionLabel(l10n, value),
                  selected: value == condition,
                  // A latching switch never says how long a foot stayed on
                  // it: the two conditions that ask are offered and refused,
                  // not hidden, so the rule reads the same on either switch.
                  enabled: !(latching && value.readsContact),
                  onTap: () => onCondition(value),
                  width: 254,
                  height: 64,
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 18),
        SizedBox(
          height: 31,
          child: AppText(
            note,
            key: const Key('external_condition_note'),
            style: TextStyle(
              color: surface.textSecondary,
              fontSize: 22,
              height: 1.3,
            ),
          ),
        ),
      ],
    );
  }

  Widget _parameterRule(BuildContext context, ExternalControlRow row) {
    final l10n = context.l10n;
    final parameter = row.parameter!;
    final held = parameter.condition == ExternalValueCondition.heldReleased;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ruleTitle(context, l10n.externalButtonValues),
        SizedBox(
          height: 64,
          child: Row(
            children: [
              for (final (index, value)
                  in ExternalValueCondition.values.indexed) ...[
                if (index > 0) const SizedBox(width: 9),
                LoopChoiceButton(
                  key: Key('external_value_condition_${value.name}'),
                  label: value == ExternalValueCondition.onOff
                      ? l10n.externalValueOnOff
                      : l10n.externalValueHeldReleased,
                  selected: value == parameter.condition,
                  enabled:
                      !(latching &&
                          value == ExternalValueCondition.heldReleased),
                  onTap: () => onValueCondition(value),
                  width: 515.5,
                  height: 64,
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 18),
        Row(
          children: [
            _value(
              context,
              row,
              active: false,
              name: held
                  ? l10n.externalConditionReleased
                  : l10n.externalConditionOff,
            ),
            const SizedBox(width: 40),
            _value(
              context,
              row,
              active: true,
              name: held
                  ? l10n.externalConditionHeld
                  : l10n.externalConditionOn,
            ),
          ],
        ),
      ],
    );
  }

  Widget _value(
    BuildContext context,
    ExternalControlRow row, {
    required bool active,
    required String name,
  }) {
    final surface = context.surface;
    final parameter = row.parameter!;
    final value = active ? parameter.active : parameter.inactive;
    final id = active ? 'active' : 'inactive';
    return SizedBox(
      width: 500,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 28,
            child: Row(
              children: [
                Expanded(
                  child: AppText(
                    name,
                    maxLines: 1,
                    style: TextStyle(
                      color: surface.textPrimary,
                      fontSize: 28,
                      height: 1,
                    ),
                  ),
                ),
                AppText(
                  _percent(value),
                  key: Key('external_value_${id}_label'),
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
            key: Key('external_value_$id'),
            value: value,
            width: 500,
            semanticLabel: '${row.name} $name',
            // Moving a value writes the draft, never the parameter: the
            // accepted design is explicit that editing a mapping dispatches
            // nothing.
            enabled: row.available,
            onChanged: (next) => onValue(active: active, value: next),
          ),
        ],
      ),
    );
  }

  static String _percent(double value) => '${(value * 100).round()}%';
}

/// A stable key fragment for a control's [target]: an activation and a
/// parameter never share one, and neither is a hash.
String externalControlKey(Object target) => switch (target) {
  final FxBindingTarget activation => 'a${activation.canonicalString()}',
  final ControlValueTarget parameter => 'p${parameter.canonicalString()}',
  _ => '$target',
};

/// What a condition is called.
String conditionLabel(AppLocalizations l10n, ExternalCondition condition) =>
    switch (condition) {
      ExternalCondition.on => l10n.externalConditionOn,
      ExternalCondition.off => l10n.externalConditionOff,
      ExternalCondition.held => l10n.externalConditionHeld,
      ExternalCondition.released => l10n.externalConditionReleased,
    };

/// Pick one control on a destination: its effects to turn on and off, then
/// its parameters, in one list.
class ExternalControlTargetList extends StatelessWidget {
  /// Creates an [ExternalControlTargetList].
  const ExternalControlTargetList({
    required this.destination,
    required this.taken,
    required this.onActivation,
    required this.onParameter,
    super.key,
  });

  /// The destination whose controls these are.
  final ExpressionDestination destination;

  /// The targets this button already drives, offered and refused.
  final Set<Object> taken;

  /// Chooses an effect.
  final ValueChanged<ExpressionActivation> onActivation;

  /// Chooses a parameter.
  final ValueChanged<ExpressionControl> onParameter;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final entries =
        <({Object target, String name, String? art, VoidCallback pick})>[
          for (final activation in destination.activations)
            (
              target: activation.target,
              name: l10n.externalActivationRow(activation.label),
              art: activation.art,
              pick: () => onActivation(activation),
            ),
          // One flat list, with no section headings to say which effect a
          // parameter belongs to — so the row says it, unless the group IS the
          // destination (a track's own fader needs no second name).
          for (final group in destination.groups)
            for (final control in group.controls)
              (
                target: control.target,
                name: group.label == destination.label
                    ? control.label
                    : '${group.label} · ${control.label}',
                art: control.art,
                pick: () => onParameter(control),
              ),
        ];
    if (entries.isEmpty) {
      return Align(
        alignment: Alignment.topLeft,
        child: AppText(
          l10n.expressionNoControls,
          style: TextStyle(
            color: surface.textSecondary,
            fontSize: 26,
            height: 1.3,
          ),
        ),
      );
    }
    return ControlRowList(
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final entry = entries[index];
        return ControlRowTile(
          key: Key('external_pick_${externalControlKey(entry.target)}'),
          destination: destination.label,
          name: entry.name,
          art: entry.art,
          taken: taken.contains(entry.target),
          onTap: entry.pick,
        );
      },
    );
  }
}
