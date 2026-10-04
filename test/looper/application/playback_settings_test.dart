import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:segno/looper/application/playback_settings.dart';
import 'package:segno/looper/model/playback_options.dart';
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

  PlaybackSettings build() =>
      PlaybackSettings(repository: repository, settings: settings);

  group('PlaybackSettings', () {
    test('defaults to no decay', () {
      expect(build().state, const PlaybackOptions());
    });

    test(
      'load restores the persisted decay and applies it to the repository',
      () async {
        await (() =>
            settings.restoreDecayCheckpoint(channel: null, percent: 25))();
        final owner = build();
        addTearDown(owner.close);
        final states = <PlaybackOptions>[];
        final subscription = owner.stream.listen(states.add);
        addTearDown(subscription.cancel);
        await ((PlaybackSettings cubit) => cubit.load())(owner);
        await Future<void>.delayed(Duration.zero);
        await owner.close();
        expect(
          states,
          (() => [
            const PlaybackOptions(overdubDecay: 25, decayReady: true),
            const PlaybackOptions(
              overdubDecay: 25,
              decayReady: true,
              oneShotReady: true,
            ),
          ])(),
        );
        ((_) => verify(() => repository.setOverdubDecay(25)).called(1))(owner);
      },
    );

    test(
      'out-of-range Decay is refused without changing persistence or audio',
      () async {
        final owner = build();
        addTearDown(owner.close);
        final states = <PlaybackOptions>[];
        final subscription = owner.stream.listen(states.add);
        addTearDown(subscription.cancel);
        await ((PlaybackSettings cubit) => cubit.setOverdubDecay(140))(owner);
        await Future<void>.delayed(Duration.zero);
        await owner.close();
        expect(states, (() => <PlaybackOptions>[])());
        await ((_) async {
          expect(await settings.readDecayCheckpoint(channel: null), isNull);
          verifyNever(() => repository.setOverdubDecay(any()));
        })(owner);
      },
    );

    test(
      'setOverdubDecay reapplies an explicit value even if the cache matches',
      () async {
        final owner = build();
        addTearDown(owner.close);
        final states = <PlaybackOptions>[];
        final subscription = owner.stream.listen(states.add);
        addTearDown(subscription.cancel);
        await ((PlaybackSettings cubit) => cubit.setOverdubDecay(0))(owner);
        await Future<void>.delayed(Duration.zero);
        await owner.close();
        expect(states, (() => [const PlaybackOptions(decayReady: true)])());
        await ((_) async {
          expect(await settings.readDecayCheckpoint(channel: null), 0);
          verify(() => repository.setOverdubDecay(0)).called(2);
        })(owner);
      },
    );

    test('load restores the default Once behavior', () async {
      await (() =>
          settings.restoreOneShotCheckpoint(channel: null, oneShot: true))();
      final owner = build();
      addTearDown(owner.close);
      final states = <PlaybackOptions>[];
      final subscription = owner.stream.listen(states.add);
      addTearDown(subscription.cancel);
      await ((PlaybackSettings cubit) => cubit.load())(owner);
      await Future<void>.delayed(Duration.zero);
      await owner.close();
      expect(
        states,
        (() => [
          const PlaybackOptions(decayReady: true),
          const PlaybackOptions(
            defaultOneShot: true,
            decayReady: true,
            oneShotReady: true,
          ),
        ])(),
      );
      ((_) => verify(
        () => repository.setOneShotSnapshot(
          defaultOneShot: true,
          trackOverrides: any(named: 'trackOverrides'),
        ),
      ).called(1))(owner);
    });

    test(
      'setDefaultOneShot persists and reapplies a matching explicit value',
      () async {
        final owner = build();
        addTearDown(owner.close);
        final states = <PlaybackOptions>[];
        final subscription = owner.stream.listen(states.add);
        addTearDown(subscription.cancel);
        await ((PlaybackSettings cubit) =>
            cubit.setDefaultOneShot(value: false))(owner);
        await Future<void>.delayed(Duration.zero);
        await owner.close();
        expect(states, (() => [const PlaybackOptions(oneShotReady: true)])());
        await ((_) async {
          expect(await settings.readOneShotCheckpoint(channel: null), isFalse);
          verify(
            () => repository.setDefaultOneShot(
              oneShot: false,
            ),
          ).called(1);
        })(owner);
      },
    );

    test(
      'refused Once changes leave the displayed and saved choice intact',
      () async {
        await (() {
          when(
            () => repository.setDefaultOneShot(
              oneShot: true,
            ),
          ).thenReturn(EngineResult.invalid);
        })();
        final owner = build();
        addTearDown(owner.close);
        final states = <PlaybackOptions>[];
        final subscription = owner.stream.listen(states.add);
        addTearDown(subscription.cancel);
        await ((PlaybackSettings cubit) =>
            cubit.setDefaultOneShot(value: true))(owner);
        await Future<void>.delayed(Duration.zero);
        await owner.close();
        expect(states, (() => [const PlaybackOptions(oneShotReady: true)])());
        await ((_) async => expect(
          await settings.readOneShotCheckpoint(channel: null),
          isNull,
        ))(owner);
      },
    );

    test(
      'refused startup Once does not advertise the saved choice as applied',
      () async {
        await (() async {
          await settings.restoreOneShotCheckpoint(channel: null, oneShot: true);
          when(
            () => repository.setOneShotSnapshot(
              defaultOneShot: true,
              trackOverrides: any(named: 'trackOverrides'),
            ),
          ).thenReturn(EngineResult.invalid);
        })();
        final owner = build();
        addTearDown(owner.close);
        final states = <PlaybackOptions>[];
        final subscription = owner.stream.listen(states.add);
        addTearDown(subscription.cancel);
        await ((PlaybackSettings cubit) => cubit.load())(owner);
        await Future<void>.delayed(Duration.zero);
        await owner.close();
        expect(states, (() => [const PlaybackOptions(decayReady: true)])());
        await ((_) async => expect(
          await settings.readOneShotCheckpoint(channel: null),
          isTrue,
        ))(owner);
      },
    );

    test(
      'follows recalled and reset defaults without changing startup settings',
      () async {
        await (() =>
            settings.restoreDecayCheckpoint(channel: null, percent: 25))();
        final owner = build();
        addTearDown(owner.close);
        final states = <PlaybackOptions>[];
        final subscription = owner.stream.listen(states.add);
        addTearDown(subscription.cancel);
        await ((PlaybackSettings cubit) async {
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
        })(owner);
        await Future<void>.delayed(Duration.zero);
        await owner.close();
        expect(
          states,
          (() => [
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
          ])(),
        );
        await ((_) async {
          expect(await settings.readDecayCheckpoint(channel: null), 25);
          expect(await settings.readOneShotCheckpoint(channel: null), isNull);
          verify(() => repository.setOverdubDecay(25)).called(1);
        })(owner);
      },
    );
  });
}
