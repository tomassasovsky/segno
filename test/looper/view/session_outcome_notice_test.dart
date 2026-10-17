import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/view/tracks_commands.dart';
import 'package:segno/session/session.dart';
import 'package:session_repository/session_repository.dart';

import '../../helpers/helpers.dart';

void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));

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

    testWidgets('tells the player a loaded session was converted and what '
        'it changed', (tester) async {
      await show(
        tester,
        const SessionState(
          status: SessionStatus.success,
          outcome: SessionOutcome.loaded,
          conversion: SessionConversionNotice(
            fromVersion: 7,
            written: true,
            changes: {
              SessionConversionChange.masterEffectsMoved,
              SessionConversionChange.monitorLevelLowered,
              SessionConversionChange.tempoFromLoop,
            },
          ),
        ),
      );
      expect(
        find.text(
          '${l10n.sessionLoadedConverted} ${l10n.sessionConvertedMasterMoved} '
          '${l10n.sessionConvertedMonitorLowered} '
          '${l10n.sessionConvertedTempoFromLoop}',
        ),
        findsOneWidget,
      );
    });

    testWidgets('does not claim a backup the write-back did not make', (
      tester,
    ) async {
      await show(
        tester,
        const SessionState(
          status: SessionStatus.success,
          outcome: SessionOutcome.loaded,
          conversion: SessionConversionNotice(fromVersion: 7, written: false),
        ),
      );
      expect(find.text(l10n.sessionLoadedConvertedUnsaved), findsOneWidget);
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
      expect(find.text(l10n.sessionErrorUnconvertible), findsOneWidget);
    });
  });
}
