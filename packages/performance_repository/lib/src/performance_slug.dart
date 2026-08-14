/// Folds [timestamp] into a performance bundle slug: `perf-YYYYMMDD-HHMMSS`
/// (D-NAME). Second-resolution and purely time-derived, so two arms in the
/// same wall-clock second collide — `PerformanceRepository` appends a `-N`
/// disambiguator in that (practically unreachable, since arming twice in one
/// second implies an instant disarm+rearm) case rather than silently
/// overwriting the earlier bundle.
String performanceSlug(DateTime timestamp) {
  String pad(int n, int width) => n.toString().padLeft(width, '0');
  return 'perf-${pad(timestamp.year, 4)}${pad(timestamp.month, 2)}'
      '${pad(timestamp.day, 2)}-${pad(timestamp.hour, 2)}'
      '${pad(timestamp.minute, 2)}${pad(timestamp.second, 2)}';
}

/// The one reserved capture name: the folder within the exports root that
/// boot salvage moves recovered bundles into
/// (`PerformanceRepository.recoveredDirName` is this same constant).
/// [performanceCaptureSlug] refuses names that fold onto it — a take renamed
/// to it would BECOME the recovered area: enumerated by the retention prune
/// and adopted as the landing zone for future salvages. Declared here rather
/// than on the repository so the validator (which the rename UIs pre-check
/// with) needs no import of the repository class.
const String reservedRecoveredDirName = 'recovered';

/// Folds [name] into a folder-safe capture slug for
/// `PerformanceRepository.renameCapture` (D-NAME) — mirrors
/// `session_repository`'s `sessionSlug` (this package can't import that one,
/// so the fold is a small, deliberately duplicated copy). Keeps letters,
/// digits, spaces, hyphens and underscores, turns every other character into
/// a space, then collapses internal whitespace runs and trims.
///
/// Returns `null` when nothing usable remains — or when the fold lands on
/// [reservedRecoveredDirName] (compared case-insensitively: the exports
/// volume may itself be case-insensitive, macOS-style, where `Recovered`
/// IS `recovered`). Callers (e.g. the rename dialog) treat `null` as an
/// invalid name — the same check `PerformanceRepository.renameCapture`
/// itself runs before touching disk, so the UI's inline error and the
/// repository's refusal can never disagree about what is nameable.
String? performanceCaptureSlug(String name) {
  final slug = name
      .replaceAll(RegExp('[^A-Za-z0-9 _-]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (slug.isEmpty) return null;
  if (slug.toLowerCase() == reservedRecoveredDirName) return null;
  return slug;
}
