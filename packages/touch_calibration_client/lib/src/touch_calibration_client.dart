import 'package:touch_calibration_client/src/touch_matrix.dart';

/// The screens a touchscreen calibration belongs to: the role names the
/// embedder gives each screen (`--segno-screen=`), which is also how
/// `segno-touch-ctl` tells the two touchscreens apart.
enum TouchScreen {
  /// The main panel.
  main,

  /// The 7" readout (the Track display).
  readout,
}

/// Reads and writes each screen's touch calibration.
abstract interface class TouchCalibrationClient {
  /// Whether this device can calibrate touch at all.
  Future<bool> isSupported();

  /// The calibration in force on [screen]; `null` when none is set and
  /// libinput uses the identity.
  Future<TouchMatrix?> read(TouchScreen screen);

  /// Applies [matrix] to [screen]'s touchscreen now without storing it: a
  /// reboot, or [restore], puts the stored calibration back.
  Future<void> apply(TouchScreen screen, TouchMatrix matrix);

  /// Stores [matrix] for [screen] and applies it to that touchscreen now.
  Future<void> write(TouchScreen screen, TouchMatrix matrix);

  /// Applies [screen]'s stored calibration again, dropping one [apply]-ed.
  Future<void> restore(TouchScreen screen);
}

/// No touch calibration: the macOS dev host.
class UnsupportedTouchCalibrationClient implements TouchCalibrationClient {
  /// Creates an [UnsupportedTouchCalibrationClient].
  const UnsupportedTouchCalibrationClient();

  @override
  Future<bool> isSupported() async => false;

  @override
  Future<TouchMatrix?> read(TouchScreen screen) async => null;

  @override
  Future<void> apply(TouchScreen screen, TouchMatrix matrix) async {}

  @override
  Future<void> write(TouchScreen screen, TouchMatrix matrix) async {}

  @override
  Future<void> restore(TouchScreen screen) async {}
}
