import 'package:wifi_client/src/wifi_models.dart';

/// I/O boundary for appliance WiFi (`segno-wifi-ctl`). Faked in tests.
abstract class WifiClient {
  /// Whether the helper / radio stack is present.
  bool get isSupported;

  /// Current association + addressing.
  Future<WifiStatus> status();

  /// Nearby networks from a scan.
  Future<List<WifiNetwork>> scan();

  /// Join [ssid]; [psk] null/empty for open networks.
  ///
  /// A failed join throws, and the helper has by then brought back the
  /// network that was active before it started, when there was one.
  Future<void> connect(String ssid, {String? psk});

  /// Drop the current association.
  Future<void> disconnect();

  /// Remove a saved network by [ssid].
  Future<void> forget(String ssid);

  /// Radio on/off (`segno-wifi-ctl radio`).
  Future<void> setEnabled({required bool enabled});

  /// Whether the saved network [ssid] is joined on its own.
  Future<void> setAutoConnect(String ssid, {required bool enabled});

  /// Stores [psk] as the saved network [ssid]'s key without joining it.
  Future<void> changePassword(String ssid, String psk);

  /// Whether the internet answers over the current link.
  Future<bool> checkConnectivity();
}
