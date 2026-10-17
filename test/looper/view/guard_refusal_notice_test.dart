import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:operation_guards/operation_guards.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/view/tracks_commands.dart';
import 'package:segno/performance/performance.dart';
import 'package:segno/session/session.dart';

import '../../helpers/helpers.dart';

/// A refusal at commit (#1198, the guard table) has to say what to wait for:
/// a silent no-op on Record is indistinguishable from a dead control.
void main() {
  late AppLocalizations l10n;

  Future<BuildContext> pumpHost(WidgetTester tester) async {
    late BuildContext captured;
    await tester.pumpApp(
      Scaffold(
        body: Builder(
          builder: (context) {
            captured = context;
            return const SizedBox();
          },
        ),
      ),
    );
    l10n = AppLocalizations.of(captured);
    return captured;
  }

  testWidgets('a refused arm shows a toast naming what it waits for', (
    tester,
  ) async {
    final context = await pumpHost(tester);
    onPerformanceRecorderState(
      context,
      const PerformanceRecorderIdle(refusedBy: GuardKind.sessionApply),
    );
    await tester.pump();
    expect(
      find.byKey(const Key('tracks_perfArmRefused_snackbar')),
      findsOneWidget,
    );
    expect(
      find.text(
        "Recording didn't start. A session is opening. Try again when it "
        'has opened.',
      ),
      findsOneWidget,
    );
    expect(
      l10n.operationBusy(GuardKind.deviceChange.name),
      'The audio interface is changing. Try again in a moment.',
    );
  });

  testWidgets('every guard kind has its own words', (tester) async {
    await pumpHost(tester);
    final words = {
      for (final kind in GuardKind.values) l10n.operationBusy(kind.name),
    };
    expect(words, hasLength(GuardKind.values.length));
    expect(
      words,
      isNot(contains('Something else is running. Try again in a moment.')),
    );
  });

  testWidgets('a plain idle shows nothing', (tester) async {
    final context = await pumpHost(tester);
    onPerformanceRecorderState(context, const PerformanceRecorderIdle());
    await tester.pump();
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('a refused session action is real copy, not a developer string', (
    tester,
  ) async {
    final context = await pumpHost(tester);
    showSessionOutcome(
      context,
      const SessionState(
        status: SessionStatus.failure,
        error: SessionError.busy,
        errorMessage: 'GuardRefused(GuardKind.sessionApply, blocked by [])',
        refusedBy: GuardKind.restart,
      ),
    );
    await tester.pump();
    expect(find.text('The console is shutting down.'), findsOneWidget);
    expect(find.textContaining('GuardRefused'), findsNothing);
  });
}
