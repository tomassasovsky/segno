import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/wifi/wifi_cubit.dart';
import 'package:segno/wifi/wifi_join_failure.dart';
import 'package:wifi_repository/wifi_repository.dart';

class _FakeWifiClient implements WifiClient {
  _FakeWifiClient({
    this.supported = true,
    this.connectFails = false,
    WifiStatus? status,
    List<WifiNetwork>? networks,
  }) : statusValue =
           status ??
           const WifiStatus(
             supported: true,
             enabled: true,
             connected: false,
           ),
       networks = List.of(networks ?? const []);

  bool supported;

  /// When true, every [connect] refuses the way the supplicant does.
  bool connectFails;

  /// Scripted refusals: each [connect] throws the next entry until the list
  /// is exhausted, then succeeds. Lets a test shape the exact stack wording
  /// (iwd race vs wrong password) and count re-activations.
  final List<Error> connectErrors = [];
  WifiStatus statusValue;
  List<WifiNetwork> networks;
  final connects = <(String, String?)>[];
  int disconnectCalls = 0;
  final forgotten = <String>[];
  Completer<void>? connectGate;

  /// Holds [status] open until completed — completing with an error makes the
  /// helper refuse the way a missing wpa_supplicant does.
  Completer<void>? statusGate;

  /// Holds [scan] open until completed, same contract as [statusGate].
  Completer<void>? scanGate;

  @override
  bool get isSupported => supported;

  @override
  Future<WifiStatus> status() async {
    final gate = statusGate;
    if (gate != null) await gate.future;
    return statusValue;
  }

  @override
  Future<List<WifiNetwork>> scan() async {
    final gate = scanGate;
    if (gate != null) await gate.future;
    return networks;
  }

  @override
  Future<void> connect(String ssid, {String? psk}) async {
    connects.add((ssid, psk));
    final gate = connectGate;
    if (gate != null) await gate.future;
    if (connectErrors.isNotEmpty) throw connectErrors.removeAt(0);
    if (connectFails) throw StateError('authentication failed');
    statusValue = WifiStatus(
      supported: true,
      enabled: true,
      connected: true,
      ssid: ssid,
      ip: '10.0.0.2',
      signal: -40,
    );
  }

  @override
  Future<void> disconnect() async {
    disconnectCalls++;
    statusValue = const WifiStatus(
      supported: true,
      enabled: true,
      connected: false,
    );
  }

  @override
  Future<void> forget(String ssid) async {
    forgotten.add(ssid);
    networks = [
      for (final n in networks)
        if (n.ssid != ssid) n,
    ];
    if (statusValue.ssid == ssid) {
      statusValue = const WifiStatus(
        supported: true,
        enabled: true,
        connected: false,
      );
    }
  }

  @override
  Future<void> setEnabled({required bool enabled}) async {
    statusValue = WifiStatus(
      supported: true,
      enabled: enabled,
      connected: enabled && statusValue.connected,
      ssid: enabled ? statusValue.ssid : '',
      ip: enabled ? statusValue.ip : '',
      signal: statusValue.signal,
    );
  }
}

WifiRepository _repo(_FakeWifiClient client) => WifiRepository(client: client);

void main() {
  group('WifiCubit', () {
    blocTest<WifiCubit, WifiState>(
      'load marks unsupported when helper missing',
      build: () => WifiCubit(
        repository: _repo(
          _FakeWifiClient(
            supported: false,
            status: WifiStatus.unsupported,
          ),
        ),
      ),
      act: (cubit) => cubit.load(),
      expect: () => [
        const WifiState(busy: true),
        const WifiState(),
      ],
    );

    blocTest<WifiCubit, WifiState>(
      'scan dedupes by ssid keeping the stronger signal',
      build: () => WifiCubit(
        repository: _repo(
          _FakeWifiClient(
            networks: const [
              WifiNetwork(ssid: 'Cafe', signal: -70, secured: true),
              WifiNetwork(ssid: 'Cafe', signal: -40, secured: true),
              WifiNetwork(ssid: 'OpenNet', signal: -55, secured: false),
            ],
          ),
        ),
      ),
      act: (cubit) async {
        await cubit.load();
        await cubit.scan();
      },
      verify: (cubit) {
        expect(cubit.state.networks.map((n) => n.ssid), ['Cafe', 'OpenNet']);
        expect(cubit.state.networks.first.signal, -40);
      },
    );

    blocTest<WifiCubit, WifiState>(
      'connect updates status',
      build: () => WifiCubit(repository: _repo(_FakeWifiClient())),
      act: (cubit) async {
        await cubit.load();
        await cubit.connect('Home', psk: 'secret');
      },
      verify: (cubit) {
        expect(cubit.state.status.connected, isTrue);
        expect(cubit.state.status.ssid, 'Home');
        expect(cubit.state.connectingSsid, isNull);
        expect(cubit.state.busy, isFalse);
      },
    );

    test('connect exposes connectingSsid while join is in flight', () async {
      final client = _FakeWifiClient()..connectGate = Completer<void>();
      final cubit = WifiCubit(repository: _repo(client));
      addTearDown(cubit.close);

      await cubit.load();
      final pending = cubit.connect('Home', psk: 'secret');
      await pumpEventQueue();
      expect(cubit.state.connectingSsid, 'Home');
      expect(cubit.state.busy, isTrue);

      client.connectGate!.complete();
      await pending;
      expect(cubit.state.connectingSsid, isNull);
      expect(cubit.state.status.ssid, 'Home');
    });

    blocTest<WifiCubit, WifiState>(
      'disconnect clears association',
      build: () => WifiCubit(
        repository: _repo(
          _FakeWifiClient(
            status: const WifiStatus(
              supported: true,
              enabled: true,
              connected: true,
              ssid: 'Home',
              ip: '10.0.0.2',
            ),
          ),
        ),
      ),
      act: (cubit) async {
        await cubit.load();
        await cubit.disconnect();
      },
      verify: (cubit) {
        expect(cubit.state.status.connected, isFalse);
      },
    );

    blocTest<WifiCubit, WifiState>(
      'toggleEnabled flips radio',
      build: () => WifiCubit(repository: _repo(_FakeWifiClient())),
      act: (cubit) async {
        await cubit.load();
        await cubit.toggleEnabled();
      },
      verify: (cubit) {
        expect(cubit.state.status.enabled, isFalse);
      },
    );
  });

  group('the failure is tied to the network it was about', () {
    blocTest<WifiCubit, WifiState>(
      'a refused join records the SSID alongside the message, so a stale '
      'name can never outlive the banner that used it',
      build: () => WifiCubit(
        repository: _repo(_FakeWifiClient(connectFails: true)),
      ),
      act: (cubit) async {
        await cubit.load();
        await cubit.connect('Studio 5G', psk: 'nope');
      },
      verify: (cubit) {
        expect(cubit.state.failedSsid, 'Studio 5G');
        expect(cubit.state.errorMessage, isNotNull);
      },
    );

    blocTest<WifiCubit, WifiState>(
      'the next attempt clears both together',
      build: () {
        final client = _FakeWifiClient(connectFails: true);
        return WifiCubit(repository: _repo(client));
      },
      act: (cubit) async {
        await cubit.load();
        await cubit.connect('Studio 5G', psk: 'nope');
        await cubit.scan();
      },
      verify: (cubit) {
        expect(cubit.state.failedSsid, isNull);
        expect(cubit.state.errorMessage, isNull);
      },
    );

    blocTest<WifiCubit, WifiState>(
      'cancelConnect drops the in-flight marker and disconnects — the only '
      'thing still true once the helper call has been issued',
      build: () => WifiCubit(repository: _repo(_FakeWifiClient())),
      act: (cubit) async {
        await cubit.load();
        final joining = cubit.connect('Studio 5G');
        expect(cubit.state.connectingSsid, 'Studio 5G');
        await joining;
        await cubit.connect('Studio 5G');
        await cubit.cancelConnect();
      },
      verify: (cubit) {
        expect(cubit.state.connectingSsid, isNull);
      },
    );

    blocTest<WifiCubit, WifiState>(
      'cancelConnect with nothing in flight emits nothing',
      build: () => WifiCubit(repository: _repo(_FakeWifiClient())),
      act: (cubit) async {
        await cubit.load();
        final before = cubit.state;
        await cubit.cancelConnect();
        expect(cubit.state, before);
      },
    );
  });

  // The #824 boot race reached the owner as "wrong password" and taught them
  // to forget the network and re-type a correct key — destroying the
  // evidence. A backend/transient failure must re-activate, bounded, and must
  // never classify as credentials; only a genuine rejection may (#829).
  group('a backend failure is not a wrong password', () {
    const iwdRace =
        'ProcessException: Activation: (wifi) Network.Connect failed: '
        'GDBus.Error:net.connman.iwd.Failed';
    const noSecrets =
        'Error: Connection activation failed: (7) Secrets were required, '
        'but not provided.';
    const zeroBackoff = [Duration.zero, Duration.zero];

    blocTest<WifiCubit, WifiState>(
      'an iwd backend refusal re-activates with backoff and, exhausted, '
      'surfaces as transient — never as credentials',
      build: () => WifiCubit(
        repository: _repo(
          _FakeWifiClient()
            ..connectErrors.addAll([
              StateError(iwdRace),
              StateError(iwdRace),
              StateError(iwdRace),
            ]),
        ),
        retryDelays: zeroBackoff,
      ),
      act: (cubit) async {
        await cubit.load();
        await cubit.connect('MyHouseWTF_es_2.4G');
      },
      verify: (cubit) {
        expect(cubit.state.errorKind, WifiJoinErrorKind.transient);
        expect(cubit.state.failedSsid, 'MyHouseWTF_es_2.4G');
        expect(cubit.state.retrying, isFalse);
        expect(cubit.state.connectingSsid, isNull);
      },
    );

    test(
      'the bounded retry issues one re-activation per backoff slot',
      () async {
        final client = _FakeWifiClient()
          ..connectErrors.addAll([
            StateError(iwdRace),
            StateError(iwdRace),
            StateError(iwdRace),
          ]);
        final cubit = WifiCubit(
          repository: _repo(client),
          retryDelays: zeroBackoff,
        );
        addTearDown(cubit.close);

        await cubit.load();
        await cubit.connect('Studio 5G');

        // Initial attempt + one per delay — then it stops. No infinite loop.
        expect(client.connects.length, 3);
      },
    );

    test(
      'a transient failure that recovers on retry connects silently',
      () async {
        final client = _FakeWifiClient()
          ..connectErrors.add(StateError(iwdRace));
        final cubit = WifiCubit(
          repository: _repo(client),
          retryDelays: zeroBackoff,
        );
        addTearDown(cubit.close);

        await cubit.load();
        final states = <WifiState>[];
        final sub = cubit.stream.listen(states.add);
        addTearDown(() => unawaited(sub.cancel()));
        await cubit.connect('Studio 5G');

        expect(client.connects.length, 2);
        expect(cubit.state.status.connected, isTrue);
        expect(cubit.state.errorMessage, isNull);
        // The retry announced itself while in flight.
        expect(states.any((s) => s.retrying), isTrue);
        expect(cubit.state.retrying, isFalse);
      },
    );

    blocTest<WifiCubit, WifiState>(
      'no-secrets on an autonomous saved-network join is the #824 race: '
      'transient, retried, and never the password prompt',
      build: () => WifiCubit(
        repository: _repo(
          _FakeWifiClient()
            ..connectErrors.addAll([
              StateError(noSecrets),
              StateError(noSecrets),
              StateError(noSecrets),
            ]),
        ),
        retryDelays: zeroBackoff,
      ),
      // No psk: a saved/open network join carries no fresh password.
      act: (cubit) async {
        await cubit.load();
        await cubit.connect('MyHouseWTF_es_2.4G');
      },
      verify: (cubit) {
        expect(cubit.state.errorKind, WifiJoinErrorKind.transient);
        expect(cubit.state.errorKind, isNot(WifiJoinErrorKind.credentials));
      },
    );

    blocTest<WifiCubit, WifiState>(
      'the same no-secrets right after the user typed a password is a '
      'credentials rejection: no retry, straight to the prompt path',
      build: () => WifiCubit(
        repository: _repo(
          _FakeWifiClient()..connectErrors.add(StateError(noSecrets)),
        ),
        retryDelays: zeroBackoff,
      ),
      act: (cubit) async {
        await cubit.load();
        await cubit.connect('Studio 5G', psk: 'typed-just-now');
      },
      verify: (cubit) {
        expect(cubit.state.errorKind, WifiJoinErrorKind.credentials);
        expect(cubit.state.failedSsid, 'Studio 5G');
      },
    );

    test('a credentials rejection does not re-activate', () async {
      final client = _FakeWifiClient()
        ..connectErrors.add(StateError('authentication failed'));
      final cubit = WifiCubit(
        repository: _repo(client),
        retryDelays: zeroBackoff,
      );
      addTearDown(cubit.close);

      await cubit.load();
      await cubit.connect('Studio 5G', psk: 'wrong-password');

      expect(client.connects.length, 1);
      expect(cubit.state.errorKind, WifiJoinErrorKind.credentials);
    });

    test('cancelConnect during the backoff stops the retry loop', () async {
      final client = _FakeWifiClient()..connectErrors.add(StateError(iwdRace));
      final cubit = WifiCubit(
        repository: _repo(client),
        retryDelays: const [Duration(milliseconds: 50)],
      );
      addTearDown(cubit.close);

      await cubit.load();
      final pending = cubit.connect('Studio 5G');
      await pumpEventQueue();
      expect(cubit.state.retrying, isTrue);

      await cubit.cancelConnect();
      await pending;

      // The queued re-activation never fired.
      expect(client.connects.length, 1);
      expect(cubit.state.connectingSsid, isNull);
      expect(cubit.state.retrying, isFalse);
    });

    test('closing the cubit during the backoff stops the retry loop', () async {
      final client = _FakeWifiClient()..connectErrors.add(StateError(iwdRace));
      final cubit = WifiCubit(
        repository: _repo(client),
        retryDelays: const [Duration(milliseconds: 50)],
      );

      await cubit.load();
      final pending = cubit.connect('Studio 5G');
      await pumpEventQueue();
      await cubit.close();

      await expectLater(pending, completes);
      expect(client.connects.length, 1);
    });
  });

  // Closing mid-flight is the network tray's ordinary shape: the helper calls
  // are slow (seconds on the appliance) and the tray is dismissible the whole
  // time. Without the post-await guards the continuation lands on a closed
  // cubit and throws `Bad state: Cannot emit new states after calling close`
  // — observed six times from `load` in the appliance log.
  group('WifiCubit closing mid-flight', () {
    test(
      'load survives the tray closing while status is in flight',
      () async {
        final client = _FakeWifiClient()..statusGate = Completer<void>();
        final cubit = WifiCubit(repository: _repo(client));

        final pending = cubit.load();
        await pumpEventQueue();
        await cubit.close();
        client.statusGate!.complete();

        await expectLater(pending, completes);
      },
    );

    test('load survives the tray closing while status is failing', () async {
      final client = _FakeWifiClient()..statusGate = Completer<void>();
      final cubit = WifiCubit(repository: _repo(client));

      final pending = cubit.load();
      await pumpEventQueue();
      await cubit.close();
      client.statusGate!.completeError(StateError('helper missing'));

      await expectLater(pending, completes);
    });

    test(
      'scan survives the tray closing while the scan is in flight',
      () async {
        final client = _FakeWifiClient();
        final cubit = WifiCubit(repository: _repo(client));
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
      'scan survives the tray closing while the scan is failing',
      () async {
        final client = _FakeWifiClient();
        final cubit = WifiCubit(repository: _repo(client));
        await cubit.load();

        client.scanGate = Completer<void>();
        final pending = cubit.scan();
        await pumpEventQueue();
        await cubit.close();
        client.scanGate!.completeError(StateError('scan refused'));

        await expectLater(pending, completes);
      },
    );

    test(
      'connect survives the tray closing while the join is in flight',
      () async {
        final client = _FakeWifiClient()..connectGate = Completer<void>();
        final cubit = WifiCubit(repository: _repo(client));
        await cubit.load();

        final pending = cubit.connect('Home', psk: 'secret');
        await pumpEventQueue();
        await cubit.close();
        client.connectGate!.complete();

        await expectLater(pending, completes);
      },
    );

    // The failure arm refreshes status before it reports, so its guard has to
    // sit after that second await rather than at the top of the catch.
    test(
      'connect survives the tray closing while the join is failing',
      () async {
        final client = _FakeWifiClient()..connectGate = Completer<void>();
        final cubit = WifiCubit(repository: _repo(client));
        await cubit.load();

        final pending = cubit.connect('Home', psk: 'secret');
        await pumpEventQueue();
        await cubit.close();
        client.connectGate!.completeError(StateError('auth failed'));

        await expectLater(pending, completes);
      },
    );
  });
}
