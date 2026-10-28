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

  /// The card illustration the family chooser draws. Ed's Rack's is the
  /// wide banner its card is drawn at.
  String get selectorAsset => 'assets/images/selector/$slug.png';

  /// The footswitch illustration.
  String get footswitchAsset => fxFootswitchAsset(slug);
}

/// Factory footswitch artwork for one catalogue slug.
String fxFootswitchAsset(String slug) => 'assets/images/footswitch/$slug.png';

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
