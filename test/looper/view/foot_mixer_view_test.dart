import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/audio_setup/audio_setup.dart';
import 'package:segno/control/control.dart';
import 'package:segno/control/model/foot_mixer.dart';
import 'package:segno/control/view/pedal_setup/pedal_hardware_face.dart';
import 'package:segno/looper/looper.dart';
import 'package:segno/looper/view/foot_mixer_view.dart';

import '../../helpers/helpers.dart';

class _Control extends MockCubit<ControlState> implements ControlCubit {}

class _Looper extends MockBloc<LooperEvent, LooperState>
    implements LooperBloc {}

class _Repository extends Mock implements LooperRepository {}

class _Inputs extends MockCubit<InputsState> implements InputsCubit {}

class _Tracks extends MockCubit<TracksState> implements TracksCubit {}

void main() {
  late _Control control;
  late Map<PedalButton, Object> contacts;
  late _Looper looper;
  late _Repository repository;
  late _Inputs inputs;
  late _Tracks tracks;

  setUpAll(() => registerFallbackValue(Object()));

  setUp(() {
    control = _Control();
    contacts = {};
    for (final button in PedalButton.values) {
      when(() => control.footMixerPressed(button, any())).thenAnswer((call) {
        contacts[button] = call.positionalArguments[1] as Object;
      });
    }
    looper = _Looper();
    repository = _Repository();
    when(repository.allMonitors).thenReturn(const {});
    when(
      () => repository.monitorChanges,
    ).thenAnswer((_) => const Stream<int>.empty());
    inputs = _Inputs();
    tracks = _Tracks();
    whenListen(
      control,
      const Stream<ControlState>.empty(),
      initialState: const ControlState(
        mode: InteractionMode.mixer,
        footMixer: FootMixerSelection(channel: 0),
      ),
    );
    whenListen(
      looper,
      const Stream<LooperState>.empty(),
      initialState: const LooperState(
        tracks: [
          Track(state: TrackState.playing, lengthFrames: 48000, volume: .8),
          Track(
            channel: 1,
            state: TrackState.playing,
            lengthFrames: 48000,
            volume: .65,
            muted: true,
          ),
          Track(
            channel: 2,
            state: TrackState.playing,
            lengthFrames: 48000,
            volume: 1.1,
          ),
          Track(channel: 3),
        ],
      ),
    );
    whenListen(
      inputs,
      const Stream<InputsState>.empty(),
      initialState: const InputsState(names: {0: 'Guitar'}),
    );
    whenListen(
      tracks,
      const Stream<TracksState>.empty(),
      initialState: const TracksState(names: []),
    );
  });

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
            BlocProvider<InputsCubit>.value(value: inputs),
            BlocProvider<TracksCubit>.value(value: tracks),
          ],
          child: const Scaffold(body: FootMixerView()),
        ),
      ),
    );
  }

  Finder pedal(PedalButton button) =>
      find.byKey(Key('foot_mixer_pedal_${button.name}'));

  testWidgets(
    'accepted layout has two raised controls and eight front pedals',
    (tester) async {
      await pump(tester);
      expect(find.byType(PedalHardwareFace), findsNWidgets(10));
      expect(
        tester.getTopLeft(pedal(PedalButton.clear)).dy,
        lessThan(tester.getTopLeft(pedal(PedalButton.undo)).dy),
      );
      expect(
        tester.getTopLeft(pedal(PedalButton.clear)).dy,
        tester.getTopLeft(pedal(PedalButton.bank)).dy,
      );
      expect(
        tester.getTopLeft(pedal(PedalButton.recPlay)).dy,
        tester.getTopLeft(pedal(PedalButton.track4)).dy,
      );
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byKey(const Key('foot_mixer_gain_bar')),
            )
            .value,
        .4,
      );
      expect(find.text('65% · Muted'), findsOneWidget);
      expect(find.text('Empty'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('touch forwards both contact edges; cancel never releases', (
    tester,
  ) async {
    await pump(tester);
    final gesture = await tester.startGesture(
      tester.getCenter(pedal(PedalButton.clear)),
    );
    verify(() => control.footMixerPressed(PedalButton.clear, any())).called(1);
    await gesture.up();
    verify(
      () => control.footMixerReleased(
        PedalButton.clear,
        contacts[PedalButton.clear]!,
      ),
    ).called(1);
    final cancelled = await tester.startGesture(
      tester.getCenter(pedal(PedalButton.undo)),
    );
    await cancelled.cancel();
    verify(
      () => control.footMixerCancelled(
        PedalButton.undo,
        contacts[PedalButton.undo]!,
      ),
    ).called(1);
    verifyNever(
      () => control.footMixerReleased(
        PedalButton.undo,
        contacts[PedalButton.undo]!,
      ),
    );
  });

  for (final cancelOther in [false, true]) {
    testWidgets(
      'second pointer cannot end admitted contact: cancel=$cancelOther',
      (
        tester,
      ) async {
        await pump(tester);
        final center = tester.getCenter(pedal(PedalButton.clear));
        final first = await tester.startGesture(center, pointer: 1);
        final second = await tester.startGesture(center, pointer: 2);
        if (cancelOther) {
          await second.cancel();
        } else {
          await second.up();
        }
        verifyNever(() => control.footMixerReleased(PedalButton.clear, any()));
        verifyNever(() => control.footMixerCancelled(PedalButton.clear, any()));
        await first.up();
        verify(
          () => control.footMixerPressed(PedalButton.clear, any()),
        ).called(1);
        verify(
          () => control.footMixerReleased(
            PedalButton.clear,
            contacts[PedalButton.clear]!,
          ),
        ).called(1);
      },
    );
  }

  testWidgets('key release cannot end pointer contact', (tester) async {
    await pump(tester);
    Focus.of(tester.element(pedal(PedalButton.clear))).requestFocus();
    await tester.pump();
    final first = await tester.startGesture(
      tester.getCenter(pedal(PedalButton.clear)),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    verifyNever(() => control.footMixerReleased(PedalButton.clear, any()));
    await first.up();
    verify(
      () => control.footMixerReleased(
        PedalButton.clear,
        contacts[PedalButton.clear]!,
      ),
    ).called(1);
  });

  testWidgets('other key and pointer cannot end keyboard contact', (
    tester,
  ) async {
    await pump(tester);
    Focus.of(tester.element(pedal(PedalButton.clear))).requestFocus();
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.tap(pedal(PedalButton.clear));
    verifyNever(() => control.footMixerReleased(PedalButton.clear, any()));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
    verify(() => control.footMixerPressed(PedalButton.clear, any())).called(1);
    verify(
      () => control.footMixerReleased(
        PedalButton.clear,
        contacts[PedalButton.clear]!,
      ),
    ).called(1);
  });

  testWidgets('each screen contact completes with its own originating token', (
    tester,
  ) async {
    await pump(tester);
    final gesture = await tester.startGesture(
      tester.getCenter(pedal(PedalButton.clear)),
    );
    final first = contacts[PedalButton.clear]!;
    await gesture.up();
    final abandoned = await tester.startGesture(
      tester.getCenter(pedal(PedalButton.clear)),
    );
    final second = contacts[PedalButton.clear]!;
    expect(identical(first, second), isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    await abandoned.cancel();
    verify(() => control.footMixerReleased(PedalButton.clear, first)).called(1);
    verify(
      () => control.footMixerCancelled(PedalButton.clear, second),
    ).called(1);
    verifyNever(() => control.footMixerReleased(PedalButton.clear, second));
    verifyNever(() => control.footMixerCancelled(PedalButton.clear, first));
  });

  testWidgets(
    'empty channel does not forward contacts; unmount cancels holds',
    (tester) async {
      await pump(tester);
      await tester.tap(pedal(PedalButton.track4));
      verifyNever(() => control.footMixerPressed(PedalButton.track4, any()));
      final gesture = await tester.startGesture(
        tester.getCenter(pedal(PedalButton.clear)),
      );
      await tester.pumpWidget(const SizedBox.shrink());
      verify(
        () => control.footMixerCancelled(
          PedalButton.clear,
          contacts[PedalButton.clear]!,
        ),
      ).called(1);
      verifyNever(
        () => control.footMixerReleased(
          PedalButton.clear,
          contacts[PedalButton.clear]!,
        ),
      );
      verifyNever(
        () => control.footMixerCancelled(
          PedalButton.undo,
          any(),
        ),
      );
      verifyNever(
        () => control.footMixerCancelled(
          PedalButton.track1,
          any(),
        ),
      );
      await gesture.cancel();
    },
  );

  testWidgets('accessibility actions use the same typed pedal dispatcher', (
    tester,
  ) async {
    await pump(tester);
    final semantics = tester.widget<Semantics>(
      find.byWidgetPredicate(
        (widget) =>
            widget is Semantics && widget.properties.label == 'Volume +',
      ),
    );
    semantics.properties.onTap!();
    verify(() => control.activateFootMixerPedal(PedalButton.clear)).called(1);
    semantics.properties.onLongPress!();
    verify(
      () => control.activateFootMixerPedal(PedalButton.clear, hold: true),
    ).called(1);
  });

  testWidgets(
    'source and exit actions delegate without changing normal cursor',
    (tester) async {
      await pump(tester);
      await tester.tap(find.text('Inputs'));
      verify(
        () => control.selectFootMixerDomain(FootMixerDomain.inputs),
      ).called(1);
      await tester.tap(find.byKey(const Key('foot_mixer_exit')));
      verify(() => control.setMode(InteractionMode.record)).called(1);
      verifyNever(() => control.selectTrack(any()));
    },
  );

  testWidgets('last eighteen-input page leaves two inert slots', (
    tester,
  ) async {
    when(() => control.state).thenReturn(
      const ControlState(
        mode: InteractionMode.mixer,
        footMixer: FootMixerSelection(
          domain: FootMixerDomain.inputs,
          page: 4,
          channel: 16,
        ),
      ),
    );
    when(
      () => looper.state,
    ).thenReturn(const LooperState(status: EngineStatus(inputChannels: 18)));
    await pump(tester);
    expect(find.text('Inputs 17–18'), findsOneWidget);
    expect(find.text('—'), findsNWidgets(2));
    await tester.tap(pedal(PedalButton.track3));
    verifyNever(() => control.footMixerPressed(PedalButton.track3, any()));
    expect(
      tester
          .widget<LinearProgressIndicator>(
            find.byKey(const Key('foot_mixer_gain_bar')),
          )
          .value,
      1,
    );
    expect(find.text('Limit · Hold reset'), findsOneWidget);
  });

  testWidgets('Auto closed readout stays truthful at the partial-step limit', (
    tester,
  ) async {
    when(() => control.state).thenReturn(
      const ControlState(
        mode: InteractionMode.mixer,
        footMixer: FootMixerSelection(
          domain: FootMixerDomain.inputs,
          channel: 0,
        ),
      ),
    );
    when(
      () => looper.state,
    ).thenReturn(const LooperState(status: EngineStatus(inputChannels: 2)));
    when(repository.allMonitors).thenReturn(const {
      0: InputMonitor(input: 0, mode: MonitorMode.auto, volume: .98),
    });
    await pump(tester);
    expect(find.text('Auto · Live off'), findsOneWidget);
    expect(find.text('Limit · Hold reset'), findsOneWidget);
    final gesture = await tester.startGesture(
      tester.getCenter(pedal(PedalButton.clear)),
    );
    verify(() => control.footMixerPressed(PedalButton.clear, any())).called(1);
    await gesture.up();
    expect(find.text('Guitar'), findsNWidgets(2));
  });

  testWidgets('empty Tracks keeps source choices available and level absent', (
    tester,
  ) async {
    when(() => looper.state).thenReturn(const LooperState());
    await pump(tester);
    expect(find.text('No recorded tracks'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    await tester.tap(pedal(PedalButton.clear));
    verifyNever(() => control.footMixerPressed(PedalButton.clear, any()));
    await tester.tap(find.text('Inputs'));
    verify(
      () => control.selectFootMixerDomain(FootMixerDomain.inputs),
    ).called(1);
  });
}
