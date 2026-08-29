import 'package:segno/l10n/l10n.dart';
import 'package:segno/wifi/wifi_join_failure.dart';

/// Maps a WiFi failure to a short operator-facing string.
///
/// When the cubit classified the failure, [kind] decides the copy — the raw
/// text is never re-guessed. The text fallback below only serves errors that
/// never went through [classifyWifiJoinFailure] (scan/status/load failures),
/// and it deliberately does **not** map NM's `no-secrets` family to the
/// password hint: without knowing whether the user just typed a password,
/// `no-secrets` is not evidence about the password at all (#824, #829).
String wifiErrorMessage(
  AppLocalizations l10n,
  String? raw, {
  WifiJoinErrorKind? kind,
}) {
  if (raw == null || raw.isEmpty) return '';
  if (kind != null) {
    return switch (kind) {
      WifiJoinErrorKind.credentials => l10n.wifiConnectFailedPassword,
      WifiJoinErrorKind.transient => l10n.wifiConnectFailedBackend,
      WifiJoinErrorKind.timeout => l10n.wifiConnectFailedTimeout,
      WifiJoinErrorKind.unknown => l10n.wifiConnectFailedGeneric,
    };
  }
  final lower = raw.toLowerCase();
  if (lower.contains('authentication failed') ||
      lower.contains('wrong password') ||
      lower.contains('invalid passphrase')) {
    return l10n.wifiConnectFailedPassword;
  }
  if (lower.contains('secrets were required') ||
      lower.contains('no secrets') ||
      lower.contains('no-secrets')) {
    return l10n.wifiConnectFailedBackend;
  }
  if (lower.contains('timed out waiting') || lower.contains('took too long')) {
    return l10n.wifiConnectFailedTimeout;
  }
  if (lower.contains('segno-wifi-ctl') ||
      lower.contains('processexception') ||
      lower.contains('connection failed')) {
    return l10n.wifiConnectFailedGeneric;
  }
  return raw;
}
