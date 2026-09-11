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

  /// Whether [key] is this module's power key.
  bool poweredBy(String key) => enables.contains(key);

  /// Whether the parameter [key] belongs to this module.
  bool owns(String key) {
    final prefix = key.split(' ').first;
    return groups.contains(prefix);
  }
}

/// Every module the factory catalogue names, with the evidence for each.
///
/// Order is the table's own, not a processing order: the source does not say
/// what order a rack runs its pedals in, and nothing here pretends to.
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
    groups: ['Dub-Verb', 'Dub'],
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
    groups: ['Harm', 'Voice', 'Lead', 'Low', 'Mid', 'High', 'Key', 'Scale'],
    artwork: ['Harmonise20'],
  ),
  FxModule(
    name: 'Smart tune',
    enables: ['Mode'],
    groups: [
      'Smart',
      'Auto',
      'Audio',
      'Reference',
      'Speed',
      'Stereo',
      'Tightness',
      'Tracking',
    ],
    artwork: ['SmartTune2'],
  ),
];

/// Parameter groups the table deliberately claims for no module.
///
/// `Master` is the rack's own output level, which the accepted design puts
/// AFTER the pedals and gives to the rack rather than to any of them.
/// `Para` appears in two families with no power key of its own and nothing
/// naming what it belongs to, so it stays an evidence gap rather than being
/// assigned to a module on a guess.
const Set<String> kFxUnclaimedGroups = {'Master', 'Para'};

/// The module whose power key is [key], or `null`.
FxModule? fxModuleFor(String key) {
  for (final module in kFxModules) {
    if (module.poweredBy(key)) return module;
  }
  return null;
}

/// The module that owns parameter [key], or `null`.
FxModule? fxModuleOwning(String key) {
  for (final module in kFxModules) {
    if (module.owns(key)) return module;
  }
  return null;
}
