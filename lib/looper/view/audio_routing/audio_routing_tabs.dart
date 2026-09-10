import 'package:flutter/material.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/view/audio_routing/audio_routing_page.dart';
import 'package:segno/theme/theme.dart';

/// The pen's `Routing task` nav: four pills in a 1720 x 93 row with a rule
/// under them. Each pill carries its own pen width, so the row reads as the
/// four task names rather than as four equal columns.
class AudioRoutingTabBar extends StatelessWidget {
  /// Creates an [AudioRoutingTabBar].
  const AudioRoutingTabBar({
    required this.selected,
    required this.onSelected,
    super.key,
  });

  /// The task now showing.
  final AudioRoutingTab selected;

  /// Called with the task the player picked.
  final ValueChanged<AudioRoutingTab> onSelected;

  static const Map<AudioRoutingTab, double> _widths = {
    AudioRoutingTab.setup: 187,
    AudioRoutingTab.record: 253,
    AudioRoutingTab.outputs: 223,
    AudioRoutingTab.outputSetup: 207,
  };

  /// The pen's left edge for each pill.
  static const Map<AudioRoutingTab, double> _lefts = {
    AudioRoutingTab.setup: 0,
    AudioRoutingTab.record: 201,
    AudioRoutingTab.outputs: 468,
    AudioRoutingTab.outputSetup: 705,
  };

  String _label(AppLocalizations l10n, AudioRoutingTab tab) => switch (tab) {
    AudioRoutingTab.setup => l10n.routingTabInputSetup,
    AudioRoutingTab.record => l10n.routingTabRecordingInputs,
    AudioRoutingTab.outputs => l10n.routingTabOutputRouting,
    AudioRoutingTab.outputSetup => l10n.routingTabOutputSetup,
  };

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    return SizedBox(
      width: 1720,
      height: 93,
      child: Stack(
        children: [
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(height: 1, color: surface.line),
          ),
          for (final tab in AudioRoutingTab.values)
            Positioned(
              left: _lefts[tab] ?? 0,
              top: 0,
              child: _TaskPill(
                key: Key('routing_tab_${tab.name}'),
                label: _label(l10n, tab),
                width: _widths[tab] ?? 0,
                selected: tab == selected,
                onTap: () => onSelected(tab),
              ),
            ),
        ],
      ),
    );
  }
}

class _TaskPill extends StatelessWidget {
  const _TaskPill({
    required this.label,
    required this.width,
    required this.selected,
    required this.onTap,
    super.key,
  });

  final String label;
  final double width;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          width: width,
          height: 64,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? surface.accentSurface : null,
            border: Border.all(
              color: selected ? surface.borderStrong : Colors.transparent,
            ),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: AppText(
                label,
                style: TextStyle(
                  color: selected ? surface.textPrimary : surface.textSecondary,
                  fontSize: 26,
                  height: 1,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
