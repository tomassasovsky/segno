/// Reads Ableton Live device presets from the user's own library.
///
/// `AbletonPresetReader` reads one `.adv` or `.adg` into an `AbletonPreset`
/// (the device, every parameter's stored value and range, and what it could
/// not read). A `DeviceSchema` such as `DriftSchema` types those values,
/// and `PresetLibrary.scan` lists a folder's presets by device and Live's
/// folder names. No Ableton presets or data are part of this package.
library;

export 'src/ableton_preset.dart';
export 'src/device_schema.dart';
export 'src/drift_schema.dart';
export 'src/preset_library.dart';
export 'src/preset_reader.dart';
