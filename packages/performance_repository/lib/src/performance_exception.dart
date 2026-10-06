/// Typed failures a performance-recording operation can raise, so callers can
/// present a human-readable, localized message instead of a raw `toString()`
/// (mirrors `session_repository`'s own `SessionException` family — this
/// package can't import that one, so the shape is deliberately duplicated,
/// not shared).
sealed class PerformanceException implements Exception {
  const PerformanceException();
}

/// A capture rename targeted a name whose folder [slug] already exists.
/// Captures never silently overwrite, so the caller must pick another name.
class PerformanceNameCollision extends PerformanceException {
  /// Creates a [PerformanceNameCollision] for the colliding [slug].
  const PerformanceNameCollision({required this.slug});

  /// The folder slug (the sanitized name) that already exists.
  final String slug;

  @override
  String toString() => 'a capture named "$slug" already exists';
}

/// A recording could not be deleted because a take is being recorded,
/// finalized or rendered: any of them may be writing into a bundle.
class PerformanceCaptureBusy extends PerformanceException {
  /// Creates a [PerformanceCaptureBusy].
  const PerformanceCaptureBusy();

  @override
  String toString() => 'a take is being recorded or rendered';
}
