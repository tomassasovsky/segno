@Tags(['screenshots'])
library;

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
import 'package:segno/library/application/removable_volumes.dart';
import 'package:segno/library/view/library_page.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/session/session.dart';
import 'package:session_repository/session_repository.dart';

import '../helpers/helpers.dart';
import '../library/helpers/fake_drive.dart';

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

/// Author-side images of pen section 34 (#1178 Part 8); CI does not claim
/// visual proof.
void main() {
  late Directory temp;
  late FakeDrive drive;
  late SessionCubit session;
  late StreamController<SessionState> sessionStates;
  late SessionRepository sessions;
  late PedalRepository pedal;

  final fontDir = Platform.environment['SEGNO_SCREENSHOT_FONT_DIR'];
  final hasScreenshotFonts =
      fontDir != null && File('$fontDir/Roboto-Regular.ttf').existsSync();

  setUpAll(() async {
    if (!hasScreenshotFonts) return;
    await loadScreenshotFont('Roboto', [
      '$fontDir/Roboto-Regular.ttf',
      '$fontDir/Roboto-Medium.ttf',
      '$fontDir/Roboto-Bold.ttf',
    ]);
    await loadScreenshotFont('Inter', [
      'assets/fonts/Inter-Regular.ttf',
      'assets/fonts/Inter-Medium.ttf',
      'assets/fonts/Inter-SemiBold.ttf',
      'assets/fonts/Inter-Bold.ttf',
    ]);
    await loadScreenshotFont('JetBrains Mono', [
      'assets/fonts/JetBrainsMono-Regular.ttf',
      'assets/fonts/JetBrainsMono-Medium.ttf',
      'assets/fonts/JetBrainsMono-SemiBold.ttf',
    ]);
    await loadScreenshotFont('MaterialIcons', [
      '$fontDir/MaterialIcons-Regular.otf',
    ]);
    await loadScreenshotFont('packages/lucide_icons_flutter/Lucide', [
      packageAssetPath('lucide_icons_flutter', 'assets/lucide.ttf'),
    ]);
  });

  setUp(() {
    WidgetsApp.debugAllowBannerOverride = false;
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
    WidgetsApp.debugAllowBannerOverride = true;
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

  Future<void> shot(String name) => expectLater(
    find.byType(Navigator).first,
    matchesGoldenFile('goldens/library_backup_$name.png'),
  );

  testWidgets('Backup in Library', (tester) async {
    await openLibrary(tester);
    await shot('tile');
  }, skip: !hasScreenshotFonts);

  testWidgets('Inline copy progress', (tester) async {
    final hold = Completer<void>();
    drive.hold = hold;
    await openLibrary(tester);
    await tester.tap(find.byKey(const Key('library_back_up')));
    await tester.pump();
    await tester.pump();
    await shot('progress');
    hold.complete();
    await tester.pumpAndSettle();
  }, skip: !hasScreenshotFonts);

  testWidgets('USB session list', (tester) async {
    await openLibrary(tester);
    await tester.tap(find.byKey(const Key('library_location_usb')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('library_backup_$_id')));
    await tester.pumpAndSettle();
    await shot('usb_list');
  }, skip: !hasScreenshotFonts);

  testWidgets('Matching backup name', (tester) async {
    File('${drive.mount}/Segno/Sessions/$_id/session.json')
      ..createSync(recursive: true)
      ..writeAsBytesSync([9]);
    await openLibrary(tester);
    await backUp(tester);
    await shot('conflict');
  }, skip: !hasScreenshotFonts);

  testWidgets('Restored session selected', (tester) async {
    when(() => sessions.restoreFrom(any())).thenAnswer((_) async => 's-new');
    when(session.refreshSessions).thenAnswer((_) async {
      sessionStates.add(
        SessionState(
          currentSessionId: _id,
          currentSessionName: 'Evening loop',
          sessions: [
            _current,
            SessionSummary(
              id: 's-new',
              name: 'Evening loop (2)',
              modifiedAt: DateTime(2026, 9, 7, 10),
              trackCount: 3,
              populatedChannels: const [0, 1, 2],
            ),
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
    await shot('restored');
  }, skip: !hasScreenshotFonts);

  testWidgets('Retry an interrupted copy', (tester) async {
    drive
      ..failOnCopy = 2
      ..failure = const StorageFailure.volumeLost(3);
    await openLibrary(tester);
    await backUp(tester);
    await shot('interrupted');
  }, skip: !hasScreenshotFonts);
}
