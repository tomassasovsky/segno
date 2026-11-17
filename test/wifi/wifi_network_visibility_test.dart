import 'package:flutter_test/flutter_test.dart';
import 'package:segno/wifi/wifi_cubit.dart';
import 'package:segno/wifi/wifi_network_visibility.dart';
import 'package:wifi_repository/wifi_repository.dart';

void main() {
  const studio = WifiNetwork(ssid: 'Studio', signal: 80, secured: true);
  const guest = WifiNetwork(ssid: 'Guest', signal: 40, secured: false);

  test('keeps the joining SSID in the list while connect is in flight', () {
    final visible = visibleWifiNetworks(
      const WifiState(networks: [studio, guest], connectingSsid: 'Studio'),
    );
    expect(visible, [studio, guest]);
  });

  test('hides the associated SSID once connected', () {
    final visible = visibleWifiNetworks(
      const WifiState(
        networks: [studio, guest],
        status: WifiStatus(
          supported: true,
          enabled: true,
          connected: true,
          ssid: 'Studio',
          ip: '192.168.1.2',
          signal: 80,
        ),
      ),
    );
    expect(visible, [guest]);
  });

  group('the order', () {
    WifiNetwork network(
      String ssid,
      int signal, {
      bool saved = false,
      bool inRange = true,
    }) => WifiNetwork(
      ssid: ssid,
      signal: signal,
      secured: true,
      saved: saved,
      inRange: inRange,
    );

    List<String> order(List<WifiNetwork> networks) =>
        visibleWifiNetworks(WifiState(networks: networks))
            .map((n) => n.ssid)
            .toList();

    test('saved first, those out of range after the saved in range', () {
      expect(
        order([
          network('Cafe', 90),
          network('Away', 0, saved: true, inRange: false),
          network('Home', 40, saved: true),
        ]),
        ['Home', 'Away', 'Cafe'],
      );
    });

    test('then by bars, then by name', () {
      expect(
        order([
          network('zeta', 40),
          network('Alpha', 40),
          network('Strong', 90),
        ]),
        ['Strong', 'Alpha', 'zeta'],
      );
    });

    test('holds still while the reading moves within its bars', () {
      final first = order([network('B', 70), network('A', 68)]);
      final next = order([network('B', 68), network('A', 75)]);
      expect(first, ['A', 'B']);
      expect(next, first);
    });

    test('reads dBm the way the icon does', () {
      expect(wifiSignalBars(-55), 3);
      expect(wifiSignalBars(-65), 2);
      expect(wifiSignalBars(-80), 1);
      expect(wifiSignalBars(80), 3);
      expect(wifiSignalBars(50), 2);
      expect(wifiSignalBars(10), 1);
    });
  });
}
