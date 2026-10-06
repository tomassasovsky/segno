import 'package:flutter/material.dart';
import 'package:segno/wifi/wifi_tray_body.dart';

/// The Network domain: the Wi-Fi face, which draws its own title row with the
/// radio's rescan and power switch.
///
/// One radio, so no tab strip: Bluetooth was retired (#1199), and a strip
/// with one pill chooses nothing.
class NetworkTrayPanel extends StatelessWidget {
  /// Creates a [NetworkTrayPanel].
  const NetworkTrayPanel({super.key});

  @override
  Widget build(BuildContext context) => const KeyedSubtree(
    key: Key('network_tray_panel'),
    child: WifiTrayBody(),
  );
}
