import 'package:flutter/material.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/model/fx_destination.dart';
import 'package:segno/looper/view/fx/fx_editor_parts.dart';
import 'package:segno/looper/view/fx_editor/fx_block_chip.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_frame.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';

/// One standalone effect, opened in place (accepted design, `02 Single
/// effect`): its parameters as direct controls, and the channel-handling
/// footer that carries the Pre/Post switch.
///
/// **Direct controls, not a grid that opens a sheet.** The accepted design
/// removed the generic parameter dialog: available controls are visible under
/// the effect they belong to, and touch moves the actual slider.
class FxEffectEditor extends StatelessWidget {
  /// Creates an [FxEffectEditor].
  const FxEffectEditor({
    required this.group,
    required this.destination,
    required this.destinationLabel,
    required this.edits,
    required this.onBack,
    required this.onOptions,
    required this.onSavePreset,
    super.key,
  });

  /// The one-entry group being edited.
  final FxChainGroup group;

  /// Where it lives, which decides whether placement is the player's to
  /// choose.
  final FxDestination destination;

  /// What the breadcrumb calls that destination.
  final String destinationLabel;

  /// How this editor writes.
  final FxEdits edits;

  /// Leaves the editor.
  final VoidCallback onBack;

  /// Opens rename and removal for this effect.
  final VoidCallback onOptions;

  /// Saves this effect as a reusable sound.
  final VoidCallback onSavePreset;

  TrackEffect get _effect => group.entries.first;

  int get _index => group.start;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final effect = _effect;
    final built = effect is BuiltInEffect ? effect : null;
    return Material(
      type: MaterialType.transparency,
      child: LoopSettingsFrame(
        crumb: l10n.fxAddCrumb(destinationLabel),
        title: fxBlockName(l10n, effect),
        onBack: onBack,
        onStage: () => Navigator.popUntil(context, (route) => route.isFirst),
        children: [
          Positioned(
            // Right-aligned inside the titlebar as the pen draws it. The
            // effect's pedal assignment sits ahead of these three there; it
            // belongs to the pedal-binding surface, which is not built.
            left: 1343,
            top: 32,
            child: _ChainActions(
              enabled: effect.enabled,
              onToggle: () =>
                  edits.setEnabled(_index, enabled: !effect.enabled),
              onOptions: onOptions,
              onSavePreset: onSavePreset,
            ),
          ),
          Positioned(
            left: 235,
            top: 124,
            right: 235,
            height: 650,
            child: _Parameters(
              effect: built,
              index: _index,
              edits: edits,
            ),
          ),
          Positioned(
            left: 36,
            top: 798,
            right: 36,
            height: 162,
            child: FxChannelFooter(
              group: group,
              destination: destination,
              onPlacement: (placement) => edits.setChain(
                fxSetGroupPlacement(
                  group.chain,
                  group.start,
                  group.end,
                  placement,
                ),
              ),
              onChannels: (channels) {
                for (final write in fxGroupChannelWrites(
                  group,
                  channels,
                ).entries) {
                  edits.setChannels(write.key, write.value);
                }
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// The titlebar's own row: the effect's bypass, its options and Save preset.
class _ChainActions extends StatelessWidget {
  const _ChainActions({
    required this.enabled,
    required this.onToggle,
    required this.onOptions,
    required this.onSavePreset,
  });

  final bool enabled;
  final VoidCallback onToggle;
  final VoidCallback onOptions;
  final VoidCallback onSavePreset;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Row(
      children: [
        LoopOutlinedButton(
          key: const Key('fx_editor_bypass'),
          width: 139,
          radius: 8,
          tone: enabled ? LoopButtonTone.accent : LoopButtonTone.raised,
          leadingIcon: LucideIcons.power,
          label: l10n.fxBypassEffect,
          onTap: onToggle,
        ),
        const SizedBox(width: 14),
        LoopOutlinedButton(
          key: const Key('fx_editor_options'),
          width: 195,
          radius: 8,
          label: l10n.fxEffectOptions,
          onTap: onOptions,
        ),
        const SizedBox(width: 14),
        LoopOutlinedButton(
          key: const Key('fx_editor_save'),
          width: 179,
          radius: 8,
          label: l10n.fxSavePreset,
          onTap: onSavePreset,
        ),
      ],
    );
  }
}

/// The effect's own controls, two to a row as the pen lays them out.
class _Parameters extends StatelessWidget {
  const _Parameters({
    required this.effect,
    required this.index,
    required this.edits,
  });

  final BuiltInEffect? effect;
  final int index;
  final FxEdits edits;

  @override
  Widget build(BuildContext context) {
    final effect = this.effect;
    if (effect == null) return const SizedBox.shrink();
    final params = effect.type.params;
    return Align(
      alignment: Alignment.topRight,
      child: SizedBox(
        width: 1050,
        child: Wrap(
          spacing: 58,
          runSpacing: 46,
          children: [
            for (var i = 0; i < params.length; i++)
              FxParamControl(
                key: Key('fx_param_$i'),
                label: params[i].label,
                value: effect.params[i],
                width: 493,
                // The accepted design's own words: raw source values are
                // shown WITHOUT invented physical units, and a control whose
                // mapping was never recovered says so rather than printing a
                // number in milliseconds nobody verified.
                note: context.l10n.fxScaleUnverified,
                onChanged: (value) => edits.setParam(index, i, value),
              ),
          ],
        ),
      ),
    );
  }
}
