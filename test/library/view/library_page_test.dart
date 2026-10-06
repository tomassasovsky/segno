import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/l10n/gen/app_localizations.dart';
import 'package:segno/library/application/removable_volumes.dart';
import 'package:segno/library/view/library_page.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/session/session.dart';
import 'package:session_repository/session_repository.dart';

import '../../helpers/helpers.dart';

class _MockSessionCubit extends MockCubit<SessionState>
    implements SessionCubit {}

class _MockSessionRepository extends Mock implements SessionRepository {}

class _MockPedalRepository extends Mock implements PedalRepository {}

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
    when(repository.listFolders).thenAnswer((_) async => ['Gigs']);
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
  }) async {
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
        child: BlocProvider<SessionCubit>.value(
          value: session,
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

  group('the shell', () {
    testWidgets('draws the title, the Sessions tab, the locations and a '
        'disabled New loop', (tester) async {
      await openLibrary(tester);

      expect(find.byKey(const Key('library_page')), findsOneWidget);
      expect(find.text(l10n.libraryTitle), findsOneWidget);
      expect(find.byKey(const Key('library_tab_sessions')), findsOneWidget);
      expect(
        find.byKey(const Key('library_location_internal')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('library_location_usb')), findsOneWidget);
      // Drawn for the row's geometry, inert until New loop is built.
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
          currentSessionId: 's-cur',
          sessions: _catalog,
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.byKey(const Key('library_open_refused')), findsOneWidget);
      expect(find.text(l10n.sessionErrorSampleRate), findsOneWidget);
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
}
