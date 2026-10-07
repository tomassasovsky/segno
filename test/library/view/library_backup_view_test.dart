import 'dart:async';
import 'dart:io';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:operation_guards/operation_guards.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/l10n/gen/app_localizations.dart';
import 'package:segno/library/application/removable_volumes.dart';
import 'package:segno/library/view/library_page.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/session/session.dart';
import 'package:session_repository/session_repository.dart';

import '../../helpers/helpers.dart';
import '../helpers/fake_drive.dart';

class _MockSessionCubit extends MockCubit<SessionState>
    implements SessionCubit {}

class _MockSessionRepository extends Mock implements SessionRepository {}

class _MockPedalRepository extends Mock implements PedalRepository {}

class _MockLooperBloc extends MockBloc<LooperEvent, LooperState>
    implements LooperBloc {}

const _id = 's-cur';

final _current = SessionSummary(
  id: _id,
  name: 'Evening loop',
  modifiedAt: DateTime(2026, 9, 7, 10),
  trackCount: 3,
  populatedChannels: const [0, 1, 2],
  fxCount: 15,
);

/// Pen section 34's six tiles against a fake drive (#1178 Part 8).
void main() {
  late AppLocalizations l10n;
  late Directory temp;
  late FakeDrive drive;
  late SessionCubit session;
  late StreamController<SessionState> sessionStates;
  late SessionRepository sessions;
  late PedalRepository pedal;

  setUpAll(() async {
    l10n = await AppLocalizations.delegate.load(const Locale('en'));
  });

  setUp(() {
    temp = Directory.systemTemp.createTempSync('segno_backup_view');
    final bundle = '${temp.path}/sessions/$_id';
    for (final f in ['track0_lane0_L0.wav', 'session.json']) {
      File('$bundle/$f')
        ..createSync(recursive: true)
        ..writeAsBytesSync([1]);
    }
    Directory('${temp.path}/usb').createSync();
    drive = FakeDrive('${temp.path}/usb');
    sessionStates = StreamController<SessionState>.broadcast();
    session = _MockSessionCubit();
    whenListen(
      session,
      sessionStates.stream,
      initialState: SessionState(
        currentSessionId: _id,
        currentSessionName: 'Evening loop',
        sessions: [_current],
      ),
    );
    when(session.refreshSessions).thenAnswer((_) async {});
    sessions = _MockSessionRepository();
    when(() => sessions.readPreview(any())).thenAnswer(
      (call) async => SessionPreview(
        summary: call.positionalArguments.first == _id
            ? _current
            : const SessionSummary(id: 's-new', name: 'Evening loop (2)'),
        tracks: const [],
        fxCount: 15,
        sampleRate: 48000,
      ),
    );
    when(() => sessions.bundlePathOf(_id)).thenAnswer((_) async => bundle);
    when(
      () => sessions.bundleFiles(_id),
    ).thenAnswer((_) async => ['track0_lane0_L0.wav', 'session.json']);
    when(() => sessions.listBackups(any())).thenReturn([
      _current,
      const SessionSummary(id: 's-other', name: 'Acoustic set'),
    ]);
    when(() => sessions.stopAudition()).thenReturn(EngineResult.ok);
    pedal = _MockPedalRepository();
    when(() => pedal.events).thenAnswer((_) => const Stream.empty());
  });

  tearDown(() async {
    await sessionStates.close();
    await drive.close();
    temp.deleteSync(recursive: true);
  });

  Future<void> openLibrary(WidgetTester tester) async {
    final looper = _MockLooperBloc();
    whenListen(
      looper,
      const Stream<LooperState>.empty(),
      initialState: const LooperState(),
    );
    tester.view
      ..physicalSize = const Size(1920, 1080)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpApp(
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<SessionRepository>.value(value: sessions),
          RepositoryProvider<PedalRepository>.value(value: pedal),
          RepositoryProvider<GuardRegistry>.value(value: GuardRegistry()),
          RepositoryProvider<RemovableVolumes>.value(value: drive),
        ],
        child: MultiBlocProvider(
          providers: [
            BlocProvider<SessionCubit>.value(value: session),
            BlocProvider<LooperBloc>.value(value: looper),
          ],
          child: const LibraryPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> backUp(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('library_back_up')));
    await tester.pumpAndSettle();
  }

  testWidgets('Backup in Library: the preview offers Back up to USB, and a '
      'finished backup says so', (tester) async {
    await openLibrary(tester);

    expect(find.text(l10n.libraryBackUp), findsOneWidget);
    expect(find.byKey(const Key('library_return_to_tracks')), findsOneWidget);

    await backUp(tester);

    expect(drive.files, [
      'Segno/Sessions/$_id/session.json',
      'Segno/Sessions/$_id/track0_lane0_L0.wav',
    ]);
    expect(drive.leases, [l10n.libraryBackupPurpose('Evening loop')]);
    expect(find.text(l10n.libraryBackedUp), findsOneWidget);
  });

  testWidgets('Inline copy progress: Backing up with Cancel, which leaves '
      'nothing', (tester) async {
    final hold = Completer<void>();
    drive.hold = hold;
    await openLibrary(tester);
    await tester.tap(find.byKey(const Key('library_back_up')));
    await tester.pump();
    await tester.pump();

    expect(find.text(l10n.libraryBackingUp('Evening loop')), findsOneWidget);
    expect(find.byKey(const Key('library_backup_bar')), findsOneWidget);
    expect(find.byKey(const Key('library_back_up')), findsNothing);

    await tester.tap(find.byKey(const Key('library_backup_cancel')));
    hold.complete();
    await tester.pumpAndSettle();

    expect(drive.files, isEmpty);
    expect(find.byKey(const Key('library_back_up')), findsOneWidget);
  });

  testWidgets('Matching backup name: Cancel, Keep both and Replace', (
    tester,
  ) async {
    File('${drive.mount}/Segno/Sessions/$_id/session.json')
      ..createSync(recursive: true)
      ..writeAsBytesSync([9]);
    await openLibrary(tester);
    await backUp(tester);

    expect(find.text(l10n.libraryBackupConflictTitle), findsOneWidget);
    expect(find.text(l10n.libraryAudioKeepBoth), findsOneWidget);
    expect(find.text(l10n.libraryBackupReplace), findsOneWidget);
    expect(drive.copies, isEmpty);

    await tester.tap(find.byKey(const Key('library_backup_dialog_cancel')));
    await tester.pumpAndSettle();
    expect(drive.copies, isEmpty);

    await backUp(tester);
    await tester.tap(find.byKey(const Key('library_backup_replace')));
    await tester.pumpAndSettle();

    expect(drive.files, [
      'Segno/Sessions/$_id/session.json',
      'Segno/Sessions/$_id/track0_lane0_L0.wav',
    ]);
    expect(
      File('${drive.mount}/Segno/Sessions/$_id/session.json').readAsBytesSync(),
      [1],
    );
  });

  testWidgets('Retry an interrupted copy: the drive went away, nothing '
      'changed, Retry finishes it', (tester) async {
    drive
      ..failOnCopy = 2
      ..failure = const StorageFailure.volumeLost(3);
    await openLibrary(tester);
    await backUp(tester);

    expect(find.text(l10n.libraryBackupInterrupted), findsOneWidget);
    expect(find.text(l10n.libraryBackupDriveLost), findsOneWidget);
    expect(drive.files, isEmpty);

    drive.failOnCopy = null;
    await tester.tap(find.byKey(const Key('library_backup_retry')));
    await tester.pumpAndSettle();

    expect(drive.files, hasLength(2));
    expect(find.text(l10n.libraryBackedUp), findsOneWidget);
  });

  testWidgets('USB session list: Session and Saved, Restore to Library once '
      'a backup is selected', (tester) async {
    await openLibrary(tester);
    await tester.tap(find.byKey(const Key('library_location_usb')));
    await tester.pumpAndSettle();

    expect(find.text(l10n.libraryBackupSession), findsOneWidget);
    expect(find.text(l10n.libraryBackupSaved), findsOneWidget);
    expect(find.text('Acoustic set'), findsOneWidget);
    expect(find.text(l10n.libraryRestoreAdds), findsOneWidget);
    expect(
      find.text(l10n.libraryBackupMeta(l10n.libraryTrackCount(3), 15)),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('library_restore')));
    await tester.pumpAndSettle();
    verifyNever(() => sessions.restoreFrom(any()));
  });

  testWidgets('Restored session selected: the copy shows in Internal with '
      'Open session, and the catalog is read again', (tester) async {
    when(() => sessions.restoreFrom(any())).thenAnswer((_) async => 's-new');
    when(session.refreshSessions).thenAnswer((_) async {
      sessionStates.add(
        SessionState(
          currentSessionId: _id,
          currentSessionName: 'Evening loop',
          sessions: [
            _current,
            const SessionSummary(id: 's-new', name: 'Evening loop (2)'),
          ],
        ),
      );
    });
    await openLibrary(tester);
    await tester.tap(find.byKey(const Key('library_location_usb')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('library_backup_$_id')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('library_restore')));
    await tester.pumpAndSettle();

    verify(
      () => sessions.restoreFrom('${drive.mount}/Segno/Sessions/$_id'),
    ).called(1);
    verify(session.refreshSessions).called(greaterThan(1));
    expect(find.byKey(const Key('library_backups')), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const Key('library_preview')),
        matching: find.text('Evening loop (2)'),
      ),
      findsOneWidget,
    );
    expect(find.byKey(const Key('library_open_session')), findsOneWidget);
  });

  testWidgets('a restore that fails says so and adds nothing', (tester) async {
    when(
      () => sessions.restoreFrom(any()),
    ).thenThrow(const FileSystemException('gone'));
    await openLibrary(tester);
    await tester.tap(find.byKey(const Key('library_location_usb')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('library_backup_s-other')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('library_restore')));
    await tester.pumpAndSettle();

    expect(find.text(l10n.libraryRestoreFailed), findsOneWidget);
    expect(find.byKey(const Key('library_backups')), findsOneWidget);
  });
}
