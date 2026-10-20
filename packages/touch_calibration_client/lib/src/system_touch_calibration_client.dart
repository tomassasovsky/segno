import 'dart:convert';
import 'dart:io';

import 'package:spawn_process/spawn_process.dart';
import 'package:touch_calibration_client/src/touch_calibration_client.dart';
import 'package:touch_calibration_client/src/touch_matrix.dart';

/// Production [TouchCalibrationClient]: shells out to
/// `/usr/bin/segno-touch-ctl`.
class SystemTouchCalibrationClient implements TouchCalibrationClient {
  /// Creates a [SystemTouchCalibrationClient].
  const SystemTouchCalibrationClient({
    this.helperPath = '/usr/bin/segno-touch-ctl',
    this.readTimeout = const Duration(seconds: 20),
    this.changeTimeout = const Duration(seconds: 60),
  });

  /// Path to the calibration helper.
  final String helperPath;

  /// How long [read] may take. A `get` changes nothing, so a helper still
  /// running then is killed.
  final Duration readTimeout;

  /// How long [apply], [write] and [restore] may take before they throw a
  /// `TimeoutException`. Each re-adds the touchscreen: a udev `remove`, then
  /// an `add`, each followed by a settle of up to 5 s. A helper killed
  /// between the two would leave the panel without touch until a reboot, so
  /// a helper still running then is not killed: it finishes on its own, and
  /// the call reports the delay.
  final Duration changeTimeout;

  @override
  Future<bool> isSupported() async => File(helperPath).existsSync();

  @override
  Future<TouchMatrix?> read(TouchScreen screen) async {
    final json = await _runJson(['get', screen.name], readTimeout);
    if (json is! Map || json['calibrated'] != true) return null;
    final matrix = json['matrix'];
    return matrix is String ? TouchMatrix.tryParse(matrix) : null;
  }

  @override
  Future<void> apply(TouchScreen screen, TouchMatrix matrix) async {
    await _change(['try', screen.name, ...matrix.toArgument().split(' ')]);
  }

  @override
  Future<void> write(TouchScreen screen, TouchMatrix matrix) async {
    await _change(['set', screen.name, ...matrix.toArgument().split(' ')]);
  }

  @override
  Future<void> restore(TouchScreen screen) async {
    await _change(['restore', screen.name]);
  }

  Future<Object?> _runJson(List<String> args, Duration timeout) async {
    final result = await _run(args, timeout: timeout);
    final text = result.stdout.toString().trim();
    if (text.isEmpty) return null;
    return jsonDecode(text);
  }

  /// Runs a verb that re-adds a touchscreen; see [changeTimeout].
  Future<void> _change(List<String> args) =>
      _run(args, timeout: changeTimeout, killOnTimeout: false);

  Future<ProcessResult> _run(
    List<String> args, {
    required Duration timeout,
    bool killOnTimeout = true,
  }) async {
    final result = await runProcess(
      helperPath,
      args,
      timeout: timeout,
      killOnTimeout: killOnTimeout,
    );
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
