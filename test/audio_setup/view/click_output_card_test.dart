import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:segno/audio_setup/audio_setup.dart';
import 'package:segno/audio_setup/view/console/click_output_card.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/looper/cubit/tempo_cubit.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

class _MockAudioSetupCubit extends MockCubit<AudioSetupState>
    implements AudioSetupCubit {}

class _MockLooperRepository extends Mock implements LooperRepository {}

/// A four-out interface reported by the engine.
const _fourOut = AudioSetupState(
  status: AudioSetupStatus.running,
  engineStatus: EngineStatus(isConnected: true, outputChannels: 4),
);

/// Pins [audio] to [state] for the life of a test.
void _seed(_MockAudioSetupCubit audio, AudioSetupState state) {
  when(() => audio.state).thenReturn(state);
  whenListen(audio, const Stream<AudioSetupState>.empty(), initialState: state);
}

void main() {
  late _MockAudioSetupCubit audio;
  late _MockLooperRepository repository;
  late TempoCubit tempo;

  setUp(() {
    audio = _MockAudioSetupCubit();
    _seed(audio, _fourOut);
    repository = _MockLooperRepository();
    when(
      () => repository.looperState,
    ).thenAnswer((_) => const Stream<LooperState>.empty());
    when(() => repository.setClickOutput(any())).thenReturn(EngineResult.ok);
    when(() => repository.setClickVolume(any())).thenReturn(EngineResult.ok);
    tempo = TempoCubit(
      repository: repository,
      settings: SettingsRepository(store: FakeKeyValueStore()),
    );
  });

  Future<void> pump(WidgetTester tester) => tester.pumpApp(
    MultiBlocProvider(
      providers: [
        BlocProvider<AudioSetupCubit>.value(value: audio),
        BlocProvider<TempoCubit>.value(value: tempo),
      ],
      child: const Scaffold(body: ClickOutputCard()),
    ),
  );

  ConsoleRow row(WidgetTester tester) => tester.widget<ConsoleRow>(
    find.byKey(const Key('audio_click_output_row')),
  );

  Finder chip(int index) => find.byKey(Key('audio_click_output_$index'));

  group('ClickOutputCard', () {
    testWidgets('rests shut, saying where the click goes', (tester) async {
      await pump(tester);

      expect(row(tester).state, 'nowhere');
      expect(row(tester).expanded, isFalse);
      expect(chip(0), findsNothing);
    });

    testWidgets('the row opens one chip per output and stays open across '
        'taps', (tester) async {
      await pump(tester);

      await tester.tap(find.byKey(const Key('audio_click_output_row')));
      await tester.pumpAndSettle();
      for (var i = 0; i < 4; i++) {
        expect(chip(i), findsOneWidget);
      }
      expect(chip(4), findsNothing);

      await tester.tap(chip(1));
      await tester.pumpAndSettle();
      expect(tempo.state.clickOutputMask, 0x2);
      verify(() => repository.setClickOutput(0x2)).called(1);
      // Not a pick-one: the grid is still there for the next bit.
      expect(row(tester).expanded, isTrue);
      expect(chip(0), findsOneWidget);

      await tester.tap(chip(0));
      await tester.pumpAndSettle();
      expect(tempo.state.clickOutputMask, 0x3);
      expect(row(tester).state, 'Out 1 · Out 2');

      // Tapping a lit chip clears its bit.
      await tester.tap(chip(1));
      await tester.pumpAndSettle();
      expect(tempo.state.clickOutputMask, 0x1);
      expect(row(tester).state, 'Out 1');
    });

    testWidgets('every output lit reads as all', (tester) async {
      await pump(tester);

      await tempo.setClickOutput(0xF);
      await tester.pump();
      expect(row(tester).state, 'all outputs');
    });

    testWidgets('more outputs than fit in the readout read as a count', (
      tester,
    ) async {
      _seed(
        audio,
        const AudioSetupState(
          engineStatus: EngineStatus(isConnected: true, outputChannels: 8),
        ),
      );
      await tempo.setClickOutput(0xF);
      await pump(tester);

      expect(row(tester).state, '4 outputs');
    });

    testWidgets('the bar maps its travel onto the gain ceiling', (
      tester,
    ) async {
      await pump(tester);
      final bar = tester.widget<ConsoleValueBar>(
        find.byKey(const Key('audio_click_volume')),
      );

      // Unity is half the bar, and where a double tap lands.
      expect(bar.value, 1 / kMaxClickGain);
      expect(bar.resetValue, 1 / kMaxClickGain);
      expect(bar.readout, '100%');
      expect(bar.semanticLabel, 'Click volume');
    });

    testWidgets('dragging the bar writes the volume', (tester) async {
      await pump(tester);
      final bar = find.byKey(const Key('audio_click_volume'));

      await tester.drag(bar, const Offset(-200, 0));
      await tester.pumpAndSettle();

      final written = verify(
        () => repository.setClickVolume(captureAny()),
      ).captured;
      expect(written, isNotEmpty);
      expect(written.last, lessThan(1));
      expect(tempo.state.clickVolume, written.last);
      expect(
        tester.widget<ConsoleValueBar>(bar).readout,
        '${(tempo.state.clickVolume * 100).round()}%',
      );
    });
  });
}
