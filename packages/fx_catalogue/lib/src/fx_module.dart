import 'package:fx_catalogue/src/fx_family.dart';
import 'package:fx_catalogue/src/fx_preset.dart';

/// The kinds of effect the factory racks are built from.
///
/// The Looper X runs one generic DSP module per kind, and each rack exposes a
/// subset of that module's parameters: its variant. Two pedals of one kind
/// (the Delay and the Dub delay, the four-band and the parametric EQ) are two
/// variants of it.
enum FxKind {
  /// Equalizer.
  eq,

  /// Compressor.
  compressor,

  /// Transient shaper.
  transient,

  /// High-pass filter with a gate.
  hpGate,

  /// Doubler.
  doubler,

  /// Chorus.
  chorus,

  /// Wah.
  wah,

  /// Overdrive.
  overdrive,

  /// Distortion.
  distortion,

  /// Vinyl simulation.
  vinyl,

  /// Sample-rate and filter degrader.
  degrade,

  /// Low-pass filter.
  lpf,

  /// Spring reverb.
  spring,

  /// The Dub Rack's dub reverb.
  dubVerb,

  /// The Dub Rack's ambience reverb.
  ambVerb,

  /// Pitch shifter.
  pitchShift,

  /// Delay.
  delay,

  /// Reverb.
  reverb,

  /// Amplifier with cabinet.
  ampCab,

  /// Modulation: chorus, phaser or flanger.
  mod,

  /// Slicer.
  slicer,

  /// Pumper.
  pumper,

  /// Whammy.
  whammy,

  /// Two-voice octaver.
  dualOctaver,

  /// Pitch correction.
  smartTune,

  /// Harmonizer.
  harmonizer,
}

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
    required this.kind,
    required this.enables,
    required this.groups,
    required this.artwork,
    this.shared = const [],
    this.families,
  });

  /// The pedal's display name.
  final String name;

  /// The kind of effect this pedal is.
  final FxKind kind;

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

const Set<String> _paraEqFamilies = {'Dub Rack', 'Lo-Fi Rack'};

const Set<String> _fourBandEqFamilies = {
  'Drum Rack',
  "Ed's Rack",
  'Guitar Rack',
  'Rhythmic Rack',
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

/// The Vocal Tuner parameters that both Smart Tune and the Harmonizer read.
const List<String> _vocalTunerShared = [
  'Mode',
  'Auto Source',
  'Key',
  'Scale Type',
];

/// Every module the factory catalogue names, with the evidence for each.
///
/// A rack builds its entries in this table's order. That is the table's own
/// order, not the order the Looper X runs its modules in, because no source
/// examined records that order:
///
/// - The presets are flat maps whose keys are stored in alphabetical order.
/// - The extracted UI draws a rack's power buttons from the binary's parameter
///   model (`Pages/FxEdit/SelectorPanel.qml` repeats `effect.param(index)` for
///   `index < effect.bypassCount`, and `Pages/FxEdit/ParamsPanel.qml` does the
///   same for the parameters), so the QML holds no order of its own.
/// - The binary's string table lists Ed's Rack power keys as Oct, Wah,
///   Compressor, OvDrive, Amp, Chor, EQ 4-Band and the Dub Rack's as Para EQ,
///   Doubler, Dub Delay, Dub-Verb, Amb-Verb, but the linker keeps only the
///   first copy of a repeated string (Delay, Reverb and Comp are missing from
///   those runs), and the same racks' parameter strings follow a different
///   order (the EQ parameters come last). String order is therefore not a
///   processing order either.
///
/// Until a source states the order, a rack's modules keep the table order and
/// the player reorders them.
const List<FxModule> kFxModules = [
  FxModule(
    name: 'Amp',
    kind: FxKind.ampCab,
    enables: ['Amp'],
    // `Cab` is a value of the amp, not a module: it is space-free like a
    // power key but continuous, so it is a parameter that happens to be
    // spelled without one.
    groups: ['Amp', 'Cab'],
    artwork: ['Amp4'],
  ),
  FxModule(
    name: 'Compressor',
    kind: FxKind.compressor,
    enables: ['Comp', 'Compressor'],
    groups: ['Comp'],
    artwork: ['Compressor2', 'Compressor3', 'Compressor4'],
  ),
  FxModule(
    name: 'Overdrive',
    kind: FxKind.overdrive,
    enables: ['OvDrive'],
    groups: ['OD'],
    artwork: ['Overdrive2'],
  ),
  FxModule(
    name: 'Distortion',
    kind: FxKind.distortion,
    enables: ['Dist', 'Distort'],
    groups: ['Dist'],
    artwork: ['Distort1', 'Distort2'],
  ),
  FxModule(
    name: 'Four-band EQ',
    kind: FxKind.eq,
    enables: ['EQ', 'EQ 4-Band'],
    groups: ['EQ'],
    artwork: ['EQ3', 'EQ4', 'EQ5', 'EQ8'],
    families: _fourBandEqFamilies,
  ),
  FxModule(
    name: 'Parametric EQ',
    kind: FxKind.eq,
    // The Dub and Lo-Fi racks power their EQ with `Para EQ` and give it the
    // same `EQ` prefix the four-band EQ uses elsewhere.
    enables: ['Para EQ'],
    groups: ['EQ'],
    // The binary's single-effect artwork list runs in effect-name order and
    // puts EQ5 between Overdrive2 and PitchShift2, where Parametric EQ falls.
    artwork: ['EQ5'],
    families: _paraEqFamilies,
  ),
  FxModule(
    name: 'Low-pass filter',
    kind: FxKind.lpf,
    enables: ['LPF'],
    groups: ['LPF'],
    artwork: ['LPF2', 'LPF4'],
  ),
  FxModule(
    name: 'Wah',
    kind: FxKind.wah,
    enables: ['Wah'],
    groups: ['Wah'],
    artwork: ['Wah1'],
  ),
  FxModule(
    name: 'Chorus',
    kind: FxKind.chorus,
    enables: ['Chor'],
    groups: ['Chor'],
    artwork: ['Chorus3'],
  ),
  FxModule(
    name: 'Modulation',
    kind: FxKind.mod,
    enables: ['Mod'],
    groups: ['Mod'],
    artwork: ['Mod3'],
  ),
  FxModule(
    name: 'Octaver',
    kind: FxKind.dualOctaver,
    enables: ['Oct'],
    groups: ['Oct', 'Octave'],
    artwork: ['Octaver3'],
  ),
  FxModule(
    name: 'Pitch shift',
    kind: FxKind.pitchShift,
    enables: ['Pitch'],
    groups: ['Pitch'],
    artwork: ['PitchShift2'],
  ),
  FxModule(
    name: 'Whammy',
    kind: FxKind.whammy,
    enables: ['Whammy'],
    groups: ['Whammy'],
    artwork: ['Wham2'],
  ),
  FxModule(
    name: 'Delay',
    kind: FxKind.delay,
    enables: ['Delay'],
    groups: ['Del'],
    artwork: ['Delay3', 'Delay4', 'Delay6'],
    families: _delayFamilies,
  ),
  FxModule(
    name: 'Dub delay',
    kind: FxKind.delay,
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
    kind: FxKind.reverb,
    enables: ['Reverb'],
    groups: ['Rev'],
    artwork: ['Reverb2', 'Reverb3', 'Reverb5'],
  ),
  FxModule(
    name: 'Spring reverb',
    kind: FxKind.spring,
    enables: ['Spring'],
    groups: ['Spring'],
    artwork: ['SpringRev2'],
  ),
  FxModule(
    name: 'Ambience',
    kind: FxKind.ambVerb,
    // The source spells the group three ways across the Dub Rack, including
    // one that differs only in case.
    enables: ['Amb-Verb'],
    groups: ['Amb-Verb', 'Amb-verb', 'Amb-Dub'],
    artwork: ['AmbiVerb2'],
  ),
  FxModule(
    name: 'Dub reverb',
    kind: FxKind.dubVerb,
    enables: ['Dub-Verb'],
    groups: ['Dub-Verb'],
    artwork: ['DubVerb2'],
  ),
  FxModule(
    name: 'Doubler',
    kind: FxKind.doubler,
    enables: ['Doubler'],
    groups: ['Doubler'],
    artwork: ['Doubler1', 'Doubler2'],
  ),
  FxModule(
    name: 'High-pass gate',
    kind: FxKind.hpGate,
    // Two power keys that are not alternatives of one another: `HP/Gate` is
    // the module's own, and `Highpass` reads as its frequency. Both are here
    // because both are space-free, and the test pins only the binary one.
    enables: ['HP/Gate'],
    groups: ['Gate', 'Highpass'],
    artwork: ['HPFGate2'],
  ),
  FxModule(
    name: 'Transient',
    kind: FxKind.transient,
    enables: ['Transient'],
    groups: ['Attack', 'Sustain'],
    artwork: ['Transient3'],
  ),
  FxModule(
    name: 'Pumper',
    kind: FxKind.pumper,
    enables: ['Pumper'],
    groups: ['Pumper'],
    artwork: ['Pumper2'],
  ),
  FxModule(
    name: 'Slicer',
    kind: FxKind.slicer,
    enables: ['Slicer'],
    groups: ['Slic'],
    artwork: ['Slicer2'],
  ),
  FxModule(
    name: 'Vinyl',
    kind: FxKind.vinyl,
    enables: ['Vinyl'],
    groups: ['Vinyl'],
    artwork: ['Vinyl4'],
  ),
  FxModule(
    name: 'Degrade',
    kind: FxKind.degrade,
    enables: ['Degrade'],
    groups: ['Degrade'],
    artwork: ['Degrade3'],
  ),
  FxModule(
    name: 'Harmonizer',
    kind: FxKind.harmonizer,
    enables: ['Harmonize'],
    groups: ['Harm', 'Voice', 'Lead', 'Low', 'Mid', 'High', 'Scale'],
    shared: _vocalTunerShared,
    artwork: ['Harmonise20'],
  ),
  FxModule(
    name: 'Smart tune',
    kind: FxKind.smartTune,
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
  ),
];

/// Parameter groups the table deliberately claims for no module.
///
/// `Master` is the rack's own output level, which the accepted design puts
/// AFTER the pedals and gives to the rack rather than to any of them.
const Set<String> kFxUnclaimedGroups = {'Master'};

/// The module whose power key is [key], or `null`.
FxModule? fxModuleFor(String key) {
  for (final module in kFxModules) {
    if (module.poweredBy(key)) return module;
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

/// The modules of a [family] rack that read parameter [key], in table order.
///
/// Usually one. Two for a parameter in [FxModule.shared], and none for a power
/// key or a key the table leaves unclaimed on purpose.
List<FxModule> fxModulesOwning(String key, String family) => [
  for (final module in kFxModules)
    if (module.appearsIn(family) && module.owns(key)) module,
];

/// The modules [preset] holds, in the table's order, keeping only those the
/// preset actually names.
///
/// A preset names a module by carrying its power key or any of its
/// parameters — some presets carry a module's controls without its power key
/// and the other way round, so either is enough to say the rack has it.
List<FxModule> fxPresetModules(FxPreset preset) => [
  for (final module in kFxModules)
    if (module.appearsIn(preset.family) && _names(preset, module)) module,
];

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
/// A row is a kind and its default variant. The variant is a pedal of the
/// module table as one factory rack exposes it: [module] in a [family] rack.
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

  /// The rack family whose [module] is the default variant, or `null` while
  /// the kind has several variants and none has been chosen as the default.
  final String? family;
}

/// The 26 rows of the pen's "Add an effect to a rack" screen, in the pen's
/// order.
///
/// Where a pedal has one variant, the row takes it; a pedal several racks
/// carry with the same parameters names one of them. Where it has several,
/// the accepted plan (#887) names the default: the four-band EQ is Ed's, the
/// delay the mode delay (Ed's Rack carries it, as six other racks do) and the
/// reverb the mode reverb with brightness (Ed's, as the Vocal and Vocal Tuner
/// racks do). The compressor, distortion, doubler, low-pass filter and
/// modulation have several variants and no default yet, so their
/// [FxAddableEffect.family] is `null`.
const List<FxAddableEffect> kFxAddableEffects = [
  FxAddableEffect(label: 'Amp', module: 'Amp', family: "Ed's Rack"),
  FxAddableEffect(label: 'Chorus', module: 'Chorus', family: "Ed's Rack"),
  FxAddableEffect(label: 'Compressor', module: 'Compressor', family: null),
  FxAddableEffect(label: 'Degrade', module: 'Degrade', family: 'Lo-Fi Rack'),
  FxAddableEffect(label: 'Delay', module: 'Delay', family: "Ed's Rack"),
  FxAddableEffect(label: 'Distortion', module: 'Distortion', family: null),
  FxAddableEffect(label: 'Doubler', module: 'Doubler', family: null),
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
    family: null,
  ),
  FxAddableEffect(label: 'Modulation', module: 'Modulation', family: null),
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
