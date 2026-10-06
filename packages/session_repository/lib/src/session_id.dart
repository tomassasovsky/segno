/// Folds [timestamp] into a new session bundle id: `s-YYYYMMDD-HHMMSS`.
///
/// Second-resolution and purely time-derived, like the performance bundle
/// slug, so two saves in the same wall-clock second collide;
/// `SessionRepository.newSessionId` appends a `-N` disambiguator in that case
/// rather than reusing a directory.
String sessionIdFor(DateTime timestamp) {
  String pad(int n, int width) => n.toString().padLeft(width, '0');
  return 's-${pad(timestamp.year, 4)}${pad(timestamp.month, 2)}'
      '${pad(timestamp.day, 2)}-${pad(timestamp.hour, 2)}'
      '${pad(timestamp.minute, 2)}${pad(timestamp.second, 2)}';
}

/// Whether [id] can be a bundle directory name: non-empty, no path separators
/// and not a relative-path component. Ids are read from directory listings and
/// minted by [sessionIdFor]; anything else is refused before it reaches disk.
bool isValidSessionId(String id) =>
    id.isNotEmpty &&
    id != '.' &&
    id != '..' &&
    !id.contains('/') &&
    !id.contains(r'\');
