import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:segno/common/console_rename_sheet.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/view/fx/fx_options_sheet.dart';
import 'package:segno/session/session.dart';
import 'package:session_repository/session_repository.dart';

/// The Manage sheet's rows (plan deviation 1: the pen draws the button, not
/// the sheet, so it is the options sheet every other page uses).
enum LibraryManageAction {
  /// Write the live rig back to the open session.
  save,

  /// Write the live rig under a new name and make that current.
  saveAs,

  /// Copy the selected saved session under a new name.
  duplicate,

  /// Rename the selected session (its manifest only).
  rename,

  /// Move the selected session to a folder or to Unfiled.
  move,

  /// Delete the selected session; never the open one.
  delete,
}

/// Opens Manage for [summary], the selected session, and runs the chosen
/// action through [SessionCubit], the catalog's one authority.
///
/// Save and Save as act on the live rig whichever session is selected
/// (plan D5); Duplicate, Rename, Move and Delete act on [summary]. Delete is
/// drawn disabled on the open session, and the cubit refuses it as well
/// (plan D6).
Future<void> showLibraryManage(
  BuildContext context,
  SessionSummary summary,
) async {
  final l10n = context.l10n;
  final session = context.read<SessionCubit>();
  final isCurrent = summary.id == session.state.currentSessionId;
  // Save and Save as write the live rig whichever session is selected
  // (plan D5); on another session's sheet they say whose.
  final open = session.state.currentSessionName ?? l10n.libraryCurrentLoop;
  final choice = await showFxOptionsSheet(
    context,
    title: summary.name,
    options: [
      FxOption(
        id: LibraryManageAction.save.name,
        label: isCurrent ? l10n.sessionSave : l10n.libraryManageSaveOpen(open),
      ),
      FxOption(
        id: LibraryManageAction.saveAs.name,
        label: isCurrent
            ? l10n.sessionSaveAs
            : l10n.libraryManageSaveOpenAs(open),
      ),
      FxOption(
        id: LibraryManageAction.duplicate.name,
        label: l10n.sessionDuplicate,
      ),
      FxOption(id: LibraryManageAction.rename.name, label: l10n.sessionRename),
      FxOption(
        id: LibraryManageAction.move.name,
        label: l10n.libraryMoveToFolder,
      ),
      FxOption(
        id: LibraryManageAction.delete.name,
        label: l10n.sessionDelete,
        enabled: !isCurrent,
      ),
    ],
  );
  if (choice == null || !context.mounted) return;
  switch (LibraryManageAction.values.byName(choice)) {
    case LibraryManageAction.save:
      await session.save();
    case LibraryManageAction.saveAs:
      await _nameSession(
        context,
        subtitle: l10n.sessionNewTitle,
        initial: '',
        run: session.saveAs,
      );
    case LibraryManageAction.duplicate:
      await _nameSession(
        context,
        subtitle: l10n.sessionDuplicateTitle,
        initial: summary.name,
        run: (name) => session.duplicateSession(summary.id, name),
      );
    case LibraryManageAction.rename:
      await _nameSession(
        context,
        subtitle: l10n.sessionRenameTitle,
        initial: summary.name,
        own: summary.name,
        run: (name) => session.renameSession(summary.id, name),
      );
    case LibraryManageAction.move:
      await _move(context, summary);
    case LibraryManageAction.delete:
      final confirmed = await showConsoleConfirmDialog(
        context,
        title: l10n.sessionDeleteConfirmTitle(summary.name),
        body: l10n.sessionDeleteConfirmBody,
        confirmLabel: l10n.sessionDelete,
      );
      if (confirmed) await session.deleteSession(summary.id);
  }
}

/// Asks for a session name on the keyboard sheet (pen 19/04) and runs [run]
/// with it. A name that sanitizes to nothing, or that another session
/// carries exactly, is answered in the sheet before anything runs; a
/// refusal from the cubit is answered there too, and the sheet stays open.
/// [own] is the name the session already has, which a rename may keep.
Future<void> _nameSession(
  BuildContext context, {
  required String subtitle,
  required String initial,
  required Future<void> Function(String name) run,
  String? own,
}) async {
  final l10n = context.l10n;
  final session = context.read<SessionCubit>();
  await showConsoleRenameSheet(
    context,
    title: l10n.sessionNameHint,
    subtitle: subtitle,
    current: initial,
    fieldLabel: l10n.sessionNameHint,
    onSave: (raw) async {
      final slug = sessionSlug(raw);
      if (slug == null) return l10n.sessionNameInvalid;
      if (slug != own && session.state.sessions.any((s) => s.name == slug)) {
        return l10n.sessionNameDuplicate(slug);
      }
      await run(raw);
      return _refusalOf(
        l10n,
        session.state,
        taken: l10n.sessionNameDuplicate(slug),
      );
    },
  );
}

/// Asks for a folder name and creates it, then runs [then] with the
/// folder's name when the folder was made.
Future<void> promptNewFolder(
  BuildContext context, {
  Future<void> Function(String folder)? then,
}) async {
  final l10n = context.l10n;
  final session = context.read<SessionCubit>();
  await showConsoleRenameSheet(
    context,
    title: l10n.libraryFolderName,
    subtitle: l10n.libraryNewFolder,
    current: '',
    fieldLabel: l10n.libraryFolderName,
    onSave: (raw) async {
      final slug = sessionSlug(raw);
      if (slug == null || isMintedSessionId(slug)) {
        return l10n.sessionNameInvalid;
      }
      if (session.state.folders.contains(slug)) {
        return l10n.libraryFolderNameTaken(slug);
      }
      await session.createFolder(raw);
      final refusal = _refusalOf(
        l10n,
        session.state,
        taken: l10n.libraryFolderNameTaken(slug),
      );
      if (refusal == null && then != null) await then(slug);
      return refusal;
    },
  );
}

/// Move to folder: `Unfiled`, every folder, and `New folder…`, with where
/// the session already is disabled.
Future<void> _move(BuildContext context, SessionSummary summary) async {
  final l10n = context.l10n;
  final session = context.read<SessionCubit>();
  const unfiled = '\u0000unfiled';
  const create = '\u0000new';
  final choice = await showFxOptionsSheet(
    context,
    title: l10n.libraryMoveTitle,
    body: summary.name,
    options: [
      FxOption(
        id: unfiled,
        label: l10n.libraryFolderUnfiled,
        enabled: summary.folder != null,
      ),
      for (final folder in session.state.folders)
        FxOption(
          id: folder,
          label: folder,
          enabled: folder != summary.folder,
        ),
      FxOption(id: create, label: l10n.libraryNewFolderOption),
    ],
  );
  if (choice == null || !context.mounted) return;
  switch (choice) {
    case unfiled:
      await session.moveSession(summary.id);
    case create:
      await promptNewFolder(
        context,
        then: (folder) => session.moveSession(summary.id, folder: folder),
      );
    default:
      await session.moveSession(summary.id, folder: choice);
  }
}

/// The sheet's answer to the action that just ran: null when it succeeded,
/// [taken] for a name collision, else the Library's failure line.
String? _refusalOf(
  AppLocalizations l10n,
  SessionState state, {
  required String taken,
}) {
  if (state.status != SessionStatus.failure) return null;
  return switch (state.error) {
    SessionError.nameCollision => taken,
    SessionError.saveFailed => l10n.librarySaveFailed,
    _ => l10n.libraryActionFailed,
  };
}

/// A folder chip's options (a long press): `Rename folder`, and `Delete
/// folder` while no session is filed in it. The pen draws neither; plan D2
/// keeps a folder until it is deleted.
Future<void> showFolderManage(BuildContext context, String folder) async {
  final l10n = context.l10n;
  final session = context.read<SessionCubit>();
  final empty = !session.state.sessions.any((s) => s.folder == folder);
  final choice = await showFxOptionsSheet(
    context,
    title: folder,
    options: [
      FxOption(id: 'rename', label: l10n.libraryRenameFolder),
      FxOption(id: 'delete', label: l10n.libraryDeleteFolder, enabled: empty),
    ],
  );
  if (choice == null || !context.mounted) return;
  if (choice == 'delete') {
    final confirmed = await showConsoleConfirmDialog(
      context,
      title: l10n.libraryDeleteFolderTitle(folder),
      body: l10n.libraryDeleteFolderBody,
      confirmLabel: l10n.libraryDeleteFolder,
    );
    if (confirmed) await session.deleteFolder(folder);
    return;
  }
  await showConsoleRenameSheet(
    context,
    title: l10n.libraryFolderName,
    subtitle: l10n.libraryRenameFolder,
    current: folder,
    fieldLabel: l10n.libraryFolderName,
    onSave: (raw) async {
      final slug = sessionSlug(raw);
      if (slug == null || isMintedSessionId(slug)) {
        return l10n.sessionNameInvalid;
      }
      if (slug == folder) return null;
      if (session.state.folders.contains(slug)) {
        return l10n.libraryFolderNameTaken(slug);
      }
      await session.renameFolder(folder, raw);
      return _refusalOf(
        l10n,
        session.state,
        taken: l10n.libraryFolderNameTaken(slug),
      );
    },
  );
}
