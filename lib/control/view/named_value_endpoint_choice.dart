import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/control/binding/control_value_target.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/model/record_start.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/looper/view/tempo_labels.dart';
import 'package:segno/theme/theme.dart';

/// A mapping endpoint's named Hear click or Count-in value.
///
/// The stored endpoint is left untouched until a choice is made. Escape then
/// restores its exact opening value, including an older noncanonical value.
class NamedValueEndpointChoice extends StatefulWidget {
  /// Creates a compact four-choice endpoint.
  const NamedValueEndpointChoice({
    required this.target,
    required this.value,
    required this.width,
    required this.enabled,
    required this.keyPrefix,
    required this.onChanged,
    this.caption,
    super.key,
  });

  /// The one named four-choice target this endpoint edits.
  final ControlValueTarget target;

  /// The normalized draft endpoint.
  final double value;

  /// Width of this editor slot.
  final double width;

  /// Whether the target can be edited now.
  final bool enabled;

  /// Stable identity for choice buttons.
  final String keyPrefix;

  /// Writes an endpoint choice to the draft only.
  final ValueChanged<double> onChanged;

  /// Optional MIDI caption; other editors draw one outside this widget.
  final String? caption;

  @override
  State<NamedValueEndpointChoice> createState() =>
      _NamedValueEndpointChoiceState();
}

class _NamedValueEndpointChoiceState extends State<NamedValueEndpointChoice> {
  final _focusNode = FocusNode();
  double? _opening;

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  void _choose(double normalized) {
    if (!widget.enabled) return;
    _opening ??= widget.value;
    _focusNode.requestFocus();
    widget.onChanged(normalized);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final choices = switch (widget.target) {
      ClickModeValueTarget() => <(String, String, double)>[
        for (final mode in ClickModeValueTarget.choices)
          (
            mode.name,
            switch (mode) {
              ClickMode.off => l10n.loopClickOff,
              ClickMode.recFirst => l10n.loopClickFirst,
              ClickMode.rec => l10n.loopClickRecording,
              ClickMode.playRec => l10n.loopClickAlways,
            },
            const ClickModeValueTarget().fromDomain(mode),
          ),
      ],
      CountInValueTarget() => <(String, String, double)>[
        for (final bars in kCountInBarOptions)
          (
            '$bars',
            countInLabels(l10n)[bars]!,
            const CountInValueTarget().fromDomain(bars),
          ),
      ],
      _ => throw ArgumentError.value(widget.target, 'target'),
    };
    final selected = (widget.value.clamp(0.0, 1.0) * 3).round();
    return Focus(
      focusNode: _focusNode,
      skipTraversal: true,
      onFocusChange: (focused) {
        if (focused) {
          _opening ??= widget.value;
        } else {
          _opening = null;
        }
      },
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent ||
            event.logicalKey != LogicalKeyboardKey.escape ||
            _opening == null) {
          return KeyEventResult.ignored;
        }
        widget.onChanged(_opening!);
        _opening = null;
        node.unfocus();
        return KeyEventResult.handled;
      },
      child: SizedBox(
        width: widget.width,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.caption case final caption?) ...[
              AppText(
                caption,
                style: TextStyle(
                  color: context.surface.textSecondary,
                  fontSize: 21,
                ),
              ),
              const SizedBox(height: 8),
            ],
            for (var row = 0; row < 2; row++) ...[
              if (row != 0) const SizedBox(height: 6),
              Row(
                children: [
                  for (var column = 0; column < 2; column++) ...[
                    if (column != 0) const SizedBox(width: 8),
                    LoopChoiceButton(
                      key: Key(
                        '${widget.keyPrefix}_'
                        '${choices[row * 2 + column].$1}',
                      ),
                      width: (widget.width - 8) / 2,
                      height: 46,
                      fontSize: 21,
                      label: choices[row * 2 + column].$2,
                      selected: selected == row * 2 + column,
                      enabled: widget.enabled,
                      onTap: () => _choose(choices[row * 2 + column].$3),
                    ),
                  ],
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
