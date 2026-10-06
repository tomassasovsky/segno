import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/library/application/removable_volumes.dart';
import 'package:segno/library/cubit/library_cubit.dart';
import 'package:segno/library/view/library_sessions_tab.dart';
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
      unawaited(cubit.start(selected: session.state.currentSessionId));
      return cubit;
    },
    child: const LibraryView(),
  );
}

/// The Library's frame: the topbar with the section tab and Stage, the
/// title row with the location segment and New loop, and the Sessions tab.
///
/// A footswitch press returns to Tracks, as Stage does (plan D14).
class LibraryView extends StatelessWidget {
  /// Creates the Library view.
  const LibraryView({super.key});

  static void _toTracks(BuildContext context) =>
      Navigator.popUntil(context, (route) => route.isFirst);

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return BlocListener<LibraryCubit, LibraryState>(
      listenWhen: (previous, current) =>
          !previous.dismissalRequested && current.dismissalRequested,
      listener: (context, _) => _toTracks(context),
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
          onStage: () => _toTracks(context),
          actions: const LibraryActions(),
          children: const [
            Positioned(
              left: 64,
              top: 128,
              width: 1792,
              height: 820,
              child: LibrarySessionsTab(),
            ),
          ],
        ),
      ),
    );
  }
}

/// The title row's actions: the `Internal` / `USB` location segment and
/// `New loop`.
///
/// `New loop` is drawn disabled until it is built (plan Part 5): the one
/// stand-in the plan allows, because the row's geometry needs it.
class LibraryActions extends StatelessWidget {
  /// Creates the Library's title-row actions.
  const LibraryActions({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final location = context.select<LibraryCubit, LibraryLocation>(
      (c) => c.state.location,
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
          opacity: context.surface.disabledOpacity,
          child: LoopOutlinedButton(
            key: const Key('library_new_loop'),
            width: 157,
            tone: LoopButtonTone.accent,
            label: l10n.libraryNewLoop,
            onTap: null,
          ),
        ),
      ],
    );
  }
}
