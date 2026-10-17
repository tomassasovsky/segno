import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/library/application/removable_volumes.dart';
import 'package:segno/library/cubit/library_audio_cubit.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/theme/theme.dart';

/// One button of a [LibraryAudioDialog].
class LibraryDialogAction {
  /// Creates an action labelled [label] that closes the dialog with [value].
  const LibraryDialogAction({
    required this.key,
    required this.role,
    required this.label,
    required this.value,
  });

  /// The button's key.
  final Key key;

  /// Its label.
  final String label;

  /// What the dialog answers when it is pressed.
  final Object value;

  /// Which of the pen's buttons it is, which sets its size and fill.
  final LibraryDialogRole role;
}

/// The pen's dialog buttons (20/09, 20/10) and the chooser's rows, with
/// their widths and fills.
enum LibraryDialogRole {
  /// Outlined `Cancel`, 125 wide.
  cancel(width: 125, tone: LoopButtonTone.outlined),

  /// Filled `Keep both`, 167 wide.
  keepBoth(width: 167, tone: LoopButtonTone.accent),

  /// `Replace file` outlined in the record colour, 175 wide.
  replace(width: 175, tone: LoopButtonTone.outlined, destructive: true),

  /// Filled `Try again`, 155 wide.
  tryAgain(width: 155, tone: LoopButtonTone.accent),

  /// Filled `Retry`, 112 wide (pen 34).
  retry(width: 112, tone: LoopButtonTone.accent),

  /// Outlined `Replace`, 139 wide (pen 34's backup name match).
  replaceBackup(width: 139, tone: LoopButtonTone.outlined),

  /// A chooser row, the panel's full inner width.
  choice(width: 878, tone: LoopButtonTone.outlined);

  const LibraryDialogRole({
    required this.width,
    required this.tone,
    this.destructive = false,
  });

  /// The button's width.
  final double width;

  /// Its fill.
  final LoopButtonTone tone;

  /// Whether it is outlined in the record colour.
  final bool destructive;
}

/// The Library's two dialog panels: the Audio tab's 960-wide ones (pen
/// 20/09, 20/10) and section 34's 900-wide backup ones.
enum LibraryDialogPanel {
  /// Pen 20/09 and 20/10.
  export(width: 960),

  /// Pen 34 `Matching backup name` and `Retry an interrupted copy`.
  backup(width: 900);

  const LibraryDialogPanel({required this.width});

  /// The panel's width.
  final double width;
}

/// The Library's dialog (pen 20/09, 20/10, 34): a panel with a title, one
/// line, and its actions at the trailing edge, or with [choices] stacked
/// under the title (the package chooser).
class LibraryAudioDialog extends StatelessWidget {
  /// Creates a dialog.
  const LibraryAudioDialog({
    required this.title,
    required this.actions,
    this.body,
    this.choices = const [],
    this.panel = LibraryDialogPanel.export,
    super.key,
  });

  /// Which panel it is, which sets its width.
  final LibraryDialogPanel panel;

  /// The question.
  final String title;

  /// The line under it.
  final String? body;

  /// Full-width answers stacked under the title.
  final List<LibraryDialogAction> choices;

  /// The answers at the foot, right-aligned.
  final List<LibraryDialogAction> actions;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    Widget button(LibraryDialogAction a) => LoopOutlinedButton(
      key: a.key,
      width: a.role.width,
      label: a.label,
      tone: a.role.tone,
      borderColor: a.role.destructive ? surface.rec : null,
      onTap: () => Navigator.of(context).pop(a.value),
    );
    return Center(
      child: Material(
        color: Colors.transparent,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Container(
            width: panel.width,
            padding: const EdgeInsets.all(41),
            decoration: BoxDecoration(
              color: surface.cardHigh,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: surface.borderStrong),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AppText(
                  title,
                  style: TextStyle(
                    color: surface.textPrimary,
                    fontSize: 32,
                    height: 1.15,
                  ),
                ),
                if (body case final body?) ...[
                  const SizedBox(height: 24),
                  AppText(
                    body,
                    style: TextStyle(
                      color: surface.textSecondary,
                      fontSize: 24,
                      height: 1.2,
                    ),
                  ),
                ],
                for (final c in choices) ...[
                  const SizedBox(height: 16),
                  button(c),
                ],
                const SizedBox(height: 24),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    for (final (i, a) in actions.indexed) ...[
                      if (i > 0) const SizedBox(width: 16),
                      button(a),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Asks what a recording's `Export to USB` writes: the recording alone, or
/// the DAW package. Null when cancelled.
Future<LibraryAudioExportKind?> showLibraryExportChooser(
  BuildContext context,
) async {
  final l10n = context.l10n;
  final answer = await showDialog<Object>(
    context: context,
    barrierColor: context.surface.scrim,
    builder: (_) => LibraryAudioDialog(
      key: const Key('library_export_chooser'),
      title: l10n.libraryAudioChooserTitle,
      choices: [
        LibraryDialogAction(
          key: const Key('library_export_choose_recording'),
          role: LibraryDialogRole.choice,
          label: l10n.libraryAudioChooseRecording,
          value: LibraryAudioExportKind.recording,
        ),
        LibraryDialogAction(
          key: const Key('library_export_choose_daw'),
          role: LibraryDialogRole.choice,
          label: l10n.libraryAudioChooseDaw,
          value: LibraryAudioExportKind.dawPackage,
        ),
      ],
      actions: [
        LibraryDialogAction(
          key: const Key('library_export_chooser_cancel'),
          role: LibraryDialogRole.cancel,
          label: l10n.cancel,
          value: false,
        ),
      ],
    ),
  );
  return answer is LibraryAudioExportKind ? answer : null;
}

/// Shows 20/09 (`Already on USB`) or 20/10 (`Connect a USB drive`) for
/// [export] and hands the answer to the Audio tab's cubit. Dismissing it
/// is `Cancel`.
Future<void> showLibraryExportQuestion(
  BuildContext context,
  LibraryAudioExport export,
) async {
  final l10n = context.l10n;
  final cubit = context.read<LibraryAudioCubit>();
  final cancel = LibraryDialogAction(
    key: const Key('library_export_dialog_cancel'),
    role: LibraryDialogRole.cancel,
    label: l10n.cancel,
    value: false,
  );
  final answer = await showDialog<Object>(
    context: context,
    barrierColor: context.surface.scrim,
    builder: (_) => switch (export) {
      LibraryExportConflict(:final name) => LibraryAudioDialog(
        key: const Key('library_export_conflict'),
        title: l10n.libraryAudioConflictTitle,
        body: name,
        actions: [
          cancel,
          LibraryDialogAction(
            key: const Key('library_export_keep_both'),
            role: LibraryDialogRole.keepBoth,
            label: l10n.libraryAudioKeepBoth,
            value: ConflictPolicy.keepBoth,
          ),
          LibraryDialogAction(
            key: const Key('library_export_replace'),
            role: LibraryDialogRole.replace,
            label: l10n.libraryAudioReplace,
            value: ConflictPolicy.replace,
          ),
        ],
      ),
      _ => LibraryAudioDialog(
        key: const Key('library_export_connect'),
        title: l10n.libraryConnectUsb,
        body: l10n.libraryAudioConnectBody,
        actions: [
          cancel,
          LibraryDialogAction(
            key: const Key('library_export_try_again'),
            role: LibraryDialogRole.tryAgain,
            label: l10n.libraryAudioTryAgain,
            value: true,
          ),
        ],
      ),
    },
  );
  if (cubit.isClosed) return;
  switch (answer) {
    case final ConflictPolicy policy:
      await cubit.resolveConflict(policy);
    case true:
      await cubit.retryExport();
    default:
      cubit.cancelExport();
  }
}
