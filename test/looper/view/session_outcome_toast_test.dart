import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/l10n/gen/app_localizations.dart';
import 'package:segno/looper/view/tracks_commands.dart';
import 'package:segno/session/session.dart';

import '../../helpers/helpers.dart';

void main() {
  group('showSessionOutcome', () {
    late AppLocalizations l10n;

    setUpAll(() async {
      l10n = await AppLocalizations.delegate.load(const Locale('en'));
    });

    Future<void> show(WidgetTester tester, SessionState state) async {
      await tester.pumpApp(
        Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showSessionOutcome(context, state),
              child: const Text('show'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('show'));
      await tester.pump();
    }

    testWidgets('a quick Save that named the session says which name', (
      tester,
    ) async {
      await show(
        tester,
        const SessionState(
          status: SessionStatus.success,
          outcome: SessionOutcome.savedAs,
          currentSessionId: 's-1',
          currentSessionName: 'New loop 2',
        ),
      );
      expect(find.text(l10n.sessionSavedAs('New loop 2')), findsOneWidget);
    });

    testWidgets('a folder that still holds sessions says so', (tester) async {
      await show(
        tester,
        const SessionState(
          status: SessionStatus.failure,
          error: SessionError.folderNotEmpty,
        ),
      );
      expect(find.text(l10n.libraryFolderNotEmpty), findsOneWidget);
    });

    testWidgets('a failed save says nothing was changed', (tester) async {
      await show(
        tester,
        const SessionState(
          status: SessionStatus.failure,
          error: SessionError.saveFailed,
        ),
      );
      expect(find.text(l10n.librarySaveFailed), findsOneWidget);
    });

    testWidgets('a new loop that could not be saved names itself', (
      tester,
    ) async {
      await show(
        tester,
        const SessionState(
          status: SessionStatus.failure,
          error: SessionError.newLoopNotSaved,
          currentSessionName: 'New loop 2',
        ),
      );
      expect(find.text(l10n.sessionNewLoopNotSaved('New loop 2')), findsOne);
    });

    testWidgets('an unfinished take says so', (tester) async {
      await show(
        tester,
        const SessionState(
          status: SessionStatus.failure,
          error: SessionError.captureInProgress,
        ),
      );
      expect(find.text(l10n.libraryTakeStillRunning), findsOneWidget);
    });

    testWidgets('a new loop raises no toast: the stage header names it', (
      tester,
    ) async {
      await show(
        tester,
        const SessionState(
          status: SessionStatus.success,
          outcome: SessionOutcome.newLoop,
          currentSessionName: 'New loop 2',
        ),
      );
      expect(find.byKey(const Key('tracks_session_snackbar')), findsNothing);
    });

    testWidgets('the Library catalog outcomes raise no toast behind it', (
      tester,
    ) async {
      for (final outcome in [
        SessionOutcome.renamed,
        SessionOutcome.deleted,
        SessionOutcome.duplicated,
        SessionOutcome.moved,
        SessionOutcome.folderCreated,
        SessionOutcome.folderRenamed,
        SessionOutcome.folderDeleted,
      ]) {
        await show(
          tester,
          SessionState(status: SessionStatus.success, outcome: outcome),
        );
        expect(
          find.byKey(const Key('tracks_session_snackbar')),
          findsNothing,
          reason: outcome.name,
        );
      }
    });
  });
}
