import 'dart:io';

import 'package:equatable/equatable.dart';
import 'package:storage_repository/storage_repository.dart';
import 'package:update_repository/update_repository.dart';

/// An update package found on a USB drive (#1270 Part 8).
class UsbUpdatePackage extends Equatable {
  /// Creates a [UsbUpdatePackage].
  const UsbUpdatePackage({
    required this.generation,
    required this.path,
    required this.sizeBytes,
    this.version,
  });

  /// The drive it is on.
  final int generation;

  /// Where it is.
  final String path;

  /// Its size.
  final int sizeBytes;

  /// The version its name carries (`segno-1.1.0.raucb`), or null when the
  /// name does not say. The helper reads the real one from the bundle.
  final Version? version;

  /// Its file name.
  String get name => path.substring(path.lastIndexOf('/') + 1);

  @override
  List<Object?> get props => [generation, path, sizeBytes, version];
}

/// Where on a drive packages are looked for: the root, and this folder.
const kUsbUpdateFolder = 'segno-updates';

/// The update packages on [volumes] that can be read: every `*.raucb` at a
/// drive's root and in its [kUsbUpdateFolder], by name. A folder that cannot
/// be read lists nothing.
Future<List<UsbUpdatePackage>> listUsbUpdatePackages(
  Iterable<RemovableVolume> volumes,
) async {
  final found = <UsbUpdatePackage>[];
  for (final volume in volumes) {
    final mount = volume.mountPoint;
    if (!volume.readable || mount == null) continue;
    for (final folder in [mount, '$mount/$kUsbUpdateFolder']) {
      final directory = Directory(folder);
      try {
        if (!directory.existsSync()) continue;
        await for (final entity in directory.list(followLinks: false)) {
          if (entity is! File || !entity.path.endsWith('.raucb')) continue;
          found.add(
            UsbUpdatePackage(
              generation: volume.generation,
              path: entity.path,
              sizeBytes: await entity.length(),
              version: _versionIn(entity.path),
            ),
          );
        }
      } on FileSystemException {
        continue;
      }
    }
  }
  found.sort((a, b) => a.name.compareTo(b.name));
  return found;
}

final _versionInName = RegExp(r'(\d+\.\d+\.\d+(?:-[0-9A-Za-z.]+)?)\.raucb$');

Version? _versionIn(String path) {
  final match = _versionInName.firstMatch(path);
  if (match == null) return null;
  try {
    return Version.parse(match.group(1)!);
  } on FormatException {
    return null;
  }
}
