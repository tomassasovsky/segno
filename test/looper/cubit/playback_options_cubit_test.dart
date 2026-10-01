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
      () => repository.setOverdubDecay(any()),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.setDefaultOneShot(oneShot: any(named: 'oneShot')),
    ).thenReturn(EngineResult.ok);
  });

  tearDown(() => looperStates.close());

  PlaybackOptionsCubit build() =>
      PlaybackOptionsCubit(repository: repository, settings: settings);

  group('PlaybackOptionsCubit', () {
    test('defaults to no decay', () {
      expect(build().state, const PlaybackOptions());
    });

    blocTest<PlaybackOptionsCubit, PlaybackOptions>(
      'load restores the persisted decay and applies it to the repository',
      setUp: () => settings.saveOverdubDecay(25),
      build: build,
      act: (cubit) => cubit.load(),
      expect: () => [const PlaybackOptions(overdubDecay: 25)],
      verify: (_) => verify(() => repository.setOverdubDecay(25)).called(1),
    );

    blocTest<PlaybackOptionsCubit, PlaybackOptions>(
      'setOverdubDecay emits, persists and applies the clamped value',
      build: build,
      act: (cubit) => cubit.setOverdubDecay(140),
      expect: () => [const PlaybackOptions(overdubDecay: 100)],
      verify: (_) async {
        expect(await settings.loadOverdubDecay(), 100);
        verify(() => repository.setOverdubDecay(100)).called(1);
      },
    );

    blocTest<PlaybackOptionsCubit, PlaybackOptions>(
      'setOverdubDecay reapplies an explicit value even if the cache matches',
      build: build,
      act: (cubit) => cubit.setOverdubDecay(0),
      expect: () => [const PlaybackOptions()],
      verify: (_) async {
        expect(await settings.loadOverdubDecay(), 0);
        verify(() => repository.setOverdubDecay(0)).called(1);
      },
    );

    blocTest<PlaybackOptionsCubit, PlaybackOptions>(
      'load restores the default Once behavior',
      setUp: () => settings.saveDefaultOneShot(oneShot: true),
      build: build,
      act: (cubit) => cubit.load(),
      expect: () => [const PlaybackOptions(defaultOneShot: true)],
      verify: (_) => verify(
        () => repository.setDefaultOneShot(oneShot: true),
      ).called(1),
    );

    blocTest<PlaybackOptionsCubit, PlaybackOptions>(
      'setDefaultOneShot persists and reapplies a matching explicit value',
      build: build,
      act: (cubit) => cubit.setDefaultOneShot(value: false),
      expect: () => [const PlaybackOptions()],
      verify: (_) async {
        expect(await settings.loadDefaultOneShot(), isFalse);
        verify(() => repository.setDefaultOneShot(oneShot: false)).called(1);
      },
    );

    blocTest<PlaybackOptionsCubit, PlaybackOptions>(
      'refused Once changes leave the displayed and saved choice intact',
      setUp: () {
        when(
          () => repository.setDefaultOneShot(oneShot: true),
        ).thenReturn(EngineResult.invalid);
      },
      build: build,
      act: (cubit) => cubit.setDefaultOneShot(value: true),
      expect: () => <PlaybackOptions>[],
      verify: (_) async => expect(await settings.loadDefaultOneShot(), isFalse),
    );

    blocTest<PlaybackOptionsCubit, PlaybackOptions>(
      'refused startup Once does not advertise the saved choice as applied',
      setUp: () async {
        await settings.saveDefaultOneShot(oneShot: true);
        when(
          () => repository.setDefaultOneShot(oneShot: true),
        ).thenReturn(EngineResult.invalid);
      },
      build: build,
      act: (cubit) => cubit.load(),
      expect: () => [const PlaybackOptions()],
      verify: (_) async => expect(await settings.loadDefaultOneShot(), isTrue),
    );

    blocTest<PlaybackOptionsCubit, PlaybackOptions>(
      'follows recalled and reset defaults without changing startup settings',
      setUp: () => settings.saveOverdubDecay(25),
      build: build,
      act: (cubit) async {
        await cubit.load();
        looperStates.add(
          const LooperState(
            transport: TransportState(overdubDecay: 80, defaultOneShot: true),
          ),
        );
        await Future<void>.delayed(Duration.zero);
        looperStates.add(const LooperState());
        await Future<void>.delayed(Duration.zero);
        await cubit.load();
      },
      expect: () => [
        const PlaybackOptions(overdubDecay: 25),
        const PlaybackOptions(overdubDecay: 80, defaultOneShot: true),
        const PlaybackOptions(),
      ],
      verify: (_) async {
        expect(await settings.loadOverdubDecay(), 25);
        expect(await settings.loadDefaultOneShot(), isFalse);
        verify(() => repository.setOverdubDecay(25)).called(1);
      },
    );
  });
}
