import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/control/control.dart';
import 'package:segno/control/model/foot_sessions.dart';
import 'package:segno/control/view/pedal_setup/pedal_hardware_face.dart';
import 'package:segno/looper/looper.dart';
import 'package:segno/looper/view/foot_sessions_view.dart';
import 'package:segno/performance/cubit/performance_recorder_cubit.dart';
import 'package:segno/theme/theme.dart';
import 'package:session_repository/session_repository.dart';

import '../../helpers/helpers.dart';

class _Sessions extends Mock implements SessionRepository;

class _Control extends MockCubit<ControlState> implements ControlCubit;

class _Tracks extends MockCubit<TracksState> implements TracksCubit;

class _Looper extends MockBloc<LooperEvent, LooperState> implements LooperBloc;

class _Recorder extends MockCubit<PerformanceRecorderState>
    implements PerformanceRecorderCubit;

const List<PedalButton> _tracks = [
  PedalButton.track1,
  PedalButton.track2,
  PedalButton.track3,
  PedalButton.track4,
];

FootSessionCatalogue _catalogue(List<String> names, {String? openId}) =>
    FootSessionCatalogue(
      sessions: [
        for (final (index, name) in names.indexed)
          FootSessionEntry(
            id: name,
            name: name,
            trackCount: index + 1,
            tempoBpm: index.isEven ? 84 : 0,
            looperMode: index.isEven ? LooperMode.song : null,
          ),
      ],
      openId: openId,
    );

void main() {
  late _Control control;
  late _Tracks tracks;
  late _Looper looper;
  late _Recorder recorder;
  late _Sessions sessions;

  setUpAll(() => registerFallbackValue(Object()));

  /// What the repository says about the session shown.
  void previewIs(SessionPreview preview) =>
      when(() => sessions.readPreview(any())).thenAnswer((_) async => preview);

  /// The rig under the face: [tracks] on the looper, and a performance
  /// recording [recording] or not.
  void rig({List<Track> tracks = const [], bool recording = false}) {
    whenListen(
      looper,
      const Stream<LooperState>.empty(),
      initialState: LooperState(tracks: tracks),
    );
    whenListen(
      recorder,
      const Stream<PerformanceRecorderState>.empty(),
      initialState: recording
          ? const PerformanceRecorderArmed(
              elapsed: Duration.zero,
              overrun: false,
            )
          : const PerformanceRecorderIdle(),
    );
  }

  setUp(() {
    control = _Control();
    tracks = _Tracks();
    looper = _Looper();
    recorder = _Recorder();
    sessions = _Sessions();
    previewIs(
      const SessionPreview(
        summary: SessionSummary(id: 'x', name: 'x'),
        tracks: [],
        fxCount: 0,
        sampleRate: 48000,
      ),
    );
    whenListen(
      tracks,
      const Stream<TracksState>.empty(),
      initialState: const TracksState(names: []),
    );
    rig();
  });

  void given(
    FootSessionCatalogue catalogue, {
    FootSessionsSelection selection = const FootSessionsSelection(),
  }) => whenListen(
    control,
    const Stream<ControlState>.empty(),
    initialState: ControlState(
      mode: InteractionMode.sessions,
      sessionCatalogue: catalogue,
      footSessions: selection,
    ),
  );

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpApp(
      RepositoryProvider<SessionRepository>.value(
        value: sessions,
        child: MultiBlocProvider(
          providers: [
            BlocProvider<ControlCubit>.value(value: control),
            BlocProvider<TracksCubit>.value(value: tracks),
            BlocProvider<LooperBloc>.value(value: looper),
            BlocProvider<PerformanceRecorderCubit>.value(value: recorder),
          ],
          child: const Scaffold(body: FootSessionsView()),
        ),
      ),
    );
  }

  Finder pedal(PedalButton button) =>
      find.byKey(Key('foot_sessions_pedal_${button.name}'));

  Finder under(PedalButton button, String text) =>
      find.descendant(of: pedal(button), matching: find.text(text));

  const readout = Key('foot_sessions_preview');

  Finder inReadout(String text) =>
      find.descendant(of: find.byKey(readout), matching: find.text(text));

  /// The baseline of the one text [finder] finds, from the screen's top.
  double baselineOf(WidgetTester tester, Finder finder) {
    final rich = find.descendant(
      of: finder,
      matching: find.byType(RichText),
      matchRoot: true,
    );
    final paragraph = tester.renderObject<RenderParagraph>(rich.first);
    final painter = TextPainter(
      text: paragraph.text,
      textDirection: paragraph.textDirection,
      textScaler: paragraph.textScaler,
      strutStyle: paragraph.strutStyle,
    )..layout(maxWidth: paragraph.size.width);
    return tester.getTopLeft(rich.first).dy +
        painter.computeDistanceToActualBaseline(TextBaseline.alphabetic);
  }

  testWidgets('draws the ten pedals and names each track switch for the '
      'session in its position', (tester) async {
    given(_catalogue(const ['a', 'b', 'c', 'd', 'e', 'f'], openId: 'b'));
    await pump(tester);

    expect(find.byType(PedalHardwareFace), findsNWidgets(10));
    expect(find.text('Sessions'), findsOneWidget);
    for (final (index, button) in _tracks.indexed) {
      expect(under(button, ['a', 'b', 'c', 'd'][index]), findsOneWidget);
    }
    // The setup under the name: the looper mode and the tempo.
    expect(under(PedalButton.track1, 'Song · 84 BPM'), findsOneWidget);
    // A session whose manifest names neither says what it holds.
    expect(under(PedalButton.track4, '4 tracks'), findsOneWidget);
    expect(under(PedalButton.track2, 'Open now'), findsOneWidget);
    expect(find.text('Open now'), findsOneWidget);
    // A Hold opens every session but the open one.
    expect(find.text('Hold · Open'), findsNWidgets(3));
    expect(under(PedalButton.track2, 'Hold · Open'), findsNothing);
    // Undo saves on a press and starts a new session on its Hold.
    expect(under(PedalButton.undo, 'Save'), findsOneWidget);
    expect(under(PedalButton.undo, 'Hold · New session'), findsOneWidget);
    expect(under(PedalButton.clear, 'Previous page'), findsOneWidget);
    expect(under(PedalButton.bank, 'Next page'), findsOneWidget);
    expect(find.text('1 / 2'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('with no session shown the readout names the page and how '
      'many sessions there are, says what a press and a Hold do, and reads '
      'nothing', (tester) async {
    given(_catalogue(const ['a', 'b', 'c', 'd', 'e', 'f'], openId: 'b'));
    await pump(tester);

    expect(find.text('Page 1 of 2'), findsOneWidget);
    expect(find.text('6 sessions'), findsOneWidget);
    expect(
      find.text('Press a switch to see its session. Hold it to open.'),
      findsOneWidget,
    );
    expect(find.byKey(readout), findsNothing);
    verifyNever(() => sessions.readPreview(any()));
  });

  testWidgets('with a loop playing and no session shown, the readout says '
      'what an Open would end before any press', (tester) async {
    rig(tracks: const [Track(state: TrackState.playing, lengthFrames: 48000)]);
    given(_catalogue(const ['a', 'b'], openId: 'a'));
    await pump(tester);

    expect(find.byKey(const Key('foot_sessions_ends')), findsOneWidget);
    expect(find.text('Opening a session stops playback'), findsOneWidget);
    // With the hint, not in its place.
    expect(find.byKey(const Key('foot_sessions_hint')), findsOneWidget);
  });

  testWidgets('with nothing playing, or no sessions, it says nothing about '
      'an Open', (tester) async {
    given(_catalogue(const ['a', 'b'], openId: 'a'));
    await pump(tester);
    expect(find.byKey(const Key('foot_sessions_ends')), findsNothing);
  });

  testWidgets('the readout lines up with the pedals beside it: its last '
      "line on their captions' baseline, its left edge on the first track "
      "switch's face", (tester) async {
    given(_catalogue(const ['a', 'b'], openId: 'a'));
    await pump(tester);

    expect(
      baselineOf(tester, find.byKey(const Key('foot_sessions_hint'))),
      moreOrLessEquals(
        baselineOf(tester, under(PedalButton.clear, 'Previous page')),
        epsilon: 1,
      ),
    );
    final face = find.descendant(
      of: pedal(PedalButton.track1),
      matching: find.byType(PedalHardwareFace),
    );
    expect(
      tester.getTopLeft(find.byKey(const Key('foot_sessions_page'))).dx,
      moreOrLessEquals(tester.getTopLeft(face).dx, epsilon: 1),
    );
  });

  testWidgets('the last page says Empty under the switches with no session', (
    tester,
  ) async {
    given(
      _catalogue(const ['a', 'b', 'c', 'd', 'e', 'f']),
      selection: const FootSessionsSelection(page: 1),
    );
    await pump(tester);

    expect(find.text('Page 2 of 2'), findsOneWidget);
    expect(under(PedalButton.track1, 'e'), findsOneWidget);
    expect(under(PedalButton.track2, 'f'), findsOneWidget);
    expect(under(PedalButton.track3, 'Empty'), findsOneWidget);
    expect(under(PedalButton.track4, 'Empty'), findsOneWidget);
    expect(find.text('Hold · Open'), findsNWidgets(2));
  });

  testWidgets('a session the player hid is under no switch, and the readout '
      'names it when it is the open one', (tester) async {
    given(
      const FootSessionCatalogue(
        sessions: [
          FootSessionEntry(id: 'a', name: 'a'),
          FootSessionEntry(id: 'x', name: 'Scratch', onFace: false),
          FootSessionEntry(id: 'z', name: 'z'),
        ],
        openId: 'x',
      ),
    );
    await pump(tester);

    expect(under(PedalButton.track1, 'a'), findsOneWidget);
    expect(under(PedalButton.track2, 'z'), findsOneWidget);
    expect(under(PedalButton.track3, 'Empty'), findsOneWidget);
    expect(find.text('Scratch'), findsNothing);
    expect(find.text('2 sessions · Open: Scratch'), findsOneWidget);
    expect(find.text('Open now'), findsNothing);
  });

  testWidgets('an open session the face lists is not named in the readout', (
    tester,
  ) async {
    given(_catalogue(const ['a', 'b'], openId: 'a'));
    await pump(tester);

    expect(find.text('2 sessions'), findsOneWidget);
    expect(find.textContaining('Open:'), findsNothing);
  });

  testWidgets('the session being opened says so under its switch and in '
      'the readout, and nothing says what an Open would end', (tester) async {
    rig(tracks: const [Track(state: TrackState.playing, lengthFrames: 48000)]);
    given(
      _catalogue(const ['a', 'b', 'c'], openId: 'a'),
      selection: const FootSessionsSelection().opening('c', 0),
    );
    await pump(tester);
    await tester.pump();

    expect(under(PedalButton.track3, 'Opening…'), findsOneWidget);
    expect(under(PedalButton.track1, 'Open now'), findsOneWidget);
    expect(inReadout('Opening…'), findsOneWidget);
    expect(find.text('Opening a session stops playback'), findsNothing);
    // No switch offers a Hold while an Open is in flight.
    expect(find.text('Hold · Open'), findsNothing);
  });

  testWidgets('with every session hidden it says so and where to show them, '
      'and names the open one', (tester) async {
    given(
      const FootSessionCatalogue(
        sessions: [FootSessionEntry(id: 'x', name: 'Scratch', onFace: false)],
        openId: 'x',
      ),
    );
    await pump(tester);

    expect(
      find.text(
        'Every session is hidden from the pedal. Show them in Library.',
      ),
      findsOneWidget,
    );
    expect(
      find.text('No sessions yet. Save or start a new session.'),
      findsNothing,
    );
    expect(find.text('Open: Scratch'), findsOneWidget);
    expect(find.text('Empty'), findsNWidgets(4));
  });

  testWidgets('with no saved session it says how the first one comes to be', (
    tester,
  ) async {
    given(const FootSessionCatalogue());
    await pump(tester);

    expect(
      find.text('No sessions yet. Save or start a new session.'),
      findsOneWidget,
    );
    expect(find.text('Empty'), findsNWidgets(4));
    expect(find.text('Hold · Open'), findsNothing);
    expect(find.byKey(const Key('foot_sessions_hint')), findsNothing);
  });

  testWidgets('a contact on a drawn pedal is the switch', (tester) async {
    given(_catalogue(const ['a', 'b'], openId: 'a'));
    await pump(tester);

    final gesture = await tester.startGesture(
      tester.getCenter(pedal(PedalButton.track2)),
    );
    await tester.pump();
    verify(() => control.footSessionsPressed(PedalButton.track2, any()))
        .called(1);
    await gesture.up();
    await tester.pump();
    verify(() => control.footSessionsReleased(PedalButton.track2, any()))
        .called(1);
  });

  testWidgets('Exit on the top bar goes back as MODE does', (tester) async {
    given(_catalogue(const ['a']));
    await pump(tester);

    await tester.tap(find.byKey(const Key('foot_sessions_exit')));
    verify(() => control.activateFootSessionsPedal(PedalButton.mode)).called(1);
  });

  testWidgets("a pending Hold to open fills the drawn switch's LED bar from "
      'the left, in place of the bar under the face', (tester) async {
    whenListen(
      control,
      const Stream<ControlState>.empty(),
      initialState: ControlState(
        mode: InteractionMode.sessions,
        sessionCatalogue: _catalogue(const ['a', 'b'], openId: 'a'),
        footSessions: const FootSessionsSelection().previewing('b'),
        pendingHolds: const {PedalButton.track2},
      ),
    );
    await pump(tester);
    await tester.pump(const Duration(milliseconds: 400));

    final fill = find.byKey(const Key('foot_sessions_pedal_track2_led_fill'));
    expect(fill, findsOneWidget);
    // Halfway through the 800 ms hold.
    expect(
      tester.widget<FractionallySizedBox>(fill).widthFactor,
      moreOrLessEquals(0.5, epsilon: 0.05),
    );
    expect(
      find.byKey(const Key('foot_sessions_pedal_track1_led_fill')),
      findsNothing,
    );
    await tester.pump(const Duration(seconds: 1));
  });

  group('what an Open would end is the last line of the readout', () {
    const playing = Track(state: TrackState.playing, lengthFrames: 48000);
    const ends = Key('foot_sessions_preview_ends');

    Future<void> show(WidgetTester tester, String id) async {
      given(
        _catalogue(const ['a', 'b', 'c'], openId: 'a'),
        selection: const FootSessionsSelection().previewing(id),
      );
      await pump(tester);
      await tester.pump();
    }

    testWidgets('a playing track: stops playback', (tester) async {
      rig(tracks: const [playing]);
      await show(tester, 'b');

      expect(inReadout('Opening a session stops playback'), findsOneWidget);
      // On the pedals' caption baseline, where the hint was.
      expect(
        baselineOf(tester, find.byKey(ends)),
        moreOrLessEquals(
          baselineOf(tester, under(PedalButton.clear, 'Previous page')),
          epsilon: 1,
        ),
      );
    });

    testWidgets('a take: ends the take', (tester) async {
      rig(
        tracks: const [
          playing,
          Track(channel: 1, state: TrackState.recording),
        ],
      );
      await show(tester, 'b');

      expect(inReadout('Opening a session ends the take'), findsOneWidget);
      expect(find.text('Opening a session stops playback'), findsNothing);
    });

    testWidgets('a performance recording: ends the recording', (tester) async {
      rig(tracks: const [playing], recording: true);
      await show(tester, 'b');

      expect(inReadout('Opening a session ends the recording'), findsOneWidget);
    });

    testWidgets('nothing, with the rig stopped', (tester) async {
      rig(
        tracks: const [Track(state: TrackState.stopped, lengthFrames: 48000)],
      );
      await show(tester, 'b');

      expect(find.byKey(readout), findsOneWidget);
      expect(find.byKey(ends), findsNothing);
    });

    testWidgets('the open session reads Open now, whatever plays', (
      tester,
    ) async {
      rig(tracks: const [playing]);
      await show(tester, 'a');

      expect(inReadout('Open now'), findsOneWidget);
      expect(find.text('Opening a session stops playback'), findsNothing);
    });
  });

  testWidgets('the session whose Open failed says so under its switch, and '
      'in the readout while it is shown', (tester) async {
    rig(tracks: const [Track(state: TrackState.playing, lengthFrames: 48000)]);
    given(
      _catalogue(const ['a', 'b', 'c'], openId: 'a'),
      selection: const FootSessionsSelection()
          .opening('b', 0)
          .settled(failed: 'b'),
    );
    await pump(tester);
    await tester.pump();

    expect(under(PedalButton.track2, 'Could not open'), findsOneWidget);
    expect(inReadout('Could not open'), findsOneWidget);
    expect(find.text('Opening a session stops playback'), findsNothing);
    // It can be tried again.
    expect(under(PedalButton.track2, 'Hold · Open'), findsOneWidget);
  });

  testWidgets('with one page Clear and Bank are dimmed, and Undo keeps its '
      'Hold', (tester) async {
    given(_catalogue(const ['a', 'b'], openId: 'a'));
    await pump(tester);

    expect(find.text('Page 1 of 1'), findsOneWidget);
    expect(find.text('Previous page'), findsOneWidget);
    expect(find.text('Next page'), findsOneWidget);
    expect(find.text('1 / 1'), findsOneWidget);
    expect(find.text('Hold · New session'), findsOneWidget);
    // No switch has a bare Hold.
    expect(find.text('Hold'), findsNothing);
  });

  testWidgets('while an Open is in flight Undo offers no new session', (
    tester,
  ) async {
    given(
      _catalogue(const ['a', 'b'], openId: 'a'),
      selection: const FootSessionsSelection().opening('b', 0),
    );
    await pump(tester);

    expect(find.text('Hold · New session'), findsNothing);
  });

  testWidgets("a contact on Undo's drawn pedal is the switch's, so its "
      'press and its Hold are told apart as on the pedal', (tester) async {
    given(_catalogue(const ['a', 'b'], openId: 'a'));
    await pump(tester);

    await tester.tap(pedal(PedalButton.undo));
    await tester.pump();
    verify(() => control.footSessionsPressed(PedalButton.undo, any()))
        .called(1);
    verify(() => control.footSessionsReleased(PedalButton.undo, any()))
        .called(1);
  });

  testWidgets('a session with no recordings is not called empty', (
    tester,
  ) async {
    given(
      const FootSessionCatalogue(
        sessions: [
          FootSessionEntry(id: 'a', name: 'Verse setup'),
          FootSessionEntry(
            id: 'b',
            name: 'Chorus setup',
            tempoBpm: 84,
            looperMode: LooperMode.band,
          ),
        ],
      ),
    );
    await pump(tester);

    // Neither a mode nor a tempo in its manifest: what it holds.
    expect(under(PedalButton.track2, 'No recordings'), findsOneWidget);
    expect(under(PedalButton.track1, 'Band · 84 BPM'), findsOneWidget);
    expect(find.text('No tracks'), findsNothing);
  });

  testWidgets('a 40-character name stays under its own switch', (tester) async {
    const long = 'Friday night at the corner bar, late set';
    expect(long.length, 40);
    // It sorts first, so it is under switch 1.
    given(_catalogue(const [long, 'x', 'y', 'z'], openId: long));
    await pump(tester);

    expect(under(PedalButton.track1, long), findsOneWidget);
    expect(tester.takeException(), isNull);
    final own = tester.getRect(pedal(PedalButton.track1));
    final name = tester.getRect(under(PedalButton.track1, long));
    expect(name.left, greaterThanOrEqualTo(own.left));
    expect(name.right, lessThanOrEqualTo(own.right));
  });

  group('the readout of the session under the foot', () {
    String chainOf(List<TrackEffectType> types) => encodeFxChain(
      FxChainEnvelope(
        entries: [for (final type in types) BuiltInEffect(type: type)],
      ),
    );

    SessionPreviewTrack track(int channel) => SessionPreviewTrack(
      channel: channel,
      lengthFrames: 96000,
      baseLengthFrames: 96000,
      bars: 1,
      layers: 1,
      muted: false,
      fxCount: 0,
      liveLayerFile: 'layers/$channel.wav',
    );

    Future<void> show(WidgetTester tester) async {
      given(
        _catalogue(const ['a', 'b'], openId: 'a'),
        selection: const FootSessionsSelection().previewing('b'),
      );
      await pump(tester);
      await tester.pump();
    }

    String label(WidgetTester tester, int row) {
      final texts = tester.widgetList<AppText>(
        find.descendant(
          of: find.byKey(Key('foot_sessions_preview_row_$row')),
          matching: find.byType(AppText),
        ),
      );
      return texts.map((text) => text.data).join(' | ');
    }

    testWidgets('is a labelled list: loop mode, tempo, loop length, tracks '
        'and effects, in that order', (tester) async {
      previewIs(
        SessionPreview(
          summary: const SessionSummary(
            id: 'b',
            name: 'b',
            tempoBpm: 84,
            tsNum: 6,
            tsDen: 8,
          ),
          tracks: [track(0), track(3)],
          fxCount: 0,
          sampleRate: 48000,
          looperMode: LooperMode.song,
          loopBars: 8,
          inputChains: [
            chainOf(const [TrackEffectType.delay, TrackEffectType.reverb]),
            // The same effect on a second input is named once.
            chainOf(const [TrackEffectType.delay]),
          ],
          allTracksChain: chainOf(const [TrackEffectType.reverb]),
        ),
      );
      await show(tester);

      expect(
        tester
            .widget<AppText>(
              find.byKey(const Key('foot_sessions_preview_name')),
            )
            .data,
        'b',
      );
      expect(label(tester, 0), 'Loop mode | Song');
      expect(label(tester, 1), 'Tempo | 84 BPM · 6/8');
      expect(label(tester, 2), 'Loop length | 8 bars');
      expect(label(tester, 3), 'Tracks | 2 recorded');
      expect(label(tester, 4), 'Effects | Delay, Reverb');
      // The strip lights the tracks that hold a recording.
      final surface = tester.element(find.byKey(readout)).surface;
      for (var channel = 0; channel < 8; channel++) {
        final segment = tester.widget<ColoredBox>(
          find.descendant(
            of: find.byKey(Key('foot_sessions_preview_track_$channel')),
            matching: find.byType(ColoredBox),
          ),
        );
        expect(
          segment.color,
          const {0, 3}.contains(channel)
              ? surface.textPrimary
              : surface.controlStrong,
          reason: 'track $channel',
        );
      }
      verify(() => sessions.readPreview('b')).called(1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a setup with nothing recorded, no tempo, no loop length and '
        'no effects says each of those in words', (tester) async {
      previewIs(
        const SessionPreview(
          summary: SessionSummary(id: 'b', name: 'b'),
          tracks: [],
          fxCount: 0,
          sampleRate: 48000,
          looperMode: LooperMode.free,
        ),
      );
      await show(tester);

      expect(label(tester, 0), 'Loop mode | Free');
      expect(label(tester, 1), 'Tempo | No tempo');
      // No loop length set: the line is left out, not written as zero.
      expect(label(tester, 2), 'Tracks | None recorded');
      expect(label(tester, 3), 'Effects | None');
      expect(
        find.byKey(const Key('foot_sessions_preview_row_4')),
        findsNothing,
      );
    });

    testWidgets('a long list of effects says how many more there are', (
      tester,
    ) async {
      previewIs(
        SessionPreview(
          summary: const SessionSummary(id: 'b', name: 'b'),
          tracks: const [],
          fxCount: 0,
          sampleRate: 48000,
          outputChains: [
            chainOf(const [
              TrackEffectType.delay,
              TrackEffectType.reverb,
              TrackEffectType.chorus,
              TrackEffectType.tremolo,
              TrackEffectType.wah,
              TrackEffectType.drive,
            ]),
          ],
        ),
      );
      await show(tester);

      expect(inReadout('Delay, Reverb, Chorus, Tremolo, +2'), findsOneWidget);
    });

    testWidgets('a session that cannot be read says so and keeps its name', (
      tester,
    ) async {
      when(() => sessions.readPreview(any())).thenThrow(StateError('gone'));
      await show(tester);

      expect(inReadout('This session could not be read.'), findsOneWidget);
      expect(
        tester
            .widget<AppText>(
              find.byKey(const Key('foot_sessions_preview_name')),
            )
            .data,
        'b',
      );
      expect(
        find.byKey(const Key('foot_sessions_preview_row_0')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('the name of the session shown reads in the primary colour '
        'under its switch', (tester) async {
      await show(tester);

      final surface = tester.element(find.byKey(readout)).surface;
      final shown = tester.widget<AppText>(
        find.descendant(
          of: pedal(PedalButton.track2),
          matching: find.widgetWithText(AppText, '2 tracks'),
        ),
      );
      expect(shown.style?.color, surface.textPrimary);
    });
  });
}
