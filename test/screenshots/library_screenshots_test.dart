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
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/library/application/removable_volumes.dart';
import 'package:segno/library/view/library_page.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/session/session.dart';
import 'package:session_repository/session_repository.dart';

import '../helpers/helpers.dart';

class _MockSessionCubit extends MockCubit<SessionState>
    implements SessionCubit {}

class _MockSessionRepository extends Mock implements SessionRepository {}

class _MockPedalRepository extends Mock implements PedalRepository {}

class _MockLooperBloc extends MockBloc<LooperEvent, LooperState>
    implements LooperBloc {}

final _saved = DateTime(2026, 9, 7, 10);

final _catalog = [
  const SessionSummary(id: 's-2', name: 'New loop 2'),
  SessionSummary(
    id: 's-1',
    name: 'Evening loop',
    modifiedAt: _saved,
    trackCount: 3,
    populatedChannels: const [0, 1, 2],
    tempoBpm: 84,
    fxCount: 15,
  ),
  SessionSummary(
    id: 's-3',
    name: 'Sunday rehearsal',
    folder: 'Gigs',
    modifiedAt: _saved,
    trackCount: 2,
    populatedChannels: const [0, 4],
    tempoBpm: 120,
  ),
];

SessionPreviewTrack _track(int channel, int bars) => SessionPreviewTrack(
  channel: channel,
  lengthFrames: bars * 137143,
  baseLengthFrames: 4 * 137143,
  bars: bars,
  layers: 4,
  muted: false,
  fxCount: 3,
  liveLayerFile: 'track${channel}_lane0_L0.wav',
);

SessionPreview _previewOf(String id) => switch (id) {
  's-1' => SessionPreview(
    summary: _catalog[1],
    tracks: [_track(0, 2), _track(1, 4), _track(2, 1)],
    fxCount: 15,
    sampleRate: 48000,
    hasMixdown: true,
  ),
  's-3' => SessionPreview(
    summary: _catalog[2],
    tracks: [_track(0, 4), _track(4, 4)],
    fxCount: 4,
    sampleRate: 48000,
    hasMixdown: true,
  ),
  _ => SessionPreview(
    summary: _catalog[0],
    tracks: const [],
    fxCount: 0,
    sampleRate: 48000,
  ),
};

/// Author-side images of the Library against pen 19/01 to 19/05 and 18/06;
/// CI does not claim visual proof.
void main() {
  setUpAll(() => registerFallbackValue(_track(0, 1)));

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

  // The debug ribbon would sit in every image that frames the navigator.
  setUp(() => WidgetsApp.debugAllowBannerOverride = false);
  tearDown(() => WidgetsApp.debugAllowBannerOverride = true);

  Future<void> pump(
    WidgetTester tester, {
    required String current,
    Stream<SessionState> states = const Stream.empty(),
  }) async {
    tester.view
      ..physicalSize = const Size(1920, 1080)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final session = _MockSessionCubit();
    when(session.refreshSessions).thenAnswer((_) async {});
    whenListen(
      session,
      states,
      initialState: SessionState(
        currentSessionId: current,
        currentSessionName: _catalog.firstWhere((s) => s.id == current).name,
        sessions: _catalog,
        folders: const ['Gigs'],
      ),
    );
    final repository = _MockSessionRepository();
    when(() => repository.readPreview(any())).thenAnswer(
      (call) async => _previewOf(call.positionalArguments.first as String),
    );
    // A recorded take's shape, different per track.
    when(
      () => repository.readPeaks(
        any(),
        any(),
      ),
    ).thenAnswer((call) async {
      final channel =
          (call.positionalArguments[1] as SessionPreviewTrack).channel;
      return Float32List.fromList([
        for (var i = 0; i < 256; i++)
          0.15 +
              0.6 *
                  (0.5 + 0.5 * math.sin(i / (6.0 + channel))).abs() *
                  (1 - (i % 32) / 48),
      ]);
    });
    when(
      () => repository.startAudition(
        any(),
        stillWanted: any(named: 'stillWanted'),
      ),
    ).thenAnswer(
      (_) async => const AuditionStart(
        result: EngineResult.ok,
        frames: 48000 * 120,
        rate: 48000,
        truncated: true,
      ),
    );
    when(repository.auditionState).thenReturn(
      const AuditionState(frames: 48000 * 120, position: 48000 * 12, bus: 0),
    );
    when(repository.stopAudition).thenReturn(EngineResult.ok);
    final pedal = _MockPedalRepository();
    when(() => pedal.events).thenAnswer((_) => const Stream.empty());
    // The live rig holds the current session's three tracks.
    final looper = _MockLooperBloc();
    whenListen(
      looper,
      const Stream<LooperState>.empty(),
      initialState: LooperState(
        tracks: [
          for (var c = 0; c < 8; c++)
            Track(
              channel: c,
              state: c < 3 ? TrackState.stopped : TrackState.empty,
              lengthFrames: c < 3 ? 48000 : 0,
            ),
        ],
      ),
    );
    await tester.pumpApp(
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<SessionRepository>.value(value: repository),
          RepositoryProvider<PedalRepository>.value(value: pedal),
          RepositoryProvider<RemovableVolumes>.value(
            value: const InternalOnlyVolumes(),
          ),
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

  // The navigator, so a sheet or dialog over the page is in the image.
  Future<void> shot(String name) => expectLater(
    find.byType(Navigator).first,
    matchesGoldenFile('goldens/library_$name.png'),
  );

  testWidgets('19/01 the current session selected', (tester) async {
    await pump(tester, current: 's-1');
    await shot('current');
  }, skip: !hasScreenshotFonts);

  testWidgets('19/03 another session selected', (tester) async {
    await pump(tester, current: 's-2');
    await tester.tap(find.byKey(const Key('library_row_s-1')));
    await tester.pumpAndSettle();
    await shot('selected');
  }, skip: !hasScreenshotFonts);

  testWidgets('18/06 USB without a drive', (tester) async {
    await pump(tester, current: 's-1');
    await tester.tap(find.byKey(const Key('library_location_usb')));
    await tester.pumpAndSettle();
    await shot('usb_disconnected');
  }, skip: !hasScreenshotFonts);

  testWidgets('Manage on the selected session', (tester) async {
    await pump(tester, current: 's-2');
    await tester.tap(find.byKey(const Key('library_row_s-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('library_manage')));
    await tester.pumpAndSettle();
    await shot('manage');
  }, skip: !hasScreenshotFonts);

  testWidgets('19/04 Rename on the keyboard sheet', (tester) async {
    await pump(tester, current: 's-1');
    await tester.tap(find.byKey(const Key('library_manage')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('fx_option_rename')));
    await tester.pumpAndSettle();
    await shot('rename');
  }, skip: !hasScreenshotFonts);

  testWidgets('Move to folder', (tester) async {
    await pump(tester, current: 's-1');
    await tester.tap(find.byKey(const Key('library_manage')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('fx_option_move')));
    await tester.pumpAndSettle();
    await shot('move');
  }, skip: !hasScreenshotFonts);

  testWidgets('19/02 the New loop sheet', (tester) async {
    await pump(tester, current: 's-1');
    await tester.tap(find.byKey(const Key('library_new_loop')));
    await tester.pumpAndSettle();
    await shot('new_loop');
  }, skip: !hasScreenshotFonts);

  testWidgets('Listen on the selected session', (tester) async {
    await pump(tester, current: 's-1');
    await tester.tap(find.byKey(const Key('library_listen')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await shot('listen');
  }, skip: !hasScreenshotFonts);

  testWidgets('19/05 a failed save', (tester) async {
    // The line reports a save taken while the Library is open.
    final states = StreamController<SessionState>();
    addTearDown(states.close);
    await pump(tester, current: 's-1', states: states.stream);
    states.add(
      SessionState(
        status: SessionStatus.failure,
        error: SessionError.saveFailed,
        currentSessionId: 's-1',
        currentSessionName: 'Evening loop',
        sessions: _catalog,
        folders: const ['Gigs'],
      ),
    );
    await tester.pumpAndSettle();
    await shot('save_failed');
  }, skip: !hasScreenshotFonts);
}
