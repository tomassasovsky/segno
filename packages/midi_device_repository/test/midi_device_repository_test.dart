import 'dart:async';

import 'package:controller_repository/controller_repository.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:midi_client/testing.dart';
import 'package:midi_device_repository/midi_device_repository.dart';
import 'package:settings_repository/settings_repository.dart';

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
  const cc = RawControllerInput(
    kind: ControllerSourceKind.midiCc,
    id: 64,
    value: 127,
  );

  late _InMemoryStore store;
  late SettingsRepository settings;
  late List<MidiDevice> enumerated;
  late List<FakeMidiCapture> created;
  late int Function(String id) openResult;

  setUp(() {
    store = _InMemoryStore();
    settings = SettingsRepository(store: store);
    enumerated = const [];
    created = [];
    openResult = (_) => 0;
  });

  FakeMidiCapture capture() {
    final source = FakeMidiCapture(devices: () => enumerated)
      ..openResult = (id) => openResult(id);
    created.add(source);
    return source;
  }

  /// The capture that opened [id] (the first one created is the scanner).
  FakeMidiCapture captureOf(String id) =>
      created.skip(1).firstWhere((source) => source.opened.contains(id));

  // Builds a repository with the hotplug timer disabled (tests drive
  // [refresh]).
  MidiDeviceRepository build() => MidiDeviceRepository(
    captures: capture,
    settings: settings,
    pollInterval: Duration.zero,
  );

  // Builds the repository and lets the async launch hydrate complete.
  Future<MidiDeviceRepository> hydrated() async {
    final repository = build();
    await pumpEventQueue();
    return repository;
  }

  group('captures', () {
    test('captures every plugged-in device at once', () async {
      enumerated = const [dev1, dev2];
      final repository = await hydrated();
      addTearDown(repository.dispose);

      expect(repository.connection.devices, const [dev1, dev2]);
      expect(repository.connection.open, {'id-1', 'id-2'});
      expect(repository.sessions, {
        'id-1': const MidiInputSession('id-1', 1),
        'id-2': const MidiInputSession('id-2', 1),
      });
      expect(repository.connection.statusOf('id-2'), isConnected);
      // Nothing is selected: capture does not depend on the selection.
      expect(repository.connection.status, MidiConnectionStatus.none);
    });

    test(
      'each message carries the session of the device it came from',
      () async {
        enumerated = const [dev1, dev2];
        final repository = build();
        addTearDown(repository.dispose);
        final messages = <MidiInputMessage>[];
        final ticks = <void>[];
        repository.messages.listen(messages.add);
        repository.activity.listen(ticks.add);

        captureOf('id-1').send(cc);
        captureOf('id-2').send(cc);
        await pumpEventQueue();

        expect(messages.map((m) => m.session), [
          const MidiInputSession('id-1', 1),
          const MidiInputSession('id-2', 1),
        ]);
        expect(ticks, hasLength(2));
      },
    );

    test('a device listed once per port is captured once', () async {
      enumerated = const [
        MidiDevice(id: 'id-1', name: 'FCB1010 Port 1'),
        MidiDevice(id: 'id-1', name: 'FCB1010 Port 2'),
      ];
      final repository = await hydrated();
      addTearDown(repository.dispose);

      expect(created, hasLength(2)); // the scanner and one capture
      expect(captureOf('id-1').opened, ['id-1']);
    });

    test('a port that would not open is reported and retried', () async {
      enumerated = const [dev1, dev2];
      openResult = (id) => id == 'id-1' ? 5 : 0;
      final repository = await hydrated();
      addTearDown(repository.dispose);

      expect(repository.connection.openErrors, {'id-1': '5'});
      expect(repository.connection.statusOf('id-1'), isError);
      expect(repository.connection.statusOf('id-2'), isConnected);

      openResult = (_) => 0;
      repository.refresh();

      expect(repository.connection.openErrors, isEmpty);
      expect(repository.connection.open, {'id-1', 'id-2'});
    });

    test('a port that throws on open does not stop the others', () async {
      enumerated = const [dev1, dev2];
      openResult = (id) =>
          id == 'id-1' ? throw StateError('native open failed') : 0;
      final repository = await hydrated();
      addTearDown(repository.dispose);

      expect(repository.connection.openErrors['id-1'], contains('native'));
      expect(repository.connection.open, {'id-2'});
    });

    test('a null factory degrades gracefully (no devices, no crash)', () async {
      final repository = MidiDeviceRepository(
        captures: null,
        settings: settings,
        pollInterval: Duration.zero,
      );
      addTearDown(repository.dispose);
      await pumpEventQueue();

      expect(repository.connection.status, MidiConnectionStatus.none);
      expect(repository.connection.devices, isEmpty);
      expect(repository.sessions, isEmpty);
      await repository.select('id-1'); // no-op, must not throw
      expect(repository.connection.selectedId, '');
    });
  });

  group('hotplug', () {
    test('unplugging closes only that device and raises lost', () async {
      enumerated = const [dev1, dev2];
      final repository = await hydrated();
      addTearDown(repository.dispose);

      enumerated = const [dev2];
      repository.refresh();

      expect(repository.connection.open, {'id-2'});
      expect(repository.connection.statusOf('id-1'), isGone);
      expect(captureOf('id-1').closes, 1);
      expect(captureOf('id-2').closes, 0);
      expect(repository.connection.connectivity, MidiConnectivity.lost);
      expect(repository.connection.connectivityDeviceId, 'id-1');
      expect(repository.connection.connectivityDeviceName, 'FCB1010');
    });

    test(
      'replugging reopens with a new lifetime and raises restored',
      () async {
        enumerated = const [dev1];
        final repository = await hydrated();
        addTearDown(repository.dispose);

        enumerated = const [];
        repository.refresh();
        enumerated = const [dev1];
        repository.refresh();

        expect(repository.sessions, {
          'id-1': const MidiInputSession('id-1', 2),
        });
        expect(repository.connection.connectivity, MidiConnectivity.restored);
        expect(repository.connection.connectivityDeviceId, 'id-1');
      },
    );

    test(
      'no transition on the first observation or for a new device',
      () async {
        enumerated = const [dev1];
        final repository = await hydrated();
        addTearDown(repository.dispose);
        expect(repository.connection.connectivity, MidiConnectivity.none);

        enumerated = const [dev1, dev2];
        repository.refresh();

        expect(repository.connection.open, {'id-1', 'id-2'});
        expect(repository.connection.connectivity, MidiConnectivity.none);
      },
    );

    test('the poll timer drives periodic refresh', () {
      fakeAsync((async) {
        final repository = MidiDeviceRepository(
          captures: capture,
          settings: settings,
          pollInterval: const Duration(milliseconds: 500),
        );
        async.flushMicrotasks(); // launch hydrate
        enumerated = const [dev1];

        async.elapse(const Duration(milliseconds: 500)); // one poll tick

        expect(repository.connection.devices, const [dev1]);
        expect(repository.connection.open, {'id-1'});
        unawaited(repository.dispose());
        async.flushMicrotasks();
      });
    });
  });

  group('selection', () {
    test('persists the shown device and opens nothing', () async {
      enumerated = const [dev1, dev2];
      final repository = await hydrated();
      addTearDown(repository.dispose);

      await repository.select('id-2');

      expect(repository.connection.selectedId, 'id-2');
      expect(repository.connection.selectedName, 'SoftStep');
      expect(repository.connection.status, MidiConnectionStatus.connected);
      expect(await settings.loadMidiDevice(), (id: 'id-2', name: 'SoftStep'));
      expect(captureOf('id-2').opened, ['id-2']);
      expect(repository.connection.open, {'id-1', 'id-2'});
    });

    test('a failed write stays uncertain until a retry saves it', () async {
      enumerated = const [dev1, dev2];
      final repository = await hydrated();
      addTearDown(repository.dispose);
      await repository.select('id-1');
      store.refusedWrite = 'midi.input_device';

      await expectLater(repository.select('id-2'), throwsStateError);

      expect(repository.connection.selectedId, 'id-2');
      expect(repository.connection.pinUncertain, isTrue);
      expect(repository.connection.errorDetail, contains('refused'));
      expect((await settings.loadMidiDevice())?.id, 'id-1');
      // Capture is unaffected.
      expect(repository.connection.open, {'id-1', 'id-2'});

      store.refusedWrite = null;
      await repository.select('id-2');
      expect(repository.connection.pinUncertain, isFalse);
      expect(repository.connection.errorDetail, isNull);
      expect((await settings.loadMidiDevice())?.id, 'id-2');
    });

    test('write-then-throw keeps a coherent pair on relaunch', () async {
      enumerated = const [dev1, dev2];
      final repository = await hydrated();
      addTearDown(repository.dispose);
      store.failAfterWrite = 'midi.input_device';

      await expectLater(repository.select('id-2'), throwsStateError);
      expect(repository.connection.pinUncertain, isTrue);

      final relaunched = await hydrated();
      addTearDown(relaunched.dispose);
      expect(relaunched.connection.selectedId, 'id-2');
      expect(relaunched.connection.selectedName, 'SoftStep');
    });

    test('a dropped write is not reported as saved', () async {
      enumerated = const [dev1, dev2];
      final repository = await hydrated();
      addTearDown(repository.dispose);
      await repository.select('id-1');
      store.dropWrite = 'midi.input_device';

      await expectLater(repository.select('id-2'), throwsStateError);
      expect(repository.connection.pinUncertain, isTrue);
      expect(await settings.loadMidiDevice(), (id: 'id-1', name: 'FCB1010'));
    });

    test('rapid A then B saves only the latest request', () async {
      enumerated = const [dev1, dev2];
      final repository = await hydrated();
      addTearDown(repository.dispose);

      await Future.wait([repository.select('id-1'), repository.select('id-2')]);

      expect(repository.connection.selectedId, 'id-2');
      expect((await settings.loadMidiDevice())?.id, 'id-2');
    });

    test('re-selecting the shown device writes nothing', () async {
      enumerated = const [dev1];
      final repository = await hydrated();
      addTearDown(repository.dispose);
      await repository.select('id-1');
      store.refusedWrite = 'midi.input_device';

      await repository.select('id-1');

      expect(repository.connection.pinUncertain, isFalse);
    });
  });

  group('launch', () {
    test('restores a saved device that is present', () async {
      await settings.saveMidiDevice(id: 'id-1', name: 'FCB1010');
      enumerated = const [dev1];

      final repository = await hydrated();
      addTearDown(repository.dispose);

      expect(repository.connection.selectedId, 'id-1');
      expect(repository.connection.status, MidiConnectionStatus.connected);
    });

    test('keeps a saved device that is absent as deviceGone', () async {
      await settings.saveMidiDevice(id: 'id-9', name: 'Ghost');
      enumerated = const [dev1];

      final repository = await hydrated();
      addTearDown(repository.dispose);

      expect(repository.connection.status, MidiConnectionStatus.deviceGone);
      expect(repository.connection.selectedId, 'id-9');
      expect(repository.connection.selectedName, 'Ghost');
      expect(repository.connection.open, {'id-1'});
    });

    test('a failed read reports uncertainty and still captures', () async {
      store.refusedRead = 'midi.input_device';
      enumerated = const [dev1];
      final repository = await hydrated();
      addTearDown(repository.dispose);

      expect(repository.connection.pinUncertain, isTrue);
      expect(repository.connection.selectedId, isEmpty);
      expect(repository.connection.open, {'id-1'});
    });

    test('a malformed saved pair selects nothing', () async {
      enumerated = const [dev1];
      store.values['midi.input_device'] = '{"id":"id-1"}';
      final repository = await hydrated();
      addTearDown(repository.dispose);

      expect(repository.connection.pinUncertain, isTrue);
      expect(repository.connection.selectedId, isEmpty);
      store.refusedRead = null;
      await repository.select('id-1');
      expect(repository.connection.pinUncertain, isFalse);
      expect(await settings.loadMidiDevice(), (id: 'id-1', name: 'FCB1010'));
    });
  });

  group('connections stream', () {
    test('replays the current connection to a late subscriber', () async {
      enumerated = const [dev1, dev2];
      final repository = await hydrated();
      addTearDown(repository.dispose);

      final first = await repository.connections.first;

      expect(first.devices, const [dev1, dev2]);
      expect(first.open, {'id-1', 'id-2'});
    });
  });

  group('disposal', () {
    test('disposes every capture and the scanner', () async {
      enumerated = const [dev1, dev2];
      final repository = await hydrated();

      await repository.dispose();

      expect(created, hasLength(3));
      expect(created.every((source) => source.isDisposed), isTrue);
    });

    test('a late selection does not write after disposal', () async {
      enumerated = const [dev1];
      final repository = await hydrated();
      await repository.dispose();

      await repository.select('id-1');

      expect(store.values, isEmpty);
    });
  });

  group('MidiConnection', () {
    test('statusOf reads each device on its own', () {
      const connection = MidiConnection(
        devices: [dev1, dev2],
        open: {'id-1'},
        openErrors: {'id-2': '5'},
        selectedId: 'id-9',
      );

      expect(connection.statusOf('id-1'), isConnected);
      expect(connection.statusOf('id-2'), isError);
      expect(connection.statusOf('id-9'), isGone);
      expect(connection.statusOf(''), MidiConnectionStatus.none);
      expect(connection.status, isGone);
      expect(connection.isSelectedPresent, isFalse);
    });

    test('copyWith replaces fields; clearError resets the detail', () {
      const base = MidiConnection(errorDetail: '5', pinUncertain: true);

      final updated = base.copyWith(open: {'id-1'});
      expect(updated.open, {'id-1'});
      expect(updated.errorDetail, '5'); // retained without clearError

      expect(base.copyWith(clearError: true).errorDetail, isNull);
      expect(base.copyWith(pinUncertain: false).pinUncertain, isFalse);
    });

    test('value equality is by props', () {
      expect(
        const MidiConnection(selectedId: 'a'),
        const MidiConnection(selectedId: 'a'),
      );
      expect(
        const MidiConnection(open: {'a'}),
        isNot(const MidiConnection(open: {'b'})),
      );
    });
  });
}

const MidiConnectionStatus isConnected = MidiConnectionStatus.connected;
const MidiConnectionStatus isError = MidiConnectionStatus.error;
const MidiConnectionStatus isGone = MidiConnectionStatus.deviceGone;
