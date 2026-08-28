import 'dart:async';

import 'package:flutter/material.dart';
import 'package:segno/app/segno_navigator.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/theme/theme.dart';

/// A full-width affordance shown when the engine isn't running (no first-run
/// gate exists anymore). Tapping it opens settings, where the engine can be
/// (re)started by choosing a device.
class AudioNotRunningBanner extends StatelessWidget {
  /// Creates an [AudioNotRunningBanner].
  const AudioNotRunningBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        key: const Key('tracks_audioNotRunning'),
        borderRadius: BorderRadius.circular(10),
        onTap: () => unawaited(openSegnoSettings()),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              const Icon(Icons.warning_amber_rounded, size: 18),
              const SizedBox(width: 10),
              Expanded(child: AppText(context.l10n.engineStoppedBanner)),
              const Icon(Icons.settings, size: 18),
            ],
          ),
        ),
      ),
    );
  }
}

/// The session area in the top bar: the current session name (or "Unsaved")
/// beside a folder button that opens the **Sessions** popup — the single place
/// to save / load / manage sessions and export (Segno-Pro-style). The popup
/// surfaces its own actions; save/load/export outcomes still flow through the
/// view's [BlocListener] (a live-region SnackBar).
