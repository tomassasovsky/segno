import 'package:fx_catalogue/fx_catalogue.dart';

/// What segno adds to the Looper X's factory presets when it builds them:
/// parameters the source files do not carry. The catalogue keeps the
/// source's values untouched; these apply where a preset becomes a rack
/// (`fxRackEntries`). Each is a departure from the Looper X catalogue, made
/// by the owner's decision.
///
/// The Guitar Rack opens with a High-pass gate (#1644). The Looper X's Guitar
/// Rack has none, so its drive presets lift an idle input's floor by 23 to
/// 41 dB (white noise at -90 dBFS) and play it as hiss. Every Guitar Rack
/// preset gets the gate; it is on in [kFxGuitarGateOn], the presets that
/// lift that floor by about 25 dB or more, and off, but in the rack, in the
/// rest. Its threshold, -70.5 dBFS on the input's RMS, closes on a floor up
/// to -80 dBFS RMS (the gate shuts 6 dB under it, at -76.5) and opens on a
/// soft pick; its high-pass stays off, so the open gate passes the guitar
/// untouched.
FxPreset fxWithAdditions(FxPreset preset) {
  if (preset.family != 'Guitar Rack') return preset;
  final added = {
    'HP/Gate': kFxGuitarGateOn.contains(preset.name) ? 1.0 : 0.0,
    'Highpass': 0.0,
    'Gate Thresh': kFxGuitarGateThreshold,
  };
  return FxPreset(
    family: preset.family,
    name: preset.name,
    id: preset.id,
    type: preset.type,
    version: preset.version,
    // A key the source already carries keeps the source's value.
    params: {...added, ...preset.params},
  );
}

/// The Guitar Rack presets whose gate is on: the ones that lift a -90 dBFS
/// floor by about 25 dB or more (segno's engine, white noise).
const Set<String> kFxGuitarGateOn = {
  'Full Drive',
  'Full Drive Power',
  'Lead Crunch',
  'Lead Dirty',
  'Lead Wet',
  'Rhythm Dirty',
  'Rhythm Power Chor',
  'Rhythm Wet+Dirty',
};

/// The Guitar Rack's gate threshold as a preset stores it: -70.5 dB on the
/// gate's -120..0 dB scale.
const double kFxGuitarGateThreshold = 49.5 / 120;
