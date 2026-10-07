/// A WiFi helper call that failed.
///
/// Carries the helper's own explanation and nothing else: never the
/// arguments it was called with, and never a key, so the text is safe to show
/// and to log.
class WifiHelperException implements Exception {
  /// Creates a [WifiHelperException].
  const WifiHelperException(this.message, {this.restored});

  /// What the helper said went wrong.
  final String message;

  /// The network a failed join brought back, when the helper reactivated the
  /// one that was up before it started (#1270 D13). Empty when it came back
  /// but its name could not be read; null when nothing was restored.
  final String? restored;

  @override
  String toString() => message;
}
