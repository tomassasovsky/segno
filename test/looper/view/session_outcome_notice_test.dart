import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/view/tracks_commands.dart';
import 'package:segno/session/session.dart';

import '../../helpers/helpers.dart';

void main() {
  group('showSessionOutcome', () {
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

    testWidgets('tells the player a loaded session was converted', (
      tester,
    ) async {
      await show(
        tester,
        const SessionState(
          status: SessionStatus.success,
          outcome: SessionOutcome.loaded,
          convertedFrom: 7,
        ),
      );
      final l10n = lookupAppLocalizations(const Locale('en'));
      expect(find.text(l10n.sessionLoadedConverted), findsOneWidget);
      expect(find.text(l10n.sessionLoaded), findsNothing);
    });

    testWidgets('keeps the plain notice for a current session', (
      tester,
    ) async {
      await show(
        tester,
        const SessionState(
          status: SessionStatus.success,
          outcome: SessionOutcome.loaded,
        ),
      );
      final l10n = lookupAppLocalizations(const Locale('en'));
      expect(find.text(l10n.sessionLoaded), findsOneWidget);
    });

    testWidgets('names an unconvertible older session', (tester) async {
      await show(
        tester,
        const SessionState(
          status: SessionStatus.failure,
          error: SessionError.unconvertible,
        ),
      );
      final l10n = lookupAppLocalizations(const Locale('en'));
      expect(find.text(l10n.sessionErrorUnconvertible), findsOneWidget);
    });
  });
}
