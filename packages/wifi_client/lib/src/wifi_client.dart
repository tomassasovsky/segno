import 'package:wifi_client/src/wifi_exception.dart';
import 'package:wifi_client/src/wifi_models.dart';

/// I/O boundary for appliance WiFi (`segno-wifi-ctl`). Faked in tests.
abstract class WifiClient {
  /// Whether the helper / radio stack is present.
  bool get isSupported;

  /// Current association + addressing.
  Future<WifiStatus> status();

  /// Nearby networks from a scan.
  Future<List<WifiNetwork>> scan();

  /// One event for each change NetworkManager announces: the Wi-Fi device
  /// connecting, connected or dropped, the radio going off, a saved network
  /// added or removed. Carries no state; read [status] after a burst.
  ///
  /// Listening starts one long-lived helper process
  /// (`segno-wifi-ctl monitor`), and cancelling stops it. The stream ends
  /// when the helper does.
  Stream<void> changes();

  /// Join [ssid]; [psk] null/empty for open networks.
  ///
  /// A failed join throws a [WifiHelperException]: [WifiHelperException.join]
  /// says why, and the helper has by then brought back the network that was
  /// active before it started, when there was one:
  /// [WifiHelperException.restored] names it. A failed join never deletes a
  /// saved network; a profile made for a new one is removed.
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

  /// While [hold] is true, the appliance's background reconnect after a WiFi
  /// drop (`segno-wifi-retry`) neither scans nor joins; it catches up once
  /// released. Held for the length of a performance, so a reconnect scan never
  /// takes the radio off-channel mid-show (#1337).
  Future<void> holdReconnects({required bool hold});
}
