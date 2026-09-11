import 'package:flutter/material.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/model/fx_destination.dart';
import 'package:segno/looper/view/fx_editor/fx_block_chip.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_frame.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/theme/theme.dart';

/// Everything one effect's editor can change, dispatched by the page that
/// owns the chain rather than reached from here.
///
/// A record of callbacks rather than a repository handle: this editor is used
/// on five stages whose writes have five different owners, and threading the
/// owner in would put the stage switch inside the editor.
typedef FxEffectEdits = ({
  void Function({required bool enabled}) setEnabled,
  void Function(int param, double value) setParam,
  void Function(FxPlacement placement) setPlacement,
  void Function(FxChannels channels) setChannels,
});

/// One effect, opened in place (accepted design, `02 Single effect`): its
/// artwork, its parameters as direct controls, and the channel-handling
/// footer that carries the Pre/Post switch.
///
/// **Direct controls, not a grid that opens a sheet.** The accepted design
/// removed the generic parameter dialog: available controls are visible under
/// the effect they belong to, and touch moves the actual slider.
class FxEffectEditor extends StatelessWidget {
  /// Creates an [FxEffectEditor].
  const FxEffectEditor({
    required this.effect,
    required this.destination,
    required this.destinationLabel,
    required this.edits,
    required this.onBack,
    super.key,
  });

  /// The entry being edited.
  final TrackEffect effect;

  /// Where it lives, which decides whether placement is the player's to
  /// choose.
  final FxDestination destination;

  /// What the breadcrumb calls that destination.
  final String destinationLabel;

  /// How this editor writes.
  final FxEffectEdits edits;

  /// Leaves the editor.
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final built = effect is BuiltInEffect ? effect as BuiltInEffect : null;
    return Material(
      type: MaterialType.transparency,
      child: LoopSettingsFrame(
        crumb: l10n.fxAddCrumb(destinationLabel),
        title: fxBlockName(l10n, effect),
        onBack: onBack,
        onStage: () => Navigator.popUntil(context, (route) => route.isFirst),
        children: [
          Positioned(
            left: 1170,
            top: 32,
            child: _ChainActions(
              enabled: effect.enabled,
              onToggle: () => edits.setEnabled(enabled: !effect.enabled),
            ),
          ),
          Positioned(
            left: 235,
            top: 124,
            right: 235,
            height: 650,
            child: _Parameters(effect: built, edits: edits),
          ),
          Positioned(
            left: 36,
            top: 798,
            right: 36,
            height: 162,
            child: _ChannelHandling(
              effect: effect,
              destination: destination,
              edits: edits,
            ),
          ),
        ],
      ),
    );
  }
}

/// The titlebar's own row: the effect's bypass, its options and Save preset.
class _ChainActions extends StatelessWidget {
  const _ChainActions({required this.enabled, required this.onToggle});

  final bool enabled;
  final VoidCallback onToggle;

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
        // Rename, reorder and remove, and saving this sound for reuse. Both
        // arrive with the rack options surface; drawn now because the pen
        // draws this row whole and a row that grew a button later would move
        // the two beside it.
        LoopOutlinedButton(
          key: const Key('fx_editor_options'),
          width: 195,
          radius: 8,
          label: l10n.fxEffectOptions,
          onTap: null,
        ),
        const SizedBox(width: 14),
        LoopOutlinedButton(
          key: const Key('fx_editor_save'),
          width: 179,
          radius: 8,
          label: l10n.fxSavePreset,
          onTap: null,
        ),
      ],
    );
  }
}

/// The effect's own controls, two to a row as the pen lays them out.
class _Parameters extends StatelessWidget {
  const _Parameters({required this.effect, required this.edits});

  final BuiltInEffect? effect;
  final FxEffectEdits edits;

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
              _ParamControl(
                key: Key('fx_param_$i'),
                label: params[i].label,
                value: effect.params[i],
                onChanged: (value) => edits.setParam(i, value),
              ),
          ],
        ),
      ),
    );
  }
}

/// One parameter: its name, its value, the slider, and the note that says its
/// real-world scale was never recovered.
class _ParamControl extends StatelessWidget {
  const _ParamControl({
    required this.label,
    required this.value,
    required this.onChanged,
    super.key,
  });

  final String label;
  final double value;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return SizedBox(
      width: 493,
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
            width: 493,
            semanticLabel: label,
            onChanged: onChanged,
          ),
          const SizedBox(height: 14),
          // The accepted design's own words: raw source values are shown
          // WITHOUT invented physical units, and a control whose mapping was
          // never recovered says so rather than printing a number in
          // milliseconds nobody verified.
          AppText(
            context.l10n.fxScaleUnverified,
            style: TextStyle(
              color: surface.textTertiary,
              fontSize: 16,
              height: 1,
            ),
          ),
        ],
      ),
    );
  }
}

/// The footer: placement, the effect's channel handling and its balance.
class _ChannelHandling extends StatelessWidget {
  const _ChannelHandling({
    required this.effect,
    required this.destination,
    required this.edits,
  });

  final TrackEffect effect;
  final FxDestination destination;
  final FxEffectEdits edits;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final channels = effect.channels;
    final mono = channels.output == FxChannelOutput.mono;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Outputs and All tracks omit the switch entirely, because their
        // stage is fixed after their respective mixes and a control that
        // could not move would be a promise the rig cannot keep.
        if (destination.placementIsEditable) ...[
          _Block(
            caption: l10n.fxPlacementCaption,
            hint: effect.placement == FxPlacement.pre
                ? l10n.fxPlacementPreHint
                : l10n.fxPlacementPostHint,
            child: Row(
              children: [
                LoopChoiceButton(
                  key: const Key('fx_placement_pre'),
                  label: l10n.fxPlacementPre,
                  selected: effect.placement == FxPlacement.pre,
                  onTap: () => edits.setPlacement(FxPlacement.pre),
                  width: 76,
                  height: 64,
                  fontSize: 22,
                ),
                const SizedBox(width: 5),
                LoopChoiceButton(
                  key: const Key('fx_placement_post'),
                  label: l10n.fxPlacementPost,
                  selected: effect.placement == FxPlacement.post,
                  onTap: () => edits.setPlacement(FxPlacement.post),
                  width: 87,
                  height: 64,
                  fontSize: 22,
                ),
              ],
            ),
          ),
          const SizedBox(width: 24),
        ],
        _Block(
          caption: l10n.fxEffectInput,
          child: _InputChoice(
            value: channels.input,
            onChanged: (input) =>
                edits.setChannels(channels.copyWith(input: input)),
          ),
        ),
        const SizedBox(width: 24),
        _Block(
          caption: l10n.fxEffectOutput,
          child: Row(
            children: [
              LoopChoiceButton(
                key: const Key('fx_output_stereo'),
                label: l10n.fxChannelStereo,
                selected: !mono,
                onTap: () => edits.setChannels(
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
                onTap: () => edits.setChannels(
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
                edits.setChannels(channels.copyWith(placement: value)),
          ),
        ),
      ],
    );
  }
}

/// One captioned control of the footer, with an optional consequence line.
class _Block extends StatelessWidget {
  const _Block({required this.caption, required this.child, this.hint});

  final String caption;
  final Widget child;
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

/// The effect's input channel handling, as the pen's dropdown.
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
