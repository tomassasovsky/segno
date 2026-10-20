/// Data client for appliance touch calibration (`segno-touch-ctl`): the
/// libinput matrix per screen, and the fit that measures one.
library;

export 'src/system_touch_calibration_client.dart'
    show SystemTouchCalibrationClient, createTouchCalibrationClient;
export 'src/touch_calibration_client.dart'
    show TouchCalibrationClient, TouchScreen, UnsupportedTouchCalibrationClient;
export 'src/touch_matrix.dart' show TouchMatrix, TouchPoint, fitTouchMatrix;
