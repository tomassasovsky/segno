import 'dart:convert';
import 'dart:math' as math;

import 'package:meta/meta.dart';
import 'package:segno_engine/src/plugin_descriptor.dart';

/// The native `le_fx_type` code for a hosted plugin entry (`LE_FX_PLUGIN`).
/// A chain entry carrying this code plus a `plugin` key is a [PluginEffect];
/// every other code is a [BuiltInEffect].
const int kPluginFxCode = 8;

/// The maximum number of effects one chain can hold. The cap exists only so
/// the audio thread reads a fixed-size, allocation-free array — it is not a
/// CPU limit: the audio path iterates the ACTIVE count, and an unused slot
/// allocates no DSP state.
///
/// Sixty-four because the accepted FX design builds a chain out of RACKS, and
/// one factory rack is about six pedals. Mirrors the native `LE_FX_MAX`,
/// whose own note records what raising it cost.
const int kTrackEffectMax = 64;

/// The number of normalized (`0..1`) parameter cells each chain entry carries.
/// Mirrors the native `LE_FX_PARAMS`. A type uses the first
/// `type.params.length` of them; the rest stay 0 (see [canonicalEffectParams]).
///
/// Thirty-two since the Looper X kinds (#887 part 4): each carries its generic
/// module's whole parameter set, and the four-band EQ alone has fourteen.
const int kTrackEffectParams = 32;

/// The [kTrackEffectParams] cells an entry of [type] holds for [params]: the
/// given values for the parameters the type uses, its defaults for any the
/// list does not reach, and 0 past them.
///
/// Every [BuiltInEffect] holds its parameters in this shape, so two entries
/// that sound the same compare equal however their lists were built, and a
/// list saved by a narrower build (or trimmed by [BuiltInEffect.toJson])
/// decodes to the same entry.
List<double> canonicalEffectParams(
  TrackEffectType type,
  List<double>? params,
) {
  assert(
    params == null || params.length <= kTrackEffectParams,
    'an entry holds at most $kTrackEffectParams parameter cells',
  );
  final defaults = type.defaultParams;
  if (params == null) return defaults; // already canonical and unmodifiable
  final count = type.params.length;
  return List<double>.unmodifiable([
    for (var i = 0; i < kTrackEffectParams; i++)
      if (i >= count)
        0.0
      else if (i < params.length)
        params[i]
      else
        defaults[i],
  ]);
}

/// The ceiling of a chain entry's own level, [FxChannels.level]: `4.0`, about
/// +12 dB, the top of a factory rack's level. Mirrors the native
/// `LE_FX_LEVEL_MAX`.
const double kFxLevelMax = 4;

/// How one chain entry takes the pair it is handed (slice 3e) — the accepted
/// design's rack input choice, and a single effect's "Effect input".
enum FxChannelInput {
  /// The default: left and right as they arrive.
  stereo,

  /// The incoming left on both sides.
  left,

  /// The incoming right on both sides.
  right,

  /// Their average on both sides.
  monoSum;

  /// Maps an omitted value to [stereo] and rejects an invalid explicit value.
  static FxChannelInput fromWireName(Object? raw) {
    if (raw == null) return FxChannelInput.stereo;
    for (final v in values) {
      if (v.name == raw) return v;
    }
    throw const FormatException('invalid effect channel input');
  }
}

/// How one chain entry hands its result on. [stereo] keeps what the effects
/// made and the placement is a Balance; [mono] averages them and the placement
/// is a Pan.
enum FxChannelOutput {
  /// The default.
  stereo,

  /// Averaged to mono and placed.
  mono;

  /// Maps an omitted value to [stereo] and rejects an invalid explicit value.
  static FxChannelOutput fromWireName(Object? raw) {
    if (raw == null) return FxChannelOutput.stereo;
    for (final value in values) {
      if (value.name == raw) return value;
    }
    throw const FormatException('invalid effect channel output');
  }
}

/// One chain entry's channel handling and level (slice 3e).
///
/// The accepted design puts these around each instance: the [input] choice
/// before its effects, the [output] choice and then the [level] after them.
/// [placement] is a Balance when [output] is stereo and a Pan when it is mono,
/// on the one unity-centre law the lanes, monitors and output buses use — so
/// [defaults] is bit-identical to no channel handling at all, and is omitted
/// from a persisted entry.
@immutable
final class FxChannels {
  /// Creates an [FxChannels].
  const FxChannels({
    this.input = FxChannelInput.stereo,
    this.output = FxChannelOutput.stereo,
    this.placement = 0,
    this.level = 1,
  });

  /// Rebuilds an [FxChannels] from its [toJson] map. Omitted fields use their
  /// defaults; invalid explicit fields reject the saved chain.
  factory FxChannels.fromJson(Map<String, dynamic> json) {
    final placement = json['placement'];
    final level = json['level'];
    if ((json.containsKey('input') && json['input'] == null) ||
        (json.containsKey('output') && json['output'] == null) ||
        (json.containsKey('placement') &&
            (placement is! num ||
                !placement.isFinite ||
                placement < -1 ||
                placement > 1)) ||
        (json.containsKey('level') &&
            (level is! num ||
                !level.isFinite ||
                level < 0 ||
                level > kFxLevelMax))) {
      throw const FormatException('invalid effect channels');
    }
    return FxChannels(
      input: FxChannelInput.fromWireName(json['input']),
      output: FxChannelOutput.fromWireName(json['output']),
      placement: placement is num ? placement.toDouble() : 0,
      level: level is num ? level.toDouble() : 1,
    );
  }

  /// Stereo in, stereo out, centre, unity — what an untouched entry carries.
  static const FxChannels defaults = FxChannels();

  /// What the entry's effects are handed.
  final FxChannelInput input;

  /// How the entry hands its result on.
  final FxChannelOutput output;

  /// Balance (stereo out) or Pan (mono out), `-1..1`, centre `0`.
  final double placement;

  /// The entry's own gain, applied last: `0..kFxLevelMax`, unity `1`.
  final double level;

  /// Whether this is [defaults] — the shape the engine reads as "nothing to
  /// do" and the wire omits.
  bool get isDefault => this == defaults;

  /// Returns a copy with the given fields replaced.
  FxChannels copyWith({
    FxChannelInput? input,
    FxChannelOutput? output,
    double? placement,
    double? level,
  }) => FxChannels(
    input: input ?? this.input,
    output: output ?? this.output,
    placement: placement ?? this.placement,
    level: level ?? this.level,
  );

  /// A JSON-friendly map for persistence.
  Map<String, dynamic> toJson() => {
    'input': input.name,
    'output': output.name,
    'placement': placement,
    'level': level,
  };

  @override
  bool operator ==(Object other) =>
      other is FxChannels &&
      other.input == input &&
      other.output == output &&
      other.placement == placement &&
      other.level == level;

  @override
  int get hashCode => Object.hash(input, output, placement, level);
}

/// The rack a chain entry belongs to.
///
/// The accepted design's chain is built out of RACKS — named groups of pedals
/// that the player adds, renames, reorders and removes as one thing. This
/// engine's chain is a flat run of entries, so the grouping rides the entries:
/// every module of one rack carries the same [id], and a run of entries
/// sharing an [id] IS that rack.
///
/// Denormalised on purpose. The chain crosses four persistence boundaries (a
/// session file, a performance arm snapshot, the settings store and the
/// repository's own maps) as one encoded list, and a field on the entry rides
/// all of them for free. A rename rewrites every module of the rack; that is
/// cheaper than a second structure that could fall out of step with the chain
/// it describes.
///
/// A `null` rack means a standalone single effect, which the accepted design
/// offers beside the racks and which is edited in its own direct editor.
@immutable
final class FxRack {
  /// Creates an [FxRack].
  const FxRack({required this.id, required this.name, this.art});

  /// Rebuilds an [FxRack] from [toJson] output, or `null` when the map does
  /// not carry the two fields that make a rack addressable.
  static FxRack? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final name = json['name'];
    if (id is! String || id.isEmpty || name is! String) return null;
    final art = json['art'];
    return FxRack(id: id, name: name, art: art is String ? art : null);
  }

  /// The rack's identity, shared by every module in it and unique within its
  /// chain. Minted when the rack is added and never rewritten, so a rename or
  /// a reorder leaves every binding that names this rack still pointing at it.
  final String id;

  /// The rack's name, which the player can change. Starts as the preset's own
  /// name; renaming it never touches the saved preset it came from.
  final String name;

  /// The catalogue artwork slug the card draws, or `null` when there is none.
  ///
  /// A plain string rather than a catalogue type: this package knows nothing
  /// about the asset catalogue, and a slug whose artwork has since gone simply
  /// draws nothing.
  final String? art;

  /// Returns a copy with the given fields replaced.
  FxRack copyWith({String? id, String? name, String? art}) =>
      FxRack(id: id ?? this.id, name: name ?? this.name, art: art ?? this.art);

  /// A JSON-friendly map for persistence.
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    if (art != null) 'art': art,
  };

  @override
  bool operator ==(Object other) =>
      other is FxRack &&
      other.id == id &&
      other.name == name &&
      other.art == art;

  @override
  int get hashCode => Object.hash(id, name, art);
}

/// Where one chain entry sits relative to the loop player.
///
/// The chain is ordered [pre] entries first, then [post] entries, so the split
/// is a single boundary index — the count of leading [pre] entries — and that
/// is the only thing the native engine is told (`a_fx_pre_count`).
///
/// - [pre]: the entry belongs to what the take plays back. On a hardware
///   input it is copied onto the lane at record; on a lane it is rendered from
///   the dry original and engaged at a loop boundary, so a track Stop stops
///   its tail with the recording.
/// - [post]: the entry runs downstream of the loop player, so a track Stop
///   leaves its tail to drain.
///
/// [post] is the wire default and is omitted from a persisted entry; a live
/// input's new entries are created [pre] by the surface that adds them, not by
/// this model.
enum FxPlacement {
  /// Recorded into the loop: part of the take's playable representation.
  pre,

  /// Downstream of the player: can ring after Stop.
  post;

  /// The canonical wire name.
  String get wireName => name;

  /// Maps an omitted value to [post] and rejects an invalid explicit value.
  static FxPlacement fromWireName(Object? raw) {
    if (raw == null) return FxPlacement.post;
    for (final value in values) {
      if (value.wireName == raw) return value;
    }
    throw const FormatException('invalid effect placement');
  }
}

/// The number of leading [FxPlacement.pre] entries in [chain].
///
/// Every chain that has crossed a repository write is partitioned pre-first,
/// so this is the whole split. A chain that is not partitioned (only reachable
/// from a hand-built list in a test) counts its leading run and nothing more,
/// which is exactly what the engine would see.
int fxPreCount(List<TrackEffect> chain) {
  var n = 0;
  while (n < chain.length && chain[n].placement == FxPlacement.pre) {
    n++;
  }
  return n;
}

/// A built-in effect type. The integer [code] matches the native
/// `le_fx_type` enum, and each type interprets its [kTrackEffectParams]
/// normalized parameters differently (see [params]).
enum TrackEffectType {
  /// The entry is bypassed.
  none(0, 'None'),

  /// Soft-clipping overdrive.
  drive(1, 'Drive'),

  /// Resonant low-pass filter.
  filter(2, 'Filter'),

  /// Feedback delay.
  delay(3, 'Delay'),

  /// Sine-LFO amplitude modulation.
  tremolo(4, 'Tremolo'),

  /// Pitch-shift octaver — shifts up or down, by octaves or smaller intervals.
  octaver(5, 'Octaver'),

  /// Tape-style echo with damped, smearing repeats.
  echo(6, 'Echo'),

  /// Schroeder/Freeverb room reverb — a dense, smooth decaying tail. Spreads a
  /// mono source into a stereo tail across the first two channels of its output
  /// route, so it is best placed last in a chain.
  reverb(7, 'Reverb'),

  /// The Looper X's generic EQ (#887 part 4): low cut, low shelf, two
  /// peaking mids, high shelf, air shelf and high cut. A factory rack exposes
  /// a subset of its fifteen parameters.
  eq(9, 'EQ'),

  /// The Looper X's compressor (#887 part 5): threshold, ratio, attack,
  /// release and make-up. Feed-forward and stereo-linked, hard knee.
  compressor(10, 'Compressor'),

  /// The Looper X's transient shaper (#887 part 5): attack, attack length
  /// and sustain, each neutral at 50 %.
  transient(11, 'Transient'),

  /// The Looper X's high-pass gate (#887 part 5): a 12 dB/octave high-pass,
  /// then a gate keyed on what it passes.
  hpGate(12, 'HP / Gate'),

  /// The Looper X's doubler (#887 part 6): two slowly drifting delayed
  /// copies of the input, panned apart by the separation.
  doubler(13, 'Doubler'),

  /// The Looper X's chorus (#887 part 6): one triangle-modulated voice per
  /// channel, low-passed, mixed with the dry signal.
  chorus(14, 'Chorus'),

  /// The Looper X's wah (#887 part 6): a resonant band-pass swept by the
  /// pedal.
  wah(15, 'Wah'),

  /// The Looper X's overdrive (#887 part 7): a clean part plus a clipped
  /// part whose gain the drive sets, then a tone filter; fit to the Guitar
  /// Rack's OvDrive.
  overdrive(16, 'Overdrive'),

  /// The Looper X's amp simulator at its defaults, which the Studio Rack
  /// labels Dist (#887 part 7): an asymmetric curve, then the 4x12"
  /// cabinet; fit to the Phase 0 amp captures.
  distortion(17, 'Distortion'),

  /// The Looper X's vinyl (#887 part 7): a high-pass, a roll-off, soft
  /// saturation, then hiss and crackle.
  vinyl(18, 'Vinyl'),

  /// The Looper X's degrade (#887 part 7): sample-rate reduction, filtered
  /// and mixed with the dry signal.
  degrade(19, 'Degrade'),

  /// The Looper X's low-pass filter (#887 part 7): resonant, 12 dB/octave.
  lpf(20, 'LPF');

  const TrackEffectType(this.code, this.label);

  /// The native `le_fx_type` integer.
  final int code;

  /// A short human-readable name for menus.
  final String label;

  /// Maps a native `le_fx_type` integer back to a [TrackEffectType]; unknown
  /// values fall back to [TrackEffectType.none].
  static TrackEffectType fromCode(int code) =>
      values.firstWhere((t) => t.code == code, orElse: () => none);

  /// This type's parameters, in order: a copy of the engine's descriptor table
  /// (`le_fx_param_info`, the `LE_FX_*_PARAMS` rows in `engine_fx.c`), with
  /// the same order and values. The list length is the number of parameters
  /// the type uses (`<=` [kTrackEffectParams]).
  ///
  /// The table is copied rather than read over FFI so widgets and binding
  /// labels can read it synchronously, with or without the native library.
  /// `fx_param_info_native_test.dart` compares this copy with the engine
  /// field by field.
  List<FxParamInfo> get params => switch (this) {
    TrackEffectType.none => const [],
    TrackEffectType.drive => const [
      // tanh pre-gain 1 + 29 v
      FxParamInfo(
        key: 'drive',
        unit: FxParamUnit.times,
        atMin: 1,
        atMax: 30,
        defaultValue: 0.5,
      ),
      FxParamInfo(
        key: 'level',
        unit: FxParamUnit.percent,
        atMin: 0,
        atMax: 100,
        defaultValue: 0.8,
      ),
    ],
    TrackEffectType.filter => const [
      // 20 * 900^v Hz, clamped to 0.45 x the sample rate
      FxParamInfo(
        key: 'cutoff',
        unit: FxParamUnit.hz,
        atMin: 20,
        atMax: 18000,
        curve: FxParamCurve.exponential,
        defaultValue: 0.5,
      ),
      FxParamInfo(
        key: 'resonance',
        unit: FxParamUnit.percent,
        atMin: 0,
        atMax: 100,
        defaultValue: 0.2,
      ),
    ],
    TrackEffectType.delay => const [
      FxParamInfo(
        key: 'time',
        unit: FxParamUnit.ms,
        atMin: 0,
        atMax: 1000,
        defaultValue: 0.35,
      ),
      FxParamInfo(
        key: 'feedback',
        unit: FxParamUnit.percent,
        atMin: 0,
        atMax: 95,
        defaultValue: 0.35,
      ),
      FxParamInfo(
        key: 'mix',
        unit: FxParamUnit.percent,
        atMin: 0,
        atMax: 100,
        defaultValue: 0.35,
      ),
    ],
    TrackEffectType.tremolo => const [
      FxParamInfo(
        key: 'rate',
        unit: FxParamUnit.hz,
        atMin: 0.1,
        atMax: 12,
        defaultValue: 0.3,
      ),
      FxParamInfo(
        key: 'depth',
        unit: FxParamUnit.percent,
        atMin: 0,
        atMax: 100,
        defaultValue: 0.7,
      ),
    ],
    TrackEffectType.octaver => const [
      // Whole semitones across +-2 octaves, unison at the centre position.
      FxParamInfo(
        key: 'shift',
        unit: FxParamUnit.semitones,
        steps: 49,
        atMin: -24,
        atMax: 24,
        defaultValue: 0.25,
      ),
      FxParamInfo(
        key: 'tone',
        unit: FxParamUnit.percent,
        atMin: 0,
        atMax: 100,
        defaultValue: 0.5,
      ),
      FxParamInfo(
        key: 'mix',
        unit: FxParamUnit.percent,
        atMin: 0,
        atMax: 100,
        defaultValue: 0.5,
      ),
      // Position 0 = phase vocoder, 1 = PSOLA.
      FxParamInfo(
        key: 'mode',
        unit: FxParamUnit.choice,
        steps: 2,
        atMin: 0,
        atMax: 1,
        defaultValue: 0,
      ),
    ],
    TrackEffectType.echo => const [
      FxParamInfo(
        key: 'time',
        unit: FxParamUnit.ms,
        atMin: 0,
        atMax: 1000,
        defaultValue: 0.45,
      ),
      FxParamInfo(
        key: 'feedback',
        unit: FxParamUnit.percent,
        atMin: 0,
        atMax: 97,
        defaultValue: 0.5,
      ),
      FxParamInfo(
        key: 'mix',
        unit: FxParamUnit.percent,
        atMin: 0,
        atMax: 100,
        defaultValue: 0.35,
      ),
    ],
    // The Looper X ranges, except the two mid frequencies, which span every
    // rack's own range (taper unverified). Ed's 4-band EQ's defaults.
    TrackEffectType.eq => const [
      FxParamInfo(
        key: 'low_cut',
        unit: FxParamUnit.hz,
        atMin: 20,
        atMax: 8000,
        curve: FxParamCurve.exponential,
        defaultValue: 0.21,
      ),
      FxParamInfo(
        key: 'low_gain',
        unit: FxParamUnit.db,
        atMin: -18,
        atMax: 18,
        defaultValue: 0.5,
      ),
      FxParamInfo(
        key: 'low_freq',
        unit: FxParamUnit.hz,
        atMin: 20,
        atMax: 1000,
        curve: FxParamCurve.exponential,
        defaultValue: 0.384476,
      ),
      FxParamInfo(
        key: 'low_q',
        unit: FxParamUnit.q,
        atMin: 0.4,
        atMax: 2,
        curve: FxParamCurve.exponential,
        defaultValue: 0,
      ),
      FxParamInfo(
        key: 'lo_mid_gain',
        unit: FxParamUnit.db,
        atMin: -18,
        atMax: 18,
        defaultValue: 0.5,
      ),
      FxParamInfo(
        key: 'lo_mid_freq',
        unit: FxParamUnit.hz,
        atMin: 20,
        atMax: 20000,
        curve: FxParamCurve.exponential,
        defaultValue: 0.3445,
        taperUnverified: true,
      ),
      FxParamInfo(
        key: 'lo_mid_q',
        unit: FxParamUnit.q,
        atMin: 0.4,
        atMax: 10,
        curve: FxParamCurve.exponential,
        defaultValue: 0.174,
      ),
      FxParamInfo(
        key: 'hi_mid_gain',
        unit: FxParamUnit.db,
        atMin: -18,
        atMax: 18,
        defaultValue: 0.5,
      ),
      FxParamInfo(
        key: 'hi_mid_freq',
        unit: FxParamUnit.hz,
        atMin: 20,
        atMax: 20000,
        curve: FxParamCurve.exponential,
        defaultValue: 0.652,
        taperUnverified: true,
      ),
      FxParamInfo(
        key: 'hi_mid_q',
        unit: FxParamUnit.q,
        atMin: 0.4,
        atMax: 10,
        curve: FxParamCurve.exponential,
        defaultValue: 0.15557,
      ),
      FxParamInfo(
        key: 'high_gain',
        unit: FxParamUnit.db,
        atMin: -18,
        atMax: 18,
        defaultValue: 0.5,
      ),
      FxParamInfo(
        key: 'high_freq',
        unit: FxParamUnit.hz,
        atMin: 2000,
        atMax: 16000,
        curve: FxParamCurve.exponential,
        defaultValue: 0.5278,
      ),
      FxParamInfo(
        key: 'high_q',
        unit: FxParamUnit.q,
        atMin: 0.4,
        atMax: 2,
        curve: FxParamCurve.exponential,
        defaultValue: 0,
      ),
      FxParamInfo(
        key: 'high_cut',
        unit: FxParamUnit.hz,
        atMin: 120,
        atMax: 20000,
        curve: FxParamCurve.exponential,
        defaultValue: 1,
      ),
      FxParamInfo(
        key: 'air_gain',
        unit: FxParamUnit.db,
        atMin: -18,
        atMax: 18,
        defaultValue: 0.5,
      ),
    ],
    // The Looper X ranges and tapers (#887 part 5); the ratio's is its own
    // reciprocal taper. Ed's Rack's defaults.
    TrackEffectType.compressor => const [
      FxParamInfo(
        key: 'threshold',
        unit: FxParamUnit.db,
        atMin: 0,
        atMax: -60,
        defaultValue: 0.35,
      ),
      FxParamInfo(
        key: 'ratio',
        unit: FxParamUnit.ratio,
        atMin: 1,
        atMax: 100,
        curve: FxParamCurve.reciprocal,
        defaultValue: 0.76,
      ),
      FxParamInfo(
        key: 'attack',
        unit: FxParamUnit.ms,
        atMin: 0.01,
        atMax: 300,
        curve: FxParamCurve.exponential,
        defaultValue: 0.5,
      ),
      FxParamInfo(
        key: 'release',
        unit: FxParamUnit.ms,
        atMin: 5,
        atMax: 4000,
        curve: FxParamCurve.exponential,
        defaultValue: 0.5,
      ),
      FxParamInfo(
        key: 'makeup',
        unit: FxParamUnit.db,
        atMin: 0,
        atMax: 30,
        defaultValue: 0.06,
      ),
    ],
    // Shown as the Looper X shows them; what each percent does is chosen.
    TrackEffectType.transient => const [
      FxParamInfo(
        key: 'attack',
        unit: FxParamUnit.percent,
        atMin: 0,
        atMax: 100,
        defaultValue: 0.5,
        taperUnverified: true,
      ),
      FxParamInfo(
        key: 'attack_length',
        unit: FxParamUnit.percent,
        atMin: 0,
        atMax: 100,
        defaultValue: 0.5,
        taperUnverified: true,
      ),
      FxParamInfo(
        key: 'sustain',
        unit: FxParamUnit.percent,
        atMin: 0,
        atMax: 100,
        defaultValue: 0.5,
        taperUnverified: true,
      ),
    ],
    // The Vocal Rack's defaults: the high-pass at 1 Hz, the gate at -120 dB.
    TrackEffectType.hpGate => const [
      FxParamInfo(
        key: 'highpass',
        unit: FxParamUnit.hz,
        atMin: 1,
        atMax: 1000,
        curve: FxParamCurve.exponential,
        defaultValue: 0,
      ),
      FxParamInfo(
        key: 'gate_threshold',
        unit: FxParamUnit.db,
        atMin: -120,
        atMax: 0,
        defaultValue: 0,
      ),
    ],
    // Shown as the Looper X shows them; what each percent does is chosen,
    // or for the chorus measured on the Guitar Rack's (#891). The Dub
    // Rack's doubler, Ed's chorus and Ed's wah defaults.
    TrackEffectType.doubler => const [
      FxParamInfo(
        key: 'mix',
        unit: FxParamUnit.percent,
        atMin: 0,
        atMax: 100,
        defaultValue: 1,
        taperUnverified: true,
      ),
      FxParamInfo(
        key: 'separation',
        unit: FxParamUnit.percent,
        atMin: 0,
        atMax: 100,
        defaultValue: 1,
        taperUnverified: true,
      ),
    ],
    TrackEffectType.chorus => const [
      FxParamInfo(
        key: 'rate',
        unit: FxParamUnit.percent,
        atMin: 0,
        atMax: 100,
        defaultValue: 0.45,
        taperUnverified: true,
      ),
      FxParamInfo(
        key: 'depth',
        unit: FxParamUnit.percent,
        atMin: 0,
        atMax: 100,
        defaultValue: 0.21,
        taperUnverified: true,
      ),
      FxParamInfo(
        key: 'mix',
        unit: FxParamUnit.percent,
        atMin: 0,
        atMax: 100,
        defaultValue: 0.5,
        taperUnverified: true,
      ),
    ],
    TrackEffectType.wah => const [
      FxParamInfo(
        key: 'pedal',
        unit: FxParamUnit.percent,
        atMin: 0,
        atMax: 100,
        defaultValue: 0.619,
        taperUnverified: true,
      ),
    ],
    // Fit to the Guitar Rack's OvDrive (#891): the drive's law is measured,
    // the tone's only at 50 %. Ed's Rack's defaults.
    TrackEffectType.overdrive => const [
      FxParamInfo(
        key: 'drive',
        unit: FxParamUnit.percent,
        atMin: 0,
        atMax: 100,
        defaultValue: 0.09,
      ),
      FxParamInfo(
        key: 'tone',
        unit: FxParamUnit.percent,
        atMin: 0,
        atMax: 100,
        defaultValue: 0.5,
        taperUnverified: true,
      ),
    ],
    // Fit to the amp captures (#891), the Studio Rack's Dist; the Lo-Fi
    // Rack's is taken to be the same module, so both carry the flag. The
    // Lo-Fi Rack's defaults.
    TrackEffectType.distortion => const [
      FxParamInfo(
        key: 'drive',
        unit: FxParamUnit.percent,
        atMin: 0,
        atMax: 100,
        defaultValue: 0.2,
        taperUnverified: true,
      ),
      FxParamInfo(
        key: 'tone',
        unit: FxParamUnit.percent,
        atMin: 0,
        atMax: 100,
        defaultValue: 0.5,
        taperUnverified: true,
      ),
    ],
    // The Looper X's ranges and tapers; what each control does is chosen
    // (#891). The Lo-Fi Rack's defaults.
    TrackEffectType.vinyl => const [
      FxParamInfo(
        key: 'drive',
        unit: FxParamUnit.percent,
        atMin: 0,
        atMax: 100,
        defaultValue: 0.4,
        taperUnverified: true,
      ),
      FxParamInfo(
        key: 'frequency',
        unit: FxParamUnit.hz,
        atMin: 50,
        atMax: 5000,
        curve: FxParamCurve.exponential,
        defaultValue: 0.35,
        taperUnverified: true,
      ),
      FxParamInfo(
        key: 'noise',
        unit: FxParamUnit.percent,
        atMin: 0,
        atMax: 100,
        defaultValue: 0.3,
        taperUnverified: true,
      ),
      FxParamInfo(
        key: 'noise_tone',
        unit: FxParamUnit.percent,
        atMin: 0,
        atMax: 100,
        defaultValue: 0.9,
        taperUnverified: true,
      ),
    ],
    TrackEffectType.degrade => const [
      FxParamInfo(
        key: 'frequency',
        unit: FxParamUnit.hz,
        atMin: 500,
        atMax: 50000,
        curve: FxParamCurve.exponential,
        defaultValue: 1,
        taperUnverified: true,
      ),
      FxParamInfo(
        key: 'filter',
        unit: FxParamUnit.percent,
        atMin: 0,
        atMax: 100,
        defaultValue: 1,
        taperUnverified: true,
      ),
      FxParamInfo(
        key: 'mix',
        unit: FxParamUnit.percent,
        atMin: 0,
        atMax: 100,
        defaultValue: 1,
        taperUnverified: true,
      ),
    ],
    TrackEffectType.lpf => const [
      FxParamInfo(
        key: 'cutoff',
        unit: FxParamUnit.hz,
        atMin: 20,
        atMax: 20000,
        curve: FxParamCurve.exponential,
        defaultValue: 1,
      ),
      FxParamInfo(
        key: 'resonance',
        unit: FxParamUnit.percent,
        atMin: 0,
        atMax: 100,
        defaultValue: 1,
        taperUnverified: true,
      ),
    ],
    TrackEffectType.reverb => const [
      // comb feedback 0.70 + 0.28 v; feedback low-pass 0.4 v
      FxParamInfo(
        key: 'size',
        unit: FxParamUnit.percent,
        atMin: 0,
        atMax: 100,
        defaultValue: 0.5,
      ),
      FxParamInfo(
        key: 'damping',
        unit: FxParamUnit.percent,
        atMin: 0,
        atMax: 100,
        defaultValue: 0.5,
      ),
      FxParamInfo(
        key: 'mix',
        unit: FxParamUnit.percent,
        atMin: 0,
        atMax: 100,
        defaultValue: 0.35,
      ),
    ],
  };

  /// The setting each of the [kTrackEffectParams] parameters starts at when
  /// the type is freshly engaged: each descriptor's
  /// [FxParamInfo.defaultValue], then 0 for the parameters the type does not
  /// use. The engine's `le_fx_defaults` reads the same table.
  List<double> get defaultParams => _defaultParams[this]!;

  static final Map<TrackEffectType, List<double>> _defaultParams = {
    for (final t in values)
      t: List<double>.unmodifiable([
        for (final p in t.params) p.defaultValue,
        for (var i = t.params.length; i < kTrackEffectParams; i++) 0.0,
      ]),
  };
}

/// The unit a built-in parameter's value is shown in. Mirrors the native
/// `le_fx_param_unit`; [code] is the native value.
enum FxParamUnit {
  /// 0..100 percent (`LE_FX_UNIT_PERCENT`).
  percent(0),

  /// Milliseconds (`LE_FX_UNIT_MS`).
  ms(1),

  /// Hertz (`LE_FX_UNIT_HZ`).
  hz(2),

  /// A pitch interval in semitones (`LE_FX_UNIT_SEMITONES`).
  semitones(3),

  /// A gain factor, shown with "x" (`LE_FX_UNIT_TIMES`).
  times(4),

  /// Named positions; the value is the position (`LE_FX_UNIT_CHOICE`).
  choice(5),

  /// Decibels (`LE_FX_UNIT_DB`).
  db(6),

  /// A filter's Q, a plain number (`LE_FX_UNIT_Q`).
  q(7),

  /// A compression ratio, "n : 1" (`LE_FX_UNIT_RATIO`).
  ratio(8);

  const FxParamUnit(this.code);

  /// The native `le_fx_param_unit` value.
  final int code;
}

/// How a built-in parameter's value follows its normalized setting. Mirrors
/// the native `le_fx_param_curve`; [code] is the native value.
enum FxParamCurve {
  /// `atMin + (atMax - atMin) * v` (`LE_FX_CURVE_LINEAR`).
  linear(0),

  /// `atMin * (atMax / atMin) ^ v` (`LE_FX_CURVE_EXPONENTIAL`).
  exponential(1),

  /// `1 / (1 / atMin + (1 / atMax - 1 / atMin) * v)`: the reciprocal is
  /// linear (`LE_FX_CURVE_RECIPROCAL`, the Looper X compressor's ratio).
  reciprocal(2);

  const FxParamCurve(this.code);

  /// The native `le_fx_param_curve` value.
  final int code;
}

/// One built-in effect parameter: what its normalized `0..1` setting means.
/// The Dart copy of the native `le_fx_param_desc`.
///
/// The setting itself lives on the chain entry (see [TrackEffect]); this
/// describes it: a stable [key] the app localizes the name by, the [unit] the
/// value is shown in, the mapping from setting to value ([atMin], [atMax],
/// [curve]), how many positions it snaps to ([steps]) and where a freshly
/// engaged effect starts ([defaultValue]).
@immutable
class FxParamInfo {
  /// Creates an [FxParamInfo].
  const FxParamInfo({
    required this.key,
    required this.unit,
    required this.atMin,
    required this.atMax,
    required this.defaultValue,
    this.steps = 0,
    this.curve = FxParamCurve.linear,
    this.taperUnverified = false,
  });

  /// The stable parameter key (`drive`, `cutoff`, `shift`, ...).
  final String key;

  /// The unit [valueAt] returns.
  final FxParamUnit unit;

  /// 0 for a continuous parameter, otherwise the number of positions a
  /// control snaps it to: position k of n stands for setting `k / (n - 1)`.
  /// The kernel reads a choice at its nearest position and every other
  /// parameter as set, so a setting between positions (from a dragged slider
  /// or an expression pedal) plays as set.
  final int steps;

  /// The value at setting 0.
  final double atMin;

  /// The value at setting 1.
  final double atMax;

  /// How the value follows the setting between [atMin] and [atMax].
  final FxParamCurve curve;

  /// The setting a freshly engaged effect starts at.
  final double defaultValue;

  /// Whether the mapping was chosen rather than measured against the effect
  /// it reproduces (the native `LE_FX_PARAM_TAPER_UNVERIFIED` flag).
  final bool taperUnverified;

  /// Whether the parameter snaps to [steps] positions.
  bool get isStepped => steps > 1;

  /// The value [setting] (clamped to `0..1`) stands for, mapped as the engine
  /// maps it: a choice first takes its nearest position, then [curve] runs
  /// from [atMin] to [atMax].
  double valueAt(double setting) {
    var v = setting.isNaN ? 0.0 : setting.clamp(0.0, 1.0);
    if (unit == FxParamUnit.choice && isStepped) {
      v = positionOf(v) / (steps - 1);
    }
    return switch (curve) {
      FxParamCurve.exponential => atMin * math.pow(atMax / atMin, v),
      FxParamCurve.reciprocal => 1 / (1 / atMin + (1 / atMax - 1 / atMin) * v),
      FxParamCurve.linear => atMin + (atMax - atMin) * v,
    };
  }

  /// The setting (`0..1`) that stands for [value], the inverse of [valueAt]
  /// for a continuous parameter; a value outside the range clamps.
  double settingFor(double value) {
    final v = switch (curve) {
      FxParamCurve.exponential =>
        math.log(value / atMin) / math.log(atMax / atMin),
      FxParamCurve.reciprocal =>
        (1 / value - 1 / atMin) / (1 / atMax - 1 / atMin),
      FxParamCurve.linear => (value - atMin) / (atMax - atMin),
    };
    return v.isNaN ? 0.0 : v.clamp(0.0, 1.0);
  }

  /// The position (`0..steps-1`) [setting] (clamped to `0..1`) snaps to.
  ///
  /// Throws a [StateError] for a continuous parameter, which has no positions.
  int positionOf(double setting) {
    if (!isStepped) throw StateError('$key is continuous');
    final v = setting.isNaN ? 0.0 : setting.clamp(0.0, 1.0);
    return (v * (steps - 1) + 0.5).floor();
  }

  @override
  bool operator ==(Object other) =>
      other is FxParamInfo &&
      other.key == key &&
      other.unit == unit &&
      other.steps == steps &&
      other.atMin == atMin &&
      other.atMax == atMax &&
      other.curve == curve &&
      other.defaultValue == defaultValue &&
      other.taperUnverified == taperUnverified;

  @override
  int get hashCode => Object.hash(
    key,
    unit,
    steps,
    atMin,
    atMax,
    curve,
    defaultValue,
    taperUnverified,
  );

  @override
  String toString() =>
      'FxParamInfo($key, ${unit.name}, steps: $steps, '
      '$atMin..$atMax ${curve.name}, default: $defaultValue'
      '${taperUnverified ? ', taper unverified' : ''})';
}

/// The identity of a hosted plugin in a chain entry: its [format], stable [id]
/// (VST3 TUID / CLAP descriptor id), and packed [version] (for drift
/// detection). This is enough to re-resolve and re-load the plugin from a
/// persisted chain; the variable parameter values and the opaque state blob
/// land in later parts.
@immutable
final class PluginRef {
  /// Creates a [PluginRef].
  const PluginRef({
    required this.format,
    required this.id,
    this.version = 0,
  });

  /// Rebuilds a [PluginRef] from its [toJson] map.
  factory PluginRef.fromJson(Map<String, dynamic> json) => PluginRef(
    format: PluginFormat.fromCode((json['format'] as num?)?.toInt() ?? 0),
    id: (json['id'] as String?) ?? '',
    version: (json['version'] as num?)?.toInt() ?? 0,
  );

  /// The plugin format.
  final PluginFormat format;

  /// The stable plugin id (VST3 TUID hex / CLAP descriptor id).
  final String id;

  /// Packed version `major << 16 | minor << 8 | patch`, or `0` if unknown.
  final int version;

  /// A JSON-friendly map for persistence.
  Map<String, dynamic> toJson() => {
    'format': format.code,
    'id': id,
    'version': version,
  };

  @override
  bool operator ==(Object other) =>
      other is PluginRef &&
      other.format == format &&
      other.id == id &&
      other.version == version;

  @override
  int get hashCode => Object.hash(format, id, version);
}

/// One entry in an effects chain — a sealed hierarchy of either a built-in DSP
/// effect ([BuiltInEffect]) or a hosted VST3/CLAP plugin ([PluginEffect]).
///
/// The recording is always dry and every active entry colors playback in
/// order. The same model backs a lane's record-route chain and a hardware
/// input's live-monitor chain. Each entry carries its own [placement], and the
/// chain is stored with every [FxPlacement.pre] entry ahead of every
/// [FxPlacement.post] one.
sealed class TrackEffect {
  /// Const base constructor for the sealed subtypes.
  const TrackEffect();

  /// Rebuilds a [TrackEffect] from a persisted entry, dual-decoding by shape: a
  /// `LE_FX_PLUGIN` ([kPluginFxCode]) entry carrying a `plugin` key is a
  /// [PluginEffect]; everything else is a [BuiltInEffect]. There is no envelope
  /// — a pre-plugin chain (an array of bare `{type, params}` entries) decodes
  /// unchanged. A plugin entry is NEVER silently dropped to `none`.
  factory TrackEffect.fromJson(Map<String, dynamic> json) {
    final code = (json['type'] as num?)?.toInt() ?? 0;
    if (code == kPluginFxCode && json['plugin'] is Map<String, dynamic>) {
      return PluginEffect.fromJson(json);
    }
    return BuiltInEffect.fromJson(json);
  }

  /// The native `le_fx_type` code for this entry.
  int get typeCode;

  /// Where this entry sits relative to the loop player.
  FxPlacement get placement;

  /// This entry's channel handling and level.
  FxChannels get channels;

  /// The rack this entry belongs to, or `null` when it is a standalone single
  /// effect. Every module of one rack carries the same [FxRack.id].
  FxRack? get rack;

  /// What the factory catalogue calls this entry, or `null` when it did not
  /// come from the catalogue.
  ///
  /// One string rather than a name and an artwork path, because the catalogue
  /// maps a module name to both. It is kept because the engine effect an entry
  /// became is not what the player chose: a pedal this build cannot process at
  /// all becomes a passthrough entry, and without its own name it would be
  /// indistinguishable from every other one.
  String? get module;

  /// A JSON-friendly map for persistence (codes, not enum names).
  Map<String, dynamic> toJson();
}

/// A built-in DSP effect: a [type] with its normalized [params].
@immutable
final class BuiltInEffect extends TrackEffect {
  /// Creates a [BuiltInEffect]. [params] defaults to the [type]'s musical
  /// defaults.
  BuiltInEffect({
    required this.type,
    List<double>? params,
    this.enabled = true,
    this.slotId,
    this.placement = FxPlacement.post,
    this.channels = FxChannels.defaults,
    this.rack,
    this.module,
    this.presetId,
    Map<String, double> source = const {},
  }) : params = canonicalEffectParams(type, params),
       source = Map<String, double>.unmodifiable(source);

  /// [copyWith] keeping [type]: [params] is already canonical for it.
  const BuiltInEffect._sameType({
    required this.type,
    required this.params,
    required this.enabled,
    required this.slotId,
    required this.placement,
    required this.channels,
    required this.rack,
    required this.module,
    required this.presetId,
    required this.source,
  });

  /// Rebuilds a [BuiltInEffect] from [toJson] output; unknown codes fall back
  /// to safe defaults. A legacy `stage` key (from the removed pre/post model)
  /// is ignored, so older persisted chains still decode.
  ///
  /// The decoded `params` go through [canonicalEffectParams], like any
  /// other list: a short one takes the type's defaults for the cells it does
  /// not reach, and cells past the type's parameters are dropped. A
  /// missing `enabled` decodes `true` (every pre-FX-v3 entry was audible —
  /// R15's "migration defaults every level to enabled"); a missing `slotId`
  /// stays null for the repository write boundary to mint (A9).
  factory BuiltInEffect.fromJson(Map<String, dynamic> json) {
    final type = TrackEffectType.fromCode((json['type'] as num?)?.toInt() ?? 0);
    // `is`-checks, not casts: a wrong-typed field in a corrupt persisted
    // chain must decode to the default, never throw a TypeError past
    // decodeTrackEffects' FormatException-only catch.
    final rawEnabled = json['enabled'];
    final enabled = rawEnabled is! bool || rawEnabled;
    final rawSlotId = json['slotId'];
    final slotId = rawSlotId is String ? rawSlotId : null;
    if (json.containsKey('placement') && json['placement'] == null) {
      throw const FormatException('invalid effect placement');
    }
    final placement = FxPlacement.fromWireName(json['placement']);
    final rawChannels = json['channels'];
    if (json.containsKey('channels') && rawChannels is! Map<String, dynamic>) {
      throw const FormatException('invalid effect channels');
    }
    final channels = rawChannels is Map<String, dynamic>
        ? FxChannels.fromJson(rawChannels)
        : FxChannels.defaults;
    final rack = FxRack.fromJson(json['rack']);
    final rawModule = json['module'];
    final module = rawModule is String ? rawModule : null;
    final rawPresetId = json['presetId'];
    final presetId = rawPresetId is String ? rawPresetId : null;
    final rawSource = json['source'];
    final source = <String, double>{
      if (rawSource is Map)
        for (final e in rawSource.entries)
          if (e.key is String && e.value is num)
            e.key as String: (e.value as num).toDouble(),
    };
    final rawParams = json['params'];
    if (rawParams is! List) {
      return BuiltInEffect(
        type: type,
        enabled: enabled,
        slotId: slotId,
        placement: placement,
        channels: channels,
        rack: rack,
        module: module,
        presetId: presetId,
        source: source,
      );
    }
    // Cells past the width cannot belong to any type: dropped, as a corrupt
    // or foreign file's extra cells are.
    final decoded = [
      for (final v in rawParams.take(kTrackEffectParams)) (v as num).toDouble(),
    ];
    return BuiltInEffect(
      type: type,
      params: decoded,
      enabled: enabled,
      slotId: slotId,
      placement: placement,
      channels: channels,
      rack: rack,
      module: module,
      presetId: presetId,
      source: source,
    );
  }

  /// The effect type.
  final TrackEffectType type;

  /// The normalized parameter values, in [canonicalEffectParams] shape:
  /// length [kTrackEffectParams], the type's parameters first, 0 after them.
  final List<double> params;

  /// Whether this entry is audible (R16): a disabled entry stays in the chain
  /// with its type and params intact but renders bit-exact passthrough. The
  /// engine receives the flag through the per-slot enable setters, never
  /// through the chain payload.
  final bool enabled;

  /// The entry's stable per-slot identity (A9), minted by the repository write
  /// boundary and never reused within a session; `null` until minted. Pure
  /// Dart-side passthrough — the C engine never parses it.
  final String? slotId;

  @override
  final FxPlacement placement;

  @override
  final FxChannels channels;

  @override
  final FxRack? rack;

  @override
  final String? module;

  /// The id of the factory preset this entry was built from, or `null` when
  /// it did not come from one.
  final String? presetId;

  /// The factory preset's own values for this entry's module, by the
  /// preset's parameter names. Kept whatever this build could do with them,
  /// so a later build can rebuild the module from what the player loaded.
  final Map<String, double> source;

  @override
  int get typeCode => type.code;

  /// Returns a copy with the given fields replaced. [params] is copied.
  ///
  /// A new [type] without new [params] starts at that type's defaults, as
  /// the engine seeds them on a type change: one type's settings mean
  /// nothing to another.
  BuiltInEffect copyWith({
    TrackEffectType? type,
    List<double>? params,
    bool? enabled,
    String? slotId,
    FxPlacement? placement,
    FxChannels? channels,
    FxRack? rack,
    String? module,
    String? presetId,
    Map<String, double>? source,
  }) => params == null && (type == null || type == this.type)
      ? BuiltInEffect._sameType(
          type: this.type,
          params: this.params,
          enabled: enabled ?? this.enabled,
          slotId: slotId ?? this.slotId,
          placement: placement ?? this.placement,
          channels: channels ?? this.channels,
          rack: rack ?? this.rack,
          module: module ?? this.module,
          presetId: presetId ?? this.presetId,
          source: source == null
              ? this.source
              : Map<String, double>.unmodifiable(source),
        )
      : BuiltInEffect(
          type: type ?? this.type,
          params: params ?? (type ?? this.type).defaultParams,
          enabled: enabled ?? this.enabled,
          slotId: slotId ?? this.slotId,
          placement: placement ?? this.placement,
          channels: channels ?? this.channels,
          rack: rack ?? this.rack,
          module: module ?? this.module,
          presetId: presetId ?? this.presetId,
          source: source ?? this.source,
        );

  @override
  Map<String, dynamic> toJson() => {
    'type': type.code,
    // Only the cells the type uses: the rest are 0 by construction, and
    // fromJson restores them.
    'params': params.sublist(0, type.params.length),
    // The keys below are omitted at their defaults, keeping the wire short.
    if (!enabled) 'enabled': false,
    if (slotId != null) 'slotId': slotId,
    if (placement != FxPlacement.post) 'placement': placement.wireName,
    if (!channels.isDefault) 'channels': channels.toJson(),
    if (rack != null) 'rack': rack!.toJson(),
    if (module != null) 'module': module,
    if (presetId != null) 'presetId': presetId,
    if (source.isNotEmpty) 'source': source,
  };

  @override
  bool operator ==(Object other) =>
      other is BuiltInEffect &&
      other.type == type &&
      other.enabled == enabled &&
      other.slotId == slotId &&
      other.placement == placement &&
      other.channels == channels &&
      other.rack == rack &&
      other.module == module &&
      other.presetId == presetId &&
      _listEquals(other.params, params) &&
      _sourceEquals(other.source, source);

  @override
  int get hashCode => Object.hash(
    type,
    enabled,
    slotId,
    placement,
    channels,
    rack,
    module,
    presetId,
    Object.hashAll(params),
    Object.hashAllUnordered([
      for (final e in source.entries) Object.hash(e.key, e.value),
    ]),
  );

  static bool _sourceEquals(Map<String, double> a, Map<String, double> b) {
    if (a.length != b.length) return false;
    for (final e in a.entries) {
      if (b[e.key] != e.value) return false;
    }
    return true;
  }

  static bool _listEquals(List<double> a, List<double> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// A hosted VST3/CLAP plugin in a chain entry, identified by its [ref].
///
/// Carries the plugin identity, the user-tweaked [paramValues] (persisted), the
/// opaque [state] blob (persisted, base64), and the live [params] metadata
/// enumerated from the loaded plugin (transient). An unresolved plugin (its
/// `ref` no longer matches an installed plugin) is still a [PluginEffect] —
/// never silently dropped — so its identity + state survive a reload (D-MISS).
@immutable
final class PluginEffect extends TrackEffect {
  /// Creates a [PluginEffect] for [ref], optionally seeded with persisted
  /// [paramValues] / [state] and live [params] metadata.
  const PluginEffect({
    required this.ref,
    this.paramValues = const {},
    this.params = const [],
    this.state = '',
    this.name = '',
    this.enabled = true,
    this.slotId,
    this.placement = FxPlacement.post,
    this.channels = FxChannels.defaults,
    this.rack,
    this.module,
  });

  /// Rebuilds a [PluginEffect] from a persisted `{type, plugin, paramValues,
  /// state}` entry. Absent / malformed fields decode to empty (a part-4
  /// `{type, plugin}` entry stays readable). A missing `enabled` decodes
  /// `true` (R15); a missing `slotId` stays null for the repository write
  /// boundary to mint (A9).
  factory PluginEffect.fromJson(Map<String, dynamic> json) {
    final raw = json['paramValues'];
    final values = <int, double>{};
    if (raw is Map) {
      raw.forEach((key, value) {
        final id = int.tryParse(key.toString());
        if (id != null && value is num) values[id] = value.toDouble();
      });
    }
    // Same wrong-typed-field tolerance as BuiltInEffect.fromJson.
    final rawEnabled = json['enabled'];
    final rawSlotId = json['slotId'];
    if (json.containsKey('placement') && json['placement'] == null) {
      throw const FormatException('invalid effect placement');
    }
    if (json.containsKey('channels') &&
        json['channels'] is! Map<String, dynamic>) {
      throw const FormatException('invalid effect channels');
    }
    return PluginEffect(
      ref: PluginRef.fromJson(json['plugin'] as Map<String, dynamic>),
      paramValues: values,
      state: (json['state'] as String?) ?? '',
      name: (json['name'] as String?) ?? '',
      enabled: rawEnabled is! bool || rawEnabled,
      slotId: rawSlotId is String ? rawSlotId : null,
      placement: FxPlacement.fromWireName(json['placement']),
      channels: json['channels'] is Map<String, dynamic>
          ? FxChannels.fromJson(json['channels'] as Map<String, dynamic>)
          : FxChannels.defaults,
      rack: FxRack.fromJson(json['rack']),
      module: json['module'] is String ? json['module'] as String : null,
    );
  }

  /// The hosted plugin's identity.
  final PluginRef ref;

  /// Persisted plain parameter values keyed by parameter id. Only params the
  /// user has changed are stored; an absent id falls back to the plugin's
  /// default. Empty when no param has been tweaked.
  final Map<int, double> paramValues;

  /// The plugin's opaque state, base64-encoded (umbrella D-P1). Persisted as-is
  /// (it is the wire form); the repository base64-decodes it to bytes only when
  /// restoring the plugin. Empty when the plugin has no state.
  final String state;

  /// Live parameter metadata enumerated from the loaded plugin, in plugin
  /// order. Transient — populated at load time, never persisted (a reload
  /// re-enumerates it), so it is excluded from equality and [toJson].
  final List<PluginParamInfo> params;

  /// The plugin's user-visible display name, persisted so it survives a restart
  /// even before the catalog rescans — and so a missing plugin's placeholder
  /// reads as its name rather than a cryptic id. Re-resolved from the catalog
  /// (which wins) once a scan completes. Empty when never resolved.
  final String name;

  /// Whether this entry is audible (R16) — see [BuiltInEffect.enabled]. A
  /// disabled plugin keeps its own DSP state (its tail resumes on re-enable).
  final bool enabled;

  /// The entry's stable per-slot identity (A9) — see [BuiltInEffect.slotId].
  final String? slotId;

  @override
  final FxPlacement placement;

  @override
  final FxChannels channels;

  @override
  final FxRack? rack;

  @override
  final String? module;

  @override
  int get typeCode => kPluginFxCode;

  /// Returns a copy with the given fields replaced.
  PluginEffect copyWith({
    PluginRef? ref,
    Map<int, double>? paramValues,
    List<PluginParamInfo>? params,
    String? state,
    String? name,
    bool? enabled,
    String? slotId,
    FxPlacement? placement,
    FxChannels? channels,
    FxRack? rack,
    String? module,
  }) => PluginEffect(
    ref: ref ?? this.ref,
    paramValues: paramValues ?? this.paramValues,
    params: params ?? this.params,
    state: state ?? this.state,
    name: name ?? this.name,
    enabled: enabled ?? this.enabled,
    slotId: slotId ?? this.slotId,
    placement: placement ?? this.placement,
    channels: channels ?? this.channels,
    rack: rack ?? this.rack,
    module: module ?? this.module,
  );

  @override
  Map<String, dynamic> toJson() => {
    'type': kPluginFxCode,
    'plugin': ref.toJson(),
    if (paramValues.isNotEmpty)
      'paramValues': {
        for (final e in paramValues.entries) '${e.key}': e.value,
      },
    if (state.isNotEmpty) 'state': state,
    if (name.isNotEmpty) 'name': name,
    // Omitted when default so a pre-FX-v3 chain's encoding is byte-unchanged.
    if (!enabled) 'enabled': false,
    if (slotId != null) 'slotId': slotId,
    if (placement != FxPlacement.post) 'placement': placement.wireName,
    if (!channels.isDefault) 'channels': channels.toJson(),
    if (rack != null) 'rack': rack!.toJson(),
    if (module != null) 'module': module,
  };

  @override
  bool operator ==(Object other) =>
      other is PluginEffect &&
      other.ref == ref &&
      other.state == state &&
      other.name == name &&
      other.enabled == enabled &&
      other.slotId == slotId &&
      other.placement == placement &&
      other.channels == channels &&
      other.rack == rack &&
      other.module == module &&
      _mapEquals(other.paramValues, paramValues);

  @override
  int get hashCode => Object.hash(
    ref,
    state,
    name,
    enabled,
    slotId,
    placement,
    channels,
    rack,
    module,
    Object.hashAllUnordered([
      for (final e in paramValues.entries) Object.hash(e.key, e.value),
    ]),
  );

  static bool _mapEquals(Map<int, double> a, Map<int, double> b) {
    if (a.length != b.length) return false;
    for (final e in a.entries) {
      if (b[e.key] != e.value) return false;
    }
    return true;
  }
}

/// Encodes an ordered effects chain to a JSON string for persistence.
String encodeTrackEffects(List<TrackEffect> effects) =>
    jsonEncode([for (final e in effects) e.toJson()]);

/// Decodes a chain produced by [encodeTrackEffects]. Malformed JSON yields an
/// empty chain; invalid explicit effect metadata rejects the chain.
List<TrackEffect> decodeTrackEffects(String? encoded) {
  if (encoded == null || encoded.isEmpty) return const [];
  final Object? raw;
  try {
    raw = jsonDecode(encoded);
  } on FormatException {
    return const [];
  }
  if (raw is! List) return const [];
  return [
    for (final item in raw)
      if (item is Map<String, dynamic>) TrackEffect.fromJson(item),
  ];
}
