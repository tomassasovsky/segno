import 'dart:typed_data';

import 'package:segno_engine/segno_engine.dart';

/// A [StorageIo] without the native library, for a `PerformanceRepository`
/// that finalizes takes in a test: every file reads as the same stand-in
/// digest and a directory sync does nothing. The real calls are the
/// engine's, tested there.
class FakeStorageIo implements StorageIo {
  /// The stand-in digest every read returns.
  static final String digest = '0' * 64;

  @override
  String digestBytes(Uint8List bytes) => digest;

  @override
  FileDigest digestFile(String path, {int offset = 0, int? length}) =>
      FileDigested(digest);

  @override
  void syncDirectory(String path) {}

  @override
  RenameOutcome renameWithoutReplacing(String from, String to) =>
      throw UnimplementedError();
}

/// Constructs a [FakeStorageIo]: a top-level function, so a background
/// isolate can call it.
StorageIo fakeStorageIo() => FakeStorageIo();
