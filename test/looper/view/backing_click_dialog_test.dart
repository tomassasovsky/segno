import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:segno/backing/cubit/backing_cubit.dart';
import 'package:segno/backing/cubit/backing_mix_cubit.dart';
import 'package:segno/backing/model/backing_mix.dart';
import 'package:segno/backing/model/backing_state.dart';
import 'package:segno/control/binding/mix_value_scale.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/cubit/tempo_cubit.dart';
import 'package:segno/looper/model/tempo_state.dart';
import 'package:segno/looper/view/backing_click_dialog.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';

import '../../helpers/helpers.dart';

class _MockBacking extends MockCubit<BackingCubitState>
    implements BackingCubit {}

class _MockMix extends MockCubit<BackingMixState> implements BackingMixCubit {}

class _MockTempo extends MockCubit<TempoState> implements TempoCubit {}

void main() {
  late _MockBacking backing;
  late _MockMix mix;
  late _MockTempo tempo;

  setUp(() {
    backing = _MockBacking();
    mix = _MockMix();
    tempo = _MockTempo();
    when(() => tempo.setClickVolume(any())).thenAnswer((_) async {});
    when(() => mix.state).thenReturn(
      const BackingMixState(
        mix: BackingMix(level: 0.5, pan: -0.5),
        mixReady: true,
        clickPan: 0.25,
        clickPanReady: true,
      ),
    );
    when(() => tempo.state).thenReturn(
      const TempoState(
        clickMode: ClickMode.recFirst,
        clickReady: true,
      ),
    );
  });

  void loaded(String? name) => when(() => backing.state).thenReturn(
    BackingCubitState(
      backing: BackingState(
        loaded: name == null ? null : BackingItem(digest: 'd', name: name),
      ),
    ),
  );

  Future<void> pump(WidgetTester tester) async {
    tester.view
      ..physicalSize = const Size(1920, 1080)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpApp(
      MultiBlocProvider(
        providers: [
          BlocProvider<BackingCubit>.value(value: backing),
          BlocProvider<BackingMixCubit>.value(value: mix),
          BlocProvider<TempoCubit>.value(value: tempo),
        ],
        child: const BackingClickDialog(),
      ),
    );
  }

  Finder slider(String row, String control) => find.descendant(
    of: find.descendant(
      of: find.byKey(Key('backing_click_$row')),
      matching: find.byKey(Key('backing_click_$control')),
    ),
    matching: find.byType(LoopSlider),
  );

  AppLocalizations l10n(WidgetTester tester) =>
      AppLocalizations.of(tester.element(find.byType(BackingClickDialog)));

  testWidgets('draws the backing and the click, each with Volume and Pan', (
    tester,
  ) async {
    loaded('Evening lights.wav');
    await pump(tester);
    final t = l10n(tester);
    expect(find.byType(LoopSlider), findsNWidgets(4));
    expect(find.text(t.mixerBackingClick), findsOneWidget);
    expect(find.text(t.mixerBackingChannel), findsOneWidget);
    expect(find.text('Evening lights.wav'), findsOneWidget);
    expect(find.text(t.loopClickFirst), findsOneWidget);
    // 0.5 is -6.0 dB; unity reads 0.0 dB.
    expect(find.text('−6.0 dB'), findsOneWidget);
    expect(find.text('0.0 dB'), findsOneWidget);
    expect(find.text(t.routingPanLeftAmount(50)), findsOneWidget);
    expect(find.text(t.routingPanRightAmount(25)), findsOneWidget);
  });

  testWidgets('says when nothing is loaded', (tester) async {
    loaded(null);
    await pump(tester);
    expect(find.text(l10n(tester).mixerBackingNothingLoaded), findsOneWidget);
  });

  testWidgets('a double tap restores unity and centre', (tester) async {
    loaded('a.wav');
    await pump(tester);
    for (final (row, control) in [
      ('backing', 'volume'),
      ('backing', 'pan'),
      ('click', 'volume'),
      ('click', 'pan'),
    ]) {
      final target = tester.getCenter(slider(row, control));
      await tester.tapAt(target);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(target);
      await tester.pumpAndSettle();
    }
    verify(() => mix.setLevel(1)).called(1);
    verify(() => mix.setPan(0)).called(1);
    verify(() => tempo.setClickVolume(1)).called(1);
    verify(() => mix.setClickPan(0)).called(1);
  });

  testWidgets('a drag commits one value, on the Mixer gain axis', (
    tester,
  ) async {
    loaded('a.wav');
    await pump(tester);
    final box = tester.getRect(slider('backing', 'volume'));
    final gesture = await tester.startGesture(
      box.centerLeft + const Offset(10, 0),
    );
    await gesture.moveBy(Offset(box.width * 0.3, 0));
    await gesture.moveBy(Offset(box.width * 0.3, 0));
    await tester.pump();
    final travel = tester.widget<LoopSlider>(slider('backing', 'volume')).value;
    verifyNever(() => mix.setLevel(any()));
    await gesture.up();
    await tester.pumpAndSettle();
    final captured = verify(() => mix.setLevel(captureAny())).captured;
    expect(captured, hasLength(1));
    // The slider's travel is the Mixer fader's, not a linear gain.
    expect(travel, inExclusiveRange(0.3, 0.9));
    expect(captured.single as double, closeTo(mixerGainAt(travel), 1e-9));
    verifyNever(() => mix.setPan(any()));
  });

  testWidgets('Done closes it', (tester) async {
    loaded('a.wav');
    await tester.pumpApp(
      MultiBlocProvider(
        providers: [
          BlocProvider<BackingCubit>.value(value: backing),
          BlocProvider<BackingMixCubit>.value(value: mix),
          BlocProvider<TempoCubit>.value(value: tempo),
        ],
        child: Builder(
          builder: (context) => TextButton(
            onPressed: () => showBackingClickDialog(context),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(BackingClickDialog), findsOneWidget);
    await tester.tap(find.byKey(const Key('backing_click_done')));
    await tester.pumpAndSettle();
    expect(find.byType(BackingClickDialog), findsNothing);
  });
}
