import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/control/control.dart';
import 'package:segno/control/model/foot_peel.dart';
import 'package:segno/control/view/pedal_setup/pedal_hardware_face.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/looper.dart';
import 'package:segno/looper/view/foot_peel_view.dart';
import 'package:segno/theme/theme.dart';

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
      when(() => control.footPeelPressed(button, any())).thenAnswer((call) {
        contacts[button] = call.positionalArguments[1] as Object;
      });
    }
    whenListen(
      looper,
      const Stream<LooperState>.empty(),
      initialState: const LooperState(
        tracks: [
          Track(state: TrackState.playing, lengthFrames: 48000, peelDepth: 2),
          Track(channel: 1, state: TrackState.playing, lengthFrames: 48000),
          // Overdubbing over one layer: busy, but still recorded.
          Track(
            channel: 2,
            state: TrackState.overdubbing,
            lengthFrames: 48000,
            peelDepth: 1,
          ),
          Track(channel: 3),
          Track(
            channel: 4,
            state: TrackState.stopped,
            lengthFrames: 48000,
            peelDepth: 1,
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
        child: const Scaffold(body: FootPeelView()),
      ),
    );
  }

  Finder pedal(PedalButton button) =>
      find.byKey(Key('foot_peel_pedal_${button.name}'));

  Finder overview(int channel) =>
      find.byKey(Key('foot_peel_overview_$channel'));

  Semantics pedalSemantics(WidgetTester tester, PedalButton button) => find
      .ancestor(of: pedal(button), matching: find.byType(Semantics))
      .evaluate()
      .map((element) => element.widget as Semantics)
      .firstWhere((semantics) => semantics.properties.button ?? false);

  testWidgets('the overview and pedals read every track’s layers', (
    tester,
  ) async {
    given(const ControlState(mode: InteractionMode.peel));
    await pump(tester);
    expect(find.byType(PedalHardwareFace), findsNWidgets(10));
    expect(find.text('Layers'), findsOneWidget);
    for (final (channel, word) in [
      (0, '3 layers'),
      (1, 'Original only'),
      // A busy recorded track reads its real layers, never "Empty".
      (2, '2 layers'),
      (3, 'Empty'),
      (4, '2 layers'),
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
        of: pedal(PedalButton.track3),
        matching: find.text('2 layers'),
      ),
      findsOneWidget,
    );
    expect(find.text('Switch bank'), findsOneWidget);
    // The selection bar mirrors the LED: lit only where a press would peel.
    for (final (button, lit) in [
      (PedalButton.track1, true),
      (PedalButton.track2, false),
      (PedalButton.track3, false),
      (PedalButton.track4, false),
    ]) {
      expect(
        pedalSemantics(tester, button).properties.selected,
        lit,
        reason: button.name,
      );
    }
  });

  testWidgets('a busy recorded track reads dimmer than a peelable one', (
    tester,
  ) async {
    given(const ControlState(mode: InteractionMode.peel));
    await pump(tester);
    Color? colorOf(int channel, String word) => tester
        .widget<Text>(
          find.descendant(of: overview(channel), matching: find.text(word)),
        )
        .style
        ?.color;
    final surface = tester.element(overview(0)).surface;
    expect(colorOf(0, '3 layers'), surface.textPrimary);
    expect(colorOf(2, '2 layers'), surface.textSecondary);
    expect(colorOf(3, 'Empty'), surface.textMuted);
  });

  testWidgets('Undo, Clear and empty tracks admit no contact; recorded '
      'tracks do', (
    tester,
  ) async {
    given(const ControlState(mode: InteractionMode.peel));
    await pump(tester);
    for (final button in [PedalButton.undo, PedalButton.clear]) {
      expect(pedalSemantics(tester, button).properties.enabled, isFalse);
      await tester.tap(pedal(button), warnIfMissed: false);
      await tester.pump();
      verifyNever(() => control.footPeelPressed(button, any()));
    }
    // A recorded track that cannot peel now still takes the press, so the
    // refusal can say why.
    for (final button in [PedalButton.track2, PedalButton.track3]) {
      expect(pedalSemantics(tester, button).properties.enabled, isTrue);
      await tester.tap(pedal(button));
      await tester.pump();
      verify(() => control.footPeelPressed(button, any())).called(1);
    }
    // An empty track's pedal is dimmed and silent, as on Fade and Reverse.
    expect(
      pedalSemantics(tester, PedalButton.track4).properties.enabled,
      isFalse,
    );
    await tester.tap(pedal(PedalButton.track4), warnIfMissed: false);
    await tester.pump();
    verifyNever(() => control.footPeelPressed(PedalButton.track4, any()));
  });

  testWidgets('pedals follow the shared bank', (tester) async {
    given(const ControlState(mode: InteractionMode.peel, activeBank: 1));
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
    given(const ControlState(mode: InteractionMode.peel));
    await pump(tester);
    final gesture = await tester.startGesture(
      tester.getCenter(pedal(PedalButton.track1)),
    );
    await tester.pump();
    verify(() => control.footPeelPressed(PedalButton.track1, any())).called(1);
    await gesture.up();
    await tester.pump();
    verify(
      () => control.footPeelReleased(
        PedalButton.track1,
        contacts[PedalButton.track1]!,
      ),
    ).called(1);
  });

  testWidgets('the header Exit returns to Tracks', (tester) async {
    given(const ControlState(mode: InteractionMode.peel));
    await pump(tester);
    await tester.tap(find.byKey(const Key('foot_peel_exit')));
    verify(() => control.setMode(InteractionMode.record)).called(1);
  });

  testWidgets('every refusal has its own notice, in English and Spanish', (
    tester,
  ) async {
    late AppLocalizations en;
    late AppLocalizations es;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) {
            en = lookupAppLocalizations(const Locale('en'));
            es = lookupAppLocalizations(const Locale('es'));
            return const SizedBox();
          },
        ),
      ),
    );
    for (final l10n in [en, es]) {
      final texts = {
        for (final refusal in FootPeelRefusal.values)
          footPeelRefusalText(l10n, refusal),
      };
      expect(texts, hasLength(FootPeelRefusal.values.length));
    }
    for (final refusal in [FootPeelRefusal.busy, FootPeelRefusal.failed]) {
      expect(
        footPeelRefusalText(es, refusal),
        contains('Inténtalo de nuevo'),
        reason: 'the retry wording every Spanish notice uses',
      );
    }
  });
}
