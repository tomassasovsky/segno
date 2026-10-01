import 'package:flutter/material.dart';
import 'package:fx_catalogue/fx_catalogue.dart';
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

/// The artwork frame inside a card, at the pen's fixed height.
const double kFxCardArtHeight = 138;

/// The asset path for a rack artwork slug, in the catalogue package.
String fxRackArtAsset(String slug) => 'assets/images/footswitch/$slug.png';

/// One destination's chain, drawn as the pen's horizontal strip: a card per
/// RACK (or per standalone single effect) in processing order, plain lines
/// between consecutive cards, and a break where the Pre run hands over to the
/// Post run.
///
/// A card is a group, not an entry. The accepted chain is built out of racks —
/// named groups of pedals the player adds and moves as one thing — so a rack of
/// six pedals is one card here and six pedals inside its own editor.
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

  /// Flips a whole group's power, by its index among the groups.
  final void Function(int group, {required bool enabled}) onTogglePower;

  /// Opens one group's editor, by its index among the groups.
  final void Function(int group) onOpen;

  /// Whether the chain as a whole is engaged. A switched-off chain dims every
  /// card without touching the per-entry bits it will come back to.
  final bool chainEnabled;

  /// The strip's scroll position, so the page can keep each destination's
  /// place across a context switch.
  final ScrollController? controller;

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
    final groups = fxChainGroups(entries);
    final preGroups = groups
        .where((g) => g.placement == FxPlacement.pre)
        .length;
    return SingleChildScrollView(
      controller: controller,
      scrollDirection: Axis.horizontal,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < groups.length; i++) ...[
            if (i > 0) _gapBefore(i, preGroups, surface),
            _FxChainCard(
              key: Key('fx_card_${fxGroupId(groups[i])}'),
              group: groups[i],
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
  Widget _gapBefore(int i, int preGroups, SurfaceTheme surface) {
    final isBreak = showPlacement && i == preGroups && preGroups > 0;
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

/// One group in the strip: its placement tag, its artwork frame, its name, and
/// the status line carrying its pedal assignment and its power.
class _FxChainCard extends StatelessWidget {
  const _FxChainCard({
    required this.group,
    required this.showPlacement,
    required this.dimmed,
    required this.onTogglePower,
    required this.onOpen,
    super.key,
  });

  final FxChainGroup group;
  final bool showPlacement;
  final bool dimmed;
  final void Function({required bool enabled}) onTogglePower;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final l10n = context.l10n;
    final name = fxGroupName(l10n, group);
    // The pen's two card states: an engaged card takes the accent surface and
    // border, a bypassed one the plain card and a muted edge. Bypassed is
    // drawn, not hidden — a chain reads as a chain whether or not every link
    // is passing signal.
    final lit = group.anyEnabled && !dimmed;
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
                              group.placement == FxPlacement.pre
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
                  FxRackArt(slug: group.rack?.art, lit: lit),
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
                  const Spacer(),
                  SizedBox(
                    height: 28,
                    child: Row(
                      children: [
                        Expanded(
                          child: AppText(
                            group.isRack
                                ? l10n.fxModuleCount(group.entries.length)
                                : l10n.fxUnassigned,
                            style: TextStyle(
                              color: surface.textTertiary,
                              fontSize: 18,
                              height: 1,
                            ),
                          ),
                        ),
                        _PowerButton(
                          key: Key('fx_power_${fxGroupId(group)}'),
                          on: group.anyEnabled,
                          name: name,
                          onTap: () =>
                              onTogglePower(enabled: !group.anyEnabled),
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

/// A rack's artwork frame at the pen's fixed height.
///
/// Falls back to the app's own mark when the group is a single effect (which
/// has no rack artwork), when the slug names a file this build did not ship,
/// and in a widget test, which has no asset bundle at all.
class FxRackArt extends StatelessWidget {
  /// Creates an [FxRackArt].
  const FxRackArt({required this.slug, required this.lit, super.key});

  /// The catalogue artwork slug, or `null` for a single effect.
  final String? slug;

  /// Whether the group is audible, which the fallback mark follows.
  final bool lit;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final slug = this.slug;
    return SizedBox(
      height: kFxCardArtHeight,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: surface.cardHigh,
          borderRadius: BorderRadius.circular(6),
        ),
        child: slug == null
            ? _fallback(surface)
            : Image.asset(
                fxRackArtAsset(slug),
                package: FxCatalogueLoader.package,
                fit: BoxFit.contain,
                errorBuilder: (_, _, _) => _fallback(surface),
              ),
      ),
    );
  }

  Widget _fallback(SurfaceTheme surface) => Center(
    child: Icon(
      LucideIcons.audioWaveform,
      size: 56,
      color: lit ? surface.accent : surface.textTertiary,
    ),
  );
}

/// What a group is called: the rack's own name, or the single effect's.
String fxGroupName(AppLocalizations l10n, FxChainGroup group) =>
    group.rack?.name ?? fxBlockName(l10n, group.entries.first);

/// The card's power: the one owner of a group's audibility.
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
