import 'dart:async';

import 'package:controller_repository/controller_repository.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:midi_client/midi_client.dart';
import 'package:midi_device_repository/midi_device_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:settings_repository/settings_repository.dart';

class _MockMidiSource extends Mock implements MidiControllerSource {}

class _InMemoryStore implements KeyValueStore {
  final Map<String, Object> values = {};
  String? refusedRemoval;
  String? refusedWrite;
  String? refusedRead;
  String? failAfterWrite;
  String? failAfterRemoval;
  String? dropWrite;
  Completer<void>? removalGate;

  @override
  Future<int?> getInt(String key) async => values[key] as int?;

  @override
  Future<void> setInt(String key, int value) async => values[key] = value;

  @override
  Future<String?> getString(String key) async {
    if (key == refusedRead) throw StateError('storage read refused $key');
    return values[key] as String?;
  }

  @override
  Future<void> setString(String key, String value) async {
    if (key == refusedWrite) throw StateError('storage write refused $key');
    if (key == dropWrite) return;
    values[key] = value;
    if (key == failAfterWrite) {
      failAfterWrite = null;
      throw StateError('storage failed after writing $key');
    }
  }

  @override
  Future<bool?> getBool(String key) async => values[key] as bool?;

  @override
  Future<void> setBool(String key, {required bool value}) async =>
      values[key] = value;

  @override
  Future<double?> getDouble(String key) async => values[key] as double?;

  @override
  Future<void> setDouble(String key, double value) async => values[key] = value;

  @override
  Future<void> remove(String key) async {
    await removalGate?.future;
    if (key == refusedRemoval) throw StateError('storage refused $key');
    values.remove(key);
    if (key == failAfterRemoval) {
      failAfterRemoval = null;
      throw StateError('storage failed after removing $key');
    }
  }

  @override
  Future<void> clear() async => values.clear();
}

void main() {
  const dev1 = MidiDevice(id: 'id-1', name: 'FCB1010');
  const dev2 = MidiDevice(id: 'id-2', name: 'SoftStep');

  late _MockMidiSource source;
  late _InMemoryStore store;
  late SettingsRepository settings;
  late StreamController<RawControllerInput> activity;
  late List<MidiDevice> enumerated;

  setUp(() {
    source = _MockMidiSource();
    store = _InMemoryStore();
    settings = SettingsRepository(store: store);
    activity = StreamController<RawControllerInput>.broadcast();
    enumerated = const [];
    when(() => source.enumerate()).thenAnswer((_) => enumerated);
    when(() => source.activity).thenAnswer((_) => activity.stream);
    when(() => source.open(any())).thenReturn(0);
    when(source.close).thenReturn(0);
  });

  tearDown(() => activity.close());

  // Builds a repository with the hotplug timer disabled (tests drive
  // [refresh]).
  MidiDeviceRepository build() => MidiDeviceRepository(
    source: source,
    settings: settings,
    pollInterval: Duration.zero,
  );

  // Builds the repository and lets the async launch hydrate complete.
  Future<MidiDeviceRepository> hydrated() async {
    final repository = build();
    await pumpEventQueue();
    return repository;
  }

  group('enumeration + initial state', () {
    test('starts with no selection and the enumerated devices', () async {
      enumerated = const [dev1, dev2];
      final repository = await hydrated();
      addTearDown(repository.dispose);

      expect(repository.connection.status, MidiConnectionStatus.none);
      expect(repository.connection.devices, const [dev1, dev2]);
      expect(repository.connection.selectedId, '');
    });

    test('a null source degrades gracefully (no devices, no crash)', () async {
      final repository = MidiDeviceRepository(
        source: null,
        settings: settings,
        pollInterval: Duration.zero,
      );
      addTearDown(repository.dispose);
      await pumpEventQueue();

      expect(repository.connection.status, MidiConnectionStatus.none);
      expect(repository.connection.devices, isEmpty);
      expect(repository.activity, emitsDone); // empty stream
      await repository.select('id-1'); // no-op, must not throw
      expect(repository.connection.selectedId, '');
    });

    test(
      'failed initial read reports uncertainty without an uncaught error',
      () async {
        store.refusedRead = 'midi.input_device';
        final repository = await hydrated();
        addTearDown(repository.dispose);

        expect(repository.connection.pinUncertain, isTrue);
        expect(repository.connection.selectedId, isEmpty);
        store.refusedRead = null;
        await repository.select('');
        expect(repository.connection.pinUncertain, isFalse);
        expect(repository.connection.status, MidiConnectionStatus.none);
      },
    );

    test(
      'malformed saved pair fails closed until explicitly cleared',
      () async {
        enumerated = const [dev1];
        store.values['midi.input_device'] = '{"id":"id-1"}';
        final repository = await hydrated();
        addTearDown(repository.dispose);

        expect(repository.connection.pinUncertain, isTrue);
        expect(repository.connection.selectedId, isEmpty);
        verifyNever(() => source.open(any()));
        await repository.selectNone();
        expect(repository.connection.pinUncertain, isFalse);
        expect(await settings.loadMidiDevice(), isNull);
      },
    );

    test('republishes raw source activity for the indicator', () async {
      final repository = await hydrated();
      addTearDown(repository.dispose);
      final ticks = <void>[];
      final sub = repository.activity.listen(ticks.add);
      addTearDown(sub.cancel);

      activity.add(
        const RawControllerInput(
          kind: ControllerSourceKind.midiCc,
          id: 80,
          value: 127,
        ),
      );
      await pumpEventQueue();

      expect(ticks, hasLength(1));
    });
  });

  group('select', () {
    test('opens the device, persists it, and connects', () async {
      enumerated = const [dev1, dev2];
      final repository = await hydrated();
      addTearDown(repository.dispose);

      await repository.select('id-1');

      expect(repository.connection.status, MidiConnectionStatus.connected);
      expect(repository.connection.selectedId, 'id-1');
      expect(repository.connection.selectedName, 'FCB1010');
      verify(() => source.open('id-1')).called(1);
      final saved = await settings.loadMidiDevice();
      expect(saved?.id, 'id-1');
      expect(saved?.name, 'FCB1010');
    });

    test(
      'switching A→B opens B and persists B (native open closes A)',
      () async {
        enumerated = const [dev1, dev2];
        final repository = await hydrated();
        addTearDown(repository.dispose);

        await repository.select('id-1');
        await repository.select('id-2');

        expect(repository.connection.selectedId, 'id-2');
        expect(repository.connection.status, MidiConnectionStatus.connected);
        verify(() => source.open('id-2')).called(1);
        expect((await settings.loadMidiDevice())?.id, 'id-2');
      },
    );

    test(
      'a failed open surfaces a recoverable error, retaining the pin',
      () async {
        enumerated = const [dev1];
        when(() => source.open('id-1')).thenReturn(5);
        final repository = await hydrated();
        addTearDown(repository.dispose);

        await repository.select('id-1');

        expect(repository.connection.status, MidiConnectionStatus.error);
        expect(repository.connection.errorDetail, '5');
        expect(repository.connection.selectedId, 'id-1');
        // The selection is still persisted so a later retry / replug recovers.
        expect((await settings.loadMidiDevice())?.id, 'id-1');
      },
    );

    test('re-selecting the already-connected device is a no-op', () async {
      enumerated = const [dev1];
      final repository = await hydrated();
      addTearDown(repository.dispose);
      await repository.select('id-1');
      clearInteractions(source);

      await repository.select('id-1'); // already connected → no reopen

      verifyNever(() => source.open(any()));
      expect(repository.connection.status, MidiConnectionStatus.connected);
    });

    for (final priorUncertainty in [false, true]) {
      test(
        'confirmed pin stays retryable after thrown open '
        '(prior uncertainty: $priorUncertainty)',
        () async {
          enumerated = const [dev1];
          final repository = await hydrated();
          addTearDown(repository.dispose);
          if (priorUncertainty) {
            store.refusedWrite = 'midi.input_device';
            await expectLater(repository.select('id-1'), throwsStateError);
            expect(repository.connection.pinUncertain, isTrue);
            verifyNever(() => source.open('id-1'));
            store.refusedWrite = null;
          }
          var opens = 0;
          when(() => source.open('id-1')).thenAnswer((_) {
            opens++;
            if (opens == 1) throw StateError('native open failed');
            return 0;
          });

          await expectLater(repository.select('id-1'), throwsStateError);
          expect(await settings.loadMidiDevice(), (
            id: 'id-1',
            name: 'FCB1010',
          ));
          expect(repository.connection.status, MidiConnectionStatus.error);
          expect(repository.connection.errorDetail, contains('native open'));
          expect(repository.connection.pinUncertain, isFalse);
          expect(repository.connection.selectedId, 'id-1');
          repository.refresh();
          expect(opens, 2);
          expect(repository.connection.status, MidiConnectionStatus.connected);
          expect(repository.connection.errorDetail, isNull);
        },
      );
    }

    test(
      'failed device write stays uncertain across refresh and retries',
      () async {
        enumerated = const [dev1, dev2];
        final repository = await hydrated();
        addTearDown(repository.dispose);
        await repository.select('id-1');
        clearInteractions(source);
        store.refusedWrite = 'midi.input_device';

        await expectLater(repository.select('id-2'), throwsStateError);
        expect(repository.connection.selectedId, 'id-2');
        expect(repository.connection.pinUncertain, isTrue);
        expect(repository.connection.status, MidiConnectionStatus.error);
        expect((await settings.loadMidiDevice())?.id, 'id-1');
        repository.refresh();
        expect(repository.connection.pinUncertain, isTrue);
        verifyNever(() => source.open('id-2'));
        enumerated = const [];
        repository.refresh();
        enumerated = const [dev1, dev2];
        repository.refresh();
        expect(repository.connection.connectivity, MidiConnectivity.none);

        final relaunched = await hydrated();
        addTearDown(relaunched.dispose);
        expect(relaunched.connection.selectedId, 'id-1');
        store.refusedWrite = null;
        await repository.select('id-2');
        expect(repository.connection.pinUncertain, isFalse);
        expect(repository.connection.status, MidiConnectionStatus.connected);
        expect((await settings.loadMidiDevice())?.id, 'id-2');
        verify(() => source.open('id-2')).called(1);
      },
    );

    test(
      'write-then-throw retains uncertainty and a coherent pair on relaunch',
      () async {
        enumerated = const [dev1, dev2];
        final repository = await hydrated();
        addTearDown(repository.dispose);
        await repository.select('id-1');
        clearInteractions(source);
        store.failAfterWrite = 'midi.input_device';

        await expectLater(repository.select('id-2'), throwsStateError);
        expect(repository.connection.pinUncertain, isTrue);
        expect(await settings.loadMidiDevice(), (id: 'id-2', name: 'SoftStep'));
        repository.refresh();
        verifyNever(() => source.open('id-2'));

        final relaunched = await hydrated();
        addTearDown(relaunched.dispose);
        expect(relaunched.connection.selectedId, 'id-2');
        expect(relaunched.connection.selectedName, 'SoftStep');

        await repository.select('id-2');
        expect(repository.connection.pinUncertain, isFalse);
        expect(await settings.loadMidiDevice(), (
          id: 'id-2',
          name: 'SoftStep',
        ));
      },
    );

    test('dropped write is not reported as a saved new selection', () async {
      enumerated = const [dev1, dev2];
      final repository = await hydrated();
      addTearDown(repository.dispose);
      await repository.select('id-1');
      clearInteractions(source);
      store.dropWrite = 'midi.input_device';

      await expectLater(repository.select('id-2'), throwsStateError);
      expect(repository.connection.pinUncertain, isTrue);
      expect(await settings.loadMidiDevice(), (id: 'id-1', name: 'FCB1010'));
      repository.refresh();
      verifyNever(() => source.open('id-2'));

      store.dropWrite = null;
      await repository.select('id-2');
      expect(repository.connection.pinUncertain, isFalse);
      expect(await settings.loadMidiDevice(), (id: 'id-2', name: 'SoftStep'));
    });
  });

  group('None', () {
    test('closes the device, clears the keys, and stops events', () async {
      enumerated = const [dev1];
      final repository = await hydrated();
      addTearDown(repository.dispose);
      await repository.select('id-1');

      await repository.selectNone();

      expect(repository.connection.status, MidiConnectionStatus.none);
      expect(repository.connection.selectedId, '');
      expect(repository.connection.pinUncertain, isFalse);
      verify(source.close).called(2);
      expect(await settings.loadMidiDevice(), isNull);
    });

    test('failed first removal stops ingress and stays retryable', () async {
      enumerated = const [dev1];
      final repository = await hydrated();
      addTearDown(repository.dispose);
      await repository.select('id-1');
      clearInteractions(source);
      store.refusedRemoval = 'midi.input_device';

      final clearing = repository.selectNone();
      expect(repository.connection.selectedId, '');
      expect(repository.connection.status, MidiConnectionStatus.connecting);
      verify(source.close).called(1);
      await expectLater(clearing, throwsStateError);

      expect(repository.connection.status, MidiConnectionStatus.error);
      expect(repository.connection.selectedId, '');
      expect(repository.connection.pinUncertain, isTrue);
      expect(repository.connection.errorDetail, contains('storage refused'));
      expect((await settings.loadMidiDevice())?.id, 'id-1');
      repository.refresh();
      verifyNever(() => source.open(any()));

      // A restart still observes the old durable pin. Retry confirms None.
      final relaunched = await hydrated();
      addTearDown(relaunched.dispose);
      expect(relaunched.connection.selectedId, 'id-1');
      expect(relaunched.connection.status, MidiConnectionStatus.connected);
      store.refusedRemoval = null;
      await repository.selectNone();
      expect(repository.connection.status, MidiConnectionStatus.none);
      expect(repository.connection.pinUncertain, isFalse);
      expect(await settings.loadMidiDevice(), isNull);
    });

    test(
      'remove-then-throw remains uncertain and relaunch sees None',
      () async {
        enumerated = const [dev1];
        final repository = await hydrated();
        addTearDown(repository.dispose);
        await repository.select('id-1');
        store.failAfterRemoval = 'midi.input_device';

        await expectLater(repository.selectNone(), throwsStateError);

        expect(repository.connection.status, MidiConnectionStatus.error);
        expect(repository.connection.selectedId, '');
        expect(repository.connection.pinUncertain, isTrue);
        expect(await settings.loadMidiDevice(), isNull);
        expect(store.values.containsKey('midi.input_device'), isFalse);
        clearInteractions(source);
        final relaunched = await hydrated();
        addTearDown(relaunched.dispose);
        expect(relaunched.connection.status, MidiConnectionStatus.none);
        verifyNever(() => source.open(any()));
        await repository.selectNone();
        expect(repository.connection.status, MidiConnectionStatus.none);
        expect(store.values.containsKey('midi.input_device'), isFalse);
      },
    );

    test('a newer selection outranks an old failed clear', () async {
      enumerated = const [dev1, dev2];
      final repository = await hydrated();
      addTearDown(repository.dispose);
      await repository.select('id-1');
      store.refusedRemoval = 'midi.input_device';
      final gate = Completer<void>();
      store.removalGate = gate;

      final clearing = repository.selectNone();
      await pumpEventQueue(); // the old clear is inside the store
      final selecting = repository.select('id-2');
      gate.complete();
      await expectLater(clearing, throwsStateError);
      await selecting;

      expect(repository.connection.selectedId, 'id-2');
      expect(repository.connection.status, MidiConnectionStatus.connected);
      expect((await settings.loadMidiDevice())?.id, 'id-2');
    });
  });

  test(
    'rapid A then B selection opens only the latest captured request',
    () async {
      enumerated = const [dev1, dev2];
      final repository = await hydrated();
      addTearDown(repository.dispose);
      final a = repository.select('id-1');
      final b = repository.select('id-2');
      await Future.wait([a, b]);
      verifyNever(() => source.open('id-1'));
      verify(() => source.open('id-2')).called(1);
      expect(repository.connection.selectedId, 'id-2');
      expect((await settings.loadMidiDevice())?.id, 'id-2');
    },
  );

  test('None invalidates an unfinished selection before it opens', () async {
    enumerated = const [dev1];
    final repository = await hydrated();
    addTearDown(repository.dispose);
    final selection = repository.select('id-1');
    final none = repository.selectNone();
    await Future.wait([selection, none]);
    verifyNever(() => source.open(any()));
    expect(repository.connection.status, MidiConnectionStatus.none);
    expect(await settings.loadMidiDevice(), isNull);
  });

  group('launch auto-reconnect', () {
    test('re-opens a saved device that is present', () async {
      await settings.saveMidiDevice(id: 'id-1', name: 'FCB1010');
      enumerated = const [dev1];

      final repository = await hydrated();
      addTearDown(repository.dispose);

      expect(repository.connection.status, MidiConnectionStatus.connected);
      expect(repository.connection.selectedId, 'id-1');
      verify(() => source.open('id-1')).called(1);
    });

    test('retains a saved device that is absent as deviceGone', () async {
      await settings.saveMidiDevice(id: 'id-9', name: 'Ghost');
      enumerated = const [dev1]; // id-9 not present

      final repository = await hydrated();
      addTearDown(repository.dispose);

      expect(repository.connection.status, MidiConnectionStatus.deviceGone);
      expect(repository.connection.selectedId, 'id-9');
      expect(repository.connection.selectedName, 'Ghost');
      verifyNever(() => source.open(any()));
    });
  });

  group('hotplug', () {
    test('losing the connected device marks it gone and raises lost', () async {
      enumerated = const [dev1];
      final repository = await hydrated();
      addTearDown(repository.dispose);
      await repository.select('id-1');

      enumerated = const []; // unplugged
      repository.refresh();

      expect(repository.connection.status, MidiConnectionStatus.deviceGone);
      expect(repository.connection.connectivity, MidiConnectivity.lost);
      expect(repository.connection.connectivityDeviceName, 'FCB1010');
    });

    test('replugging reconnects the device and raises restored', () async {
      enumerated = const [dev1];
      final repository = await hydrated();
      addTearDown(repository.dispose);
      await repository.select('id-1');
      clearInteractions(source);

      enumerated = const [];
      repository.refresh(); // lost
      enumerated = const [dev1];
      repository.refresh(); // restored

      expect(repository.connection.status, MidiConnectionStatus.connected);
      expect(repository.connection.connectivity, MidiConnectivity.restored);
      verify(() => source.open('id-1')).called(1);
    });

    test('does not flag a transition on the first observation', () async {
      enumerated = const [dev1];
      final repository = await hydrated();
      addTearDown(repository.dispose);
      await repository.select('id-1');

      repository.refresh(); // still present, no transition

      expect(repository.connection.connectivity, MidiConnectivity.none);
      expect(repository.connection.status, MidiConnectionStatus.connected);
    });

    test(
      'a failed reopen on replug surfaces the error after restored',
      () async {
        enumerated = const [dev1];
        final repository = await hydrated();
        addTearDown(repository.dispose);
        await repository.select('id-1');

        enumerated = const [];
        repository.refresh(); // lost
        when(() => source.open('id-1')).thenReturn(7);
        enumerated = const [dev1];
        repository.refresh(); // present again, but the reopen fails

        expect(repository.connection.status, MidiConnectionStatus.error);
        expect(repository.connection.errorDetail, '7');
        expect(repository.connection.connectivity, MidiConnectivity.restored);
      },
    );

    test('the poll timer drives periodic refresh', () {
      enumerated = const [dev1];
      fakeAsync((async) {
        final repository = MidiDeviceRepository(
          source: source,
          settings: settings,
          pollInterval: const Duration(milliseconds: 500),
        );
        async.flushMicrotasks(); // launch hydrate
        clearInteractions(source);

        async.elapse(const Duration(milliseconds: 500)); // one poll tick

        verify(() => source.enumerate()).called(greaterThanOrEqualTo(1));
        // The poll reconciled the live enumeration into the connection.
        expect(repository.connection.devices, const [dev1]);
        unawaited(repository.dispose());
        async.flushMicrotasks();
      });
    });
  });

  group('connections stream', () {
    test('replays the current connection to a late subscriber', () async {
      enumerated = const [dev1, dev2];
      final repository = await hydrated();
      addTearDown(repository.dispose);

      // Subscribe after the launch enumerate/hydrate already ran.
      final first = await repository.connections.first;

      expect(first.devices, const [dev1, dev2]);
      expect(first.status, MidiConnectionStatus.none);
    });

    test('emits as the lifecycle advances', () async {
      enumerated = const [dev1];
      final repository = await hydrated();
      addTearDown(repository.dispose);

      final statuses = <MidiConnectionStatus>[];
      final sub = repository.connections.listen((c) => statuses.add(c.status));
      addTearDown(sub.cancel);

      await repository.select('id-1');
      await pumpEventQueue();

      expect(
        statuses,
        containsAllInOrder([
          MidiConnectionStatus.connecting,
          MidiConnectionStatus.connected,
        ]),
      );
      expect(statuses.last, MidiConnectionStatus.connected);
    });
  });

  group('audio independence', () {
    test('selecting / switching / clearing touches only the MIDI source and '
        'settings — never an audio engine', () async {
      enumerated = const [dev1, dev2];
      final repository = await hydrated();
      addTearDown(repository.dispose);

      await repository.select('id-1');
      await repository.select('id-2');
      await repository.selectNone();

      // The repository has no LooperRepository collaborator at all; its only
      // interactions are open/close/enumerate on the MIDI source.
      verify(() => source.open(any())).called(2);
      verify(source.close).called(3);
      verify(() => source.enumerate()).called(greaterThanOrEqualTo(1));
      verifyNoMoreInteractions(source);
    });
  });

  group('disposal', () {
    test('does not dispose the borrowed source', () async {
      final repository = await hydrated();

      await repository.dispose();

      // The source is owned by the ControllerRepository; the repository only
      // borrows it and must never tear it down.
      verifyNever(() => source.dispose());
    });

    test('a late None request does not start a write after disposal', () async {
      final repository = await hydrated();
      await repository.dispose();
      clearInteractions(source);

      await repository.select('');

      verifyNever(source.close);
      expect(store.values, isEmpty);
    });
  });

  group('MidiConnection', () {
    test('isSelectedPresent reflects the current enumeration', () {
      const absent = MidiConnection(devices: [dev1], selectedId: 'id-9');
      const present = MidiConnection(devices: [dev1], selectedId: 'id-1');

      expect(absent.isSelectedPresent, isFalse);
      expect(present.isSelectedPresent, isTrue);
    });

    test('copyWith replaces fields; clearError resets the detail', () {
      const base = MidiConnection(
        status: MidiConnectionStatus.error,
        errorDetail: '5',
      );

      final updated = base.copyWith(status: MidiConnectionStatus.connecting);
      expect(updated.status, MidiConnectionStatus.connecting);
      expect(updated.errorDetail, '5'); // retained without clearError

      expect(base.copyWith(clearError: true).errorDetail, isNull);
      expect(base.copyWith(pinUncertain: true).pinUncertain, isTrue);
    });

    test('value equality is by props', () {
      expect(
        const MidiConnection(selectedId: 'a'),
        const MidiConnection(selectedId: 'a'),
      );
      expect(
        const MidiConnection(selectedId: 'a'),
        isNot(const MidiConnection(selectedId: 'b')),
      );
    });
  });
}
