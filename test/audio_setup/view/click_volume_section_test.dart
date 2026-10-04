import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:segno/audio_setup/audio_setup.dart';
import 'package:segno/audio_setup/view/click_volume_section.dart';
import 'package:segno/looper/application/tempo_settings.dart';
import 'package:segno/looper/cubit/tempo_cubit.dart';
import 'package:segno/looper/model/click_volume.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

class _MockAudioSetupCubit extends MockCubit<AudioSetupState>
    implements AudioSetupCubit {}

/// A four-out interface reported by the engine, with nothing pinned.
const _fourOut = AudioSetupState(
  status: AudioSetupStatus.running,
  engineStatus: EngineStatus(isConnected: true, outputChannels: 4),
);

void main() {
  late TempoSettings tempoOwner;
  late _MockAudioSetupCubit audio;
  late LooperRepository repository;
  late TempoCubit tempo;

  setUp(() {
    audio = _MockAudioSetupCubit();
  });

  void seed(AudioSetupState state) {
    when(() => audio.state).thenReturn(state);
    whenListen(
      audio,
      const Stream<AudioSetupState>.empty(),
      initialState: state,
    );
  }

  Future<void> pump(WidgetTester tester) async {
    repository = LooperRepository(
      engine: FakeAudioEngine(),
      ticker: const Stream<void>.empty(),
    );
    tempoOwner = TempoSettings(
      repository: repository,
      settings: SettingsRepository(store: FakeKeyValueStore()),
    );
    final closeTempoOwner = tempoOwner.close;
    addTearDown(() => unawaited(closeTempoOwner()));
    tempo = TempoCubit(settings: tempoOwner);
    addTearDown(() => unawaited(tempo.close()));
    addTearDown(repository.dispose);
    unawaited(tempoOwner.load());
    await tester.pumpApp(
      MultiBlocProvider(
        providers: [
          BlocProvider<AudioSetupCubit>.value(value: audio),
          BlocProvider<TempoCubit>.value(value: tempo),
        ],
        child: const Material(
          child: SingleChildScrollView(child: ClickVolumeSection()),
        ),
      ),
    );
    await tester.pump();
  }

  group('ClickVolumeSection', () {
    testWidgets('says nothing about where the click goes: Audio routing owns '
        'that now', (tester) async {
      seed(_fourOut);
      await pump(tester);
      expect(
        find.byKey(const Key('audioSettings_clickOutput_0')),
        findsNothing,
      );
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

      // Dragging left from unity lowers the accepted deferred value.
      await tester.drag(slider, const Offset(-120, 0));
      await tester.pumpAndSettle();

      final written = repository.sessionTransport.clickVolume;
      expect(written, lessThan(1));
      expect(tempo.state.clickVolume, written);
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

      expect((await tempoOwner.setClickVolume(0.5)).isOk, isTrue);
      expect(tempo.state.clickVolume, .5);
      expect(repository.sessionTransport.clickVolume, .5);
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: readout, matching: find.text('50%')),
        findsOneWidget,
      );

      // The bar reaches the engine's +6 dB ceiling, not 100%.
      expect((await tempoOwner.setClickVolume(kMaxClickGain)).isOk, isTrue);
      expect(repository.sessionTransport.clickVolume, 2);
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: readout, matching: find.text('200%')),
        findsOneWidget,
      );
    });
  });
}
