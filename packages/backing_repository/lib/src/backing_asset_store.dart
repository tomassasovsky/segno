import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:backing_repository/src/models/backing_asset.dart';
import 'package:backing_repository/src/models/backing_failure.dart';
import 'package:segno_engine/segno_engine.dart';

/// Copies [sourcePath] to [relativePath] under the Internal root and returns
/// the path written: `StorageRepository.copyFile` to Internal in production
/// (`.part`, fsync, rename; nothing left behind on failure). Throws on any
/// failure.
typedef BackingCopier =
    Future<String> Function(
      String sourcePath,
      String relativePath,
    );

/// The SHA-256 of the file at a path as 64 lower-case hex digits, or null
/// when it cannot be read (`StorageIo.digestFile`).
typedef BackingDigester = Future<String?> Function(String path);

/// Makes a directory's entries durable (`StorageIo.syncDirectory`).
typedef BackingDirSync = void Function(String path);

/// The managed `Backing tracks` store (plan D7): content-addressed internal
/// copies, validated at import by a probe that keeps no samples.
///
/// Layout: `<root>/Backing tracks/<16 hex>/<original name>` plus `info.json`
/// (`digest`, `name`, `sourceRate`, `sourceChannels`, `sourceFrames`,
/// `peaks`). The directory name is the digest's first 16 hex digits; the
/// identity is the full digest, which `info.json` carries and [resolve]
/// checks against the bytes before a load.
class BackingAssetStore {
  /// Creates a [BackingAssetStore] under [root] (the exports root).
  BackingAssetStore({
    required Future<String> Function() root,
    required AudioDecoder decoder,
    required BackingCopier copier,
    BackingDigester? digester,
    BackingDirSync? syncDirectory,
  }) : _root = root,
       _decoder = decoder,
       _copier = copier,
       _digester = digester ?? _nativeDigest,
       _sync = syncDirectory ?? NativeStorageIo().syncDirectory;

  /// The store's directory name under the root.
  static const String folder = 'Backing tracks';

  /// The extensions the decoder reads.
  static const Set<String> playable = {'.wav', '.mp3'};

  final Future<String> Function() _root;
  final AudioDecoder _decoder;
  final BackingCopier _copier;
  final BackingDigester _digester;
  final BackingDirSync _sync;

  static Future<String?> _nativeDigest(String path) =>
      Isolate.run(() => NativeStorageIo().digestFile(path));

  Future<Directory> _store() async => Directory('${await _root()}/$folder');

  /// Every asset in the store, available or not, by name.
  Future<List<BackingAsset>> list() async {
    final store = await _store();
    if (!store.existsSync()) return const [];
    final assets = <BackingAsset>[];
    for (final entry in store.listSync()) {
      if (entry is! Directory) continue;
      final id = _basename(entry.path);
      if (!_id.hasMatch(id)) continue;
      final asset = _read(entry);
      if (asset != null) assets.add(asset);
    }
    assets.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return assets;
  }

  /// Imports [sourcePath] as [name] (its own file name by default), reusing
  /// an existing copy of the same bytes.
  ///
  /// Digests the source, copies it in, probes the copy (decoding all of it,
  /// keeping nothing) and checks the copy's digest, then publishes
  /// `info.json` durably. Throws a [BackingFailure]; on any failure nothing
  /// new is left in the store.
  Future<BackingAsset> import(String sourcePath, {String? name}) async {
    final fileName = name ?? _basename(sourcePath);
    final hex = await _digester(sourcePath);
    if (hex == null) {
      throw BackingFailure(BackingFailureReason.missing, name: fileName);
    }
    final digest = 'sha256:$hex';
    final store = await _store();
    final dir = Directory('${store.path}/${BackingAsset.idOf(digest)}');
    final existing = dir.existsSync() ? _read(dir) : null;
    if (existing != null && existing.digest == digest && existing.available) {
      return existing;
    }
    if (dir.existsSync()) dir.deleteSync(recursive: true);
    try {
      final path = await _copyIn(sourcePath, dir, fileName);
      final probe = await _probe(path, fileName, digest);
      if (await _digester(path) != hex) {
        throw BackingFailure(
          BackingFailureReason.damaged,
          name: fileName,
          digest: digest,
        );
      }
      final asset = BackingAsset(
        digest: digest,
        name: fileName,
        path: path,
        sourceRate: probe.info.sourceRate,
        sourceChannels: probe.info.sourceChannels,
        sourceFrames: probe.info.sourceFrames,
        peaks: probe.peaks,
      );
      _publishInfo(dir, asset);
      _sync(store.path);
      return asset;
    } on Object {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
      rethrow;
    }
  }

  /// The asset with [digest], verified against its bytes. Throws a
  /// [BackingFailure]: [BackingFailureReason.missing] when the store has no
  /// such asset or its file is gone, [BackingFailureReason.damaged] when the
  /// bytes no longer match.
  Future<BackingAsset> resolve(String digest, {String name = ''}) async {
    if (!BackingAsset.isDigest(digest)) {
      throw BackingFailure(BackingFailureReason.missing, name: name);
    }
    final dir = Directory(
      '${(await _store()).path}/${BackingAsset.idOf(digest)}',
    );
    final asset = dir.existsSync() ? _read(dir) : null;
    if (asset == null || asset.digest != digest) {
      throw BackingFailure(
        BackingFailureReason.missing,
        name: name,
        digest: digest,
      );
    }
    if (!asset.available) {
      throw BackingFailure(asset.problem!, name: asset.name, digest: digest);
    }
    if ('sha256:${await _digester(asset.path)}' != digest) {
      throw BackingFailure(
        BackingFailureReason.damaged,
        name: asset.name,
        digest: digest,
      );
    }
    return asset;
  }

  Future<String> _copyIn(String source, Directory dir, String name) async {
    try {
      return await _copier(source, '$folder/${_basename(dir.path)}/$name');
    } on Object {
      throw BackingFailure(BackingFailureReason.storage, name: name);
    }
  }

  Future<AudioProbe> _probe(String path, String name, String digest) async {
    try {
      return await _decoder.probe(path); // 512 peaks, the decoder's default
    } on EngineException catch (e) {
      final reason = e.result == EngineResult.invalid && !_playable(name)
          ? BackingFailureReason.unsupported
          : BackingFailureReason.fromEngine(e.result);
      throw BackingFailure(reason, name: name, digest: digest);
    }
  }

  /// `info.json` written as `.part`, renamed, then the directory synced.
  void _publishInfo(Directory dir, BackingAsset asset) {
    File('${dir.path}/$_info.part')
      ..writeAsStringSync(
        jsonEncode({
          'digest': asset.digest,
          'name': asset.name,
          'sourceRate': asset.sourceRate,
          'sourceChannels': asset.sourceChannels,
          'sourceFrames': asset.sourceFrames,
          'peaks': asset.peaks,
        }),
        flush: true,
      )
      ..renameSync('${dir.path}/$_info');
    _sync(dir.path);
  }

  /// The asset in [dir], or null when the directory holds nothing of ours.
  BackingAsset? _read(Directory dir) {
    final id = _basename(dir.path);
    final files = dir
        .listSync()
        .whereType<File>()
        .where((f) => !_basename(f.path).startsWith(_info))
        .where((f) => !f.path.endsWith('.part'))
        .toList();
    final audio = files.isEmpty ? null : files.first;
    Map<String, Object?>? info;
    try {
      final decoded = jsonDecode(File('${dir.path}/$_info').readAsStringSync());
      if (decoded is Map<String, Object?>) info = decoded;
    } on Object {
      info = null;
    }
    final digest = info?['digest'];
    final name = info?['name'];
    final valid =
        info != null &&
        digest is String &&
        BackingAsset.isDigest(digest) &&
        BackingAsset.idOf(digest) == id &&
        name is String &&
        info['sourceRate'] is int &&
        info['sourceChannels'] is int &&
        info['sourceFrames'] is int &&
        info['peaks'] is List;
    if (!valid) {
      if (audio == null) return null;
      return BackingAsset(
        digest: digest is String && BackingAsset.isDigest(digest)
            ? digest
            : 'sha256:$id${'0' * 48}',
        name: _basename(audio.path),
        path: audio.path,
        problem: BackingFailureReason.damaged,
      );
    }
    final path = '${dir.path}/$name';
    return BackingAsset(
      digest: digest,
      name: name,
      path: path,
      sourceRate: info['sourceRate']! as int,
      sourceChannels: info['sourceChannels']! as int,
      sourceFrames: info['sourceFrames']! as int,
      peaks: [for (final p in info['peaks']! as List) (p as num).toDouble()],
      problem: File(path).existsSync() ? null : BackingFailureReason.missing,
    );
  }

  static bool _playable(String name) {
    final dot = name.lastIndexOf('.');
    return dot >= 0 && playable.contains(name.substring(dot).toLowerCase());
  }

  static String _basename(String path) {
    final parts = path.split(Platform.pathSeparator);
    return parts.isEmpty ? path : parts.last;
  }

  static const String _info = 'info.json';
  static final RegExp _id = RegExp(r'^[0-9a-f]{16}$');
}
