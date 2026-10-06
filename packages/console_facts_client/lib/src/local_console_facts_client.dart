import 'dart:io';

import 'package:console_facts_client/src/console_facts_client.dart';
import 'package:console_facts_client/src/console_facts_models.dart';
import 'package:console_facts_client/src/directory_size.dart';
import 'package:meta/meta.dart';

/// A filesystem's total and free capacity, in bytes.
///
/// The two numbers [LocalConsoleFactsClient] cannot derive from a directory
/// walk: how big the volume is, and how much of it is still empty. Read by the
/// composition root through the engine's `statvfs` (no subprocess: a `df`
/// fork from the app stalls the real-time audio thread, #806), faked directly
/// in tests. This package keeps its own two-field type so it depends on no
/// engine; the root adapts the engine's reading into it.
@immutable
class DiskSpace {
  /// Creates a [DiskSpace].
  const DiskSpace({required this.totalBytes, required this.freeBytes});

  /// The volume's total size.
  final int totalBytes;

  /// What is still free on it — the filesystem's *available* figure, not
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
/// it: a `statvfs` on the directory the session and capture repositories
/// actually write to. On the appliance that path is under `/data` (the 897 GB
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
  /// lives. [diskSpace] reads a volume's total/free capacity for an EXISTING
  /// path; the root passes the engine's `statvfs`, tests a function of their
  /// own. There is deliberately no default: the one this had was a `df`
  /// subprocess, and a fork from the app is what #806 ruled out.
  LocalConsoleFactsClient({
    required Future<String> Function() sessionsRoot,
    required Future<String> Function() capturesRoot,
    required Future<DiskSpace?> Function(String path) diskSpace,
    String bluetoothState = kRetiredBluetoothState,
  }) : _sessionsRoot = sessionsRoot,
       _capturesRoot = capturesRoot,
       _diskSpace = diskSpace,
       _bluetoothState = bluetoothState;

  final Future<String> Function() _sessionsRoot;
  final Future<String> Function() _capturesRoot;
  final Future<DiskSpace?> Function(String path) _diskSpace;
  final String _bluetoothState;

  @override
  bool get isSupported => true;

  @override
  Future<StorageUsage> storage() async {
    final sessionsDir = await _sessionsRoot();
    final capturesDir = await _capturesRoot();
    // The reading targets the captures directory, so the volume it reports is
    // the one a capture would actually fill — or, before the first capture is
    // written, the nearest ancestor that exists, which is on the same volume.
    // A whole reading with no volume behind it is no reading at all — say
    // "unknown" rather than draw a breakdown of a disk whose size we do not
    // know.
    final target = _firstExistingAncestor(capturesDir);
    final space = target == null ? null : await _diskSpace(target);
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

  /// Counts the device records BlueZ kept under [kRetiredBluetoothState]:
  /// `<adapter address>/<device address>/info`. Anything else in the tree
  /// (the adapter's `settings`, its `cache` directory) is not a pairing.
  /// An unreadable tree counts as none: there is nothing it could be shown
  /// to have held.
  @override
  Future<int> retiredBluetoothPairings() async {
    final root = Directory(_bluetoothState);
    if (!root.existsSync()) return 0;
    try {
      var count = 0;
      for (final adapter in root.listSync().whereType<Directory>()) {
        if (!_bluetoothAddress.hasMatch(_name(adapter))) continue;
        for (final device in adapter.listSync().whereType<Directory>()) {
          if (_bluetoothAddress.hasMatch(_name(device)) &&
              File('${device.path}/info').existsSync()) {
            count++;
          }
        }
      }
      return count;
    } on FileSystemException {
      return 0;
    }
  }
}

/// Where the appliance kept BlueZ's pairings so they survived an update; the
/// retired Bluetooth service bound it over `/var/lib/bluetooth`.
const kRetiredBluetoothState = '/data/bluetooth';

/// A Bluetooth device address as BlueZ names its directories.
final _bluetoothAddress = RegExp(r'^[0-9A-F]{2}(:[0-9A-F]{2}){5}$');

String _name(Directory dir) => dir.uri.pathSegments.lastWhere(
  (segment) => segment.isNotEmpty,
  orElse: () => '',
);

/// The nearest existing directory at or above [path], or `null` if even the
/// filesystem root is unreadable. Lets the capacity reader measure the right
/// volume before the app has written anything into its own subdirectories (a
/// `statvfs` on a path that does not exist yet fails rather than answering).
String? _firstExistingAncestor(String path) {
  var dir = Directory(path);
  while (!dir.existsSync()) {
    final parent = dir.parent;
    if (parent.path == dir.path) return null; // reached the root, still nothing
    dir = parent;
  }
  return dir.path;
}
