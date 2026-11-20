import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/control/control.dart';
import 'package:segno/control/model/foot_sessions.dart';
import 'package:segno/control/view/pedal_setup/pedal_hardware_face.dart';
import 'package:segno/looper/looper.dart';
import 'package:segno/looper/view/foot_sessions_view.dart';

import '../../helpers/helpers.dart';

class _Control extends MockCubit<ControlState> implements ControlCubit;

class _Tracks extends MockCubit<TracksState> implements TracksCubit;

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

  setUpAll(() => registerFallbackValue(Object()));

  setUp(() {
    control = _Control();
    tracks = _Tracks();
    whenListen(
      tracks,
      const Stream<TracksState>.empty(),
      initialState: const TracksState(names: []),
    );
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
