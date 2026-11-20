import 'package:bloc_test/bloc_test.dart';
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

import '../../helpers/helpers.dart';

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
          ),
      ],
      openId: openId,
    );

void main() {
  late _Control control;
  late _Tracks tracks;
  late _Looper looper;
  late _Recorder recorder;

  setUpAll(() => registerFallbackValue(Object()));

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
      MultiBlocProvider(
        providers: [
          BlocProvider<ControlCubit>.value(value: control),
          BlocProvider<TracksCubit>.value(value: tracks),
          BlocProvider<LooperBloc>.value(value: looper),
          BlocProvider<PerformanceRecorderCubit>.value(value: recorder),
        ],
        child: const Scaffold(body: FootSessionsView()),
      ),
    );
  }

  Finder pedal(PedalButton button) =>
      find.byKey(Key('foot_sessions_pedal_${button.name}'));

  Finder card(PedalButton button) =>
      find.byKey(Key('foot_sessions_card_${button.name}'));

  Finder onCard(PedalButton button, String text) =>
      find.descendant(of: card(button), matching: find.text(text));

  testWidgets('draws the ten pedals and the four sessions of the page, each '
      'card over the switch that opens it', (tester) async {
    given(_catalogue(const ['a', 'b', 'c', 'd', 'e', 'f'], openId: 'b'));
    await pump(tester);

    expect(find.byType(PedalHardwareFace), findsNWidgets(10));
    expect(find.text('Sessions'), findsOneWidget);
    expect(find.text('Page 1 of 2 · 6 sessions'), findsOneWidget);
    for (final (index, button) in _tracks.indexed) {
      final name = ['a', 'b', 'c', 'd'][index];
      expect(onCard(button, name), findsOneWidget, reason: name);
      // The card stands over its own switch, and above it.
      expect(
        tester.getCenter(card(button)).dx,
        moreOrLessEquals(tester.getCenter(pedal(button)).dx, epsilon: 1),
        reason: name,
      );
      expect(
        tester.getBottomLeft(card(button)).dy,
        lessThanOrEqualTo(tester.getTopLeft(pedal(button)).dy),
        reason: name,
      );
    }
    expect(onCard(PedalButton.track1, '1 track · 84 BPM'), findsOneWidget);
    // A session with no tempo says its tracks alone.
    expect(onCard(PedalButton.track2, '2 tracks'), findsOneWidget);
    expect(onCard(PedalButton.track2, 'Open now'), findsOneWidget);
    expect(find.text('Open now'), findsOneWidget);
    expect(find.text('Open'), findsNWidgets(4));
    expect(find.text('Save'), findsOneWidget);
    expect(find.text('New loop'), findsOneWidget);
    expect(find.text('Next page'), findsOneWidget);
    expect(find.text('1 / 2'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the last page says Empty over the switches with no session', (
    tester,
  ) async {
    given(
      _catalogue(const ['a', 'b', 'c', 'd', 'e', 'f']),
      selection: const FootSessionsSelection(page: 1),
    );
    await pump(tester);

    expect(find.text('Page 2 of 2 · 6 sessions'), findsOneWidget);
    expect(onCard(PedalButton.track1, 'e'), findsOneWidget);
    expect(onCard(PedalButton.track2, 'f'), findsOneWidget);
    expect(onCard(PedalButton.track3, 'Empty'), findsOneWidget);
    expect(onCard(PedalButton.track4, 'Empty'), findsOneWidget);
    expect(find.text('Open'), findsNWidgets(2));
  });

  testWidgets('the session being opened says so on its card', (tester) async {
    given(
      _catalogue(const ['a', 'b', 'c'], openId: 'a'),
      selection: const FootSessionsSelection().opening('c', 0),
    );
    await pump(tester);

    expect(onCard(PedalButton.track3, 'Opening…'), findsOneWidget);
    expect(onCard(PedalButton.track1, 'Open now'), findsOneWidget);
  });

  testWidgets('with no saved session it says how the first one comes to be', (
    tester,
  ) async {
    given(const FootSessionCatalogue());
    await pump(tester);

    expect(
      find.text('No sessions yet. Save or start a new loop.'),
      findsOneWidget,
    );
    expect(find.text('Empty'), findsNWidgets(4));
    expect(find.text('Open'), findsNothing);
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

  group('what an Open would end is said on every card it applies to', () {
    const playing = Track(state: TrackState.playing, lengthFrames: 48000);

    testWidgets('a playing track: Stops playback, but not on the open '
        'session', (tester) async {
      rig(tracks: const [playing]);
      given(_catalogue(const ['a', 'b', 'c'], openId: 'a'));
      await pump(tester);

      expect(onCard(PedalButton.track2, 'Stops playback'), findsOneWidget);
      expect(onCard(PedalButton.track3, 'Stops playback'), findsOneWidget);
      expect(onCard(PedalButton.track1, 'Open now'), findsOneWidget);
      expect(find.text('Stops playback'), findsNWidgets(2));
    });

    testWidgets('a take: Ends the take', (tester) async {
      rig(
        tracks: const [
          playing,
          Track(channel: 1, state: TrackState.recording),
        ],
      );
      given(_catalogue(const ['a', 'b'], openId: 'a'));
      await pump(tester);

      expect(onCard(PedalButton.track2, 'Ends the take'), findsOneWidget);
      expect(find.text('Stops playback'), findsNothing);
    });

    testWidgets('a performance recording: Ends the recording', (tester) async {
      rig(tracks: const [playing], recording: true);
      given(_catalogue(const ['a', 'b'], openId: 'a'));
      await pump(tester);

      expect(onCard(PedalButton.track2, 'Ends the recording'), findsOneWidget);
    });

    testWidgets('nothing, with the rig stopped', (tester) async {
      rig(
        tracks: const [Track(state: TrackState.stopped, lengthFrames: 48000)],
      );
      given(_catalogue(const ['a', 'b'], openId: 'a'));
      await pump(tester);

      expect(find.text('Stops playback'), findsNothing);
      expect(find.text('Ends the take'), findsNothing);
      expect(find.text('Ends the recording'), findsNothing);
    });
  });

  testWidgets('the session whose Open failed says so on its card, over what '
      'an Open would end', (tester) async {
    rig(tracks: const [Track(state: TrackState.playing, lengthFrames: 48000)]);
    given(
      _catalogue(const ['a', 'b', 'c'], openId: 'a'),
      selection: const FootSessionsSelection().settled(failed: 'b'),
    );
    await pump(tester);

    expect(onCard(PedalButton.track2, 'Could not open'), findsOneWidget);
    expect(onCard(PedalButton.track2, 'Stops playback'), findsNothing);
    expect(onCard(PedalButton.track3, 'Stops playback'), findsOneWidget);
  });

  testWidgets('names the folder in view, and Bank says its Hold shows the '
      'next one', (tester) async {
    given(
      const FootSessionCatalogue(
        sessions: [
          FootSessionEntry(id: 'a', name: 'a', folder: 'Friday set'),
          FootSessionEntry(id: 'b', name: 'b'),
        ],
        openId: 'a',
      ),
      selection: const FootSessionsSelection(folder: 'Friday set'),
    );
    await pump(tester);

    expect(find.byKey(const Key('foot_sessions_folder')), findsOneWidget);
    expect(find.text('Friday set'), findsOneWidget);
    expect(find.text('Page 1 of 1 · 1 session'), findsOneWidget);
    expect(find.text('Hold · Folder'), findsOneWidget);
  });

  testWidgets('the sessions outside a folder read Unfiled, and with one '
      'folder Bank has no Hold', (tester) async {
    given(_catalogue(const ['a', 'b'], openId: 'a'));
    await pump(tester);

    expect(find.text('Unfiled'), findsOneWidget);
    expect(find.text('Hold · Folder'), findsNothing);
  });

  testWidgets('a tap on a card is its switch; an empty position takes none', (
    tester,
  ) async {
    given(_catalogue(const ['a', 'b'], openId: 'a'));
    await pump(tester);

    await tester.tap(card(PedalButton.track2));
    verify(() => control.activateFootSessionsPedal(PedalButton.track2))
        .called(1);
    await tester.tap(card(PedalButton.track3), warnIfMissed: false);
    verifyNever(() => control.activateFootSessionsPedal(PedalButton.track3));
  });

  testWidgets('a 40-character name stays inside its card', (tester) async {
    const long = 'Friday night at the corner bar, late set';
    expect(long.length, 40);
    // It sorts first, so it is over switch 1.
    given(_catalogue(const [long, 'x', 'y', 'z'], openId: long));
    await pump(tester);

    expect(onCard(PedalButton.track1, long), findsOneWidget);
    expect(tester.takeException(), isNull);
    final cardRect = tester.getRect(card(PedalButton.track1));
    final nameRect = tester.getRect(onCard(PedalButton.track1, long));
    expect(cardRect.contains(nameRect.topLeft), isTrue);
    expect(cardRect.contains(nameRect.bottomRight), isTrue);
  });
}
