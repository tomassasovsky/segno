import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/control/control.dart';
import 'package:segno/control/view/pedal_setup/pedal_hardware_face.dart';
import 'package:segno/looper/looper.dart';
import 'package:segno/looper/view/foot_reverse_view.dart';

import '../../helpers/helpers.dart';

class _Control extends MockCubit<ControlState> implements ControlCubit {}

class _Looper extends MockBloc<LooperEvent, LooperState>
    implements LooperBloc {}

class _Tracks extends MockCubit<TracksState> implements TracksCubit {}

void main() {
  late _Control control;
  late _Looper looper;
  late _Tracks tracks;
  late Map<PedalButton, Object> contacts;

  setUpAll(() => registerFallbackValue(Object()));

  setUp(() {
    control = _Control();
    looper = _Looper();
    tracks = _Tracks();
    contacts = {};
    for (final button in PedalButton.values) {
      when(() => control.footReversePressed(button, any())).thenAnswer((call) {
        contacts[button] = call.positionalArguments[1] as Object;
      });
    }
    whenListen(
      looper,
      const Stream<LooperState>.empty(),
      initialState: const LooperState(
        tracks: [
          Track(state: TrackState.playing, lengthFrames: 48000),
          Track(
            channel: 1,
            state: TrackState.playing,
            lengthFrames: 48000,
            reversed: true,
          ),
          Track(channel: 2, state: TrackState.recording),
          Track(channel: 3),
          Track(
            channel: 4,
            state: TrackState.stopped,
            lengthFrames: 48000,
            reversed: true,
          ),
        ],
      ),
    );
    whenListen(
      tracks,
      const Stream<TracksState>.empty(),
      initialState: const TracksState(names: []),
    );
  });

  void given(ControlState state) => whenListen(
    control,
    const Stream<ControlState>.empty(),
    initialState: state,
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
          BlocProvider<LooperBloc>.value(value: looper),
          BlocProvider<TracksCubit>.value(value: tracks),
        ],
        child: const Scaffold(body: FootReverseView()),
      ),
    );
  }

  Finder pedal(PedalButton button) =>
      find.byKey(Key('foot_reverse_pedal_${button.name}'));

  Finder overview(int channel) =>
      find.byKey(Key('foot_reverse_overview_$channel'));

  Semantics pedalSemantics(WidgetTester tester, PedalButton button) => find
      .ancestor(of: pedal(button), matching: find.byType(Semantics))
      .evaluate()
      .map((element) => element.widget as Semantics)
      .firstWhere((semantics) => semantics.properties.button ?? false);

  testWidgets('the overview and pedals read every direction', (tester) async {
    given(const ControlState(mode: InteractionMode.reverse));
    await pump(tester);
    expect(find.byType(PedalHardwareFace), findsNWidgets(10));
    expect(find.text('Playback direction'), findsOneWidget);
    for (final (channel, word) in [
      (0, 'Forward'),
      (1, 'Reverse'),
      (2, 'Empty'),
      (3, 'Empty'),
      (4, 'Reverse'),
      (7, 'Empty'),
    ]) {
      expect(
        find.descendant(of: overview(channel), matching: find.text(word)),
        findsOneWidget,
        reason: 'track ${channel + 1}',
      );
    }
    expect(
      find.descendant(
        of: overview(1),
        matching: find.byIcon(Icons.chevron_left),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: overview(0),
        matching: find.byIcon(Icons.chevron_right),
      ),
      findsOneWidget,
    );
    expect(find.text('Switch bank'), findsOneWidget);
    // The selection bar mirrors the LED: lit on the reversed track only.
    expect(
      pedalSemantics(tester, PedalButton.track2).properties.selected,
      isTrue,
    );
    expect(
      pedalSemantics(tester, PedalButton.track1).properties.selected,
      isFalse,
    );
  });

  testWidgets('Undo, Clear and unavailable tracks admit no contact', (
    tester,
  ) async {
    given(const ControlState(mode: InteractionMode.reverse));
    await pump(tester);
    for (final button in [
      PedalButton.undo,
      PedalButton.clear,
      PedalButton.track3,
      PedalButton.track4,
    ]) {
      expect(pedalSemantics(tester, button).properties.enabled, isFalse);
      await tester.tap(pedal(button), warnIfMissed: false);
      await tester.pump();
      verifyNever(() => control.footReversePressed(button, any()));
    }
  });

  testWidgets('a busy recorded track reads its real direction, dimmed, and '
      'still takes the stomp', (tester) async {
    whenListen(
      looper,
      const Stream<LooperState>.empty(),
      initialState: const LooperState(
        tracks: [
          Track(state: TrackState.overdubbing, lengthFrames: 48000),
          Track(
            channel: 1,
            state: TrackState.playing,
            lengthFrames: 48000,
            reversed: true,
            pending: true,
          ),
          Track(channel: 2, state: TrackState.playing, lengthFrames: 48000),
        ],
      ),
    );
    given(const ControlState(mode: InteractionMode.reverse));
    await pump(tester);
    double opacityOf(int channel) =>
        tester.widget<Opacity>(overview(channel)).opacity;
    for (final (channel, word, chevron) in [
      (0, 'Forward', Icons.chevron_right),
      (1, 'Reverse', Icons.chevron_left),
    ]) {
      expect(
        find.descendant(of: overview(channel), matching: find.text(word)),
        findsOneWidget,
        reason: 'track ${channel + 1}',
      );
      expect(
        find.descendant(of: overview(channel), matching: find.byIcon(chevron)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: overview(channel), matching: find.text('Empty')),
        findsNothing,
      );
      expect(opacityOf(channel), lessThan(1), reason: 'track ${channel + 1}');
      expect(
        find.descendant(
          of: pedal(PedalButton.values[PedalButton.track1.index + channel]),
          matching: find.text(word),
        ),
        findsOneWidget,
      );
    }
    expect(opacityOf(2), 1);
    // The reversed busy track keeps its lit bar, like its LED.
    expect(
      pedalSemantics(tester, PedalButton.track2).properties.selected,
      isTrue,
    );
    for (final button in [PedalButton.track1, PedalButton.track2]) {
      expect(pedalSemantics(tester, button).properties.enabled, isTrue);
      await tester.tap(pedal(button));
      await tester.pump();
      verify(() => control.footReversePressed(button, any())).called(1);
    }
  });

  testWidgets('pedals follow the shared bank', (tester) async {
    given(const ControlState(mode: InteractionMode.reverse, activeBank: 1));
    await pump(tester);
    expect(find.text('Bank B'), findsOneWidget);
    expect(
      pedalSemantics(tester, PedalButton.bank).properties.selected,
      isTrue,
    );
    expect(
      find.descendant(
        of: pedal(PedalButton.track1),
        matching: find.text('TRACK 5'),
      ),
      findsOneWidget,
    );
    expect(
      pedalSemantics(tester, PedalButton.track1).properties.selected,
      isTrue,
    );
  });

  testWidgets('a contact is admitted, then completed by its own token', (
    tester,
  ) async {
    given(const ControlState(mode: InteractionMode.reverse));
    await pump(tester);
    final gesture = await tester.startGesture(
      tester.getCenter(pedal(PedalButton.track2)),
    );
    await tester.pump();
    verify(
      () => control.footReversePressed(PedalButton.track2, any()),
    ).called(1);
    await gesture.up();
    await tester.pump();
    verify(
      () => control.footReverseReleased(
        PedalButton.track2,
        contacts[PedalButton.track2]!,
      ),
    ).called(1);
  });

  testWidgets('the header Exit returns to Tracks', (tester) async {
    given(const ControlState(mode: InteractionMode.reverse));
    await pump(tester);
    await tester.tap(find.byKey(const Key('foot_reverse_exit')));
    verify(() => control.setMode(InteractionMode.record)).called(1);
  });
}
