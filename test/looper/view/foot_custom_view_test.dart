import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/control/control.dart';
import 'package:segno/control/view/pedal_setup/pedal_hardware_face.dart';
import 'package:segno/looper/looper.dart';
import 'package:segno/looper/view/foot_custom_view.dart';
import 'package:segno/performance/performance.dart';
import 'package:segno/theme/theme.dart';

import '../../helpers/helpers.dart';

class _Control extends MockCubit<ControlState> implements ControlCubit {}

class _Tracks extends MockCubit<TracksState> implements TracksCubit {}

class _Recorder extends MockCubit<PerformanceRecorderState>
    implements PerformanceRecorderCubit {}

const _fade = TrackOperationAction(
  operation: TrackOperation.fade,
  scope: SelectedTrackScope(),
);

final PedalSetup _setup = const PedalSetup()
    .withCustom(
      PedalButton.track1,
      bank: 0,
      pair: const ControlGesturePair(
        press: SelectTrackAction(0),
        hold: CommandAction(ControlCommand.tapTempo),
      ),
    )
    .withCustom(
      PedalButton.track1,
      bank: 1,
      pair: const ControlGesturePair(press: _fade),
    )
    .withCustom(
      PedalButton.undo,
      bank: 0,
      pair: const ControlGesturePair(hold: CommandAction(ControlCommand.redo)),
    )
    .withCustom(
      PedalButton.clear,
      bank: 0,
      pair: const ControlGesturePair(press: UnavailableAction('future:thing')),
    )
    .withCustom(
      PedalButton.stop,
      bank: 0,
      pair: const ControlGesturePair(
        press: CommandAction(ControlCommand.recordPerformance),
      ),
    );

void main() {
  late _Control control;
  late _Tracks tracks;
  late _Recorder recorder;
  late Map<PedalButton, Object> contacts;

  setUpAll(() => registerFallbackValue(Object()));

  setUp(() {
    control = _Control();
    tracks = _Tracks();
    recorder = _Recorder();
    contacts = {};
    for (final button in PedalButton.values) {
      when(() => control.footCustomPressed(button, any())).thenAnswer((call) {
        contacts[button] = call.positionalArguments[1] as Object;
      });
    }
    whenListen(
      tracks,
      const Stream<TracksState>.empty(),
      initialState: const TracksState(names: ['Drums']),
    );
    whenListen(
      recorder,
      const Stream<PerformanceRecorderState>.empty(),
      initialState: const PerformanceRecorderIdle(),
    );
  });

  void given(ControlState state) => whenListen(
    control,
    const Stream<ControlState>.empty(),
    initialState: state,
  );

  ControlState custom({int bank = 0, Map<PedalButton, bool> lit = const {}}) =>
      ControlState(
        mode: InteractionMode.custom,
        pedalSetup: _setup,
        activeBank: bank,
        customLit: lit,
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
          BlocProvider<PerformanceRecorderCubit>.value(value: recorder),
        ],
        child: const Scaffold(body: FootCustomView()),
      ),
    );
  }

  Finder pedal(PedalButton button) =>
      find.byKey(Key('foot_custom_pedal_${button.name}'));

  Finder within(PedalButton button, String text) =>
      find.descendant(of: pedal(button), matching: find.text(text));

  Semantics pedalSemantics(WidgetTester tester, PedalButton button) => find
      .ancestor(of: pedal(button), matching: find.byType(Semantics))
      .evaluate()
      .map((element) => element.widget as Semantics)
      .firstWhere((semantics) => semantics.properties.button ?? false);

  testWidgets('each switch names its assignment; an unassigned switch reads '
      'its hardware name', (tester) async {
    given(custom());
    await pump(tester);
    expect(find.byType(PedalHardwareFace), findsNWidgets(10));
    expect(find.text('Custom'), findsOneWidget);
    expect(within(PedalButton.track1, 'Select Drums'), findsOneWidget);
    expect(within(PedalButton.track1, 'Hold · Tap tempo'), findsOneWidget);
    // Hold only: the hardware name, with the Hold under it.
    expect(within(PedalButton.undo, 'Undo'), findsOneWidget);
    expect(within(PedalButton.undo, 'Hold · Redo'), findsOneWidget);
    expect(
      within(PedalButton.clear, 'Unavailable · future:thing'),
      findsOneWidget,
    );
    expect(within(PedalButton.stop, 'Record performance'), findsOneWidget);
    expect(within(PedalButton.recPlay, 'Record / Play'), findsOneWidget);
    expect(within(PedalButton.track2, 'Track 2'), findsOneWidget);
    expect(within(PedalButton.mode, 'Exit'), findsOneWidget);
    expect(within(PedalButton.bank, 'Bank A'), findsOneWidget);
    expect(within(PedalButton.bank, 'Switch bank'), findsOneWidget);
    expect(find.byKey(const Key('foot_custom_recording')), findsNothing);
  });

  testWidgets('Bank flips the bank-keyed captions', (tester) async {
    given(custom(bank: 1));
    await pump(tester);
    expect(within(PedalButton.bank, 'Bank B'), findsOneWidget);
    expect(within(PedalButton.track1, 'Selected track · Fade'), findsOneWidget);
    expect(within(PedalButton.track2, 'Track 6'), findsOneWidget);
    expect(
      pedalSemantics(tester, PedalButton.bank).properties.selected,
      isTrue,
    );
  });

  testWidgets('an unavailable action stays enabled with its caption muted', (
    tester,
  ) async {
    given(custom());
    await pump(tester);
    final surface = tester.element(pedal(PedalButton.clear)).surface;
    Color? colorOf(PedalButton button, String text) =>
        tester.widget<Text>(within(button, text)).style?.color;
    expect(
      colorOf(PedalButton.clear, 'Unavailable · future:thing'),
      surface.textMuted,
    );
    expect(
      colorOf(PedalButton.track1, 'Select Drums'),
      isNot(
        surface.textMuted,
      ),
    );
    expect(
      pedalSemantics(tester, PedalButton.clear).properties.enabled,
      isTrue,
    );
    await tester.tap(pedal(PedalButton.clear));
    await tester.pump();
    verify(() => control.footCustomPressed(PedalButton.clear, any())).called(1);
  });

  testWidgets('only unassigned switches are dimmed and inert', (tester) async {
    given(custom());
    await pump(tester);
    for (final button in [
      PedalButton.recPlay,
      PedalButton.track2,
      PedalButton.track3,
      PedalButton.track4,
    ]) {
      expect(
        pedalSemantics(tester, button).properties.enabled,
        isFalse,
        reason: button.name,
      );
      await tester.tap(pedal(button), warnIfMissed: false);
      await tester.pump();
      verifyNever(() => control.footCustomPressed(button, any()));
    }
    for (final button in [
      PedalButton.track1,
      PedalButton.undo,
      PedalButton.stop,
      PedalButton.mode,
      PedalButton.bank,
    ]) {
      expect(
        pedalSemantics(tester, button).properties.enabled,
        isTrue,
        reason: button.name,
      );
    }
  });

  testWidgets('the selection bars are the published LED value', (
    tester,
  ) async {
    given(
      custom(lit: const {PedalButton.track1: true, PedalButton.stop: false}),
    );
    await pump(tester);
    for (final (button, lit) in [
      (PedalButton.track1, true),
      (PedalButton.stop, false),
      (PedalButton.mode, true),
      (PedalButton.bank, false),
    ]) {
      expect(
        pedalSemantics(tester, button).properties.selected,
        lit,
        reason: button.name,
      );
    }
  });

  testWidgets('while a performance records, its switch offers to stop it', (
    tester,
  ) async {
    whenListen(
      recorder,
      const Stream<PerformanceRecorderState>.empty(),
      initialState: const PerformanceRecorderArmed(
        elapsed: Duration(minutes: 1, seconds: 23),
        overrun: false,
      ),
    );
    given(custom(lit: const {PedalButton.stop: true}));
    await pump(tester);
    expect(within(PedalButton.stop, 'Stop recording'), findsOneWidget);
    expect(
      pedalSemantics(tester, PedalButton.stop).properties.selected,
      isTrue,
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('foot_custom_recording')),
        matching: find.text('01:23'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('a contact is admitted, then completed by its own token; a '
      'semantic long press runs the Hold', (tester) async {
    given(custom());
    await pump(tester);
    final gesture = await tester.startGesture(
      tester.getCenter(pedal(PedalButton.track1)),
    );
    await tester.pump();
    verify(
      () => control.footCustomPressed(PedalButton.track1, any()),
    ).called(1);
    await gesture.up();
    await tester.pump();
    verify(
      () => control.footCustomReleased(
        PedalButton.track1,
        contacts[PedalButton.track1]!,
      ),
    ).called(1);
    pedalSemantics(tester, PedalButton.track1).properties.onLongPress!();
    verify(
      () => control.activateFootCustomPedal(PedalButton.track1, hold: true),
    ).called(1);
    expect(
      pedalSemantics(tester, PedalButton.stop).properties.onLongPress,
      isNull,
    );
  });

  testWidgets('the header Exit returns to Tracks', (tester) async {
    given(custom());
    await pump(tester);
    await tester.tap(find.byKey(const Key('foot_custom_exit')));
    verify(() => control.setMode(InteractionMode.record)).called(1);
  });
}
