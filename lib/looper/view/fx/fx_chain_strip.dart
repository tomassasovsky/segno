import 'package:flutter/material.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/model/fx_art.dart';
import 'package:segno/looper/model/fx_names.dart';
import 'package:segno/looper/view/fx/fx_art_view.dart';
import 'package:segno/theme/theme.dart';

/// The pen's rack card geometry (`01 Effects · destinations`, sound-grid).
const double kFxCardWidth = 352;

/// The pen's rack card height.
const double kFxCardHeight = 360;

/// The pen's gap between two cards, which the cable crosses.
const double kFxCardGap = 24;

/// A single effect's card: half a rack card's column, so two singles and the
/// cable between them span one rack card, and within a run (Pre or Post)
/// every card starts on the column grid the rack cards set (#1754). The
/// Pre/Post break ([kFxStageBreak]) is wider than a gap, so the Post run's
/// grid is shifted by it, as it was for rack cards.
const double kFxSingleCardWidth = (kFxCardWidth - kFxCardGap) / 2;

/// The break the pen draws between the Pre run and the Post run — wider than
/// [kFxCardGap] and with no cable across it, because the loop player sits
/// between the two stages.
const double kFxStageBreak = 72;

/// The artwork frame inside a card, at the pen's fixed height.
const double kFxCardArtHeight = 138;

/// One destination's chain, drawn as the pen's horizontal strip: a card per
/// RACK and a half-width card per standalone single effect (#1754), in
/// processing order, plain lines between consecutive cards, and a break where
/// the Pre run hands over to the Post run.
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
    this.assignments = const {},
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

  /// What the controls assigned to each effect and each rack are called
  /// (`fxAssignmentNames`), by [fxGroupId]: a single effect's slot id or a
  /// rack's id. Each card prints its own on its assignment line; one missing
  /// here is unassigned.
  final Map<String, List<String>> assignments;

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
            if (i > 0)
              _ChainGap(
                index: i,
                stageBreak: showPlacement && i == preGroups && preGroups > 0,
              ),
            _FxChainCard(
              key: Key('fx_card_${fxGroupId(groups[i])}'),
              group: groups[i],
              showPlacement: showPlacement,
              assignedTo: assignments[fxGroupId(groups[i])] ?? const [],
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
}

/// The space before card [index]: the stage break where the Pre run ends,
/// and otherwise the plain cable.
class _ChainGap extends StatelessWidget {
  const _ChainGap({required this.index, required this.stageBreak});

  final int index;

  /// Whether the Pre run ends here.
  final bool stageBreak;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: stageBreak ? kFxStageBreak : kFxCardGap,
    height: kFxCardHeight,
    child: stageBreak
        ? null
        : Center(
            child: Container(
              key: Key('fx_cable_$index'),
              height: 3,
              color: context.surface.borderStrong,
            ),
          ),
  );
}

/// One group in the strip: a rack's card ([_RackCardBody]) or a single
/// effect's narrower card ([_SingleCardBody], #1754) in the same frame, with
/// the same states: an engaged card takes the accent surface and border, a
/// bypassed one the plain card and a muted edge, and a switched-off chain
/// dims it. Bypassed is drawn, not hidden — a chain reads as a chain whether
/// or not every link is passing signal.
class _FxChainCard extends StatelessWidget {
  const _FxChainCard({
    required this.group,
    required this.showPlacement,
    required this.assignedTo,
    required this.dimmed,
    required this.onTogglePower,
    required this.onOpen,
    super.key,
  });

  final FxChainGroup group;
  final bool showPlacement;
  final List<String> assignedTo;
  final bool dimmed;
  final void Function({required bool enabled}) onTogglePower;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final lit = group.audible && !dimmed;
    final power = _PowerButton(
      key: Key('fx_power_${fxGroupId(group)}'),
      on: group.isOn,
      name: fxGroupName(context.l10n, group),
      onTap: () => onTogglePower(enabled: !group.isOn),
    );
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
            width: group.isRack ? kFxCardWidth : kFxSingleCardWidth,
            height: kFxCardHeight,
            child: group.isRack
                ? _RackCardBody(
                    group: group,
                    showPlacement: showPlacement,
                    assignedTo: assignedTo,
                    lit: lit,
                    power: power,
                  )
                : _SingleCardBody(
                    group: group,
                    showPlacement: showPlacement,
                    assignedTo: assignedTo,
                    lit: lit,
                    power: power,
                  ),
          ),
        ),
      ),
    );
  }
}

/// The inset of a card's placement line from its top and of its status line
/// from its bottom: the rack card's, which the single card keeps so a mixed
/// row's lines read across.
const double _kCardInset = 17;

/// The height of a rack card's placement line.
const double _kPlacementHeight = 26;

/// The height of a card's status line, which carries the power.
const double _kStatusHeight = 28;

/// The Pre/Post tag of a group, as both cards print it.
class _PlacementTag extends StatelessWidget {
  const _PlacementTag({required this.placement});

  final FxPlacement placement;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AppText(
      placement == FxPlacement.pre ? l10n.fxPlacementPre : l10n.fxPlacementPost,
      style: TextStyle(
        color: context.surface.textSecondary,
        fontSize: 20,
        height: 1,
      ),
    );
  }
}

/// A rack card's inside: its placement tag, its artwork frame, its name, the
/// controls acting on the rack or its effects (#1760), and the status line
/// carrying its pedal count and its power.
class _RackCardBody extends StatelessWidget {
  const _RackCardBody({
    required this.group,
    required this.showPlacement,
    required this.assignedTo,
    required this.lit,
    required this.power,
  });

  final FxChainGroup group;
  final bool showPlacement;

  /// What the controls acting on the rack or its effects are called, or
  /// none.
  final List<String> assignedTo;
  final bool lit;
  final Widget power;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final l10n = context.l10n;
    return Padding(
      padding: const EdgeInsets.all(_kCardInset),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: _kPlacementHeight,
            child: showPlacement
                ? Align(
                    alignment: Alignment.centerLeft,
                    child: _PlacementTag(placement: group.placement),
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
                fxGroupName(l10n, group),
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
            height: _kStatusHeight,
            child: _AssignmentLine(assignedTo: assignedTo),
          ),
          SizedBox(
            height: _kStatusHeight,
            child: Row(
              children: [
                Expanded(
                  child: AppText(
                    l10n.fxModuleCount(group.entries.length),
                    style: TextStyle(
                      color: surface.textTertiary,
                      fontSize: 18,
                      height: 1,
                    ),
                  ),
                ),
                power,
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A single effect's inside (#1754): the placement and the power on a line
/// level with a rack card's placement line, the pedal drawn as large as the
/// card allows, and the assignment on a line level with a rack card's status
/// line. No title: the pedal prints the effect's name (the owner's call), and
/// the card carries it for a screen reader. An effect with no pedal (a plugin)
/// prints its name under the app's mark instead.
class _SingleCardBody extends StatelessWidget {
  const _SingleCardBody({
    required this.group,
    required this.showPlacement,
    required this.assignedTo,
    required this.lit,
    required this.power,
  });

  final FxChainGroup group;
  final bool showPlacement;

  /// What the controls assigned to the effect are called, or none.
  final List<String> assignedTo;
  final bool lit;
  final Widget power;

  @override
  Widget build(BuildContext context) {
    final spacing = context.spacing;
    final l10n = context.l10n;
    final pedal = fxEntryArt(group.entries.first, live: false);
    final name = fxGroupName(l10n, group);
    final fallback = _NamedFallbackMark(name: name, lit: lit);
    return Semantics(
      label: name,
      child: Padding(
        // The header line is a status line's height, centred where a rack
        // card's placement line is centred.
        padding: EdgeInsets.fromLTRB(
          spacing.md,
          _kCardInset - (_kStatusHeight - _kPlacementHeight) / 2,
          spacing.md,
          _kCardInset,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: _kStatusHeight,
              child: Row(
                children: [
                  Expanded(
                    child: showPlacement
                        ? _PlacementTag(placement: group.placement)
                        : const SizedBox.shrink(),
                  ),
                  power,
                ],
              ),
            ),
            SizedBox(height: spacing.sm),
            // Still: the strip shows which pedal, not its settings.
            Expanded(
              child: pedal == null
                  ? fallback
                  : FxArtView(art: pedal, fallback: fallback),
            ),
            SizedBox(height: spacing.md),
            SizedBox(
              height: _kStatusHeight,
              child: _AssignmentLine(assignedTo: assignedTo),
            ),
          ],
        ),
      ),
    );
  }
}

/// A rack's artwork frame at the pen's fixed height, or a saved single
/// effect's pedal in the same frame (the saved presets list).
///
/// Falls back to the app's own mark for a single effect with no pedal, when
/// the slug names a file this build did not ship, and in a widget test,
/// which has no asset bundle at all.
class FxRackArt extends StatelessWidget {
  /// Creates an [FxRackArt].
  const FxRackArt({
    required this.slug,
    required this.lit,
    this.pedal,
    super.key,
  });

  /// The catalogue artwork slug, or `null` for a single effect.
  final String? slug;

  /// A single effect's pedal, drawn when there is no [slug] (#1730).
  final FxPedalPicture? pedal;

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
        child: switch ((slug, pedal)) {
          (final slug?, _) => FxArtView(
            art: FxRackPicture(slug),
            fallback: _FallbackMark(lit: lit),
          ),
          (null, final pedal?) => Padding(
            padding: const EdgeInsets.all(8),
            child: FxArtView(
              art: pedal,
              fallback: _FallbackMark(lit: lit),
            ),
          ),
          (null, null) => _FallbackMark(lit: lit),
        },
      ),
    );
  }
}

/// The app's own mark, drawn where a group has no rack artwork.
class _FallbackMark extends StatelessWidget {
  const _FallbackMark({required this.lit});

  /// Whether the group is audible.
  final bool lit;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Center(
      child: Icon(
        LucideIcons.audioWaveform,
        size: 56,
        color: lit ? surface.accent : surface.textTertiary,
      ),
    );
  }
}

/// The app's mark with the effect's name under it, for a single effect that
/// has no pedal to print its name. The card's label already names it for a
/// screen reader.
class _NamedFallbackMark extends StatelessWidget {
  const _NamedFallbackMark({required this.name, required this.lit});

  /// The effect's name.
  final String name;

  /// Whether the group is audible.
  final bool lit;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _FallbackMark(lit: lit),
        SizedBox(height: context.spacing.sm),
        ExcludeSemantics(
          child: AppText(
            name,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: surface.textPrimary,
              fontSize: 20,
              height: 1.1,
            ),
          ),
        ),
      ],
    );
  }
}

/// A card's assignment line (#1757, #1760): what the controls acting on the
/// effect or the rack are called, on one line, aligned to the start.
class _AssignmentLine extends StatelessWidget {
  const _AssignmentLine({required this.assignedTo});

  /// What the controls are called, or none.
  final List<String> assignedTo;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: AppText(
        fxAssignmentLine(context.l10n, assignedTo),
        // The line shows the first and a count; a screen reader hears every
        // one.
        semanticsLabel: assignedTo.isEmpty ? null : assignedTo.join(', '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: context.surface.textTertiary,
          fontSize: 18,
          height: 1,
        ),
      ),
    );
  }
}

/// The text of a card's assignment line (#1757): the one control assigned,
/// the first and how many more, or Unassigned.
String fxAssignmentLine(AppLocalizations l10n, List<String> names) =>
    switch (names) {
      [] => l10n.fxUnassigned,
      [final only] => only,
      [final first, ...final rest] => l10n.fxAssignedMore(first, rest.length),
    };

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
    // Its own node: without it the card's texts merge into the toggle and
    // the card itself is announced with no name.
    return Semantics(
      container: true,
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
