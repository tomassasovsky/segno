import 'package:flutter/material.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/view/tracks/names_tracks_tab.dart';

/// The Tracks domain: what each track is called.
///
/// Same construction as Control and Loop, minus the strip: routing moved to
/// its own route with the accepted design (slice 3c), leaving one task here.
///
/// What differs from those domains is what a ROW means. There a row is a
/// global setting; here a row is a **track**, off the engine-reported
/// roster.
class TracksTrayPanel extends StatelessWidget {
  /// Creates a [TracksTrayPanel].
  const TracksTrayPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;

    return KeyedSubtree(
      key: const Key('tracks_tray_panel'),
      // One task, so no strip: routing left this panel for Settings > Audio
      // routing with the accepted design (slice 3c), and a lone pill over a
      // single body is a rail that chooses nothing.
      child: ConsoleDomainPanel<int>(
        title: l10n.trayTracksLabel,
        selected: 0,
        onChanged: (_) {},
        tabs: const [],
        body: const NamesTracksTab(),
      ),
    );
  }
}
