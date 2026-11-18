/// Why a join failed, as `segno-wifi-ctl connect` reports it on stdout
/// (`{"error":<code>}`).
///
/// The helper decides from what iwd logged during the attempt, never from
/// NetworkManager's reason: on a console with no secret agent NM ends every
/// failed activation that asked for secrets as `no-secrets`, whatever went
/// wrong (#1817).
enum WifiJoinError {
  /// iwd's 4-way handshake failed: the access point tested the key and
  /// refused it. The only failure that is about the password.
  wrongPassword,

  /// The network is not in range.
  notFound,

  /// The link came up but no IPv4 address did.
  noAddress,

  /// Anything else: an authentication or association the access point
  /// rejected or let time out, the join running out of time, a backend race.
  /// The key was never tested.
  noConnection;

  /// The failure the helper named with [code]; [noConnection] when it named
  /// none (it could not reach NetworkManager, or the join never started).
  static WifiJoinError fromCode(String? code) => switch (code) {
    'wrong-password' => wrongPassword,
    'not-found' => notFound,
    'no-address' => noAddress,
    _ => noConnection,
  };
}

/// A WiFi helper call that failed.
///
/// Carries the helper's own explanation and nothing else: never the
/// arguments it was called with, and never a key, so the text is safe to show
/// and to log.
class WifiHelperException implements Exception {
  /// Creates a [WifiHelperException].
  const new(this.message, {this.restored, this.join});

  /// What the helper said went wrong.
  final String message;

  /// The network a failed join brought back, when the helper reactivated the
  /// one that was up before it started (#1270 D13). Empty when it came back
  /// but its name could not be read; null when nothing was restored.
  final String? restored;

  /// Why a join failed, for a failed `connect`; null for any other call.
  final WifiJoinError? join;

  @override
  String toString() => message;
}
