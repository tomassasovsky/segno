import 'dart:io';

/// Total bytes of every file at or under [path], walked recursively.
///
/// The one implementation of the recursive size the app needs in two places:
/// the Storage face's per-directory accounting (`LocalConsoleFactsClient`) and
/// the recorder's in-flight stop-floor, which sizes the capture it must be able
/// to finalize (#656). Both previously carried their own copy of this walk.
///
/// Returns 0 for a missing or unreadable directory rather than throwing. Every
/// caller treats "cannot read" as "contributes nothing measurable" — the
/// Storage face draws a directory that is not there as 0, and the recorder's
/// floor falls back to its own headroom — and a throw would take the whole
/// reading down. A single file that vanishes mid-walk is skipped for the same
/// reason.
int directorySizeBytes(String path) {
  final dir = Directory(path);
  if (!dir.existsSync()) return 0;
  try {
    var total = 0;
    for (final entry in dir.listSync(recursive: true, followLinks: false)) {
      if (entry is File) {
        try {
          total += entry.lengthSync();
        } on FileSystemException {
          // A file that disappeared between the listing and the stat: it is
          // no longer on the disk, so it contributes nothing to what is.
        }
      }
    }
    return total;
  } on FileSystemException {
    return 0;
  }
}
