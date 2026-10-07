import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:meta/meta.dart';
import 'package:segno_engine/src/audio_engine.dart';
import 'package:segno_engine/src/engine_library.dart';
import 'package:segno_engine/src/generated/segno_engine_bindings.dart';

/// The outcome of digesting a file range ([StorageIo.digestFile]).
///
/// Recovery tells a missing recording from a damaged one by this, not by a
/// separate existence check the file could change under.
sealed class FileDigest {
  const FileDigest();
}

/// The range was read whole: [sha256] is its digest, 64 lower-case hex
/// digits.
@immutable
final class FileDigested extends FileDigest {
  /// Creates a [FileDigested].
  const FileDigested(this.sha256);

  /// The digest.
  final String sha256;

  @override
  bool operator ==(Object other) =>
      other is FileDigested && other.sha256 == sha256;

  @override
  int get hashCode => sha256.hashCode;

  @override
  String toString() => 'FileDigested($sha256)';
}

/// Nothing exists at the path (or a directory on it is missing).
final class FileMissing extends FileDigest {
  /// Creates a [FileMissing].
  const FileMissing();
}

/// The file exists but is shorter than the range it must hold: damaged.
final class FileTruncated extends FileDigest {
  /// Creates a [FileTruncated].
  const FileTruncated();
}

/// The file could not be read: not a regular file, no permission, or an I/O
/// error (a failing drive).
final class FileUnreadable extends FileDigest {
  /// Creates a [FileUnreadable].
  const FileUnreadable();
}

/// Recorded-audio identity and durable publication, without an engine.
///
/// Recorded audio is identified by the SHA-256 of its sample payload, so an
/// intact copy is recognised wherever it is and whatever it is called, and a
/// damaged or different file never passes for it (accepted behaviour 6.10).
/// Directory sync is what makes a rename durable: a bundle is published by
/// writing a temporary file, syncing it, renaming it into place and then
/// syncing the directory, and Dart has no way to do the last step itself.
///
/// None of this touches the audio engine, so a repository can hold one of
/// these beside its `AudioEngine`, and [NativeStorageIo] can be constructed
/// inside `Isolate.run` to digest a multi-gigabyte file off the UI isolate.
abstract interface class StorageIo {
  /// The SHA-256 of [bytes], as 64 lower-case hex digits.
  ///
  /// Hashed through a fixed native window ([NativeStorageIo.windowBytes]),
  /// so a layer of hundreds of megabytes is never copied whole.
  String digestBytes(Uint8List bytes);

  /// The SHA-256 of [length] bytes of the file at [path] starting at
  /// [offset]; a null [length] reads to the end of the file.
  ///
  /// [FileMissing] when nothing is there, [FileTruncated] when the file is
  /// shorter than the range (a damaged file never yields a digest of whatever
  /// is left in it), [FileUnreadable] otherwise. The file is read in 64 KiB
  /// chunks. Throws [ArgumentError] for an empty path or a negative range.
  FileDigest digestFile(String path, {int offset = 0, int? length});

  /// Makes the entries of the directory at [path] durable, so a rename into
  /// it survives a power cut.
  ///
  /// Throws a [FileSystemException], carrying the OS error, when the
  /// directory cannot be opened or the sync fails: a caller must not report
  /// a publication as durable when it is not.
  void syncDirectory(String path);

  /// Renames [from] to [to] only if nothing is at [to], as one atomic step.
  ///
  /// A copy publishes its part this way, so a name another writer took
  /// meanwhile is never overwritten and no placeholder ever stands at the
  /// final name. [RenameOutcome.nameTaken] means nothing moved;
  /// [RenameOutcome.unsupported] means the kernel or the filesystem cannot
  /// refuse a replacement and nothing moved (the caller falls back). Throws a
  /// [FileSystemException] carrying the OS error for any other failure.
  RenameOutcome renameWithoutReplacing(String from, String to);
}

/// What [StorageIo.renameWithoutReplacing] did.
enum RenameOutcome {
  /// The file is at its new name.
  renamed,

  /// Something was already at the new name; nothing moved.
  nameTaken,

  /// This kernel or filesystem cannot refuse a replacement; nothing moved.
  unsupported,
}

/// The [StorageIo] backed by the native engine library.
class NativeStorageIo implements StorageIo {
  /// Creates a [NativeStorageIo], opening the native library in the current
  /// isolate unless [bindings] are injected.
  NativeStorageIo({SegnoEngineBindings? bindings})
    : _bindings = bindings ?? SegnoEngineBindings(openSegnoEngineLibrary());

  final SegnoEngineBindings _bindings;

  static const int _digestBytes = 32;

  /// `UINT64_MAX` as the native API spells "to the end of the file".
  static const int _toEnd = -1;

  /// The native window [digestBytes] copies through, a piece at a time.
  static const int windowBytes = 1 << 20;

  @override
  String digestBytes(Uint8List bytes) {
    final state = calloc<Uint64>(LE_DIGEST_STATE_BYTES ~/ 8);
    final window = malloc<Uint8>(
      bytes.length < windowBytes
          ? (bytes.isEmpty ? 1 : bytes.length)
          : windowBytes,
    );
    final out = calloc<Uint8>(_digestBytes);
    try {
      _check(_bindings.le_digest_begin(state.cast(), LE_DIGEST_STATE_BYTES));
      for (var at = 0; at < bytes.length; at += windowBytes) {
        final end = at + windowBytes < bytes.length
            ? at + windowBytes
            : bytes.length;
        window.asTypedList(end - at).setRange(0, end - at, bytes, at);
        _check(
          _bindings.le_digest_update(state.cast(), window.cast(), end - at),
        );
      }
      _check(_bindings.le_digest_end(state.cast(), out));
      return _hex(out);
    } finally {
      calloc
        ..free(out)
        ..free(state);
      malloc.free(window);
    }
  }

  static void _check(int code) {
    if (!EngineResult.fromCode(code).isOk) {
      throw EngineException(EngineResult.fromCode(code), 'digest failed');
    }
  }

  @override
  FileDigest digestFile(String path, {int offset = 0, int? length}) {
    if (path.isEmpty) throw ArgumentError.value(path, 'path');
    if (offset < 0) throw ArgumentError.value(offset, 'offset');
    if (length != null && length < 0) {
      throw ArgumentError.value(length, 'length');
    }
    final pathPtr = path.toNativeUtf8();
    final out = calloc<Uint8>(_digestBytes);
    try {
      final code = _bindings.le_digest_file(
        pathPtr.cast(),
        offset,
        length ?? _toEnd,
        out,
      );
      return switch (code) {
        0 => FileDigested(_hex(out)),
        _ when code == le_result.LE_ERR_NOT_FOUND.value => const FileMissing(),
        _ when code == le_result.LE_ERR_TRUNCATED.value =>
          const FileTruncated(),
        _ => const FileUnreadable(),
      };
    } finally {
      calloc.free(out);
      malloc.free(pathPtr);
    }
  }

  @override
  void syncDirectory(String path) {
    final pathPtr = path.toNativeUtf8();
    final errorPtr = calloc<Int32>();
    try {
      final code = _bindings.le_fs_sync_dir_errno(pathPtr.cast(), errorPtr);
      if (!EngineResult.fromCode(code).isOk) {
        final errno = errorPtr.value;
        throw FileSystemException(
          'could not sync the directory',
          path,
          errno == 0 ? null : OSError('sync failed', errno),
        );
      }
    } finally {
      calloc.free(errorPtr);
      malloc.free(pathPtr);
    }
  }

  @override
  RenameOutcome renameWithoutReplacing(String from, String to) {
    final fromPtr = from.toNativeUtf8();
    final toPtr = to.toNativeUtf8();
    final errorPtr = calloc<Int32>();
    try {
      final code = _bindings.le_fs_rename_noreplace(
        fromPtr.cast(),
        toPtr.cast(),
        errorPtr,
      );
      switch (EngineResult.fromCode(code)) {
        case EngineResult.ok:
          return RenameOutcome.renamed;
        case EngineResult.unsupported:
          return RenameOutcome.unsupported;
        case EngineResult.device when errorPtr.value == _eexist:
          return RenameOutcome.nameTaken;
        case EngineResult.device:
          throw FileSystemException(
            'could not rename to $to',
            from,
            OSError('rename failed', errorPtr.value),
          );
        case _:
          throw FileSystemException('could not rename to $to', from);
      }
    } finally {
      calloc.free(errorPtr);
      malloc
        ..free(toPtr)
        ..free(fromPtr);
    }
  }

  static const int _eexist = 17;

  static String _hex(Pointer<Uint8> digest) {
    final buffer = StringBuffer();
    for (final byte in digest.asTypedList(_digestBytes)) {
      buffer.write(byte.toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }
}
