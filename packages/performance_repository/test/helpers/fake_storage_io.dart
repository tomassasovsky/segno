import 'dart:io';
import 'dart:typed_data';

import 'package:segno_engine/segno_engine.dart';

/// A [StorageIo] without the native library: a stand-in digest (see
/// [fakeDigest]) and a directory sync that records what it synced. The
/// real SHA-256 is the engine's, tested there.
class FakeStorageIo implements StorageIo {
  /// Every directory [syncDirectory] synced, on the isolate that asked.
  static final List<String> synced = [];

  @override
  String digestBytes(Uint8List bytes) => fakeDigest(bytes);

  @override
  FileDigest digestFile(String path, {int offset = 0, int? length}) {
    final file = File(path);
    if (!file.existsSync()) return const FileMissing();
    final bytes = file.readAsBytesSync();
    final end = length == null ? bytes.length : offset + length;
    if (end > bytes.length) return const FileTruncated();
    return FileDigested(fakeDigest(Uint8List.sublistView(bytes, offset, end)));
  }

  @override
  void syncDirectory(String path) => synced.add(path);

  @override
  RenameOutcome renameWithoutReplacing(String from, String to) =>
      throw UnimplementedError();
}

/// [FakeStorageIo] that cannot read any file.
class UnreadableStorageIo extends FakeStorageIo {
  @override
  FileDigest digestFile(String path, {int offset = 0, int? length}) =>
      const FileUnreadable();
}

/// Constructs a [FakeStorageIo]: a top-level function, so a background
/// isolate can call it.
StorageIo fakeStorageIo() => FakeStorageIo();

/// Constructs an [UnreadableStorageIo].
StorageIo unreadableStorageIo() => UnreadableStorageIo();

/// A 64-hex-digit stand-in for SHA-256 that depends on every byte and its
/// position: eight 32-bit FNV-1a lanes over the bytes, each seeded
/// differently.
String fakeDigest(Uint8List bytes) {
  final lanes = [for (var i = 0; i < 8; i++) 0x811c9dc5 + i];
  for (var i = 0; i < bytes.length; i++) {
    final lane = i % 8;
    lanes[lane] = ((lanes[lane] ^ bytes[i]) * 0x01000193) & 0xffffffff;
  }
  return lanes.map((v) => v.toRadixString(16).padLeft(8, '0')).join();
}
