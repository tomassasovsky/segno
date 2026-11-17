import 'package:segno/wifi/wifi_cubit.dart';
import 'package:wifi_repository/wifi_repository.dart';

/// Three bars, two or one, for a signal that is dBm on some paths and a
/// 0-100 quality on others.
int wifiSignalBars(int signal) => switch (signal) {
  < 0 when signal >= -60 => 3,
  < 0 when signal >= -72 => 2,
  < 0 => 1,
  >= 67 => 3,
  >= 34 => 2,
  _ => 1,
};

/// The rows of the network list, in the order they are shown.
///
/// Hides the network the console is on once [WifiStatus.connected], so it
/// appears only on the connection card; the one being joined stays, so its
/// row is still there.
///
/// The order holds still while the page scans every few seconds, the way
/// Android's Wi-Fi picker keeps it: saved networks first, then those in
/// range, then by signal bars (not the raw reading, which moves between two
/// scans), then by name. A network only moves when its bars change.
List<WifiNetwork> visibleWifiNetworks(WifiState state) {
  final connectedSsid = state.status.connected && state.status.ssid.isNotEmpty
      ? state.status.ssid
      : null;
  return [
    for (final network in state.networks)
      if (network.ssid != connectedSsid) network,
  ]..sort(_byListOrder);
}

int _byListOrder(WifiNetwork a, WifiNetwork b) {
  if (a.saved != b.saved) return a.saved ? -1 : 1;
  if (a.inRange != b.inRange) return a.inRange ? -1 : 1;
  if (a.inRange) {
    final bars = wifiSignalBars(b.signal) - wifiSignalBars(a.signal);
    if (bars != 0) return bars;
  }
  final name = a.ssid.toLowerCase().compareTo(b.ssid.toLowerCase());
  return name != 0 ? name : a.ssid.compareTo(b.ssid);
}
