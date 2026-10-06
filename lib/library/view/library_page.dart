import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:operation_guards/operation_guards.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/library/application/removable_volumes.dart';
import 'package:segno/library/cubit/library_cubit.dart';
import 'package:segno/library/view/library_sessions_tab.dart';
import 'package:segno/library/view/new_loop_sheet.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_frame.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/session/session.dart';
import 'package:segno/theme/theme.dart';
import 'package:session_repository/session_repository.dart';

/// The full-screen Library (pen `01 CURRENT UX` 19/01): saved sessions with
/// search, folders and a preview that never loads.
///
/// Provides the page's [LibraryCubit], selecting the current session, and
/// re-reads the session catalog so the list is fresh.
class LibraryPage extends StatelessWidget {
  /// Creates the Library page.
  const LibraryPage({super.key});

  @override
  Widget build(BuildContext context) => BlocProvider(
    create: (context) {
      final session = context.read<SessionCubit>();
      unawaited(session.refreshSessions());
      final cubit = LibraryCubit(
        sessions: context.read<SessionRepository>(),
        volumes: context.read<RemovableVolumes>(),
        pedal: context.read<PedalRepository>(),
      );
      if (session.state.currentSessionId case final current?) {
        unawaited(cubit.select(current));
      }
      return cubit;
    },
    child: const LibraryView(),
  );
}

/// The Library's frame: the topbar with the section tab and Stage, the
/// title row with the location segment and New loop, the Sessions tab, and
/// under it the line that reports a failed action (pen 19/05).
///
/// A footswitch press returns to Tracks, as Stage does (plan D14). After
/// every catalog action the selection is re-read: a Save as or an automatic
/// save selects the new current session, and a deleted selection falls back
/// to the current one.
///
/// The 19/05 line reports only failures of actions taken while this page is
/// open. A failure other than a save is dropped once another row is
/// selected; a failed save stays until a later action, as it stays true.
class LibraryView extends StatefulWidget {
  /// Creates the Library view.
  const LibraryView({super.key});

  @override
  State<LibraryView> createState() => _LibraryViewState();
}

class _LibraryViewState extends State<LibraryView> {
  /// The session state whose failure the line does not show: the one the
  /// page opened onto, or the one a later selection moved past.
  late SessionState _dismissed = context.read<SessionCubit>().state;

  void _toTracks() => Navigator.popUntil(context, (route) => route.isFirst);

  void _reselect(BuildContext context, SessionState session) {
    final library = context.read<LibraryCubit>();
    if (library.state.folderFilter case FolderSessions(
      :final folder,
    ) when !session.folders.contains(folder)) {
      // The chip's folder was renamed or deleted.
      library.filterFolder(const AllSessions());
    }
    final selected = library.state.selectedId;
    final current = session.currentSessionId;
    final SessionId? next;
    if (session.outcome == SessionOutcome.savedAs) {
      next = current;
    } else if (selected != null &&
        session.sessions.any((s) => s.id == selected)) {
      next = selected;
    } else {
      next = current;
    }
    if (next == null) {
      library.clearSelection();
    } else {
      unawaited(library.select(next));
    }
  }

  void _dismissOnSelection(BuildContext context, LibraryState _) {
    final session = context.read<SessionCubit>().state;
    if (libraryFailureOf(session) case final failure?
        when failure != LibraryFailure.saveFailed) {
      setState(() => _dismissed = session);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final session = context.watch<SessionCubit>().state;
    final failure = identical(session, _dismissed)
        ? null
        : libraryFailureOf(session);
    return MultiBlocListener(
      listeners: [
        BlocListener<LibraryCubit, LibraryState>(
          listenWhen: (previous, current) =>
              !previous.dismissalRequested && current.dismissalRequested,
          listener: (context, _) => _toTracks(),
        ),
        BlocListener<LibraryCubit, LibraryState>(
          listenWhen: (previous, current) =>
              previous.selectedId != current.selectedId,
          listener: _dismissOnSelection,
        ),
        BlocListener<SessionCubit, SessionState>(
          listenWhen: (previous, current) =>
              previous.status != current.status &&
              current.status == SessionStatus.success,
          listener: _reselect,
        ),
        // A new loop is played on the stage (19/06), which names it.
        BlocListener<SessionCubit, SessionState>(
          listenWhen: (previous, current) =>
              previous.status != current.status &&
              current.status == SessionStatus.success &&
              current.outcome == SessionOutcome.newLoop,
          listener: (_, _) => _toTracks(),
        ),
      ],
      child: Material(
        type: MaterialType.transparency,
        child: LoopSettingsFrame(
          key: const Key('library_page'),
          tabs: LoopChoiceButton(
            key: const Key('library_tab_sessions'),
            label: l10n.librarySessions,
            selected: true,
            onTap: () {},
            width: 180,
            height: 64,
          ),
          title: l10n.libraryTitle,
          titleLeft: 64,
          onBack: () => Navigator.pop(context),
          onStage: _toTracks,
          actions: const LibraryActions(),
          children: [
            // 19/05 shortens the layout by 60 to make room for the line.
            Positioned(
              left: 64,
              top: 128,
              width: 1792,
              height: failure != null ? 760 : 820,
              child: const LibrarySessionsTab(),
            ),
            if (failure != null)
              Positioned(
                left: 64,
                top: 916,
                width: 1792,
                height: 33,
                child: LibraryFailureLine(
                  failure: failure,
                  refusedBy: session.refusedBy,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The failures the Library reports on its 19/05 line.
enum LibraryFailure {
  /// A save failed: the pen's "Could not save your current loop. Nothing
  /// was changed."
  saveFailed,

  /// The open session was asked to be deleted.
  deleteCurrentRefused,

  /// A folder that still holds sessions was asked to be deleted.
  folderNotEmpty,

  /// An Open or New loop ended a take that did not finish in time.
  captureInProgress,

  /// Any other catalog action failed.
  actionFailed,

  /// Refused at its commit because another operation is in flight (the
  /// guard table, #1198); the line names what to wait for.
  busy,
}

/// What the Library says about the last session action's failure, or null
/// when there is nothing to say here: an Open's refusal shows on the preview
/// card of the session that refused, and a boot recovery has its own
/// app-wide notice.
LibraryFailure? libraryFailureOf(SessionState state) {
  if (state.status != SessionStatus.failure) return null;
  // A save that failed before an Open (plan D7) is still a failed save.
  if (state.error == SessionError.saveFailed) return LibraryFailure.saveFailed;
  // The outgoing take, not the target, stopped an Open.
  if (state.error == SessionError.captureInProgress) {
    return LibraryFailure.captureInProgress;
  }
  if (state.failedSessionId != null) return null;
  return switch (state.error) {
    SessionError.bootPersistence => null,
    SessionError.sampleRateMismatch ||
    SessionError.unsupportedVersion ||
    SessionError.unconvertible => LibraryFailure.actionFailed,
    SessionError.saveFailed => LibraryFailure.saveFailed,
    SessionError.currentSessionProtected => LibraryFailure.deleteCurrentRefused,
    SessionError.folderNotEmpty => LibraryFailure.folderNotEmpty,
    SessionError.busy => LibraryFailure.busy,
    SessionError.captureInProgress => LibraryFailure.captureInProgress,
    SessionError.nameCollision ||
    SessionError.corruptLayers ||
    SessionError.unknown ||
    null => LibraryFailure.actionFailed,
  };
}

/// The pen's 19/05 line under the layout: "Could not save your current
/// loop. Nothing was changed." for a failed save, and the same place for
/// any other failed catalog action.
class LibraryFailureLine extends StatelessWidget {
  /// Creates the line for [failure].
  const LibraryFailureLine({
    required this.failure,
    this.refusedBy,
    super.key,
  });

  /// What failed.
  final LibraryFailure failure;

  /// For [LibraryFailure.busy]: the operation that refused the action.
  final GuardKind? refusedBy;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final message = switch (failure) {
      LibraryFailure.saveFailed => l10n.librarySaveFailed,
      LibraryFailure.deleteCurrentRefused => l10n.libraryDeleteCurrentRefused,
      LibraryFailure.folderNotEmpty => l10n.libraryFolderNotEmpty,
      LibraryFailure.captureInProgress => l10n.libraryTakeStillRunning,
      LibraryFailure.actionFailed => l10n.libraryActionFailed,
      LibraryFailure.busy => l10n.operationBusy(refusedBy?.name ?? 'other'),
    };
    return Semantics(
      liveRegion: true,
      child: Align(
        alignment: Alignment.centerLeft,
        child: AppText(
          message,
          key: const Key('library_failure'),
          style: TextStyle(
            color: context.surface.rec,
            fontSize: 23,
            height: 1,
          ),
        ),
      ),
    );
  }
}

/// The title row's actions: the `Internal` / `USB` location segment and
/// `New loop`, which asks first (19/02) and is inert while another session
/// action runs.
class LibraryActions extends StatelessWidget {
  /// Creates the Library's title-row actions.
  const LibraryActions({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final location = context.select<LibraryCubit, LibraryLocation>(
      (c) => c.state.location,
    );
    final busy = context.select<SessionCubit, bool>(
      (c) => c.state.status == SessionStatus.working,
    );
    final cubit = context.read<LibraryCubit>();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        LoopChoiceButton(
          key: const Key('library_location_internal'),
          label: l10n.libraryInternal,
          selected: location == LibraryLocation.internal,
          onTap: () => cubit.setLocation(LibraryLocation.internal),
          width: 160,
          height: 64,
        ),
        const SizedBox(width: 12),
        LoopChoiceButton(
          key: const Key('library_location_usb'),
          label: l10n.libraryUsb,
          selected: location == LibraryLocation.usb,
          onTap: () => cubit.setLocation(LibraryLocation.usb),
          width: 160,
          height: 64,
        ),
        const SizedBox(width: 40),
        Opacity(
          // Inert while another session action runs, and drawn so.
          opacity: busy ? context.surface.disabledOpacity : 1,
          child: LoopOutlinedButton(
            key: const Key('library_new_loop'),
            width: 157,
            tone: LoopButtonTone.accent,
            label: l10n.libraryNewLoop,
            onTap: busy ? null : () => unawaited(startNewLoop(context)),
          ),
        ),
      ],
    );
  }
}
