import 'package:flutter/material.dart';
import 'package:segno/common/console_mode.dart';
import 'package:segno/common/console_rename_sheet.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/cubit/tracks_cubit.dart';
import 'package:segno/theme/theme.dart';

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
  final result = kConsoleMode
      // Constant title, name in the subtitle — the sheet's header does not
      // wrap its title, and the track name is unbounded.
      ? await showConsoleRenameSheet(
          context,
          title: l10n.tracksRenameSheetTitle,
          subtitle: display,
          current: current,
          fieldLabel: l10n.tracksRenameSheetTitle,
        )
      : await _showRenameDialog(context, l10n, display, current);
  if (result != null) {
    final trimmed = result.trim();
    if (trimmed.isNotEmpty) await cubit.rename(channel, trimmed);
  }
}

Future<String?> _showRenameDialog(
  BuildContext context,
  AppLocalizations l10n,
  String display,
  String current,
) {
  final controller = TextEditingController(text: current);
  return showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: AppText(l10n.renameTrackTitle(display)),
      content: TextField(
        key: const Key('renameTrack_field'),
        controller: controller,
        autofocus: true,
        textCapitalization: TextCapitalization.characters,
        onSubmitted: (value) => Navigator.of(dialogContext).pop(value),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: AppText(l10n.cancel),
        ),
        TextButton(
          key: const Key('renameTrack_save'),
          onPressed: () => Navigator.of(dialogContext).pop(controller.text),
          child: AppText(l10n.save),
        ),
      ],
    ),
  );
}
