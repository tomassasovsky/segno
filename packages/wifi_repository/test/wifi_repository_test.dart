import 'package:test/test.dart';
import 'package:wifi_repository/wifi_repository.dart';

class _FakeClient implements WifiClient {
  bool enabled = false;
  final autoConnect = <String, bool>{};
  final passwords = <String, String>{};
  bool internet = true;
  int connectivityChecks = 0;

  @override
  bool get isSupported => true;

  @override
  Future<WifiStatus> status() async => WifiStatus(
    supported: true,
    enabled: enabled,
    connected: false,
    autoConnect: Map.of(autoConnect),
  );

  @override
  Future<List<WifiNetwork>> scan() async => const [];

  @override
  Future<void> connect(String ssid, {String? psk}) async {}

  @override
  Future<void> disconnect() async {}

  @override
  Future<void> forget(String ssid) async {}

  @override
  Future<void> setEnabled({required bool enabled}) async {
    this.enabled = enabled;
  }

  @override
  Future<void> setAutoConnect(String ssid, {required bool enabled}) async {
    autoConnect[ssid] = enabled;
  }

  @override
  Future<void> changePassword(String ssid, String psk) async {
    passwords[ssid] = psk;
  }

  @override
  Future<bool> checkConnectivity() async {
    connectivityChecks++;
    return internet;
  }
}

void main() {
  test('setEnabled delegates to client', () async {
    final client = _FakeClient();
    final repo = WifiRepository(client: client);
    await repo.setEnabled(enabled: true);
    expect(client.enabled, isTrue);
    expect((await repo.status()).enabled, isTrue);
    expect((await repo.status()).connected, isFalse);
  });

  test('setAutoConnect delegates to client', () async {
    final client = _FakeClient();
    final repo = WifiRepository(client: client);
    await repo.setAutoConnect('The Studio', enabled: false);
    expect((await repo.status()).autoConnect, {'The Studio': false});
  });

  test('changePassword delegates to client', () async {
    final client = _FakeClient();
    await WifiRepository(
      client: client,
    ).changePassword('The Studio', 'n3w-s3cret');
    expect(client.passwords, {'The Studio': 'n3w-s3cret'});
  });

  test('checkConnectivity delegates to client, once per call', () async {
    final client = _FakeClient()..internet = false;
    final repo = WifiRepository(client: client);
    expect(await repo.checkConnectivity(), isFalse);
    expect(client.connectivityChecks, 1);
  });
}
