import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:segno/looper/looper.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

class _MockLooperRepository extends Mock implements LooperRepository {}

void main() {
  late SettingsRepository settings;
  late LooperRepository repository;
  late StreamController<LooperState> looperStates;

  setUp(() {
    settings = SettingsRepository(store: FakeKeyValueStore());
    repository = _MockLooperRepository();
    when(() => repository.sessionRevision).thenReturn(0);
    looperStates = StreamController<LooperState>.broadcast();
    when(() => repository.looperState).thenAnswer((_) => looperStates.stream);
    when(
      () => repository.setQuantize(enabled: any(named: 'enabled')),
    ).thenReturn(EngineResult.ok);
  });

  tearDown(() => looperStates.close());

  group('QuantizeCubit', () {
    test('defaults to off', () {
      final cubit = QuantizeCubit(repository: repository, settings: settings);
      expect(cubit.state, isFalse);
    });

    blocTest<QuantizeCubit, bool>(
      'load restores the persisted value and applies it to the repository',
      setUp: () => settings.saveQuantize(value: true),
      build: () => QuantizeCubit(repository: repository, settings: settings),
      act: (cubit) => cubit.load(),
      expect: () => [true],
      verify: (_) =>
          verify(() => repository.setQuantize(enabled: true)).called(1),
    );

    blocTest<QuantizeCubit, bool>(
      'setEnabled emits, persists, and applies the new value',
      build: () => QuantizeCubit(repository: repository, settings: settings),
      act: (cubit) => cubit.setEnabled(value: true),
      expect: () => [true],
      verify: (_) async {
        expect(await settings.loadQuantize(), isTrue);
        verify(() => repository.setQuantize(enabled: true)).called(1);
      },
    );

    blocTest<QuantizeCubit, bool>(
      'setEnabled reapplies an explicit value even if the cache matches',
      build: () => QuantizeCubit(repository: repository, settings: settings),
      act: (cubit) => cubit.setEnabled(value: false),
      expect: () => [false],
      verify: (_) async {
        expect(await settings.loadQuantize(), isFalse);
        verify(() => repository.setQuantize(enabled: false)).called(1);
      },
    );

    blocTest<QuantizeCubit, bool>(
      'a refused edit preserves the displayed and saved value',
      setUp: () {
        when(
          () => repository.setQuantize(enabled: true),
        ).thenReturn(EngineResult.invalid);
      },
      build: () => QuantizeCubit(repository: repository, settings: settings),
      act: (cubit) => cubit.setEnabled(value: true),
      expect: () => <bool>[],
      verify: (_) async => expect(await settings.loadQuantize(), isFalse),
    );

    blocTest<QuantizeCubit, bool>(
      'follows recall and reset without changing startup settings',
      setUp: () => settings.saveQuantize(value: true),
      build: () => QuantizeCubit(repository: repository, settings: settings),
      act: (cubit) async {
        await cubit.load();
        looperStates.add(const LooperState());
        await Future<void>.delayed(Duration.zero);
        await cubit.load();
        await cubit.toggle();
      },
      expect: () => [true, false, true],
      verify: (_) async {
        expect(await settings.loadQuantize(), isTrue);
        verify(() => repository.setQuantize(enabled: true)).called(2);
      },
    );
  });
}
