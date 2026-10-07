import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/audio_setup/audio_setup.dart';
import 'package:segno/control/control.dart';
import 'package:segno/control/model/foot_tuner.dart';
import 'package:segno/control/view/pedal_setup/pedal_hardware_face.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/looper.dart';
import 'package:segno/theme/theme.dart';
import 'package:segno/tuner/application/tuner_settings.dart';
import 'package:segno/tuner/cubit/tuner_cubit.dart';
import 'package:segno/tuner/pitch.dart';
import 'package:segno/tuner/view/foot_tuner_view.dart';

import '../../helpers/helpers.dart';

class _Control extends MockCubit<ControlState> implements ControlCubit {}

class _Looper extends MockBloc<LooperEvent, LooperState>
    implements LooperBloc {}

class _Tuner extends MockCubit<TunerState> implements TunerCubit {}

class _Inputs extends MockCubit<InputsState> implements InputsCubit {}

/// The foot Tuner face (pen 23/x, #1229).
void main() {
  late _Control control;
  late _Looper looper;
  late _Tuner tuner;
  late _Inputs inputs;
  late Map<PedalButton, Object> contacts;

  setUpAll(() => registerFallbackValue(Object()));

  setUp(() {
    control = _Control();
    looper = _Looper();
    tuner = _Tuner();
    inputs = _Inputs();
    contacts = {};
    for (final button in PedalButton.values) {
      when(() => control.footTunerPressed(button, any())).thenAnswer((call) {
        contacts[button] = call.positionalArguments[1] as Object;
      });
    }
    whenListen(
      inputs,
      const Stream<InputsState>.empty(),
      initialState: const InputsState(
        names: {0: 'Acoustic guitar', 1: 'Lead vocal microphone'},
      ),
    );
  });

  void given({
    int channels = 4,
    FootTunerSelection selection = const FootTunerSelection(),
    TunerPreferences preferences = const TunerPreferences(),
    TunerState reading = const TunerState(),
  }) {
    whenListen(
      looper,
      const Stream<LooperState>.empty(),
      initialState: LooperState(
        status: EngineStatus(inputChannels: channels),
      ),
    );
    whenListen(
      control,
      const Stream<ControlState>.empty(),
      initialState: ControlState(
        mode: InteractionMode.tuner,
        footTuner: selection,
        tunerPreferences: preferences,
      ),
    );
    whenListen(
      tuner,
      const Stream<TunerState>.empty(),
      initialState: reading,
    );
  }

  Future<void> pump(WidgetTester tester, {Locale? locale}) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final face = MultiBlocProvider(
      providers: [
        BlocProvider<ControlCubit>.value(value: control),
        BlocProvider<LooperBloc>.value(value: looper),
        BlocProvider<TunerCubit>.value(value: tuner),
        BlocProvider<InputsCubit>.value(value: inputs),
      ],
      child: const Scaffold(body: FootTunerView()),
    );
    if (locale == null) return tester.pumpApp(face);
    await tester.pumpWidget(
      MaterialApp(
        locale: locale,
        theme: AppTheme.neon,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: face,
      ),
    );
  }

  Finder pedal(PedalButton button) =>
      find.byKey(Key('foot_tuner_pedal_${button.name}'));

  Finder within(PedalButton button, String text) =>
      find.descendant(of: pedal(button), matching: find.text(text));

  Finder reading(String text) => find.descendant(
    of: find.byKey(const Key('foot_tuner_reading')),
    matching: find.text(text),
  );

  Semantics pedalSemantics(WidgetTester tester, PedalButton button) => find
      .ancestor(of: pedal(button), matching: find.byType(Semantics))
      .evaluate()
      .map((element) => element.widget as Semantics)
      .firstWhere((semantics) => semantics.properties.button ?? false);

  testWidgets('tune an input (23/1): the map, the reference and a flat '
      'reading', (tester) async {
    given(
      reading: TunerState(
        hz: 81,
        pitch: pitchFromHz(81),
      ),
    );
    await pump(tester);
    expect(find.byType(PedalHardwareFace), findsNWidgets(10));
    expect(find.text('Tuner'), findsOneWidget);
    expect(find.text('A4 reference'), findsOneWidget);
    expect(find.text('440'), findsOneWidget);
    expect(within(PedalButton.track1, 'Acoustic guitar'), findsOneWidget);
    expect(within(PedalButton.track1, 'Input 1'), findsOneWidget);
    expect(within(PedalButton.track3, 'Input 3'), findsNWidgets(2));
    expect(within(PedalButton.stop, 'Unmute input'), findsOneWidget);
    expect(within(PedalButton.stop, 'Input muted'), findsOneWidget);
    expect(within(PedalButton.undo, 'Reference −'), findsOneWidget);
    expect(within(PedalButton.clear, 'Reference +'), findsOneWidget);
    expect(within(PedalButton.clear, 'Hold · 440 Hz'), findsOneWidget);
    expect(within(PedalButton.bank, 'Inputs 1–4'), findsOneWidget);
    expect(within(PedalButton.mode, 'Exit'), findsOneWidget);
    expect(reading('Acoustic guitar'), findsOneWidget);
    expect(reading('Input muted'), findsOneWidget);
    expect(reading('E'), findsOneWidget);
    expect(reading('Flat'), findsOneWidget);
    expect(find.byKey(const Key('foot_tuner_needle')), findsOneWidget);
    for (final (button, lit) in [
      (PedalButton.track1, true),
      (PedalButton.track2, false),
      (PedalButton.stop, true),
      (PedalButton.mode, true),
      (PedalButton.bank, false),
    ]) {
      expect(
        pedalSemantics(tester, button).properties.selected,
        lit,
        reason: button.name,
      );
    }
    // One page: Bank and Record / Play are dimmed and silent.
    for (final button in [PedalButton.bank, PedalButton.recPlay]) {
      expect(pedalSemantics(tester, button).properties.enabled, isFalse);
      await tester.tap(pedal(button), warnIfMissed: false);
      await tester.pump();
      verifyNever(() => control.footTunerPressed(button, any()));
    }
  });

  testWidgets('in tune (23/2)', (tester) async {
    given(reading: TunerState(hz: 82.4069, pitch: pitchFromHz(82.4069)));
    await pump(tester);
    expect(reading('In tune'), findsOneWidget);
    expect(reading('0.0 cents'), findsOneWidget);
  });

  testWidgets('no signal (23/3)', (tester) async {
    given();
    await pump(tester);
    expect(reading('—'), findsOneWidget);
    expect(reading('Play one note'), findsOneWidget);
    expect(find.byKey(const Key('foot_tuner_needle')), findsNothing);
  });

  testWidgets('live monitoring (23/4): Mute input, Input audible', (
    tester,
  ) async {
    given(selection: const FootTunerSelection(muted: false));
    await pump(tester);
    expect(within(PedalButton.stop, 'Mute input'), findsOneWidget);
    expect(within(PedalButton.stop, 'Input audible'), findsOneWidget);
    expect(reading('Input audible'), findsOneWidget);
    expect(
      pedalSemantics(tester, PedalButton.stop).properties.selected,
      isFalse,
    );
  });

  testWidgets('18 inputs (23/5): Inputs 17–18, two empty positions', (
    tester,
  ) async {
    given(
      channels: 18,
      selection: const FootTunerSelection(page: 4),
      preferences: const TunerPreferences(input: 16),
    );
    await pump(tester);
    expect(within(PedalButton.bank, 'Inputs 17–18'), findsOneWidget);
    expect(within(PedalButton.bank, 'Next inputs'), findsOneWidget);
    expect(
      pedalSemantics(tester, PedalButton.bank).properties.selected,
      isTrue,
    );
    expect(within(PedalButton.track3, '—'), findsOneWidget);
    expect(
      pedalSemantics(tester, PedalButton.track4).properties.enabled,
      isFalse,
    );
    expect(within(PedalButton.track1, 'Input 17'), findsNWidgets(2));
  });

  testWidgets('a stale reading dims the note', (tester) async {
    given(
      reading: TunerState(hz: 81, pitch: pitchFromHz(81), isStale: true),
    );
    await pump(tester);
    final note = tester.widget<Text>(
      find.descendant(
        of: find.byKey(const Key('foot_tuner_note')),
        matching: find.byType(Text),
      ),
    );
    expect(
      note.style?.color,
      tester.element(pedal(PedalButton.mode)).surface.textSecondary,
    );
  });

  testWidgets('a reading for another input is not drawn', (tester) async {
    given(reading: TunerState(input: 1, hz: 81, pitch: pitchFromHz(81)));
    await pump(tester);
    expect(reading('Play one note'), findsOneWidget);
  });

  testWidgets('no tunable input says so', (tester) async {
    given(channels: 0);
    await pump(tester);
    expect(reading('No input to tune'), findsOneWidget);
    expect(
      pedalSemantics(tester, PedalButton.stop).properties.enabled,
      isFalse,
    );
  });

  testWidgets('a contact is admitted, then completed by its own token; '
      'Undo and Clear offer a semantic hold; Exit leaves', (tester) async {
    given();
    await pump(tester);
    final gesture = await tester.startGesture(
      tester.getCenter(pedal(PedalButton.track2)),
    );
    await tester.pump();
    verify(
      () => control.footTunerPressed(PedalButton.track2, any()),
    ).called(1);
    await gesture.up();
    await tester.pump();
    verify(
      () => control.footTunerReleased(
        PedalButton.track2,
        contacts[PedalButton.track2]!,
      ),
    ).called(1);
    pedalSemantics(tester, PedalButton.clear).properties.onLongPress!();
    verify(
      () => control.activateFootTunerPedal(PedalButton.clear, hold: true),
    ).called(1);
    expect(
      pedalSemantics(tester, PedalButton.track1).properties.onLongPress,
      isNull,
    );
    await tester.tap(find.byKey(const Key('foot_tuner_exit')));
    verify(() => control.activateFootTunerPedal(PedalButton.mode)).called(1);
  });

  testWidgets('every refusal has its own notice, in English and Spanish', (
    tester,
  ) async {
    for (final locale in const [Locale('en'), Locale('es')]) {
      final l10n = lookupAppLocalizations(locale);
      final texts = {
        for (final refusal in FootTunerRefusal.values)
          footTunerRefusalText(l10n, refusal),
      };
      expect(texts, hasLength(FootTunerRefusal.values.length));
    }
  });

  testWidgets('Spanish strings fit', (tester) async {
    given(reading: TunerState(hz: 81, pitch: pitchFromHz(81)));
    await pump(tester, locale: const Locale('es'));
    expect(find.text('Afinador'), findsOneWidget);
    expect(within(PedalButton.stop, 'Activar entrada'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
