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

  setUp(() {
    settings = SettingsRepository(store: FakeKeyValueStore());
    repository = _MockLooperRepository();
    when(
      () => repository.setOverdubDecay(any()),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.setDefaultOnce(once: any(named: 'once')),
    ).thenReturn(EngineResult.ok);
  });

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
      'load restores the persisted default Once and applies it',
      setUp: () => settings.saveDefaultOnce(value: true),
      build: build,
      act: (cubit) => cubit.load(),
      expect: () => [const PlaybackOptions(once: true)],
      verify: (_) =>
          verify(() => repository.setDefaultOnce(once: true)).called(1),
    );

    blocTest<PlaybackOptionsCubit, PlaybackOptions>(
      'setOnce emits, persists and applies the default',
      build: build,
      act: (cubit) => cubit.setOnce(value: true),
      expect: () => [const PlaybackOptions(once: true)],
      verify: (_) async {
        expect(await settings.loadDefaultOnce(), isTrue);
        verify(() => repository.setDefaultOnce(once: true)).called(1);
      },
    );

    blocTest<PlaybackOptionsCubit, PlaybackOptions>(
      'setOverdubDecay to the current value persists but emits nothing new',
      build: build,
      act: (cubit) => cubit.setOverdubDecay(0),
      expect: () => <PlaybackOptions>[],
      verify: (_) async {
        expect(await settings.loadOverdubDecay(), 0);
        verifyNever(() => repository.setOverdubDecay(any()));
      },
    );
  });
}
