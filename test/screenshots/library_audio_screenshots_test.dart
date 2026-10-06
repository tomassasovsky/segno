@Tags(['screenshots'])
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:operation_guards/operation_guards.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:performance_repository/performance_repository.dart';
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

class _MockPerformance extends Mock implements PerformanceRepository {}

class _MockPedalRepository extends Mock implements PedalRepository {}

class _MockLooperBloc extends MockBloc<LooperEvent, LooperState>
    implements LooperBloc {}

/// Author-side images of Library > Audio against pen 18/01 and 20/07 to
/// 20/12; CI does not claim visual proof.
void main() {
  final fontDir = Platform.environment['SEGNO_SCREENSHOT_FONT_DIR'];
  final hasScreenshotFonts =
      fontDir != null && File('$fontDir/Roboto-Regular.ttf').existsSync();

  setUpAll(() async {
    registerFallbackValue(
      const CaptureSummary(
        path: '',
        name: '',
        durationFrames: 0,
        sampleRate: 0,
        parts: [],
      ),
    );
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

  late Directory temp;
  late FakeDrive drive;

  setUp(() {
    WidgetsApp.debugAllowBannerOverride = false;
    temp = Directory.systemTemp.createTempSync('segno_audio_shots');
    Directory('${temp.path}/usb').createSync();
    drive = FakeDrive('${temp.path}/usb');
  });

  tearDown(() async {
    WidgetsApp.debugAllowBannerOverride = true;
    await drive.close();
    temp.deleteSync(recursive: true);
  });

  CaptureSummary take(
    String name, {
    required int seconds,
    int parts = 1,
    bool recovered = false,
  }) {
    final dir = '${temp.path}/exports/$name';
    return CaptureSummary(
      path: dir,
      name: name,
      durationFrames: 48000 * seconds,
      sampleRate: 48000,
      recovered: recovered,
      parts: [
        for (var i = 1; i <= parts; i++)
          CapturePart(
            stream: 0,
            index: i,
            file: 'master-00$i.wav',
            frames: 48000 * seconds ~/ parts,
            bytes:
                (File('$dir/master-00$i.wav')
                      ..createSync(recursive: true)
                      ..writeAsBytesSync([i]))
                    .lengthSync(),
          ),
      ],
    );
  }

  Future<void> pump(WidgetTester tester, {RemovableVolumes? volumes}) async {
    tester.view
      ..physicalSize = const Size(1920, 1080)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final session = _MockSessionCubit();
    when(session.refreshSessions).thenAnswer((_) async {});
    whenListen(
      session,
      const Stream<SessionState>.empty(),
      initialState: const SessionState(),
    );
    final sessions = _MockSessionRepository();
    when(sessions.listSessions).thenAnswer(
      (_) async => const [SessionSummary(id: 's-1', name: 'Sunday rehearsal')],
    );
    when(() => sessions.mixdownOf(any())).thenAnswer(
      (_) async => const SessionMixdown(
        frames: 48000 * 202,
        sampleRate: 48000,
        bytes: 1,
      ),
    );
    when(sessions.stopAudition).thenReturn(EngineResult.ok);
    when(sessions.auditionState).thenReturn(const AuditionState());
    final performance = _MockPerformance();
    when(() => performance.rendering).thenReturn(false);
    when(performance.listCaptures).thenAnswer(
      (_) async => [
        take('Evening loop - Take 1', seconds: 83),
        take('Rehearsal run', seconds: 222),
        take('perf-20261005-221500', seconds: 3061, parts: 2, recovered: true),
      ],
    );
    when(
      () => performance.readPeaks(any(), buckets: any(named: 'buckets')),
    ).thenAnswer(
      (_) async => Float32List.fromList([
        for (var i = 0; i < 90; i++)
          0.1 + 0.8 * (0.5 + 0.5 * math.sin(i / 3.1)).abs() * (1 - i % 11 / 14),
      ]),
    );
    final pedal = _MockPedalRepository();
    when(() => pedal.events).thenAnswer((_) => const Stream.empty());
    final looper = _MockLooperBloc();
    whenListen(
      looper,
      const Stream<LooperState>.empty(),
      initialState: const LooperState(),
    );
    await tester.pumpApp(
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<SessionRepository>.value(value: sessions),
          RepositoryProvider<PerformanceRepository>.value(value: performance),
          RepositoryProvider<PedalRepository>.value(value: pedal),
          RepositoryProvider<GuardRegistry>.value(value: GuardRegistry()),
          RepositoryProvider<RemovableVolumes>.value(value: volumes ?? drive),
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
    await tester.tap(find.byKey(const Key('library_tab_audio')));
    await tester.pumpAndSettle();
  }

  Future<void> selectFirst(WidgetTester tester) async {
    await tester.tap(
      find.byKey(const Key('library_audio_folder_performances')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(
        Key('library_audio_row_${temp.path}/exports/Evening loop - Take 1'),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> exportFirst(WidgetTester tester) async {
    await selectFirst(tester);
    await tester.tap(find.byKey(const Key('library_audio_export')));
    await tester.pumpAndSettle();
  }

  Future<void> shot(String name) => expectLater(
    find.byType(Navigator).first,
    matchesGoldenFile('goldens/library_audio_$name.png'),
  );

  testWidgets('18/01 the two folders', (tester) async {
    await pump(tester);
    await shot('folders');
  }, skip: !hasScreenshotFonts);

  testWidgets('20/07 a recording selected', (tester) async {
    await pump(tester);
    await selectFirst(tester);
    await shot('selected');
  }, skip: !hasScreenshotFonts);

  testWidgets('the package chooser', (tester) async {
    await pump(tester);
    await exportFirst(tester);
    await shot('chooser');
  }, skip: !hasScreenshotFonts);

  testWidgets('20/08 an export running', (tester) async {
    final hold = Completer<void>();
    drive.hold = hold;
    await pump(tester);
    await exportFirst(tester);
    await tester.tap(find.byKey(const Key('library_export_choose_recording')));
    await tester.pumpAndSettle();
    await shot('exporting');
    hold.complete();
    await tester.pumpAndSettle();
  }, skip: !hasScreenshotFonts);

  testWidgets('20/09 already on USB', (tester) async {
    File('${drive.mount}/Segno/Performances/Evening loop - Take 1.wav')
      ..createSync(recursive: true)
      ..writeAsBytesSync([1]);
    await pump(tester);
    await exportFirst(tester);
    await tester.tap(find.byKey(const Key('library_export_choose_recording')));
    await tester.pumpAndSettle();
    await shot('conflict');
  }, skip: !hasScreenshotFonts);

  testWidgets('20/10 connect a USB drive', (tester) async {
    await pump(tester, volumes: const InternalOnlyVolumes());
    await exportFirst(tester);
    await tester.tap(find.byKey(const Key('library_export_choose_recording')));
    await tester.pumpAndSettle();
    await shot('connect');
  }, skip: !hasScreenshotFonts);

  testWidgets('20/11 not enough space', (tester) async {
    drive.spaceAnswer = const VolumeSpace(totalBytes: 1, freeBytes: 0);
    await pump(tester);
    await exportFirst(tester);
    await tester.tap(find.byKey(const Key('library_export_choose_recording')));
    await tester.pumpAndSettle();
    await shot('full');
  }, skip: !hasScreenshotFonts);

  testWidgets('20/12 exported', (tester) async {
    await pump(tester);
    await exportFirst(tester);
    await tester.tap(find.byKey(const Key('library_export_choose_recording')));
    await tester.pumpAndSettle();
    await shot('done');
  }, skip: !hasScreenshotFonts);
}
