import 'dart:io';

import 'package:console_facts_client/src/console_facts_client.dart';
import 'package:console_facts_client/src/console_facts_models.dart';
import 'package:console_facts_client/src/directory_size.dart';
import 'package:meta/meta.dart';

/// A filesystem's total and free capacity, in bytes.
///
/// The two numbers [LocalConsoleFactsClient] cannot derive from a directory
/// walk: how big the volume is, and how much of it is still empty. Read from
/// `df` on the real appliance, faked directly in tests.
@immutable
class DiskSpace {
  /// Creates a [DiskSpace].
  const DiskSpace({required this.totalBytes, required this.freeBytes});

  /// The volume's total size.
  final int totalBytes;

  /// What is still free on it — `df`'s *available* column, not
  /// total-minus-used: those disagree by the filesystem's reserved blocks, and
  /// the number a person can actually fill is the available one.
  final int freeBytes;
}

/// The real storage accounting for a build that runs on the box (Linux) or a
/// developer's desktop (macOS) — the honest replacement for the
/// `UnsupportedConsoleFactsClient` the Storage face fell back to (#656).
///
/// It answers exactly the one question #656 is about — what the disk holds —
/// against the **user-data volume**, resolved the way the app itself resolves
/// it: `df` on the directory the session and capture repositories actually
/// write to. On the appliance that path is under `/data` (the 897 GB
/// persistent partition), never the small A/B rootfs; on macOS it is the app
/// support/documents volume. Measuring the repositories' own paths is what
/// makes that split correct without this client ever naming a partition.
///
/// The other three questions stay honestly unanswered here: [facts] is what the
/// box *is* (not derivable from the filesystem), and export + capture retention
/// are unimplemented on the appliance side — so those keep the same "unknown"
/// answers the unsupported client gave, per-field, rather than this class
/// pretending to a completeness it does not have. Only the disk figures are
/// real. [isSupported] is nonetheless `true`: the build *can* read the disk,
/// which is the one thing that flag gates.
class LocalConsoleFactsClient implements ConsoleFactsClient {
  /// Creates a [LocalConsoleFactsClient].
  ///
  /// [sessionsRoot] and [capturesRoot] resolve the same directories the session
  /// and performance repositories write to (the composition root passes the
  /// very functions it wires into those repositories), so the accounting is of
  /// the app's own data by construction rather than a second guess at where it
  /// lives. [diskSpace] reads a volume's total/free capacity, defaulting to a
  /// `df` call; injected in tests so the total/free half of the reading is
  /// deterministic without depending on the test machine's real disk.
  LocalConsoleFactsClient({
    required Future<String> Function() sessionsRoot,
    required Future<String> Function() capturesRoot,
    Future<DiskSpace?> Function(String path)? diskSpace,
  }) : _sessionsRoot = sessionsRoot,
       _capturesRoot = capturesRoot,
       _diskSpace = diskSpace ?? _dfDiskSpace;

  final Future<String> Function() _sessionsRoot;
  final Future<String> Function() _capturesRoot;
  final Future<DiskSpace?> Function(String path) _diskSpace;

  @override
  bool get isSupported => true;

  @override
  Future<StorageUsage> storage() async {
    final sessionsDir = await _sessionsRoot();
    final capturesDir = await _capturesRoot();
    // df targets the captures directory, so the volume it reports is the one a
    // capture would actually fill. A whole reading with no volume behind it is
    // no reading at all — say "unknown" rather than draw a breakdown of a disk
    // whose size we do not know.
    final space = await _diskSpace(capturesDir);
    if (space == null) return const StorageUsage.unknown();

    final sessionBytes = directorySizeBytes(sessionsDir);
    final captureBytes = directorySizeBytes(capturesDir);

    // "system" is everything used on the volume that is not the app's own
    // sessions or captures — the OS, other users' data, everything else on
    // /data. Derived, not walked: sizing the whole volume would cost a walk of
    // hundreds of gigabytes to learn a number df already implies. Clamped at 0
    // so a session/capture directory wired onto a *different* volume than df
    // measured (never the shipped layout) can never render as a negative
    // system figure.
    final used = space.totalBytes - space.freeBytes;
    final otherBytes = used - sessionBytes - captureBytes;
    return StorageUsage(
      sessionBytes: sessionBytes,
      captureBytes: captureBytes,
      // No plugin store on the data volume that this build tracks yet; folded
      // into the derived "system" remainder above rather than guessed at.
      pluginBytes: 0,
      systemBytes: otherBytes < 0 ? 0 : otherBytes,
      freeBytes: space.freeBytes,
    );
  }

  /// What the box *is* — not something a filesystem read can answer, so still
  /// unknown here. Kept honest per-field rather than fabricated (#656 is disk
  /// accounting only).
  @override
  Future<ConsoleFacts> facts() async => ConsoleFacts.unknown;

  /// Capture retention is unimplemented on the appliance side; nothing is
  /// removed and nothing is claimed to be.
  @override
  Future<int> deleteCapturesOlderThan(int days) async => 0;

  /// USB export is unimplemented; there is no destination to offer.
  @override
  Future<String> exportDestination() async => '';

  @override
  Future<void> exportEverything(String destination) async {}
}

/// Reads [path]'s volume total/free via `df -k -P`, or `null` when the platform
/// or the path cannot answer.
///
/// `-k` fixes the block size at 1024 bytes and `-P` forces the single-line
/// portable layout, so the parse does not have to cope with a wrapped long
/// device name or a platform's default block size. macOS and Linux both honour
/// both flags. When [path] does not exist yet (a fresh install before the first
/// session is written) it walks up to the first ancestor that does, so `df`
/// still lands on the right volume rather than failing. The stdout parse lives
/// in [parseDfKP], where every defensive branch is unit-tested away from the
/// subprocess.
Future<DiskSpace?> _dfDiskSpace(String path) async {
  final target = _firstExistingAncestor(path);
  if (target == null) return null;
  final ProcessResult result;
  try {
    result = await Process.run('df', ['-k', '-P', target]);
  } on ProcessException {
    return null; // no df on this platform (Windows): unknown, honestly
  }
  if (result.exitCode != 0) return null;
  return parseDfKP(result.stdout as String);
}

/// Parses the stdout of `df -k -P` into a [DiskSpace], or `null` when the
/// output is not the shape that command guarantees.
///
/// Split out from the subprocess so the defensive branches — output with no
/// data line, a line with too few columns, non-numeric sizes — are pinned by
/// tests a live `df` would never produce on demand, and so a future `df`-format
/// surprise fails loudly here rather than silently mis-reads a disk.
///
/// `-P` guarantees one filesystem per line with the header first, so the data
/// line is the last, and its columns are `Filesystem, 1024-blocks, Used,
/// Available, Capacity, Mounted-on`. Total and available are read straight off,
/// scaled from 1024-byte blocks to bytes.
DiskSpace? parseDfKP(String stdout) {
  final lines = stdout.trim().split('\n');
  if (lines.length < 2) return null; // header only, or empty: no data line
  final fields = lines.last.trim().split(RegExp(r'\s+'));
  if (fields.length < 4) return null; // a wrapped or truncated line
  final totalKb = int.tryParse(fields[1]);
  final availKb = int.tryParse(fields[3]);
  if (totalKb == null || availKb == null) return null; // non-numeric sizes
  return DiskSpace(totalBytes: totalKb * 1024, freeBytes: availKb * 1024);
}

/// The nearest existing directory at or above [path], or `null` if even the
/// filesystem root is unreadable. Lets `df` measure the right volume before the
/// app has written anything into its own subdirectories.
String? _firstExistingAncestor(String path) {
  var dir = Directory(path);
  while (!dir.existsSync()) {
    final parent = dir.parent;
    if (parent.path == dir.path) return null; // reached the root, still nothing
    dir = parent;
  }
  return dir.path;
}
