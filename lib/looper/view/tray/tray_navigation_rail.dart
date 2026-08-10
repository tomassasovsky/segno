import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:routing_graph/routing_graph.dart' show FocusableTapTarget;
import 'package:segno/common/pen_icons.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/cubit/settings_tray_cubit.dart';
import 'package:segno/looper/view/tray/tray_metrics.dart';
import 'package:segno/theme/theme.dart';

/// Paints one rail glyph in [color]. See [TrayNavigationRail._glyphFor].
typedef _Glyph = Widget Function(Color color);

/// The open tray's navigation spine: a persistent vertical rail listing every
/// in-tray destination, with the selected one filling the sheet beside it.
///
/// This is the seam the rest of the console redesign (#442) hangs off — a new
/// config surface becomes "add a [SettingsTrayDestination] and an entry here",
/// not "push another full-screen route away from the performance view".
///
/// Only destinations that render *inside* the tray belong here. Settings is
/// the last surface that still pushes a full-screen route, and so stays a tile
/// on the home face: a rail item that navigated away would lie about what the
/// rail is.
class TrayNavigationRail extends StatelessWidget {
  /// Creates a [TrayNavigationRail].
  const TrayNavigationRail({required this.onBrightness, super.key});

  /// Opens the brightness popover. Not a destination — see [domains].
  final VoidCallback onBrightness;

  /// Rail width. Sized for an icon beside a full-size label, because the rail
  /// is a navigation spine and should read as one — a column of icon-over-
  /// caption tiles reads as more of the tile grid the rail exists to replace.
  ///
  /// From the redesign mockups (#490); the earlier 84px stacked form was built
  /// without them, since the decision record carries no diagrams.
  /// Rail width. Public because the brightness popover hangs off its edge.
  static const double width = 165;

  static const double _itemGap = 4;

  /// The rail's destinations, in the order the mockups stack them.
  ///
  /// Every value: brightness is NOT one of them — it opens a popover rather
  /// than a face, so it is a button pinned below these, not a ninth domain.
  ///
  /// Public so a test can aim at the gap between the two groups without
  /// naming a destination that a later part will move.
  static const List<SettingsTrayDestination> domains =
      SettingsTrayDestination.values;

  /// The glyph for [destination] — every one of them what the pen's SCREENS
  /// draw, not what its `NavRail` component names.
  ///
  /// Those two disagree, and the disagreement is why this rail was wrong
  /// twice. `ctaGc`'s `NavItem` instances carry lucide names — `activity`,
  /// `gamepad-2`, `align-justify`, `target` — and every screen draws something
  /// else in their place: a sine rather than a jagged pulse, upright bars
  /// rather than horizontal rules, a speaker with waves rather than a cabinet,
  /// a chip rather than a gear. The screens are what a person looks at, so the
  /// screens win and the component's names are stale defaults.
  ///
  /// Four of them are no lucide glyph at all and are drawn from the pen's own
  /// geometry — see [PenIcon]. The five that ARE stock come from the font,
  /// which is why this returns a widget rather than an `IconData`: one rail,
  /// two mechanisms, because the design uses two.
  ///
  /// Exhaustive `switch`, deliberately — the rail is built by iterating
  /// [SettingsTrayDestination.values], so a part that adds a destination gets
  /// a compile error here instead of a rail that silently omits its own panel.
  /// `TrayPanel`'s face switch already fails this way; the rail must too, or a
  /// destination can be reachable in code and invisible on screen.
  ///
  /// Returns a builder rather than a widget because the tint is the rail
  /// item's to decide — it changes with selection.
  static _Glyph _glyphFor(SettingsTrayDestination destination) {
    _Glyph lucide(IconData icon) =>
        (color) => Icon(icon, size: iconSize, color: color);
    _Glyph pen(PenIcon icon) =>
        (color) => PenIconView(icon: icon, size: iconSize, color: color);
    return switch (destination) {
      SettingsTrayDestination.signal => pen(PenIcon.signal),
      SettingsTrayDestination.control => pen(PenIcon.control),
      SettingsTrayDestination.loop => lucide(LucideIcons.repeat),
      SettingsTrayDestination.tracks => pen(PenIcon.tracks),
      // A cone with two arcs, which is `volume-2`. The component says
      // `speaker` — lucide's cabinet-with-drivers — and no screen draws it.
      SettingsTrayDestination.audio => lucide(LucideIcons.volume2),
      SettingsTrayDestination.tuner => pen(PenIcon.tuner),
      // TWO arcs over the dot, not three: `wifi-high`, not `wifi`.
      SettingsTrayDestination.network => lucide(LucideIcons.wifiHigh),
      // A square in a square with eight pins — a chip, not a gear.
      SettingsTrayDestination.system => lucide(LucideIcons.cpu),
    };
  }

  /// The pen draws every rail glyph in a 22px box (`NavItem`'s `tbxzR`). The
  /// rail had been drawing them at 20.
  static const double iconSize = 22;

  /// The caption for [destination]. Exhaustive for the same reason as
  /// [_glyphFor].
  static String _labelFor(
    AppLocalizations l10n,
    SettingsTrayDestination destination,
  ) => switch (destination) {
    SettingsTrayDestination.signal => l10n.traySignalLabel,
    SettingsTrayDestination.control => l10n.trayControlLabel,
    SettingsTrayDestination.loop => l10n.trayLoopLabel,
    SettingsTrayDestination.tracks => l10n.trayTracksLabel,
    SettingsTrayDestination.audio => l10n.trayAudioLabel,
    SettingsTrayDestination.tuner => l10n.trayTunerLabel,
    SettingsTrayDestination.network => l10n.trayNetworkLabel,
    SettingsTrayDestination.system => l10n.traySystemLabel,
  };

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final destination = context.watch<SettingsTrayCubit>().state.destination;
    final cubit = context.read<SettingsTrayCubit>();

    // Clamped rather than fixed: a sheet narrower than the rail's natural
    // width would otherwise overflow the item Row. Real on a small display,
    // not only in a test harness.
    return LayoutBuilder(
      builder: (context, constraints) {
        final railWidth = constraints.maxWidth.isFinite
            ? math.min(TrayNavigationRail.width, constraints.maxWidth)
            : TrayNavigationRail.width;
        return SizedBox(
          width: railWidth,
          // The rail absorbs taps that miss an item. Without this they fall
          // through to the panel's full-bleed dismiss detector and close the
          // tray — fine for the home face's tile grid (Control Center
          // dismisses on a miss), wrong for a persistent navigation
          // surface you are aiming at.
          //
          // `excludeFromSemantics` because this detector exists purely to stop
          // pointers: left in the tree it collapses the whole rail into one
          // tappable node whose activation does nothing, so a screen reader
          // offers a no-op action over the real items.
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            excludeFromSemantics: true,
            onTap: () {},
            child: Semantics(
              explicitChildNodes: true,
              label: l10n.a11yTrayRail,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border(
                    right: BorderSide(
                      color: surface.line.withValues(alpha: 0.4),
                    ),
                  ),
                ),
                // The domains scroll; brightness does not. The pen pins it
                // at the foot of the rail behind a fill spacer, which inside
                // a scroll view would do nothing — an unbounded child has no
                // slack to give. Splitting the two puts it where the mockups
                // draw it at any height, and keeps it reachable when the
                // domain list is taller than the rail.
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    spacing: _itemGap,
                    children: [
                      // Expanded, not Flexible: under a loose fit the scroll
                      // view takes its CONTENT height, so with eight domains
                      // shorter than the rail — which is every real height —
                      // the column packs to the top and brightness sits under
                      // System with the slack below it. It pinned only when
                      // the list overflowed, which is the one case the pen is
                      // not describing.
                      Expanded(
                        child: SingleChildScrollView(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            spacing: _itemGap,
                            children: [
                              for (final target in domains)
                                // Stretch so every pill spans the rail: pills
                                // sized to their own text read as chips, not
                                // as rows of one list.
                                _RailItem(
                                  key: Key('settingsTrayRail_${target.name}'),
                                  glyph: _glyphFor(target),
                                  label: _labelFor(l10n, target),
                                  selected: destination == target,
                                  onTap: () => cubit.showDestination(target),
                                ),
                            ],
                          ),
                        ),
                      ),
                      // The drag handle rides at the open panel's bottom
                      // edge — pad past it so this does not sit under a
                      // control that closes the tray.
                      Padding(
                        padding: const EdgeInsets.only(
                          bottom: kTrayHandleHeight,
                        ),
                        child: _RailItem(
                          key: const Key('settingsTrayRail_brightness'),
                          // A sun, as the pen draws it — the one entry that
                          // is about the screen rather than the rig.
                          glyph: (color) => Icon(
                            LucideIcons.sun,
                            size: TrayNavigationRail.iconSize,
                            color: color,
                          ),
                          label: l10n.trayBrightLabel,
                          // Never "selected": it does not replace the face
                          // behind it, so a lit pill here would claim a
                          // destination the rail has not moved to.
                          selected: false,
                          onTap: onBrightness,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// One rail entry: icon beside label, accent-tinted and pill-backed while it
/// is the showing destination.
class _RailItem extends StatelessWidget {
  const _RailItem({
    required this.glyph,
    required this.label,
    required this.selected,
    required this.onTap,
    super.key,
  });

  final _Glyph glyph;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  static const double _radius = 24;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final tint = selected ? surface.accent : surface.textSecondary;
    return FocusableTapTarget(
      onTap: onTap,
      semanticLabel: label,
      selected: selected,
      borderRadius: _radius,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 11),
        margin: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(_radius),
          color: selected
              ? surface.accent.withValues(alpha: 0.18)
              : Colors.transparent,
        ),
        // Icon beside the label, one row per destination. The label is at
        // reading size rather than caption size: this is the surface you aim
        // at to change what the sheet is showing, not a dense tile.
        child: Row(
          children: [
            glyph(tint),
            const SizedBox(width: 9),
            Expanded(
              child: AppText(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: tint,
                  fontSize: 14,
                  height: 1.1,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
