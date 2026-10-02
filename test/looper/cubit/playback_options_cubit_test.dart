import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:segno/looper/looper.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/fake_key_value_store.dart';

class _MockLooperRepository extends Mock implements LooperRepository {}

void main() {
  late SettingsRepository settings;
  late LooperRepository repository;
  late StreamController<LooperState> looperStates;

  setUp(() {
    settings = SettingsRepository(store: FakeKeyValueStore());
    repository = _MockLooperRepository();
    when(() => repository.sessionRevision).thenReturn(0);
    when(() => repository.mixGeneration).thenReturn(0);
    when(() => repository.decayReplayResult).thenReturn(EngineResult.ok);
    var decay = 0;
    var once = false;
    final onceOverrides = <int, bool>{};
    when(() => repository.oneShotRecoveryRequired).thenReturn(false);
    when(() => repository.oneShotSettingsSettled).thenReturn(true);
    when(
      () => repository.settleOneShot(),
    ).thenAnswer((_) async => EngineResult.ok);
    when(
      () => repository.trackOneShotOverrides,
    ).thenAnswer((_) => Map.of(onceOverrides));
    when(() => repository.oneShotRestartIntent).thenAnswer(
      (_) => (defaultOneShot: once, trackOverrides: Map.of(onceOverrides)),
    );
    when(
      () => repository.setOneShotSnapshot(
        defaultOneShot: any(named: 'defaultOneShot'),
        trackOverrides: any(named: 'trackOverrides'),
      ),
    ).thenAnswer((call) {
      once = call.namedArguments[#defaultOneShot] as bool;
      onceOverrides
        ..clear()
        ..addAll(call.namedArguments[#trackOverrides] as Map<int, bool>);
      return EngineResult.ok;
    });

    final overrides = <int, int>{};
    when(() => repository.defaultOverdubDecay).thenAnswer((_) => decay);
    when(() => repository.defaultOneShot).thenAnswer((_) => once);
    when(
      () => repository.trackOverdubDecayOverrides,
    ).thenAnswer((_) => Map.of(overrides));
    when(() => repository.decayRestartIntent).thenAnswer(
      (_) => (defaultPercent: decay, trackOverrides: Map.of(overrides)),
    );
    when(() => repository.state).thenReturn(const LooperState());
    when(
      () => repository.setTrackOverdubDecay(
        channel: any(named: 'channel'),
        percent: any(named: 'percent'),
      ),
    ).thenAnswer((call) {
      final channel = call.namedArguments[#channel] as int;
      final percent = call.namedArguments[#percent] as int?;
      if (percent == null) {
        overrides.remove(channel);
      } else {
        overrides[channel] = percent;
      }
      return EngineResult.ok;
    });
    looperStates = StreamController<LooperState>.broadcast();
    when(() => repository.looperState).thenAnswer((_) => looperStates.stream);
    when(
      () => repository.setOverdubDecay(any()),
    ).thenAnswer((call) {
      decay = call.positionalArguments.single as int;
      return EngineResult.ok;
    });
    when(
      () => repository.setDefaultOneShot(
        oneShot: any(named: 'oneShot'),
        releasedOneShot: any(named: 'releasedOneShot'),
      ),
    ).thenAnswer((call) {
      once = call.namedArguments[#oneShot] as bool;
      return EngineResult.ok;
    });
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
      expect: () => [
        const PlaybackOptions(overdubDecay: 25, decayReady: true),
        const PlaybackOptions(
          overdubDecay: 25,
          decayReady: true,
          oneShotReady: true,
        ),
      ],
      verify: (_) => verify(() => repository.setOverdubDecay(25)).called(1),
    );

    blocTest<PlaybackOptionsCubit, PlaybackOptions>(
      'out-of-range Decay is refused without changing persistence or audio',
      build: build,
      act: (cubit) => cubit.setOverdubDecay(140),
      expect: () => <PlaybackOptions>[],
      verify: (_) async {
        expect(await settings.loadOverdubDecay(), 0);
        verifyNever(() => repository.setOverdubDecay(any()));
      },
    );

    blocTest<PlaybackOptionsCubit, PlaybackOptions>(
      'setOverdubDecay reapplies an explicit value even if the cache matches',
      build: build,
      act: (cubit) => cubit.setOverdubDecay(0),
      expect: () => [const PlaybackOptions(decayReady: true)],
      verify: (_) async {
        expect(await settings.loadOverdubDecay(), 0);
        verify(() => repository.setOverdubDecay(0)).called(2);
      },
    );

    blocTest<PlaybackOptionsCubit, PlaybackOptions>(
      'load restores the default Once behavior',
      setUp: () => settings.saveDefaultOneShot(oneShot: true),
      build: build,
      act: (cubit) => cubit.load(),
      expect: () => [
        const PlaybackOptions(decayReady: true),
        const PlaybackOptions(
          defaultOneShot: true,
          decayReady: true,
          oneShotReady: true,
        ),
      ],
      verify: (_) => verify(
        () => repository.setOneShotSnapshot(
          defaultOneShot: true,
          trackOverrides: any(named: 'trackOverrides'),
        ),
      ).called(1),
    );

    blocTest<PlaybackOptionsCubit, PlaybackOptions>(
      'setDefaultOneShot persists and reapplies a matching explicit value',
      build: build,
      act: (cubit) => cubit.setDefaultOneShot(value: false),
      expect: () => [const PlaybackOptions(oneShotReady: true)],
      verify: (_) async {
        expect(await settings.loadDefaultOneShot(), isFalse);
        verify(
          () => repository.setDefaultOneShot(
            oneShot: false,
          ),
        ).called(1);
      },
    );

    blocTest<PlaybackOptionsCubit, PlaybackOptions>(
      'refused Once changes leave the displayed and saved choice intact',
      setUp: () {
        when(
          () => repository.setDefaultOneShot(
            oneShot: true,
          ),
        ).thenReturn(EngineResult.invalid);
      },
      build: build,
      act: (cubit) => cubit.setDefaultOneShot(value: true),
      expect: () => [const PlaybackOptions(oneShotReady: true)],
      verify: (_) async => expect(await settings.loadDefaultOneShot(), isFalse),
    );

    blocTest<PlaybackOptionsCubit, PlaybackOptions>(
      'refused startup Once does not advertise the saved choice as applied',
      setUp: () async {
        await settings.saveDefaultOneShot(oneShot: true);
        when(
          () => repository.setOneShotSnapshot(
            defaultOneShot: true,
            trackOverrides: any(named: 'trackOverrides'),
          ),
        ).thenReturn(EngineResult.invalid);
      },
      build: build,
      act: (cubit) => cubit.load(),
      expect: () => [const PlaybackOptions(decayReady: true)],
      verify: (_) async => expect(await settings.loadDefaultOneShot(), isTrue),
    );

    blocTest<PlaybackOptionsCubit, PlaybackOptions>(
      'follows recalled and reset defaults without changing startup settings',
      setUp: () => settings.saveOverdubDecay(25),
      build: build,
      act: (cubit) async {
        await cubit.load();
        when(() => repository.defaultOverdubDecay).thenReturn(80);
        when(() => repository.defaultOneShot).thenReturn(true);
        looperStates.add(
          const LooperState(
            transport: TransportState(overdubDecay: 80, defaultOneShot: true),
          ),
        );
        await Future<void>.delayed(Duration.zero);
        when(() => repository.defaultOverdubDecay).thenReturn(0);
        when(() => repository.defaultOneShot).thenReturn(false);
        looperStates.add(const LooperState());
        await Future<void>.delayed(Duration.zero);
        await cubit.load();
      },
      expect: () => [
        const PlaybackOptions(overdubDecay: 25, decayReady: true),
        const PlaybackOptions(
          overdubDecay: 25,
          decayReady: true,
          oneShotReady: true,
        ),
        const PlaybackOptions(
          overdubDecay: 80,
          defaultOneShot: true,
          decayReady: true,
          oneShotReady: true,
        ),
        const PlaybackOptions(decayReady: true, oneShotReady: true),
      ],
      verify: (_) async {
        expect(await settings.loadOverdubDecay(), 25);
        expect(await settings.loadDefaultOneShot(), isFalse);
        verify(() => repository.setOverdubDecay(25)).called(1);
      },
    );
  });
}
