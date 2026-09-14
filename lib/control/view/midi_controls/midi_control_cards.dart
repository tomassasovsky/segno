import 'package:controller_repository/controller_repository.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:segno/control/view/midi_controls/midi_segmented.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/theme/theme.dart';

/// How one thing a mapping drives reads in the editor.
class MidiControlCard {
  /// Creates a [MidiControlCard].
  const MidiControlCard({
    required this.control,
    required this.label,
    required this.available,
  });

  /// The control.
  final MidiControl control;

  /// What it is called.
  final String label;

  /// Whether the rig still has it. A missing one keeps its card, to be
  /// repaired or removed, and is never quietly repointed.
  final bool available;
}

/// The two ends of a parameter's range, as the mapping's behavior names them.
///
/// A Program writes one value, so it has only the high end.
({String? low, String high}) midiRangeCaptions(
  AppLocalizations l10n,
  MidiBehavior behavior, {
  required bool program,
}) {
  if (program) return (low: null, high: l10n.midiRangeValue);
  return switch (behavior) {
    MidiBehavior.continuous || MidiBehavior.trigger => (
      low: l10n.midiRangeFrom,
      high: l10n.midiRangeTo,
    ),
    MidiBehavior.toggle => (
      low: l10n.externalConditionOff,
      high: l10n.externalConditionOn,
    ),
    MidiBehavior.momentary => (
      low: l10n.externalConditionReleased,
      high: l10n.externalConditionHeld,
    ),
  };
}

/// The editor's right column: everything the mapping drives.
class MidiControlCards extends StatelessWidget {
  /// Creates a [MidiControlCards].
  const MidiControlCards({
    required this.cards,
    required this.behavior,
    required this.program,
    required this.onAdd,
    required this.onChange,
    required this.onRemove,
    required this.onRange,
    required this.onTrigger,
    super.key,
  });

  /// The controls, in the order they were added.
  final List<MidiControlCard> cards;

  /// How the mapping behaves, which names a parameter's range.
  final MidiBehavior behavior;

  /// Whether the control is a Program Change, which has no release.
  final bool program;

  /// Starts choosing something to drive.
  final VoidCallback onAdd;

  /// Repoints a parameter.
  final ValueChanged<String> onChange;

  /// Stops driving a control.
  final ValueChanged<String> onRemove;

  /// Moves one end of a parameter's range.
  final void Function(String key, {double? low, double? high}) onRange;

  /// Chooses when an action runs.
  final void Function(String key, MidiEdge trigger) onTrigger;

  /// The pen's column.
  static const Size penSize = Size(1260, 808);

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    return SizedBox.fromSize(
      size: penSize,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 64,
            child: Row(
              children: [
                AppText(
                  l10n.midiControlsHeading,
                  style: TextStyle(color: surface.textPrimary, fontSize: 30),
                ),
                const Spacer(),
                LoopOutlinedButton(
                  key: const Key('midi_add_control'),
                  width: 172,
                  label: l10n.expressionAddControl,
                  onTap: onAdd,
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          Expanded(
            child: cards.isEmpty
                ? Padding(
                    padding: const EdgeInsets.symmetric(vertical: 46),
                    child: AppText(
                      l10n.midiControlsEmpty,
                      key: const Key('midi_controls_empty'),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: surface.textTertiary,
                        fontSize: 25,
                      ),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.all(5),
                    itemCount: cards.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 20),
                    itemBuilder: (context, index) => _Card(
                      card: cards[index],
                      captions: midiRangeCaptions(
                        l10n,
                        behavior,
                        program: program,
                      ),
                      program: program,
                      onChange: onChange,
                      onRemove: onRemove,
                      onRange: onRange,
                      onTrigger: onTrigger,
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({
    required this.card,
    required this.captions,
    required this.program,
    required this.onChange,
    required this.onRemove,
    required this.onRange,
    required this.onTrigger,
  });

  final MidiControlCard card;
  final ({String? low, String high}) captions;
  final bool program;
  final ValueChanged<String> onChange;
  final ValueChanged<String> onRemove;
  final void Function(String key, {double? low, double? high}) onRange;
  final void Function(String key, MidiEdge trigger) onTrigger;

  static const double _rangeWidth = 578;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final control = card.control;
    final key = control.key;
    return Container(
      key: Key('midi_control_$key'),
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 22),
      decoration: BoxDecoration(
        color: surface.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: surface.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 64,
            child: Row(
              children: [
                Expanded(
                  child: AppText(
                    card.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: surface.textPrimary, fontSize: 25),
                  ),
                ),
                if (control is MidiParameterControl) ...[
                  const SizedBox(width: 18),
                  LoopOutlinedButton(
                    key: Key('midi_control_change_$key'),
                    width: 213,
                    label: card.available
                        ? l10n.expressionChangeControl
                        : l10n.midiRepairControl,
                    onTap: () => onChange(key),
                  ),
                ],
                const SizedBox(width: 18),
                Semantics(
                  button: true,
                  label: l10n.a11yMidiRemoveControl(card.label),
                  excludeSemantics: true,
                  child: InkWell(
                    key: Key('midi_control_remove_$key'),
                    onTap: () => onRemove(key),
                    borderRadius: BorderRadius.circular(8),
                    child: SizedBox.square(
                      dimension: 54,
                      child: Icon(
                        LucideIcons.x,
                        size: 28,
                        color: surface.textPrimary,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          switch (control) {
            MidiParameterControl(:final low, :final high) => Row(
              children: [
                if (captions.low case final lowCaption?) ...[
                  _Range(
                    key: Key('midi_range_low_$key'),
                    caption: lowCaption,
                    value: low,
                    width: _rangeWidth,
                    semanticLabel: '${card.label} $lowCaption',
                    enabled: card.available,
                    onChanged: (value) => onRange(key, low: value),
                  ),
                  const SizedBox(width: 36),
                ],
                _Range(
                  key: Key('midi_range_high_$key'),
                  caption: captions.high,
                  value: high,
                  width: _rangeWidth,
                  semanticLabel: '${card.label} ${captions.high}',
                  enabled: card.available,
                  onChanged: (value) => onRange(key, high: value),
                ),
              ],
            ),
            MidiActionControl(:final trigger) => Row(
              children: [
                AppText(
                  l10n.midiWhen,
                  style: TextStyle(color: surface.textPrimary, fontSize: 21),
                ),
                const SizedBox(width: 28),
                MidiSegmented<MidiEdge>(
                  keyPrefix: 'midi_trigger_$key',
                  semanticLabel: '${card.label} ${l10n.midiWhen}',
                  segmentWidth: 130,
                  segmentHeight: 58,
                  selected: trigger,
                  segments: [
                    MidiSegment(value: MidiEdge.press, label: l10n.midiPressed),
                    if (!program)
                      MidiSegment(
                        value: MidiEdge.release,
                        label: l10n.midiReleased,
                      ),
                  ],
                  onSelected: (edge) => onTrigger(key, edge),
                ),
              ],
            ),
          },
        ],
      ),
    );
  }
}

/// One end of a parameter's range: its caption and value over a slider.
class _Range extends StatelessWidget {
  const _Range({
    required this.caption,
    required this.value,
    required this.width,
    required this.semanticLabel,
    required this.enabled,
    required this.onChanged,
    super.key,
  });

  final String caption;
  final double value;
  final double width;
  final String semanticLabel;
  final bool enabled;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return SizedBox(
      width: width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 27,
            child: Row(
              children: [
                AppText(
                  caption,
                  style: TextStyle(color: surface.textSecondary, fontSize: 21),
                ),
                const Spacer(),
                AppText(
                  '${(value * 100).round()}%',
                  style: TextStyle(
                    color: surface.textPrimary,
                    fontSize: 21,
                    fontFamily: SurfaceTheme.monoFont,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          LoopSlider(
            value: value,
            width: width,
            semanticLabel: semanticLabel,
            // Moving a value writes the draft, never the parameter: editing a
            // mapping dispatches nothing.
            enabled: enabled,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}
