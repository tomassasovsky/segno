import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:segno/audio_setup/application/port_aliases.dart';
import 'package:segno/audio_setup/cubit/alias_rename_result.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

class _Repository extends Mock implements LooperRepository {}

class _Store extends FakeKeyValueStore {
  String? blockedKey;
  Completer<void>? gate;
  Completer<void>? readGate;
  bool failAfterWrite = false;
  bool failNextRead = false;
  bool failRollback = false;
  final writes = <(String, String)>[];

  @override
  Future<String?> getString(String key) async {
    await readGate?.future;
    if (failNextRead) {
      failNextRead = false;
      throw StateError('read failed');
    }
    return super.getString(key);
  }

  @override
  Future<void> setString(String key, String value) async {
    writes.add((key, value));
    if (key == blockedKey) await gate?.future;
    await super.setString(key, value);
    if (failAfterWrite) {
      failAfterWrite = false;
      throw StateError('mutated before failure');
    }
  }

  @override
  Future<void> remove(String key) async {
    await super.remove(key);
    if (failRollback) throw StateError('removed before failure');
  }
}

void main() {
  for (final kind in PortAliasKind.values) {
    group(kind.name, () {
      late _Store store;
      late _Repository repository;
      late PortAliases aliases;
      late List<PortAliasSnapshot> published;
      late String key;

      setUp(() async {
        store = _Store();
        published = [];
        key = '${kind == PortAliasKind.input ? 'input' : 'output'}_name.Rig.0';
        repository = _Repository();
        when(() => repository.mixGeneration).thenReturn(0);
        when(() => repository.looperState).thenAnswer(
          (_) => const Stream.empty(),
        );
        when(() => repository.state).thenReturn(
          const LooperState(
            status: EngineStatus(
              isConnected: true,
              devicePresent: true,
              deviceName: 'Rig',
            ),
          ),
        );
        aliases = PortAliases(
          settings: SettingsRepository(store: store),
          repository: repository,
          kind: kind,
          probeCeiling: 2,
          onChanged: published.add,
        );
        addTearDown(aliases.close);
        await pumpEventQueue();
      });

      test(
        'clearing a name after failed startup really removes its saved key',
        () async {
          await aliases.close();
          store
            ..values[key] = 'saved'
            ..failNextRead = true;
          aliases = PortAliases(
            settings: SettingsRepository(store: store),
            repository: repository,
            kind: kind,
            probeCeiling: 2,
            onChanged: published.add,
          );
          addTearDown(aliases.close);
          await pumpEventQueue();
          expect(published.last.names, isEmpty);
          expect(await aliases.rename(0, ''), AliasRenameResult.applied);
          expect(store.values.containsKey(key), isFalse);
        },
      );

      test('closing during initial load prevents late publication', () async {
        await aliases.close();
        published.clear();
        final gate = Completer<void>();
        store
          ..readGate = gate
          ..values[key] = 'saved';
        aliases = PortAliases(
          settings: SettingsRepository(store: store),
          repository: repository,
          kind: kind,
          probeCeiling: 2,
          onChanged: published.add,
        );
        addTearDown(aliases.close);
        await pumpEventQueue();
        expect(published.single.names, isEmpty);
        await aliases.close();
        gate.complete();
        await pumpEventQueue();
        expect(published, hasLength(1));
        expect(store.values[key], 'saved');
      });

      test('same key is serial while a different key progresses', () async {
        final gate = Completer<void>();
        store
          ..blockedKey = key
          ..gate = gate;
        final first = aliases.rename(0, 'first');
        final second = aliases.rename(0, 'second');
        await pumpEventQueue();
        expect(store.writes, [(key, 'first')]);
        expect(
          await aliases.rename(1, 'independent'),
          AliasRenameResult.applied,
        );
        expect(published.last.names, {1: 'independent'});
        gate.complete();
        expect(await first, AliasRenameResult.applied);
        expect(await second, AliasRenameResult.applied);
        expect(store.writes.where((entry) => entry.$1 == key), [
          (key, 'first'),
          (key, 'second'),
        ]);
        expect(store.values[key], 'second');
        expect(published.last.names, {0: 'second', 1: 'independent'});
        expect(
          store.values.keys,
          everyElement(startsWith('${kind.name}_name.Rig.')),
        );
      });

      test(
        'close fences publication but still compensates an admitted write',
        () async {
          expect(await aliases.rename(0, 'old'), AliasRenameResult.applied);
          final gate = Completer<void>();
          store
            ..blockedKey = key
            ..gate = gate
            ..failAfterWrite = true;
          final pending = aliases.rename(0, 'new');
          await pumpEventQueue();
          await aliases.close();
          final count = published.length;
          gate.complete();
          expect(await pending, AliasRenameResult.storageFailed);
          expect(store.values[key], 'old');
          expect(published, hasLength(count));
          expect(published.last.names, {0: 'old'});
          expect(await aliases.rename(0, 'late'), AliasRenameResult.refused);
        },
      );

      test(
        'failed compensation blocks only that key until explicit reload',
        () async {
          store
            ..failAfterWrite = true
            ..failRollback = true;
          expect(
            await aliases.rename(0, 'uncertain'),
            AliasRenameResult.recoveryRequired,
          );
          expect(store.values.containsKey(key), isFalse);
          expect(
            await aliases.rename(0, 'blocked'),
            AliasRenameResult.recoveryRequired,
          );
          expect(await aliases.rename(1, 'other'), AliasRenameResult.applied);
          expect(published.last.names, {1: 'other'});
          store.failRollback = false;
          await aliases.retryAliasRecovery(0);
          expect(
            await aliases.rename(0, 'recovered'),
            AliasRenameResult.applied,
          );
          expect(store.values[key], 'recovered');
          expect(published.last.names, {0: 'recovered', 1: 'other'});
        },
      );
    });
  }
}
