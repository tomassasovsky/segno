import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:segno/audio_setup/audio_setup.dart';
import 'package:segno/audio_setup/view/click_output_section.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/cubit/tempo_cubit.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

class _MockAudioSetupCubit extends MockCubit<AudioSetupState>
    implements AudioSetupCubit {}

class _MockLooperRepository extends Mock implements LooperRepository {}

/// A four-out interface reported by the engine, with nothing pinned.
const _fourOut = AudioSetupState(
  status: AudioSetupStatus.running,
  engineStatus: EngineStatus(isConnected: true, outputChannels: 4),
);

/// A pinned 20-out Scarlett the engine has NOT opened yet.
const _pinnedScarlett = AudioSetupState(
  playbackDeviceId: 'scarlett-out',
  devices: [
    AudioDevice(
      id: 'scarlett-out',
      name: 'Scarlett 18i20',
      isDefault: false,
      isInput: false,
      outputChannels: 20,
    ),
  ],
);

void main() {
  late _MockAudioSetupCubit audio;
  late _MockLooperRepository repository;
  late TempoCubit tempo;

  setUp(() {
    audio = _MockAudioSetupCubit();
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

  void seed(AudioSetupState state) {
    when(() => audio.state).thenReturn(state);
    whenListen(
      audio,
      const Stream<AudioSetupState>.empty(),
      initialState: state,
    );
  }

  Future<void> pump(WidgetTester tester) => tester.pumpApp(
    MultiBlocProvider(
      providers: [
        BlocProvider<AudioSetupCubit>.value(value: audio),
        BlocProvider<TempoCubit>.value(value: tempo),
      ],
      child: const Material(
        child: SingleChildScrollView(child: ClickOutputSection()),
      ),
    ),
  );

  Finder chip(int index) => find.byKey(Key('audioSettings_clickOutput_$index'));

  group('clickOutputCount', () {
    test('takes the pinned device over the engine and stereo last', () {
      expect(clickOutputCount(_pinnedScarlett), 20);
      expect(clickOutputCount(_fourOut), 4);
      // A stopped engine with nothing pinned reports no outputs, and a click
      // with nowhere to go is not a useful thing to draw.
      expect(clickOutputCount(const AudioSetupState()), 2);
    });
  });

  group('clickOutputSummary', () {
    testWidgets('names a few outputs, counts many, and has words for the '
        'edges', (tester) async {
      seed(_fourOut);
      await pump(tester);
      final l10n = AppLocalizations.of(
        tester.element(find.byType(ClickOutputSection)),
      );

      expect(clickOutputSummary(l10n, mask: 0, outputs: 4), 'nowhere');
      expect(clickOutputSummary(l10n, mask: 0xF, outputs: 4), 'all outputs');
      expect(
        clickOutputSummary(l10n, mask: 0x5, outputs: 4),
        'Out 1 · Out 3',
      );
      expect(clickOutputSummary(l10n, mask: 0xF, outputs: 6), '4 outputs');
      // Bits above the rig's own outputs do not make it "all".
      expect(
        clickOutputSummary(l10n, mask: 0x13, outputs: 4),
        'Out 1 · Out 2',
      );
    });
  });

  group('ClickOutputSection', () {
    testWidgets('draws one chip per hardware output', (tester) async {
      seed(_fourOut);
      await pump(tester);

      for (var i = 0; i < 4; i++) {
        expect(chip(i), findsOneWidget);
      }
      expect(chip(4), findsNothing);
    });

    testWidgets('a pinned device sets the width before the engine opens it', (
      tester,
    ) async {
      seed(_pinnedScarlett);
      await pump(tester);

      expect(chip(19), findsOneWidget);
      expect(chip(20), findsNothing);
    });

    testWidgets('tapping a chip toggles that bit through the cubit', (
      tester,
    ) async {
      seed(_fourOut);
      await pump(tester);

      await tester.tap(chip(0));
      await tester.pumpAndSettle();
      expect(tempo.state.clickOutputMask, 0x1);
      verify(() => repository.setClickOutput(0x1)).called(1);

      await tester.tap(chip(2));
      await tester.pumpAndSettle();
      expect(tempo.state.clickOutputMask, 0x5);
      verify(() => repository.setClickOutput(0x5)).called(1);

      // A second tap clears the bit rather than replacing the answer.
      await tester.tap(chip(0));
      await tester.pumpAndSettle();
      expect(tempo.state.clickOutputMask, 0x4);
      verify(() => repository.setClickOutput(0x4)).called(1);
    });

    testWidgets('the slider spans the engine gain ceiling and writes through', (
      tester,
    ) async {
      seed(_fourOut);
      await pump(tester);

      final slider = find.byKey(const Key('audioSettings_clickVolume_slider'));
      expect(tester.widget<Slider>(slider).max, kMaxClickGain);
      // The cubit starts at unity, which is half the travel.
      expect(tester.widget<Slider>(slider).value, 1);

      // Dragging left from unity lowers it; a drag fires onChanged more than
      // once, so only the last write is pinned down.
      await tester.drag(slider, const Offset(-120, 0));
      await tester.pumpAndSettle();

      final written = verify(
        () => repository.setClickVolume(captureAny()),
      ).captured;
      expect(written, isNotEmpty);
      expect(written.last, lessThan(1));
      expect(tempo.state.clickVolume, written.last);
    });

    testWidgets('the readout is percent of unity', (tester) async {
      seed(_fourOut);
      await pump(tester);
      final readout = find.byKey(
        const Key('audioSettings_clickVolume_readout'),
      );
      expect(
        find.descendant(of: readout, matching: find.text('100%')),
        findsOneWidget,
      );

      await tempo.setClickVolume(0.5);
      await tester.pump();
      expect(
        find.descendant(of: readout, matching: find.text('50%')),
        findsOneWidget,
      );

      // The bar reaches the engine's +6 dB ceiling, not 100%.
      await tempo.setClickVolume(kMaxClickGain);
      await tester.pump();
      expect(
        find.descendant(of: readout, matching: find.text('200%')),
        findsOneWidget,
      );
    });
  });
}
