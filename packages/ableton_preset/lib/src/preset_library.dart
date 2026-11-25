import 'dart:io';

import 'package:ableton_preset/src/ableton_preset.dart';
import 'package:ableton_preset/src/device_schema.dart';
import 'package:ableton_preset/src/drift_schema.dart';
import 'package:ableton_preset/src/preset_reader.dart';
import 'package:path/path.dart' as p;

/// The devices Segno can play, by element name.
final Map<String, DeviceSchema> playableDevices = Map.unmodifiable({
  'Drift': DriftSchema(),
});

/// Whether Segno can play a library entry.
enum PresetStatus {
  /// A device preset whose device Segno plays.
  playable,

  /// A device preset of a device Segno does not play (yet).
  unsupportedDevice,

  /// A rack (`.adg`): not played for now.
  rack,

  /// The file is not a preset this reader can read.
  unreadable,
}

/// One preset file in a library.
final class LibraryEntry {
  /// An entry for the file at [path].
  const new({
    required this.path,
    required this.name,
    required this.folderPath,
    required this.status,
    this.preset,
    this.error,
  });

  /// The file's path.
  final String path;

  /// The preset's name (the file name without its extension).
  final String name;

  /// The folders between the library's root and the file, outermost first.
  final List<String> folderPath;

  /// Whether Segno can play it.
  final PresetStatus status;

  /// The preset as read; null when [status] is [PresetStatus.unreadable].
  final AbletonPreset? preset;

  /// Why the file could not be read, when [status] is
  /// [PresetStatus.unreadable].
  final AbletonPresetException? error;

  /// The preset's device; null when unreadable.
  String? get device => preset?.device;
}

/// The presets under one folder (a USB drive, Internal, or Live's own
/// `Ableton Live Devices`).
final class PresetLibrary {
  /// A library of [entries].
  const new(this.entries);

  /// Walks [root] and reads every `.adv` and `.adg` under it, each file
  /// once. Hidden files and folders (names starting with `.`, such as the
  /// `._` files macOS leaves on FAT drives) are skipped, and so are links
  /// and folders that cannot be listed. Entries come in path order.
  static Future<PresetLibrary> scan(
    Directory root, {
    Map<String, DeviceSchema>? devices,
  }) async {
    final playable = devices ?? playableDevices;
    final entries = <LibraryEntry>[];
    await _walk(root, const [], playable, entries);
    return PresetLibrary(entries);
  }

  /// Every preset file found, in path order.
  final List<LibraryEntry> entries;

  /// The readable entries grouped by device, each group in path order (so
  /// Live's folders stay together).
  Map<String, List<LibraryEntry>> get byDevice {
    final groups = <String, List<LibraryEntry>>{};
    for (final entry in entries) {
      final device = entry.device;
      if (device != null) (groups[device] ??= []).add(entry);
    }
    return groups;
  }

  static Future<void> _walk(
    Directory directory,
    List<String> folders,
    Map<String, DeviceSchema> playable,
    List<LibraryEntry> entries,
  ) async {
    final List<FileSystemEntity> children;
    try {
      children = await directory.list(followLinks: false).toList();
    } on FileSystemException {
      return;
    }
    children.sort((a, b) => a.path.compareTo(b.path));
    for (final child in children) {
      final base = p.basename(child.path);
      if (base.startsWith('.')) continue;
      if (child is Directory) {
        await _walk(child, [...folders, base], playable, entries);
      } else if (child is File) {
        final extension = p.extension(base).toLowerCase();
        if (extension != '.adv' && extension != '.adg') continue;
        entries.add(await _entry(child, folders, playable));
      }
    }
  }

  static Future<LibraryEntry> _entry(
    File file,
    List<String> folders,
    Map<String, DeviceSchema> playable,
  ) async {
    final name = p.basenameWithoutExtension(file.path);
    try {
      final preset = await AbletonPresetReader.read(file, folderPath: folders);
      return LibraryEntry(
        path: file.path,
        name: name,
        folderPath: folders,
        status: switch (preset.kind) {
          PresetKind.rack => PresetStatus.rack,
          PresetKind.device when playable.containsKey(preset.device) =>
            PresetStatus.playable,
          PresetKind.device => PresetStatus.unsupportedDevice,
        },
        preset: preset,
      );
    } on AbletonPresetException catch (error) {
      return LibraryEntry(
        path: file.path,
        name: name,
        folderPath: folders,
        status: PresetStatus.unreadable,
        error: error,
      );
    }
  }
}
