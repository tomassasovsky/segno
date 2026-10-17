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
import 'package:segno/theme/theme.dart';

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

/// [_rig] with its tracks replaced.
LooperState _withTracks(List<Track> tracks) => LooperState(
  transport: _rig.transport,
  status: _rig.status,
  tracks: tracks,
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

  Finder inPedal(PedalButton button, String text) =>
      find.descendant(of: pedal(button), matching: find.text(text));

  String? note(WidgetTester tester) => tester
      .widget<AppText>(find.byKey(const Key('foot_length_panel_note')))
      .data;

  Semantics pedalSemantics(WidgetTester tester, PedalButton button) => find
      .ancestor(of: pedal(button), matching: find.byType(Semantics))
      .evaluate()
      .map((element) => element.widget as Semantics)
      .firstWhere((semantics) => semantics.properties.button ?? false);

  testWidgets('Multiply (pen 16 01): Clear doubles, Rec/Play and Undo keep '
      'their Tracks roles, the panel reads the selected track', (
    tester,
  ) async {
    given(const ControlState(mode: InteractionMode.multiply));
    await pump(tester);
    expect(find.byType(PedalHardwareFace), findsNWidgets(10));
    expect(find.byKey(const Key('foot_length_title')), findsOneWidget);
    expect(find.text('Multiply'), findsOneWidget);
    expect(inPedal(PedalButton.clear, 'Double length'), findsOneWidget);
    expect(inPedal(PedalButton.clear, 'Repeat to 4 bars'), findsOneWidget);
    expect(inPedal(PedalButton.recPlay, 'Record / Play'), findsOneWidget);
    expect(inPedal(PedalButton.recPlay, 'TRACK 1'), findsOneWidget);
    expect(inPedal(PedalButton.undo, 'Undo'), findsOneWidget);
    expect(inPedal(PedalButton.undo, 'Nothing to undo'), findsOneWidget);
    expect(pedalSemantics(tester, PedalButton.undo).properties.enabled, false);
    expect(inPedal(PedalButton.stop, 'All tracks'), findsOneWidget);
    expect(inPedal(PedalButton.bank, 'Bank A'), findsOneWidget);
    expect(inPedal(PedalButton.bank, 'Tracks 1–4'), findsOneWidget);
    expect(inPedal(PedalButton.mode, 'Exit'), findsOneWidget);
    expect(pedalSemantics(tester, PedalButton.mode).properties.selected, true);
    for (final (button, word) in [
      (PedalButton.track1, '2 bars'),
      (PedalButton.track2, '4 bars'),
      (PedalButton.track3, '1 bar'),
      (PedalButton.track4, 'Empty'),
    ]) {
      expect(inPedal(button, word), findsOneWidget, reason: button.name);
    }
    expect(
      pedalSemantics(tester, PedalButton.track1).properties.selected,
      isTrue,
    );
    expect(
      pedalSemantics(tester, PedalButton.track2).properties.selected,
      isFalse,
    );
    // The panel: the selected track, its length, one cell per bar, and
    // the outcome line.
    final panel = find.byKey(const Key('foot_length_panel'));
    expect(
      find.descendant(of: panel, matching: find.text('TRACK 1')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: panel, matching: find.text('2 bars')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('foot_length_cell_1')), findsOneWidget);
    expect(find.byKey(const Key('foot_length_cell_2')), findsNothing);
    expect(note(tester), 'Speed and pitch unchanged');
  });

  testWidgets('Multiply (pen 16 02): after a Double the outcome reads '
      '"Repeated to", Undo names the length edit', (tester) async {
    whenListen(
      looper,
      const Stream<LooperState>.empty(),
      initialState: _withTracks(
        [
          const Track(
            state: TrackState.playing,
            lengthFrames: 96000,
            multiple: 2,
            undoDepth: 1,
          ),
          ..._rig.tracks.skip(1),
        ],
      ),
    );
    given(
      const ControlState(
        mode: InteractionMode.multiply,
        footLengthOutcome: FootLengthOutcome(
          channel: 0,
          edit: LengthEdit.doubled,
          fromFrames: 48000,
          toFrames: 96000,
          toUndoDepth: 1,
        ),
      ),
    );
    await pump(tester);
    expect(note(tester), 'Repeated to 4 bars');
    expect(inPedal(PedalButton.clear, 'Repeat to 8 bars'), findsOneWidget);
    expect(inPedal(PedalButton.undo, 'Length edit'), findsOneWidget);
    expect(pedalSemantics(tester, PedalButton.undo).properties.enabled, true);
    expect(find.byKey(const Key('foot_length_cell_3')), findsOneWidget);
  });

  testWidgets('an overdub on top of a Double, or Undo past it, ends the '
      'outcome and the "Length edit" caption', (tester) async {
    const doubled = FootLengthOutcome(
      channel: 0,
      edit: LengthEdit.doubled,
      fromFrames: 48000,
      toFrames: 96000,
      toUndoDepth: 1,
    );
    whenListen(
      looper,
      const Stream<LooperState>.empty(),
      initialState: _withTracks([
        const Track(
          state: TrackState.playing,
          lengthFrames: 96000,
          multiple: 2,
          undoDepth: 2, // the overdub's layer
        ),
        ..._rig.tracks.skip(1),
      ]),
    );
    given(
      const ControlState(
        mode: InteractionMode.multiply,
        footLengthOutcome: doubled,
      ),
    );
    await pump(tester);
    expect(note(tester), 'Speed and pitch unchanged');
    expect(inPedal(PedalButton.undo, 'Last change'), findsOneWidget);
  });

  testWidgets('Double twice then Undo twice never reads "Repeated to 1 bar"', (
    tester,
  ) async {
    whenListen(
      looper,
      const Stream<LooperState>.empty(),
      initialState: _withTracks([
        const Track(
          state: TrackState.playing,
          lengthFrames: 24000,
          redoDepth: 2,
        ),
        ..._rig.tracks.skip(1),
      ]),
    );
    given(
      const ControlState(
        mode: InteractionMode.multiply,
        footLengthOutcome: FootLengthOutcome(
          channel: 0,
          edit: LengthEdit.doubled,
          fromFrames: 48000,
          fromUndoDepth: 1,
          toFrames: 96000,
          toUndoDepth: 2,
        ),
      ),
    );
    await pump(tester);
    expect(note(tester), 'Speed and pitch unchanged');
    expect(inPedal(PedalButton.undo, 'Nothing to undo'), findsOneWidget);
    // Redo is still a hold away, so the pedal stays live.
    expect(pedalSemantics(tester, PedalButton.undo).properties.enabled, true);
  });

  testWidgets('Divide (pen 16 03-05): halves on Undo and Clear, captioned in '
      'bars or beats; Hold · Undo once there is something to undo', (
    tester,
  ) async {
    given(const ControlState(mode: InteractionMode.divide));
    await pump(tester);
    expect(find.text('Divide'), findsOneWidget);
    expect(inPedal(PedalButton.undo, 'First half'), findsOneWidget);
    expect(inPedal(PedalButton.undo, 'Bar 1'), findsOneWidget);
    expect(inPedal(PedalButton.undo, 'Hold · Undo'), findsNothing);
    expect(inPedal(PedalButton.clear, 'Last half'), findsOneWidget);
    expect(inPedal(PedalButton.clear, 'Bar 2'), findsOneWidget);
    expect(inPedal(PedalButton.recPlay, 'Record / Play'), findsOneWidget);
    final panel = find.byKey(const Key('foot_length_panel'));
    expect(
      find.descendant(of: panel, matching: find.text('First half')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: panel, matching: find.text('Last half')),
      findsOneWidget,
    );
    expect(note(tester), 'Speed and pitch unchanged');
    // Accessible hold: Undo.
    final semantics = pedalSemantics(tester, PedalButton.undo);
    semantics.properties.onLongPress!();
    verify(() => control.holdFootLengthPedal(PedalButton.undo)).called(1);
  });

  testWidgets('Divide (pen 16 04): the first bar kept reads in beats', (
    tester,
  ) async {
    whenListen(
      looper,
      const Stream<LooperState>.empty(),
      initialState: _withTracks(
        [
          const Track(
            state: TrackState.playing,
            lengthFrames: 24000,
            undoDepth: 1,
          ),
          ..._rig.tracks.skip(1),
        ],
      ),
    );
    given(
      const ControlState(
        mode: InteractionMode.divide,
        footLengthOutcome: FootLengthOutcome(
          channel: 0,
          edit: LengthEdit.firstHalf,
          fromFrames: 48000,
          toFrames: 24000,
          toUndoDepth: 1,
        ),
      ),
    );
    await pump(tester);
    expect(note(tester), 'First 1 bar kept');
    expect(inPedal(PedalButton.undo, 'Beats 1–2'), findsOneWidget);
    expect(inPedal(PedalButton.undo, 'Hold · Undo'), findsOneWidget);
    expect(inPedal(PedalButton.clear, 'Beats 3–4'), findsOneWidget);
  });

  testWidgets('Divide (pen 16 06): pedals and panel follow the shared bank', (
    tester,
  ) async {
    given(
      const ControlState(
        mode: InteractionMode.divide,
        activeBank: 1,
        cursor: 4,
      ),
    );
    await pump(tester);
    expect(inPedal(PedalButton.bank, 'Bank B'), findsOneWidget);
    expect(inPedal(PedalButton.bank, 'Tracks 5–8'), findsOneWidget);
    expect(
      pedalSemantics(tester, PedalButton.bank).properties.selected,
      isTrue,
    );
    expect(inPedal(PedalButton.track1, 'TRACK 5'), findsOneWidget);
    expect(inPedal(PedalButton.track1, '6 beats'), findsOneWidget);
    expect(
      pedalSemantics(tester, PedalButton.track1).properties.selected,
      isTrue,
    );
    // Six beats: halves of three beats.
    expect(inPedal(PedalButton.undo, 'Beats 1–3'), findsOneWidget);
    expect(inPedal(PedalButton.clear, 'Beats 4–6'), findsOneWidget);
  });

  testWidgets('Divide (pen 16 07): with no recording selected the edit '
      'pedals read "Select a track" and admit no contact', (tester) async {
    whenListen(
      looper,
      const Stream<LooperState>.empty(),
      initialState: _withTracks(
        [for (var i = 0; i < 4; i++) Track(channel: i)],
      ),
    );
    given(const ControlState(mode: InteractionMode.divide));
    await pump(tester);
    expect(find.byKey(const Key('foot_length_panel_empty')), findsOneWidget);
    expect(find.text('Loop length'), findsOneWidget);
    expect(note(tester), 'No recorded audio in this bank');
    for (final button in [
      PedalButton.track1,
      PedalButton.undo,
      PedalButton.clear,
    ]) {
      expect(pedalSemantics(tester, button).properties.enabled, isFalse);
      await tester.tap(pedal(button), warnIfMissed: false);
      await tester.pump();
      verifyNever(() => control.footLengthPressed(button, any()));
    }
    expect(inPedal(PedalButton.undo, 'Select a track'), findsOneWidget);
    expect(inPedal(PedalButton.clear, 'Select a track'), findsOneWidget);
    for (final button in [
      PedalButton.recPlay,
      PedalButton.stop,
      PedalButton.bank,
      PedalButton.mode,
    ]) {
      expect(pedalSemantics(tester, button).properties.enabled, isTrue);
    }
  });

  testWidgets('an empty track selected while the bank has recordings asks '
      'for a track', (tester) async {
    given(const ControlState(mode: InteractionMode.multiply, cursor: 3));
    await pump(tester);
    expect(note(tester), 'Select a track');
    expect(inPedal(PedalButton.clear, 'Select a track'), findsOneWidget);
  });

  testWidgets('Divide (pen 16 08): a recording track keeps its length and '
      'asks to finish recording, still taking the stomp', (tester) async {
    whenListen(
      looper,
      const Stream<LooperState>.empty(),
      initialState: _withTracks(
        [
          const Track(state: TrackState.overdubbing, lengthFrames: 48000),
          ..._rig.tracks.skip(1),
        ],
      ),
    );
    given(const ControlState(mode: InteractionMode.divide));
    await pump(tester);
    expect(note(tester), 'Finish recording to change length');
    expect(inPedal(PedalButton.undo, 'Finish recording'), findsOneWidget);
    expect(inPedal(PedalButton.clear, 'Finish recording'), findsOneWidget);
    expect(inPedal(PedalButton.track1, '2 bars'), findsOneWidget);
    // Numbered bars while recording, not the halves.
    final panel = find.byKey(const Key('foot_length_panel'));
    expect(
      find.descendant(of: panel, matching: find.text('First half')),
      findsNothing,
    );
    await tester.tap(pedal(PedalButton.clear));
    await tester.pump();
    verify(
      () => control.footLengthPressed(PedalButton.clear, any()),
    ).called(1);
  });

  testWidgets('a contact is admitted, then completed by its own token', (
    tester,
  ) async {
    given(const ControlState(mode: InteractionMode.divide));
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
    given(const ControlState(mode: InteractionMode.multiply));
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
      'That length does not fit the other loops, or would leave half a beat.',
    );
  });
}
