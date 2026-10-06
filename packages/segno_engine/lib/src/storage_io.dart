import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:segno_engine/src/audio_engine.dart';
import 'package:segno_engine/src/engine_library.dart';
import 'package:segno_engine/src/generated/segno_engine_bindings.dart';

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
  String digestBytes(Uint8List bytes);

  /// The SHA-256 of [length] bytes of the file at [path] starting at
  /// [offset], as 64 lower-case hex digits; a null [length] reads to the end
  /// of the file.
  ///
  /// Null when the file cannot be read, is not a regular file, or is shorter
  /// than the range: a damaged file never yields a digest of whatever is left
  /// in it. The file is read in 64 KiB chunks.
  String? digestFile(String path, {int offset = 0, int? length});

  /// Makes the entries of the directory at [path] durable, so a rename into
  /// it survives a power cut.
  ///
  /// Throws a [FileSystemException] when the directory cannot be opened or
  /// the sync fails: a caller must not report a publication as durable when
  /// it is not.
  void syncDirectory(String path);
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

  @override
  String digestBytes(Uint8List bytes) {
    final data = bytes.isEmpty ? nullptr : malloc<Uint8>(bytes.length);
    final out = calloc<Uint8>(_digestBytes);
    try {
      if (data != nullptr) data.asTypedList(bytes.length).setAll(0, bytes);
      final code = _bindings.le_digest_bytes(data.cast(), bytes.length, out);
      if (!EngineResult.fromCode(code).isOk) {
        throw EngineException(
          EngineResult.fromCode(code),
          'digest of ${bytes.length} bytes failed',
        );
      }
      return _hex(out);
    } finally {
      calloc.free(out);
      if (data != nullptr) malloc.free(data);
    }
  }

  @override
  String? digestFile(String path, {int offset = 0, int? length}) {
    if (path.isEmpty || offset < 0 || (length != null && length < 0)) {
      return null;
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
      return EngineResult.fromCode(code).isOk ? _hex(out) : null;
    } finally {
      calloc.free(out);
      malloc.free(pathPtr);
    }
  }

  @override
  void syncDirectory(String path) {
    final pathPtr = path.toNativeUtf8();
    try {
      final code = _bindings.le_fs_sync_dir(pathPtr.cast());
      if (!EngineResult.fromCode(code).isOk) {
        throw FileSystemException('could not sync the directory', path);
      }
    } finally {
      malloc.free(pathPtr);
    }
  }

  static String _hex(Pointer<Uint8> digest) {
    final buffer = StringBuffer();
    for (final byte in digest.asTypedList(_digestBytes)) {
      buffer.write(byte.toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }
}
