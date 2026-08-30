import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/l10n/gen/app_localizations.dart';
import 'package:segno/session/session.dart';
import 'package:segno/theme/theme.dart';
import 'package:session_repository/session_repository.dart';

class _MockSessionCubit extends MockCubit<SessionState>
    implements SessionCubit {}

class _MockPedalRepository extends Mock implements PedalRepository {}

void main() {
  group('SessionsManagerDialog', () {
    late SessionCubit session;
    late PedalRepository defaultPedal;

    const two = [SessionSummary(name: 'A'), SessionSummary(name: 'B')];
    const five = [
      SessionSummary(name: 'A'),
      SessionSummary(name: 'B'),
      SessionSummary(name: 'C'),
      SessionSummary(name: 'D'),
      SessionSummary(name: 'E'),
    ];

    setUp(() {
      session = _MockSessionCubit();
      defaultPedal = _MockPedalRepository();
      when(
        () => defaultPedal.events,
      ).thenAnswer((_) => const Stream<PedalEvent>.empty());
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
      PedalRepository? pedal,
    }) async {
      whenListen(
        session,
        const Stream<SessionState>.empty(),
        initialState: state,
      );
      final home = RepositoryProvider<PedalRepository>.value(
        value: pedal ?? defaultPedal,
        child: BlocProvider<SessionCubit>.value(
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
          home: home,
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    /// Types [name] into the console rename sheet and confirms with Enter.
    ///
    /// The sheet reads `KeyEvent.character`, so there is no text field to
    /// `enterText` into -- each character is sent as its own key event.
    Future<void> typeSheetName(WidgetTester tester, String name) async {
      for (var i = 0; i < 40; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      }
      for (final ch in name.split('')) {
        await tester.sendKeyEvent(LogicalKeyboardKey.keyA, character: ch);
      }
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
    }

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
      await typeSheetName(tester, 'Chorus');
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
      await typeSheetName(tester, 'A copy');
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

    testWidgets('the delete confirm shrinks instead of filling the screen', (
      tester,
    ) async {
      await openManager(
        tester,
        state: const SessionState(currentSessionName: 'A', sessions: two),
      );
      await tester.tap(find.byKey(const Key('sessions_delete')));
      await tester.pumpAndSettle();
      final size = tester.getSize(
        find.byKey(const Key('sessionDelete_dialog')),
      );
      expect(size.height, lessThan(400));
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
      await typeSheetName(tester, 'B');
      final dup = (await l10n()).sessionNameDuplicate('B');
      expect(find.text(dup), findsOneWidget);
      verifyNever(() => session.renameSession(any(), any()));
    });

    testWidgets('older saves read as yesterday, then as a short date', (
      tester,
    ) async {
      final strings = await l10n();
      final yesterday = DateTime.now().subtract(const Duration(days: 1));
      final older = DateTime(2026, 3, 7, 9, 30);
      await openManager(
        tester,
        state: SessionState(
          sessions: [
            SessionSummary(name: 'A', modifiedAt: yesterday),
            SessionSummary(name: 'B', modifiedAt: older),
          ],
        ),
      );
      expect(find.text(strings.sessionDateYesterday), findsOneWidget);
      // The short-date branch, without pinning one locale's ordering.
      final bRow = tester.widget<ConsoleRow>(
        find.byKey(const Key('sessions_card_B')),
      );
      expect(bRow.state, isNotEmpty);
      expect(bRow.state, isNot(strings.sessionDateYesterday));
    });

    testWidgets('a newer-version refusal shows its own banner', (
      tester,
    ) async {
      final strings = await l10n();
      await openManager(
        tester,
        state: const SessionState(
          sessions: two,
          error: SessionError.unsupportedVersion,
        ),
      );
      expect(
        find.text(strings.sessionErrorUnsupportedVersion),
        findsOneWidget,
      );
    });

    testWidgets('an unsanitizable name shows the inline error', (
      tester,
    ) async {
      await openManager(
        tester,
        state: const SessionState(currentSessionName: 'A', sessions: two),
      );
      await tester.tap(find.byKey(const Key('sessions_rename')));
      await tester.pumpAndSettle();
      await typeSheetName(tester, '///');
      expect(find.text((await l10n()).sessionNameInvalid), findsOneWidget);
      verifyNever(() => session.renameSession(any(), any()));
    });

    testWidgets('cancelling the name prompt renames nothing', (tester) async {
      await openManager(
        tester,
        state: const SessionState(currentSessionName: 'A', sessions: two),
      );
      await tester.tap(find.byKey(const Key('sessions_rename')));
      await tester.pumpAndSettle();
      await tester.tap(find.text((await l10n()).cancel));
      await tester.pumpAndSettle();
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
      await typeSheetName(tester, 'Bridge');
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
      expect(find.byKey(const Key('console_rename_sheet')), findsOneWidget);
      verifyNever(session.save);
    });

    testWidgets('the panel shrinks to its rows instead of filling the screen', (
      tester,
    ) async {
      await openManager(tester, state: const SessionState(sessions: two));
      final size = tester.getSize(find.byKey(const Key('sessions_manager')));
      // The dialog route is the full 600px test surface. A Flexible list
      // used to stretch the shell to that height; the pen is content-height.
      expect(size.height, lessThan(500));
    });

    testWidgets('caps the list at four rows and scrolls to later sessions', (
      tester,
    ) async {
      await openManager(tester, state: const SessionState(sessions: five));
      final scrollView = find.byType(SingleChildScrollView);
      expect(
        tester.getSize(scrollView).height,
        kConsoleRowHeight * 4 + ConsoleCard.borderExtent,
      );

      await tester.drag(
        scrollView,
        const Offset(0, -kConsoleRowHeight * 2),
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('sessions_card_E')));
      await tester.pump();

      verify(() => session.loadNamed('E')).called(1);
    });

    testWidgets('a pedal footswitch press dismisses the dialog', (
      tester,
    ) async {
      final events = StreamController<PedalEvent>.broadcast();
      addTearDown(events.close);
      final pedal = _MockPedalRepository();
      when(() => pedal.events).thenAnswer((_) => events.stream);

      await openManager(
        tester,
        state: const SessionState(sessions: two),
        pedal: pedal,
      );
      expect(find.byKey(const Key('sessions_manager')), findsOneWidget);

      events.add(const ButtonPressed(PedalButton.clear));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('sessions_manager')), findsNothing);
    });

    testWidgets('a pedal press dismisses a nested confirm too', (tester) async {
      final events = StreamController<PedalEvent>.broadcast();
      addTearDown(events.close);
      final pedal = _MockPedalRepository();
      when(() => pedal.events).thenAnswer((_) => events.stream);

      await openManager(
        tester,
        state: const SessionState(currentSessionName: 'A', sessions: two),
        pedal: pedal,
      );
      await tester.tap(find.byKey(const Key('sessions_delete')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('sessionDelete_confirm')), findsOneWidget);

      events.add(const ButtonPressed(PedalButton.recPlay));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('sessionDelete_confirm')), findsNothing);
      expect(find.byKey(const Key('sessions_manager')), findsNothing);
      expect(find.text('open'), findsOneWidget);
      verifyNever(() => session.deleteSession(any()));

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('sessions_manager')), findsOneWidget);
    });

    testWidgets('repeated pedal presses dismiss only the Sessions route', (
      tester,
    ) async {
      final events = StreamController<PedalEvent>.broadcast();
      addTearDown(events.close);
      final pedal = _MockPedalRepository();
      when(() => pedal.events).thenAnswer((_) => events.stream);

      await openManager(
        tester,
        state: const SessionState(sessions: two),
        pedal: pedal,
      );

      events
        ..add(const ButtonPressed(PedalButton.clear))
        ..add(const ButtonPressed(PedalButton.recPlay));
      await tester.pumpAndSettle();

      expect(find.text('open'), findsOneWidget);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('sessions_manager')), findsOneWidget);
    });

    testWidgets('a pedal press racing a barrier dismissal preserves home', (
      tester,
    ) async {
      final events = StreamController<PedalEvent>.broadcast();
      addTearDown(events.close);
      final pedal = _MockPedalRepository();
      when(() => pedal.events).thenAnswer((_) => events.stream);

      await openManager(
        tester,
        state: const SessionState(sessions: two),
        pedal: pedal,
      );

      await tester.tapAt(const Offset(1, 1));
      await tester.pump();
      events.add(const ButtonPressed(PedalButton.clear));
      await tester.pumpAndSettle();

      expect(find.text('open'), findsOneWidget);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('sessions_manager')), findsOneWidget);
    });

    testWidgets('an encoder turn leaves the dialog open', (tester) async {
      final events = StreamController<PedalEvent>.broadcast();
      addTearDown(events.close);
      final pedal = _MockPedalRepository();
      when(() => pedal.events).thenAnswer((_) => events.stream);

      await openManager(
        tester,
        state: const SessionState(sessions: two),
        pedal: pedal,
      );

      events.add(const EncoderDelta(1));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('sessions_manager')), findsOneWidget);
    });
  });
}
