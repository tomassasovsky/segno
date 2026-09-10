import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:segno/audio_setup/cubit/outputs_cubit.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

class _MockLooperRepository extends Mock implements LooperRepository {}

/// The engine with an interface open. The device NAME is the key the names are
/// stored against, so a test that never opens one can never store a name.
const _scarlett = LooperState(
  status: EngineStatus(
    isConnected: true,
    deviceName: 'Scarlett 18i20',
    sampleRate: 48000,
    outputChannels: 20,
  ),
);

const _builtIn = LooperState(
  status: EngineStatus(
    isConnected: true,
    deviceName: 'Built-in audio',
    sampleRate: 48000,
    outputChannels: 2,
  ),
);

void main() {
  late SettingsRepository settings;
  late _MockLooperRepository repository;
  late StreamController<LooperState> engine;

  setUp(() {
    settings = SettingsRepository(store: FakeKeyValueStore());
    repository = _MockLooperRepository();
    engine = StreamController<LooperState>.broadcast();
    addTearDown(engine.close);
    when(() => repository.looperState).thenAnswer((_) => engine.stream);
    when(() => repository.state).thenReturn(_scarlett);
  });

  OutputsCubit build() {
    final cubit = OutputsCubit(settings: settings, repository: repository);
    addTearDown(cubit.close);
    return cubit;
  }

  /// Lets the constructor's own device read land before the test asserts.
  Future<void> settle() => pumpEventQueue();

  group('OutputsCubit', () {
    test('adopts the device the engine already has open', () async {
      final cubit = build();
      await settle();
      expect(cubit.state.device, 'Scarlett 18i20');
      expect(cubit.state.names, isEmpty);
      expect(cubit.state.namedCount(10), 0);
      expect(cubit.state.isNamed(0), isFalse);
    });

    test('rename trims, persists against the DEVICE, and counts', () async {
      final cubit = build();
      await settle();

      await cubit.rename(1, '  monitors  ');
      expect(cubit.state.nameOf(1), 'monitors');
      expect(cubit.state.namedCount(10), 1);
      expect(
        await settings.loadOutputName(device: 'Scarlett 18i20', bus: 1),
        'monitors',
      );
      expect(
        await settings.loadOutputName(device: 'Built-in audio', bus: 1),
        isNull,
      );
    });

    test('a name is kept per DESTINATION, not per jack', () async {
      // Bus 1 is outputs 3 and 4. Naming it must not touch bus 3's key, which
      // an implementation keyed by channel number would collide with.
      final cubit = build();
      await settle();
      await cubit.rename(1, 'monitors');

      expect(
        await settings.loadOutputName(device: 'Scarlett 18i20', bus: 3),
        isNull,
      );
      expect(cubit.state.isNamed(3), isFalse);
    });

    test('a different interface has its own names', () async {
      final cubit = build();
      await settle();
      await cubit.rename(0, 'mains');

      engine.add(_builtIn);
      await settle();
      expect(cubit.state.device, 'Built-in audio');
      expect(cubit.state.nameOf(0), isEmpty);

      await cubit.rename(0, 'laptop');
      engine.add(_scarlett);
      await settle();
      expect(cubit.state.nameOf(0), 'mains');
    });

    test(
      'emptying a name un-names the destination and FORGETS the key',
      () async {
        final cubit = build();
        await settle();
        await cubit.rename(0, 'mains');

        await cubit.rename(0, '   ');
        expect(cubit.state.isNamed(0), isFalse);
        expect(
          await settings.loadOutputName(device: 'Scarlett 18i20', bus: 0),
          isNull,
        );
      },
    );

    test('renaming to the same name changes nothing', () async {
      final cubit = build();
      await settle();
      await cubit.rename(2, 'wedge');

      final before = cubit.state;
      await cubit.rename(2, 'wedge');
      expect(cubit.state, same(before));
    });

    test('a rename with no device open is refused', () async {
      when(() => repository.state).thenReturn(const LooperState());
      final cubit = build();
      await settle();

      await cubit.rename(0, 'mains');
      expect(cubit.state.names, isEmpty);
    });

    test('a reopen does not blank the names it is between', () async {
      final cubit = build();
      await settle();
      await cubit.rename(0, 'mains');

      engine.add(const LooperState());
      await settle();
      expect(cubit.state.nameOf(0), 'mains');
      expect(cubit.state.device, 'Scarlett 18i20');
    });

    test('a name on the widest destination the engine can address survives a '
        'reload', () async {
      final cubit = build();
      await settle();
      await cubit.rename(kMaxOutputBuses - 1, 'sub');

      final reloaded = build();
      await settle();
      expect(reloaded.state.nameOf(kMaxOutputBuses - 1), 'sub');
    });

    test('a rename racing the device read is MERGED, not dropped', () async {
      await settings.saveOutputName(
        device: 'Scarlett 18i20',
        bus: 0,
        name: 'mains',
      );
      await settings.saveOutputName(
        device: 'Scarlett 18i20',
        bus: 3,
        name: 'wedge',
      );

      final cubit = build();
      await cubit.rename(0, 'PA');
      await settle();

      expect(cubit.state.nameOf(0), 'PA', reason: 'the rename wins');
      expect(cubit.state.nameOf(3), 'wedge', reason: 'the restore still lands');
    });
  });

  group('OutputsState', () {
    test('namedCount counts only the destinations the face shows', () {
      const state = OutputsState(
        device: 'Scarlett 18i20',
        names: {0: 'mains', 9: 'kept from a wider rig'},
      );
      expect(state.namedCount(2), 1);
      expect(state.namedCount(10), 2);
    });

    test('a destination has a name for every jack pair the engine can '
        'address', () {
      // The probe walks the store one destination at a time, so the ceiling
      // decides which names come back at all.
      expect(OutputsState.probeCeiling, kMaxOutputBuses);
    });
  });
}
