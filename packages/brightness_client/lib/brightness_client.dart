/// Data client for appliance display brightness (`segno-brightness-ctl`) and
/// the outputs the app's screens are drawn on.
library;

export 'src/brightness_client.dart'
    show BrightnessClient, UnsupportedBrightnessClient;
export 'src/display_outputs.dart'
    show
        DisplayOutputs,
        SystemDisplayOutputs,
        UnknownDisplayOutputs,
        createDisplayOutputs,
        parseHomescreenScreenConnectors;
export 'src/system_brightness_client.dart'
    show SystemBrightnessClient, createBrightnessClient;
