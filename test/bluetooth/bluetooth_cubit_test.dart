import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:bluetooth_repository/bluetooth_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/bluetooth/bluetooth_cubit.dart';

class _FakeBluetoothClient implements BluetoothClient {
  _FakeBluetoothClient({
    this.supported = true,
    BluetoothStatus? status,
    List<BluetoothDevice>? devices,
  }) : statusValue =
           status ??
           const BluetoothStatus(
             supported: true,
             powered: true,
             discoverable: false,
             advertising: false,
             alias: 'Segno',
           ),
       devices = List.of(devices ?? const []);

  bool supported;
  BluetoothStatus statusValue;
  List<BluetoothDevice> devices;

  /// Holds [status] open until completed — completing with an error makes the
  /// helper refuse the way an absent bluez does.
  Completer<void>? statusGate;

  /// Holds [scan] open until completed, same contract as [statusGate].
  Completer<void>? scanGate;

  @override
  bool get isSupported => supported;

  @override
  Future<BluetoothStatus> status() async {
    final gate = statusGate;
    if (gate != null) await gate.future;
    return statusValue;
  }

  @override
  Future<List<BluetoothDevice>> scan() async {
    final gate = scanGate;
    if (gate != null) await gate.future;
    return devices;
  }

  @override
  Future<void> setPowered({required bool enabled}) async {
    statusValue = BluetoothStatus(
      supported: true,
      powered: enabled,
      discoverable: enabled && statusValue.discoverable,
      advertising: enabled && statusValue.advertising,
      alias: statusValue.alias,
    );
  }

  @override
  Future<void> setDiscoverable({required bool enabled}) async {
    statusValue = BluetoothStatus(
      supported: true,
      powered: true,
      discoverable: enabled,
      advertising: statusValue.advertising,
      alias: statusValue.alias,
    );
  }

  @override
  Future<void> setAdvertising({required bool enabled}) async {
    statusValue = BluetoothStatus(
      supported: true,
      powered: true,
      discoverable: enabled || statusValue.discoverable,
      advertising: enabled,
      alias: statusValue.alias,
    );
  }

  /// Recorded device verbs, so a test can assert what the cubit asked for.
  final List<String> calls = [];

  /// When set, the next [pair] throws with this message.
  String? pairFailure;

  /// Holds [pair] open until completed, same contract as [statusGate].
  Completer<void>? pairGate;

  /// Holds [connect] open until completed, same contract as [statusGate].
  Completer<void>? connectGate;

  @override
  Future<void> pair(String address) async {
    calls.add('pair $address');
    final gate = pairGate;
    if (gate != null) await gate.future;
    final failure = pairFailure;
    if (failure != null) {
      pairFailure = null;
      throw StateError(failure);
    }
    devices = [
      for (final d in devices)
        if (d.address == address)
          BluetoothDevice(
            name: d.name,
            address: d.address,
            paired: true,
            connected: true,
            kind: d.kind,
          )
        else
          d,
    ];
  }

  @override
  Future<void> connect(String address) async {
    calls.add('connect $address');
    final gate = connectGate;
    if (gate != null) await gate.future;
  }

  @override
  Future<void> disconnect(String address) async =>
      calls.add('disconnect $address');

  @override
  Future<void> forget(String address) async {
    calls.add('forget $address');
    devices = [
      for (final d in devices)
        if (d.address != address) d,
    ];
  }
}

BluetoothRepository _repo(_FakeBluetoothClient client) =>
    BluetoothRepository(client: client);

void main() {
  group('BluetoothCubit', () {
    blocTest<BluetoothCubit, BluetoothState>(
      'load marks unsupported when helper missing',
      build: () => BluetoothCubit(
        repository: _repo(
          _FakeBluetoothClient(
            supported: false,
            status: BluetoothStatus.unsupported,
          ),
        ),
      ),
      act: (cubit) => cubit.load(),
      expect: () => [const BluetoothState(busy: true), const BluetoothState()],
    );

    blocTest<BluetoothCubit, BluetoothState>(
      'setDiscoverable updates status',
      build: () => BluetoothCubit(repository: _repo(_FakeBluetoothClient())),
      act: (cubit) async {
        await cubit.load();
        await cubit.setDiscoverable(enabled: true);
      },
      verify: (cubit) {
        expect(cubit.state.status.discoverable, isTrue);
      },
    );

    blocTest<BluetoothCubit, BluetoothState>(
      'scan populates devices',
      build: () => BluetoothCubit(
        repository: _repo(
          _FakeBluetoothClient(
            devices: const [
              BluetoothDevice(name: 'Phone', address: 'AA:BB:CC:DD:EE:FF'),
            ],
          ),
        ),
      ),
      act: (cubit) async {
        await cubit.load();
        await cubit.scan();
      },
      verify: (cubit) {
        expect(cubit.state.devices, hasLength(1));
        expect(cubit.state.devices.first.name, 'Phone');
      },
    );

    blocTest<BluetoothCubit, BluetoothState>(
      'setAdvertising updates advertising flag',
      build: () => BluetoothCubit(repository: _repo(_FakeBluetoothClient())),
      act: (cubit) async {
        await cubit.load();
        await cubit.setAdvertising(enabled: true);
      },
      verify: (cubit) {
        expect(cubit.state.status.advertising, isTrue);
      },
    );

    blocTest<BluetoothCubit, BluetoothState>(
      'togglePowered flips adapter power',
      build: () => BluetoothCubit(repository: _repo(_FakeBluetoothClient())),
      act: (cubit) async {
        await cubit.load();
        await cubit.togglePowered();
      },
      verify: (cubit) {
        expect(cubit.state.status.powered, isFalse);
      },
    );
  });

  group('device actions', () {
    const address = 'AA:BB:CC:DD:EE:FF';
    BluetoothDevice fresh() =>
        const BluetoothDevice(name: 'Cans', address: address);

    blocTest<BluetoothCubit, BluetoothState>(
      'pair re-reads scan and status rather than trusting the verb — bluez '
      'accepts a command and leaves the device as it was',
      build: () {
        final client = _FakeBluetoothClient(devices: [fresh()]);
        return BluetoothCubit(repository: _repo(client));
      },
      act: (cubit) async {
        await cubit.load();
        await cubit.pair(address);
      },
      verify: (cubit) {
        expect(cubit.state.devices.single.paired, isTrue);
        expect(cubit.state.pairingAddress, isNull);
        expect(cubit.state.errorMessage, isNull);
      },
    );

    blocTest<BluetoothCubit, BluetoothState>(
      'pairing marks pairingAddress and NOT busy — the list stays live '
      'behind the banner while a human is at the far device',
      build: () => BluetoothCubit(
        repository: _repo(_FakeBluetoothClient(devices: [fresh()])),
      ),
      act: (cubit) async {
        await cubit.load();
        final pairing = cubit.pair(address);
        expect(cubit.state.pairingAddress, address);
        expect(cubit.state.busy, isFalse);
        await pairing;
      },
    );

    blocTest<BluetoothCubit, BluetoothState>(
      'a refusal ties the message to the device it was about',
      build: () {
        final client = _FakeBluetoothClient(devices: [fresh()])
          ..pairFailure = 'Pairing timed out.';
        return BluetoothCubit(repository: _repo(client));
      },
      act: (cubit) async {
        await cubit.load();
        await cubit.pair(address);
      },
      verify: (cubit) {
        expect(cubit.state.failedAddress, address);
        expect(cubit.state.errorMessage, contains('Pairing timed out'));
        expect(cubit.state.pairingAddress, isNull);
      },
    );

    blocTest<BluetoothCubit, BluetoothState>(
      'cancelPairing drops the marker and claims nothing more — the helper '
      'call cannot be recalled once issued',
      build: () => BluetoothCubit(
        repository: _repo(_FakeBluetoothClient(devices: [fresh()])),
      ),
      act: (cubit) async {
        await cubit.load();
        final pairing = cubit.pair(address);
        cubit.cancelPairing();
        expect(cubit.state.pairingAddress, isNull);
        await pairing;
      },
    );

    blocTest<BluetoothCubit, BluetoothState>(
      'forget removes the pairing and the row',
      build: () {
        final client = _FakeBluetoothClient(devices: [fresh()]);
        return BluetoothCubit(repository: _repo(client));
      },
      act: (cubit) async {
        await cubit.load();
        await cubit.forget(address);
      },
      verify: (cubit) {
        expect(cubit.state.devices, isEmpty);
      },
    );

    blocTest<BluetoothCubit, BluetoothState>(
      'device verbs are inert when the stack is unsupported',
      build: () => BluetoothCubit(
        repository: _repo(_FakeBluetoothClient(supported: false)),
      ),
      act: (cubit) async {
        await cubit.load();
        await cubit.pair(address);
        await cubit.connect(address);
        await cubit.disconnect(address);
        await cubit.forget(address);
      },
      verify: (cubit) {
        expect(cubit.state.errorMessage, isNull);
        expect(cubit.state.pairingAddress, isNull);
      },
    );
  });

  // Same shape as the WiFi tray: bluez calls take seconds and the tray is
  // dismissible throughout, so every post-await emit has to re-check
  // `isClosed` or the continuation throws on a closed cubit.
  group('BluetoothCubit closing mid-flight', () {
    const address = 'AA:BB:CC:DD:EE:FF';

    test(
      'load survives the tray closing while status is in flight',
      () async {
        final client = _FakeBluetoothClient()..statusGate = Completer<void>();
        final cubit = BluetoothCubit(repository: _repo(client));

        final pending = cubit.load();
        await pumpEventQueue();
        await cubit.close();
        client.statusGate!.complete();

        await expectLater(pending, completes);
      },
    );

    test('load survives the tray closing while status is failing', () async {
      final client = _FakeBluetoothClient()..statusGate = Completer<void>();
      final cubit = BluetoothCubit(repository: _repo(client));

      final pending = cubit.load();
      await pumpEventQueue();
      await cubit.close();
      client.statusGate!.completeError(StateError('helper missing'));

      await expectLater(pending, completes);
    });

    test(
      'scan survives the tray closing while discovery is in flight',
      () async {
        final client = _FakeBluetoothClient();
        final cubit = BluetoothCubit(repository: _repo(client));
        await cubit.load();

        client.scanGate = Completer<void>();
        final pending = cubit.scan();
        await pumpEventQueue();
        await cubit.close();
        client.scanGate!.complete();

        await expectLater(pending, completes);
      },
    );

    test(
      'scan survives the tray closing while discovery is failing',
      () async {
        final client = _FakeBluetoothClient();
        final cubit = BluetoothCubit(repository: _repo(client));
        await cubit.load();

        client.scanGate = Completer<void>();
        final pending = cubit.scan();
        await pumpEventQueue();
        await cubit.close();
        client.scanGate!.completeError(StateError('discovery refused'));

        await expectLater(pending, completes);
      },
    );

    // Pairing waits on a human at the far device, so the tray outlives it least
    // of all. The failure has to come from `pair` itself: a failure raised by
    // the refresh behind it lands in `_refreshDevices`, which was already
    // guarded, and would prove nothing about `pair`'s own catch.
    test('pair survives the tray closing mid-pairing', () async {
      final client = _FakeBluetoothClient(
        devices: const [
          BluetoothDevice(name: 'Phone', address: address),
        ],
      );
      final cubit = BluetoothCubit(repository: _repo(client));
      await cubit.load();

      client.pairGate = Completer<void>();
      final pending = cubit.pair(address);
      await pumpEventQueue();
      await cubit.close();
      client.pairGate!.completeError(StateError('no such device'));

      await expectLater(pending, completes);
    });

    test('a device verb survives the tray closing mid-call', () async {
      final client = _FakeBluetoothClient(
        devices: const [
          BluetoothDevice(name: 'Phone', address: address, paired: true),
        ],
      );
      final cubit = BluetoothCubit(repository: _repo(client));
      await cubit.load();

      client.connectGate = Completer<void>();
      final pending = cubit.connect(address);
      await pumpEventQueue();
      await cubit.close();
      client.connectGate!.completeError(StateError('link dropped'));

      await expectLater(pending, completes);
    });
  });
}
