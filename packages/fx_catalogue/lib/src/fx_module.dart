import 'package:fx_catalogue/src/fx_family.dart';
import 'package:fx_catalogue/src/fx_preset.dart';

/// One pedal a factory rack can hold: how the source spells its power, which
/// parameter groups belong to it, and which illustrations the catalogue
/// carries for it.
///
/// **This table is a READING of the data, not something recovered from it.**
/// A preset is a flat map of parameter names to values; it never says which
/// modules it holds. Three vocabularies in the source disagree about how to
/// name the same pedal — the power key (`Compressor`), the parameter prefix
/// (`Comp Ratio`) and the artwork (`Compressor2`) — so the correspondence has
/// to be written down rather than derived. The accepted design says as much:
/// the study's grouping was a design proposal, not a recovered signal chain.
///
/// What IS checked against the data, by test: every [enables] key appears in
/// the catalogue and is binary everywhere it appears, every [groups] prefix
/// appears, every [artwork] name is a file that exists, and no two modules
/// claim the same key or group.
class FxModule {
  /// Creates an [FxModule].
  const FxModule({
    required this.name,
    required this.enables,
    required this.groups,
    required this.artwork,
    this.shared = const [],
    this.families,
  });

  /// The pedal's display name.
  final String name;

  /// The keys the source uses for this module's POWER, any one of which may
  /// appear in a given preset.
  ///
  /// More than one because the source is not consistent: the EQ is `EQ` in
  /// some presets and `EQ 4-Band` in others, and the compressor is `Comp` in
  /// some families and `Compressor` in another. Each is binary wherever it
  /// appears, which is the property the test pins.
  final List<String> enables;

  /// The parameter-name prefixes that belong to this module.
  ///
  /// Usually one, occasionally several, and almost never the same word as the
  /// power key: `Delay` enables `Del *`, `Reverb` enables `Rev *`, `OvDrive`
  /// enables `OD *`.
  final List<String> groups;

  /// The illustrations the catalogue carries for this pedal, lowest variant
  /// first.
  ///
  /// Several because the source ships numbered variants (`Delay3`, `Delay4`,
  /// `Delay6`) and nothing in the preset data says which variant a given
  /// family used. The first is what a surface draws; the rest are recorded so
  /// the gap stays visible rather than looking like a choice.
  final List<String> artwork;

  /// Whole parameter names this module reads although another module of the
  /// same rack reads them too.
  ///
  /// The Vocal Tuner's Smart Tune and Harmonizer both read the tuning mode,
  /// the source that drives them, the key and the scale type: presets with
  /// Smart Tune off still set them for the Harmonizer ("Midi Harm" sets Auto
  /// Source to 1, "Scale Harm" sets Mode to 1 and Key to 3/11). A prefix group
  /// cannot say that, because it gives each key to one module.
  final List<String> shared;

  /// The rack families this module appears in, or `null` for every family.
  ///
  /// Needed where two racks use the same parameter prefix for different
  /// pedals: the `Del` parameters are the Dub delay's in the Dub Rack and the
  /// Delay's everywhere else, and the `EQ` parameters are the parametric EQ's
  /// in the Dub and Lo-Fi racks and the four-band EQ's everywhere else.
  final Set<String>? families;

  /// Whether [key] is this module's power key.
  bool poweredBy(String key) => enables.contains(key);

  /// Whether the parameter [key] belongs to this module.
  bool owns(String key) {
    if (shared.contains(key)) return true;
    final prefix = key.split(' ').first;
    return groups.contains(prefix);
  }

  /// Whether this module can appear in a rack of [family].
  bool appearsIn(String family) => families?.contains(family) ?? true;
}

const Set<String> _paraEqFamilies = {
  'Dub Rack',
  'Lo-Fi Rack',
  'Rhythmic Rack',
};

const Set<String> _fourBandEqFamilies = {
  'Drum Rack',
  "Ed's Rack",
  'Guitar Rack',
  'Studio Rack',
  'Vocal Rack',
  'Vocal Tuner Rack',
};

const Set<String> _dubDelayFamilies = {'Dub Rack'};

const Set<String> _delayFamilies = {
  'Drum Rack',
  "Ed's Rack",
  'Guitar Rack',
  'Lo-Fi Rack',
  'Rhythmic Rack',
  'Studio Rack',
  'Vocal Rack',
  'Vocal Tuner Rack',
};

const Set<String> _vocalTunerFamilies = {'Vocal Tuner Rack'};

/// The Vocal Tuner parameters that both Smart Tune and the Harmonizer read.
const List<String> _vocalTunerShared = [
  'Mode',
  'Auto Source',
  'Key',
  'Scale Type',
];

/// Every module the factory catalogue names, with the evidence for each.
///
/// The table's own order is not a processing order. A rack builds its entries
/// in the order [kFxRackOrders] gives its family.
const List<FxModule> kFxModules = [
  FxModule(
    name: 'Amp',
    enables: ['Amp'],
    // `Cab` is a value of the amp, not a module: it is space-free like a
    // power key but continuous, so it is a parameter that happens to be
    // spelled without one.
    groups: ['Amp', 'Cab'],
    artwork: ['Amp4'],
  ),
  FxModule(
    name: 'Compressor',
    enables: ['Comp', 'Compressor'],
    groups: ['Comp'],
    artwork: ['Compressor2', 'Compressor3', 'Compressor4'],
  ),
  FxModule(
    name: 'Overdrive',
    enables: ['OvDrive'],
    groups: ['OD'],
    artwork: ['Overdrive2'],
  ),
  FxModule(
    name: 'Distortion',
    enables: ['Dist', 'Distort'],
    groups: ['Dist'],
    artwork: ['Distort1', 'Distort2'],
  ),
  FxModule(
    name: 'Four-band EQ',
    enables: ['EQ', 'EQ 4-Band'],
    groups: ['EQ'],
    artwork: ['EQ3', 'EQ4', 'EQ5', 'EQ8'],
    families: _fourBandEqFamilies,
  ),
  FxModule(
    name: 'Parametric EQ',
    // The Dub and Lo-Fi racks power their EQ with `Para EQ` and give it the
    // same `EQ` prefix the four-band EQ uses elsewhere. The Rhythmic Rack
    // powers its EQ with `EQ`, the four-band EQ's power key, but its controls
    // are the parametric EQ's (EQ Low Cut, EQ High Cut, EQ Mid Freq, EQ Mid
    // Gain) without the Q, and it shares no control with any four-band EQ.
    // The controls are what the pedal is, so it is this module.
    enables: ['Para EQ', 'EQ'],
    groups: ['EQ'],
    // The binary's single-effect artwork list runs in effect-name order and
    // puts EQ5 between Overdrive2 and PitchShift2, where Parametric EQ falls.
    artwork: ['EQ5'],
    families: _paraEqFamilies,
  ),
  FxModule(
    name: 'Low-pass filter',
    enables: ['LPF'],
    groups: ['LPF'],
    artwork: ['LPF2', 'LPF4'],
  ),
  FxModule(
    name: 'Wah',
    enables: ['Wah'],
    groups: ['Wah'],
    artwork: ['Wah1'],
  ),
  FxModule(
    name: 'Chorus',
    enables: ['Chor'],
    groups: ['Chor'],
    artwork: ['Chorus3'],
  ),
  FxModule(
    name: 'Modulation',
    enables: ['Mod'],
    groups: ['Mod'],
    artwork: ['Mod3'],
  ),
  FxModule(
    name: 'Octaver',
    enables: ['Oct'],
    groups: ['Oct', 'Octave'],
    artwork: ['Octaver3'],
  ),
  FxModule(
    name: 'Pitch shift',
    enables: ['Pitch'],
    groups: ['Pitch'],
    artwork: ['PitchShift2'],
  ),
  FxModule(
    name: 'Whammy',
    enables: ['Whammy'],
    groups: ['Whammy'],
    artwork: ['Wham2'],
  ),
  FxModule(
    name: 'Delay',
    enables: ['Delay'],
    groups: ['Del'],
    artwork: ['Delay3', 'Delay4', 'Delay6'],
    families: _delayFamilies,
  ),
  FxModule(
    name: 'Dub delay',
    // The Dub Rack powers its delay with `Dub Delay` and gives it the same
    // `Del` prefix the plain delay uses elsewhere.
    enables: ['Dub Delay'],
    groups: ['Del'],
    // The binary's single-effect artwork list runs in effect-name order and
    // puts Delay6 between Doubler1 and the four-band EQ, where Dub Delay
    // falls.
    artwork: ['Delay6'],
    families: _dubDelayFamilies,
  ),
  FxModule(
    name: 'Reverb',
    enables: ['Reverb'],
    groups: ['Rev'],
    artwork: ['Reverb2', 'Reverb3', 'Reverb5'],
  ),
  FxModule(
    name: 'Spring reverb',
    enables: ['Spring'],
    groups: ['Spring'],
    artwork: ['SpringRev2'],
  ),
  FxModule(
    name: 'Ambience',
    // The source spells the group three ways across the Dub Rack, including
    // one that differs only in case.
    enables: ['Amb-Verb'],
    groups: ['Amb-Verb', 'Amb-verb', 'Amb-Dub'],
    artwork: ['AmbiVerb2'],
  ),
  FxModule(
    name: 'Dub reverb',
    enables: ['Dub-Verb'],
    groups: ['Dub-Verb'],
    artwork: ['DubVerb2'],
  ),
  FxModule(
    name: 'Doubler',
    enables: ['Doubler'],
    groups: ['Doubler'],
    artwork: ['Doubler1', 'Doubler2'],
  ),
  FxModule(
    name: 'High-pass gate',
    // Two power keys that are not alternatives of one another: `HP/Gate` is
    // the module's own, and `Highpass` reads as its frequency. Both are here
    // because both are space-free, and the test pins only the binary one.
    enables: ['HP/Gate'],
    groups: ['Gate', 'Highpass'],
    artwork: ['HPFGate2'],
  ),
  FxModule(
    name: 'Transient',
    enables: ['Transient'],
    groups: ['Attack', 'Sustain'],
    artwork: ['Transient3'],
  ),
  FxModule(
    name: 'Pumper',
    enables: ['Pumper'],
    groups: ['Pumper'],
    artwork: ['Pumper2'],
  ),
  FxModule(
    name: 'Slicer',
    enables: ['Slicer'],
    groups: ['Slic'],
    artwork: ['Slicer2'],
  ),
  FxModule(
    name: 'Vinyl',
    enables: ['Vinyl'],
    groups: ['Vinyl'],
    artwork: ['Vinyl4'],
  ),
  FxModule(
    name: 'Degrade',
    enables: ['Degrade'],
    groups: ['Degrade'],
    artwork: ['Degrade3'],
  ),
  FxModule(
    name: 'Harmonizer',
    enables: ['Harmonize'],
    groups: ['Harm', 'Voice', 'Lead', 'Low', 'Mid', 'High', 'Scale'],
    shared: _vocalTunerShared,
    artwork: ['Harmonise20'],
    families: _vocalTunerFamilies,
  ),
  FxModule(
    name: 'Smart tune',
    enables: ['Smart Tune'],
    groups: [
      'Audio',
      'Reference',
      'Speed',
      'Stereo',
      'Tightness',
      'Tracking',
    ],
    shared: _vocalTunerShared,
    artwork: ['SmartTune2'],
    families: _vocalTunerFamilies,
  ),
];

/// Parameter groups the table deliberately claims for no module.
///
/// `Master` is the rack's own output level, which the accepted design puts
/// AFTER the pedals and gives to the rack rather than to any of them.
const Set<String> kFxUnclaimedGroups = {'Master'};

/// The order each factory rack runs its modules in, first to last, by
/// [FxModule.name]. The rack's own level (`Master Vol`, see
/// [kFxUnclaimedGroups]) comes after the last of them in every rack.
///
/// Measured on the Looper X in the #891 rig and recorded under "Chain order"
/// in `docs/plan/2026-10-20-looperx-derived-tables.md`: each rack's processor
/// runs a fixed array of slots in index order, in series, and each list below
/// is that array read through this table's modules. The presets cannot give
/// the order, because their keys are stored alphabetically.
///
/// Where one module covers several measured slots, it stands where they do:
///
/// - Guitar's Modulation is three slots in series, Chorus, Phaser and
///   Flanger, of which Mod Mode runs one.
/// - Studio's Modulation is two slots, Chorus then Tremolo.
/// - The High-pass gate is the highpass and gate slots of the Vocal and Vocal
///   Tuner racks, which the editor shows as one HP/Gate pedal.
/// - Studio's Distortion is the processor's amp simulator, which the editor
///   labels Dist.
///
/// Ed's Rack is the one rack whose editor disagrees with its processor: the
/// editor draws Delay before Reverb, and the processor runs Reverb then
/// Delay. This table follows the processor. Both are linear, so in series the
/// order does not change the sound.
const Map<String, List<String>> kFxRackOrders = {
  'Drum Rack': [
    'Transient',
    'Delay',
    'Reverb',
    'Four-band EQ',
    'Compressor',
  ],
  'Dub Rack': [
    'Doubler',
    'Dub delay',
    // Less certain: the processor shows two reverb slots without names, so
    // Dub reverb before Ambience comes from the Dub editor's pedal order
    // alone. Both are linear, so in series the order is not audible.
    'Dub reverb',
    'Ambience',
    'Compressor',
    'Parametric EQ',
  ],
  "Ed's Rack": [
    'Octaver',
    'Wah',
    'Compressor',
    'Overdrive',
    'Amp',
    'Chorus',
    // The processor's order. The editor draws Delay first.
    'Reverb',
    'Delay',
    'Four-band EQ',
  ],
  'Guitar Rack': [
    'Whammy',
    'Overdrive',
    'Wah',
    'Amp',
    'Modulation',
    'Spring reverb',
    'Delay',
  ],
  'Lo-Fi Rack': [
    'Low-pass filter',
    'Vinyl',
    'Degrade',
    'Distortion',
    'Parametric EQ',
    'Delay',
  ],
  'Rhythmic Rack': [
    'Low-pass filter',
    'Slicer',
    'Pumper',
    'Parametric EQ',
    'Delay',
    'Reverb',
  ],
  'Studio Rack': [
    'Pitch shift',
    'Distortion',
    'Doubler',
    'Modulation',
    'Delay',
    'Reverb',
    'Compressor',
    'Four-band EQ',
  ],
  'Vocal Rack': [
    'High-pass gate',
    'Pitch shift',
    'Doubler',
    'Delay',
    'Reverb',
    'Compressor',
    'Four-band EQ',
  ],
  // The measurement places this rack's Master Vol slot by elimination. It is
  // the rack level, after every module, either way.
  'Vocal Tuner Rack': [
    'High-pass gate',
    'Smart tune',
    'Harmonizer',
    'Doubler',
    'Delay',
    'Reverb',
    'Compressor',
    'Four-band EQ',
  ],
};

/// The module of a [family] rack whose power key is [key], or `null`.
FxModule? fxModuleFor(String key, String family) {
  for (final module in kFxModules) {
    if (module.appearsIn(family) && module.poweredBy(key)) return module;
  }
  return null;
}

/// The module CALLED [name], or `null` — the lookup a persisted chain entry
/// uses to find its pedal again.
///
/// Distinct from [fxModuleFor], which resolves a source POWER key: an entry
/// stores the display name, and the two vocabularies are not the same word.
FxModule? fxModuleNamed(String name) {
  for (final module in kFxModules) {
    if (module.name == name) return module;
  }
  return null;
}

/// The illustration for the module called [name], or `null` when the
/// catalogue names none.
String? fxModuleArt(String name) {
  final artwork = fxModuleNamed(name)?.artwork;
  if (artwork == null || artwork.isEmpty) return null;
  return fxStompAsset(artwork.first);
}

/// The modules of a [family] rack that own [key] as a parameter, in table
/// order.
///
/// Usually one, and two for a key in [FxModule.shared]. Ownership is by
/// prefix, so a one-word power key whose word is also one of its module's
/// groups (`Wah`, `Comp`, `LPF`) is owned by that module too; a power key
/// spelled differently from its group (`Delay` for `Del`) and a key the table
/// leaves unclaimed on purpose have no owner.
List<FxModule> fxModulesOwning(String key, String family) => [
  for (final module in kFxModules)
    if (module.appearsIn(family) && module.owns(key)) module,
];

/// The modules [preset] holds, in the order its rack runs them
/// ([kFxRackOrders]), keeping only those the preset actually names.
///
/// A preset names a module by carrying its power key or any of its
/// parameters — some presets carry a module's controls without its power key
/// and the other way round, so either is enough to say the rack has it.
///
/// A module the family's order does not place (no factory preset has one, a
/// test pins that) is still kept, after the placed ones in table order: a rack
/// is what the player loaded.
List<FxModule> fxPresetModules(FxPreset preset) {
  final named = [
    for (final module in kFxModules)
      if (module.appearsIn(preset.family) && _names(preset, module)) module,
  ];
  final order = kFxRackOrders[preset.family] ?? const <String>[];
  return [
    for (final name in order) ...named.where((m) => m.name == name),
    ...named.where((m) => !order.contains(m.name)),
  ];
}

bool _names(FxPreset preset, FxModule module) {
  for (final key in module.enables) {
    if (preset.params.containsKey(key)) return true;
  }
  for (final key in preset.params.keys) {
    if (module.owns(key)) return true;
  }
  return false;
}

/// One effect the player can add to a rack on its own: a row of the pen's
/// "Add an effect to a rack" screen (frame `Rv04K`).
///
/// A row adds one pedal of the module table in its default variant: the
/// [module] as the [family] rack exposes it.
class FxAddableEffect {
  /// Creates an [FxAddableEffect].
  const FxAddableEffect({
    required this.label,
    required this.module,
    required this.family,
  });

  /// The row's label, as the pen writes it.
  final String label;

  /// The [FxModule.name] of the pedal the row adds.
  final String module;

  /// The rack family whose [module] is the default variant.
  final String family;
}

/// The 26 rows of the pen's "Add an effect to a rack" screen, in the pen's
/// order.
///
/// Where a pedal has one variant, the row takes it; a pedal several racks
/// carry with the same parameters names one of them. Where it has several,
/// the accepted plan (#887) names the default for the EQs, the delay and the
/// reverb: the four-band EQ is Ed's, the parametric EQ the Dub Rack's (the
/// Lo-Fi Rack's is the same; the Rhythmic Rack's has no Q), the delay the
/// mode delay (Ed's Rack carries it, as six other racks do) and the reverb
/// the mode reverb with brightness (Ed's, as the Vocal and Vocal Tuner racks
/// do). The owner chose the rest on #1382: the variant exposing the most
/// controls, which is the compressor from Ed's Rack, the distortion from the
/// Lo-Fi Rack, the doubler from the Dub Rack, the low-pass filter from the
/// Rhythmic Rack and the modulation from the Guitar Rack.
const List<FxAddableEffect> kFxAddableEffects = [
  FxAddableEffect(label: 'Amp', module: 'Amp', family: "Ed's Rack"),
  FxAddableEffect(label: 'Chorus', module: 'Chorus', family: "Ed's Rack"),
  FxAddableEffect(
    label: 'Compressor',
    module: 'Compressor',
    family: "Ed's Rack",
  ),
  FxAddableEffect(label: 'Degrade', module: 'Degrade', family: 'Lo-Fi Rack'),
  FxAddableEffect(label: 'Delay', module: 'Delay', family: "Ed's Rack"),
  FxAddableEffect(
    label: 'Distortion',
    module: 'Distortion',
    family: 'Lo-Fi Rack',
  ),
  FxAddableEffect(label: 'Doubler', module: 'Doubler', family: 'Dub Rack'),
  FxAddableEffect(label: 'Dub Delay', module: 'Dub delay', family: 'Dub Rack'),
  FxAddableEffect(
    label: 'Four-band EQ',
    module: 'Four-band EQ',
    family: "Ed's Rack",
  ),
  FxAddableEffect(
    label: 'Harmonize',
    module: 'Harmonizer',
    family: 'Vocal Tuner Rack',
  ),
  FxAddableEffect(
    label: 'HP / Gate',
    module: 'High-pass gate',
    family: 'Vocal Rack',
  ),
  FxAddableEffect(
    label: 'Low-pass Filter',
    module: 'Low-pass filter',
    family: 'Rhythmic Rack',
  ),
  FxAddableEffect(
    label: 'Modulation',
    module: 'Modulation',
    family: 'Guitar Rack',
  ),
  FxAddableEffect(label: 'Octaver', module: 'Octaver', family: "Ed's Rack"),
  FxAddableEffect(label: 'Overdrive', module: 'Overdrive', family: "Ed's Rack"),
  FxAddableEffect(
    label: 'Parametric EQ',
    module: 'Parametric EQ',
    family: 'Dub Rack',
  ),
  FxAddableEffect(
    label: 'Pitch Shift',
    module: 'Pitch shift',
    family: 'Studio Rack',
  ),
  FxAddableEffect(label: 'Pumper', module: 'Pumper', family: 'Rhythmic Rack'),
  FxAddableEffect(label: 'Reverb', module: 'Reverb', family: "Ed's Rack"),
  FxAddableEffect(label: 'Slicer', module: 'Slicer', family: 'Rhythmic Rack'),
  FxAddableEffect(
    label: 'Smart Tune',
    module: 'Smart tune',
    family: 'Vocal Tuner Rack',
  ),
  FxAddableEffect(
    label: 'Spring Reverb',
    module: 'Spring reverb',
    family: 'Guitar Rack',
  ),
  FxAddableEffect(
    label: 'Transient',
    module: 'Transient',
    family: 'Drum Rack',
  ),
  FxAddableEffect(label: 'Vinyl', module: 'Vinyl', family: 'Lo-Fi Rack'),
  FxAddableEffect(label: 'Wah', module: 'Wah', family: "Ed's Rack"),
  FxAddableEffect(label: 'Whammy', module: 'Whammy', family: 'Guitar Rack'),
];
