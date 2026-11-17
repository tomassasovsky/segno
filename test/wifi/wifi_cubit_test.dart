import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/wifi/wifi_cubit.dart';
import 'package:wifi_repository/wifi_repository.dart';

class _FakeWifiClient implements WifiClient {
  new({
    this.supported = true,
    this.connectFails = false,
    WifiStatus? status,
    List<WifiNetwork>? networks,
  }) : statusValue =
           status ??
           const WifiStatus(supported: true, enabled: true, connected: false),
       networks = List.of(networks ?? const []);

  bool supported;

  /// When true, every [connect] refuses the way the supplicant does.
  bool connectFails;

  /// Scripted refusals: each [connect] throws the next entry until the list
  /// is exhausted, then succeeds. Lets a test shape the exact stack wording
  /// (iwd race vs wrong password) and count re-activations.
  final List<Object> connectErrors = [];
  WifiStatus statusValue;
  List<WifiNetwork> networks;
  final connects = <(String, String?)>[];
  int disconnectCalls = 0;
  final forgotten = <String>[];

  /// What [status] reads after a [forget], when set.
  WifiStatus? statusAfterForget;
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
    statusReads++;
    final gate = statusGate;
    if (gate != null) await gate.future;
    return statusValue;
  }

  @override
  Future<List<WifiNetwork>> scan() async {
    scans++;
    final gate = scanGate;
    if (gate != null) await gate.future;
    return networks;
  }

  /// How many scans ran.
  int scans = 0;

  /// How many reads of [status] ran.
  int statusReads = 0;

  /// What the helper's monitor announces; [monitors] counts listeners.
  final monitor = StreamController<void>.broadcast();
  int monitors = 0;

  @override
  Stream<void> changes() {
    monitors++;
    return monitor.stream;
  }

  @override
  Future<void> connect(String ssid, {String? psk}) async {
    connects.add((ssid, psk));
    final gate = connectGate;
    if (gate != null) await gate.future;
    if (connectErrors.isNotEmpty) {
      // An Error or the helper's WifiHelperException, as the test scripts it.
      Error.throwWithStackTrace(connectErrors.removeAt(0), StackTrace.current);
    }
    if (connectFails) {
      throw const WifiHelperException(
        'segno-wifi-ctl: join failed: wrong-password',
        join: WifiJoinError.wrongPassword,
      );
    }
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
    final after = statusAfterForget;
    if (after != null) statusValue = after;
    networks = [
      for (final n in networks)
        if (n.ssid != ssid) n,
    ];
    if (after == null && statusValue.ssid == ssid) {
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

  final autoConnectCalls = <(String, bool)>[];
  final passwordChanges = <(String, String)>[];

  /// What the internet check answers.
  bool internet = true;
  int connectivityChecks = 0;

  @override
  Future<void> setAutoConnect(String ssid, {required bool enabled}) async {
    autoConnectCalls.add((ssid, enabled));
    statusValue = _withAutoConnect({...statusValue.autoConnect, ssid: enabled});
  }

  @override
  Future<void> changePassword(String ssid, String psk) async {
    passwordChanges.add((ssid, psk));
  }

  @override
  Future<bool> checkConnectivity() async {
    connectivityChecks++;
    return internet;
  }

  @override
  Future<void> holdReconnects({required bool hold}) async {}

  WifiStatus _withAutoConnect(Map<String, bool> autoConnect) => WifiStatus(
    supported: statusValue.supported,
    enabled: statusValue.enabled,
    connected: statusValue.connected,
    ssid: statusValue.ssid,
    ip: statusValue.ip,
    signal: statusValue.signal,
    autoConnect: autoConnect,
    lastSsid: statusValue.lastSsid,
  );
}

WifiRepository _repo(_FakeWifiClient client) => WifiRepository(client: client);

/// Waits until the join loop has actually entered its backoff.
///
/// `pumpEventQueue()` cannot express this. `retrying: true` is emitted
/// immediately before `await Future.delayed(...)`, so on a loaded runner a
/// pump that itself outlasts the backoff lets the retry complete and finds the
/// flag already false again — which is exactly how this suite failed in CI
/// while passing locally. Waiting on the emission is what "inside the backoff"
/// means; the delay below then only has to outlast the handful of microtasks
/// between that emission and the act under test.
Future<void> enterBackoff(WifiCubit cubit) =>
    cubit.stream.firstWhere((s) => s.retrying);

/// Long enough that the act under test lands inside the window even on a
/// contended runner, short enough that awaiting the abandoned timer out (the
/// backoff is a plain `Future.delayed` and cannot be cancelled) stays cheap.
const backoffWindow = Duration(milliseconds: 300);

void main() {
  group('WifiCubit', () {
    blocTest<WifiCubit, WifiState>(
      'load marks unsupported when helper missing',
      build: () => WifiCubit(
        repository: _repo(
          _FakeWifiClient(supported: false, status: WifiStatus.unsupported),
        ),
      ),
      act: (cubit) => cubit.load(),
      expect: () => [const WifiState(busy: true), const WifiState()],
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
      'setEnabled switches the radio',
      build: () => WifiCubit(repository: _repo(_FakeWifiClient())),
      act: (cubit) async {
        await cubit.load();
        await cubit.setEnabled(enabled: false);
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
      build: () =>
          WifiCubit(repository: _repo(_FakeWifiClient(connectFails: true))),
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

  // On 2026-11-17 a WiFi 6 router timed out the 802.11 authentication (iwd
  // status 16), NM ended the join as `no-secrets`, and the page said
  // "Incorrect password" for a key the access point never tested (#1817). The
  // helper now says why a join failed; the cubit takes its word, retries only
  // a failed connection, and never reads a password into anything else.
  group('why a join failed', () {
    const noConnection = WifiHelperException(
      'segno-wifi-ctl: join failed: no-connection (connect-failed, status: 16)',
      join: WifiJoinError.noConnection,
    );
    const wrongPassword = WifiHelperException(
      'segno-wifi-ctl: join failed: wrong-password',
      join: WifiJoinError.wrongPassword,
    );
    const zeroBackoff = [Duration.zero, Duration.zero];

    Future<WifiCubit> failing(
      _FakeWifiClient client, {
      List<Duration> delays = zeroBackoff,
    }) async {
      final cubit = WifiCubit(repository: _repo(client), retryDelays: delays);
      addTearDown(cubit.close);
      await cubit.load();
      return cubit;
    }

    test('a failed connection after a typed key is not the key', () async {
      final client = _FakeWifiClient()
        ..connectErrors.addAll([noConnection, noConnection, noConnection]);
      final cubit = await failing(client);

      await cubit.connect('MyHouseWTF_es', psk: 'typed-just-now');
      expect(cubit.state.joinError, WifiJoinError.noConnection);
      expect(cubit.state.failedSsid, 'MyHouseWTF_es');
      expect(cubit.state.retrying, isFalse);
      expect(cubit.state.connectingSsid, isNull);
    });

    test(
      'a key the access point refused is the key, and not retried',
      () async {
        final client = _FakeWifiClient()..connectErrors.add(wrongPassword);
        final cubit = await failing(client);

        await cubit.connect('Studio 5G', psk: 'wrong-password');
        expect(client.connects.length, 1);
        expect(cubit.state.joinError, WifiJoinError.wrongPassword);
      },
    );

    test('each reason the helper gives is kept', () async {
      for (final reason in WifiJoinError.values) {
        final client = _FakeWifiClient()
          ..connectErrors.addAll([
            for (var i = 0; i < 3; i++)
              WifiHelperException('segno-wifi-ctl: x', join: reason),
          ]);
        final cubit = await failing(client);
        await cubit.connect('Cafe');
        expect(cubit.state.joinError, reason, reason: '$reason');
      }
    });

    test("a failure that is not the helper's is a failed connection", () async {
      final client = _FakeWifiClient()
        ..connectErrors.addAll([
          StateError('spawn failed'),
          StateError('spawn failed'),
          StateError('spawn failed'),
        ]);
      final cubit = await failing(client);
      await cubit.connect('Cafe');
      expect(cubit.state.joinError, WifiJoinError.noConnection);
    });

    test('only a failed connection is retried', () async {
      for (final (reason, attempts) in [
        (WifiJoinError.noConnection, 3),
        (WifiJoinError.wrongPassword, 1),
        (WifiJoinError.notFound, 1),
        (WifiJoinError.noAddress, 1),
      ]) {
        final client = _FakeWifiClient()
          ..connectErrors.addAll([
            for (var i = 0; i < 3; i++)
              WifiHelperException('segno-wifi-ctl: x', join: reason),
          ]);
        final cubit = await failing(client);
        await cubit.connect('Cafe');
        // Initial attempt + one per delay at most. No infinite loop.
        expect(client.connects.length, attempts, reason: '$reason');
      }
    });

    test(
      'a failed connection that recovers on retry connects silently',
      () async {
        final client = _FakeWifiClient()..connectErrors.add(noConnection);
        final cubit = await failing(client);
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

    group('Try again', () {
      test(
        'joins the failed network again with the key it was given',
        () async {
          final client = _FakeWifiClient()
            ..connectErrors.addAll([noConnection, noConnection, noConnection]);
          final cubit = await failing(client);
          await cubit.connect('MyHouseWTF_es', psk: 'typed-once');
          client.connects.clear();

          await cubit.retry();
          expect(client.connects, [('MyHouseWTF_es', 'typed-once')]);
          expect(cubit.state.status.ssid, 'MyHouseWTF_es');
          expect(cubit.state.failedSsid, isNull);
        },
      );

      test('does nothing after a wrong password', () async {
        final client = _FakeWifiClient()..connectErrors.add(wrongPassword);
        final cubit = await failing(client);
        await cubit.connect('Studio 5G', psk: 'wrong');
        client.connects.clear();

        await cubit.retry();
        expect(client.connects, isEmpty);
      });

      test('does nothing once the failure is gone', () async {
        final client = _FakeWifiClient()
          ..connectErrors.addAll([noConnection, noConnection, noConnection]);
        final cubit = await failing(client);
        await cubit.connect('Cafe');
        await cubit.scan();
        client.connects.clear();

        await cubit.retry();
        expect(client.connects, isEmpty);
      });

      test('forgets the key after a join that worked', () async {
        final client = _FakeWifiClient()
          ..connectErrors.addAll([noConnection, noConnection, noConnection]);
        final cubit = await failing(client);
        await cubit.connect('Cafe', psk: 'k3y-one');
        await cubit.connect('Cafe');
        client.connects.clear();

        await cubit.retry();
        expect(client.connects, isEmpty);
      });
    });

    test('cancelConnect during the backoff stops the retry loop', () async {
      final client = _FakeWifiClient()..connectErrors.add(noConnection);
      final cubit = await failing(client, delays: const [backoffWindow]);

      final pending = cubit.connect('Studio 5G');
      await enterBackoff(cubit);
      expect(cubit.state.retrying, isTrue);

      await cubit.cancelConnect();
      await pending;

      // The queued re-activation never fired.
      expect(client.connects.length, 1);
      expect(cubit.state.connectingSsid, isNull);
      expect(cubit.state.retrying, isFalse);
      // No helper was running, so the link was left alone: the network the
      // helper brought back stays up, and NetworkManager may still rejoin.
      expect(client.disconnectCalls, 0);
    });

    test(
      'cancel then re-tap of the SAME network mid-backoff leaves exactly one '
      'live loop — the abandoned one neither re-activates nor emits',
      () async {
        final client = _FakeWifiClient()..connectErrors.add(noConnection);
        final cubit = await failing(client, delays: const [backoffWindow]);

        final first = cubit.connect('Studio 5G');
        await enterBackoff(cubit);
        expect(cubit.state.retrying, isTrue);

        await cubit.cancelConnect();
        // Same SSID, inside the old join's backoff window — the marker alone
        // could not tell the two joins apart.
        final second = cubit.connect('Studio 5G');
        await pumpEventQueue();
        expect(cubit.state.status.connected, isTrue);

        // Let the abandoned loop's timer fire, then prove it went silent:
        // no third activation, and no emit over the successful join.
        await first;
        await second;
        await Future<void>.delayed(
          backoffWindow + const Duration(milliseconds: 60),
        );
        expect(client.connects.length, 2);
        expect(cubit.state.status.connected, isTrue);
        expect(cubit.state.errorMessage, isNull);
        expect(cubit.state.retrying, isFalse);
      },
    );

    test('cancelConnect while the helper call is in flight cannot leave '
        '`retrying` stuck — the abandoned catch never emits', () async {
      final client = _FakeWifiClient()
        ..connectErrors.add(noConnection)
        ..connectGate = Completer<void>();
      final cubit = await failing(
        client,
        delays: const [Duration(milliseconds: 50)],
      );

      final pending = cubit.connect('Studio 5G');
      await pumpEventQueue();
      await cubit.cancelConnect();
      // The helper call now fails into the abandoned loop's catch.
      client.connectGate!.complete();
      await pending;

      expect(cubit.state.retrying, isFalse);
      expect(cubit.state.connectingSsid, isNull);
      expect(cubit.state.errorMessage, isNull);
      expect(client.connects.length, 1);
    });

    test('closing the cubit during the backoff stops the retry loop', () async {
      final client = _FakeWifiClient()..connectErrors.add(noConnection);
      final cubit = WifiCubit(
        repository: _repo(client),
        retryDelays: const [backoffWindow],
      );

      await cubit.load();
      final pending = cubit.connect('Studio 5G');
      await enterBackoff(cubit);
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
    test('load survives the tray closing while status is in flight', () async {
      final client = _FakeWifiClient()..statusGate = Completer<void>();
      final cubit = WifiCubit(repository: _repo(client));

      final pending = cubit.load();
      await pumpEventQueue();
      await cubit.close();
      client.statusGate!.complete();

      await expectLater(pending, completes);
    });

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

    test('scan survives the tray closing while the scan is failing', () async {
      final client = _FakeWifiClient();
      final cubit = WifiCubit(repository: _repo(client));
      await cubit.load();

      client.scanGate = Completer<void>();
      final pending = cubit.scan();
      await pumpEventQueue();
      await cubit.close();
      client.scanGate!.completeError(StateError('scan refused'));

      await expectLater(pending, completes);
    });

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

  group('connection lost', () {
    const studio = WifiStatus(
      supported: true,
      enabled: true,
      connected: false,
      autoConnect: {'The Studio': true},
      lastSsid: 'The Studio',
    );

    test('the saved network that was up, radio on, nothing joined', () async {
      final cubit = WifiCubit(
        repository: _repo(_FakeWifiClient(status: studio)),
      );
      addTearDown(cubit.close);
      await cubit.load();

      expect(cubit.state.lostSsid, 'The Studio');
    });

    test('not while the radio is off', () async {
      final cubit = WifiCubit(
        repository: _repo(
          _FakeWifiClient(
            status: const WifiStatus(
              supported: true,
              enabled: false,
              connected: false,
              autoConnect: {'The Studio': true},
              lastSsid: 'The Studio',
            ),
          ),
        ),
      );
      addTearDown(cubit.close);
      await cubit.load();

      expect(cubit.state.lostSsid, isNull);
    });

    test('not for a network that is no longer saved', () async {
      final cubit = WifiCubit(
        repository: _repo(
          _FakeWifiClient(
            status: const WifiStatus(
              supported: true,
              enabled: true,
              connected: false,
              lastSsid: 'The Studio',
            ),
          ),
        ),
      );
      addTearDown(cubit.close);
      await cubit.load();

      expect(cubit.state.lostSsid, isNull);
    });

    test('not after Disconnect, and again once a later link drops', () async {
      final client = _FakeWifiClient(
        status: const WifiStatus(
          supported: true,
          enabled: true,
          connected: true,
          ssid: 'The Studio',
          autoConnect: {'The Studio': true},
          lastSsid: 'The Studio',
        ),
      );
      final cubit = WifiCubit(repository: _repo(client));
      addTearDown(cubit.close);
      await cubit.load();

      await cubit.disconnect();
      client.statusValue = studio;
      await cubit.scan();
      expect(cubit.state.lostSsid, isNull);

      // Back on it, then dropped without being asked: lost.
      await cubit.connect('The Studio');
      expect(cubit.state.status.connected, isTrue);
      client.statusValue = studio;
      await cubit.scan();
      expect(cubit.state.lostSsid, 'The Studio');
    });

    test(
      'not for the network that was up before one that was forgotten',
      () async {
        final client = _FakeWifiClient(
          status: const WifiStatus(
            supported: true,
            enabled: true,
            connected: true,
            ssid: 'Rehearsal',
            autoConnect: {'The Studio': true, 'Rehearsal': true},
            lastSsid: 'Rehearsal',
          ),
        )..statusAfterForget = studio;
        final cubit = WifiCubit(repository: _repo(client));
        addTearDown(cubit.close);
        await cubit.load();

        await cubit.forget('Rehearsal');
        expect(cubit.state.status.lastSsid, 'The Studio');
        expect(cubit.state.lostSsid, isNull);
      },
    );

    test('not after a join is cancelled', () async {
      final client = _FakeWifiClient(status: studio)
        ..connectErrors.add(StateError('association took too long'));
      final cubit = WifiCubit(
        repository: _repo(client),
        retryDelays: const [backoffWindow],
      );
      addTearDown(cubit.close);
      await cubit.load();
      client.statusValue = studio;

      final pending = cubit.connect('Rehearsal', psk: 'goodpass');
      await enterBackoff(cubit);
      await cubit.cancelConnect();
      await pending;
      expect(cubit.state.lostSsid, isNull);
    });

    test('not while the radio switch brings it back on its own', () async {
      final client = _FakeWifiClient(
        status: const WifiStatus(
          supported: true,
          enabled: false,
          connected: false,
          autoConnect: {'The Studio': true},
          lastSsid: 'The Studio',
        ),
      );
      final cubit = WifiCubit(repository: _repo(client));
      addTearDown(cubit.close);
      await cubit.load();

      await cubit.setEnabled(enabled: true);
      expect(cubit.state.status.enabled, isTrue);
      expect(cubit.state.lostSsid, isNull);
    });
  });

  group('cancel leaves the console where it started', () {
    const onStudio = WifiStatus(
      supported: true,
      enabled: true,
      connected: true,
      ssid: 'The Studio',
      autoConnect: {'The Studio': true},
      lastSsid: 'The Studio',
    );

    test('a cancel while the helper runs ends its activation', () async {
      final client = _FakeWifiClient(status: onStudio)
        ..connectGate = Completer<void>()
        ..connectErrors.add(
          const WifiHelperException(
            'segno-wifi-ctl: connection failed',
            restored: 'The Studio',
          ),
        );
      final cubit = WifiCubit(repository: _repo(client));
      addTearDown(cubit.close);
      await cubit.load();

      final pending = cubit.connect('Rehearsal', psk: 'goodpass');
      await pumpEventQueue();
      await cubit.cancelConnect();
      expect(client.disconnectCalls, 1);
      client
        ..statusValue = onStudio
        ..connectGate!.complete();
      await pending;

      // The helper brought The Studio back; nothing more is done.
      expect(client.connects, [('Rehearsal', 'goodpass')]);
      expect(cubit.state.status.ssid, 'The Studio');
      expect(cubit.state.errorMessage, isNull);
    });

    test('a join that went through after Cancel is undone', () async {
      final client = _FakeWifiClient(status: onStudio)
        ..connectGate = Completer<void>();
      final cubit = WifiCubit(repository: _repo(client));
      addTearDown(cubit.close);
      await cubit.load();

      final pending = cubit.connect('Rehearsal', psk: 'goodpass');
      await pumpEventQueue();
      await cubit.cancelConnect();
      client.connectGate!.complete();
      await pending;

      // Saved by this join, so forgotten; and The Studio is back.
      expect(client.forgotten, ['Rehearsal']);
      expect(client.connects.last, ('The Studio', null));
      expect(cubit.state.status.ssid, 'The Studio');
      expect(cubit.state.connectingSsid, isNull);
    });

    test('a saved network joined after Cancel, with nothing up before, is '
        'disconnected and kept', () async {
      final client = _FakeWifiClient(
        status: const WifiStatus(
          supported: true,
          enabled: true,
          connected: false,
          autoConnect: {'Rehearsal': true},
        ),
      )..connectGate = Completer<void>();
      final cubit = WifiCubit(repository: _repo(client));
      addTearDown(cubit.close);
      await cubit.load();

      final pending = cubit.connect('Rehearsal');
      await pumpEventQueue();
      await cubit.cancelConnect();
      client.connectGate!.complete();
      await pending;

      expect(client.forgotten, isEmpty);
      expect(client.disconnectCalls, 2);
      expect(cubit.state.status.connected, isFalse);
    });

    test('a previous network the helper could not bring back is', () async {
      final client = _FakeWifiClient(status: onStudio)
        ..connectGate = Completer<void>()
        ..connectErrors.add(
          const WifiHelperException('segno-wifi-ctl: connection failed'),
        );
      final cubit = WifiCubit(repository: _repo(client));
      addTearDown(cubit.close);
      await cubit.load();

      final pending = cubit.connect('Rehearsal', psk: 'goodpass');
      await pumpEventQueue();
      await cubit.cancelConnect();
      client.connectGate!.complete();
      await pending;

      expect(client.connects.last, ('The Studio', null));
      expect(cubit.state.status.ssid, 'The Studio');
    });

    test('a join after Cancel waits for the cancelled helper call', () async {
      final client = _FakeWifiClient(status: onStudio)
        ..connectGate = Completer<void>()
        ..connectErrors.add(
          const WifiHelperException(
            'segno-wifi-ctl: connection failed',
            restored: 'The Studio',
          ),
        );
      final cubit = WifiCubit(repository: _repo(client));
      addTearDown(cubit.close);
      await cubit.load();

      final first = cubit.connect('Rehearsal', psk: 'goodpass');
      await pumpEventQueue();
      await cubit.cancelConnect();
      client.statusValue = onStudio;

      final second = cubit.connect('Cafe');
      await pumpEventQueue();
      // Still one helper call: the second waits rather than racing it.
      expect(client.connects.length, 1);
      expect(cubit.state.connectingSsid, 'Cafe');

      final gate = client.connectGate!;
      client.connectGate = null;
      gate.complete();
      await first;
      await second;
      expect(client.connects.map((c) => c.$1), ['Rehearsal', 'Cafe']);
      expect(cubit.state.status.ssid, 'Cafe');
      expect(cubit.state.connectingSsid, isNull);
    });

    test(
      'a cancel while waiting for an earlier join takes nothing down',
      () async {
        final client = _FakeWifiClient(status: onStudio)
          ..connectGate = Completer<void>()
          ..connectErrors.add(
            const WifiHelperException(
              'segno-wifi-ctl: connection failed',
              restored: 'The Studio',
            ),
          );
        final cubit = WifiCubit(repository: _repo(client));
        addTearDown(cubit.close);
        await cubit.load();

        final first = cubit.connect('Rehearsal', psk: 'goodpass');
        await pumpEventQueue();
        await cubit.cancelConnect();
        expect(client.disconnectCalls, 1);
        client.statusValue = onStudio;

        final second = cubit.connect('Cafe');
        await pumpEventQueue();
        await cubit.cancelConnect();
        client.connectGate!.complete();
        await first;
        await second;

        expect(client.disconnectCalls, 1);
        expect(client.connects.map((c) => c.$1), ['Rehearsal']);
        expect(cubit.state.status.ssid, 'The Studio');
      },
    );
  });

  group('a failed join that brought the old network back', () {
    test('is not retried', () async {
      final client = _FakeWifiClient()
        ..connectErrors.add(
          const WifiHelperException(
            'segno-wifi-ctl: join failed: no-connection',
            restored: 'The Studio',
            join: WifiJoinError.noConnection,
          ),
        );
      final cubit = WifiCubit(
        repository: _repo(client),
        retryDelays: const [Duration.zero, Duration.zero],
      );
      addTearDown(cubit.close);
      await cubit.load();

      await cubit.connect('Rehearsal');
      expect(client.connects.length, 1);
      expect(cubit.state.joinError, WifiJoinError.noConnection);
      expect(cubit.state.failedSsid, 'Rehearsal');
    });

    test('can still be tried again by hand', () async {
      final client = _FakeWifiClient()
        ..connectErrors.add(
          const WifiHelperException(
            'segno-wifi-ctl: join failed: no-connection',
            restored: 'The Studio',
            join: WifiJoinError.noConnection,
          ),
        );
      final cubit = WifiCubit(repository: _repo(client));
      addTearDown(cubit.close);
      await cubit.load();

      await cubit.connect('Rehearsal', psk: 'k3y');
      await cubit.retry();
      expect(client.connects.last, ('Rehearsal', 'k3y'));
      expect(cubit.state.status.ssid, 'Rehearsal');
    });

    test('one that restored nothing is still retried', () async {
      final client = _FakeWifiClient()
        ..connectErrors.add(
          const WifiHelperException(
            'segno-wifi-ctl: join failed: no-connection',
            join: WifiJoinError.noConnection,
          ),
        );
      final cubit = WifiCubit(
        repository: _repo(client),
        retryDelays: const [Duration.zero, Duration.zero],
      );
      addTearDown(cubit.close);
      await cubit.load();

      await cubit.connect('Rehearsal');
      expect(client.connects.length, 2);
      expect(cubit.state.status.connected, isTrue);
    });
  });

  // A phone's Wi-Fi settings follow the console while they are open: the
  // connection live, the list rescanned every few seconds (#1817).
  group('while the page is open', () {
    const studio = WifiStatus(
      supported: true,
      enabled: true,
      connected: true,
      ssid: 'The Studio',
      ip: '10.0.0.5',
      autoConnect: {'The Studio': true},
      lastSsid: 'The Studio',
    );
    const dropped = WifiStatus(
      supported: true,
      enabled: true,
      connected: false,
      autoConnect: {'The Studio': true},
      lastSsid: 'The Studio',
    );
    const rejoining = WifiStatus(
      supported: true,
      enabled: true,
      connected: false,
      connecting: true,
      ssid: 'The Studio',
      autoConnect: {'The Studio': true},
      lastSsid: 'The Studio',
    );

    /// Runs [body] in fake time with a started cubit over [client].
    void open(
      _FakeWifiClient client,
      void Function(FakeAsync async, WifiCubit cubit) body,
    ) {
      fakeAsync((async) {
        final cubit = WifiCubit(
          repository: _repo(client),
          clock: async.getClock(DateTime(2026, 11, 17)).now,
        );
        unawaited(cubit.start());
        async.flushMicrotasks();
        body(async, cubit);
        unawaited(cubit.close());
        async.flushMicrotasks();
      });
    }

    test('follows a drop and a rejoin NetworkManager made by itself', () {
      final client = _FakeWifiClient(status: studio);
      open(client, (async, cubit) {
        expect(client.monitors, 1);

        client.statusValue = dropped;
        client.monitor.add(null);
        async.elapse(WifiCubit.changeSettle);
        expect(cubit.state.lostSsid, 'The Studio');

        client.statusValue = rejoining;
        client.monitor.add(null);
        async.elapse(WifiCubit.changeSettle);
        expect(cubit.state.status.connecting, isTrue);
        expect(cubit.state.lostSsid, isNull, reason: 'it is coming back');

        client.statusValue = studio;
        client.monitor.add(null);
        async.elapse(WifiCubit.changeSettle);
        expect(cubit.state.status.connected, isTrue);
        expect(cubit.state.status.ip, '10.0.0.5');
      });
    });

    test('a burst of changes is read once', () {
      final client = _FakeWifiClient(status: studio);
      open(client, (async, cubit) {
        final before = client.statusReads;
        for (var i = 0; i < 6; i++) {
          client.monitor.add(null);
          async.elapse(const Duration(milliseconds: 20));
        }
        async.elapse(WifiCubit.changeSettle);
        expect(client.statusReads - before, 1);
      });
    });

    test('a change during an action is read after it', () {
      final client = _FakeWifiClient(status: studio);
      open(client, (async, cubit) {
        // Made in fake time, so completing it runs there too.
        client.connectGate = Completer<void>();
        unawaited(cubit.connect('Rehearsal', psk: 'k3y'));
        async.flushMicrotasks();
        final before = client.statusReads;
        client.monitor.add(null);
        async.elapse(WifiCubit.changeSettle);
        expect(client.statusReads, before, reason: 'not while it runs');

        client.connectGate!.complete();
        async.flushMicrotasks();
        final after = client.statusReads;
        async.elapse(WifiCubit.changeSettle);
        expect(client.statusReads, after + 1);
      });
    });

    test('scans every 10 s, quietly, keeping a failure on screen', () {
      final client = _FakeWifiClient(status: studio)
        ..connectErrors.add(
          const WifiHelperException(
            'segno-wifi-ctl: join failed: not-found',
            join: WifiJoinError.notFound,
          ),
        );
      open(client, (async, cubit) {
        expect(client.scans, 1, reason: 'one scan on opening');
        unawaited(cubit.connect('Cafe'));
        async.flushMicrotasks();
        expect(cubit.state.joinError, WifiJoinError.notFound);

        final states = <WifiState>[];
        final sub = cubit.stream.listen(states.add);
        client.networks = const [
          WifiNetwork(ssid: 'Cafe', signal: 60, secured: false),
        ];
        async.elapse(WifiCubit.scanInterval);
        expect(client.scans, 2);
        expect(cubit.state.networks.map((n) => n.ssid), ['Cafe']);
        expect(states.any((s) => s.scanning), isFalse);
        expect(cubit.state.joinError, WifiJoinError.notFound);
        async.elapse(WifiCubit.scanInterval * 3);
        expect(client.scans, 5);
        unawaited(sub.cancel());
      });
    });

    test('no scan while the radio is off, a join runs or one is joining', () {
      final client = _FakeWifiClient(status: studio);
      open(client, (async, cubit) {
        client.connectGate = Completer<void>();
        final opened = client.scans;
        unawaited(cubit.connect('Rehearsal'));
        async
          ..flushMicrotasks()
          ..elapse(WifiCubit.scanInterval * 2);
        expect(client.scans, opened, reason: 'the page is joining');
        client.connectGate!.complete();
        async.flushMicrotasks();

        client.statusValue = rejoining;
        client.monitor.add(null);
        async.elapse(WifiCubit.changeSettle);
        final joining = client.scans;
        async.elapse(WifiCubit.scanInterval * 2);
        expect(client.scans, joining, reason: 'NetworkManager is joining');

        client.statusValue = const WifiStatus(
          supported: true,
          enabled: false,
          connected: false,
        );
        client.monitor.add(null);
        async.elapse(WifiCubit.changeSettle);
        final off = client.scans;
        async.elapse(WifiCubit.scanInterval * 2);
        expect(client.scans, off, reason: 'the radio is off');
      });
    });

    test('a radio switched on elsewhere is scanned at once', () {
      final client = _FakeWifiClient(
        status: const WifiStatus(
          supported: true,
          enabled: false,
          connected: false,
        ),
      );
      open(client, (async, cubit) {
        expect(client.scans, 0);
        client.statusValue = dropped;
        client.monitor.add(null);
        async.elapse(WifiCubit.changeSettle);
        expect(client.scans, 1);
      });
    });

    test('a Scan tap during the periodic scan joins it', () {
      final client = _FakeWifiClient(status: studio);
      open(client, (async, cubit) {
        client.scanGate = Completer<void>();
        async.elapse(WifiCubit.scanInterval);
        final running = client.scans;
        unawaited(cubit.scan());
        async.flushMicrotasks();
        expect(cubit.state.scanning, isTrue);
        client.scanGate!.complete();
        async.flushMicrotasks();
        expect(client.scans, running, reason: 'no second scan');
        expect(cubit.state.scanning, isFalse);
      });
    });

    test('checks the internet every 30 s', () {
      final client = _FakeWifiClient(status: studio);
      open(client, (async, cubit) {
        final opened = client.connectivityChecks;
        async.elapse(WifiCubit.connectivityInterval * 2);
        expect(client.connectivityChecks, opened + 2);
      });
    });

    test('a monitor that ends is started again', () {
      final client = _FakeWifiClient(status: studio);
      open(client, (async, cubit) {
        unawaited(client.monitor.close());
        async
          ..flushMicrotasks()
          ..elapse(WifiCubit.monitorRestart);
        expect(client.monitors, 2);
      });
    });

    test('nothing runs once the page has closed the cubit', () {
      final client = _FakeWifiClient(status: studio);
      fakeAsync((async) {
        final cubit = WifiCubit(repository: _repo(client));
        unawaited(cubit.start());
        async.flushMicrotasks();
        unawaited(cubit.close());
        async.flushMicrotasks();
        final scans = client.scans;
        final checks = client.connectivityChecks;
        final reads = client.statusReads;
        expect(client.monitor.hasListener, isFalse);
        async.elapse(const Duration(minutes: 2));
        expect(client.scans, scans);
        expect(client.connectivityChecks, checks);
        expect(client.statusReads, reads);
      });
    });

    test('an unsupported console starts nothing', () {
      final client = _FakeWifiClient(
        supported: false,
        status: WifiStatus.unsupported,
      );
      open(client, (async, cubit) {
        async.elapse(WifiCubit.scanInterval * 3);
        expect(client.monitors, 0);
        expect(client.scans, 0);
      });
    });
  });

  group('connectivity', () {
    const connected = WifiStatus(
      supported: true,
      enabled: true,
      connected: true,
      ssid: 'The Studio',
    );

    test('no answer while connected reads "No internet"', () async {
      final client = _FakeWifiClient(status: connected)..internet = false;
      final cubit = WifiCubit(repository: _repo(client));
      addTearDown(cubit.close);
      await cubit.load();

      expect(cubit.state.noInternet, isFalse);
      await cubit.checkConnectivity();
      expect(client.connectivityChecks, 1);
      expect(cubit.state.noInternet, isTrue);
    });

    test('an answer reads connected', () async {
      final client = _FakeWifiClient(status: connected);
      final cubit = WifiCubit(repository: _repo(client));
      addTearDown(cubit.close);
      await cubit.load();

      await cubit.checkConnectivity();
      expect(cubit.state.noInternet, isFalse);
    });

    test('never more often than every 30 s for one connection', () async {
      var now = DateTime(2026, 10, 7, 12);
      final client = _FakeWifiClient(status: connected);
      final cubit = WifiCubit(repository: _repo(client), clock: () => now);
      addTearDown(cubit.close);
      await cubit.load();

      await cubit.checkConnectivity();
      now = now.add(const Duration(seconds: 10));
      await cubit.checkConnectivity();
      now = now.add(const Duration(seconds: 14));
      await cubit.checkConnectivity();
      expect(client.connectivityChecks, 1);

      now = now.add(const Duration(seconds: 1));
      await cubit.checkConnectivity();
      expect(client.connectivityChecks, 2);
    });

    test(
      'every tick of the page timer checks, though status reads vary',
      () async {
        var now = DateTime(2026, 10, 7, 12);
        final client = _FakeWifiClient(status: connected);
        final cubit = WifiCubit(repository: _repo(client), clock: () => now);
        addTearDown(cubit.close);
        await cubit.load();

        // The timer ticks once per interval; a check can land late on one
        // tick (2 s here) and on time on the next.
        final tick = DateTime(2026, 10, 7, 12);
        now = tick.add(const Duration(seconds: 2));
        await cubit.checkConnectivity();
        now = tick.add(WifiCubit.connectivityInterval);
        await cubit.checkConnectivity();
        now = tick.add(WifiCubit.connectivityInterval * 2);
        await cubit.checkConnectivity();
        expect(client.connectivityChecks, 3);
      },
    );

    test('a new connection is checked at once', () async {
      final now = DateTime(2026, 10, 7, 12);
      final client = _FakeWifiClient(status: connected);
      final cubit = WifiCubit(repository: _repo(client), clock: () => now);
      addTearDown(cubit.close);
      await cubit.load();
      await cubit.checkConnectivity();

      await cubit.connect('Rehearsal', psk: 'goodpass');
      await cubit.checkConnectivity();
      expect(client.connectivityChecks, 2);
    });

    test('nothing is checked while not connected', () async {
      final client = _FakeWifiClient();
      final cubit = WifiCubit(repository: _repo(client));
      addTearDown(cubit.close);
      await cubit.load();

      await cubit.checkConnectivity();
      expect(client.connectivityChecks, 0);
    });

    test('nothing is checked once the page has closed the cubit', () async {
      final client = _FakeWifiClient(status: connected);
      final cubit = WifiCubit(repository: _repo(client));
      await cubit.load();
      await cubit.close();

      await cubit.checkConnectivity();
      expect(client.connectivityChecks, 0);
    });

    test('the answer belongs to the connection it was made over', () async {
      final client = _FakeWifiClient(status: connected)..internet = false;
      final cubit = WifiCubit(repository: _repo(client));
      addTearDown(cubit.close);
      await cubit.load();
      await cubit.checkConnectivity();
      expect(cubit.state.noInternet, isTrue);

      client.internet = true;
      await cubit.connect('Rehearsal', psk: 'goodpass');
      // Not checked yet: no stale "No internet" carried over.
      expect(cubit.state.noInternet, isFalse);
    });
  });

  group('saved network controls', () {
    test('Connect automatically goes to the helper and back', () async {
      final client = _FakeWifiClient(
        status: const WifiStatus(
          supported: true,
          enabled: true,
          connected: false,
          autoConnect: {'The Studio': true},
        ),
      );
      final cubit = WifiCubit(repository: _repo(client));
      addTearDown(cubit.close);
      await cubit.load();

      await cubit.setAutoConnect('The Studio', enabled: false);
      expect(client.autoConnectCalls, [('The Studio', false)]);
      expect(cubit.state.status.autoConnect, {'The Studio': false});
      expect(cubit.state.busy, isFalse);
    });

    test(
      'a new password for a network in range is tested by joining',
      () async {
        final client = _FakeWifiClient(
          networks: const [
            WifiNetwork(
              ssid: 'The Studio',
              signal: -40,
              secured: true,
              saved: true,
            ),
          ],
        );
        final cubit = WifiCubit(repository: _repo(client));
        addTearDown(cubit.close);
        await cubit.load();
        await cubit.scan();

        await cubit.changePassword('The Studio', 'n3w-s3cret');
        expect(client.connects, [('The Studio', 'n3w-s3cret')]);
        expect(client.passwordChanges, isEmpty);
      },
    );

    test('a new password for a network out of range is stored', () async {
      final client = _FakeWifiClient(
        networks: const [
          WifiNetwork(
            ssid: 'The Studio',
            signal: 0,
            secured: true,
            saved: true,
            inRange: false,
          ),
        ],
      );
      final cubit = WifiCubit(repository: _repo(client));
      addTearDown(cubit.close);
      await cubit.load();
      await cubit.scan();

      await cubit.changePassword('The Studio', 'n3w-s3cret');
      expect(client.passwordChanges, [('The Studio', 'n3w-s3cret')]);
      expect(client.connects, isEmpty);
    });
  });
}
