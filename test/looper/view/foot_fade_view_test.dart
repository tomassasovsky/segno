import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/control/control.dart';
import 'package:segno/control/model/foot_fade.dart';
import 'package:segno/control/view/pedal_setup/pedal_hardware_face.dart';
import 'package:segno/looper/application/fade_settings.dart';
import 'package:segno/looper/looper.dart';
import 'package:segno/looper/view/foot_fade_view.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

class _Control extends MockCubit<ControlState> implements ControlCubit {}

class _Looper extends MockBloc<LooperEvent, LooperState>
    implements LooperBloc {}

class _Tracks extends MockCubit<TracksState> implements TracksCubit {}

const _playing = Track(state: TrackState.playing, lengthFrames: 48000);

void main() {
  late _Control control;
  late _Looper looper;
  late _Tracks tracks;
  late FadeSettings settings;
  late Map<PedalButton, Object> contacts;

  setUpAll(() => registerFallbackValue(Object()));

  setUp(() {
    control = _Control();
    looper = _Looper();
    tracks = _Tracks();
    contacts = {};
    for (final button in PedalButton.values) {
      when(() => control.footFadePressed(button, any())).thenAnswer((call) {
        contacts[button] = call.positionalArguments[1] as Object;
      });
    }
    whenListen(
      looper,
      const Stream<LooperState>.empty(),
      initialState: const LooperState(
        tracks: [
          _playing,
          Track(
            channel: 1,
            state: TrackState.playing,
            lengthFrames: 48000,
            fade: FadeImage(amount: 0, target: 0),
          ),
          Track(
            channel: 2,
            state: TrackState.playing,
            lengthFrames: 48000,
            fade: FadeImage(amount: .5, target: 0, fullTravelSeconds: 4),
          ),
          Track(channel: 3),
          Track(channel: 4, state: TrackState.playing, lengthFrames: 48000),
        ],
      ),
    );
    whenListen(
      tracks,
      const Stream<TracksState>.empty(),
      initialState: const TracksState(names: []),
    );
  });

  // Storage I/O runs outside the fake clock: awaiting it inside the
  // widget-test zone never completes.
  Future<void> durations(
    WidgetTester tester, {
    bool load = true,
  }) => tester.runAsync(() async {
    final store = SettingsRepository(store: FakeKeyValueStore());
    await store.saveFadeDurations(FadeDurations(overrides: const {1: 8000}));
    settings = FadeSettings(
      repository: LooperRepository(
        engine: FakeAudioEngine(),
        ticker: const Stream.empty(),
      ),
      settings: store,
      blocked: () => false,
      sessionBlocked: () => false,
    );
    if (load) await settings.load();
  });

  void given(ControlState state) => whenListen(
    control,
    const Stream<ControlState>.empty(),
    initialState: state,
  );

  Future<void> pump(WidgetTester tester, {bool load = true}) async {
    await durations(tester, load: load);
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpApp(
      RepositoryProvider<FadeSettings>.value(
        value: settings,
        child: MultiBlocProvider(
          providers: [
            BlocProvider<ControlCubit>.value(value: control),
            BlocProvider<LooperBloc>.value(value: looper),
            BlocProvider<TracksCubit>.value(value: tracks),
          ],
          child: const Scaffold(body: FootFadeView()),
        ),
      ),
    );
  }

  Finder pedal(PedalButton button) =>
      find.byKey(Key('foot_fade_pedal_${button.name}'));

  Finder selectedTime(String value) => find.descendant(
    of: find.byKey(const Key('foot_fade_selected_time')),
    matching: find.text(value),
  );

  Finder overview(int channel) =>
      find.byKey(Key('foot_fade_overview_$channel'));

  testWidgets('Default readout and all-eight overview reflect real owners', (
    tester,
  ) async {
    given(const ControlState(mode: InteractionMode.fade));
    await pump(tester);
    expect(find.byType(PedalHardwareFace), findsNWidgets(10));
    expect(find.text('Default fade time'), findsOneWidget);
    expect(selectedTime('4.0'), findsOneWidget);
    expect(find.byKey(const Key('foot_fade_time_source')), findsNothing);
    expect(
      find.descendant(of: overview(1), matching: find.text('8.0s')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: overview(1), matching: find.text('Faded out')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: overview(2), matching: find.text('Fading out')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: overview(3), matching: find.text('Empty')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: overview(0), matching: find.text('Full level')),
      findsOneWidget,
    );
    expect(find.text('Hold · Reset'), findsNWidgets(2));
    expect(find.text('Bank A'), findsOneWidget);
  });

  testWidgets('a selected track time names its source', (tester) async {
    given(
      const ControlState(
        mode: InteractionMode.fade,
        footFade: FootFadeSelection(timeChannel: 1),
      ),
    );
    await pump(tester);
    expect(find.text('TRACK 2 fade time'), findsOneWidget);
    expect(selectedTime('8.0'), findsOneWidget);
    expect(find.text('Custom'), findsOneWidget);
    expect(find.text('Hold · Use default'), findsNWidgets(2));
  });

  testWidgets('an inherited track time reads Uses default', (tester) async {
    given(
      const ControlState(
        mode: InteractionMode.fade,
        footFade: FootFadeSelection(timeChannel: 0),
      ),
    );
    await pump(tester);
    expect(find.text('Uses default'), findsOneWidget);
  });

  testWidgets('pedals follow the shared bank', (tester) async {
    given(const ControlState(mode: InteractionMode.fade, activeBank: 1));
    await pump(tester);
    expect(find.text('Bank B'), findsOneWidget);
    final bank = find
        .ancestor(of: pedal(PedalButton.bank), matching: find.byType(Semantics))
        .evaluate()
        .map((element) => element.widget as Semantics)
        .firstWhere((semantics) => semantics.properties.label == 'Bank B');
    expect(bank.properties.selected, isTrue, reason: 'mirrors the Bank LED');
    expect(
      find.descendant(
        of: pedal(PedalButton.track1),
        matching: find.text('TRACK 5'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('a contact is admitted, then completed by its own token', (
    tester,
  ) async {
    given(const ControlState(mode: InteractionMode.fade));
    await pump(tester);
    final gesture = await tester.startGesture(
      tester.getCenter(pedal(PedalButton.track1)),
    );
    await tester.pump();
    verify(() => control.footFadePressed(PedalButton.track1, any())).called(1);
    await gesture.up();
    await tester.pump();
    verify(
      () => control.footFadeReleased(
        PedalButton.track1,
        contacts[PedalButton.track1]!,
      ),
    ).called(1);
  });

  testWidgets('an empty track pedal admits no contact', (tester) async {
    given(const ControlState(mode: InteractionMode.fade));
    await pump(tester);
    await tester.tap(pedal(PedalButton.track4), warnIfMissed: false);
    await tester.pump();
    verifyNever(() => control.footFadePressed(PedalButton.track4, any()));
  });

  testWidgets('settings needing recovery show no duration', (tester) async {
    given(const ControlState(mode: InteractionMode.fade));
    await pump(tester, load: false);
    expect(selectedTime('—'), findsOneWidget);
  });
}
