import 'dart:convert';
import 'dart:io';

import 'package:touch_calibration_client/src/touch_calibration_client.dart';
import 'package:touch_calibration_client/src/touch_matrix.dart';

/// Production [TouchCalibrationClient]: shells out to
/// `/usr/bin/segno-touch-ctl`.
class SystemTouchCalibrationClient implements TouchCalibrationClient {
  /// Creates a [SystemTouchCalibrationClient].
  const SystemTouchCalibrationClient({
    this.helperPath = '/usr/bin/segno-touch-ctl',
  });

  /// Path to the calibration helper.
  final String helperPath;

  /// How long one helper call may take. A write re-adds the touchscreen and
  /// waits for udev to settle, which takes well under a second; a wedged udev
  /// must not hold the calibration page for ever.
  static const timeout = Duration(seconds: 20);

  @override
  Future<bool> isSupported() async => File(helperPath).existsSync();

  @override
  Future<TouchMatrix?> read(TouchScreen screen) async {
    final json = await _runJson(['get', screen.name]);
    if (json is! Map || json['calibrated'] != true) return null;
    final matrix = json['matrix'];
    return matrix is String ? TouchMatrix.tryParse(matrix) : null;
  }

  @override
  Future<void> apply(TouchScreen screen, TouchMatrix matrix) async {
    await _run(['try', screen.name, ...matrix.toArgument().split(' ')]);
  }

  @override
  Future<void> write(TouchScreen screen, TouchMatrix matrix) async {
    await _run(['set', screen.name, ...matrix.toArgument().split(' ')]);
  }

  @override
  Future<void> restore(TouchScreen screen) async {
    await _run(['restore', screen.name]);
  }

  Future<Object?> _runJson(List<String> args) async {
    final result = await _run(args);
    final text = result.stdout.toString().trim();
    if (text.isEmpty) return null;
    return jsonDecode(text);
  }

  Future<ProcessResult> _run(List<String> args) async {
    final result = await Process.run(helperPath, args).timeout(timeout);
    if (result.exitCode != 0) {
      throw ProcessException(
        helperPath,
        args,
        '${result.stderr}'.trim().isEmpty
            ? 'touch calibration helper failed'
            : '${result.stderr}'.trim(),
        result.exitCode,
      );
    }
    return result;
  }
}

/// Factory: the real helper on Linux when present, else unsupported.
TouchCalibrationClient createTouchCalibrationClient() {
  if (!Platform.isLinux) return const UnsupportedTouchCalibrationClient();
  const system = SystemTouchCalibrationClient();
  if (!File(system.helperPath).existsSync()) {
    return const UnsupportedTouchCalibrationClient();
  }
  return system;
}
