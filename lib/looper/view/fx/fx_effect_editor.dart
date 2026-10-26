import 'package:flutter/material.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/model/fx_destination.dart';
import 'package:segno/looper/view/fx/fx_chain_power.dart';
import 'package:segno/looper/view/fx/fx_editor_parts.dart';
import 'package:segno/looper/view/fx_editor/fx_block_chip.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_frame.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/theme/theme.dart';

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
    required this.onStage,
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

  /// Leaves the Effects route for Stage.
  final VoidCallback onStage;

  /// Leaves the editor.
  final VoidCallback onBack;

  /// Opens rename and removal for this effect.
  final VoidCallback onOptions;

  /// Saves this effect as a reusable sound.
  final VoidCallback onSavePreset;

  TrackEffect get _effect => group.entries.first;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final effect = _effect;
    final built = effect is BuiltInEffect ? effect : null;
    final address = destination.address;
    final chainOn = address == null || watchFxChainEnabled(context, address);
    final band = chainOn ? 0.0 : FxChainOffNotice.height + 12;
    return Material(
      type: MaterialType.transparency,
      child: LoopSettingsFrame(
        crumb: l10n.fxAddCrumb(destinationLabel),
        title: fxBlockName(l10n, effect),
        // Ends before the Effects power control (#1452), about 270 wide and
        // 24 short of Track Solo.
        titleRight: 1920 - 1130 + 24 + 300,
        onBack: onBack,
        onStage: onStage,
        children: [
          // The chain's own power, ahead of Track Solo and the effect's own
          // switch (#1452).
          if (address != null)
            Positioned(
              right: kLoopPenSize.width - 1130 + 24,
              top: 32,
              child: FxChainPower(
                address: address,
                onChanged: (enabled) => edits.setChainEnabled(enabled: enabled),
              ),
            ),
          // The Track Solo chip keeps the rack editor's distance ahead of the
          // bypass (the pen draws it on the rack editor only).
          Positioned(
            left: 1130,
            top: 52,
            child: FxTrackSolo(destination: destination),
          ),
          Positioned(
            // Right-aligned inside the titlebar as the pen draws it. The
            // effect's pedal assignment sits ahead of these three there; it
            // belongs to the pedal-binding surface, which is not built.
            left: 1343,
            top: 32,
            child: _ChainActions(
              enabled: effect.enabled,
              onToggle: () {
                final id = effect.slotId;
                if (id != null) {
                  edits.setEnabled(id, enabled: !effect.enabled);
                }
              },
              onOptions: onOptions,
              onSavePreset: onSavePreset,
            ),
          ),
          if (!chainOn)
            Positioned(
              left: 36,
              top: 124,
              right: 36,
              child: FxChainOffNotice(
                message: l10n.fxChainOffHere,
                onTurnOn: () => edits.setChainEnabled(enabled: true),
              ),
            ),
          Positioned(
            left: 235,
            top: 124 + band,
            right: 235,
            height: 650 - band,
            child: Opacity(
              key: const Key('fx_effect_parameters'),
              opacity: chainOn ? 1 : context.surface.disabledOpacity,
              child: _Parameters(
                effect: built,
                slotId: effect.slotId,
                edits: edits,
              ),
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
              onPlacement: (placement) =>
                  edits.setPlacement(fxGroupId(group), placement),
              onChannels: (channels) =>
                  edits.setChannels(fxGroupId(group), channels),
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
    required this.slotId,
    required this.edits,
  });

  final BuiltInEffect? effect;
  final String? slotId;
  final FxEdits edits;

  @override
  Widget build(BuildContext context) {
    final effect = this.effect;
    if (effect == null) return const SizedBox.shrink();
    final controls = fxEntryControls(effect);
    return Align(
      alignment: Alignment.topRight,
      child: SizedBox(
        width: 1050,
        child: Wrap(
          spacing: 58,
          runSpacing: 46,
          children: [
            for (var j = 0; j < controls.params.length; j++)
              FxBuiltInParamControl(
                key: Key('fx_param_${controls.params[j]}'),
                effect: effect,
                index: controls.params[j],
                labelKey: controls.keys[j],
                width: 493,
                onChanged: (value) {
                  final id = slotId;
                  if (id != null) {
                    edits.setParam(id, controls.params[j], value);
                  }
                },
              ),
          ],
        ),
      ),
    );
  }
}
