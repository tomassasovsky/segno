import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/control/control.dart';
import 'package:segno/control/model/foot_length.dart';
import 'package:segno/control/view/pedal_setup/pedal_hardware_face.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/looper.dart';
import 'package:segno/looper/view/foot_length_view.dart';

import '../../helpers/helpers.dart';

class _Control extends MockCubit<ControlState> implements ControlCubit {}

class _Looper extends MockBloc<LooperEvent, LooperState>
    implements LooperBloc {}

class _Tracks extends MockCubit<TracksState> implements TracksCubit {}

/// Two bars over 48000 frames: 24000 frames a bar.
const _rig = LooperState(
  transport: TransportState(
    isRunning: true,
    masterLengthFrames: 48000,
    loopBars: 2,
  ),
  status: EngineStatus(sampleRate: 48000),
  tracks: [
    Track(state: TrackState.playing, lengthFrames: 48000),
    Track(
      channel: 1,
      state: TrackState.playing,
      lengthFrames: 96000,
      multiple: 2,
    ),
    Track(
      channel: 2,
      state: TrackState.playing,
      lengthFrames: 24000,
      syncDivisor: 2,
    ),
    Track(channel: 3),
    Track(channel: 4, state: TrackState.stopped, lengthFrames: 36000),
    Track(channel: 5, state: TrackState.stopped, lengthFrames: 37000),
  ],
);

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
      when(() => control.footLengthPressed(button, any())).thenAnswer((call) {
        contacts[button] = call.positionalArguments[1] as Object;
      });
    }
    whenListen(
      looper,
      const Stream<LooperState>.empty(),
      initialState: _rig,
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
        child: const Scaffold(body: FootLengthView()),
      ),
    );
  }

  Finder pedal(PedalButton button) =>
      find.byKey(Key('foot_length_pedal_${button.name}'));

  Finder overview(int channel) =>
      find.byKey(Key('foot_length_overview_$channel'));

  Semantics pedalSemantics(WidgetTester tester, PedalButton button) => find
      .ancestor(of: pedal(button), matching: find.byType(Semantics))
      .evaluate()
      .map((element) => element.widget as Semantics)
      .firstWhere((semantics) => semantics.properties.button ?? false);

  testWidgets('the overview reads every length; the edit pedals name the '
      'selected track', (tester) async {
    given(const ControlState(mode: InteractionMode.length, cursor: 1));
    await pump(tester);
    expect(find.byType(PedalHardwareFace), findsNWidgets(10));
    expect(find.text('Loop length'), findsOneWidget);
    for (final (channel, word) in [
      (0, '2 bars'),
      (1, '4 bars · ×2'),
      (2, '1 bar · 1/2'),
      (3, 'Empty'),
      // One and a half bars of 4/4: 6 whole beats (#1168).
      (4, '6 beats'),
      (5, '0.8 s'),
      (7, 'Empty'),
    ]) {
      expect(
        find.descendant(of: overview(channel), matching: find.text(word)),
        findsOneWidget,
        reason: 'track ${channel + 1}',
      );
    }
    for (final (button, caption) in [
      (PedalButton.recPlay, 'Double'),
      (PedalButton.undo, 'First half'),
      (PedalButton.clear, 'Last half'),
    ]) {
      expect(
        find.descendant(of: pedal(button), matching: find.text(caption)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: pedal(button), matching: find.text('TRACK 2')),
        findsOneWidget,
      );
      expect(pedalSemantics(tester, button).properties.enabled, isTrue);
    }
    // The selection bar mirrors the LED: lit on the selected track only.
    expect(
      pedalSemantics(tester, PedalButton.track2).properties.selected,
      isTrue,
    );
    expect(
      pedalSemantics(tester, PedalButton.track1).properties.selected,
      isFalse,
    );
    final bar = tester.widget<Container>(
      find.byKey(const Key('foot_length_overview_bar_1')),
    );
    expect(bar.color, isNot(Colors.transparent));
  });

  testWidgets('an empty track is dimmed and silent: its pedal and, while it '
      'is selected, the edit pedals admit no contact', (tester) async {
    given(const ControlState(mode: InteractionMode.length, cursor: 3));
    await pump(tester);
    for (final button in [
      PedalButton.track4,
      PedalButton.recPlay,
      PedalButton.undo,
      PedalButton.clear,
    ]) {
      expect(pedalSemantics(tester, button).properties.enabled, isFalse);
      await tester.tap(pedal(button), warnIfMissed: false);
      await tester.pump();
      verifyNever(() => control.footLengthPressed(button, any()));
    }
    expect(
      find.descendant(
        of: pedal(PedalButton.recPlay),
        matching: find.text('Empty'),
      ),
      findsOneWidget,
    );
    // Stop, Bank and Exit still work.
    for (final button in [
      PedalButton.stop,
      PedalButton.bank,
      PedalButton.mode,
    ]) {
      expect(pedalSemantics(tester, button).properties.enabled, isTrue);
    }
  });

  testWidgets('a busy recorded track keeps its length, dimmed, and still '
      'takes the stomp', (tester) async {
    whenListen(
      looper,
      const Stream<LooperState>.empty(),
      initialState: const LooperState(
        status: EngineStatus(sampleRate: 48000),
        tracks: [
          Track(state: TrackState.overdubbing, lengthFrames: 48000),
          Track(channel: 1, state: TrackState.playing, lengthFrames: 48000),
        ],
      ),
    );
    given(const ControlState(mode: InteractionMode.length));
    await pump(tester);
    double opacityOf(int channel) =>
        tester.widget<Opacity>(overview(channel)).opacity;
    expect(opacityOf(0), lessThan(1));
    expect(opacityOf(1), 1);
    expect(
      find.descendant(of: overview(0), matching: find.text('Empty')),
      findsNothing,
    );
    expect(
      pedalSemantics(tester, PedalButton.recPlay).properties.enabled,
      isTrue,
    );
    await tester.tap(pedal(PedalButton.recPlay));
    await tester.pump();
    verify(
      () => control.footLengthPressed(PedalButton.recPlay, any()),
    ).called(1);
  });

  testWidgets('pedals follow the shared bank', (tester) async {
    given(
      const ControlState(
        mode: InteractionMode.length,
        activeBank: 1,
        cursor: 4,
      ),
    );
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
    given(const ControlState(mode: InteractionMode.length));
    await pump(tester);
    final gesture = await tester.startGesture(
      tester.getCenter(pedal(PedalButton.undo)),
    );
    await tester.pump();
    verify(() => control.footLengthPressed(PedalButton.undo, any())).called(1);
    await gesture.up();
    await tester.pump();
    verify(
      () => control.footLengthReleased(
        PedalButton.undo,
        contacts[PedalButton.undo]!,
      ),
    ).called(1);
  });

  testWidgets('the header Exit returns to Tracks', (tester) async {
    given(const ControlState(mode: InteractionMode.length));
    await pump(tester);
    await tester.tap(find.byKey(const Key('foot_length_exit')));
    verify(() => control.setMode(InteractionMode.record)).called(1);
  });

  testWidgets('every refusal has its own notice text', (tester) async {
    late AppLocalizations l10n;
    await tester.pumpApp(
      Builder(
        builder: (context) {
          l10n = context.l10n;
          return const SizedBox();
        },
      ),
    );
    final texts = {
      for (final refusal in FootLengthRefusal.values)
        footLengthRefusalText(l10n, refusal),
    };
    expect(texts, hasLength(FootLengthRefusal.values.length));
    expect(
      footLengthRefusalText(l10n, FootLengthRefusal.incompatible),
      l10n.footLengthIncompatible,
    );
  });
}
