import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:meta/meta.dart';

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
///
/// The watch itself can fail: inotify drops events when its queue overflows
/// and reports that as an error, and a watch can end. Either way events may
/// have been lost, so the client logs it and re-lists the directory; a watch
/// that ended is started again while anyone is listening, after a delay that
/// doubles while the watch keeps ending straight away (an exhausted inotify
/// limit would otherwise make that a tight log-and-relist loop).
class LinuxUsbStorageClient implements UsbStorageClient {
  /// Creates a [LinuxUsbStorageClient] over [runDir] (the helper's
  /// `/run/segno/usb`). [newRequestId] names eject requests; the default is a
  /// random 128-bit hex id, injectable for deterministic tests. [log] receives
  /// one line per skipped file and per watch failure. [watchDirectory] is the
  /// platform's directory watcher, injectable so tests can make it fail.
  /// [restartDelay] is the first wait before an ended watch is started again;
  /// it doubles up to [maxRestartDelay] while watches keep ending, and comes
  /// back to [restartDelay] once a watch delivers an event.
  LinuxUsbStorageClient({
    this.runDir = '/run/segno/usb',
    String Function()? newRequestId,
    void Function(String message)? log,
    @visibleForTesting
    Stream<FileSystemEvent> Function(String path)? watchDirectory,
    @visibleForTesting this.restartDelay = const Duration(seconds: 1),
    @visibleForTesting this.maxRestartDelay = const Duration(seconds: 30),
  }) : _newRequestId = newRequestId ?? _randomId,
       _log = log ?? _noLog,
       _watchDirectory = watchDirectory ?? _platformWatch,
       _nextRestart = restartDelay;

  /// The helper's state directory.
  final String runDir;

  /// The first wait before an ended watch is started again.
  final Duration restartDelay;

  /// The longest wait between two restarts.
  final Duration maxRestartDelay;

  final String Function() _newRequestId;
  final void Function(String message) _log;
  final Stream<FileSystemEvent> Function(String path) _watchDirectory;

  final _listeners = <StreamController<List<RemovableVolumeRecord>>>{};
  StreamSubscription<FileSystemEvent>? _watch;
  Timer? _restart;
  Duration _nextRestart;
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
        if (_restart == null) _watch ??= _startWatch();
        _last = _readAll();
        controller.add(_last);
      },
      onCancel: () {
        _listeners.remove(controller);
        if (_listeners.isEmpty) {
          unawaited(_watch?.cancel());
          _watch = null;
          _restart?.cancel();
          _restart = null;
        }
      },
    );
    return controller.stream;
  }

  StreamSubscription<FileSystemEvent> _startWatch() {
    return _watchDirectory(volumesDir).listen(
      _onEvent,
      onError: (Object error) {
        // An inotify queue overflow, or any other watcher failure: events may
        // be gone, so the list is read again rather than trusted.
        _log('usb_storage_client: watch of $volumesDir failed: $error');
        _relist();
      },
      onDone: () {
        // Only a live subscription ends this way (a cancel does not call
        // onDone), so someone is listening: watch again after the backoff,
        // unless the directory itself is gone, where a new watch would only
        // end again.
        _log(
          'usb_storage_client: watch of $volumesDir ended; '
          'watching again in ${_nextRestart.inMilliseconds} ms',
        );
        _watch = null;
        _relist();
        if (!isSupported) return;
        final wait = _nextRestart;
        final doubled = _nextRestart * 2;
        _nextRestart = doubled > maxRestartDelay ? maxRestartDelay : doubled;
        _restart = Timer(wait, () {
          _restart = null;
          if (_listeners.isEmpty || !isSupported) return;
          _watch = _startWatch();
          _relist();
        });
      },
    );
  }

  void _onEvent(FileSystemEvent event) {
    // A watch that delivers is a working watch: the next failure starts the
    // backoff from the beginning.
    _nextRestart = restartDelay;
    if (!_isRecord(event.path) &&
        !(event is FileSystemMoveEvent && _isRecord(event.destination))) {
      return;
    }
    _relist();
  }

  /// Re-reads the directory once per event-loop turn and emits the list when
  /// it changed.
  void _relist() {
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
      if (entry is Directory || !_isRecord(entry.path)) continue;
      final record = _readOne(File(entry.path));
      if (record != null) records.add(record);
    }
    records.sort((a, b) => a.generation.compareTo(b.generation));
    return records;
  }

  RemovableVolumeRecord? _readOne(File file) {
    try {
      // Bytes, decoded leniently: a label byte that is not UTF-8 shows as a
      // replacement character instead of hiding the whole volume.
      final text = utf8.decode(file.readAsBytesSync(), allowMalformed: true);
      final decoded = jsonDecode(text);
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
    } on PathNotFoundException {
      // Deleted between the listing and the read: it is gone, so it is not
      // in the list.
      return null;
    } on FileSystemException catch (e) {
      // There but unreadable: leave it out, and say so, because a volume
      // missing from the app with nothing in the log cannot be traced.
      _log('usb_storage_client: could not read ${file.path}: ${e.message}');
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
  Future<bool> cancelEject(String requestId) async {
    final file = File('$requestsDir/$requestId.json');
    try {
      file.deleteSync();
      return true;
    } on FileSystemException {
      // Already taken by the helper (it deletes a request before it
      // unmounts) or never written: nothing to withdraw, and the answer, if
      // any, is still coming.
      return false;
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

  static Stream<FileSystemEvent> _platformWatch(String path) =>
      Directory(path).watch();
}
