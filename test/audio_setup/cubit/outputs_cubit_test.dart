import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:segno/audio_setup/cubit/alias_rename_result.dart';
import 'package:segno/audio_setup/cubit/outputs_cubit.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

class _MockLooperRepository extends Mock implements LooperRepository {}

class _FaultStore extends FakeKeyValueStore {
  Completer<void>? firstReadGate;
  Completer<void>? writeGate;
  bool failAfterWrite = false;
  bool failRollback = false;
  int writes = 0;

  @override
  Future<String?> getString(String key) async {
    if (key == 'output_name.Scarlett 18i20.0' && firstReadGate != null) {
      final gate = firstReadGate!;
      firstReadGate = null;
      await gate.future;
    }
    return super.getString(key);
  }

  @override
  Future<void> setString(String key, String value) async {
    await writeGate?.future;
    await super.setString(key, value);
    if (key != 'output_name.Scarlett 18i20.0') return;
    writes++;
    if (failAfterWrite) {
      failAfterWrite = false;
      throw StateError('write changed key then failed');
    }
    if (failRollback && writes >= 2) {
      throw StateError('rollback failed');
    }
  }

  @override
  Future<void> remove(String key) async {
    await super.remove(key);
    if (key == 'output_name.Scarlett 18i20.0' && failRollback) {
      throw StateError('rollback removed key then failed');
    }
  }
}

/// The engine with an interface open. The device NAME is the key the names are
/// stored against, so a test that never opens one can never store a name.
const _scarlett = LooperState(
  status: EngineStatus(
    isConnected: true,
    devicePresent: true,
    deviceName: 'Scarlett 18i20',
    sampleRate: 48000,
    outputChannels: 20,
  ),
);

const _builtIn = LooperState(
  status: EngineStatus(
    isConnected: true,
    devicePresent: true,
    deviceName: 'Built-in audio',
    sampleRate: 48000,
    outputChannels: 2,
  ),
);

void main() {
  late SettingsRepository settings;
  late _MockLooperRepository repository;
  late StreamController<LooperState> engine;
  late int generation;

  setUp(() {
    settings = SettingsRepository(store: FakeKeyValueStore());
    repository = _MockLooperRepository();
    engine = StreamController<LooperState>.broadcast();
    generation = 0;
    addTearDown(engine.close);
    when(() => repository.looperState).thenAnswer((_) => engine.stream);
    when(() => repository.state).thenReturn(_scarlett);
    when(() => repository.mixGeneration).thenAnswer((_) => generation);
  });

  OutputsCubit build() {
    final cubit = OutputsCubit(settings: settings, repository: repository);
    addTearDown(cubit.close);
    return cubit;
  }

  Future<AliasRenameResult> renameResult(
    OutputsCubit cubit,
    int bus,
    String name, {
    int? expectedLifetime,
  }) async {
    AliasRenameResult? result;
    await cubit.rename(
      bus,
      name,
      expectedLifetime: expectedLifetime,
      onResult: (value) => result = value,
    );
    return result!;
  }

  /// Lets the constructor's own device read land before the test asserts.
  Future<void> settle() => pumpEventQueue();

  group('OutputsCubit', () {
    test('late A restore cannot publish after B opens', () async {
      final gate = Completer<void>();
      final store = _FaultStore()..firstReadGate = gate;
      final owned = SettingsRepository(store: store);
      await owned.saveOutputName(
        device: 'Built-in audio',
        bus: 0,
        name: 'laptop',
      );
      final cubit = OutputsCubit(settings: owned, repository: repository);
      addTearDown(cubit.close);
      engine.add(_builtIn);
      await settle();
      expect(cubit.state.device, 'Built-in audio');
      expect(cubit.state.nameOf(0), 'laptop');
      gate.complete();
      await settle();
      expect(cubit.state.device, 'Built-in audio');
      expect(cubit.state.nameOf(0), 'laptop');
    });

    test('a same-name reopen invalidates an old rename sheet', () async {
      final cubit = build();
      await settle();
      final opened = cubit.state.lifetime;
      engine.add(const LooperState());
      await settle();
      engine.add(_scarlett);
      await settle();
      expect(
        await renameResult(cubit, 0, 'stale', expectedLifetime: opened),
        AliasRenameResult.refused,
      );
      expect(
        await settings.loadOutputName(device: 'Scarlett 18i20', bus: 0),
        isNull,
      );
    });

    test(
      'write-then-throw restores the exact prior alias before showing it',
      () async {
        final store = _FaultStore();
        final owned = SettingsRepository(store: store);
        await owned.saveOutputName(
          device: 'Scarlett 18i20',
          bus: 0,
          name: 'old',
        );
        final cubit = OutputsCubit(settings: owned, repository: repository);
        addTearDown(cubit.close);
        await settle();
        store.failAfterWrite = true;
        expect(
          await renameResult(cubit, 0, 'new'),
          AliasRenameResult.storageFailed,
        );
        expect(cubit.state.nameOf(0), 'old');
        expect(
          await owned.loadOutputName(device: 'Scarlett 18i20', bus: 0),
          'old',
        );
      },
    );

    test(
      'failed rollback locks the uncertain key until a successful reload',
      () async {
        final store = _FaultStore();
        final owned = SettingsRepository(store: store);
        final cubit = OutputsCubit(settings: owned, repository: repository);
        addTearDown(cubit.close);
        await settle();
        store
          ..writes = 0
          ..failAfterWrite = true
          ..failRollback = true;
        expect(
          await renameResult(cubit, 0, 'new'),
          AliasRenameResult.recoveryRequired,
        );
        expect(cubit.state.nameOf(0), isEmpty);
        expect(
          await renameResult(cubit, 0, 'another'),
          AliasRenameResult.recoveryRequired,
        );
        await cubit.retryAliasRecovery(0);
        store.failRollback = false;
        expect(
          await renameResult(cubit, 0, 'another'),
          AliasRenameResult.applied,
        );
        expect(cubit.state.nameOf(0), 'another');
      },
    );
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

    test('renaming to the same name writes nothing', () async {
      // The guard is worth having for the store round-trip it avoids, not for
      // the emit: bloc drops an equal state either way, so asserting on the
      // state alone would pass with no guard at all.
      final cubit = build();
      await settle();
      await cubit.rename(2, 'wedge');

      // Clear the key behind the cubit's back. A rename to the same name must
      // not put it back.
      await settings.clearOutputName(device: 'Scarlett 18i20', bus: 2);
      await cubit.rename(2, 'wedge');
      expect(
        await settings.loadOutputName(device: 'Scarlett 18i20', bus: 2),
        isNull,
      );
      expect(cubit.state.nameOf(2), 'wedge');
    });

    test('a rename with no device open is refused', () async {
      when(() => repository.state).thenReturn(const LooperState());
      final cubit = build();
      await settle();

      await cubit.rename(0, 'mains');
      expect(cubit.state.names, isEmpty);
    });

    test('disconnect clears names from the outgoing device', () async {
      final cubit = build();
      await settle();
      await cubit.rename(0, 'mains');

      engine.add(const LooperState());
      await settle();
      expect(cubit.state.nameOf(0), '');
      expect(cubit.state.device, '');
    });

    test(
      'same-name restart refuses an old sheet before the next poll',
      () async {
        final cubit = build();
        await settle();
        final oldLifetime = cubit.state.lifetime;
        generation++;
        expect(
          await renameResult(
            cubit,
            0,
            'stale',
            expectedLifetime: oldLifetime,
          ),
          AliasRenameResult.refused,
        );
        expect(
          await settings.loadOutputName(device: 'Scarlett 18i20', bus: 0),
          isNull,
        );
      },
    );

    test('reopen reload waits for an old durable write', () async {
      final store = _FaultStore();
      final owned = SettingsRepository(store: store);
      final cubit = OutputsCubit(settings: owned, repository: repository);
      addTearDown(cubit.close);
      await settle();
      final gate = Completer<void>();
      store.writeGate = gate;
      final rename = renameResult(cubit, 0, 'mains');
      await settle();
      generation++;
      engine.add(
        const LooperState(
          mixGeneration: 1,
          status: EngineStatus(
            isConnected: true,
            devicePresent: true,
            deviceName: 'Scarlett 18i20',
            outputChannels: 20,
          ),
        ),
      );
      await settle();
      gate.complete();
      expect(await rename, AliasRenameResult.refused);
      await settle();
      expect(
        await owned.loadOutputName(device: 'Scarlett 18i20', bus: 0),
        'mains',
      );
      expect(cubit.state.nameOf(0), 'mains');
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
