import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:usb_storage_client/src/removable_volume_record.dart';
import 'package:usb_storage_client/src/usb_storage_client.dart';

/// The production [UsbStorageClient]: reads `segno-usb-ctl`'s files under
/// [runDir] and watches them with the platform's directory watcher (inotify on
/// the appliance). No timer, no polling, no subprocess (#806).
///
/// Only files named `<digits>.json` are volume records. The helper writes
/// through a dotfile (`.<gen>.json.tmp`) and renames it into place, so a
/// create event for a dotfile is noise and is ignored; the rename's
/// destination is what triggers a re-read. Every change re-lists the whole
/// directory rather than patching one entry, and a burst of events within one
/// event-loop turn produces one list, so a listener sees one attach as one
/// event.
class LinuxUsbStorageClient implements UsbStorageClient {
  /// Creates a [LinuxUsbStorageClient] over [runDir] (the helper's
  /// `/run/segno/usb`). [newRequestId] names eject requests; the default is a
  /// random 128-bit hex id, injectable for deterministic tests. [log] receives
  /// one line per skipped (malformed) file.
  LinuxUsbStorageClient({
    this.runDir = '/run/segno/usb',
    String Function()? newRequestId,
    void Function(String message)? log,
  }) : _newRequestId = newRequestId ?? _randomId,
       _log = log ?? _noLog;

  /// The helper's state directory.
  final String runDir;

  final String Function() _newRequestId;
  final void Function(String message) _log;

  final _listeners = <StreamController<List<RemovableVolumeRecord>>>{};
  StreamSubscription<FileSystemEvent>? _watch;
  List<RemovableVolumeRecord> _last = const [];
  bool _relistScheduled = false;

  static final RegExp _recordName = RegExp(r'^[0-9]+\.json$');

  /// `volumes/` under [runDir].
  String get volumesDir => '$runDir/volumes';

  /// `requests/` under [runDir].
  String get requestsDir => '$runDir/requests';

  @override
  bool get isSupported => Directory(volumesDir).existsSync();

  @override
  Stream<List<RemovableVolumeRecord>> get volumes {
    if (!isSupported) return Stream.value(const []);
    // One single-subscription controller per listener over one shared,
    // reference-counted directory watch. The watch is started before the
    // first read so no change can land between the two; its cancel is not
    // awaited, because the platform watcher's cancel future is not something
    // a listener's own cancel should hang on.
    late StreamController<List<RemovableVolumeRecord>> controller;
    controller = StreamController<List<RemovableVolumeRecord>>(
      onListen: () {
        _listeners.add(controller);
        _watch ??= Directory(volumesDir).watch().listen(_onEvent);
        _last = _readAll();
        controller.add(_last);
      },
      onCancel: () {
        _listeners.remove(controller);
        if (_listeners.isEmpty) {
          unawaited(_watch?.cancel());
          _watch = null;
        }
      },
    );
    return controller.stream;
  }

  void _onEvent(FileSystemEvent event) {
    if (!_isRecord(event.path) &&
        !(event is FileSystemMoveEvent && _isRecord(event.destination))) {
      return;
    }
    if (_relistScheduled) return;
    _relistScheduled = true;
    scheduleMicrotask(() {
      _relistScheduled = false;
      final next = _readAll();
      if (_sameList(next, _last)) return;
      _last = next;
      for (final listener in _listeners) {
        listener.add(next);
      }
    });
  }

  static bool _isRecord(String? path) =>
      path != null && _recordName.hasMatch(path.split('/').last);

  List<RemovableVolumeRecord> _readAll() {
    final dir = Directory(volumesDir);
    if (!dir.existsSync()) return const [];
    final records = <RemovableVolumeRecord>[];
    for (final entry in dir.listSync()) {
      if (entry is! File || !_isRecord(entry.path)) continue;
      final record = _readOne(entry);
      if (record != null) records.add(record);
    }
    records.sort((a, b) => a.generation.compareTo(b.generation));
    return records;
  }

  RemovableVolumeRecord? _readOne(File file) {
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map<String, Object?>) {
        throw const FormatException('not an object');
      }
      return RemovableVolumeRecord.fromJson(decoded);
    } on FormatException catch (e) {
      // Half-written or foreign: skip it, say so, keep the stream alive. The
      // helper renames complete files into place, so this is rare; a file that
      // stays malformed is a helper bug worth a log line, not a dead stream.
      _log('usb_storage_client: skipped ${file.path}: ${e.message}');
      return null;
    } on FileSystemException {
      // Deleted between the listing and the read: it is gone, so it is not
      // in the list.
      return null;
    }
  }

  static bool _sameList(
    List<RemovableVolumeRecord> a,
    List<RemovableVolumeRecord> b,
  ) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  Future<String> requestEject(int generation) async {
    final id = _newRequestId();
    final dir = Directory(requestsDir)..createSync(recursive: true);
    final body = jsonEncode({'generation': generation, 'request': id});
    // Rename, never write in place: the helper's path unit fires on the
    // directory, and a partial file could be served as a malformed request.
    File('${dir.path}/.$id.json.tmp')
      ..writeAsStringSync(body, flush: true)
      ..renameSync('${dir.path}/$id.json');
    return id;
  }

  @override
  Future<void> cancelEject(String requestId) async {
    final file = File('$requestsDir/$requestId.json');
    try {
      file.deleteSync();
    } on FileSystemException {
      // Already served (deleted by the helper) or never written: nothing to
      // withdraw.
    }
  }

  static String _randomId() {
    final random = Random.secure();
    final buffer = StringBuffer();
    for (var i = 0; i < 16; i++) {
      buffer.write(random.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }

  static void _noLog(String message) {}
}
