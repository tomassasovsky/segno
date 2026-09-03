// coverage:ignore-file
// The one file in this package that touches a device node. Its logic is
// three calls into dart:io; the codec it feeds is covered by the parser tests.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:pedal_repository/src/pedal_link.dart';
import 'package:pedal_repository/src/pedal_link_codec.dart';
import 'package:pedal_repository/src/pedal_link_message.dart';

/// Where the console board's link lands on the appliance: the Pi 5's uart3
/// (GPIO8/9, `dtoverlay=uart3-pi5`), which the board's ribbon carries to the
/// Pico 2's UART0.
const kConsolePedalDevice = '/dev/ttyAMA3';

/// The line settings the board expects; the same on both ends.
const kConsolePedalBaud = 115200;

/// The [PedalLink] over a Linux serial device.
///
/// Opened with [UartPedalLink.open], which configures the line with `stty`
/// (raw, 8N1, no echo — echo would loop the board's own bytes back at it) and
/// then reads and writes the device node as a plain file. Bytes in go through
/// a [PedalLinkParser]; messages out go through [PedalLinkCodec].
class UartPedalLink implements PedalLink {
  UartPedalLink._(this._path, this._writer, Stream<List<int>> bytes) {
    _bytesSub = bytes.listen(
      (chunk) => _parser.push(chunk).forEach(_inbound.add),
      onError: (Object error, StackTrace stack) {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stack,
            library: 'pedal_repository',
            context: ErrorDescription('reading the pedal link $_path'),
          ),
        );
      },
    );
  }

  /// Opens [path], or returns `null` when it does not exist or cannot be
  /// configured — a desktop build, or an appliance whose overlay is missing.
  /// Absence is not an error: the looper runs with the on-screen pedal alone.
  static Future<UartPedalLink?> open({
    String path = kConsolePedalDevice,
    int baud = kConsolePedalBaud,
  }) async {
    final file = File(path);
    if (!file.existsSync()) return null;
    try {
      final stty = await Process.run('stty', [
        '-F',
        path,
        '$baud',
        'cs8',
        '-parenb',
        '-cstopb',
        'raw',
        '-echo',
        '-crtscts',
        'min',
        '1',
        'time',
        '0',
      ]);
      if (stty.exitCode != 0) {
        debugPrint('pedal link: stty failed on $path: ${stty.stderr}');
        return null;
      }
      final writer = file.openSync(mode: FileMode.writeOnlyAppend);
      return UartPedalLink._(path, writer, file.openRead());
    } on Object catch (error, stack) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'pedal_repository',
          context: ErrorDescription('opening the pedal link $path'),
        ),
      );
      return null;
    }
  }

  final String _path;
  final RandomAccessFile _writer;
  final PedalLinkParser _parser = PedalLinkParser();
  final StreamController<PedalLinkMessage> _inbound =
      StreamController<PedalLinkMessage>.broadcast();
  late final StreamSubscription<List<int>> _bytesSub;
  bool _disposed = false;

  /// The device this link is open on.
  String get path => _path;

  @override
  Stream<PedalLinkMessage> get inbound => _inbound.stream;

  @override
  void send(PedalLinkMessage message) {
    if (_disposed) return;
    final bytes = PedalLinkCodec.encode(message);
    try {
      _writer.writeFromSync(bytes);
    } on FileSystemException catch (error) {
      debugPrint('pedal link: write to $_path failed: $error');
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _bytesSub.cancel();
    await _inbound.close();
    _writer.closeSync();
  }
}
