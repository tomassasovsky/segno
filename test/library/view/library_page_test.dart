import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/l10n/gen/app_localizations.dart';
import 'package:segno/library/application/removable_volumes.dart';
import 'package:segno/library/cubit/library_cubit.dart';
import 'package:segno/library/view/library_page.dart';
import 'package:segno/library/view/library_sessions_tab.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/session/session.dart';
import 'package:segno/theme/theme.dart';
import 'package:session_repository/session_repository.dart';

import '../../helpers/helpers.dart';

class _MockSessionCubit extends MockCubit<SessionState>
    implements SessionCubit {}

class _MockSessionRepository extends Mock implements SessionRepository {}

class _MockPedalRepository extends Mock implements PedalRepository {}

class _MockLooperBloc extends MockBloc<LooperEvent, LooperState>
    implements LooperBloc {}

final _saved = DateTime(2026, 9, 7, 10);

final _catalog = [
  SessionSummary(
    id: 's-cur',
    name: 'Evening loop',
    modifiedAt: _saved,
    trackCount: 3,
    populatedChannels: const [0, 1, 2],
    tempoBpm: 84,
    fxCount: 15,
  ),
  SessionSummary(
    id: 's-gig',
    name: 'Night set',
    folder: 'Gigs',
    modifiedAt: _saved,
    trackCount: 1,
    populatedChannels: const [4],
  ),
  const SessionSummary(id: 's-new', name: 'New loop 2'),
];

SessionPreviewTrack _track(int channel, int frames, {int bars = 0}) =>
    SessionPreviewTrack(
      channel: channel,
      lengthFrames: frames,
      baseLengthFrames: 4000,
      bars: bars,
      layers: 4,
      muted: false,
      fxCount: 3,
      liveLayerFile: 'track${channel}_lane0_L0.wav',
    );

SessionPreview _previewOf(String id) => switch (id) {
  's-cur' => SessionPreview(
    summary: _catalog[0],
    tracks: [
      _track(0, 2000, bars: 2),
      _track(1, 4000, bars: 4),
      _track(2, 1000, bars: 1),
    ],
    fxCount: 15,
    sampleRate: 48000,
  ),
  's-gig' => SessionPreview(
    summary: _catalog[1],
    tracks: [_track(4, 72000)],
    fxCount: 2,
    sampleRate: 48000,
  ),
  _ => SessionPreview(
    summary: _catalog[2],
    tracks: const [],
    fxCount: 0,
    sampleRate: 48000,
  ),
};

void main() {
  late SessionCubit session;
  late SessionRepository repository;
  late PedalRepository pedal;
  late StreamController<PedalEvent> pedalEvents;
  late AppLocalizations l10n;

  setUpAll(() async {
    l10n = await AppLocalizations.delegate.load(const Locale('en'));
  });

  setUp(() {
    session = _MockSessionCubit();
    when(session.refreshSessions).thenAnswer((_) async {});
    when(() => session.open(any())).thenAnswer((_) async {});
    repository = _MockSessionRepository();
    when(() => repository.readPreview(any())).thenAnswer(
      (call) async => _previewOf(call.positionalArguments.first as String),
    );
    pedalEvents = StreamController<PedalEvent>.broadcast();
    pedal = _MockPedalRepository();
    when(() => pedal.events).thenAnswer((_) => pedalEvents.stream);
  });

  tearDown(() => pedalEvents.close());

  /// Pumps the stage with the Library pushed over it, at the pen's 1920 x
  /// 1080, so the layout is the appliance's.
  Future<void> openLibrary(
    WidgetTester tester, {
    SessionState? state,
    Stream<SessionState> states = const Stream.empty(),
    RemovableVolumes volumes = const InternalOnlyVolumes(),
    LooperState looperState = const LooperState(),
  }) async {
    final looper = _MockLooperBloc();
    whenListen(
      looper,
      const Stream<LooperState>.empty(),
      initialState: looperState,
    );
    tester.view
      ..physicalSize = const Size(1920, 1080)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    whenListen(
      session,
      states,
      initialState:
          state ??
          SessionState(
            currentSessionId: 's-cur',
            currentSessionName: 'Evening loop',
            sessions: _catalog,
            folders: const ['Gigs'],
          ),
    );
    await tester.pumpApp(
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<SessionRepository>.value(value: repository),
          RepositoryProvider<PedalRepository>.value(value: pedal),
          RepositoryProvider<RemovableVolumes>.value(
            value: volumes,
          ),
        ],
        child: MultiBlocProvider(
          providers: [
            BlocProvider<SessionCubit>.value(value: session),
            BlocProvider<LooperBloc>.value(value: looper),
          ],
          child: Navigator(
            onGenerateRoute: (_) => MaterialPageRoute<void>(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => const LibraryPage(),
                    ),
                  ),
                  child: const Text('stage'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('stage'));
    await tester.pumpAndSettle();
  }

  Finder row(String id) => find.byKey(Key('library_row_$id'));

  Finder inRow(String id, String text) =>
      find.descendant(of: row(id), matching: find.text(text));

  Finder inPreview(Finder finder) => find.descendant(
    of: find.byKey(const Key('library_preview')),
    matching: finder,
  );

  /// Types [text] into the open keyboard sheet and confirms.
  Future<void> type(WidgetTester tester, String text) async {
    for (var i = 0; i < 40; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    }
    for (final ch in text.split('')) {
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA, character: ch);
    }
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
  }

  group('the shell', () {
    testWidgets('draws the title, the Sessions tab, the locations and New '
        'loop', (tester) async {
      await openLibrary(tester);

      expect(find.byKey(const Key('library_page')), findsOneWidget);
      expect(find.text(l10n.libraryTitle), findsOneWidget);
      expect(find.byKey(const Key('library_tab_sessions')), findsOneWidget);
      expect(
        find.byKey(const Key('library_location_internal')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('library_location_usb')), findsOneWidget);
      expect(
        tester
            .widget<LoopOutlinedButton>(
              find.byKey(const Key('library_new_loop')),
            )
            .onTap,
        isNotNull,
      );
    });

    testWidgets('New loop is inert while a session action runs', (
      tester,
    ) async {
      await openLibrary(
        tester,
        state: SessionState(
          status: SessionStatus.working,
          currentSessionId: 's-cur',
          currentSessionName: 'Evening loop',
          sessions: _catalog,
        ),
      );

      expect(
        tester
            .widget<LoopOutlinedButton>(
              find.byKey(const Key('library_new_loop')),
            )
            .onTap,
        isNull,
      );
    });

    testWidgets('re-reads the catalog when it opens', (tester) async {
      await openLibrary(tester);
      verify(session.refreshSessions).called(1);
    });

    testWidgets('places the list and the preview on the pen grid', (
      tester,
    ) async {
      await openLibrary(tester);

      // Main area starts under the 96 top bar; the layout at (64, 128).
      expect(
        tester.getTopLeft(find.byKey(const Key('library_search'))),
        const Offset(64, 96 + 128),
      );
      expect(tester.getSize(row('s-cur')), const Size(699, 148));
      expect(
        tester.getRect(find.byKey(const Key('library_preview'))),
        const Rect.fromLTWH(64 + 765, 96 + 128, 1027, 820),
      );
    });
  });

  group('rows', () {
    testWidgets('one per saved session, the current one reading Current '
        'session and the others their date and track count', (tester) async {
      await openLibrary(tester);

      expect(inRow('s-cur', 'Evening loop'), findsOneWidget);
      expect(inRow('s-cur', l10n.libraryCurrentSession), findsOneWidget);
      expect(inRow('s-gig', '7 Sep · 1 track'), findsOneWidget);
      // No saved date (a stat failure) leaves only the track count.
      expect(inRow('s-new', 'no tracks'), findsOneWidget);
    });

    testWidgets('the track strip fills the populated channels', (tester) async {
      await openLibrary(tester);

      for (final channel in [0, 1, 2]) {
        expect(
          find.descendant(
            of: row('s-cur'),
            matching: find.byKey(Key('library_strip_${channel}_filled')),
          ),
          findsOneWidget,
        );
      }
      expect(
        find.descendant(
          of: row('s-cur'),
          matching: find.byKey(const Key('library_strip_3_empty')),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: row('s-gig'),
          matching: find.byKey(const Key('library_strip_4_filled')),
        ),
        findsOneWidget,
      );
    });

    testWidgets('says so when there are no saved sessions', (tester) async {
      await openLibrary(tester, state: const SessionState());
      expect(find.text(l10n.libraryNoSessions), findsOneWidget);
      expect(inPreview(find.text(l10n.libraryNoSelection)), findsOneWidget);
    });
  });

  group('selection', () {
    testWidgets('opens on the current session, previewed', (tester) async {
      await openLibrary(tester);

      expect(inPreview(find.text('Evening loop')), findsOneWidget);
      for (final fact in ['84 BPM', '4/4', '3 tracks']) {
        expect(inPreview(find.text(fact)), findsOneWidget);
      }
      expect(inPreview(find.text('15 FX · 0 backing tracks')), findsOneWidget);
      expect(find.byKey(const Key('library_return_to_tracks')), findsOneWidget);
      expect(find.byKey(const Key('library_open_session')), findsNothing);
    });

    testWidgets('selecting another row previews it and never opens it', (
      tester,
    ) async {
      await openLibrary(tester);

      await tester.tap(row('s-gig'));
      await tester.pumpAndSettle();

      expect(inPreview(find.text('Night set')), findsOneWidget);
      expect(find.byKey(const Key('library_open_session')), findsOneWidget);
      expect(find.byKey(const Key('library_return_to_tracks')), findsNothing);
      verify(() => repository.readPreview('s-gig')).called(1);
      verifyNever(() => session.open(any()));
    });

    testWidgets('Open session opens the selected id once', (tester) async {
      await openLibrary(tester);
      await tester.tap(row('s-gig'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('library_open_session')));
      await tester.pumpAndSettle();

      verify(() => session.open('s-gig')).called(1);
      // Open keeps the Library: the row becomes current in place.
      expect(find.byKey(const Key('library_page')), findsOneWidget);
    });

    testWidgets('Open session is unavailable while a session action runs', (
      tester,
    ) async {
      await openLibrary(
        tester,
        state: SessionState(
          status: SessionStatus.working,
          currentSessionId: 's-cur',
          sessions: _catalog,
        ),
      );
      await tester.tap(row('s-gig'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('library_open_session')));
      await tester.pumpAndSettle();

      verifyNever(() => session.open(any()));
    });

    testWidgets('an opened session turns its footer into Return to tracks', (
      tester,
    ) async {
      final states = StreamController<SessionState>();
      addTearDown(states.close);
      await openLibrary(tester, states: states.stream);
      await tester.tap(row('s-gig'));
      await tester.pumpAndSettle();

      states.add(
        SessionState(
          status: SessionStatus.success,
          outcome: SessionOutcome.loaded,
          currentSessionId: 's-gig',
          currentSessionName: 'Night set',
          sessions: _catalog,
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(inRow('s-gig', l10n.libraryCurrentSession), findsOneWidget);
      expect(find.byKey(const Key('library_return_to_tracks')), findsOneWidget);
    });

    testWidgets('a refused Open shows its reason on that session', (
      tester,
    ) async {
      final states = StreamController<SessionState>();
      addTearDown(states.close);
      await openLibrary(tester, states: states.stream);
      await tester.tap(row('s-gig'));
      await tester.pumpAndSettle();

      states.add(
        SessionState(
          status: SessionStatus.failure,
          error: SessionError.sampleRateMismatch,
          failedSessionId: 's-gig',
          currentSessionId: 's-cur',
          sessions: _catalog,
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.byKey(const Key('library_open_refused')), findsOneWidget);
      expect(find.text(l10n.sessionErrorSampleRate), findsOneWidget);

      // The refusal belongs to Night set, not to whatever is selected next.
      await tester.tap(row('s-new'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('library_open_refused')), findsNothing);
    });

    testWidgets('an Open refused for any other reason says why in the '
        'Library', (tester) async {
      final states = StreamController<SessionState>();
      addTearDown(states.close);
      await openLibrary(tester, states: states.stream);
      await tester.tap(row('s-gig'));
      await tester.pumpAndSettle();

      // What SessionCubit.open emits when the audio device is not running.
      const reason =
          'Bad state: audio device must be running before session '
          'load';
      states.add(
        SessionState(
          status: SessionStatus.failure,
          error: SessionError.unknown,
          errorMessage: reason,
          failedSessionId: 's-gig',
          currentSessionId: 's-cur',
          sessions: _catalog,
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(
        inPreview(find.text(l10n.sessionErrorGeneric(reason))),
        findsOneWidget,
      );
    });

    testWidgets('a failure of another action shows no Open refusal', (
      tester,
    ) async {
      final states = StreamController<SessionState>();
      addTearDown(states.close);
      await openLibrary(tester, states: states.stream);
      await tester.tap(row('s-gig'));
      await tester.pumpAndSettle();

      states.add(
        SessionState(
          status: SessionStatus.failure,
          error: SessionError.unknown,
          errorMessage: 'disk full',
          currentSessionId: 's-cur',
          sessions: _catalog,
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.byKey(const Key('library_open_refused')), findsNothing);
    });

    testWidgets('Open session is dimmed while a session action runs', (
      tester,
    ) async {
      await openLibrary(
        tester,
        state: SessionState(
          status: SessionStatus.working,
          currentSessionId: 's-cur',
          sessions: _catalog,
        ),
      );
      await tester.tap(row('s-gig'));
      await tester.pumpAndSettle();

      final opacity = tester.widget<Opacity>(
        find
            .ancestor(
              of: find.byKey(const Key('library_open_session')),
              matching: find.byType(Opacity),
            )
            .first,
      );
      expect(opacity.opacity, lessThan(1));
    });

    testWidgets('a selection the search hides is not previewed', (
      tester,
    ) async {
      await openLibrary(tester);
      await tester.tap(find.byKey(const Key('library_search')));
      await tester.pumpAndSettle();
      await type(tester, 'night');

      expect(inPreview(find.text(l10n.libraryNoSelection)), findsOneWidget);
      expect(find.byKey(const Key('library_return_to_tracks')), findsNothing);
    });
  });

  group('type', () {
    TextStyle styleOf(WidgetTester tester, Finder text) =>
        tester.widget<Text>(text).style!;

    testWidgets('the musical facts and track figures are in the mono face', (
      tester,
    ) async {
      await openLibrary(tester);

      for (final fact in ['84 BPM', '4/4', '3 tracks']) {
        expect(
          styleOf(tester, inPreview(find.text(fact))).fontFamily,
          SurfaceTheme.monoFont,
        );
      }
      expect(
        styleOf(
          tester,
          find
              .descendant(
                of: find.byKey(const Key('library_track_1')),
                matching: find.text('4'),
              )
              .first,
        ).fontFamily,
        SurfaceTheme.monoFont,
      );
    });

    testWidgets('the search placeholder is drawn like a query, as the pen '
        'draws it', (tester) async {
      await openLibrary(tester);
      final context = tester.element(find.byKey(const Key('library_search')));
      expect(
        styleOf(
          tester,
          find.descendant(
            of: find.byKey(const Key('library_search')),
            matching: find.text(l10n.librarySearchSessions),
          ),
        ).color,
        context.surface.textPrimary,
      );
    });
  });

  group('saved date', () {
    Future<BuildContext> contextOf(WidgetTester tester) async {
      await tester.pumpApp(const SizedBox.shrink());
      return tester.element(find.byType(SizedBox));
    }

    // Not the wall clock's day, so the label must read [now].
    final now = DateTime(2025, 3, 4, 15, 30);

    testWidgets('a session saved today reads as today, with the time', (
      tester,
    ) async {
      final context = await contextOf(tester);
      expect(
        savedDateLabel(context, DateTime(2025, 3, 4, 9, 5), now: now),
        l10n.sessionDateToday('09:05'),
      );
    });

    testWidgets('older saves read as yesterday, then as a short date', (
      tester,
    ) async {
      final context = await contextOf(tester);
      expect(
        savedDateLabel(context, DateTime(2025, 3, 3, 23, 59), now: now),
        l10n.sessionDateYesterday,
      );
      expect(
        savedDateLabel(context, DateTime(2025, 2, 7, 10), now: now),
        '7 Feb',
      );
      expect(savedDateLabel(context, null, now: now), isEmpty);
    });
  });

  group('USB with a drive that cannot be read', () {
    RemovableVolume volume(RemovableVolumeStatus status) => RemovableVolume(
      generation: 1,
      fingerprint: 'f',
      label: 'MAC DRIVE',
      fsType: 'hfsplus',
      sizeBytes: 1,
      status: status,
    );

    testWidgets('an unsupported filesystem says so, not "connect a drive"', (
      tester,
    ) async {
      await openLibrary(
        tester,
        volumes: _OneDrive(volume(RemovableVolumeStatus.unsupported)),
      );
      await tester.tap(find.byKey(const Key('library_location_usb')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('library_unusable_usb')), findsOneWidget);
      expect(find.text(l10n.libraryUsbUnsupported('hfsplus')), findsOneWidget);
      expect(find.text(l10n.libraryConnectUsb), findsNothing);
    });

    testWidgets('a failed mount says so', (tester) async {
      await openLibrary(
        tester,
        volumes: _OneDrive(volume(RemovableVolumeStatus.mountFailed)),
      );
      await tester.tap(find.byKey(const Key('library_location_usb')));
      await tester.pumpAndSettle();

      expect(find.text(l10n.libraryUsbMountFailed), findsOneWidget);
    });

    testWidgets('an ejected drive reads as no drive', (tester) async {
      await openLibrary(
        tester,
        volumes: _OneDrive(volume(RemovableVolumeStatus.ejected)),
      );
      await tester.tap(find.byKey(const Key('library_location_usb')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('library_connect_usb')), findsOneWidget);
    });
  });

  group('preview', () {
    testWidgets('each track shows bars, layers and FX, and a clip at its '
        'share of the longest track', (tester) async {
      await openLibrary(tester);

      final lane = tester.getSize(
        find.descendant(
          of: find.byKey(const Key('library_track_1')),
          matching: find.byKey(const Key('library_track_clip')),
        ),
      );
      double clipWidth(int channel) => tester
          .getSize(
            find.descendant(
              of: find.byKey(Key('library_track_$channel')),
              matching: find.byKey(const Key('library_track_clip')),
            ),
          )
          .width;
      expect(clipWidth(0), closeTo(lane.width / 2, 0.5));
      expect(clipWidth(2), closeTo(lane.width / 4, 0.5));
      expect(lane.height, 74);
      expect(
        find.descendant(
          of: find.byKey(const Key('library_track_0')),
          matching: find.text('Track 1'),
        ),
        findsOneWidget,
      );
      expect(find.text('FX 3'), findsNWidgets(3));
      expect(find.text('layers'), findsNWidgets(3));
    });

    testWidgets('a track without bars shows seconds', (tester) async {
      await openLibrary(tester);
      await tester.tap(row('s-gig'));
      await tester.pumpAndSettle();

      expect(inPreview(find.text('1.5')), findsOneWidget);
      expect(inPreview(find.text(l10n.librarySecondsUnit)), findsOneWidget);
    });

    testWidgets('a session without audio says so', (tester) async {
      await openLibrary(tester);
      await tester.tap(row('s-new'));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('library_preview_no_tracks')),
        findsOneWidget,
      );
    });

    testWidgets('a session saved by a newer build shows the refusal', (
      tester,
    ) async {
      when(() => repository.readPreview('s-gig')).thenThrow(
        const SessionUnsupportedVersion(version: 99, supported: 11),
      );
      await openLibrary(tester);
      await tester.tap(row('s-gig'));
      await tester.pumpAndSettle();

      expect(
        inPreview(find.text(l10n.sessionErrorUnsupportedVersion)),
        findsOneWidget,
      );
      expect(find.byKey(const Key('library_open_session')), findsNothing);
    });

    testWidgets('a session too old to convert says so', (tester) async {
      when(() => repository.readPreview('s-gig')).thenThrow(
        const SessionUnconvertible(version: 0, reason: 'older than 1'),
      );
      await openLibrary(tester);
      await tester.tap(row('s-gig'));
      await tester.pumpAndSettle();

      expect(
        inPreview(find.text(l10n.sessionErrorUnconvertible)),
        findsOneWidget,
      );
    });

    testWidgets('a session that does not decode says it cannot be read', (
      tester,
    ) async {
      when(
        () => repository.readPreview('s-gig'),
      ).thenThrow(const FormatException('bad'));
      await openLibrary(tester);
      await tester.tap(row('s-gig'));
      await tester.pumpAndSettle();

      expect(
        inPreview(find.text(l10n.libraryPreviewUnreadable)),
        findsOneWidget,
      );
    });
  });

  group('search and folders', () {
    testWidgets('search filters by a case-insensitive substring', (
      tester,
    ) async {
      await openLibrary(tester);

      await tester.tap(find.byKey(const Key('library_search')));
      await tester.pumpAndSettle();
      await type(tester, 'NIGHT');

      expect(row('s-gig'), findsOneWidget);
      expect(row('s-cur'), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(const Key('library_search')),
          matching: find.text('NIGHT'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('a search that hides every row says so', (tester) async {
      await openLibrary(tester);
      await tester.tap(find.byKey(const Key('library_search')));
      await tester.pumpAndSettle();
      await type(tester, 'zzz');

      expect(find.text(l10n.libraryNoMatches), findsOneWidget);
    });

    testWidgets('Unfiled is the root and a folder chip is that folder', (
      tester,
    ) async {
      await openLibrary(tester);

      await tester.tap(find.byKey(const Key('library_folder_unfiled')));
      await tester.pumpAndSettle();
      expect(row('s-cur'), findsOneWidget);
      expect(row('s-new'), findsOneWidget);
      expect(row('s-gig'), findsNothing);

      await tester.tap(find.byKey(const Key('library_folder_Gigs')));
      await tester.pumpAndSettle();
      expect(row('s-gig'), findsOneWidget);
      expect(row('s-cur'), findsNothing);

      await tester.tap(find.byKey(const Key('library_folder_all')));
      await tester.pumpAndSettle();
      expect(row('s-gig'), findsOneWidget);
      expect(row('s-cur'), findsOneWidget);
    });
  });

  group('USB', () {
    testWidgets('with no drive says to connect one and keeps internal a tap '
        'away', (tester) async {
      await openLibrary(tester);

      await tester.tap(find.byKey(const Key('library_location_usb')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('library_connect_usb')), findsOneWidget);
      expect(find.text(l10n.libraryConnectUsb), findsOneWidget);
      expect(find.text(l10n.libraryConnectUsbBody), findsOneWidget);
      expect(row('s-cur'), findsNothing);

      await tester.tap(find.byKey(const Key('library_location_internal')));
      await tester.pumpAndSettle();
      expect(row('s-cur'), findsOneWidget);
    });
  });

  group('leaving', () {
    testWidgets('a footswitch press returns to Tracks', (tester) async {
      await openLibrary(tester);

      pedalEvents.add(const ButtonPressed(PedalButton.recPlay));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('library_page')), findsNothing);
      expect(find.text('stage'), findsOneWidget);
    });

    testWidgets('a footswitch press also closes the search keyboard', (
      tester,
    ) async {
      await openLibrary(tester);
      await tester.tap(find.byKey(const Key('library_search')));
      await tester.pumpAndSettle();

      pedalEvents.add(const ButtonPressed(PedalButton.clear));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('library_page')), findsNothing);
      expect(find.text('stage'), findsOneWidget);
    });

    testWidgets('Return to tracks returns to Tracks', (tester) async {
      await openLibrary(tester);
      await tester.tap(find.byKey(const Key('library_return_to_tracks')));
      await tester.pumpAndSettle();
      expect(find.text('stage'), findsOneWidget);
    });

    testWidgets('Stage and Back return to Tracks', (tester) async {
      await openLibrary(tester);
      await tester.tap(find.byKey(const Key('loop_settings_stage')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('library_page')), findsNothing);

      await tester.tap(find.text('stage'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('loop_settings_back')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('library_page')), findsNothing);
    });
  });

  group('manage', () {
    late StreamController<SessionState> states;

    setUp(() {
      states = StreamController<SessionState>.broadcast();
      when(session.save).thenAnswer((_) async {});
      when(() => session.saveAs(any())).thenAnswer((_) async {});
      when(
        () => session.duplicateSession(any(), any()),
      ).thenAnswer((_) async {});
      when(() => session.renameSession(any(), any())).thenAnswer((_) async {});
      when(
        () => session.moveSession(any(), folder: any(named: 'folder')),
      ).thenAnswer((_) async {});
      when(() => session.deleteSession(any())).thenAnswer((_) async {});
      when(() => session.createFolder(any())).thenAnswer((_) async {});
    });

    tearDown(() => states.close());

    SessionState current({
      SessionStatus status = SessionStatus.idle,
      SessionOutcome? outcome,
      SessionError? error,
      String currentId = 's-cur',
      List<SessionSummary>? sessions,
    }) => SessionState(
      status: status,
      outcome: outcome,
      error: error,
      currentSessionId: currentId,
      currentSessionName: currentId,
      sessions: sessions ?? _catalog,
      folders: const ['Gigs'],
    );

    Future<void> open(WidgetTester tester, {SessionState? state}) =>
        openLibrary(tester, state: state ?? current(), states: states.stream);

    /// Moves the mocked cubit to [next] the way a real action settles.
    Future<void> settle(SessionState next) async {
      states.add(next);
      await Future<void>.delayed(Duration.zero);
    }

    Future<void> manage(WidgetTester tester, {String? select}) async {
      if (select != null) {
        await tester.tap(row(select));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.byKey(const Key('library_manage')));
      await tester.pumpAndSettle();
    }

    Future<void> choose(WidgetTester tester, String option) async {
      await tester.tap(find.byKey(Key('fx_option_$option')));
      await tester.pumpAndSettle();
    }

    testWidgets('lists Save, Save as, Duplicate, Rename, Move and Delete, '
        'with Delete disabled on the open session', (tester) async {
      await open(tester);
      await manage(tester);

      for (final label in [
        l10n.sessionSave,
        l10n.sessionSaveAs,
        l10n.sessionDuplicate,
        l10n.sessionRename,
        l10n.libraryMoveToFolder,
        l10n.sessionDelete,
      ]) {
        expect(find.text(label), findsOneWidget);
      }
      await tester.tap(find.byKey(const Key('fx_option_delete')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('fx_options_sheet')), findsOneWidget);
      verifyNever(() => session.deleteSession(any()));
    });

    testWidgets('Save writes the live rig back', (tester) async {
      await open(tester);
      await manage(tester);
      await choose(tester, 'save');
      verify(session.save).called(1);
    });

    testWidgets('Save as names a new session on the keyboard sheet', (
      tester,
    ) async {
      await open(tester);
      await manage(tester);
      await choose(tester, 'saveAs');

      expect(find.text(l10n.sessionNameHint), findsWidgets);
      await type(tester, 'Bridge');

      verify(() => session.saveAs('Bridge')).called(1);
      expect(find.byKey(const Key('console_rename_sheet')), findsNothing);
    });

    testWidgets('Save as on a taken name answers in the sheet and saves '
        'nothing', (tester) async {
      await open(tester);
      await manage(tester);
      await choose(tester, 'saveAs');
      await type(tester, 'Night set!');

      expect(find.text(l10n.sessionNameDuplicate('Night set')), findsOneWidget);
      expect(find.byKey(const Key('console_rename_sheet')), findsOneWidget);
      verifyNever(() => session.saveAs(any()));
    });

    testWidgets('a name the cubit refuses keeps the sheet open with the '
        'reason', (tester) async {
      when(() => session.saveAs(any())).thenAnswer(
        (_) => settle(
          current(
            status: SessionStatus.failure,
            error: SessionError.nameCollision,
          ),
        ),
      );
      await open(tester);
      await manage(tester);
      await choose(tester, 'saveAs');
      await type(tester, 'Raced');

      expect(find.text(l10n.sessionNameDuplicate('Raced')), findsOneWidget);
      expect(find.byKey(const Key('console_rename_sheet')), findsOneWidget);
    });

    testWidgets('Duplicate copies the selected session under a new name', (
      tester,
    ) async {
      await open(tester);
      await manage(tester, select: 's-gig');
      await choose(tester, 'duplicate');
      await type(tester, 'Night set copy');

      verify(
        () => session.duplicateSession('s-gig', 'Night set copy'),
      ).called(1);
    });

    testWidgets('Rename renames the selected session and may keep its own '
        'name', (tester) async {
      await open(tester);
      await manage(tester, select: 's-gig');
      await choose(tester, 'rename');
      await type(tester, 'Night set');

      verify(() => session.renameSession('s-gig', 'Night set')).called(1);
    });

    testWidgets('Move to folder moves into a folder, with where it is '
        'disabled', (tester) async {
      await open(tester);
      await manage(tester);
      await choose(tester, 'move');

      // Evening loop is Unfiled already.
      await tester.tap(find.byKey(const Key('fx_option_\u0000unfiled')));
      await tester.pumpAndSettle();
      verifyNever(
        () => session.moveSession(any(), folder: any(named: 'folder')),
      );

      await choose(tester, 'Gigs');
      verify(() => session.moveSession('s-cur', folder: 'Gigs')).called(1);
    });

    testWidgets('Move to Unfiled moves out of a folder', (tester) async {
      await open(tester);
      await manage(tester, select: 's-gig');
      await choose(tester, 'move');
      await choose(tester, '\u0000unfiled');

      verify(() => session.moveSession('s-gig')).called(1);
    });

    testWidgets('Move to a new folder creates it, then moves', (tester) async {
      await open(tester);
      await manage(tester);
      await choose(tester, 'move');
      await choose(tester, '\u0000new');
      await type(tester, 'Demos');

      verifyInOrder([
        () => session.createFolder('Demos'),
        () => session.moveSession('s-cur', folder: 'Demos'),
      ]);
    });

    testWidgets('Delete asks first, then deletes the selected session', (
      tester,
    ) async {
      await open(tester);
      await manage(tester, select: 's-gig');
      await choose(tester, 'delete');

      expect(
        find.text(l10n.sessionDeleteConfirmTitle('Night set')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('console_confirm_confirm')));
      await tester.pumpAndSettle();
      verify(() => session.deleteSession('s-gig')).called(1);
    });

    testWidgets('cancelling the delete question deletes nothing', (
      tester,
    ) async {
      await open(tester);
      await manage(tester, select: 's-gig');
      await choose(tester, 'delete');
      await tester.tap(find.byKey(const Key('console_confirm_cancel')));
      await tester.pumpAndSettle();
      verifyNever(() => session.deleteSession(any()));
    });

    testWidgets('Manage is there for a session whose preview cannot be read', (
      tester,
    ) async {
      when(
        () => repository.readPreview('s-gig'),
      ).thenThrow(const FormatException('bad'));
      await open(tester);
      await manage(tester, select: 's-gig');
      await choose(tester, 'delete');
      await tester.tap(find.byKey(const Key('console_confirm_confirm')));
      await tester.pumpAndSettle();
      verify(() => session.deleteSession('s-gig')).called(1);
    });

    testWidgets('Manage and New folder wait while an action runs', (
      tester,
    ) async {
      await open(tester, state: current(status: SessionStatus.working));
      await tester.tap(find.byKey(const Key('library_manage')));
      await tester.tap(find.byKey(const Key('library_new_folder')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('fx_options_sheet')), findsNothing);
      expect(find.byKey(const Key('console_rename_sheet')), findsNothing);
    });

    testWidgets('New folder creates a folder; a taken name answers in the '
        'sheet', (tester) async {
      await open(tester);
      await tester.tap(find.byKey(const Key('library_new_folder')));
      await tester.pumpAndSettle();
      await type(tester, 'Gigs');
      expect(find.text(l10n.libraryFolderNameTaken('Gigs')), findsOneWidget);
      verifyNever(() => session.createFolder(any()));

      await type(tester, 'Demos');
      verify(() => session.createFolder('Demos')).called(1);
      expect(find.byKey(const Key('console_rename_sheet')), findsNothing);
    });

    testWidgets('the chips are the catalog folders', (tester) async {
      await open(tester);
      expect(find.byKey(const Key('library_folder_Gigs')), findsOneWidget);
    });
  });

  group('after an action', () {
    late StreamController<SessionState> states;

    setUp(() => states = StreamController<SessionState>.broadcast());
    tearDown(() => states.close());

    testWidgets('a Save as selects the new current session', (tester) async {
      await openLibrary(tester, states: states.stream);
      states.add(
        SessionState(
          status: SessionStatus.success,
          outcome: SessionOutcome.savedAs,
          currentSessionId: 's-gig',
          currentSessionName: 'Night set',
          sessions: _catalog,
        ),
      );
      await tester.pumpAndSettle();

      expect(inPreview(find.text('Night set')), findsOneWidget);
      expect(find.byKey(const Key('library_return_to_tracks')), findsOneWidget);
    });

    testWidgets('a deleted selection falls back to the open session', (
      tester,
    ) async {
      await openLibrary(tester, states: states.stream);
      await tester.tap(row('s-gig'));
      await tester.pumpAndSettle();

      states.add(
        SessionState(
          status: SessionStatus.success,
          outcome: SessionOutcome.deleted,
          currentSessionId: 's-cur',
          sessions: [_catalog[0], _catalog[2]],
        ),
      );
      await tester.pumpAndSettle();

      expect(inPreview(find.text('Evening loop')), findsOneWidget);
    });

    testWidgets('with no open session a deleted selection clears the card', (
      tester,
    ) async {
      await openLibrary(
        tester,
        state: SessionState(sessions: _catalog),
        states: states.stream,
      );
      await tester.tap(row('s-gig'));
      await tester.pumpAndSettle();

      states.add(
        SessionState(
          status: SessionStatus.success,
          outcome: SessionOutcome.deleted,
          sessions: [_catalog[0]],
        ),
      );
      await tester.pumpAndSettle();

      expect(inPreview(find.text(l10n.libraryNoSelection)), findsOneWidget);
      expect(
        tester
            .element(find.byType(LibraryView))
            .read<LibraryCubit>()
            .state
            .selectedId,
        isNull,
      );
    });

    testWidgets('a rename re-reads the selected preview', (tester) async {
      await openLibrary(tester, states: states.stream);
      clearInteractions(repository);

      states.add(
        SessionState(
          status: SessionStatus.success,
          outcome: SessionOutcome.renamed,
          currentSessionId: 's-cur',
          sessions: _catalog,
        ),
      );
      await tester.pumpAndSettle();

      verify(() => repository.readPreview('s-cur')).called(1);
    });
  });

  group('the 19/05 line', () {
    late StreamController<SessionState> states;

    setUp(() => states = StreamController<SessionState>.broadcast());
    tearDown(() => states.close());

    SessionState failed(
      SessionError error, {
      String? failedSessionId,
      int count = 1,
    }) => SessionState(
      status: SessionStatus.failure,
      error: error,
      failedSessionId: failedSessionId,
      currentSessionId: 's-cur',
      sessions: _catalog,
      failureCount: count,
    );

    /// Opens the Library, then fails an action taken on it.
    Future<void> failWith(
      WidgetTester tester,
      SessionError error, {
      String? failedSessionId,
    }) async {
      await openLibrary(tester, states: states.stream);
      states.add(failed(error, failedSessionId: failedSessionId));
      await tester.pump();
      await tester.pump();
    }

    testWidgets('a failed save says nothing was changed, under a shorter '
        'layout', (tester) async {
      await failWith(tester, SessionError.saveFailed);

      expect(find.text(l10n.librarySaveFailed), findsOneWidget);
      expect(
        tester.getTopLeft(find.byKey(const Key('library_failure'))).dy,
        closeTo(96 + 916, 8),
      );
      expect(
        tester.getSize(find.byKey(const Key('library_preview'))).height,
        760,
      );
    });

    testWidgets('an Open stopped by an unfinished take says so on the line, '
        'not on the target', (tester) async {
      await failWith(
        tester,
        SessionError.captureInProgress,
        failedSessionId: 's-gig',
      );
      expect(find.text(l10n.libraryTakeStillRunning), findsOneWidget);
      expect(find.byKey(const Key('library_open_refused')), findsNothing);
    });

    testWidgets('a refused delete has its own words', (tester) async {
      await failWith(tester, SessionError.currentSessionProtected);
      expect(find.text(l10n.libraryDeleteCurrentRefused), findsOneWidget);
    });

    testWidgets('a folder that still holds sessions says so', (tester) async {
      await failWith(tester, SessionError.folderNotEmpty);
      expect(find.text(l10n.libraryFolderNotEmpty), findsOneWidget);
    });

    testWidgets('any other failed action says it did not work', (
      tester,
    ) async {
      await failWith(tester, SessionError.unknown);
      expect(find.text(l10n.libraryActionFailed), findsOneWidget);
    });

    testWidgets('an Open refused for any reason stays off the line', (
      tester,
    ) async {
      await failWith(tester, SessionError.unknown, failedSessionId: 's-gig');
      expect(find.byKey(const Key('library_failure')), findsNothing);
    });

    testWidgets('an open refusal stays on the preview card, not the line', (
      tester,
    ) async {
      await failWith(
        tester,
        SessionError.sampleRateMismatch,
        failedSessionId: 's-gig',
      );
      expect(find.byKey(const Key('library_failure')), findsNothing);
      expect(
        tester.getSize(find.byKey(const Key('library_preview'))).height,
        820,
      );
    });

    testWidgets('a failure from before the Library opened is not shown', (
      tester,
    ) async {
      await openLibrary(tester, state: failed(SessionError.saveFailed));
      expect(find.byKey(const Key('library_failure')), findsNothing);
    });

    testWidgets('a failure from before the Library opened stays hidden '
        'through the refresh on open, and a new one shows', (tester) async {
      await openLibrary(
        tester,
        state: failed(SessionError.saveFailed),
        states: states.stream,
      );
      // The page's own refresh re-lists and keeps the result as it was.
      states.add(failed(SessionError.saveFailed).copyWith(sessions: _catalog));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('library_failure')), findsNothing);

      states.add(failed(SessionError.unknown, count: 2));
      await tester.pump();
      await tester.pump();
      expect(find.text(l10n.libraryActionFailed), findsOneWidget);
    });

    test('a failure with no classified error says nothing', () {
      expect(
        libraryFailureOf(const SessionState(status: SessionStatus.failure)),
        isNull,
      );
    });

    testWidgets('another failure goes once another row is selected', (
      tester,
    ) async {
      await failWith(tester, SessionError.unknown);
      expect(find.byKey(const Key('library_failure')), findsOneWidget);

      await tester.tap(row('s-gig'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('library_failure')), findsNothing);
    });

    testWidgets('a failed save stays through a selection', (tester) async {
      await failWith(tester, SessionError.saveFailed);

      await tester.tap(row('s-gig'));
      await tester.pumpAndSettle();

      expect(find.text(l10n.librarySaveFailed), findsOneWidget);
    });
  });

  group('Open asks before it stops playback (D8)', () {
    LooperState withTrack(TrackState state) => LooperState(
      transport: const TransportState(isRunning: true),
      tracks: [
        Track(state: state, lengthFrames: 48000),
        for (var c = 1; c < 8; c++) Track(channel: c),
      ],
    );

    Future<void> tapOpen(WidgetTester tester, LooperState looperState) async {
      await openLibrary(tester, looperState: looperState);
      await tester.tap(row('s-gig'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('library_open_session')));
      await tester.pumpAndSettle();
    }

    for (final state in [TrackState.playing, TrackState.recording]) {
      testWidgets('a ${state.name} track is asked about first', (
        tester,
      ) async {
        await tapOpen(tester, withTrack(state));

        expect(
          find.text(l10n.libraryOpenInterruptTitle('Night set')),
          findsOneWidget,
        );
        verifyNever(() => session.open(any()));

        await tester.tap(find.byKey(const Key('console_confirm_confirm')));
        await tester.pumpAndSettle();
        verify(() => session.open('s-gig')).called(1);
      });
    }

    testWidgets('Cancel changes nothing', (tester) async {
      await tapOpen(tester, withTrack(TrackState.playing));
      await tester.tap(find.byKey(const Key('console_confirm_cancel')));
      await tester.pumpAndSettle();
      verifyNever(() => session.open(any()));
    });

    testWidgets('stopped tracks on a running device are not asked about', (
      tester,
    ) async {
      await tapOpen(tester, withTrack(TrackState.stopped));

      expect(
        find.text(l10n.libraryOpenInterruptTitle('Night set')),
        findsNothing,
      );
      verify(() => session.open('s-gig')).called(1);
    });
  });

  group('a failed preservation', () {
    testWidgets('shows the 19/05 line, not a refusal on the target', (
      tester,
    ) async {
      final states = StreamController<SessionState>.broadcast();
      addTearDown(states.close);
      await openLibrary(tester, states: states.stream);
      await tester.tap(row('s-gig'));
      await tester.pumpAndSettle();

      states.add(
        SessionState(
          status: SessionStatus.failure,
          error: SessionError.saveFailed,
          failedSessionId: 's-gig',
          currentSessionId: 's-cur',
          sessions: _catalog,
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.text(l10n.librarySaveFailed), findsOneWidget);
      expect(find.byKey(const Key('library_open_refused')), findsNothing);
    });
  });

  group('New loop (19/02)', () {
    Future<void> tapNewLoop(
      WidgetTester tester, {
      SessionState? state,
      Stream<SessionState> states = const Stream.empty(),
      LooperState looperState = const LooperState(),
    }) async {
      when(session.newLoop).thenAnswer((_) async {});
      await openLibrary(
        tester,
        state: state,
        states: states,
        looperState: looperState,
      );
      await tester.tap(find.byKey(const Key('library_new_loop')));
      await tester.pumpAndSettle();
    }

    testWidgets('always asks, naming the session that stays and drawing its '
        'tracks giving way to empty ones', (tester) async {
      await tapNewLoop(
        tester,
        looperState: LooperState(
          tracks: [
            const Track(state: TrackState.stopped, lengthFrames: 48000),
            for (var c = 1; c < 8; c++)
              Track(
                channel: c,
                state: c == 2 ? TrackState.stopped : TrackState.empty,
                lengthFrames: c == 2 ? 48000 : 0,
              ),
          ],
        ),
      );

      expect(find.byKey(const Key('new_loop_sheet')), findsOneWidget);
      expect(
        find.text(
          l10n.libraryNewLoopStays('Evening loop'),
          findRichText: true,
        ),
        findsOneWidget,
      );
      expect(find.text(l10n.libraryNewLoopKeeps), findsOneWidget);
      Finder slot(String strip, int channel, String fill) => find.descendant(
        of: find.byKey(Key(strip)),
        matching: find.byKey(Key('library_strip_${channel}_$fill')),
      );
      expect(slot('new_loop_before', 0, 'filled'), findsOneWidget);
      expect(slot('new_loop_before', 1, 'empty'), findsOneWidget);
      expect(slot('new_loop_before', 2, 'filled'), findsOneWidget);
      for (var c = 0; c < 8; c++) {
        expect(slot('new_loop_after', c, 'empty'), findsOneWidget);
      }
      verifyNever(session.newLoop);
    });

    testWidgets('a loop with no name yet is the current loop', (tester) async {
      await tapNewLoop(
        tester,
        state: SessionState(sessions: _catalog),
      );

      expect(find.text(l10n.libraryNewLoopStaysUnnamed), findsOneWidget);
    });

    testWidgets('Cancel changes nothing', (tester) async {
      await tapNewLoop(tester);

      await tester.tap(find.byKey(const Key('new_loop_cancel')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('new_loop_sheet')), findsNothing);
      expect(find.byKey(const Key('library_page')), findsOneWidget);
      verifyNever(session.newLoop);
    });

    testWidgets('Start new loop starts it', (tester) async {
      await tapNewLoop(tester);

      await tester.tap(find.byKey(const Key('new_loop_start')));
      await tester.pumpAndSettle();

      verify(session.newLoop).called(1);
    });

    testWidgets('a started new loop is played on the stage (19/06)', (
      tester,
    ) async {
      final states = StreamController<SessionState>.broadcast();
      addTearDown(states.close);
      await tapNewLoop(tester, states: states.stream);
      await tester.tap(find.byKey(const Key('new_loop_start')));
      await tester.pumpAndSettle();

      states
        ..add(
          SessionState(
            status: SessionStatus.working,
            currentSessionId: 's-cur',
            currentSessionName: 'Evening loop',
            sessions: _catalog,
          ),
        )
        ..add(
          SessionState(
            status: SessionStatus.success,
            outcome: SessionOutcome.newLoop,
            currentSessionId: 's-new',
            currentSessionName: 'New loop 2',
            sessions: _catalog,
          ),
        );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('library_page')), findsNothing);
      expect(find.text('stage'), findsOneWidget);
    });

    testWidgets('a new loop that could not be saved yet is on the stage too, '
        'which says so', (tester) async {
      final states = StreamController<SessionState>.broadcast();
      addTearDown(states.close);
      await tapNewLoop(tester, states: states.stream);
      await tester.tap(find.byKey(const Key('new_loop_start')));
      await tester.pumpAndSettle();

      states.add(
        SessionState(
          status: SessionStatus.failure,
          error: SessionError.newLoopNotSaved,
          currentSessionId: 's-new',
          currentSessionName: 'New loop 2',
          sessions: _catalog,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('library_page')), findsNothing);
    });

    testWidgets('an Open stays in the Library', (tester) async {
      final states = StreamController<SessionState>.broadcast();
      addTearDown(states.close);
      await openLibrary(tester, states: states.stream);

      states
        ..add(
          SessionState(
            status: SessionStatus.working,
            currentSessionId: 's-cur',
            sessions: _catalog,
          ),
        )
        ..add(
          SessionState(
            status: SessionStatus.success,
            outcome: SessionOutcome.loaded,
            currentSessionId: 's-gig',
            currentSessionName: 'Night set',
            sessions: _catalog,
          ),
        );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('library_page')), findsOneWidget);
    });
  });

  group('folders', () {
    late StreamController<SessionState> states;

    setUp(() {
      states = StreamController<SessionState>.broadcast();
      when(() => session.deleteFolder(any())).thenAnswer((_) async {});
      when(() => session.renameFolder(any(), any())).thenAnswer((_) async {});
    });
    tearDown(() => states.close());

    SessionState withFolders(
      List<String> folders, {
      List<SessionSummary>? sessions,
    }) => SessionState(
      currentSessionId: 's-cur',
      currentSessionName: 'Evening loop',
      sessions: sessions ?? _catalog,
      folders: folders,
    );

    Future<void> longPressChip(WidgetTester tester, String folder) async {
      await tester.longPress(find.byKey(Key('library_folder_$folder')));
      await tester.pumpAndSettle();
    }

    testWidgets('a folder holding a session can be renamed, not deleted', (
      tester,
    ) async {
      await openLibrary(tester, state: withFolders(const ['Gigs']));
      await longPressChip(tester, 'Gigs');

      await tester.tap(find.byKey(const Key('fx_option_delete')));
      await tester.pumpAndSettle();
      verifyNever(() => session.deleteFolder(any()));

      await tester.tap(find.byKey(const Key('fx_option_rename')));
      await tester.pumpAndSettle();
      await type(tester, 'Shows');
      verify(() => session.renameFolder('Gigs', 'Shows')).called(1);
    });

    testWidgets('an empty folder is deleted after asking', (tester) async {
      await openLibrary(
        tester,
        state: withFolders(const ['Gigs', 'Spare']),
      );
      await longPressChip(tester, 'Spare');
      await tester.tap(find.byKey(const Key('fx_option_delete')));
      await tester.pumpAndSettle();

      expect(find.text(l10n.libraryDeleteFolderTitle('Spare')), findsOneWidget);
      await tester.tap(find.byKey(const Key('console_confirm_confirm')));
      await tester.pumpAndSettle();
      verify(() => session.deleteFolder('Spare')).called(1);
    });

    testWidgets('All and Unfiled have no options', (tester) async {
      await openLibrary(tester, state: withFolders(const ['Gigs']));
      await longPressChip(tester, 'unfiled');
      expect(find.byKey(const Key('fx_options_sheet')), findsNothing);
    });

    testWidgets('a folder name shaped like an id is answered in the sheet', (
      tester,
    ) async {
      when(() => session.createFolder(any())).thenAnswer((_) async {});
      await openLibrary(tester, state: withFolders(const ['Gigs']));
      await tester.tap(find.byKey(const Key('library_new_folder')));
      await tester.pumpAndSettle();
      await type(tester, 's-20261006-120000');

      expect(find.text(l10n.sessionNameInvalid), findsOneWidget);
      verifyNever(() => session.createFolder(any()));
    });

    testWidgets('a chip whose folder went away puts All down', (tester) async {
      await openLibrary(
        tester,
        state: withFolders(const ['Gigs']),
        states: states.stream,
      );
      await tester.tap(find.byKey(const Key('library_folder_Gigs')));
      await tester.pumpAndSettle();
      expect(row('s-cur'), findsNothing);

      states.add(
        SessionState(
          status: SessionStatus.success,
          outcome: SessionOutcome.folderRenamed,
          currentSessionId: 's-cur',
          sessions: _catalog,
          folders: const ['Shows'],
        ),
      );
      await tester.pumpAndSettle();

      expect(row('s-cur'), findsOneWidget);
    });
  });

  group('Manage on another session', () {
    testWidgets('its Save rows name the open session they save', (
      tester,
    ) async {
      when(session.save).thenAnswer((_) async {});
      await openLibrary(tester);
      await tester.tap(row('s-gig'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('library_manage')));
      await tester.pumpAndSettle();

      expect(
        find.text(l10n.libraryManageSaveOpen('Evening loop')),
        findsOneWidget,
      );
      expect(
        find.text(l10n.libraryManageSaveOpenAs('Evening loop')),
        findsOneWidget,
      );
      expect(find.text(l10n.sessionSave), findsNothing);
      await tester.tap(find.byKey(const Key('fx_option_save')));
      await tester.pumpAndSettle();
      verify(session.save).called(1);
    });

    testWidgets('with no open session they name the current loop', (
      tester,
    ) async {
      await openLibrary(tester, state: SessionState(sessions: _catalog));
      await tester.tap(row('s-gig'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('library_manage')));
      await tester.pumpAndSettle();

      expect(
        find.text(l10n.libraryManageSaveOpen(l10n.libraryCurrentLoop)),
        findsOneWidget,
      );
    });
  });
}

/// A port reporting one drive, as the storage service would.
class _OneDrive implements RemovableVolumes {
  _OneDrive(this.drive);

  final RemovableVolume drive;

  @override
  List<RemovableVolume> get current => [drive];

  @override
  Stream<List<RemovableVolume>> get volumes => const Stream.empty();

  @override
  Future<VolumeSpace?> space(StorageDestination destination) async => null;

  @override
  Future<T> withWriteLease<T>(
    StorageDestination target,
    String purpose,
    Future<T> Function(String mountPoint) body,
  ) => throw UnimplementedError();

  @override
  Future<String> copyFile(
    String sourcePath,
    StorageDestination destination,
    String relativePath, {
    required ConflictPolicy onConflict,
  }) => throw UnimplementedError();
}
