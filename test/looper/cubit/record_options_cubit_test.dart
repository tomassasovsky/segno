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
    when(
      () => repository.setRecDub(enabled: any(named: 'enabled')),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.setAutoRecord(enabled: any(named: 'enabled')),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.setDefaultMultiple(multiple: any(named: 'multiple')),
    ).thenReturn(EngineResult.ok);
    looperStates = StreamController<LooperState>.broadcast();
    when(() => repository.looperState).thenAnswer((_) => looperStates.stream);
  });

  tearDown(() => looperStates.close());

  RecordOptionsCubit build() =>
      RecordOptionsCubit(repository: repository, settings: settings);

  group('RecordOptionsCubit', () {
    test('defaults to both off', () {
      expect(build().state, const RecordOptions());
    });

    blocTest<RecordOptionsCubit, RecordOptions>(
      'load restores persisted options and applies them',
      setUp: () async {
        await settings.saveRecDub(value: true);
        await settings.saveAutoRecord(value: true);
      },
      build: build,
      act: (cubit) => cubit.load(),
      expect: () => [const RecordOptions(recDub: true)],
      verify: (_) {
        verify(() => repository.setRecDub(enabled: true)).called(1);
        verifyNever(
          () => repository.setAutoRecord(enabled: any(named: 'enabled')),
        );
      },
    );

    blocTest<RecordOptionsCubit, RecordOptions>(
      'setRecDub emits, applies, and persists',
      build: build,
      act: (cubit) => cubit.setRecDub(value: true),
      expect: () => [const RecordOptions(recDub: true)],
      verify: (_) async {
        verify(() => repository.setRecDub(enabled: true)).called(1);
        expect(await settings.loadRecDub(), isTrue);
      },
    );

    blocTest<RecordOptionsCubit, RecordOptions>(
      'setAutoRecord emits, applies, and persists',
      build: build,
      act: (cubit) => cubit.setAutoRecord(value: true),
      expect: () => [const RecordOptions(autoRecord: true)],
      verify: (_) async {
        verify(() => repository.setAutoRecord(enabled: true)).called(1);
        expect(await settings.loadAutoRecord(), isTrue);
      },
    );

    blocTest<RecordOptionsCubit, RecordOptions>(
      'setDefaultMultiple emits, applies, and persists',
      build: build,
      act: (cubit) => cubit.setDefaultMultiple(2),
      expect: () => [const RecordOptions(defaultMultiple: 2)],
      verify: (_) async {
        verify(() => repository.setDefaultMultiple(multiple: 2)).called(1);
        expect(await settings.loadDefaultMultiple(), 2);
      },
    );
    blocTest<RecordOptionsCubit, RecordOptions>(
      'turning Sound start on persists the count-in as off (the engine '
      'clears it, D9)',
      setUp: () => settings.saveCountInBars(2),
      build: build,
      act: (cubit) => cubit.setAutoRecord(value: true),
      expect: () => [const RecordOptions(autoRecord: true)],
      verify: (_) async {
        expect(await settings.loadAutoRecord(), isTrue);
        expect(await settings.loadCountInBars(), 0);
      },
    );

    blocTest<RecordOptionsCubit, RecordOptions>(
      'follows repository Sound start changes without persisting a recall',
      setUp: () => settings.saveAutoRecord(value: true),
      build: build,
      act: (cubit) async {
        await cubit.load();
        looperStates.add(
          const LooperState(transport: TransportState(autoRecord: true)),
        );
        await Future<void>.delayed(Duration.zero);
        looperStates.add(
          const LooperState(transport: TransportState(countInBars: 1)),
        );
        await Future<void>.delayed(Duration.zero);
      },
      expect: () => [
        const RecordOptions(),
        const RecordOptions(autoRecord: true),
        const RecordOptions(),
      ],
      verify: (_) async => expect(await settings.loadAutoRecord(), isTrue),
    );

    blocTest<RecordOptionsCubit, RecordOptions>(
      'follows the repository before load without overwriting saved defaults',
      setUp: () => settings.saveAutoRecord(value: true),
      build: build,
      act: (cubit) async {
        looperStates.add(const LooperState());
        await Future<void>.delayed(Duration.zero);
      },
      expect: () => [const RecordOptions()],
      verify: (_) async => expect(await settings.loadAutoRecord(), isTrue),
    );

    blocTest<RecordOptionsCubit, RecordOptions>(
      'explicit matching values still reach the repository',
      build: build,
      act: (cubit) async {
        await cubit.setRecDub(value: false);
        await cubit.setAutoRecord(value: false);
        await cubit.setDefaultMultiple(0);
      },
      expect: () => [const RecordOptions()],
      verify: (_) {
        verify(() => repository.setRecDub(enabled: false)).called(1);
        verify(() => repository.setAutoRecord(enabled: false)).called(1);
        verify(() => repository.setDefaultMultiple(multiple: 0)).called(1);
      },
    );

    blocTest<RecordOptionsCubit, RecordOptions>(
      'refused edits preserve displayed choices and both saved start methods',
      setUp: () async {
        await settings.saveCountInBars(2);
        when(
          () => repository.setRecDub(enabled: true),
        ).thenReturn(EngineResult.invalid);
        when(
          () => repository.setAutoRecord(enabled: true),
        ).thenReturn(EngineResult.invalid);
        when(
          () => repository.setDefaultMultiple(multiple: 2),
        ).thenReturn(EngineResult.invalid);
      },
      build: build,
      act: (cubit) async {
        await cubit.setRecDub(value: true);
        await cubit.setAutoRecord(value: true);
        await cubit.setDefaultMultiple(2);
      },
      expect: () => <RecordOptions>[],
      verify: (_) async {
        expect(await settings.loadRecDub(), isFalse);
        expect(await settings.loadAutoRecord(), isFalse);
        expect(await settings.loadDefaultMultiple(), 0);
        expect(await settings.loadCountInBars(), 2);
      },
    );

    blocTest<RecordOptionsCubit, RecordOptions>(
      'follows recalled and reset recording defaults',
      build: build,
      act: (_) async {
        looperStates.add(
          const LooperState(
            transport: TransportState(
              recDub: true,
              autoRecord: true,
              defaultMultiple: 3,
            ),
          ),
        );
        await Future<void>.delayed(Duration.zero);
        looperStates.add(const LooperState());
        await Future<void>.delayed(Duration.zero);
      },
      expect: () => [
        const RecordOptions(recDub: true, autoRecord: true, defaultMultiple: 3),
        const RecordOptions(),
      ],
      verify: (_) async {
        expect(await settings.loadRecDub(), isFalse);
        expect(await settings.loadDefaultMultiple(), 0);
      },
    );
  });
}
