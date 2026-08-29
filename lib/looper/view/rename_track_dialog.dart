import 'package:flutter/material.dart';
import 'package:segno/common/console_rename_sheet.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/cubit/tracks_cubit.dart';

/// Asks for a new name for track [channel] (current name [current]) and
/// persists the result through [cubit]. Shared by the Tracks grid and the
/// settings page so the rename UX stays in one place.
///
/// On the console this is the on-screen-keyboard sheet the pen draws in
/// `STAGE / track-rename` — the same sheet every other console rename uses.
/// On desktop a physical keyboard is behind the screen, so the Material
/// dialog stays.
Future<void> showRenameTrackDialog({
  required BuildContext context,
  required TracksCubit cubit,
  required int channel,
  required String current,
}) async {
  final l10n = context.l10n;
  final display = l10n.displayTrackName(current, channel);
  // Constant title, name in the subtitle — the sheet's header does not wrap
  // its title, and the track name is unbounded.
  final result = await showConsoleRenameSheet(
    context,
    title: l10n.tracksRenameSheetTitle,
    subtitle: display,
    current: current,
    fieldLabel: l10n.tracksRenameSheetTitle,
  );
  if (result != null) {
    final trimmed = result.trim();
    if (trimmed.isNotEmpty) await cubit.rename(channel, trimmed);
  }
}
