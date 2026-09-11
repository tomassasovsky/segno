import 'package:flutter/material.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/model/fx_destination.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/theme/theme.dart';

/// Everything an FX editor can change, dispatched by the page that owns the
/// chain rather than reached from here.
///
/// A record of callbacks rather than a repository handle: these editors are
/// used on five stages whose writes have five different owners, and threading
/// the owner in would put the stage switch inside the editor.
///
/// Indices are positions in the WHOLE chain, not in the group being edited, so
/// a rack module and a standalone effect are addressed the same way.
typedef FxEdits = ({
  void Function(int index, {required bool enabled}) setEnabled,
  void Function(int index, int param, double value) setParam,
  void Function(int index, FxChannels channels) setChannels,
  void Function(List<TrackEffect> chain) setChain,
});

/// One parameter: its name, its value, the slider, and the note that says its
/// real-world scale was never recovered.
class FxParamControl extends StatelessWidget {
  /// Creates an [FxParamControl].
  const FxParamControl({
    required this.label,
    required this.value,
    required this.width,
    required this.onChanged,
    this.note,
    super.key,
  });

  /// The parameter's own name.
  final String label;

  /// Its normalized value.
  final double value;

  /// How wide the control is drawn, which differs between the two editors.
  final double width;

  /// Reports a new value.
  final ValueChanged<double> onChanged;

  /// The line under the slider, or `null` for a control that needs none.
  ///
  /// A preset parameter carries the accepted "Scale unverified" note because
  /// its real-world mapping was never recovered. The rack's own level is not
  /// one of those: it is a plain gain this build defines, so a note saying its
  /// scale is unknown would be false.
  final String? note;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return SizedBox(
      width: width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: AppText(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: surface.textPrimary,
                    fontSize: 22,
                    height: 1,
                  ),
                ),
              ),
              AppText(
                value.toStringAsFixed(2),
                style: TextStyle(
                  color: surface.textSecondary,
                  fontFamily: SurfaceTheme.monoFont,
                  fontSize: 20,
                  height: 1,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          LoopSlider(
            value: value,
            width: width,
            semanticLabel: label,
            onChanged: onChanged,
          ),
          if (note case final note?) ...[
            const SizedBox(height: 14),
            AppText(
              note,
              style: TextStyle(
                color: surface.textTertiary,
                fontSize: 16,
                height: 1,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The footer both editors share: placement, the channel handling around the
/// instance, its balance, and — for a rack — its own level.
///
/// It reads and writes the whole GROUP. The engine applies channel handling per
/// entry, so a rack's input choice lands on its first module and its output
/// side on its last; [FxChainGroup.channels] and [fxGroupChannelWrites] are the
/// one statement of that rule.
class FxChannelFooter extends StatelessWidget {
  /// Creates an [FxChannelFooter].
  const FxChannelFooter({
    required this.group,
    required this.destination,
    required this.onPlacement,
    required this.onChannels,
    super.key,
  });

  /// The rack or single effect being edited.
  final FxChainGroup group;

  /// Where it lives, which decides whether placement is the player's to
  /// choose.
  final FxDestination destination;

  /// Moves the whole group to the other stage.
  final ValueChanged<FxPlacement> onPlacement;

  /// Reports the group's new channel handling.
  final ValueChanged<FxChannels> onChannels;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final channels = group.channels;
    final mono = channels.output == FxChannelOutput.mono;
    final isRack = group.isRack;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Outputs and All tracks omit the switch entirely, because their
        // stage is fixed after their respective mixes and a control that
        // could not move would be a promise the rig cannot keep.
        if (destination.placementIsEditable) ...[
          FxBlock(
            caption: l10n.fxPlacementCaption,
            hint: group.placement == FxPlacement.pre
                ? l10n.fxPlacementPreHint
                : l10n.fxPlacementPostHint,
            child: Row(
              children: [
                LoopChoiceButton(
                  key: const Key('fx_placement_pre'),
                  label: l10n.fxPlacementPre,
                  selected: group.placement == FxPlacement.pre,
                  onTap: () => onPlacement(FxPlacement.pre),
                  width: 76,
                  height: 64,
                  fontSize: 22,
                ),
                const SizedBox(width: 5),
                LoopChoiceButton(
                  key: const Key('fx_placement_post'),
                  label: l10n.fxPlacementPost,
                  selected: group.placement == FxPlacement.post,
                  onTap: () => onPlacement(FxPlacement.post),
                  width: 87,
                  height: 64,
                  fontSize: 22,
                ),
              ],
            ),
          ),
          const SizedBox(width: 24),
        ],
        FxBlock(
          caption: isRack ? l10n.fxRackInput : l10n.fxEffectInput,
          child: _InputChoice(
            value: channels.input,
            onChanged: (input) => onChannels(channels.copyWith(input: input)),
          ),
        ),
        const SizedBox(width: 24),
        FxBlock(
          caption: isRack ? l10n.fxRackOutput : l10n.fxEffectOutput,
          child: Row(
            children: [
              LoopChoiceButton(
                key: const Key('fx_output_stereo'),
                label: l10n.fxChannelStereo,
                selected: !mono,
                onTap: () => onChannels(
                  channels.copyWith(output: FxChannelOutput.stereo),
                ),
                width: 109,
                height: 64,
                fontSize: 22,
              ),
              const SizedBox(width: 5),
              LoopChoiceButton(
                key: const Key('fx_output_mono'),
                label: l10n.fxChannelMono,
                selected: mono,
                onTap: () => onChannels(
                  channels.copyWith(output: FxChannelOutput.mono),
                ),
                width: 99,
                height: 64,
                fontSize: 22,
              ),
            ],
          ),
        ),
        const SizedBox(width: 24),
        // Balance on a stereo output, Pan on a mono one — the same control
        // doing two different jobs, so it is named for the job it is doing.
        Expanded(
          child: _BalanceControl(
            label: mono ? l10n.fxPan : l10n.fxBalance,
            value: channels.placement,
            onChanged: (value) =>
                onChannels(channels.copyWith(placement: value)),
          ),
        ),
        // A rack has its own level after its pedals; a single effect does not,
        // which is the pen's own distinction and not an omission.
        if (isRack) ...[
          const SizedBox(width: 24),
          Padding(
            padding: const EdgeInsets.only(top: 21),
            child: FxParamControl(
              key: const Key('fx_rack_level'),
              label: l10n.fxRackLevel,
              value: channels.level,
              width: 250,
              onChanged: (value) => onChannels(channels.copyWith(level: value)),
            ),
          ),
        ],
      ],
    );
  }
}

/// One captioned control of the footer, with an optional consequence line.
class FxBlock extends StatelessWidget {
  /// Creates an [FxBlock].
  const FxBlock({
    required this.caption,
    required this.child,
    this.hint,
    super.key,
  });

  /// What the control is called.
  final String caption;

  /// The control.
  final Widget child;

  /// The one line that says what choosing this does.
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Padding(
      padding: const EdgeInsets.only(top: 21),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppText(
            caption,
            style: TextStyle(
              color: surface.textSecondary,
              fontSize: 18,
              height: 1,
            ),
          ),
          const SizedBox(height: 10),
          child,
          if (hint case final hint?) ...[
            const SizedBox(height: 10),
            AppText(
              hint,
              key: const Key('fx_placement_hint'),
              style: TextStyle(
                color: surface.textTertiary,
                fontSize: 18,
                height: 1,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The instance's input channel handling, as the pen's dropdown.
class _InputChoice extends StatelessWidget {
  const _InputChoice({required this.value, required this.onChanged});

  final FxChannelInput value;
  final ValueChanged<FxChannelInput> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    String label(FxChannelInput input) => switch (input) {
      FxChannelInput.stereo => l10n.fxChannelStereo,
      FxChannelInput.left => l10n.fxChannelLeft,
      FxChannelInput.right => l10n.fxChannelRight,
      FxChannelInput.monoSum => l10n.fxChannelMonoSum,
    };
    return PopupMenuButton<FxChannelInput>(
      key: const Key('fx_input_choice'),
      onSelected: onChanged,
      itemBuilder: (context) => [
        for (final input in FxChannelInput.values)
          PopupMenuItem(value: input, child: AppText(label(input))),
      ],
      child: Container(
        width: 210,
        height: 64,
        decoration: BoxDecoration(
          color: surface.card,
          border: Border.all(color: surface.borderSubtle),
          borderRadius: BorderRadius.circular(6),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 19),
        child: Row(
          children: [
            Expanded(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: AppText(
                  label(value),
                  style: TextStyle(
                    color: surface.textPrimary,
                    fontSize: 22,
                    height: 1,
                  ),
                ),
              ),
            ),
            Icon(
              LucideIcons.chevronDown,
              size: 28,
              color: surface.textSecondary,
            ),
          ],
        ),
      ),
    );
  }
}

/// The balance or pan slider, with its ends named.
class _BalanceControl extends StatelessWidget {
  const _BalanceControl({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  /// What this control is doing right now: Balance on stereo, Pan on mono.
  final String label;

  /// The placement, `-1` (left) .. `1` (right).
  final double value;

  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    return LayoutBuilder(
      builder: (context, constraints) => Padding(
        padding: const EdgeInsets.only(top: 21),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: AppText(
                    label,
                    style: TextStyle(
                      color: surface.textPrimary,
                      fontSize: 22,
                      height: 1,
                    ),
                  ),
                ),
                AppText(
                  value == 0 ? l10n.fxCentre : value.toStringAsFixed(2),
                  key: const Key('fx_balance_readout'),
                  style: TextStyle(
                    color: surface.textSecondary,
                    fontFamily: SurfaceTheme.monoFont,
                    fontSize: 20,
                    height: 1,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            LoopSlider(
              key: const Key('fx_balance'),
              // Stored `-1..1`, driven `0..1`: the slider is a position on a
              // rail and the control is a placement between two sides.
              value: (value + 1) / 2,
              width: constraints.maxWidth,
              semanticLabel: label,
              onChanged: (fraction) => onChanged(fraction * 2 - 1),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                AppText(
                  l10n.fxLeft,
                  style: TextStyle(color: surface.textTertiary, fontSize: 16),
                ),
                AppText(
                  l10n.fxRight,
                  style: TextStyle(color: surface.textTertiary, fontSize: 16),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
