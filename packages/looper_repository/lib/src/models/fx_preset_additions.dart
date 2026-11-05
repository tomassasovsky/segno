import 'package:fx_catalogue/fx_catalogue.dart';

/// What segno adds to the Looper X's factory presets when it builds them, by
/// family, then by preset name: parameters the source files do not carry.
/// The catalogue keeps the source's values untouched; these apply where a
/// preset becomes a rack (`fxRackEntries`). Each is a departure from the
/// Looper X catalogue, made by the owner's decision.
///
/// The Guitar Rack opens with a High-pass gate (#1644). The Looper X's Guitar
/// Rack has none, so its drive presets lift an idle input's floor by 23 to
/// 41 dB (white noise at -90 dBFS) and play it as hiss. The gate is on in
/// every preset that lifts that floor by about 25 dB or more, and off, but
/// in the rack, in the rest. Its threshold, -70.5 dBFS on the input's RMS,
/// closes on a floor up to -80 dBFS RMS (the gate shuts 6 dB under it, at
/// -76.5) and opens on the softest pick; its high-pass stays off, so the
/// open gate passes the guitar untouched.
const Map<String, Map<String, Map<String, double>>> kFxPresetAdditions = {
  'Guitar Rack': {
    'Clean Rhythm': _guitarGateOff,
    'Clean Soft Chords': _guitarGateOff,
    'Full Drive': _guitarGateOn,
    'Full Drive Power': _guitarGateOn,
    'Lead Crunch': _guitarGateOn,
    'Lead Dirty': _guitarGateOn,
    'Lead Wet': _guitarGateOn,
    'Rhythm Amped': _guitarGateOff,
    'Rhythm Atmos': _guitarGateOff,
    'Rhythm Chorus': _guitarGateOff,
    'Rhythm Dirty': _guitarGateOn,
    'Rhythm Half Dirty': _guitarGateOff,
    'Rhythm Power Chor': _guitarGateOn,
    'Rhythm Wet+Dirty': _guitarGateOn,
  },
};

/// The Guitar Rack's gate threshold as a preset stores it: -70.5 dB on the
/// gate's -120..0 dB scale.
const double kFxGuitarGateThreshold = 49.5 / 120;

const Map<String, double> _guitarGateOn = {
  'HP/Gate': 1,
  'Highpass': 0,
  'Gate Thresh': kFxGuitarGateThreshold,
};

const Map<String, double> _guitarGateOff = {
  'HP/Gate': 0,
  'Highpass': 0,
  'Gate Thresh': kFxGuitarGateThreshold,
};

/// [preset] with segno's additions for it ([kFxPresetAdditions]); [preset]
/// itself when it has none. A key the source already carries keeps the
/// source's value.
FxPreset fxWithAdditions(FxPreset preset) {
  final added = kFxPresetAdditions[preset.family]?[preset.name];
  if (added == null) return preset;
  return FxPreset(
    family: preset.family,
    name: preset.name,
    id: preset.id,
    type: preset.type,
    version: preset.version,
    params: {...added, ...preset.params},
  );
}
