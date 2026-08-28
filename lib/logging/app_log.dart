import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

/// Durable, size-rotated application logfile. On the appliance the directory
/// is `$HOME/log` → `/data/log` (see `segno-kiosk-launch`). Mirrors every line
/// to `developer.log` / stderr so `journalctl -u segno.service` still works.
///
/// **This runs on the UI isolate at footswitch-press time.** `ControlCubit`
/// logs every press, momentary and binding toggle through here, and this app
/// drives a live looper whose RT audio thread shares four cores — a blocking
/// syscall here is a correctness bug, not a micro-optimisation (#804/#806).
/// So the write path costs exactly one `write(2)`:
///
/// * the file handle is opened ONCE and held, instead of an open/close per
///   line;
/// * the active size is COUNTED, instead of two `stat`s per line asking the
///   filesystem what we already know;
/// * `fsync` is reserved for [error], the only lines whose value is surviving
///   a crash that is happening right now. A plain [info] still reaches the OS
///   page cache synchronously, so it survives a process crash all the same —
///   only a power cut can lose it — which is all a breadcrumb needs;
/// * the journal mirror is one `stderr` write rather than three (stderr is
///   unbuffered, so each call was its own syscall).
class AppLog {
  AppLog._();

  /// Current log file name inside the init directory.
  static const String fileName = 'segno.log';

  /// Rotate when the active file reaches this many bytes (~2 MiB).
  static const int maxBytes = 2 * 1024 * 1024;

  /// Keep the active file plus this many rotated siblings (`.1`, `.2`, …).
  static const int rotatedCount = 2;

  static Directory? _directory;

  /// The held append handle. Null until [init], and again after [close].
  static RandomAccessFile? _handle;

  /// Bytes in the active file, counted rather than stat-ed — see the class
  /// doc. Seeded from the file's length when the handle is opened.
  static int _bytes = 0;

  static int _flushCount = 0;
  static bool _initialized = false;

  /// Whether [init] has completed successfully.
  static bool get isInitialized => _initialized;

  /// Test-only: how many `fsync`s the write path has paid since the last
  /// [init]. Should stay at zero across any number of [info] / [warn] lines.
  static int get debugFlushCount => _flushCount;

  /// Creates [directory] if needed and opens `segno.log` for append. Safe to
  /// call more than once (subsequent calls are no-ops).
  static Future<void> init({required Directory directory}) async {
    if (_initialized) return;
    _directory = directory;
    await directory.create(recursive: true);
    _flushCount = 0;
    _open();
    _initialized = true;
  }

  /// Resolves `$HOME/log` (or `%USERPROFILE%\log` on Windows). Falls back to
  /// a temp dir when neither env var is set (tests / odd hosts).
  static Directory defaultDirectory() {
    final home =
        Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    if (home != null && home.isNotEmpty) {
      return Directory('$home/log');
    }
    return Directory('${Directory.systemTemp.path}/segno-log');
  }

  /// Informational breadcrumb.
  static void info(String message) => _write('I', message);

  /// Non-fatal warning.
  static void warn(String message) => _write('W', message);

  /// Error, optionally with [error] / [stack]. The only level that syncs to
  /// the disk — see the class doc.
  static void error(
    String message, {
    Object? error,
    StackTrace? stack,
  }) => _write('E', message, error: error, stack: stack);

  /// Releases the logfile handle, syncing whatever the OS still holds.
  ///
  /// Nothing is buffered in-process (each line is written straight through),
  /// so this loses no lines and exists to hand the handle back — at process
  /// teardown, and between tests. A later [init] reopens and appends.
  static void close() {
    final handle = _handle;
    _handle = null;
    _bytes = 0;
    _initialized = false;
    _directory = null;
    if (handle == null) return;
    try {
      handle
        ..flushSync()
        ..closeSync();
    } on Object {
      // A logfile must not take the app down on the way out either.
    }
  }

  /// Opens (creating if needed) the active file for append and seeds the byte
  /// counter from its current length — the one and only `stat`, paid per open
  /// rather than per line.
  ///
  /// Swallows its own failures: an unopenable logfile (a `segno.log` left
  /// root-owned by an earlier run, a read-only `/data`) must degrade to the
  /// stderr mirror, never abort the boot that [init] sits at the front of.
  /// [_write] retries the open, so a transient cause recovers by itself.
  static void _open() {
    final dir = _directory;
    if (dir == null) return;
    try {
      final file = File('${dir.path}/$fileName');
      _bytes = file.existsSync() ? file.lengthSync() : 0;
      _handle = file.openSync(mode: FileMode.append);
    } on Object {
      _handle = null;
      _bytes = 0;
    }
  }

  static void _write(
    String level,
    String message, {
    Object? error,
    StackTrace? stack,
  }) {
    final stamp = DateTime.now().toUtc().toIso8601String();
    final logLevel = switch (level) {
      'E' => 1000,
      'W' => 900,
      _ => 800,
    };
    final payload =
        (StringBuffer('$stamp $level $message\n')
              ..write(error == null ? '' : '$error\n')
              ..write(stack == null ? '' : '$stack\n'))
            .toString();
    developer.log(message, name: 'segno', level: logLevel);
    // Intentional journal/stderr mirror for the appliance, as ONE write.
    stderr.write(payload);

    if (!_initialized) return;
    // A handle lost to a failed open or a failed rotation is retried here
    // rather than disabling the logfile for the life of the process — on the
    // appliance it is the only post-mortem there is.
    if (_handle == null) _open();
    if (_handle == null) return;
    try {
      // Encoded once and written as bytes: the size check then costs nothing
      // beyond the encoding the write needs anyway.
      final bytes = utf8.encode(payload);
      if (_bytes + bytes.length >= maxBytes) _rotateSync();
      final handle = _handle;
      if (handle == null) return;
      handle.writeFromSync(bytes);
      _bytes += bytes.length;
      if (level == 'E') {
        handle.flushSync();
        _flushCount++;
      }
    } on Object {
      // Never let logging take down the app.
    }
  }

  /// `segno.log` → `.1` → `.2` (drop oldest), then reopen a fresh active file.
  ///
  /// Closes the handle FIRST: an open handle blocks the rename on Windows, and
  /// closing is also what guarantees the file about to become `.1` holds every
  /// line written to it. The reopen is in a `finally`, so a rename that throws
  /// (a root-owned `.1`, a read-only mount) costs one rotation rather than
  /// every line for the rest of the process — and the caller's own line still
  /// lands, since the rotation is part of its write, not instead of it.
  static void _rotateSync() {
    final dir = _directory;
    if (dir == null) return;
    final handle = _handle;
    _handle = null;
    _bytes = 0;
    try {
      handle?.closeSync();
      final oldest = File('${dir.path}/$fileName.$rotatedCount');
      if (oldest.existsSync()) oldest.deleteSync();
      for (var i = rotatedCount - 1; i >= 1; i--) {
        final from = File('${dir.path}/$fileName.$i');
        if (from.existsSync()) {
          from.renameSync('${dir.path}/$fileName.${i + 1}');
        }
      }
      final current = File('${dir.path}/$fileName');
      if (current.existsSync()) {
        current.renameSync('${dir.path}/$fileName.1');
      }
    } on Object {
      // A logfile that cannot rotate is still a logfile.
    } finally {
      _open();
    }
  }
}
