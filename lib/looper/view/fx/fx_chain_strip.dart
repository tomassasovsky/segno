import 'package:flutter/material.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/view/fx_editor/fx_block_chip.dart';
import 'package:segno/theme/theme.dart';

/// The pen's rack card geometry (`01 Effects · destinations`, sound-grid).
const double kFxCardWidth = 352;

/// The pen's rack card height.
const double kFxCardHeight = 360;

/// The pen's gap between two cards, which the cable crosses.
const double kFxCardGap = 24;

/// The break the pen draws between the Pre run and the Post run — wider than
/// [kFxCardGap] and with no cable across it, because the loop player sits
/// between the two stages.
const double kFxStageBreak = 72;

/// One destination's chain, drawn as the pen's horizontal strip: a card per
/// effect in processing order, plain lines between consecutive cards, and a
/// break where the Pre run hands over to the Post run.
///
/// **No arrowheads on the connectors.** The owner rejected them twice; the
/// order of the cards is what says which way the signal goes.
///
/// The strip scrolls horizontally and never reorders on its own: dragging is
/// the Reorder surface's job, so a scroll here cannot change what the player
/// hears.
class FxChainStrip extends StatelessWidget {
  /// Creates an [FxChainStrip] over [entries].
  const FxChainStrip({
    required this.entries,
    required this.showPlacement,
    required this.onTogglePower,
    required this.onOpen,
    this.controller,
    this.chainEnabled = true,
    super.key,
  });

  /// The chain, in processing order (Pre entries first).
  final List<TrackEffect> entries;

  /// Whether each card carries its Pre/Post tag.
  ///
  /// Outputs and All tracks omit it because their stage is fixed after their
  /// respective mixes, and a tag there would offer a distinction the player
  /// cannot act on (accepted design, FX 4).
  final bool showPlacement;

  /// Flips one entry's own enabled bit.
  final void Function(int index, {required bool enabled}) onTogglePower;

  /// Opens one entry's editor.
  final void Function(int index) onOpen;

  /// Whether the chain as a whole is engaged. A switched-off chain dims every
  /// card without touching the per-entry bits it will come back to.
  final bool chainEnabled;

  /// The strip's scroll position, so the page can keep each destination's
  /// place across a context switch.
  final ScrollController? controller;

  /// Where the Pre run ends, which is where the break goes.
  int get _preCount => fxPreCount(entries);

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    if (entries.isEmpty) {
      return Align(
        alignment: Alignment.topLeft,
        child: AppText(
          l10n.fxNoEffects,
          key: const Key('fx_chain_empty'),
          style: TextStyle(color: surface.textTertiary, fontSize: 24),
        ),
      );
    }
    return SingleChildScrollView(
      controller: controller,
      scrollDirection: Axis.horizontal,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < entries.length; i++) ...[
            if (i > 0) _gapBefore(i, surface),
            _FxChainCard(
              key: Key('fx_card_${entries[i].slotId ?? i}'),
              effect: entries[i],
              showPlacement: showPlacement,
              dimmed: !chainEnabled,
              onTogglePower: ({required enabled}) =>
                  onTogglePower(i, enabled: enabled),
              onOpen: () => onOpen(i),
            ),
          ],
        ],
      ),
    );
  }

  /// The space before card [i]: the stage break where the Pre run ends, and
  /// otherwise the plain cable.
  Widget _gapBefore(int i, SurfaceTheme surface) {
    final isBreak = showPlacement && i == _preCount && _preCount > 0;
    return SizedBox(
      width: isBreak ? kFxStageBreak : kFxCardGap,
      height: kFxCardHeight,
      child: isBreak
          ? null
          : Center(
              child: Container(
                key: Key('fx_cable_$i'),
                height: 3,
                color: surface.borderStrong,
              ),
            ),
    );
  }
}

/// One effect in the strip: its placement tag, its artwork frame, its name,
/// and the status line carrying its pedal assignment and its power.
class _FxChainCard extends StatelessWidget {
  const _FxChainCard({
    required this.effect,
    required this.showPlacement,
    required this.dimmed,
    required this.onTogglePower,
    required this.onOpen,
    super.key,
  });

  final TrackEffect effect;
  final bool showPlacement;
  final bool dimmed;
  final void Function({required bool enabled}) onTogglePower;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final l10n = context.l10n;
    final name = fxBlockName(l10n, effect);
    // The pen's two card states: an engaged card takes the accent surface and
    // border, a bypassed one the plain card and a dashed edge. Bypassed is
    // drawn, not hidden — a chain reads as a chain whether or not every link
    // is passing signal.
    final lit = effect.enabled && !dimmed;
    return Opacity(
      opacity: dimmed ? surface.disabledOpacity : 1,
      child: Material(
        color: lit ? surface.accentSurface : surface.card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(
            color: lit ? surface.accent : surface.borderSubtle,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onOpen,
          child: SizedBox(
            width: kFxCardWidth,
            height: kFxCardHeight,
            child: Padding(
              padding: const EdgeInsets.all(17),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    height: 26,
                    child: showPlacement
                        ? Align(
                            alignment: Alignment.centerLeft,
                            child: AppText(
                              effect.placement == FxPlacement.pre
                                  ? l10n.fxPlacementPre
                                  : l10n.fxPlacementPost,
                              style: TextStyle(
                                color: surface.textSecondary,
                                fontSize: 20,
                                height: 1,
                              ),
                            ),
                          )
                        : null,
                  ),
                  const SizedBox(height: 12),
                  // The artwork frame. The original Looper X rack art is not
                  // in this repository, so the frame carries the effect's own
                  // identity rather than a placeholder picture pretending to
                  // be one.
                  Expanded(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: surface.cardHigh,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Center(
                        child: Icon(
                          LucideIcons.audioWaveform,
                          size: 56,
                          color: lit ? surface.accent : surface.textTertiary,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 11),
                  SizedBox(
                    height: 60,
                    child: Align(
                      alignment: Alignment.topLeft,
                      child: AppText(
                        name,
                        maxLines: 2,
                        style: TextStyle(
                          color: surface.textPrimary,
                          fontSize: 28,
                          height: 1.1,
                        ),
                      ),
                    ),
                  ),
                  SizedBox(
                    height: 28,
                    child: Row(
                      children: [
                        Expanded(
                          child: AppText(
                            l10n.fxUnassigned,
                            style: TextStyle(
                              color: surface.textTertiary,
                              fontSize: 18,
                              height: 1,
                            ),
                          ),
                        ),
                        _PowerButton(
                          key: Key('fx_power_${effect.slotId ?? name}'),
                          on: effect.enabled,
                          name: name,
                          onTap: () => onTogglePower(enabled: !effect.enabled),
                        ),
                      ],
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
}

/// The card's power: the one owner of an effect's enabled bit.
///
/// The accepted design puts power on the title/power control and nowhere
/// else: the duplicate Off/On parameter row the earlier study drew is exactly
/// what this replaces.
class _PowerButton extends StatelessWidget {
  const _PowerButton({
    required this.on,
    required this.name,
    required this.onTap,
    super.key,
  });

  final bool on;
  final String name;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Semantics(
      button: true,
      toggled: on,
      label: context.l10n.fxEffectPower(name),
      child: InkResponse(
        onTap: onTap,
        radius: 22,
        child: Icon(
          LucideIcons.power,
          size: 28,
          color: on ? surface.accent : surface.textTertiary,
        ),
      ),
    );
  }
}
