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

/// Which of the Dub Rack's two parallel paths a module runs on (#1430).
///
/// The rack's path entries form a parallel section: both paths start from
/// what the section is handed, each runs its own modules in chain order, and
/// the Amb-Verb's Amb-Dub Mix m sums them, the [amb] path at A(m) (1 up to
/// 50 %, then 1 - (2m - 1)^2) and the [dub] path at D(m) (min(1, (2m)^2)).
/// Each path carries its own dry, so with every path module off the rack
/// still passes A(m) + D(m) of its input: 1.64 at the default 40 %.
enum FxModulePath {
  /// The Doubler, the Dub Delay and the Dub-Verb.
  dub,

  /// The Amb-Verb.
  amb,
}

/// The rack path each entry of [chain] runs on, by index: a built-in entry's
/// rack variant's ([fxEntryBuild], [FxModuleBuild.path]) when its rack also
/// holds an Amb-Verb (a module on the [FxModulePath.amb] path), `null` for
/// any other. Derived, never stored, so it always agrees with the variant
/// the entry's controls come from.
///
/// So the paths exist only in a rack that has the Amb-Verb that mixes them.
/// A Dub path module anywhere else runs in series, as the module itself is:
/// the Dub delay passes its echoes only.
List<FxModulePath?> fxEntryPaths(List<TrackEffect> chain) {
  final own = [
    for (final fx in chain)
      if (fx is BuiltInEffect && fx.rack != null)
        fxEntryBuild(fx)?.path
      else
        null,
  ];
  final mixed = {
    for (var i = 0; i < chain.length; i++)
      if (own[i] == FxModulePath.amb) chain[i].rack!.id,
  };
  return [
    for (var i = 0; i < chain.length; i++)
      if (mixed.contains(chain[i].rack?.id)) own[i] else null,
  ];
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
    this.shown = const {},
    this.path,
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

  /// What a rack's control applies, for an engine parameter whose range
  /// differs from the kind's, by parameter index: the preset value is read on
  /// this scale and set to the same value on the kind's (an EQ's mid
  /// frequency, which the Drum Rack spans 40..8000 Hz and the kind
  /// 20..20000 Hz). A parameter absent here copies the preset value as it is.
  final Map<int, FxSourceScale> scales;

  /// The value, in the parameter's own unit, of each engine parameter this
  /// variant does not expose but fixes (a four-band EQ's band frequencies in
  /// the racks that show only the gains), by parameter index.
  final Map<int, double> fixed;

  /// The parameter key a variant shows instead of the kind's own, by index
  /// (a parametric EQ's single band is "Mid", not "Lo mid").
  final Map<int, String> labels;

  /// The parameter as the rack shows it, by index, where its range is
  /// narrower than the kind's (the Pitch Shift's -12..+12 semitones in 25
  /// steps on the octaver's -24..+24). It is also the rack's own scale: a
  /// preset value is read on it (its [FxParamInfo.defaultValue] when the
  /// preset lacks the key), so it needs no entry in [scales]. Its control
  /// works in this parameter's settings and writes the kind's setting for
  /// the same value ([fxEntryParam], [fxEntryShownSetting],
  /// [fxEntryKindSetting]).
  final Map<int, FxParamInfo> shown;

  /// The rack path this variant runs on, or `null` for none: in series, as
  /// every module outside the Dub Rack's paths.
  final FxModulePath? path;

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

/// What a rack control applies at each setting (see
/// [FxModuleBuild.scales]).
class FxSourceScale {
  /// `min * (max / min) ^ v`.
  const FxSourceScale.log(this.min, this.max) : log = true, points = const [];

  /// `min + (max - min) * v`.
  const FxSourceScale.linear(this.min, this.max)
    : log = false,
      points = const [];

  /// Straight lines through measured `(setting, value)` [points], in
  /// setting order from 0 to 1.
  const FxSourceScale.table(this.points) : min = 0, max = 0, log = false;

  /// The value at 0, unless [points] is set.
  final double min;

  /// The value at 1, unless [points] is set.
  final double max;

  /// Whether the scale is logarithmic.
  final bool log;

  /// The measured points of a table scale, or empty.
  final List<(double, double)> points;

  /// The value setting [v] (clamped to `0..1`) stands for.
  double valueAt(double v) {
    final c = v.clamp(0.0, 1.0);
    if (points.isEmpty) {
      return log ? min * math.pow(max / min, c) : min + (max - min) * c;
    }
    var i = 1;
    while (i < points.length - 1 && c > points[i].$1) {
      i++;
    }
    final (x0, y0) = points[i - 1];
    final (x1, y1) = points[i];
    return y0 + (y1 - y0) * (c - x0) / (x1 - x0);
  }
}

/// The rack variants of the Looper X modules, by module and family: one engine
/// kind per module (a Looper X kind, or for the Pitch Shift the octaver), each
/// variant exposing the controls its racks show
/// (docs/plan/2026-10-20-looperx-derived-tables.md) and fixing the rest:
/// - the EQ and the compressor: at the values measured on the Looper X
///   (#891, docs/plan/2026-10-23-looperx-eq-measured.md and
///   docs/plan/2026-10-23-looperx-dynamics-measured.md), with each control
///   read as the value it applies, which is not always the value the
///   Looper X shows;
/// - the doubler: where a rack hides its separation, 50 % (the Studio and
///   Vocal racks' copies reach the 51 ms of the Dub Rack's 50 %, #1445);
/// - the distortion: where a rack hides it, the tone flat (50 %, chosen).
///
/// The first variant of each module is its default, the one "Add an effect"
/// uses (#887: Ed's 4-band, the Dub Rack's Para, Ed's compressor, the Dub
/// Rack's doubler, the Lo-Fi Rack's distortion).
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
  'Compressor': {
    "Ed's Rack": _edsComp,
    'Drum Rack': _drumComp,
    'Dub Rack': _dubComp,
    'Studio Rack': _vocalComp,
    'Vocal Rack': _vocalComp,
    'Vocal Tuner Rack': _vocalComp,
  },
  'Transient': {'Drum Rack': _transient},
  'High-pass gate': {
    'Vocal Rack': _hpGate,
    'Vocal Tuner Rack': _hpGate,
  },
  'Doubler': {
    'Dub Rack': _dubDoubler,
    'Studio Rack': _doubler,
    'Vocal Rack': _doubler,
    'Vocal Tuner Rack': _doubler,
  },
  'Chorus': {"Ed's Rack": _chorus},
  'Wah': {"Ed's Rack": _wah, 'Guitar Rack': _wah},
  'Overdrive': {"Ed's Rack": _overdrive, 'Guitar Rack': _overdrive},
  'Distortion': {'Lo-Fi Rack': _loFiDistortion, 'Studio Rack': _distortion},
  'Vinyl': {'Lo-Fi Rack': _vinyl},
  'Degrade': {'Lo-Fi Rack': _degrade},
  'Low-pass filter': {'Rhythmic Rack': _rhythmicLpf, 'Lo-Fi Rack': _lpf},
  'Spring reverb': {'Guitar Rack': _spring},
  'Dub delay': {'Dub Rack': _dubDelay},
  'Dub reverb': {'Dub Rack': _dubVerb},
  'Ambience': {'Dub Rack': _ambVerb},
  'Whammy': {'Guitar Rack': _whammy},
  'Pumper': {'Rhythmic Rack': _pumper},
  'Slicer': {'Rhythmic Rack': _slicer},
  'Octaver': {"Ed's Rack": _dualOctaver},
  'Amp': {"Ed's Rack": _ampCab, 'Guitar Rack': _ampCab},
  'Modulation': {'Guitar Rack': _guitarMod, 'Studio Rack': _studioMod},
  'Delay': {
    "Ed's Rack": _modeDelay,
    'Drum Rack': _drumDelay,
    'Guitar Rack': _modeDelay,
    'Lo-Fi Rack': _modeDelay,
    'Rhythmic Rack': _modeDelay,
    'Studio Rack': _modeDelay,
    'Vocal Rack': _modeDelay,
    'Vocal Tuner Rack': _modeDelay,
  },
  'Pitch shift': {'Studio Rack': _pitchShift, 'Vocal Rack': _pitchShift},
  // Vocal before Ed's: their reverbs carry the same keys, and an entry
  // outside its rack that cannot tell them apart keeps a Mode that works.
  'Reverb': {
    'Vocal Rack': _modeVerbBright,
    "Ed's Rack": _edsVerb,
    'Vocal Tuner Rack': _modeVerbBright,
    'Studio Rack': _modeVerb,
    'Rhythmic Rack': _modeVerb,
    'Drum Rack': _drumVerb,
  },
};

// The Room reverb's modes as the racks show them: HALL, STADIUM, ROOM and
// BOX, the kind's first four rooms. A preset stores one of four positions.
const FxParamInfo _verbMode = FxParamInfo(
  key: 'room_mode',
  unit: FxParamUnit.choice,
  steps: 4,
  atMin: 0,
  atMax: 3 / 15,
  defaultValue: 0,
);

// Vocal and Vocal Tuner racks: Length, Mix, the mode and Bright.
const FxModuleBuild _modeVerbBright = FxModuleBuild(
  type: TrackEffectType.roomVerb,
  params: ['Rev Length', 'Rev Mix', 'Rev Mode', 'Rev Bright'],
  shown: {2: _verbMode},
  labels: {2: 'room_mode'},
);

// Studio and Rhythmic racks: Length, Mix and the mode, with Bright at the
// 75 % their captures read (#891 s6rev 48-53, s14: the two racks' HALL is
// the same to the sample).
const FxModuleBuild _modeVerb = FxModuleBuild(
  type: TrackEffectType.roomVerb,
  params: ['Rev Length', 'Rev Mix', 'Rev Mode'],
  fixed: {3: 75},
  shown: {2: _verbMode},
  labels: {2: 'room_mode'},
);

// Ed's Rack: Length, Mix and Bright on HALL. Its Rev Mode does not reach
// the sound on the Looper X (#1476: the four modes, chosen live or loaded
// from a preset, play HALL to -139 dB), so it stays unmapped.
const FxModuleBuild _edsVerb = FxModuleBuild(
  type: TrackEffectType.roomVerb,
  params: ['Rev Length', 'Rev Mix', null, 'Rev Bright'],
  unmapped: ['Rev Mode'],
  fixed: {2: 0},
);

// Drum Rack: Length, Mix, the ER room, Lo/Hi, Tail/ER and Density. The
// rack's list has 15 rooms; the last three (OPERA HOUSE, VINTAGE 1,
// VINTAGE 2) are off the Looper X's screen and unmeasured, so ours lists
// the 12 before them, the kind's rooms 4 to 15, and a preset's stored 12
// to 14 (of 15 positions) reads as the last, CHURCH.
const FxModuleBuild _drumVerb = FxModuleBuild(
  type: TrackEffectType.roomVerb,
  params: [
    'Rev Length',
    'Rev Mix',
    'Rev ER',
    null,
    'Rev Lo/Hi',
    'Rev Tail/ER',
    'Rev Density',
  ],
  scales: {
    2: FxSourceScale.table([(0, 4 / 15), (11 / 14, 1), (1, 1)]),
  },
  shown: {
    2: FxParamInfo(
      key: 'er_room',
      unit: FxParamUnit.choice,
      steps: 12,
      atMin: 4 / 15,
      atMax: 1,
      defaultValue: 7 / 11,
    ),
  },
  labels: {2: 'er_room'},
);

// Studio and Vocal racks: the shift and the mix, on the octaver's phase
// vocoder with the tone open. The shift reads -12..+12 semitones in whole
// steps (linear), the rack's own range, inside the octaver's +-24, and
// starts at unison. The formants move with the pitch: measured on the Looper
// X (#891, docs/plan/2026-10-23-looperx-gaps-measured.md), the Studio Rack's
// Pitch pedal and the Whammy move the spectral envelope by the pitch ratio to
// within 1 % at 0, +-6 and +-12 semitones, a resampling-type shifter; the
// Vocal Rack's pedal is the same Pitch shift module. Its +12 lands 8 cents
// sharp there (ratio 2.009), which this keeps at the display's 2.0.
const FxModuleBuild _pitchShift = FxModuleBuild(
  type: TrackEffectType.octaver,
  params: ['Pitch Shift', null, 'Pitch Mix'],
  fixed: {1: 100, 3: 0, 4: 1},
  shown: {
    0: FxParamInfo(
      key: 'shift',
      unit: FxParamUnit.semitones,
      steps: 25,
      atMin: -12,
      atMax: 12,
      defaultValue: 0.5,
    ),
  },
);

// Dub Rack: the whole Dub delay, on the Mode delay's Dub position (#1473),
// on the Dub path. It passes echoes only (#891), so its mix is held at
// 100 %: the path's dry is the rack's paths' to give.
const FxModuleBuild _dubDelay = FxModuleBuild(
  type: TrackEffectType.modeDelay,
  params: [
    'Del Time',
    'Del Feedback',
    null,
    null,
    null,
    'Del Damp',
    'Del L/R Ratio',
    'Del Reso',
    'Del Res-Freq',
  ],
  fixed: {2: 100, 3: _dubDelayMode},
  path: FxModulePath.dub,
);

// Ed's and Guitar racks: the whole Amp, its four controls and the cabinet.
const FxModuleBuild _ampCab = FxModuleBuild(
  type: TrackEffectType.ampCab,
  params: ['Amp Drive', 'Amp Bass', 'Amp Treble', 'Amp Modern', 'Cab'],
);

// Guitar Rack: the whole Mod, its rate, depth, mix and mode. The rack's
// modes are the kind's first three (CHORUS, PHASER, FLANGER), so its control
// shows those and a preset's 0, 0.5 and 1 land on them.
const FxModuleBuild _guitarMod = FxModuleBuild(
  type: TrackEffectType.mod,
  params: ['Mod Rate', 'Mod Depth', 'Mod Mix', 'Mod Mode'],
  shown: {
    3: FxParamInfo(
      key: 'mod_mode',
      unit: FxParamUnit.choice,
      steps: 3,
      atMin: 0,
      atMax: 2 / 3,
      defaultValue: 0,
    ),
  },
);

// Studio Rack: rate, depth and mode, Chorus or Tremolo (the kind's first
// and last). It shows no mix: its chorus is the Guitar Rack's at 50 %
// (#891, the voice at the same share of the dry). Its Doubler Mix belongs
// to the Doubler module.
const FxModuleBuild _studioMod = FxModuleBuild(
  type: TrackEffectType.mod,
  params: ['Mod Rate', 'Mod Depth', null, 'Mod Mode'],
  fixed: {2: 50},
  shown: {
    3: FxParamInfo(
      key: 'studio_mod_mode',
      unit: FxParamUnit.choice,
      steps: 2,
      atMin: 0,
      atMax: 1,
      defaultValue: 0,
    ),
  },
);

// Ed's Rack: the whole Dual Octaver, high mode, both octaves' levels and
// the mix.
const FxModuleBuild _dualOctaver = FxModuleBuild(
  type: TrackEffectType.dualOctaver,
  params: ['Oct High Mode', 'Octave 1 Vol', 'Octave Mix', 'Octave 2 Vol'],
);

// The kind's Drum and Dub positions, its last two of fourteen.
const double _drumDelayMode = 12 / 13;
const double _dubDelayMode = 1;

// The seven racks with the Looper X's mode delay: time (a note value),
// feedback, mix and mode. Their mode shows the kind's first twelve, the
// Looper X's twelve.
const FxModuleBuild _modeDelay = FxModuleBuild(
  type: TrackEffectType.modeDelay,
  params: ['Del Time', 'Del Feedback', 'Del Mix', 'Del Mode'],
  shown: {
    3: FxParamInfo(
      key: 'delay_mode',
      unit: FxParamUnit.choice,
      steps: 12,
      atMin: 0,
      atMax: 11 / 13,
      defaultValue: 0,
    ),
  },
);

// Drum Rack: time, feedback, mix and Freq, on the Drum's own delay (#1473).
const FxModuleBuild _drumDelay = FxModuleBuild(
  type: TrackEffectType.modeDelay,
  params: ['Del Time', 'Del Feedback', 'Del Mix', null, 'Del Freq'],
  fixed: {3: _drumDelayMode},
);

// Dub Rack: the whole Dub-Verb, decay and volume, on the Dub path.
const FxModuleBuild _dubVerb = FxModuleBuild(
  type: TrackEffectType.dubVerb,
  params: ['Dub-Verb Dec', 'Dub-Verb Vol'],
  path: FxModulePath.dub,
);

// Dub Rack: the Amb-Verb's decay and volume (the source spells its volume key
// in lower case) and the rack's Amb-Dub Mix, which the source groups with
// it and which mixes the rack's two paths. On the Amb path.
const FxModuleBuild _ambVerb = FxModuleBuild(
  type: TrackEffectType.ambVerb,
  params: ['Amb-Verb Dec', 'Amb-verb Vol', 'Amb-Dub Mix'],
  path: FxModulePath.amb,
);

// Rhythmic Rack: the whole Pumper, rate (a note value) and depth.
const FxModuleBuild _pumper = FxModuleBuild(
  type: TrackEffectType.pumper,
  params: ['Pumper Rate', 'Pumper Depth'],
);

// Rhythmic Rack: the whole Slicer, pattern, step (a note value) and mix.
const FxModuleBuild _slicer = FxModuleBuild(
  type: TrackEffectType.slicer,
  params: ['Slic Patt', 'Slic Step Len', 'Slic Mix'],
);

// Guitar Rack: the whole Whammy, pedal and range.
const FxModuleBuild _whammy = FxModuleBuild(
  type: TrackEffectType.whammy,
  params: ['Whammy Pedal', 'Whammy Range'],
);

// Guitar Rack: the whole spring.
const FxModuleBuild _spring = FxModuleBuild(
  type: TrackEffectType.spring,
  params: ['Spring Time', 'Spring Mix'],
);

// Lo-Fi Rack: the whole vinyl.
const FxModuleBuild _vinyl = FxModuleBuild(
  type: TrackEffectType.vinyl,
  params: ['Vinyl Drive', 'Vinyl Freq', 'Vinyl Noise', 'Vinyl Noise-Tone'],
);

// Lo-Fi Rack: the whole degrade.
const FxModuleBuild _degrade = FxModuleBuild(
  type: TrackEffectType.degrade,
  params: ['Degrade Freq', 'Degrade Filter', 'Degrade Mix'],
);

// Lo-Fi Rack: cutoff and resonance.
const FxModuleBuild _lpf = FxModuleBuild(
  type: TrackEffectType.lpf,
  params: ['LPF Cutoff', 'LPF Reso'],
);

// Rhythmic Rack: cutoff and resonance, and the LFO over the cutoff (depth,
// and rate, a note value).
const FxModuleBuild _rhythmicLpf = FxModuleBuild(
  type: TrackEffectType.lpf,
  params: ['LPF Cutoff', 'LPF Reso', 'LPF LFO Depth', 'LPF LFO Rate'],
);

// Lo-Fi Rack: drive and tone.
const FxModuleBuild _loFiDistortion = FxModuleBuild(
  type: TrackEffectType.distortion,
  params: ['Dist Drive', 'Dist Tone'],
);

// Studio Rack: the drive, the tone flat.
const FxModuleBuild _distortion = FxModuleBuild(
  type: TrackEffectType.distortion,
  params: ['Dist Drive'],
  fixed: {1: 50},
);

// Ed's and Guitar racks: drive and tone.
const FxModuleBuild _overdrive = FxModuleBuild(
  type: TrackEffectType.overdrive,
  params: ['OD Drive', 'OD Tone'],
);

// Dub Rack: mix and separation, on the Dub path.
const FxModuleBuild _dubDoubler = FxModuleBuild(
  type: TrackEffectType.doubler,
  params: ['Doubler Mix', 'Doubler Sep'],
  path: FxModulePath.dub,
);

// Studio, Vocal and Vocal Tuner racks: the mix, the separation held at
// 50 %, where the Dub Rack's copies reach as far as these racks' do
// (#1445: 49 ms against 51).
const FxModuleBuild _doubler = FxModuleBuild(
  type: TrackEffectType.doubler,
  params: ['Doubler Mix'],
  fixed: {1: 50},
);

// Ed's Rack: the whole chorus.
const FxModuleBuild _chorus = FxModuleBuild(
  type: TrackEffectType.chorus,
  params: ['Chor Rate', 'Chor Depth', 'Chor Mix'],
);

// Ed's and Guitar racks: the pedal.
const FxModuleBuild _wah = FxModuleBuild(
  type: TrackEffectType.wah,
  params: ['Wah Pedal'],
);

// The make-up every rack applies: its control shows 0..30 dB, linear, and
// applies this, the same in every rack and at every threshold (#891).
const FxSourceScale _makeUp = FxSourceScale.table([
  (0, 0),
  (0.06, 3.25),
  (0.106, 6.16),
  (0.2, 10.08),
  (0.303, 12.86),
  (0.4, 14.8),
  (0.5, 16.32),
  (0.6, 17.53),
  (0.75, 19.08),
  (0.8, 19.52),
  (0.9, 20.34),
  (1, 21.07),
]);

// Ed's Rack: the whole compressor.
const FxModuleBuild _edsComp = FxModuleBuild(
  type: TrackEffectType.compressor,
  params: [
    'Comp Thresh',
    'Comp Ratio',
    'Comp Attack',
    'Comp Release',
    'Comp Make-Up',
  ],
  scales: {4: _makeUp},
);

// Drum Rack: threshold, attack on its own 0.1 to 300 ms scale, make-up; a
// hidden 4 : 1 ratio and 45 ms release (measured).
const FxModuleBuild _drumComp = FxModuleBuild(
  type: TrackEffectType.compressor,
  params: ['Comp Thresh', null, 'Comp Attack', null, 'Comp Make-Up'],
  scales: {2: FxSourceScale.log(0.1, 300), 4: _makeUp},
  fixed: {1: 4, 3: 45},
);

// Studio, Vocal and Vocal Tuner racks: threshold and make-up; a hidden
// 4 : 1 ratio, 1.5 ms attack and 65 ms release (measured).
const FxModuleBuild _vocalComp = FxModuleBuild(
  type: TrackEffectType.compressor,
  params: ['Comp Thresh', null, null, null, 'Comp Make-Up'],
  scales: {4: _makeUp},
  fixed: {1: 4, 2: 1.5, 3: 65},
);

// Dub Rack: threshold and make-up; a hidden 6 : 1 ratio, 1 ms attack and
// 80 ms release (measured).
const FxModuleBuild _dubComp = FxModuleBuild(
  type: TrackEffectType.compressor,
  params: ['Comp Thresh', null, null, null, 'Comp Make-Up'],
  scales: {4: _makeUp},
  fixed: {1: 6, 2: 1, 3: 80},
);

// Drum Rack: the whole transient shaper.
const FxModuleBuild _transient = FxModuleBuild(
  type: TrackEffectType.transient,
  params: ['Attack', 'Attack Length', 'Sustain'],
);

// Vocal and Vocal Tuner racks: the whole high-pass gate.
const FxModuleBuild _hpGate = FxModuleBuild(
  type: TrackEffectType.hpGate,
  params: ['Highpass', 'Gate Thresh'],
);

// The EQ layouts (the kind's "layout" choice).
const double _layoutShelves = 0;
const double _layoutCuts = 1;
const double _layoutBells = 2;

// Ed's Rack: every control of the generic EQ, four bells and both cuts. Its
// Lo Mid and Hi Mid frequencies apply 40..8000 and 120..16000 Hz (it shows
// 100..8000 Hz for both). Its High frequency and Low and High Q need no
// scale: the kind's ranges are what they apply.
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
  scales: {5: FxSourceScale.log(40, 8000), 8: FxSourceScale.log(120, 16000)},
  fixed: {14: _layoutCuts},
);

// Drum Rack: a low shelf at 200 Hz (Q 0.5) and a high shelf at 4 kHz
// (Q 0.7), each applying 2/3 of the gain its control shows, a swept mid bell
// at Q 0.9, and no cuts.
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
  scales: {
    1: FxSourceScale.linear(-12, 12),
    5: FxSourceScale.log(40, 8000),
    10: FxSourceScale.linear(-12, 12),
  },
  fixed: {2: 200, 3: 0.5, 6: 0.9, 7: 0, 11: 4000, 12: 0.7, 14: _layoutShelves},
  labels: {4: 'mid_gain', 5: 'mid_freq'},
);

// Studio, Vocal and Vocal Tuner racks: four gains, on bells at 300, 900,
// 2700 and 8100 Hz (Q 3.6, 1.2, 1.2 and 3.6), and no cuts.
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
    'EQ High',
    null,
    null,
    'EQ Air',
  ],
  fixed: {
    2: 300,
    3: 3.6,
    5: 900,
    6: 1.2,
    8: 2700,
    9: 1.2,
    11: 8100,
    12: 3.6,
    14: _layoutBells,
  },
  labels: {4: 'mid_gain', 7: 'high_gain', 10: 'air_gain'},
);

// Dub and Lo-Fi racks: low cut, one bell, high cut. The Looper X's Dub Rack
// holds its bell at 2 kHz and lets Mid Freq set the gain; here Mid Freq
// moves the frequency, as its label says (owner decision, #1429).
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
  fixed: {1: 0, 7: 0, 10: 0, 14: _layoutCuts},
  labels: {4: 'mid_gain', 5: 'mid_freq', 6: 'mid_q'},
);

// Rhythmic Rack: the parametric EQ with its Q hidden at 1.0 (measured).
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
  fixed: {1: 0, 6: 1, 7: 0, 10: 0, 14: _layoutCuts},
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
  if (variants == null) return const FxModuleBuild.unavailable();
  return variants[family] ?? variants.values.first;
}

/// The rack variant [entry] was built as, or `null` when it is not one: an
/// entry built from a module with variants ([kFxModuleVariants]) onto the
/// variant's own type (a Looper X kind, or the octaver a Pitch Shift runs
/// on). The variant is the one whose controls all
/// appear in the entry's [BuiltInEffect.source] (with the ones it knows it
/// drops, [FxModuleBuild.unmapped]), the one with the most of them first;
/// every factory preset of a family carries all of its keys, so this is the
/// family's own. An entry no variant fits is not one.
///
/// What a surface shows for a rack pedal: [FxModuleBuild.exposed], under
/// [FxModuleBuild.labels]. Any other entry shows every parameter of its type.
FxModuleBuild? fxEntryBuild(BuiltInEffect entry) =>
    (_entryBuilds[entry] ??= (build: _findEntryBuild(entry))).build;

/// [fxEntryBuild]'s answer per entry: every control of an editor resolves
/// it, on every build and drag event, and an entry never changes.
final Expando<({FxModuleBuild? build})> _entryBuilds = Expando();

FxModuleBuild? _findEntryBuild(BuiltInEffect entry) {
  final name = entry.module;
  if (name == null) return null;
  final variants = kFxModuleVariants[name];
  if (variants == null) return null;
  FxModuleBuild? build;
  var best = -1;
  for (final MapEntry(key: family, value: v) in variants.entries) {
    // The keys it places and the ones it knows it drops: the variant with
    // the most of them that the entry carries is its rack's (the Rhythmic
    // Rack's LPF, with its LFO keys, over the Lo-Fi Rack's). Where two
    // carry the same keys (Ed's and the Vocal Rack's reverbs), the one
    // whose family the entry's rack was built from.
    final keys = [...v.params.whereType<String>(), ...v.unmapped];
    if (!keys.every(entry.source.containsKey)) continue;
    final own =
        entry.rack?.art != null && kFxFamilySlugs[family] == entry.rack!.art;
    if (keys.length > best || (keys.length == best && own)) {
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

/// Parameter [index] of [entry] as its surface shows it: its rack variant's
/// narrowed parameter ([FxModuleBuild.shown]), or its type's own.
FxParamInfo fxEntryParam(BuiltInEffect entry, int index) =>
    fxEntryBuild(entry)?.shown[index] ?? entry.type.params[index];

/// [entry]'s parameter [index] as a setting of [fxEntryParam]: the setting
/// that stands for the same value as the kind's.
double fxEntryShownSetting(BuiltInEffect entry, int index) =>
    fxEntryShownSettingFor(entry, index, entry.params[index]);

/// The setting of [fxEntryParam] that stands for the same value as
/// [kindSetting], a setting of [entry]'s parameter [index] (the entry's own
/// or another one, such as a value about to be written to it). A setting
/// outside the shown range clamps to its end.
double fxEntryShownSettingFor(
  BuiltInEffect entry,
  int index,
  double kindSetting,
) {
  final shown = fxEntryBuild(entry)?.shown[index];
  if (shown == null) return kindSetting;
  return shown.settingFor(entry.type.params[index].valueAt(kindSetting));
}

/// The kind's setting for parameter [index] of [entry] that stands for the
/// same value as [shownSetting], a setting of [fxEntryParam].
double fxEntryKindSetting(BuiltInEffect entry, int index, double shownSetting) {
  final shown = fxEntryBuild(entry)?.shown[index];
  if (shown == null) return shownSetting;
  return entry.type.params[index].settingFor(shown.valueAt(shownSetting));
}

/// Builds one chain entry for [module] out of [preset]'s values.
///
/// Returns an entry whatever the readiness: a rack is what the player loaded,
/// not what this build can run, so an unavailable module still takes its place
/// in the chain and passes signal through untouched.
///
/// The entry's enabled bit follows the preset's own power key when it carries
/// one, and an added rack keeps it: the pedals arrive on or off as the preset
/// sets them, as the Looper X loads them.
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
    final shown = build.shown[i];
    final stored = key == null ? null : preset.params[key];
    final value = stored ?? shown?.defaultValue;
    if (value == null) continue;
    // A stored value is read on the rack's scale; the shown default is a
    // setting of the shown parameter.
    final scale = stored != null ? build.scales[i] : null;
    params[i] = scale != null
        ? type.params[i].settingFor(scale.valueAt(value))
        : shown != null
        ? type.params[i].settingFor(shown.valueAt(value))
        : value.clamp(0.0, 1.0);
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
