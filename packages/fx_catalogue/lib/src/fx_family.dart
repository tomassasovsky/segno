import 'package:fx_catalogue/src/fx_preset.dart';

/// One rack family in the factory catalogue: its name, its artwork and the
/// presets filed under it.
class FxFamily {
  /// Creates an [FxFamily].
  const FxFamily({
    required this.name,
    required this.slug,
    required this.presets,
  });

  /// The family's name, which is the folder the presets are filed under.
  final String name;

  /// The artwork slug for this family. The source names its images
  /// independently of the folders (`edsguitar` for `Ed's Rack`), so the two
  /// are mapped explicitly rather than derived — a derivation would have to
  /// guess, and would be wrong on more than one of them.
  final String slug;

  /// The family's presets, in name order.
  final List<FxPreset> presets;

  /// The wide banner the library draws this family with.
  String get stripAsset => 'assets/images/strip/$slug.png';

  /// The square illustration the family chooser draws.
  String get selectorAsset => 'assets/images/selector/$slug.png';

  /// The footswitch illustration.
  String get footswitchAsset => 'assets/images/footswitch/$slug.png';
}

/// Each family's artwork slug, by folder name.
///
/// Explicit because the source's folder names and its image names do not
/// follow one rule: `Ed's Rack` is `edsguitar`, `Lo-Fi Rack` is `lo-fi` and
/// `Vocal Tuner Rack` is `vocaltuner`. A slugging function would get at least
/// the first of those wrong and silently draw the wrong rack.
const Map<String, String> kFxFamilySlugs = {
  'Drum Rack': 'drum',
  'Dub Rack': 'dub',
  "Ed's Rack": 'edsguitar',
  'Guitar Rack': 'guitar',
  'Lo-Fi Rack': 'lo-fi',
  'Rhythmic Rack': 'rhythmic',
  'Studio Rack': 'studio',
  'Vocal Rack': 'vocal',
  'Vocal Tuner Rack': 'vocaltuner',
};

/// The illustration for the standalone single-effect entry, which has no
/// family of its own.
const String kFxSingleSelectorAsset = 'assets/images/selector/singlefx.png';

/// The pedal illustration for a module named [module], or `null` when the
/// catalogue carries none.
///
/// The source files an illustration per pedal IDENTITY (`Delay3`, `Reverb5`),
/// not per module-name prefix, so this resolves only what [kFxStompAssets]
/// actually names.
String? fxStompAsset(String module) =>
    kFxStompAssets.contains(module) ? 'assets/images/stomps/$module.png' : null;

/// Every pedal illustration the catalogue carries, by its source name.
///
/// The set is the source's own inventory, not a list of effects this engine
/// can build: an entry here means an image exists, nothing more.
const Set<String> kFxStompAssets = {
  'AmbiVerb2',
  'Amp4',
  'Chorus3',
  'Compressor2',
  'Compressor3',
  'Compressor4',
  'Degrade3',
  'Delay3',
  'Delay4',
  'Delay6',
  'Distort1',
  'Distort2',
  'Doubler1',
  'Doubler2',
  'DubVerb2',
  'EQ3',
  'EQ4',
  'EQ5',
  'EQ8',
  'HPFGate2',
  'Harmonise20',
  'LPF2',
  'LPF4',
  'Mod3',
  'Octaver3',
  'Overdrive2',
  'PitchShift2',
  'Pumper2',
  'Reverb2',
  'Reverb3',
  'Reverb5',
  'Slicer2',
  'SmartTune2',
  'SpringRev2',
  'Transient3',
  'Vinyl4',
  'Wah1',
  'Wham2',
};
