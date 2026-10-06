import 'package:session_repository/session_repository.dart';

/// Typed failures a session load can raise, so callers can present a
/// human-readable, localized message instead of a raw `toString()`.
///
/// These are the recoverable, user-facing refusals (the engine is fine; the
/// chosen bundle simply can't be loaded as-is). Lower-level I/O failures and
/// engine errors surface as their native exception types.
sealed class SessionException implements Exception {
  const SessionException();
}

/// The session was recorded at a sample rate that differs from the running
/// device's. Loading its raw stems would play them back at the wrong pitch
/// (there is no resampling), so [SessionRepository.read] refuses.
class SessionSampleRateMismatch extends SessionException {
  /// Creates a [SessionSampleRateMismatch].
  const SessionSampleRateMismatch({
    required this.sessionRate,
    required this.deviceRate,
  });

  /// The sample rate the session was recorded at, in Hz.
  final int sessionRate;

  /// The running device's sample rate, in Hz.
  final int deviceRate;

  @override
  String toString() =>
      'session sample rate $sessionRate Hz does not match the device rate '
      '$deviceRate Hz';
}

/// The session manifest declares schema [version], newer than the schema
/// [supported] this build reads and converts to. [Session.fromJson] alone
/// also refuses an older schema this way; opening a bundle converts those.
class SessionUnsupportedVersion extends SessionException {
  /// Creates a [SessionUnsupportedVersion].
  const SessionUnsupportedVersion({
    required this.version,
    required this.supported,
  });

  /// The manifest's declared schema version.
  final int version;

  /// The only schema version this build can read.
  final int supported;

  @override
  String toString() =>
      'unsupported session version $version (requires $supported)';
}

/// The manifest was written by an older schema this build cannot convert:
/// one older than [oldestConvertibleSessionVersion], or one whose conversion
/// failed. The bundle is left exactly as it was.
class SessionUnconvertible extends SessionException {
  /// Creates a [SessionUnconvertible].
  const SessionUnconvertible({required this.version, required this.reason});

  /// The manifest's declared schema version.
  final int version;

  /// What stopped the conversion.
  final String reason;

  @override
  String toString() => 'session schema $version cannot be converted: $reason';
}

/// A track lane's overdub-layer stack is structurally invalid — its declared
/// `undoCount + 1 + redoCount` does not match its layer list, or the count
/// exceeds the engine's per-lane pool cap. A corrupt or foreign bundle fails
/// loudly on load rather than mid-apply.
class SessionCorruptLayers extends SessionException {
  /// Creates a [SessionCorruptLayers].
  const SessionCorruptLayers({
    required this.channel,
    required this.lane,
    required this.reason,
  });

  /// Track channel of the offending lane.
  final int channel;

  /// Lane index of the offending lane.
  final int lane;

  /// A short description of what was wrong.
  final String reason;

  @override
  String toString() =>
      'session track $channel lane $lane has a corrupt layer stack: $reason';
}

/// A save-as / rename targeted a name whose folder [slug] already exists in the
/// sessions catalog. Named sessions never silently overwrite, so the caller
/// must pick another name.
class SessionNameCollision extends SessionException {
  /// Creates a [SessionNameCollision] for the colliding [slug].
  const SessionNameCollision({required this.slug});

  /// The folder slug (the sanitized name) that already exists.
  final String slug;

  @override
  String toString() => 'a session named "$slug" already exists';
}
