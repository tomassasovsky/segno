import 'dart:io';

import 'package:segno/library/application/removable_volumes.dart';

/// Where the Library's audio exports land on a drive (plan section 4.3).
abstract final class AudioExportFolders {
  /// Recordings: `Segno/Performances/<name>.wav`, its parts, or a DAW
  /// package directory.
  static const String performances = 'Segno/Performances';

  /// Session mixdowns and stems: `Segno/Sessions/<name>.wav` and
  /// `Segno/Sessions/<name> stems/`.
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
/// true), which appears only once every file is in it.
class AudioExportPlan {
  /// Creates an [AudioExportPlan].
  const AudioExportPlan({
    required this.name,
    required this.folder,
    required this.files,
    this.package = false,
  });

  /// The export's name; `Keep both` makes it `<name> (2)`, `<name> (3)`...
  final String name;

  /// The folder on the drive, under its root.
  final String folder;

  /// The files, in copy order.
  final List<AudioExportFile> files;

  /// Whether the files go into one directory named [name].
  final bool package;
}

/// An export the player cancelled; whatever it had placed is removed.
class AudioExportCancelled implements Exception {
  /// Creates an [AudioExportCancelled].
  const AudioExportCancelled();

  @override
  String toString() => 'the export was cancelled';
}

/// Runs the Library's exports to a removable drive through the
/// [RemovableVolumes] port (#1178 Part 7): every byte goes through the port's
/// `copyFile` (`.part`, fsync, rename), under a write lease that names the
/// export, after a space check against the export's total.
///
/// An export is all or nothing on the drive. With [ConflictPolicy.ask] a name
/// already taken is reported ([NameConflict]) before anything is written.
/// `Keep both` picks the first free `<name> (n)` for every file at once, so a
/// multi-part recording keeps one name across its parts. A package is copied
/// into a hidden staging directory and renamed into place once every file is
/// there. A failure, a cancel or a lost drive part-way removes what this
/// export placed, as far as the drive still allows; internal storage is only
/// ever read.
class AudioExporter {
  /// Creates an [AudioExporter] over the port it copies through.
  const AudioExporter(this._volumes);

  final RemovableVolumes _volumes;

  /// The hidden directory a package is assembled in.
  static const String stagingName = '.segno-export';

  /// Exports [plan] to the drive [generation] under [policy], naming it
  /// [purpose] for the Storage page. [onProgress] gets the share of bytes
  /// copied after every file; [cancelled] is asked before every file.
  /// Returns the export's path on the drive, relative to its root: the
  /// package directory, or the first file.
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
      final sizes = [for (final f in plan.files) _sizeOf(f.source)];
      final total = sizes.fold<int>(0, (a, b) => a + b);
      final space = await _volumes.space(destination);
      if (space != null && space.freeBytes < total) {
        throw const StorageFailure.full();
      }
      final name = _nameFor(plan, mount, policy);
      return plan.package
          ? _runPackage(
              plan,
              name,
              mount: mount,
              destination: destination,
              policy: policy,
              sizes: sizes,
              total: total,
              onProgress: onProgress,
              cancelled: cancelled,
            )
          : _runLoose(
              plan,
              name,
              mount: mount,
              destination: destination,
              policy: policy,
              sizes: sizes,
              total: total,
              onProgress: onProgress,
              cancelled: cancelled,
            );
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

  Future<String> _runLoose(
    AudioExportPlan plan,
    String name, {
    required String mount,
    required StorageDestination destination,
    required ConflictPolicy policy,
    required List<int> sizes,
    required int total,
    required void Function(double)? onProgress,
    required bool Function()? cancelled,
  }) async {
    final targets = targetsOf(plan, name);
    final placed = <String>[];
    var done = 0;
    try {
      for (var i = 0; i < plan.files.length; i++) {
        if (cancelled?.call() ?? false) throw const AudioExportCancelled();
        placed.add(
          _onDrive(
            mount,
            await _volumes.copyFile(
              plan.files[i].source,
              destination,
              targets[i],
              onConflict: policy,
            ),
          ),
        );
        done += sizes[i];
        onProgress?.call(total == 0 ? 1 : done / total);
      }
    } on Object {
      for (final path in placed) {
        _bestEffort(() => File(path).deleteSync());
      }
      rethrow;
    }
    return targets.first;
  }

  Future<String> _runPackage(
    AudioExportPlan plan,
    String name, {
    required String mount,
    required StorageDestination destination,
    required ConflictPolicy policy,
    required List<int> sizes,
    required int total,
    required void Function(double)? onProgress,
    required bool Function()? cancelled,
  }) async {
    final staging = '${plan.folder}/$stagingName';
    final stagingDir = Directory('$mount/$staging');
    final target = '${plan.folder}/$name';
    var done = 0;
    try {
      // A staging directory a crash left behind is this exporter's own.
      if (stagingDir.existsSync()) stagingDir.deleteSync(recursive: true);
      for (var i = 0; i < plan.files.length; i++) {
        if (cancelled?.call() ?? false) throw const AudioExportCancelled();
        await _volumes.copyFile(
          plan.files[i].source,
          destination,
          '$staging/${plan.files[i].target.replaceAll('{name}', name)}',
          onConflict: ConflictPolicy.replace,
        );
        done += sizes[i];
        onProgress?.call(total == 0 ? 1 : done / total);
      }
      if (cancelled?.call() ?? false) throw const AudioExportCancelled();
      _place(stagingDir, '$mount/$target');
    } on FileSystemException catch (e) {
      _bestEffort(() => stagingDir.deleteSync(recursive: true));
      throw StorageFailure.io(e.osError?.message ?? e.message);
    } on Object {
      _bestEffort(() => stagingDir.deleteSync(recursive: true));
      rethrow;
    }
    return target;
  }

  /// Renames the finished [staging] directory to [target]. A directory
  /// already there (a `Replace`) is moved aside first and removed only once
  /// the new one is in place, so a failed rename leaves it as it was.
  static void _place(Directory staging, String target) {
    final existing = Directory(target);
    if (!existing.existsSync()) {
      staging.renameSync(target);
      return;
    }
    final aside = Directory('${staging.parent.path}/$stagingName.old');
    if (aside.existsSync()) aside.deleteSync(recursive: true);
    existing.renameSync(aside.path);
    try {
      staging.renameSync(target);
    } on Object {
      aside.renameSync(target);
      rethrow;
    }
    _bestEffort(() => aside.deleteSync(recursive: true));
  }

  static String _onDrive(String mount, String written) =>
      written.startsWith('/') ? written : '$mount/$written';

  static int _sizeOf(String path) {
    try {
      return File(path).lengthSync();
    } on FileSystemException {
      return 0;
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
