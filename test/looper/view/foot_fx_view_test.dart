import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/control/control.dart';
import 'package:segno/control/model/foot_fx.dart';
import 'package:segno/control/view/pedal_setup/pedal_hardware_face.dart';
import 'package:segno/looper/looper.dart';
import 'package:segno/looper/view/foot_fx_view.dart';
import 'package:segno/looper/view/performance_pedal.dart';

import '../../helpers/helpers.dart';

class _Control extends MockCubit<ControlState> implements ControlCubit {}

class _Looper extends MockBloc<LooperEvent, LooperState>
    implements LooperBloc {}

class _Tracks extends MockCubit<TracksState> implements TracksCubit {}

class _Repository extends Mock implements LooperRepository {}

/// The FX face (pen 10/03 `noDGu`, `ri60q`; #1229, #884, #873).
void main() {
  late _Control control;
  late _Looper looper;
  late _Tracks tracks;
  late _Repository repository;

  const input2 = FxChainTarget(FxAddress(stage: FxStage.input, index: 1));
  const lane = FxChainTarget(
    FxAddress(stage: FxStage.loop, index: 1, lane: 0),
  );
  const master = FxChainTarget(FxAddress(stage: FxStage.output));

  PedalBinding bind(
    PedalButton button,
    FxBindingTarget target, {
    int? bank,
    BindingBehavior behavior = BindingBehavior.toggle,
    FxBindingTarget? hold,
  }) => PedalBinding(
    key: PedalBindingKey(
      button: button,
      bank: PedalBindingKey.isBankKeyed(button) ? bank ?? 0 : null,
    ),
    target: target.canonicalString(),
    behavior: behavior,
    holdTarget: hold?.canonicalString(),
  );

  setUpAll(() => registerFallbackValue(Object()));

  setUp(() {
    control = _Control();
    looper = _Looper();
    tracks = _Tracks();
    repository = _Repository();
    for (final button in PedalButton.values) {
      when(() => control.footFxPressed(button, any())).thenReturn(null);
    }
    // Input 2 carries a reverb; the lane chain exists but is empty; the
    // master output carries a delay.
    when(repository.allMonitors).thenReturn({
      1: InputMonitor(
        input: 1,
        effects: [BuiltInEffect(type: TrackEffectType.reverb)],
      ),
    });
    when(
      () => repository.monitorEffects(1),
    ).thenReturn([BuiltInEffect(type: TrackEffectType.reverb)]);
    when(
      repository.allLaneChains,
    ).thenReturn(const {(1, 0): FxChainEnvelope()});
    when(() => repository.laneEffects(1, 0)).thenReturn(const []);
    when(repository.allTrackChains).thenReturn(const {});
    when(
      () => repository.state,
    ).thenReturn(const LooperState(outputBusCount: 1));
    when(
      () => repository.outputEffects(0),
    ).thenReturn([BuiltInEffect(type: TrackEffectType.delay)]);
    whenListen(
      looper,
      const Stream<LooperState>.empty(),
      initialState: LooperState(
        tracks: [
          // Track 1 has no chain of its own: a pedal bound elsewhere must
          // never read blank because of it (#884).
          const Track(state: TrackState.playing, lengthFrames: 48000),
          const Track(channel: 1),
          Track(
            channel: 2,
            effects: [BuiltInEffect(type: TrackEffectType.filter)],
          ),
          const Track(channel: 3, chainEnabled: false),
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
      RepositoryProvider<LooperRepository>.value(
        value: repository,
        child: MultiBlocProvider(
          providers: [
            BlocProvider<ControlCubit>.value(value: control),
            BlocProvider<LooperBloc>.value(value: looper),
            BlocProvider<TracksCubit>.value(value: tracks),
          ],
          child: const Scaffold(body: FootFxView()),
        ),
      ),
    );
  }

  Finder pedal(PedalButton button) =>
      find.byKey(Key('foot_fx_pedal_${button.name}'));

  Finder performancePedal(PedalButton button) => find.ancestor(
    of: pedal(button),
    matching: find.byType(PerformancePedal),
  );

  Finder within(PedalButton button, String text) =>
      find.descendant(of: pedal(button), matching: find.text(text));

  Semantics pedalSemantics(WidgetTester tester, PedalButton button) => find
      .ancestor(of: pedal(button), matching: find.byType(Semantics))
      .evaluate()
      .map((element) => element.widget as Semantics)
      .firstWhere((semantics) => semantics.properties.button ?? false);

  testWidgets('a pedal bound to a chain on another stage names that chain '
      'and stage, never a blank cell (#884)', (tester) async {
    given(
      ControlState(
        mode: InteractionMode.fx,
        globalBindings: PedalBindingSet([bind(PedalButton.track1, input2)]),
        fxSwitches: const {PedalButton.track1: (lit: true, stale: false)},
      ),
    );
    await pump(tester);
    expect(find.byType(PedalHardwareFace), findsNWidgets(10));
    expect(find.text('FX'), findsOneWidget);
    expect(within(PedalButton.track1, 'Reverb'), findsOneWidget);
    expect(within(PedalButton.track1, 'Toggle'), findsOneWidget);
    expect(within(PedalButton.track1, 'Input 2'), findsOneWidget);
    expect(
      pedalSemantics(tester, PedalButton.track1).properties.selected,
      isTrue,
    );
  });

  testWidgets('a lane target is named 1-based with its track (#873)', (
    tester,
  ) async {
    given(
      ControlState(
        mode: InteractionMode.fx,
        globalBindings: PedalBindingSet([bind(PedalButton.track2, lane)]),
        fxSwitches: const {PedalButton.track2: (lit: false, stale: false)},
      ),
    );
    await pump(tester);
    // An empty lane chain falls back to the binding's own label.
    expect(within(PedalButton.track2, 'TRACK 2 lane 1 chain'), findsOneWidget);
    expect(within(PedalButton.track2, 'TRACK 2 lane 1'), findsOneWidget);
    expect(find.textContaining('LANE 0'), findsNothing);
  });

  testWidgets('a momentary binding reads Hold, lights and highlights only '
      'while held, and a Hold target is named', (tester) async {
    given(
      ControlState(
        mode: InteractionMode.fx,
        globalBindings: PedalBindingSet([
          bind(
            PedalButton.track3,
            master,
            behavior: BindingBehavior.momentary,
          ),
          bind(PedalButton.track4, input2, hold: master),
        ]),
        fxSwitches: const {
          PedalButton.track3: (lit: true, stale: false),
          PedalButton.track4: (lit: false, stale: false),
        },
      ),
    );
    await pump(tester);
    expect(within(PedalButton.track3, 'Delay'), findsOneWidget);
    expect(within(PedalButton.track3, 'Hold'), findsOneWidget);
    expect(
      pedalSemantics(tester, PedalButton.track3).properties.selected,
      isTrue,
    );
    expect(
      tester
          .widget<PerformancePedal>(performancePedal(PedalButton.track3))
          .detailHighlighted,
      isTrue,
    );
    expect(within(PedalButton.track4, 'Toggle'), findsOneWidget);
    expect(within(PedalButton.track4, 'Hold · Delay'), findsOneWidget);
    expect(
      tester
          .widget<PerformancePedal>(performancePedal(PedalButton.track4))
          .detailHighlighted,
      isFalse,
    );
  });

  testWidgets('a stale binding reads Target missing and still takes the '
      'stomp, which is refused with a notice', (tester) async {
    given(
      ControlState(
        mode: InteractionMode.fx,
        globalBindings: PedalBindingSet([bind(PedalButton.undo, master)]),
        fxSwitches: const {PedalButton.undo: (lit: false, stale: true)},
      ),
    );
    await pump(tester);
    expect(within(PedalButton.undo, 'Target missing'), findsOneWidget);
    expect(pedalSemantics(tester, PedalButton.undo).properties.enabled, isTrue);
    await tester.tap(pedal(PedalButton.undo));
    await tester.pump();
    verify(() => control.footFxPressed(PedalButton.undo, any())).called(1);
  });

  testWidgets('bound Rec/Play and Stop act; unbound Undo and Clear are '
      'dimmed and admit no contact', (tester) async {
    given(
      ControlState(
        mode: InteractionMode.fx,
        globalBindings: PedalBindingSet([
          bind(PedalButton.recPlay, master),
          bind(PedalButton.stop, input2),
        ]),
        fxSwitches: const {
          PedalButton.recPlay: (lit: true, stale: false),
          PedalButton.stop: (lit: false, stale: false),
        },
      ),
    );
    await pump(tester);
    expect(within(PedalButton.recPlay, 'Delay'), findsOneWidget);
    expect(within(PedalButton.stop, 'Reverb'), findsOneWidget);
    for (final button in [PedalButton.recPlay, PedalButton.stop]) {
      expect(pedalSemantics(tester, button).properties.enabled, isTrue);
      await tester.tap(pedal(button));
      await tester.pump();
      verify(() => control.footFxPressed(button, any())).called(1);
    }
    for (final (button, word) in [
      (PedalButton.undo, 'Undo'),
      (PedalButton.clear, 'Clear'),
    ]) {
      expect(within(button, word), findsOneWidget);
      expect(pedalSemantics(tester, button).properties.enabled, isFalse);
      await tester.tap(pedal(button), warnIfMissed: false);
      await tester.pump();
      verifyNever(() => control.footFxPressed(button, any()));
    }
  });

  testWidgets('unbound track switches name their own chain and light with '
      'it', (tester) async {
    given(const ControlState(mode: InteractionMode.fx));
    await pump(tester);
    // Track 1: no chain, named by bank and position as the pen does.
    expect(within(PedalButton.track1, 'FX A1'), findsOneWidget);
    expect(within(PedalButton.track1, 'TRACK 1'), findsOneWidget);
    expect(within(PedalButton.track1, 'Toggle'), findsOneWidget);
    expect(within(PedalButton.track3, 'Filter'), findsOneWidget);
    expect(
      pedalSemantics(tester, PedalButton.track3).properties.selected,
      isTrue,
    );
    expect(
      pedalSemantics(tester, PedalButton.track4).properties.selected,
      isFalse,
    );
  });

  testWidgets('MODE is Exit, Bank switches bank, and Exit in the header '
      'leaves through the same path', (tester) async {
    given(const ControlState(mode: InteractionMode.fx, activeBank: 1));
    await pump(tester);
    expect(within(PedalButton.mode, 'Exit'), findsOneWidget);
    expect(within(PedalButton.bank, 'Bank B'), findsOneWidget);
    expect(within(PedalButton.bank, 'Switch bank'), findsOneWidget);
    expect(within(PedalButton.track1, 'FX B1'), findsOneWidget);
    await tester.tap(find.byKey(const Key('foot_fx_exit')));
    verify(() => control.activateFootFxPedal(PedalButton.mode)).called(1);
  });

  testWidgets('a cancelled contact is reported, not released', (
    tester,
  ) async {
    given(const ControlState(mode: InteractionMode.fx));
    await pump(tester);
    final gesture = await tester.startGesture(
      tester.getCenter(pedal(PedalButton.track1)),
    );
    await tester.pump();
    await gesture.cancel();
    await tester.pump();
    verify(
      () => control.footFxCancelled(PedalButton.track1, any()),
    ).called(1);
    verifyNever(() => control.footFxReleased(PedalButton.track1, any()));
  });

  test('the projection reads the published switch values', () {
    final pedals = projectFootFx(
      ControlState(
        mode: InteractionMode.fx,
        globalBindings: PedalBindingSet([bind(PedalButton.clear, master)]),
        fxSwitches: const {PedalButton.clear: (lit: true, stale: false)},
      ),
      const LooperState(),
    );
    expect(pedals[PedalButton.clear]!.role, FootFxRole.binding);
    expect(pedals[PedalButton.clear]!.lit, isTrue);
    expect(pedals[PedalButton.stop]!.role, FootFxRole.inert);
    expect(pedals[PedalButton.stop]!.available, isFalse);
    expect(pedals[PedalButton.mode]!.role, FootFxRole.exit);
    // A track the engine does not expose has nothing behind its switch.
    expect(pedals[PedalButton.track1]!.available, isFalse);
  });
}
