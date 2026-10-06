import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:segno/library/application/removable_volumes.dart';

/// Where the Library's audio exports land on a drive (plan section 4.3).
abstract final class AudioExportFolders {
  /// Recordings: `Segno/Performances/<name>.wav`, its parts, or a DAW
  /// package directory.
  static const String performances = 'Segno/Performances';

  /// Session mixdowns, stems and backups: `Segno/Sessions/<name>.wav`,
  /// `Segno/Sessions/<name> stems/` and `Segno/Sessions/<id>/`.
  static const String sessions = 'Segno/Sessions';
}

/// One file of an export: the internal [source] and its path inside the
/// export, where `{name}` stands for the export's name (which `Keep both`
/// suffixes).
class AudioExportFile {
  /// Creates an [AudioExportFile].
  const AudioExportFile(this.source, this.target);

  /// The file on internal storage.
  final String source;

  /// Its path under the export's folder (loose files) or directory (a
  /// package), with `{name}` for the export's name.
  final String target;
}

/// What one export writes: [files] under [folder] on the drive, either side
/// by side ([package] false) or inside one directory named [name] ([package]
/// true).
class AudioExportPlan {
  /// Creates an [AudioExportPlan].
  const AudioExportPlan({
    required this.name,
    required this.folder,
    required this.files,
    this.package = false,
    this.earlier,
  });

  /// The export's name; `Keep both` makes it `<name> (2)`, `<name> (3)`...
  final String name;

  /// The folder on the drive, under its root.
  final String folder;

  /// The files, in copy order.
  final List<AudioExportFile> files;

  /// Whether the files go into one directory named [name].
  final bool package;

  /// Entries in [folder] that an earlier export under [name] left and that
  /// `Replace` takes away with the ones it overwrites: a recording exported
  /// before as three parts leaves no `Part 003` beside a new two-part
  /// export. Null when nothing but the targets themselves is replaced.
  final RegExp? earlier;
}

/// An export the player cancelled; whatever it had placed is removed.
class AudioExportCancelled implements Exception {
  /// Creates an [AudioExportCancelled].
  const AudioExportCancelled();

  @override
  String toString() => 'the export was cancelled';
}

/// Runs the Library's exports and backups to a removable drive through the
/// [RemovableVolumes] port (#1178 Part 7): every byte goes through the port's
/// `copyFile` (`.part`, fsync, rename), under a write lease that names the
/// export, after a space check against the export's total.
///
/// An export is all or nothing on the drive, whatever stops it:
/// - Every file is first copied into a hidden staging directory named after
///   the export (`<folder>/.segno-export-<name>/`).
/// - Then a short swap puts it in place: what the export replaces (the
///   targets already there under `Replace`, and the [AudioExportPlan.earlier]
///   files of an earlier export) moves into an aside directory
///   (`.segno-export-<name>.old/`) beside a list of the targets, every staged
///   entry is renamed into place, the list is removed (the commit point), and
///   only then is the aside deleted.
/// - A failure before the commit point puts everything back at once. A cut
///   (power, unplug) leaves the aside with its list, and the next export into
///   that folder puts it back first ([recoverFolder]): the drive returns to
///   what it held before the interrupted export, never a mixture.
///
/// With [ConflictPolicy.ask] a name already taken is reported
/// ([NameConflict]) before anything is written. `Keep both` picks the first
/// free `<name> (n)` for every file at once, so a multi-part recording keeps
/// one name across its parts. Internal storage is only ever read.
class AudioExporter {
  /// Creates an [AudioExporter] over the port it copies through.
  const AudioExporter(this._volumes);

  final RemovableVolumes _volumes;

  /// The prefix of every hidden entry an export keeps in a folder: its
  /// staging directory `<prefix><name>` and its aside `<prefix><name>.old`.
  static const String stagingPrefix = '.segno-export-';

  /// The list of an aside's targets, whose presence marks a swap that has
  /// not reached its commit point.
  static const String targetsName = '.targets';

  /// Called at each step of a swap (`aside <entry>` before each move aside,
  /// `aside` once they are all aside, `placed <entry>` per entry, then
  /// `committed`), so a test can fail one or see the disk at that moment.
  @visibleForTesting
  static void Function(String step)? debugOnSwap;

  /// Exports [plan] to the drive [generation] under [policy], naming it
  /// [purpose] for the Storage page. [onProgress] gets the share of bytes
  /// copied after every file; [cancelled] is asked before every file and
  /// before the swap. Returns the export's path on the drive, relative to
  /// its root: the package directory, or the first file.
  ///
  /// Throws [NameConflict] (only under [ConflictPolicy.ask]), a
  /// [StorageFailure], or [AudioExportCancelled].
  Future<String> run(
    AudioExportPlan plan, {
    required int generation,
    required ConflictPolicy policy,
    required String purpose,
    void Function(double fraction)? onProgress,
    bool Function()? cancelled,
  }) {
    final destination = StorageDestination.removable(generation);
    return _volumes.withWriteLease(destination, purpose, (mount) async {
      final folder = Directory('$mount/${plan.folder}');
      _guardIo(() => recoverFolder(folder));
      final sizes = [for (final f in plan.files) _sizeOf(f.source)];
      final total = sizes.fold<int>(0, (a, b) => a + b);
      final space = await _volumes.space(destination);
      if (space != null && space.freeBytes < total) {
        throw const StorageFailure.full();
      }
      final name = _nameFor(plan, mount, policy);
      final entries = plan.package
          ? [name]
          : [for (final f in plan.files) f.target.replaceAll('{name}', name)];
      final staging = '${plan.folder}/$stagingPrefix$name';
      final stagingDir = Directory('$mount/$staging');
      var done = 0;
      try {
        if (stagingDir.existsSync()) stagingDir.deleteSync(recursive: true);
        for (var i = 0; i < plan.files.length; i++) {
          if (cancelled?.call() ?? false) throw const AudioExportCancelled();
          final target = plan.files[i].target.replaceAll('{name}', name);
          await _volumes.copyFile(
            plan.files[i].source,
            destination,
            plan.package ? '$staging/$name/$target' : '$staging/$target',
            onConflict: ConflictPolicy.replace,
          );
          done += sizes[i];
          onProgress?.call(total == 0 ? 1 : done / total);
        }
        if (cancelled?.call() ?? false) throw const AudioExportCancelled();
        _swap(
          folder: folder,
          name: name,
          entries: entries,
          earlier: policy == ConflictPolicy.replace ? plan.earlier : null,
        );
      } on FileSystemException catch (e) {
        _bestEffort(() => stagingDir.deleteSync(recursive: true));
        throw StorageFailure.io(e.osError?.message ?? e.message);
      } on Object {
        _bestEffort(() => stagingDir.deleteSync(recursive: true));
        rethrow;
      }
      return '${plan.folder}/${entries.first}';
    });
  }

  /// The paths [plan] takes on the drive under [name], relative to its root.
  static List<String> targetsOf(AudioExportPlan plan, String name) =>
      plan.package
      ? ['${plan.folder}/$name']
      : [
          for (final f in plan.files)
            '${plan.folder}/${f.target.replaceAll('{name}', name)}',
        ];

  /// The name the export takes: its own under `ask` (refused with
  /// [NameConflict] when taken) and `replace`, and the first free
  /// `<name> (n)` across every target under `keepBoth`.
  static String _nameFor(
    AudioExportPlan plan,
    String mount,
    ConflictPolicy policy,
  ) {
    String? takenAt(String name) {
      for (final target in targetsOf(plan, name)) {
        if (FileSystemEntity.typeSync('$mount/$target') !=
            FileSystemEntityType.notFound) {
          return '$mount/$target';
        }
      }
      return null;
    }

    switch (policy) {
      case ConflictPolicy.replace:
        return plan.name;
      case ConflictPolicy.ask:
        if (takenAt(plan.name) case final existing?) {
          throw NameConflict(existing);
        }
        return plan.name;
      case ConflictPolicy.keepBoth:
        if (takenAt(plan.name) == null) return plan.name;
        for (var n = 2; ; n++) {
          final candidate = '${plan.name} ($n)';
          if (takenAt(candidate) == null) return candidate;
        }
    }
  }

  /// Puts the staged [entries] of the export [name] in place in [folder].
  /// What they replace, and the entries [earlier] matches, move aside first
  /// and are deleted only after the commit point. Any failure before it
  /// puts everything back and rethrows.
  static void _swap({
    required Directory folder,
    required String name,
    required List<String> entries,
    RegExp? earlier,
  }) {
    final staging = Directory('${folder.path}/$stagingPrefix$name');
    final aside = Directory('${folder.path}/$stagingPrefix$name.old');
    final moving = {
      ...entries,
      if (earlier != null)
        for (final e in folder.listSync())
          if (earlier.hasMatch(_lastSegment(e.path))) _lastSegment(e.path),
    };
    try {
      if (aside.existsSync()) aside.deleteSync(recursive: true);
      aside.createSync(recursive: true);
      File('${aside.path}/$targetsName').writeAsStringSync(
        entries.join('\n'),
        flush: true,
      );
      for (final entry in moving) {
        final path = '${folder.path}/$entry';
        if (FileSystemEntity.typeSync(path) != FileSystemEntityType.notFound) {
          debugOnSwap?.call('aside $entry');
          _renameEntity(path, '${aside.path}/$entry');
        }
      }
      debugOnSwap?.call('aside');
      for (final entry in entries) {
        _renameEntity('${staging.path}/$entry', '${folder.path}/$entry');
        debugOnSwap?.call('placed $entry');
      }
    } on Object {
      _rollBack(folder: folder, staging: staging, aside: aside);
      rethrow;
    }
    // The commit point: from here the new export stands, whatever happens.
    File('${aside.path}/$targetsName').deleteSync();
    debugOnSwap?.call('committed');
    _bestEffort(() => aside.deleteSync(recursive: true));
    _bestEffort(() => staging.deleteSync(recursive: true));
  }

  /// Returns [folder] to what it held before an export that never reached
  /// its commit point: its placed targets removed, everything set aside
  /// put back, its staging gone.
  static void _rollBack({
    required Directory folder,
    required Directory staging,
    required Directory aside,
  }) {
    final list = File('${aside.path}/$targetsName');
    final targets = list.existsSync()
        ? list.readAsLinesSync().where((l) => l.isNotEmpty).toList()
        : const <String>[];
    for (final target in targets) {
      final placed = '${folder.path}/$target';
      final staged = '${staging.path}/$target';
      // Still staged: never placed, so what sits in the folder (if any) is
      // the original, not yet moved aside.
      if (FileSystemEntity.typeSync(staged) != FileSystemEntityType.notFound) {
        continue;
      }
      _deleteEntity(placed);
    }
    if (aside.existsSync()) {
      for (final e in aside.listSync()) {
        final entry = _lastSegment(e.path);
        if (entry == targetsName) continue;
        final back = '${folder.path}/$entry';
        if (FileSystemEntity.typeSync(back) == FileSystemEntityType.notFound) {
          _renameEntity(e.path, back);
        }
      }
      aside.deleteSync(recursive: true);
    }
    if (staging.existsSync()) staging.deleteSync(recursive: true);
  }

  /// Finishes what an earlier export into [folder] left: a swap cut before
  /// its commit point is put back ([_rollBack]), a swap cut after it only
  /// loses its aside, and a staging directory with no swap is removed.
  /// Runs before every export; an export of this build's predecessor named
  /// its staging `.segno-export`, which goes too.
  static void recoverFolder(Directory folder) {
    if (!folder.existsSync()) return;
    final entries = folder.listSync();
    for (final e in entries) {
      final entry = _lastSegment(e.path);
      if (e is! Directory || !entry.startsWith(stagingPrefix)) continue;
      if (!entry.endsWith('.old')) continue;
      final staging = Directory(
        '${folder.path}/${entry.substring(0, entry.length - 4)}',
      );
      if (File('${e.path}/$targetsName').existsSync()) {
        _rollBack(folder: folder, staging: staging, aside: e);
      } else {
        e.deleteSync(recursive: true);
      }
    }
    for (final e in folder.listSync()) {
      final entry = _lastSegment(e.path);
      if (e is Directory &&
          (entry.startsWith(stagingPrefix) || entry == '.segno-export')) {
        e.deleteSync(recursive: true);
      }
    }
  }

  static void _renameEntity(String from, String to) {
    final type = FileSystemEntity.typeSync(from);
    if (type == FileSystemEntityType.notFound) {
      throw FileSystemException('nothing to move', from);
    }
    if (type == FileSystemEntityType.directory) {
      Directory(from).renameSync(to);
    } else {
      File(from).renameSync(to);
    }
  }

  static void _deleteEntity(String path) {
    final type = FileSystemEntity.typeSync(path);
    if (type == FileSystemEntityType.notFound) return;
    if (type == FileSystemEntityType.directory) {
      Directory(path).deleteSync(recursive: true);
    } else {
      File(path).deleteSync();
    }
  }

  static String _lastSegment(String path) =>
      path.split('/').where((s) => s.isNotEmpty).last;

  static int _sizeOf(String path) {
    try {
      return File(path).lengthSync();
    } on FileSystemException {
      return 0;
    }
  }

  /// Runs [body], mapping a refused filesystem call to a typed failure.
  static void _guardIo(void Function() body) {
    try {
      body();
    } on FileSystemException catch (e) {
      throw StorageFailure.io(e.osError?.message ?? e.message);
    }
  }

  /// Cleanup on a drive that may already be gone.
  static void _bestEffort(void Function() body) {
    try {
      body();
    } on FileSystemException {
      // The drive went away or refused; nothing more to do from here.
    }
  }
}

/// [name] made safe as a file or directory name on the FAT32 and exFAT drives
/// the appliance writes: the characters those refuse become `-`, and the
/// trailing dots and spaces they drop are trimmed.
String driveSafeName(String name) {
  final safe = name
      .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '-')
      .replaceAll(RegExp(r'[. ]+$'), '')
      .trim();
  return safe.isEmpty ? '-' : safe;
}
