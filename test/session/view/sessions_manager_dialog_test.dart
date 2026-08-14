import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/l10n/gen/app_localizations.dart';
import 'package:segno/session/session.dart';
import 'package:segno/theme/theme.dart';
import 'package:session_repository/session_repository.dart';

class _MockSessionCubit extends MockCubit<SessionState>
    implements SessionCubit {}

void main() {
  late SessionCubit session;

  const two = [SessionSummary(name: 'A'), SessionSummary(name: 'B')];

  setUp(() {
    session = _MockSessionCubit();
    when(session.refreshSessions).thenAnswer((_) async {});
    when(() => session.loadNamed(any())).thenAnswer((_) async {});
    when(() => session.renameSession(any(), any())).thenAnswer((_) async {});
    when(() => session.deleteSession(any())).thenAnswer((_) async {});
    when(
      () => session.duplicateSession(any(), any()),
    ).thenAnswer((_) async {});
    when(() => session.saveAs(any())).thenAnswer((_) async {});
    when(session.save).thenAnswer((_) async {});
    when(() => session.exportMixdown()).thenAnswer((_) async {});
    when(() => session.exportStems()).thenAnswer((_) async {});
  });

  Future<AppLocalizations> l10n() =>
      AppLocalizations.delegate.load(const Locale('en'));

  Future<void> openManager(
    WidgetTester tester, {
    SessionState state = const SessionState(),
  }) async {
    whenListen(
      session,
      const Stream<SessionState>.empty(),
      initialState: state,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          extensions: [
            SurfaceTheme.dark,
            routingGraphThemeFromSurface(SurfaceTheme.dark),
          ],
        ),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: BlocProvider<SessionCubit>.value(
          value: session,
          child: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showSessionsManager(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  group('SessionsManagerDialog', () {
    testWidgets('refreshes the catalog on open', (tester) async {
      await openManager(tester);
      verify(session.refreshSessions).called(1);
    });

    testWidgets('renders a row per saved session', (tester) async {
      await openManager(tester, state: const SessionState(sessions: two));
      expect(find.byKey(const Key('sessions_card_A')), findsOneWidget);
      expect(find.byKey(const Key('sessions_card_B')), findsOneWidget);
    });

    testWidgets('shows the empty state with no sessions', (tester) async {
      await openManager(tester);
      expect(find.byKey(const Key('sessions_empty')), findsOneWidget);
    });

    testWidgets('the open session is the highlighted row', (tester) async {
      await openManager(
        tester,
        state: const SessionState(currentSessionName: 'A', sessions: two),
      );
      // The old header line said which session was open; the pen says it with
      // the row itself. The tint is the visible fact, so the tint is what is
      // pinned.
      final a = tester.widget<ConsoleRow>(
        find.byKey(const Key('sessions_card_A')),
      );
      final b = tester.widget<ConsoleRow>(
        find.byKey(const Key('sessions_card_B')),
      );
      expect(a.fill, isNotNull);
      expect(b.fill, isNull);
    });

    testWidgets('a session saved today reads as today, with the time', (
      tester,
    ) async {
      final strings = await l10n();
      final at = DateTime.now().copyWith(hour: 14, minute: 2);
      await openManager(
        tester,
        state: SessionState(
          sessions: [SessionSummary(name: 'A', modifiedAt: at)],
        ),
      );
      expect(find.text(strings.sessionDateToday('14:02')), findsOneWidget);
    });

    testWidgets('tapping a row loads it and the dialog stays open', (
      tester,
    ) async {
      await openManager(tester, state: const SessionState(sessions: two));
      await tester.tap(find.byKey(const Key('sessions_card_A')));
      await tester.pumpAndSettle();
      verify(() => session.loadNamed('A')).called(1);
      // Open, deliberately: the action row below targets the open session,
      // and a dialog that closed on load would make Rename one reopen more
      // expensive than the pen draws it.
      expect(find.byKey(const Key('sessions_manager')), findsOneWidget);
    });

    testWidgets(
      'rename, duplicate and delete disable with no open session',
      (tester) async {
        await openManager(tester, state: const SessionState(sessions: two));
        for (final key in const [
          'sessions_rename',
          'sessions_duplicate',
          'sessions_delete',
        ]) {
          expect(
            tester.widget<ConsoleSmallButton>(find.byKey(Key(key))).onPressed,
            isNull,
            reason: '$key must need a session to act on',
          );
        }
      },
    );

    testWidgets('renaming the open session fires the cubit', (tester) async {
      await openManager(
        tester,
        state: const SessionState(currentSessionName: 'A', sessions: two),
      );
      await tester.tap(find.byKey(const Key('sessions_rename')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('sessionName_field')),
        'Chorus',
      );
      await tester.tap(find.byKey(const Key('sessionName_save')));
      await tester.pumpAndSettle();
      verify(() => session.renameSession('A', 'Chorus')).called(1);
    });

    testWidgets('duplicating the open session fires the cubit', (
      tester,
    ) async {
      await openManager(
        tester,
        state: const SessionState(currentSessionName: 'A', sessions: two),
      );
      await tester.tap(find.byKey(const Key('sessions_duplicate')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('sessionName_field')),
        'A copy',
      );
      await tester.tap(find.byKey(const Key('sessionName_save')));
      await tester.pumpAndSettle();
      verify(() => session.duplicateSession('A', 'A copy')).called(1);
    });

    testWidgets('deleting the open session confirms then fires', (
      tester,
    ) async {
      await openManager(
        tester,
        state: const SessionState(currentSessionName: 'A', sessions: two),
      );
      await tester.tap(find.byKey(const Key('sessions_delete')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('sessionDelete_confirm')));
      await tester.pumpAndSettle();
      verify(() => session.deleteSession('A')).called(1);
    });

    testWidgets('cancelling the delete confirm does nothing', (tester) async {
      await openManager(
        tester,
        state: const SessionState(currentSessionName: 'A', sessions: two),
      );
      await tester.tap(find.byKey(const Key('sessions_delete')));
      await tester.pumpAndSettle();
      await tester.tap(find.text((await l10n()).cancel));
      await tester.pumpAndSettle();
      verifyNever(() => session.deleteSession(any()));
    });

    testWidgets('a rename collision shows an inline error', (tester) async {
      await openManager(
        tester,
        state: const SessionState(currentSessionName: 'A', sessions: two),
      );
      await tester.tap(find.byKey(const Key('sessions_rename')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('sessionName_field')), 'B');
      await tester.tap(find.byKey(const Key('sessionName_save')));
      await tester.pumpAndSettle();
      final dup = (await l10n()).sessionNameDuplicate('B');
      expect(find.text(dup), findsOneWidget);
      verifyNever(() => session.renameSession(any(), any()));
    });

    testWidgets('a refused load shows the banner the pen draws', (
      tester,
    ) async {
      final strings = await l10n();
      await openManager(
        tester,
        state: const SessionState(
          sessions: two,
          error: SessionError.sampleRateMismatch,
        ),
      );
      expect(find.byKey(const Key('sessions_loadError')), findsOneWidget);
      expect(find.text(strings.sessionErrorSampleRate), findsOneWidget);
    });

    testWidgets('Save as… saves a new named session', (tester) async {
      await openManager(tester, state: const SessionState(sessions: two));
      await tester.tap(find.byKey(const Key('sessions_saveAs')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('sessionName_field')),
        'Bridge',
      );
      await tester.tap(find.byKey(const Key('sessionName_save')));
      await tester.pumpAndSettle();
      verify(() => session.saveAs('Bridge')).called(1);
    });

    testWidgets('Save writes back when a session is open', (tester) async {
      await openManager(
        tester,
        state: const SessionState(currentSessionName: 'A', sessions: two),
      );
      await tester.tap(find.byKey(const Key('sessions_save')));
      await tester.pumpAndSettle();
      verify(session.save).called(1);
    });

    testWidgets('Save with no open session opens Save-As', (tester) async {
      await openManager(tester, state: const SessionState(sessions: two));
      await tester.tap(find.byKey(const Key('sessions_save')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('sessionName_field')), findsOneWidget);
      verifyNever(session.save);
    });

    testWidgets('the exports fire the cubit', (tester) async {
      await openManager(tester, state: const SessionState(sessions: two));
      await tester.tap(find.byKey(const Key('sessions_exportMixdown')));
      await tester.pumpAndSettle();
      verify(() => session.exportMixdown()).called(1);
      await tester.tap(find.byKey(const Key('sessions_exportStems')));
      await tester.pumpAndSettle();
      verify(() => session.exportStems()).called(1);
    });
  });
}
