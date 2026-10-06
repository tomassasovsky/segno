/// The settings tray's open sheet, which holds the tuner.
///
/// `TrayPanel` and the metrics the shell shares with it are all that leave
/// this folder.
library;

export 'tray_metrics.dart'
    show
        kTrayHandleHeight,
        kTrayHandlePill,
        kTrayMotion,
        kTrayMotionCurve,
        kTraySheetRadius;
export 'tray_panel.dart' show TrayPanel;
