import 'dart:math' as math;

import 'package:fx_catalogue/fx_catalogue.dart';
import 'package:looper_repository/src/models/fx_rack_level.dart';
import 'package:looper_repository/src/models/track_effect.dart';

/// How much of a catalogue module this engine can actually build.
///
/// The accepted design requires truthful partial support and forbids silently
/// substituting another effect and calling that exact parity, so a surface has
/// to be able to say which of these a pedal is.
enum FxModuleReadiness {
  /// The engine builds this kind of effect and every control the preset
  /// carries has somewhere to go.
  ///
  /// Not a claim of sonic parity: the accepted design permits the sound to
  /// differ. It claims only that nothing the preset says is being dropped.
  full,

  /// The engine builds this kind of effect, but the preset carries controls
  /// it has no place for. Those values are kept and shown, and the surface
  /// says they do not reach the sound.
  partial,

  /// The engine has no effect of this kind. The pedal is still shown with its
  /// parameters — a rack is what the player loaded, not what this build can
  /// run — and it processes nothing.
  unavailable,
}

/// What building one catalogue module on this engine amounts to: the effect
/// type, which preset key feeds each of its parameters, and which of the
/// preset's own controls have nowhere to go.
class FxModuleBuild {
  /// Creates an [FxModuleBuild].
  const FxModuleBuild({
    required this.type,
    this.params = const [],
    this.unmapped = const [],
    this.scales = const {},
    this.fixed = const {},
    this.labels = const {},
  });

  /// A module this engine cannot build at all.
  const FxModuleBuild.unavailable() : this(type: null);

  /// The engine effect this module becomes, or `null` when there is none.
  final TrackEffectType? type;

  /// The preset key feeding each engine parameter, in parameter order. A null
  /// entry is a parameter the preset says nothing about, which keeps the
  /// engine's own default.
  final List<String?> params;

  /// The preset's controls this engine has no parameter for. Kept so the
  /// surface can show them and say plainly that they do not reach the sound.
  final List<String> unmapped;

  /// The rack's own scale for an engine parameter whose range differs from
  /// the kind's, by parameter index: the preset value is read on this scale
  /// and set to the same value on the kind's (an EQ's mid frequency, which
  /// the Drum Rack spans 40..8000 Hz and the kind 20..20000 Hz). A parameter
  /// absent here copies the preset value as it is.
  final Map<int, FxSourceScale> scales;

  /// The value, in the parameter's own unit, of each engine parameter this
  /// variant does not expose but fixes (a four-band EQ's band frequencies in
  /// the racks that show only the gains), by parameter index. Chosen, not
  /// measured (#891).
  final Map<int, double> fixed;

  /// The parameter key a variant shows instead of the kind's own, by index
  /// (a parametric EQ's single band is "Mid", not "Lo mid").
  final Map<int, String> labels;

  /// The engine parameters this variant shows, in order: those a preset key
  /// feeds.
  List<int> get exposed => [
    for (var i = 0; i < params.length; i++)
      if (params[i] != null) i,
  ];

  /// How much of the module this build covers.
  FxModuleReadiness get readiness {
    if (type == null) return FxModuleReadiness.unavailable;
    return unmapped.isEmpty
        ? FxModuleReadiness.full
        : FxModuleReadiness.partial;
  }
}

/// What this engine can build for each catalogue module, by module name.
///
/// Written against the parameter names that are actually in the catalogue
/// files, not against a guess at what a module ought to carry. A module absent
/// from this map is [FxModuleReadiness.unavailable]: the engine builds seven
/// effects and the catalogue names twenty-six modules, so most of them are.
const Map<String, FxModuleBuild> kFxModuleBuilds = {
  // p0 time, p1 feedback, p2 mix — the three the preset names, so nothing is
  // dropped. Its mode (and the Drum Rack's feedback filter frequency) are
  // Looper X's own shaping and have no engine parameter, which is what makes
  // it partial.
  'Delay': FxModuleBuild(
    type: TrackEffectType.delay,
    params: ['Del Time', 'Del Feedback', 'Del Mix'],
    unmapped: ['Del Freq', 'Del Mode'],
  ),
  // The Dub Rack's delay: p0 time and p1 feedback. It has no mix control, so
  // the mix keeps the engine default. Its damping, stereo ratio and resonance
  // are the dub delay's own shaping and have no engine parameter.
  'Dub delay': FxModuleBuild(
    type: TrackEffectType.delay,
    params: ['Del Time', 'Del Feedback'],
    unmapped: ['Del Damp', 'Del L/R Ratio', 'Del Res-Freq', 'Del Reso'],
  ),
  // p0 size, p1 damping, p2 mix. `Rev Bright` is brightness where the engine
  // wants damping, which is its complement, so it is NOT wired here: inverting
  // someone else's control into ours is the silent substitution the accepted
  // design forbids. It stays unmapped and visible.
  'Reverb': FxModuleBuild(
    type: TrackEffectType.reverb,
    params: ['Rev Length', null, 'Rev Mix'],
    unmapped: [
      'Rev Bright',
      'Rev Density',
      'Rev ER',
      'Rev Lo/Hi',
      'Rev Mode',
      'Rev Tail/ER',
    ],
  ),
  // p0 drive, p1 output level. The preset's tone control has no engine
  // parameter — the built-in drive has no tone stage at all.
  'Overdrive': FxModuleBuild(
    type: TrackEffectType.drive,
    params: ['OD Drive'],
    unmapped: ['OD Tone'],
  ),
  'Distortion': FxModuleBuild(
    type: TrackEffectType.drive,
    params: ['Dist Drive'],
    unmapped: ['Dist Tone'],
  ),
  // p0 cutoff, p1 resonance. The preset's own LFO over the cutoff has no
  // engine parameter.
  'Low-pass filter': FxModuleBuild(
    type: TrackEffectType.filter,
    params: ['LPF Cutoff', 'LPF Reso'],
    unmapped: ['LPF LFO Depth', 'LPF LFO Rate'],
  ),
  // p0 shift, p1 tone, p2 mix, p3 mode. Only the mix has a preset key: the
  // catalogue's octaver is two fixed voices with their own levels, where this
  // engine's is one continuously shifted voice, so its shift has nothing to
  // read and keeps the engine default.
  'Octaver': FxModuleBuild(
    type: TrackEffectType.octaver,
    params: [null, null, 'Octave Mix'],
    unmapped: ['Oct High Mode', 'Octave 1 Vol', 'Octave 2 Vol'],
  ),
};

/// A rack control's own scale (see [FxModuleBuild.scales]).
class FxSourceScale {
  /// `min * (max / min) ^ v`.
  const FxSourceScale.log(this.min, this.max) : log = true;

  /// `min + (max - min) * v`.
  const FxSourceScale.linear(this.min, this.max) : log = false;

  /// The value at 0.
  final double min;

  /// The value at 1.
  final double max;

  /// Whether the scale is logarithmic.
  final bool log;

  /// The value setting [v] (clamped to `0..1`) stands for.
  double valueAt(double v) {
    final c = v.clamp(0.0, 1.0);
    return log ? min * math.pow(max / min, c) : min + (max - min) * c;
  }
}

/// The Looper X EQ's rack variants, by module and family: one engine kind
/// (`TrackEffectType.eq`), each variant exposing the controls its racks show
/// (docs/plan/2026-10-20-looperx-derived-tables.md). Where a rack shows only
/// gains, the band frequencies and Qs are fixed at values chosen here
/// (100 Hz and 5 kHz shelves, a 1 kHz mid, Q 0.71) until reference audio
/// says otherwise (#891). The first variant of each module is its default,
/// the one "Add an effect" uses (#887: Ed's 4-band, the Dub Rack's Para).
const Map<String, Map<String, FxModuleBuild>> kFxModuleVariants = {
  'Four-band EQ': {
    "Ed's Rack": _edsEq,
    'Drum Rack': _drumEq,
    'Studio Rack': _vocalEq,
    'Vocal Rack': _vocalEq,
    'Vocal Tuner Rack': _vocalEq,
  },
  'Parametric EQ': {
    'Dub Rack': _paraEq,
    'Lo-Fi Rack': _paraEq,
    'Rhythmic Rack': _rhythmicEq,
  },
};

const double _q = 0.7071;

// Ed's Rack: every control of the generic EQ but the air band.
const FxModuleBuild _edsEq = FxModuleBuild(
  type: TrackEffectType.eq,
  params: [
    'EQ Low Cut',
    'EQ Low',
    'EQ Low Freq',
    'EQ Low Q',
    'EQ Lo Mid',
    'EQ Lo Mid Freq',
    'EQ Lo Mid Q',
    'EQ Hi Mid',
    'EQ Hi Mid Freq',
    'EQ Hi Mid Q',
    'EQ High',
    'EQ High Freq',
    'EQ High Q',
    'EQ High Cut',
  ],
  scales: {
    5: FxSourceScale.log(100, 8000),
    8: FxSourceScale.log(100, 8000),
  },
  fixed: {14: 0},
);

// Drum Rack: low and high shelves, one swept mid.
const FxModuleBuild _drumEq = FxModuleBuild(
  type: TrackEffectType.eq,
  params: [
    null,
    'EQ Low',
    null,
    null,
    'EQ Mid',
    'EQ Mid Freq',
    null,
    null,
    null,
    null,
    'EQ High',
  ],
  scales: {5: FxSourceScale.log(40, 8000)},
  fixed: {
    0: 20, // low cut off
    2: 100,
    3: _q,
    6: _q,
    7: 0,
    11: 5000,
    12: _q,
    13: 20000, // high cut off
    14: 0,
  },
  labels: {4: 'mid_gain', 5: 'mid_freq'},
);

// Studio, Vocal and Vocal Tuner racks: four gains.
const FxModuleBuild _vocalEq = FxModuleBuild(
  type: TrackEffectType.eq,
  params: [
    null,
    'EQ Low',
    null,
    null,
    'EQ Mid',
    null,
    null,
    null,
    null,
    null,
    'EQ High',
    null,
    null,
    null,
    'EQ Air',
  ],
  fixed: {
    0: 20,
    2: 100,
    3: _q,
    5: 1000,
    6: _q,
    7: 0,
    11: 5000,
    12: _q,
    13: 20000,
  },
  labels: {4: 'mid_gain'},
);

// Dub and Lo-Fi racks: low cut, one band, high cut.
const FxModuleBuild _paraEq = FxModuleBuild(
  type: TrackEffectType.eq,
  params: [
    'EQ Low Cut',
    null,
    null,
    null,
    'EQ Mid Gain',
    'EQ Mid Freq',
    'EQ Mid Q',
    null,
    null,
    null,
    null,
    null,
    null,
    'EQ High Cut',
  ],
  scales: {5: FxSourceScale.log(120, 16000)},
  fixed: {1: 0, 7: 0, 10: 0, 14: 0},
  labels: {4: 'mid_gain', 5: 'mid_freq', 6: 'mid_q'},
);

// Rhythmic Rack: the parametric EQ without its Q, held at the Dub Rack's
// default (0.76).
const FxModuleBuild _rhythmicEq = FxModuleBuild(
  type: TrackEffectType.eq,
  params: [
    'EQ Low Cut',
    null,
    null,
    null,
    'EQ Mid Gain',
    'EQ Mid Freq',
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    'EQ High Cut',
  ],
  scales: {5: FxSourceScale.log(120, 16000)},
  fixed: {1: 0, 6: 0.7616, 7: 0, 10: 0, 14: 0},
  labels: {4: 'mid_gain', 5: 'mid_freq'},
);

/// The source key that carries a rack's own level.
const String kFxRackLevelKey = 'Master Vol';

/// Builds the chain entries for a whole factory rack out of [preset]: one
/// entry per module the preset holds, in rack order (see [fxPresetModules]),
/// with the preset's [kFxRackLevelKey] as the rack level.
///
/// The rack level is the last entry's [FxChannels.level], which is where
/// `FxChainGroup.channels` reads a rack's level from. `Master Vol` belongs
/// to no module, so it never becomes a module parameter. The Looper X
/// registers it in every rack as -12 to +12 dB in 0.1 dB steps through a
/// linear mapper, so its normalized value v is `-12 + 24 * v` dB (see
/// [fxRackLevelGainAt]), and every factory value lands on that 0.1 dB grid.
/// A preset without it leaves the rack at unity.
List<BuiltInEffect> fxRackEntries(FxPreset preset) {
  final entries = [
    for (final module in fxPresetModules(preset)) fxModuleEntry(module, preset),
  ];
  final level = preset.params[kFxRackLevelKey];
  if (entries.isEmpty || level == null) return entries;
  final last = entries.last;
  entries[entries.length - 1] = last.copyWith(
    channels: last.channels.copyWith(level: fxRackLevelGainAt(level)),
  );
  return entries;
}

/// What this engine can build for [module], in [family]'s variant when the
/// module has variants (its default variant without a family).
FxModuleBuild fxModuleBuild(FxModule module, {String? family}) {
  final variants = kFxModuleVariants[module.name];
  if (variants != null) {
    return variants[family] ?? variants.values.first;
  }
  return kFxModuleBuilds[module.name] ?? const FxModuleBuild.unavailable();
}

/// The rack variant [entry] was built as, or `null` when it is not one: a
/// Looper X kind ([TrackEffectType.isRackKind]) built from a module with
/// variants ([kFxModuleVariants]). The variant is the one whose controls all
/// appear in the entry's [BuiltInEffect.source], the one with the most of
/// them first; every factory preset of a family carries all of its keys, so
/// this is the family's own. An entry no variant fits is not one.
///
/// What a surface shows for a rack pedal: [FxModuleBuild.exposed], under
/// [FxModuleBuild.labels]. Any other entry shows every parameter of its type.
FxModuleBuild? fxEntryBuild(BuiltInEffect entry) {
  final name = entry.module;
  if (name == null || !entry.type.isRackKind) return null;
  final variants = kFxModuleVariants[name];
  if (variants == null) return null;
  FxModuleBuild? build;
  var best = -1;
  for (final v in variants.values) {
    final keys = v.params.whereType<String>().toList();
    if (keys.length > best && keys.every(entry.source.containsKey)) {
      best = keys.length;
      build = v;
    }
  }
  return build?.type == entry.type ? build : null;
}

/// The controls [entry] shows: the parameters, in order, and the key each is
/// named by. Its rack variant's ([fxEntryBuild]), or every parameter of its
/// type under its own key. What every surface that lists or names an entry's
/// controls goes through (the pedal, the effect editor, the control
/// bindings), so they agree.
({List<int> params, List<String> keys}) fxEntryControls(BuiltInEffect entry) {
  final build = fxEntryBuild(entry);
  final params =
      build?.exposed ?? [for (var i = 0; i < entry.type.params.length; i++) i];
  return (
    params: params,
    keys: [
      for (final i in params) build?.labels[i] ?? entry.type.params[i].key,
    ],
  );
}

/// Builds one chain entry for [module] out of [preset]'s values.
///
/// Returns an entry whatever the readiness: a rack is what the player loaded,
/// not what this build can run, so an unavailable module still takes its place
/// in the chain and passes signal through untouched.
///
/// The entry's enabled bit follows the preset's own power key when it carries
/// one. New instances arriving bypassed is the ADDING surface's rule, applied
/// where the instance is added rather than here, so this stays a faithful read
/// of the preset.
BuiltInEffect fxModuleEntry(FxModule module, FxPreset preset) {
  final build = fxModuleBuild(module, family: preset.family);
  final type = build.type ?? TrackEffectType.none;
  assert(
    build.params.length <= type.params.length,
    '${module.name} maps more keys than ${type.name} reads',
  );
  final params = List<double>.of(type.defaultParams);
  for (var i = 0; i < build.params.length && i < type.params.length; i++) {
    final key = build.params[i];
    final value = key == null ? null : preset.params[key];
    if (value == null) continue;
    final scale = build.scales[i];
    params[i] = scale == null
        ? value.clamp(0.0, 1.0)
        : type.params[i].settingFor(scale.valueAt(value));
  }
  for (final e in build.fixed.entries) {
    if (e.key < type.params.length) {
      params[e.key] = type.params[e.key].settingFor(e.value);
    }
  }
  var enabled = true;
  for (final key in module.enables) {
    final value = preset.params[key];
    if (value != null) {
      enabled = value >= 0.5;
      break;
    }
  }
  return BuiltInEffect(
    type: type,
    params: params,
    enabled: enabled,
    // The catalogue's own name for the pedal, kept whatever this engine could
    // build for it. A module with no engine effect becomes a passthrough
    // entry, and this is what still says which pedal it is.
    module: module.name,
    presetId: preset.id,
    // Every value the preset gives this module — its power key, its own
    // parameters and the ones it shares with another module — so a later
    // build can rebuild the module from what was loaded.
    source: {
      for (final e in preset.params.entries)
        if (module.poweredBy(e.key) || module.owns(e.key)) e.key: e.value,
    },
  );
}
