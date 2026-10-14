import 'package:touch_calibration_client/touch_calibration_client.dart';

/// A calibration store that remembers each call.
class FakeTouchCalibrationClient implements TouchCalibrationClient {
  FakeTouchCalibrationClient({this.stored});

  TouchMatrix? stored;
  final calls = <String>[];
  bool failWrites = false;

  @override
  Future<bool> isSupported() async => true;

  @override
  Future<TouchMatrix?> read(TouchScreen screen) async {
    calls.add('read ${screen.name}');
    return stored;
  }

  @override
  Future<void> write(TouchScreen screen, TouchMatrix matrix) async {
    calls.add('write ${screen.name}');
    if (failWrites) throw StateError('read-only');
    stored = matrix;
  }

  @override
  Future<void> reset(TouchScreen screen) async {
    calls.add('reset ${screen.name}');
    stored = null;
  }
}
