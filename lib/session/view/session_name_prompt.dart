import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:segno/common/console_rename_sheet.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/session/cubit/session_cubit.dart';
import 'package:segno/theme/theme.dart';
import 'package:session_repository/session_repository.dart';

/// Prompts for a name on the console's keyboard sheet and saves the live rig
/// as a NEW named session: the quick Save's answer when no session is open.
///
/// The check against the catalog's names is fast feedback only;
/// [SessionCubit.saveAs] stays the collision authority. Automatic names
/// replace this prompt in the Library's Part 3 (plan D4).
Future<void> promptSaveAs(BuildContext context) async {
  final cubit = context.read<SessionCubit>();
  final l10n = context.l10n;
  final raw = await showConsoleRenameSheet(
    context,
    title: l10n.sessionNewTitle,
    subtitle: l10n.sessionNameHint,
    current: '',
    fieldLabel: l10n.sessionNewTitle,
  );
  if (raw == null || !context.mounted) return;
  final slug = sessionSlug(raw);
  if (slug == null) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: AppText(l10n.sessionNameInvalid)));
    return;
  }
  if (cubit.state.sessions.any((s) => s.name == slug)) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: AppText(l10n.sessionNameDuplicate(slug))));
    return;
  }
  await cubit.saveAs(raw);
}
