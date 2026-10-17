import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/library/application/removable_volumes.dart';
import 'package:segno/library/cubit/library_cubit.dart';
import 'package:segno/library/view/library_audio_dialogs.dart';
import 'package:segno/library/view/library_sessions_tab.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/theme/theme.dart';
import 'package:session_repository/session_repository.dart';

/// `Back up to USB` (pen 19/01 `backup:export`, 220 x 64) for the previewed
/// session.
class LibraryBackUpButton extends StatelessWidget {
  /// Creates the button for [summary].
  const LibraryBackUpButton({required this.summary, super.key});

  /// The previewed session.
  final SessionSummary summary;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return LoopOutlinedButton(
      key: const Key('library_back_up'),
      width: 220,
      label: l10n.libraryBackUp,
      onTap: () => unawaited(
        context.read<LibraryCubit>().backUp(
          name: summary.name,
          purpose: l10n.libraryBackupPurpose(summary.name),
        ),
      ),
    );
  }
}

/// Pen 34 `Inline copy progress`: `Backing up <name>…`, the bar and
/// `Cancel`, in place of the preview's footer.
class LibraryBackupProgress extends StatelessWidget {
  /// Creates the progress of [backup].
  const LibraryBackupProgress({required this.backup, super.key});

  /// The running backup.
  final LibraryBackupRunning backup;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final l10n = context.l10n;
    return Row(
      key: const Key('library_backup_progress'),
      children: [
        Expanded(
          child: AppText(
            l10n.libraryBackingUp(backup.name),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: surface.textSecondary,
              fontSize: 24,
              height: 1.15,
            ),
          ),
        ),
        const SizedBox(width: 27),
        SizedBox(
          width: 212,
          height: 12,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              key: const Key('library_backup_bar'),
              value: backup.fraction,
              backgroundColor: surface.cardHigh,
              color: surface.accent,
            ),
          ),
        ),
        const SizedBox(width: 27),
        LoopOutlinedButton(
          key: const Key('library_backup_cancel'),
          width: 125,
          label: l10n.cancel,
          onTap: context.read<LibraryCubit>().cancelBackup,
        ),
      ],
    );
  }
}

/// Shows pen 34's `A backup has this name` or `Backup interrupted` (or, with
/// no drive at all, `Connect a USB drive`) for [backup] and hands the answer
/// to the Library cubit. Dismissing it is `Cancel`.
Future<void> showLibraryBackupQuestion(
  BuildContext context,
  LibraryBackup backup,
) async {
  final l10n = context.l10n;
  final cubit = context.read<LibraryCubit>();
  final cancel = LibraryDialogAction(
    key: const Key('library_backup_dialog_cancel'),
    role: LibraryDialogRole.cancel,
    label: l10n.cancel,
    value: false,
  );
  final answer = await showDialog<Object>(
    context: context,
    barrierColor: context.surface.scrim,
    builder: (_) => switch (backup) {
      LibraryBackupInterrupted(:final problem, :final blockedBy) =>
        LibraryAudioDialog(
          key: const Key('library_backup_interrupted'),
          panel: LibraryDialogPanel.backup,
          title: problem == LibraryBackupProblem.noDrive
              ? l10n.libraryConnectUsb
              : l10n.libraryBackupInterrupted,
          body: switch (problem) {
            LibraryBackupProblem.noDrive => l10n.libraryBackupNoDrive,
            LibraryBackupProblem.driveLost => l10n.libraryBackupDriveLost,
            LibraryBackupProblem.full => l10n.libraryBackupFull,
            LibraryBackupProblem.readOnly => l10n.libraryBackupReadOnly,
            LibraryBackupProblem.busy => l10n.operationBusy(
              blockedBy?.name ?? 'other',
            ),
            LibraryBackupProblem.failed => l10n.libraryBackupFailed,
          },
          actions: [
            cancel,
            LibraryDialogAction(
              key: const Key('library_backup_retry'),
              role: LibraryDialogRole.retry,
              label: l10n.libraryBackupRetry,
              value: true,
            ),
          ],
        ),
      _ => LibraryAudioDialog(
        key: const Key('library_backup_conflict'),
        panel: LibraryDialogPanel.backup,
        title: l10n.libraryBackupConflictTitle,
        body: backup.name,
        actions: [
          cancel,
          LibraryDialogAction(
            key: const Key('library_backup_keep_both'),
            role: LibraryDialogRole.keepBoth,
            label: l10n.libraryAudioKeepBoth,
            value: ConflictPolicy.keepBoth,
          ),
          LibraryDialogAction(
            key: const Key('library_backup_replace'),
            role: LibraryDialogRole.replaceBackup,
            label: l10n.libraryBackupReplace,
            value: ConflictPolicy.replace,
          ),
        ],
      ),
    },
  );
  if (cubit.isClosed) return;
  switch (answer) {
    case final ConflictPolicy policy:
      await cubit.resolveBackupConflict(policy);
    case true:
      await cubit.retryBackup();
    default:
      cubit.cancelBackup();
  }
}

/// Pen 34 `USB session list`: the drive's backups under `Session` /
/// `Saved`, and `Restore to Library` with "Adds a new session to Library."
class LibraryBackupList extends StatelessWidget {
  /// Creates the USB list.
  const LibraryBackupList({super.key});

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final l10n = context.l10n;
    final state = context.watch<LibraryCubit>().state;
    final cubit = context.read<LibraryCubit>();
    final heading = TextStyle(
      color: surface.textSecondary,
      fontSize: 23,
      height: 1.15,
    );
    return Column(
      key: const Key('library_backups'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 728,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(color: surface.borderSubtle),
                  ),
                ),
                child: SizedBox(
                  height: 52,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(28, 4, 27, 0),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: AppText(
                            l10n.libraryBackupSession,
                            style: heading,
                          ),
                        ),
                        AppText(l10n.libraryBackupSaved, style: heading),
                      ],
                    ),
                  ),
                ),
              ),
              Expanded(
                child: state.backups.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.only(top: 36, left: 28),
                        child: AppText(
                          l10n.libraryBackupsEmpty,
                          key: const Key('library_backups_empty'),
                          style: TextStyle(
                            color: surface.textSecondary,
                            fontSize: 22,
                            height: 1,
                          ),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(10, 10, 10, 0),
                        itemExtent: 128,
                        itemCount: state.backups.length,
                        itemBuilder: (context, i) {
                          final backup = state.backups[i];
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: LibraryBackupRow(
                              key: Key('library_backup_${backup.id}'),
                              backup: backup,
                              selected: backup.id == state.selectedBackup,
                              onTap: () => cubit.selectBackup(backup.id),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 28),
        SizedBox(
          height: 64,
          child: Row(
            children: [
              Expanded(
                child: AppText(
                  state.restoreError == null
                      ? l10n.libraryRestoreAdds
                      : state.restoreError == LibraryRestoreError.busy
                      ? l10n.operationBusy('sessionWrite')
                      : l10n.libraryRestoreFailed,
                  key: const Key('library_restore_line'),
                  style: TextStyle(
                    color: state.restoreError == null
                        ? surface.textSecondary
                        : surface.rec,
                    fontSize: 23,
                    height: 1.15,
                  ),
                ),
              ),
              Opacity(
                opacity: state.selectedBackup == null
                    ? surface.disabledOpacity
                    : 1,
                child: LoopOutlinedButton(
                  key: const Key('library_restore'),
                  width: 257,
                  tone: LoopButtonTone.accent,
                  label: l10n.libraryRestore,
                  onTap: state.selectedBackup == null
                      ? null
                      : () => unawaited(cubit.restore()),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// One backup's 120-tall row: its name and facts, and when it was saved.
class LibraryBackupRow extends StatelessWidget {
  /// Creates the row for [backup].
  const LibraryBackupRow({
    required this.backup,
    required this.selected,
    required this.onTap,
    super.key,
  });

  /// The backup, read like a catalog row.
  final SessionSummary backup;

  /// Whether `Restore to Library` would restore it.
  final bool selected;

  /// Selects it.
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final l10n = context.l10n;
    final meta = l10n.libraryBackupMeta(
      l10n.libraryTrackCount(backup.trackCount),
      backup.fxCount,
    );
    final date = savedDateLabel(context, backup.modifiedAt);
    return Semantics(
      button: true,
      selected: selected,
      label: backup.name,
      value: [meta, if (date.isNotEmpty) date].join(', '),
      child: LoopFocusable(
        onActivate: onTap,
        child: Material(
          color: selected ? surface.accentSurface : Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: BorderSide(
              color: selected ? surface.accent : Colors.transparent,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            canRequestFocus: false,
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(25, 26, 24, 0),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        AppText(
                          backup.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: surface.textPrimary,
                            fontSize: 28,
                            height: 1.2,
                          ),
                        ),
                        const SizedBox(height: 11),
                        AppText(
                          meta,
                          style: TextStyle(
                            color: surface.textSecondary,
                            fontSize: 20,
                            height: 1.15,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 21),
                    child: AppText(
                      date,
                      style: TextStyle(
                        color: surface.textSecondary,
                        fontSize: 23,
                        height: 1.15,
                      ),
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
