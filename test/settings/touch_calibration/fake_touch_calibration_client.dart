import 'dart:async';

import 'package:touch_calibration_client/touch_calibration_client.dart';

/// A calibration helper that remembers each call, and tells the calibration
/// on /data ([stored]) apart from the one the touchscreen uses ([inForce]).
class FakeTouchCalibrationClient implements TouchCalibrationClient {
  new({this.stored}) : inForce = stored;

  /// What a reboot would put back.
  TouchMatrix? stored;

  /// What the touchscreen uses now.
  TouchMatrix? inForce;

  final calls = <String>[];
  bool failRead = false;
  bool failApply = false;
  bool failWrite = false;
  bool failRestore = false;

  /// When set, a read waits for it before it answers.
  Completer<void>? readGate;

  /// When set, an apply waits for it before it takes effect.
  Completer<void>? applyGate;

  /// When set, a write waits for it before it takes effect.
  Completer<void>? writeGate;

  /// When set, a restore waits for it before it takes effect.
  Completer<void>? restoreGate;

  @override
  Future<bool> isSupported() async => true;

  @override
  Future<TouchMatrix?> read(TouchScreen screen) async {
    calls.add('read ${screen.name}');
    await readGate?.future;
    if (failRead) throw StateError('udev is wedged');
    return stored;
  }

  @override
  Future<void> apply(TouchScreen screen, TouchMatrix matrix) async {
    calls.add('apply ${screen.name}');
    await applyGate?.future;
    if (failApply) throw StateError('udev is wedged');
    inForce = matrix;
  }

  @override
  Future<void> write(TouchScreen screen, TouchMatrix matrix) async {
    calls.add('write ${screen.name}');
    await writeGate?.future;
    if (failWrite) throw StateError('read-only');
    stored = inForce = matrix;
  }

  @override
  Future<void> restore(TouchScreen screen) async {
    calls.add('restore ${screen.name}');
    await restoreGate?.future;
    if (failRestore) throw StateError('udev is wedged');
    inForce = stored;
  }
}
