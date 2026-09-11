import 'package:flutter/material.dart';
import 'package:fx_catalogue/fx_catalogue.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/model/fx_destination.dart';
import 'package:segno/looper/view/fx/fx_editor_parts.dart';
import 'package:segno/looper/view/fx_editor/fx_block_chip.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_frame.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/theme/theme.dart';

/// The pen's pedal column width, and the gap between two of them.
const double kFxPedalWidth = 286;

/// The pen's gap between two pedal columns.
const double kFxPedalGap = 26;

/// One rack, opened in place (accepted design, `01 Connected pedal editor`):
/// its pedals side by side with a plain cable between them, each pedal's own
/// controls beneath its artwork, and the rack's channel handling in the footer.
///
/// **Every pedal's controls are visible under that pedal.** The accepted design
/// removed the list-then-dialog hierarchy: there is no effect-selection step
/// inside a rack, and no More/Less. A column with more controls than fit
/// scrolls on its own, and the chain scrolls sideways when there are more
/// pedals than fit.
class FxRackEditor extends StatelessWidget {
  /// Creates an [FxRackEditor].
  const FxRackEditor({
    required this.group,
    required this.destination,
    required this.destinationLabel,
    required this.edits,
    required this.onBack,
    required this.onOptions,
    required this.onSavePreset,
    required this.onAddEffect,
    super.key,
  });

  /// The rack being edited.
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

  /// Opens rename, reorder and removal for this rack.
  final VoidCallback onOptions;

  /// Saves the rack as a reusable sound.
  final VoidCallback onSavePreset;

  /// Adds one more pedal to this rack.
  final VoidCallback onAddEffect;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final entries = group.entries;
    return Material(
      type: MaterialType.transparency,
      child: LoopSettingsFrame(
        crumb: l10n.fxAddCrumb(destinationLabel),
        title: group.rack?.name ?? '',
        onBack: onBack,
        onStage: () => Navigator.popUntil(context, (route) => route.isFirst),
        children: [
          Positioned(
            // The pen's row is right-aligned inside the titlebar, with the
            // rack's pedal assignment ahead of these four. That chip belongs
            // to the pedal-binding surface, which is not built; the four that
            // are keep the pen's own right edge rather than sliding left into
            // the gap it would have left.
            left: 1140,
            top: 32,
            child: _RackActions(
              enabled: group.anyEnabled,
              onToggle: () {
                // A rack's power is every pedal's power. See the editor's own
                // note: this build has no rack-level bypass bit, so turning a
                // rack back on turns every pedal on.
                final on = !group.anyEnabled;
                for (var i = group.start; i < group.end; i++) {
                  edits.setEnabled(i, enabled: on);
                }
              },
              onOptions: onOptions,
              onSavePreset: onSavePreset,
              onAddEffect: onAddEffect,
            ),
          ),
          Positioned(
            left: 36,
            top: 124,
            right: 36,
            height: 650,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < entries.length; i++) ...[
                    if (i > 0) _Cable(key: Key('fx_pedal_cable_$i')),
                    FxPedalColumn(
                      key: Key('fx_pedal_${entries[i].slotId ?? i}'),
                      effect: entries[i],
                      onTogglePower: () => edits.setEnabled(
                        group.start + i,
                        enabled: !entries[i].enabled,
                      ),
                      onParam: (param, value) =>
                          edits.setParam(group.start + i, param, value),
                    ),
                  ],
                ],
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

/// The plain line between two pedals. No arrowhead: the order of the columns
/// is what says which way the signal goes.
class _Cable extends StatelessWidget {
  const _Cable({super.key});

  @override
  Widget build(BuildContext context) => SizedBox(
    width: kFxPedalGap,
    height: 650,
    child: Align(
      alignment: const Alignment(0, -0.45),
      child: Container(height: 3, color: context.surface.borderStrong),
    ),
  );
}

/// The titlebar's own row: the rack's bypass, its options, Save preset and
/// Add effect.
class _RackActions extends StatelessWidget {
  const _RackActions({
    required this.enabled,
    required this.onToggle,
    required this.onOptions,
    required this.onSavePreset,
    required this.onAddEffect,
  });

  final bool enabled;
  final VoidCallback onToggle;
  final VoidCallback onOptions;
  final VoidCallback onSavePreset;
  final VoidCallback onAddEffect;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Row(
      children: [
        LoopOutlinedButton(
          key: const Key('fx_rack_bypass'),
          width: 133,
          radius: 8,
          tone: enabled ? LoopButtonTone.accent : LoopButtonTone.raised,
          leadingIcon: LucideIcons.power,
          label: l10n.fxBypassRack,
          onTap: onToggle,
        ),
        const SizedBox(width: 12),
        LoopOutlinedButton(
          key: const Key('fx_rack_options'),
          width: 189,
          radius: 8,
          label: l10n.fxRackOptions,
          onTap: onOptions,
        ),
        const SizedBox(width: 14),
        LoopOutlinedButton(
          key: const Key('fx_rack_save'),
          width: 179,
          radius: 8,
          label: l10n.fxSavePreset,
          onTap: onSavePreset,
        ),
        const SizedBox(width: 13),
        LoopOutlinedButton(
          key: const Key('fx_rack_add'),
          width: 204,
          radius: 8,
          tone: LoopButtonTone.accent,
          leadingIcon: LucideIcons.plus,
          label: l10n.fxAddEffect,
          onTap: onAddEffect,
        ),
      ],
    );
  }
}

/// One pedal in the rack: its power and name, its artwork, and its own
/// controls beneath.
class FxPedalColumn extends StatefulWidget {
  /// Creates an [FxPedalColumn].
  const FxPedalColumn({
    required this.effect,
    required this.onTogglePower,
    required this.onParam,
    super.key,
  });

  /// The module.
  final TrackEffect effect;

  /// Flips this pedal's own enabled bit.
  final VoidCallback onTogglePower;

  /// Reports a new value for one of its parameters.
  final void Function(int param, double value) onParam;

  @override
  State<FxPedalColumn> createState() => _FxPedalColumnState();
}

class _FxPedalColumnState extends State<FxPedalColumn> {
  /// Its own controller, so each column's parameter list keeps its place: the
  /// accepted design says a power change or an encoder edit preserves the
  /// chain's position, and scrolling is local to the pedal.
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final effect = widget.effect;
    final built = effect is BuiltInEffect ? effect : null;
    final name = fxPedalName(l10n, effect);
    final art = effect.module == null ? null : fxModuleArt(effect.module!);
    final params = built?.type.params ?? const <TrackEffectParam>[];
    return SizedBox(
      width: kFxPedalWidth,
      height: 650,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 10),
          _PedalTitle(
            key: Key('fx_pedal_power_${effect.slotId ?? name}'),
            name: name,
            enabled: effect.enabled,
            onTap: widget.onTogglePower,
          ),
          const SizedBox(height: 18),
          SizedBox(
            height: 180,
            child: Opacity(
              opacity: effect.enabled ? 1 : surface.disabledOpacity,
              child: art == null
                  ? _mark(surface, lit: effect.enabled)
                  : Image.asset(
                      art,
                      package: FxCatalogueLoader.package,
                      fit: BoxFit.contain,
                      errorBuilder: (_, _, _) =>
                          _mark(surface, lit: effect.enabled),
                    ),
            ),
          ),
          const SizedBox(height: 18),
          Expanded(
            child: params.isEmpty
                // A pedal this build cannot process keeps its name and its
                // picture and says so, rather than offering controls that
                // would reach nothing.
                ? Align(
                    alignment: Alignment.topLeft,
                    child: AppText(
                      l10n.fxModuleUnavailable,
                      key: const Key('fx_pedal_unavailable'),
                      style: TextStyle(
                        color: surface.textTertiary,
                        fontSize: 18,
                        height: 1.2,
                      ),
                    ),
                  )
                // A persistent scrollbar, not one that fades: the accepted
                // design keeps per-pedal parameter scrolling AND a separated
                // scrollbar, so a column with more controls than fit says so
                // while standing still.
                : Scrollbar(
                    controller: _scroll,
                    thumbVisibility: true,
                    child: SingleChildScrollView(
                      controller: _scroll,
                      child: Column(
                        // Start, not stretch: the pen gives the controls
                        // 250 of the column's 274 and the scrollbar its own
                        // lane beside them, so a thumb never sits over a
                        // value.
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (var i = 0; i < params.length; i++) ...[
                            if (i > 0) const SizedBox(height: 14),
                            FxParamControl(
                              key: Key('fx_pedal_param_$i'),
                              label: params[i].label,
                              value: built!.params[i],
                              width: 250,
                              note: l10n.fxScaleUnverified,
                              onChanged: (value) => widget.onParam(i, value),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _mark(SurfaceTheme surface, {required bool lit}) => Center(
    child: Icon(
      LucideIcons.audioWaveform,
      size: 48,
      color: lit ? surface.accent : surface.textTertiary,
    ),
  );
}

/// What a pedal is called: the catalogue's own name for the module, falling
/// back to the effect this engine built for it.
String fxPedalName(AppLocalizations l10n, TrackEffect effect) =>
    effect.module ?? fxBlockName(l10n, effect);

/// The pedal's title and power in one control, as the accepted design puts it:
/// power belongs to the title button and nowhere else.
class _PedalTitle extends StatelessWidget {
  const _PedalTitle({
    required this.name,
    required this.enabled,
    required this.onTap,
    super.key,
  });

  final String name;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Semantics(
      button: true,
      toggled: enabled,
      label: context.l10n.fxEffectPower(name),
      child: Material(
        color: enabled ? surface.accentSurface : surface.card,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: SizedBox(
            height: 64,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  LucideIcons.power,
                  size: 28,
                  color: enabled ? surface.accent : surface.textTertiary,
                ),
                const SizedBox(width: 12),
                Flexible(
                  child: AppText(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: enabled
                          ? surface.textPrimary
                          : surface.textTertiary,
                      fontSize: 24,
                      height: 1,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
