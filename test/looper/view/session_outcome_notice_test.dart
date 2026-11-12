import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:operation_guards/operation_guards.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/view/tracks_commands.dart';
import 'package:segno/notices/notices.dart';
import 'package:segno/session/session.dart';
import 'package:session_repository/session_repository.dart';

import '../../helpers/helpers.dart';

/// What the top bar says when a session action settles (#1562).
void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));

  ({String title, String? body, NoticeTone tone})? said(SessionState state) {
    final notice = sessionOutcomeNotice(state);
    if (notice == null) return null;
    return (
      title: notice.title(l10n),
      body: notice.body?.call(l10n),
      tone: notice.tone,
    );
  }

  test('a quick Save that named the session says which name', () {
    expect(
      said(
        const SessionState(
          status: SessionStatus.success,
          outcome: SessionOutcome.savedAs,
          currentSessionId: 's-1',
          currentSessionName: 'New loop 2',
        ),
      ),
      (
        title: l10n.sessionSavedAs('New loop 2'),
        body: null,
        tone: NoticeTone.success,
      ),
    );
  });

  test('a loaded session is a confirmation', () {
    expect(
      said(
        const SessionState(
          status: SessionStatus.success,
          outcome: SessionOutcome.loaded,
        ),
      )?.title,
      l10n.sessionLoaded,
    );
  });

  test('a converted session says so, and what the conversion changed', () {
    final notice = said(
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
    expect(notice?.title, l10n.sessionLoadedConverted);
    expect(
      notice?.body,
      '${l10n.sessionConvertedKept} ${l10n.sessionConvertedMasterMoved} '
      '${l10n.sessionConvertedMonitorLowered} '
      '${l10n.sessionConvertedTempoFromLoop}',
    );
  });

  test('does not claim a backup the write-back did not make', () {
    final notice = said(
      const SessionState(
        status: SessionStatus.success,
        outcome: SessionOutcome.loaded,
        conversion: SessionConversionNotice(fromVersion: 7, written: false),
      ),
    );
    expect(notice?.title, l10n.sessionLoadedConvertedUnsaved);
    expect(notice?.body, l10n.sessionConvertedNotWritten);
  });

  group('a session that did not load is a warning that says why', () {
    for (final (error, body) in [
      (SessionError.sampleRateMismatch, l10n.sessionLoadSampleRate),
      (SessionError.unsupportedVersion, l10n.sessionLoadNewer),
      (SessionError.unconvertible, l10n.sessionLoadUnconvertible),
    ]) {
      test(error.name, () {
        expect(
          said(SessionState(status: SessionStatus.failure, error: error)),
          (title: l10n.sessionLoadFailed, body: body, tone: NoticeTone.warning),
        );
      });
    }

    test('a sample-rate mismatch offers Open setup', () {
      final notice = sessionOutcomeNotice(
        const SessionState(
          status: SessionStatus.failure,
          error: SessionError.sampleRateMismatch,
        ),
      );
      expect(notice?.action?.label(l10n), l10n.deviceLostBannerAction);
    });
  });

  test('the Library and boot refusals say their own words', () {
    for (final (state, title) in [
      (
        const SessionState(
          status: SessionStatus.failure,
          error: SessionError.folderNotEmpty,
        ),
        l10n.libraryFolderNotEmpty,
      ),
      (
        const SessionState(
          status: SessionStatus.failure,
          error: SessionError.saveFailed,
        ),
        l10n.librarySaveFailed,
      ),
      (
        const SessionState(
          status: SessionStatus.failure,
          error: SessionError.newLoopNotSaved,
          currentSessionName: 'New loop 2',
        ),
        l10n.sessionNewLoopNotSaved('New loop 2'),
      ),
      (
        const SessionState(
          status: SessionStatus.failure,
          error: SessionError.captureInProgress,
        ),
        l10n.libraryTakeStillRunning,
      ),
      (
        const SessionState(
          status: SessionStatus.failure,
          error: SessionError.templateDoesNotFit,
        ),
        l10n.sessionTemplateDoesNotFit,
      ),
      (
        const SessionState(
          status: SessionStatus.success,
          outcome: SessionOutcome.newLoop,
          currentSessionName: 'New loop 2',
          trackNamesNotSaved: true,
        ),
        l10n.sessionTrackNamesNotSaved,
      ),
    ]) {
      expect(said(state)?.title, title);
    }
  });

  test('a refused session action is real copy, not a developer string', () {
    final notice = said(
      const SessionState(
        status: SessionStatus.failure,
        error: SessionError.busy,
        errorMessage: 'GuardRefused(GuardKind.sessionApply, blocked by [])',
        refusedBy: GuardKind.restart,
      ),
    );
    expect(notice?.title, 'The console is shutting down.');
  });

  test('a new loop, a boot recovery and the Library catalog say nothing '
      'here', () {
    expect(
      said(
        const SessionState(
          status: SessionStatus.success,
          outcome: SessionOutcome.newLoop,
          currentSessionName: 'New loop 2',
        ),
      ),
      isNull,
    );
    expect(
      said(
        const SessionState(
          status: SessionStatus.failure,
          error: SessionError.bootPersistence,
        ),
      ),
      isNull,
    );
    for (final outcome in [
      SessionOutcome.renamed,
      SessionOutcome.deleted,
      SessionOutcome.duplicated,
      SessionOutcome.moved,
      SessionOutcome.folderCreated,
      SessionOutcome.folderRenamed,
      SessionOutcome.folderDeleted,
    ]) {
      expect(
        said(SessionState(status: SessionStatus.success, outcome: outcome)),
        isNull,
        reason: outcome.name,
      );
    }
  });

  testWidgets('showSessionOutcome says it in the top bar', (tester) async {
    final notices = NoticesCubit();
    addTearDown(notices.close);
    await tester.pumpApp(
      Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showSessionOutcome(
              context,
              const SessionState(
                status: SessionStatus.success,
                outcome: SessionOutcome.saved,
              ),
            ),
            child: const Text('show'),
          ),
        ),
      ),
      notices: notices,
    );
    await tester.tap(find.text('show'));
    expect(notices.state.message?.notice.id, 'session');
    await tester.pump(const Duration(seconds: 4));
  });
}
