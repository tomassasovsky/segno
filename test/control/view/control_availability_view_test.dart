import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:segno/backing/cubit/backing_mix_cubit.dart';
import 'package:segno/backing/model/backing_mix.dart';
import 'package:segno/control/binding/control_availability.dart';
import 'package:segno/control/view/control_availability_view.dart';
import 'package:segno/looper/application/fade_settings.dart';
import 'package:segno/looper/cubit/playback_options_cubit.dart';
import 'package:segno/looper/cubit/record_options_cubit.dart';
import 'package:segno/looper/cubit/record_timing_cubit.dart';
import 'package:segno/looper/cubit/tempo_cubit.dart';
import 'package:segno/looper/model/playback_options.dart';
import 'package:segno/looper/model/record_options.dart';
import 'package:segno/looper/model/record_options_view_state.dart';
import 'package:segno/looper/model/record_timing.dart';
import 'package:segno/looper/model/tempo_state.dart';

import '../../helpers/helpers.dart';

class _MockTempo extends MockCubit<TempoState> implements TempoCubit {}

class _MockPlayback extends MockCubit<PlaybackOptions>
    implements PlaybackOptionsCubit {}

class _MockRecord extends MockCubit<RecordOptionsViewState>
    implements RecordOptionsCubit {}

class _MockTiming extends MockCubit<RecordTimingState>
    implements RecordTimingCubit {}

class _MockMix extends MockCubit<BackingMixState> implements BackingMixCubit {}

void main() {
  late LooperRepository looper;
  late FadeSettings fade;
  late _MockTempo tempo;
  late _MockPlayback playback;
  late _MockRecord record;
  late _MockTiming timing;

  setUp(() {
    looper = LooperRepository(
      engine: FakeAudioEngine(),
      ticker: const Stream.empty(),
    );
    fade = testFadeSettings(repository: looper);
    tempo = _MockTempo();
    playback = _MockPlayback();
    record = _MockRecord();
    timing = _MockTiming();
    when(() => tempo.state).thenReturn(const TempoState());
    when(() => playback.state).thenReturn(const PlaybackOptions());
    when(
      () => record.state,
    ).thenReturn(const RecordOptionsViewState(options: RecordOptions()));
    when(() => timing.state).thenReturn(const RecordTimingState());
  });

  Future<ControlAvailability> read(
    WidgetTester tester, {
    BackingMixCubit? mix,
  }) async {
    late ControlAvailability availability;
    await tester.pumpWidget(
      RepositoryProvider<LooperRepository>.value(
        value: looper,
        child: RepositoryProvider<FadeSettings>.value(
          value: fade,
          child: MultiBlocProvider(
            providers: [
              BlocProvider<TempoCubit>.value(value: tempo),
              BlocProvider<PlaybackOptionsCubit>.value(value: playback),
              BlocProvider<RecordOptionsCubit>.value(value: record),
              BlocProvider<RecordTimingCubit>.value(value: timing),
              if (mix != null) BlocProvider<BackingMixCubit>.value(value: mix),
            ],
            child: Builder(
              builder: (context) {
                availability = controlAvailability(context);
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      ),
    );
    return availability;
  }

  testWidgets('reads the backing owners when the host provides them', (
    tester,
  ) async {
    final mix = _MockMix();
    when(() => mix.state).thenReturn(
      const BackingMixState(
        mix: BackingMix(level: 0.5, pan: -0.25),
        mixReady: true,
        clickPan: 0.75,
        clickPanReady: true,
      ),
    );
    final availability = await read(tester, mix: mix);
    expect(
      availability.owned.backingMix,
      const BackingMix(level: 0.5, pan: -0.25),
    );
    expect(availability.owned.clickPan, 0.75);
  });

  testWidgets('leaves an owner out until it is ready', (tester) async {
    final mix = _MockMix();
    when(() => mix.state).thenReturn(
      const BackingMixState(
        mix: BackingMix(level: 0.5, pan: -0.25),
        clickPan: 0.75,
      ),
    );
    final availability = await read(tester, mix: mix);
    expect(availability.owned.backingMix, isNull);
    expect(availability.owned.clickPan, isNull);
  });

  testWidgets('leaves the backing out where no host provides it', (
    tester,
  ) async {
    final availability = await read(tester);
    expect(availability.owned.backingMix, isNull);
    expect(availability.owned.clickPan, isNull);
  });
}
