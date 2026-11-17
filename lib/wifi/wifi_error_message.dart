import 'package:segno/l10n/l10n.dart';
import 'package:wifi_repository/wifi_repository.dart';

/// What the page says about a join of [ssid] that failed for [reason].
///
/// The helper decides [reason] from what iwd logged (#1817), so only a key
/// the access point refused reads as a wrong password; everything else names
/// the network and is offered again.
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

/// What the page says when a Wi-Fi action that is not a join failed (a scan,
/// Disconnect, Forget, the radio switch, the first status read). The
/// helper's own text is for the log, not the screen.
String wifiErrorMessage(AppLocalizations l10n, String? raw) =>
    raw == null || raw.isEmpty ? '' : l10n.networkActionFailed;
