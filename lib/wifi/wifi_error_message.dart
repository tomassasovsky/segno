import 'package:segno/l10n/l10n.dart';
import 'package:wifi_repository/wifi_repository.dart';

/// What the page says about a join of [ssid] that failed for [reason].
///
/// The helper decides [reason] from what wpa_supplicant logged (#1817,
/// #1843), so only a key the access point refused reads as a wrong password;
/// everything else names the network and is offered again.
String wifiJoinErrorMessage(
  AppLocalizations l10n,
  WifiJoinError reason,
  String ssid,
) => switch (reason) {
  WifiJoinError.wrongPassword => l10n.networkJoinWrongPassword(ssid),
  WifiJoinError.notFound => l10n.networkJoinNotFound(ssid),
  WifiJoinError.noAddress => l10n.networkJoinNoAddress(ssid),
  WifiJoinError.noConnection => l10n.networkJoinNoConnection(ssid),
};
