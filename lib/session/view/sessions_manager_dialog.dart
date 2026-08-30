import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/common/console_rename_sheet.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/session/session.dart';
import 'package:segno/theme/theme.dart';
import 'package:session_repository/session_repository.dart';

/// Opens the **Sessions** dialog — the single place to handle sessions, drawn
/// to `SESSION & CAPTURE / sessions`: a 744 panel in the console's `Dialog`
/// idiom holding the saved-session list (load-on-tap, the open one
/// highlighted) and the action row — Rename, Duplicate, Delete, Save as…,
/// Save. Refreshes the catalog first, then hands the live [SessionCubit] down
/// through the dialog route (which sits under the root navigator, outside the
/// page's providers).
Future<void> showSessionsManager(BuildContext context) async {
  final cubit = context.read<SessionCubit>();
  final pedal = context.read<PedalRepository>();
  await cubit.refreshSessions();
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    barrierColor: context.surface.scrim,
    builder: (_) => MultiBlocProvider(
      providers: [
        BlocProvider<SessionCubit>.value(value: cubit),
        BlocProvider(create: (_) => SessionsManagerCubit(pedal: pedal)),
      ],
      child: const _SessionsManagerDialog(),
    ),
  );
}

/// Prompts for a name and saves the live rig as a NEW named session. Shared by
/// the dialog's "Save as…" and the top bar's quick Save when no session is
/// open. The prompt's inline check is fast feedback only; [SessionCubit.saveAs]
/// stays the collision authority.
Future<void> promptSaveAs(BuildContext context) async {
  final cubit = context.read<SessionCubit>();
  final l10n = context.l10n;
  final name = await _promptName(
    context,
    title: l10n.sessionNewTitle,
    taken: cubit.state.sessions.map((s) => s.name).toSet(),
  );
  if (name == null) return;
  await cubit.saveAs(name);
}

/// Prompts for a name and duplicates saved session [from] to a new copy.
Future<void> promptDuplicate(BuildContext context, String from) async {
  final cubit = context.read<SessionCubit>();
  final l10n = context.l10n;
  final to = await _promptName(
    context,
    title: l10n.sessionDuplicateTitle,
    initial: from,
    taken: cubit.state.sessions.map((s) => s.name).toSet(),
  );
  if (to == null) return;
  await cubit.duplicateSession(from, to);
}

/// One name prompt, two keyboards: the console has no physical keys, so it
/// gets the full-width sheet with the on-screen ones — the same surface every
/// other rename on the appliance uses. The desktop keeps the compact dialog
/// its hardware keyboard is already pointed at (#668).
///
/// The console path re-checks the sheet's answer against [taken] here (the
/// sheet has no validator hook); the desktop dialog validates inline as it
/// always has. Either way the cubit remains the authority.
Future<String?> _promptName(
  BuildContext context, {
  required String title,
  required Set<String> taken,
  String initial = '',
}) async {
  final l10n = context.l10n;
  final raw = await showConsoleRenameSheet(
    context,
    title: title,
    subtitle: initial.isEmpty ? l10n.sessionNameHint : initial,
    current: initial,
    fieldLabel: title,
  );
  if (raw == null) return null;
  final slug = sessionSlug(raw);
  if (!context.mounted) return null;
  if (slug == null) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: AppText(l10n.sessionNameInvalid)));
    return null;
  }
  if (taken.contains(slug)) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: AppText(l10n.sessionNameDuplicate(slug))));
    return null;
  }
  return raw;
}

/// The Sessions dialog: title, an error banner when the last load refused, the
/// saved-session card, and the action row.
///
/// A footswitch press dismisses it (and any rename / delete sheet stacked on
/// top) so a Rec/Play or Clear can see the stage. Encoder turns do not.
class _SessionsManagerDialog extends StatelessWidget {
  const _SessionsManagerDialog();

  void _dismiss(BuildContext context) {
    final navigator = Navigator.of(context);
    final route = ModalRoute.of(context);
    // A barrier/back pop makes the route non-present before its reverse
    // animation disposes this widget. Ignore a racing pedal request rather
    // than searching through and popping routes underneath it.
    if (route == null || !route.isActive) return;
    navigator.popUntil((r) => r == route);
    if (route.isCurrent) navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    return BlocListener<SessionsManagerCubit, SessionsManagerStatus>(
      listenWhen: (_, current) =>
          current == SessionsManagerStatus.dismissalRequested,
      listener: (context, _) => _dismiss(context),
      child: const _SessionsManagerBody(),
    );
  }
}

class _SessionsManagerBody extends StatelessWidget {
  const _SessionsManagerBody();

  /// Four rows is what the pen holds before the list scrolls. A [Flexible]
  /// here would take the rest of the dialog route — the full viewport —
  /// instead of shrinking to the rows.
  static const double _listMaxHeight =
      kConsoleRowHeight * 4 + ConsoleCard.borderExtent;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    return BlocBuilder<SessionCubit, SessionState>(
      buildWhen: (a, b) =>
          a.sessions != b.sessions ||
          a.currentSessionName != b.currentSessionName ||
          a.error != b.error,
      builder: (context, state) {
        // The two load refusals the pen draws as banners under the title
        // (`session-rate-error` / `session-version-error`). The other error
        // kinds surface where their actions run (name prompts, snackbars).
        final loadError = switch (state.error) {
          SessionError.sampleRateMismatch => l10n.sessionErrorSampleRate,
          SessionError.unsupportedVersion =>
            l10n.sessionErrorUnsupportedVersion,
          _ => null,
        };
        // Centered: the dialog route offers the full screen, and a shell
        // that is not wrapped takes that height as a tight max.
        return Center(
          child: ConsoleDialogShell(
            key: const Key('sessions_manager'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                AppText(
                  l10n.sessionsManagerTitle,
                  style: TextStyle(
                    color: surface.textPrimary,
                    fontSize: 19,
                    height: 1.15,
                    fontWeight: FontWeight.w600,
                    leadingDistribution: TextLeadingDistribution.even,
                  ),
                ),
                if (loadError != null) ...[
                  const SizedBox(height: 14),
                  ConsoleBanner(
                    key: const Key('sessions_loadError'),
                    message: loadError,
                    tone: ConsoleBannerTone.failure,
                  ),
                ],
                const SizedBox(height: 19),
                if (state.sessions.isEmpty)
                  Padding(
                    key: const Key('sessions_empty'),
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: AppText(
                      l10n.sessionsEmpty,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: surface.textSecondary,
                        fontSize: 16,
                        height: 1.25,
                        leadingDistribution: TextLeadingDistribution.even,
                      ),
                    ),
                  )
                else
                  ConstrainedBox(
                    constraints: const BoxConstraints(
                      maxHeight: _listMaxHeight,
                    ),
                    child: SingleChildScrollView(
                      child: ConsoleCard(
                        children: [
                          for (final (i, summary) in state.sessions.indexed)
                            _SessionRow(
                              summary: summary,
                              isCurrent:
                                  summary.name == state.currentSessionName,
                              isLast: i == state.sessions.length - 1,
                            ),
                        ],
                      ),
                    ),
                  ),
                const SizedBox(height: 19),
                _ActionRow(state: state),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// One saved session's 70px row: the name, when it was last saved, and — on
/// the open one — the highlight. Tap loads it and the dialog STAYS OPEN: the
/// action row below targets the open session, so closing on load would make
/// Rename/Duplicate/Delete one dialog-reopen more expensive than the pen
/// draws them.
class _SessionRow extends StatelessWidget {
  const _SessionRow({
    required this.summary,
    required this.isCurrent,
    required this.isLast,
  });

  final SessionSummary summary;
  final bool isCurrent;
  final bool isLast;

  /// The pen's date column: `today 14:02`, `yesterday`, then `3 Aug`.
  static String _dateLabel(BuildContext context, DateTime? at) {
    if (at == null) return '';
    final l10n = context.l10n;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(at.year, at.month, at.day);
    if (day == today) {
      final hh = at.hour.toString().padLeft(2, '0');
      final mm = at.minute.toString().padLeft(2, '0');
      return l10n.sessionDateToday('$hh:$mm');
    }
    if (day == today.subtract(const Duration(days: 1))) {
      return l10n.sessionDateYesterday;
    }
    return DateFormat.MMMd(
      Localizations.localeOf(context).toString(),
    ).format(at);
  }

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<SessionCubit>();
    return ConsoleRow(
      key: Key('sessions_card_${summary.name}'),
      title: summary.name,
      state: _dateLabel(context, summary.modifiedAt),
      // The open session's row is a selected row, and `accentSurface` is the
      // token for a selected control's fill — the inline 12% wash it replaces
      // was invisible to the high-contrast flavor, which lifts the token
      // (#768).
      fill: isCurrent ? context.surface.accentSurface : null,
      showDisclosure: false,
      showDivider: !isLast,
      onTap: () => unawaited(cubit.loadNamed(summary.name)),
    );
  }
}

/// The pen's action row: Rename / Duplicate / Delete on the open session,
/// then Save as… and Save. The first three need a session to act on and
/// disable without one ("Unsaved" is not a thing that can be renamed).
class _ActionRow extends StatelessWidget {
  const _ActionRow({required this.state});

  final SessionState state;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final cubit = context.read<SessionCubit>();
    final current = state.currentSessionName;
    return Row(
      spacing: 10,
      children: [
        ConsoleSmallButton(
          key: const Key('sessions_rename'),
          label: l10n.sessionRename,
          onPressed: current == null
              ? null
              : () => unawaited(_rename(context, cubit, current)),
        ),
        ConsoleSmallButton(
          key: const Key('sessions_duplicate'),
          label: l10n.sessionDuplicate,
          onPressed: current == null
              ? null
              : () => unawaited(promptDuplicate(context, current)),
        ),
        ConsoleSmallButton(
          key: const Key('sessions_delete'),
          label: l10n.sessionDelete,
          onPressed: current == null
              ? null
              : () => unawaited(_delete(context, cubit, current)),
        ),
        const Spacer(),
        ConsoleSmallButton(
          key: const Key('sessions_saveAs'),
          label: l10n.sessionSaveAs,
          onPressed: () => unawaited(promptSaveAs(context)),
        ),
        ConsoleDialogButton(
          key: const Key('sessions_save'),
          label: l10n.sessionSave,
          tone: ConsoleDialogTone.accent,
          // Write back to the open session, or prompt Save-As when none.
          onPressed: () => current == null
              ? unawaited(promptSaveAs(context))
              : unawaited(cubit.save()),
        ),
      ],
    );
  }

  Future<void> _rename(
    BuildContext context,
    SessionCubit cubit,
    String current,
  ) async {
    final l10n = context.l10n;
    final to = await _promptName(
      context,
      title: l10n.sessionRenameTitle,
      initial: current,
      // Every other name is taken; the session's own name is allowed (a
      // no-op).
      taken: cubit.state.sessions
          .map((s) => s.name)
          .where((n) => n != current)
          .toSet(),
    );
    if (to == null) return;
    await cubit.renameSession(current, to);
  }

  Future<void> _delete(
    BuildContext context,
    SessionCubit cubit,
    String current,
  ) async {
    final confirmed = await _confirmDelete(context, current);
    if (!confirmed) return;
    await cubit.deleteSession(current);
  }
}

class _SessionNameDialog extends StatefulWidget {
  const _SessionNameDialog({
    required this.title,
    required this.initial,
    required this.taken,
  });

  final String title;
  final String initial;
  final Set<String> taken;

  @override
  State<_SessionNameDialog> createState() => _SessionNameDialogState();
}

class _SessionNameDialogState extends State<_SessionNameDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  );
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final l10n = context.l10n;
    final raw = _controller.text;
    final slug = sessionSlug(raw);
    if (slug == null) {
      setState(() => _error = l10n.sessionNameInvalid);
      return;
    }
    if (widget.taken.contains(slug)) {
      setState(() => _error = l10n.sessionNameDuplicate(slug));
      return;
    }
    Navigator.of(context).pop(raw);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      title: AppText(widget.title),
      content: TextField(
        key: const Key('sessionName_field'),
        controller: _controller,
        autofocus: true,
        decoration: InputDecoration(
          hintText: l10n.sessionNameHint,
          errorText: _error,
        ),
        onChanged: (_) {
          if (_error != null) setState(() => _error = null);
        },
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: AppText(l10n.cancel),
        ),
        TextButton(
          key: const Key('sessionName_save'),
          onPressed: _submit,
          child: AppText(l10n.save),
        ),
      ],
    );
  }
}

/// Confirms a destructive delete of session [name] on the console's own
/// dialog; resolves `true` only if the user confirms.
Future<bool> _confirmDelete(BuildContext context, String name) async {
  final l10n = context.l10n;
  final surface = context.surface;
  final confirmed = await showDialog<bool>(
    context: context,
    barrierColor: surface.scrim,
    builder: (dialogContext) => Center(
      child: ConsoleDialogShell(
        key: const Key('sessionDelete_dialog'),
        width: 552,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            AppText(
              l10n.sessionDeleteConfirmTitle(name),
              style: TextStyle(
                color: surface.textPrimary,
                fontSize: 19,
                height: 1.15,
                fontWeight: FontWeight.w600,
                leadingDistribution: TextLeadingDistribution.even,
              ),
            ),
            const SizedBox(height: 10),
            AppText(
              l10n.sessionDeleteConfirmBody,
              style: TextStyle(
                color: surface.textSecondary,
                fontSize: 16,
                height: 1.25,
                leadingDistribution: TextLeadingDistribution.even,
              ),
            ),
            const SizedBox(height: 19),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              spacing: 10,
              children: [
                ConsoleDialogButton(
                  label: l10n.cancel,
                  onPressed: () => Navigator.of(dialogContext).pop(false),
                ),
                ConsoleDialogButton(
                  key: const Key('sessionDelete_confirm'),
                  label: l10n.sessionDelete,
                  tone: ConsoleDialogTone.destructive,
                  onPressed: () => Navigator.of(dialogContext).pop(true),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
  return confirmed ?? false;
}
