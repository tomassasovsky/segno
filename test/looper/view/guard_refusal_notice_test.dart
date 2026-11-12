import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:operation_guards/operation_guards.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/view/tracks_commands.dart';
import 'package:segno/notices/notices.dart';
import 'package:segno/performance/performance.dart';

import '../../helpers/helpers.dart';

/// A refusal at commit (#1198, the guard table) has to say what to wait for:
/// a silent no-op on Record is indistinguishable from a dead control.
void main() {
  late AppLocalizations l10n;
  late NoticesCubit notices;

  setUp(() {
    notices = NoticesCubit();
    addTearDown(notices.close);
  });

  Future<BuildContext> pumpHost(WidgetTester tester) async {
    late BuildContext captured;
    await tester.pumpApp(
      notices: notices,
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

  testWidgets('a refused arm says what it waits for', (
    tester,
  ) async {
    final context = await pumpHost(tester);
    onPerformanceRecorderState(
      context,
      const PerformanceRecorderIdle(refusedBy: GuardKind.sessionApply),
    );
    expect(notices.state.message?.notice.title(l10n), "Recording didn't start");
    expect(
      notices.state.message?.notice.body?.call(l10n),
      'A session is opening. Try again when it has opened.',
    );
    expect(notices.state.message?.notice.tone, NoticeTone.warning);
    await tester.pump(const Duration(seconds: 6));
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

  testWidgets('a take that could not be saved or finished says so, and '
      'that Capture is available again (#1639)', (tester) async {
    final context = await pumpHost(tester);
    for (final (failure, words) in [
      (
        PerformanceTakeFailure.notSaved,
        'The take could not be saved. Its files are kept. You can record '
            'again.',
      ),
      (
        PerformanceTakeFailure.notFinished,
        'The take could not be finished. Its files are kept. You can record '
            'again.',
      ),
    ]) {
      onPerformanceRecorderState(
        context,
        PerformanceRecorderIdle(takeFailed: failure),
      );
      expect(notices.state.message?.notice.title(l10n), words);
      expect(notices.state.message?.notice.tone, NoticeTone.warning);
    }
    await tester.pump(const Duration(seconds: 6));
  });

  testWidgets('a plain idle shows nothing', (tester) async {
    final context = await pumpHost(tester);
    onPerformanceRecorderState(context, const PerformanceRecorderIdle());
    expect(notices.state.message, isNull);
  });
}
