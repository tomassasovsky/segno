import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:segno/audio_setup/audio_setup.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

class _MockLooperRepository extends Mock implements LooperRepository {}

void main() {
  setUpAll(() {
    registerFallbackValue(InputConditioningParam.hpfHz);
  });

  late SettingsRepository settings;
  late LooperRepository repository;

  setUp(() {
    settings = SettingsRepository(store: FakeKeyValueStore());
    repository = _MockLooperRepository();
    when(
      () => repository.setInputConditioningEnabled(
        input: any(named: 'input'),
        enabled: any(named: 'enabled'),
      ),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.setInputConditioningParam(
        input: any(named: 'input'),
        param: any(named: 'param'),
        value: any(named: 'value'),
      ),
    ).thenReturn(EngineResult.ok);
  });

  InputConditioningCubit build() =>
      InputConditioningCubit(repository: repository, settings: settings);

  group('InputConditioningCubit', () {
    test('starts with no configured inputs', () {
      expect(build().state, const InputConditioningState());
      expect(build().state.forInput(0), const InputConditioning(input: 0));
      expect(build().state.hasInput(0), isFalse);
    });

    test('forInput synthesizes the documented defaults', () {
      const config = InputConditioning(input: 2);
      expect(config.enabled, isFalse);
      expect(config.hpfHz, 40);
      expect(config.humHz, 50);
      expect(config.humHarmonics, 4);
      expect(config.expThresholdDb, -55);
      expect(config.expRatio, 2);
      expect(config.expReleaseMs, 150);
      expect(config.restoreFlags, 0);
    });

    blocTest<InputConditioningCubit, InputConditioningState>(
      'load restores a persisted input and applies its conditioning',
      setUp: () async {
        await settings.saveInputConditioningEnabled(1, enabled: true);
        await settings.saveInputConditioningHpfHz(1, 80);
        await settings.saveInputConditioningHumHz(1, 60);
        await settings.saveInputConditioningHumHarmonics(1, 6);
        await settings.saveInputConditioningExpThresholdDb(1, -48);
        await settings.saveInputConditioningExpRatio(1, 3);
        await settings.saveInputConditioningExpReleaseMs(1, 220);
        await settings.saveInputRestore(1, 3);
      },
      build: build,
      act: (cubit) => cubit.load(),
      expect: () => [
        const InputConditioningState(
          inputs: {
            1: InputConditioning(
              input: 1,
              enabled: true,
              hpfHz: 80,
              humHz: 60,
              humHarmonics: 6,
              expThresholdDb: -48,
              expRatio: 3,
              expReleaseMs: 220,
              restoreDeclip: true,
              restoreDenoise: true,
            ),
          },
        ),
      ],
      verify: (_) {
        verify(
          () => repository.setInputConditioningEnabled(input: 1, enabled: true),
        ).called(1);
        verify(
          () => repository.setInputConditioningParam(
            input: 1,
            param: InputConditioningParam.hpfHz,
            value: 80,
          ),
        ).called(1);
        verify(
          () => repository.setInputConditioningParam(
            input: 1,
            param: InputConditioningParam.expRatio,
            value: 3,
          ),
        ).called(1);
      },
    );

    blocTest<InputConditioningCubit, InputConditioningState>(
      'load materializes no input when nothing was ever saved',
      build: build,
      act: (cubit) => cubit.load(),
      expect: () => <InputConditioningState>[],
      verify: (_) {
        verifyNever(
          () => repository.setInputConditioningEnabled(
            input: any(named: 'input'),
            enabled: any(named: 'enabled'),
          ),
        );
      },
    );

    blocTest<InputConditioningCubit, InputConditioningState>(
      'setEnabled emits, applies to the repository, and persists',
      build: build,
      act: (cubit) => cubit.setEnabled(0, enabled: true),
      expect: () => [
        const InputConditioningState(
          inputs: {0: InputConditioning(input: 0, enabled: true)},
        ),
      ],
      verify: (_) async {
        verify(
          () => repository.setInputConditioningEnabled(input: 0, enabled: true),
        ).called(1);
        expect(await settings.loadInputConditioningEnabled(0), isTrue);
      },
    );

    blocTest<InputConditioningCubit, InputConditioningState>(
      'setHpfHz applies the param with its real-unit value and persists',
      build: build,
      act: (cubit) => cubit.setHpfHz(0, 120),
      expect: () => [
        const InputConditioningState(
          inputs: {0: InputConditioning(input: 0, hpfHz: 120)},
        ),
      ],
      verify: (_) async {
        verify(
          () => repository.setInputConditioningParam(
            input: 0,
            param: InputConditioningParam.hpfHz,
            value: 120,
          ),
        ).called(1);
        expect(await settings.loadInputConditioningHpfHz(0), 120);
      },
    );

    blocTest<InputConditioningCubit, InputConditioningState>(
      'setHumHarmonics converts the int to the param real-unit value',
      build: build,
      act: (cubit) => cubit.setHumHarmonics(1, 6),
      expect: () => [
        const InputConditioningState(
          inputs: {1: InputConditioning(input: 1, humHarmonics: 6)},
        ),
      ],
      verify: (_) async {
        verify(
          () => repository.setInputConditioningParam(
            input: 1,
            param: InputConditioningParam.humHarmonics,
            value: 6,
          ),
        ).called(1);
        expect(await settings.loadInputConditioningHumHarmonics(1), 6);
      },
    );

    blocTest<InputConditioningCubit, InputConditioningState>(
      'setRestore persists the flag bitmask and touches no engine path',
      build: build,
      act: (cubit) => cubit.setRestore(2, declip: true, denoise: false),
      expect: () => [
        const InputConditioningState(
          inputs: {2: InputConditioning(input: 2, restoreDeclip: true)},
        ),
      ],
      verify: (_) async {
        // The restore opt-in drives an OFFLINE pass, so nothing is pushed to
        // the live conditioning path.
        verifyNever(
          () => repository.setInputConditioningEnabled(
            input: any(named: 'input'),
            enabled: any(named: 'enabled'),
          ),
        );
        // declip = bit 2, denoise off = bit 1 clear.
        expect(await settings.loadInputRestore(2), 2);
      },
    );

    test('setRestore encodes denoise as bit 1 and declip as bit 2', () async {
      final cubit = build();
      await cubit.setRestore(0, declip: false, denoise: true);
      expect(await settings.loadInputRestore(0), 1);
      await cubit.setRestore(0, declip: true, denoise: true);
      expect(await settings.loadInputRestore(0), 3);
    });
  });
}
