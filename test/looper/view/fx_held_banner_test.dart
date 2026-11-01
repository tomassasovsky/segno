import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart'
    show EngineStatus, FxAddress, FxStage, LooperState;
import 'package:mocktail/mocktail.dart';
import 'package:segno/audio_setup/audio_setup.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/cubit/tracks_cubit.dart';
import 'package:segno/looper/view/fx_held_banner.dart';

import '../../helpers/helpers.dart';

class _MockLooperBloc extends MockBloc<LooperEvent, LooperState>
    implements LooperBloc {}

class _MockTracksCubit extends MockCubit<TracksState> implements TracksCubit {}

class _MockInputsCubit extends MockCubit<InputsState> implements InputsCubit {}

class _MockOutputsCubit extends MockCubit<OutputsState>
    implements OutputsCubit {}

/// The stage's standing notice for effects the rig could not run (#1515,
/// the owner's R2).
void main() {
  late _MockLooperBloc looper;
  late _MockTracksCubit tracks;
  late _MockInputsCubit inputs;
  late _MockOutputsCubit outputs;

  setUpAll(() => registerFallbackValue(const LooperFxHoldNoticeDismissed()));

  setUp(() {
    looper = _MockLooperBloc();
    tracks = _MockTracksCubit();
    inputs = _MockInputsCubit();
    outputs = _MockOutputsCubit();
    when(() => tracks.state).thenReturn(
      const TracksState(names: ['', '', 'Vox', '', '', '', '', '']),
    );
    when(
      () => inputs.state,
    ).thenReturn(const InputsState(names: {0: 'Guitar'}));
    when(() => outputs.state).thenReturn(const OutputsState());
  });

  Future<void> pump(WidgetTester tester, List<FxAddress> notice) {
    when(() => looper.state).thenReturn(
      LooperState(
        status: const EngineStatus(outputChannels: 4),
        fxHeld: notice.toSet(),
        fxHoldNotice: notice,
      ),
    );
    return tester.pumpApp(
      MultiBlocProvider(
        providers: [
          BlocProvider<LooperBloc>.value(value: looper),
          BlocProvider<TracksCubit>.value(value: tracks),
          BlocProvider<InputsCubit>.value(value: inputs),
          BlocProvider<OutputsCubit>.value(value: outputs),
        ],
        child: const Scaffold(body: FxHeldBanner()),
      ),
    );
  }

  testWidgets('takes no space while nothing is held', (tester) async {
    await pump(tester, const []);
    expect(find.byKey(const Key('fx_held_banner')), findsNothing);
  });

  testWidgets('names the chains that are off, one name per track', (
    tester,
  ) async {
    await pump(tester, const [
      FxAddress(stage: FxStage.loop, index: 2, lane: 1),
      FxAddress(stage: FxStage.loop, index: 2),
      FxAddress(stage: FxStage.input),
    ]);
    expect(find.byKey(const Key('fx_held_banner')), findsOneWidget);
    expect(
      find.text(
        "Some effects are off: the rig doesn't fit the audio processing "
        "available. Vox and Guitar's input chain are off. Remove effects, "
        'then turn them back on.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('says one chain in the singular', (tester) async {
    await pump(tester, const [FxAddress(stage: FxStage.output, index: 1)]);
    expect(
      find.text(
        "Some effects are off: the rig doesn't fit the audio processing "
        'available. Outputs 3–4 is off. Remove effects, then turn them back '
        'on.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('Dismiss asks for the notice to go', (tester) async {
    await pump(tester, const [FxAddress(stage: FxStage.allTracks)]);
    await tester.tap(find.byKey(const Key('fx_held_banner_dismiss')));
    verify(() => looper.add(const LooperFxHoldNoticeDismissed())).called(1);
  });
}
