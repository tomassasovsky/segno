import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:segno/l10n/gen/app_localizations.dart';
import 'package:segno/session/session.dart';
import 'package:session_repository/session_repository.dart';

import '../../helpers/helpers.dart';

class _MockSessionCubit extends MockCubit<SessionState>
    implements SessionCubit {}

void main() {
  group('promptSaveAs', () {
    late SessionCubit session;
    late AppLocalizations l10n;

    setUpAll(() async {
      l10n = await AppLocalizations.delegate.load(const Locale('en'));
    });

    setUp(() {
      session = _MockSessionCubit();
      whenListen(
        session,
        const Stream<SessionState>.empty(),
        initialState: const SessionState(
          sessions: [SessionSummary(id: 's-1', name: 'Song')],
        ),
      );
      when(() => session.saveAs(any())).thenAnswer((_) async {});
    });

    Future<void> open(WidgetTester tester) async {
      await tester.pumpApp(
        BlocProvider<SessionCubit>.value(
          value: session,
          child: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => promptSaveAs(context),
                child: const Text('save'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('save'));
      await tester.pumpAndSettle();
    }

    /// Types [name] into the keyboard sheet and confirms.
    Future<void> type(WidgetTester tester, String name) async {
      for (final ch in name.split('')) {
        await tester.sendKeyEvent(LogicalKeyboardKey.keyA, character: ch);
      }
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
    }

    testWidgets('saves a new session under the typed name', (tester) async {
      await open(tester);
      expect(find.byKey(const Key('console_rename_sheet')), findsOneWidget);
      await type(tester, 'Bridge');
      verify(() => session.saveAs('Bridge')).called(1);
    });

    testWidgets('a name that differs only by case is not taken', (
      tester,
    ) async {
      await open(tester);
      await type(tester, 'song');
      verify(() => session.saveAs('song')).called(1);
    });

    testWidgets('a taken name says so and saves nothing', (tester) async {
      await open(tester);
      await type(tester, 'Song!');
      expect(find.text(l10n.sessionNameDuplicate('Song')), findsOneWidget);
      verifyNever(() => session.saveAs(any()));
    });

    testWidgets('an unusable name says so and saves nothing', (tester) async {
      await open(tester);
      await type(tester, '///');
      expect(find.text(l10n.sessionNameInvalid), findsOneWidget);
      verifyNever(() => session.saveAs(any()));
    });

    testWidgets('Cancel saves nothing', (tester) async {
      await open(tester);
      await tester.tap(find.text(l10n.cancel));
      await tester.pumpAndSettle();
      verifyNever(() => session.saveAs(any()));
    });
  });
}
