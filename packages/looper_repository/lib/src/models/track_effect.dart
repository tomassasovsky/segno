import 'package:equatable/equatable.dart';
import 'package:looper_repository/src/models/plugin_descriptor.dart';
import 'package:segno_engine/segno_engine.dart' as engine;

/// How one chain entry takes the pair it is handed (slice 3e). Domain mirror
/// of the engine's `FxChannelInput`.
enum FxChannelInput {
  /// The default: left and right as they arrive.
  stereo,

  /// The incoming left on both sides.
  left,

  /// The incoming right on both sides.
  right,

  /// Their average on both sides.
  monoSum,
}

/// How one chain entry hands its result on. Domain mirror of the engine's
/// `FxChannelOutput`.
enum FxChannelOutput {
  /// The default: what the effects made, with the placement as a Balance.
  stereo,

  /// Averaged to mono, with the placement as a Pan.
  mono,
}

/// One chain entry's channel handling and level. Domain mirror of the
/// engine's `FxChannels`.
///
/// The accepted design puts these around each instance: the [input] choice
/// before its effects, the [output] choice and then the [level] after them.
/// [defaults] is bit-identical to no channel handling at all.
class FxChannels extends Equatable {
  /// Creates an [FxChannels].
  const FxChannels({
    this.input = FxChannelInput.stereo,
    this.output = FxChannelOutput.stereo,
    this.placement = 0,
    this.level = 1,
  });

  /// Stereo in, stereo out, centre, unity.
  static const FxChannels defaults = FxChannels();

  /// What the entry's effects are handed.
  final FxChannelInput input;

  /// How the entry hands its result on.
  final FxChannelOutput output;

  /// Balance (stereo out) or Pan (mono out), `-1..1`, centre `0`.
  final double placement;

  /// The entry's own gain, applied last: `0..4` (about +12 dB), unity `1`.
  /// A rack's level is its last entry's, set in dB (see `fxRackLevelGain`).
  final double level;

  /// Whether this is [defaults].
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

  @override
  List<Object?> get props => [input, output, placement, level];
}

/// The rack a chain entry belongs to. Domain mirror of the engine's `FxRack`.
///
/// The accepted design's chain is built out of RACKS — named groups of pedals
/// the player adds, renames, reorders and removes as one thing. The engine's
/// chain is a flat run of entries, so the grouping rides the entries: every
/// module of one rack carries the same [id], and a run of entries sharing an
/// [id] IS that rack. A `null` rack means a standalone single effect.
///
/// `fxChainGroups` (in `fx_chain_group.dart`) turns a chain into the groups
/// the surfaces draw.
class FxRack extends Equatable {
  /// Creates an [FxRack].
  const FxRack({required this.id, required this.name, this.art});

  /// The rack's identity, shared by every module in it, unique within its
  /// chain, and never rewritten by a rename or a reorder.
  final String id;

  /// The rack's name, which the player can change. Renaming it never touches
  /// the saved preset it came from.
  final String name;

  /// The catalogue artwork slug the card draws, or `null` when there is none.
  final String? art;

  /// Returns a copy with the given fields replaced.
  FxRack copyWith({String? id, String? name, String? art}) =>
      FxRack(id: id ?? this.id, name: name ?? this.name, art: art ?? this.art);

  @override
  List<Object?> get props => [id, name, art];
}

/// Where one chain entry sits relative to the loop player. Domain mirror of
/// the engine's `FxPlacement`.
///
/// A chain is stored [pre] entries first, then [post] entries, so the split is
/// a single boundary index — [fxPreCount] — and that index is the only thing
/// the native engine is told.
///
/// The accepted design states the consequence in one line each: [pre] is
/// "recorded into loop", [post] "can ring after Stop". A hardware input's new
/// entries default to [pre] and a recorded destination's to [post]; the
/// destination chooses, not this model, whose own default is [post].
enum FxPlacement {
  /// Recorded into the loop: part of the take's playable representation, so a
  /// track Stop stops its tail with the recording.
  pre,

  /// Downstream of the player: a track Stop leaves its tail to drain.
  post,
}

/// The number of leading [FxPlacement.pre] entries in [chain] — the whole
/// pre/post split of a chain that has crossed a repository write.
int fxPreCount(List<TrackEffect> chain) {
  var n = 0;
  while (n < chain.length && chain[n].placement == FxPlacement.pre) {
    n++;
  }
  return n;
}

/// Returns [chain] partitioned [FxPlacement.pre] entries first, preserving the
/// relative order within each stage.
///
/// This is the storage invariant every repository chain write establishes, and
/// it is a STABLE partition on purpose: reorder moves an entry within its own
/// stage, so re-partitioning an already-ordered chain must be the identity.
List<TrackEffect> partitionByPlacement(List<TrackEffect> chain) => [
  for (final fx in chain)
    if (fx.placement == FxPlacement.pre) fx,
  for (final fx in chain)
    if (fx.placement == FxPlacement.post) fx,
];

/// The unit a built-in parameter's value is shown in. Domain mirror of the
/// engine's `FxParamUnit`.
enum FxParamUnit {
  /// 0..100 percent.
  percent,

  /// Milliseconds.
  ms,

  /// Hertz.
  hz,

  /// A pitch interval in semitones.
  semitones,

  /// A gain factor, shown with "x".
  times,

  /// Named positions; the value is the position.
  choice,

  /// Decibels.
  db,

  /// A filter's Q, a plain number.
  q,

  /// A compression ratio, "n : 1".
  ratio,

  /// Seconds.
  seconds,
}

/// Where a built-in parameter turns its effect off. Domain mirror of the
/// engine's `FxParamOff`.
enum FxParamOff {
  /// Never.
  none,

  /// At setting 0.
  atMin,

  /// At setting 1.
  atMax,
}

/// How a built-in parameter's value follows its normalized setting. Domain
/// mirror of the engine's `FxParamCurve`.
enum FxParamCurve {
  /// `atMin + (atMax - atMin) * v`.
  linear,

  /// `atMin * (atMax / atMin) ^ v`.
  exponential,

  /// `1 / (1 / atMin + (1 / atMax - 1 / atMin) * v)`: the reciprocal is
  /// linear.
  reciprocal,

  /// `(v + atMin) / (1 - v)`, at most `atMax`: the Looper X's reverb time
  /// display.
  reverbTime,
}

/// One built-in effect parameter: what its normalized `0..1` setting means.
/// Domain mirror of the engine's `FxParamInfo`, which copies the native
/// `le_fx_param_desc` table.
///
/// The setting itself lives on the chain entry (see [TrackEffect]); this
/// describes it: a stable [key] the app localizes the name by, the [unit] the
/// value is shown in, the mapping from setting to value ([atMin], [atMax],
/// [curve]), how many positions it snaps to ([steps]) and where a freshly
/// engaged effect starts ([defaultValue]).
class FxParamInfo extends Equatable {
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
    this.off = FxParamOff.none,
  }) : _source = null;

  FxParamInfo._fromEngine(engine.FxParamInfo p)
    : key = p.key,
      unit = _unitFromEngine(p.unit),
      atMin = p.atMin,
      atMax = p.atMax,
      defaultValue = p.defaultValue,
      steps = p.steps,
      curve = _curveFromEngine(p.curve),
      taperUnverified = p.taperUnverified,
      off = switch (p.off) {
        engine.FxParamOff.none => FxParamOff.none,
        engine.FxParamOff.atMin => FxParamOff.atMin,
        engine.FxParamOff.atMax => FxParamOff.atMax,
      },
      _source = p;

  /// The engine descriptor this mirrors, kept so the mapping below does not
  /// build one per call; `null` for one made with the public constructor.
  final engine.FxParamInfo? _source;

  /// The stable parameter key (`drive`, `cutoff`, `shift`, ...).
  final String key;

  /// The unit [valueAt] returns.
  final FxParamUnit unit;

  /// 0 for a continuous parameter, otherwise the number of positions a
  /// control snaps it to: position k of n stands for setting `k / (n - 1)`.
  /// The kernel reads a choice at its nearest position and every other
  /// parameter as set.
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
  /// it reproduces.
  final bool taperUnverified;

  /// Where the parameter turns its effect off.
  final FxParamOff off;

  /// Whether [setting] is where the effect is off.
  bool isOffAt(double setting) => switch (off) {
    FxParamOff.none => false,
    FxParamOff.atMin => setting <= 0,
    FxParamOff.atMax => setting >= 1,
  };

  /// Whether the parameter snaps to [steps] positions.
  bool get isStepped => steps > 1;

  /// The value [setting] (clamped to `0..1`) stands for, mapped as the engine
  /// maps it: a choice first takes its nearest position.
  double valueAt(double setting) => (_source ?? _toEngine()).valueAt(setting);

  /// The position (`0..steps-1`) [setting] (clamped to `0..1`) snaps to.
  ///
  /// Throws a [StateError] for a continuous parameter, which has no positions.
  int positionOf(double setting) =>
      (_source ?? _toEngine()).positionOf(setting);

  /// The setting that stands for [value] (see the engine's `settingFor`).
  double settingFor(double value) => (_source ?? _toEngine()).settingFor(value);

  /// The engine descriptor, which holds the one implementation of the
  /// mapping.
  engine.FxParamInfo _toEngine() => engine.FxParamInfo(
    key: key,
    unit: switch (unit) {
      FxParamUnit.percent => engine.FxParamUnit.percent,
      FxParamUnit.ms => engine.FxParamUnit.ms,
      FxParamUnit.hz => engine.FxParamUnit.hz,
      FxParamUnit.semitones => engine.FxParamUnit.semitones,
      FxParamUnit.times => engine.FxParamUnit.times,
      FxParamUnit.choice => engine.FxParamUnit.choice,
      FxParamUnit.db => engine.FxParamUnit.db,
      FxParamUnit.q => engine.FxParamUnit.q,
      FxParamUnit.ratio => engine.FxParamUnit.ratio,
      FxParamUnit.seconds => engine.FxParamUnit.seconds,
    },
    atMin: atMin,
    atMax: atMax,
    defaultValue: defaultValue,
    steps: steps,
    curve: switch (curve) {
      FxParamCurve.linear => engine.FxParamCurve.linear,
      FxParamCurve.exponential => engine.FxParamCurve.exponential,
      FxParamCurve.reciprocal => engine.FxParamCurve.reciprocal,
      FxParamCurve.reverbTime => engine.FxParamCurve.reverbTime,
    },
    taperUnverified: taperUnverified,
    off: switch (off) {
      FxParamOff.none => engine.FxParamOff.none,
      FxParamOff.atMin => engine.FxParamOff.atMin,
      FxParamOff.atMax => engine.FxParamOff.atMax,
    },
  );

  @override
  List<Object?> get props => [
    key,
    unit,
    steps,
    atMin,
    atMax,
    curve,
    defaultValue,
    taperUnverified,
    off,
  ];
}

/// A built-in effect type, the domain mirror of the engine's `le_fx_type`.
///
/// The integer [code] matches the native enum; the per-type parameter
/// descriptors and musical defaults are sourced from the engine so the two can
/// never drift (a single source of truth for the musical metadata), while the
/// type the presentation layer names stays a repository-owned domain type.
enum TrackEffectType {
  /// The entry is bypassed.
  none(0),

  /// Soft-clipping overdrive.
  drive(1),

  /// Resonant low-pass filter.
  filter(2),

  /// Feedback delay.
  delay(3),

  /// Sine-LFO amplitude modulation.
  tremolo(4),

  /// Pitch-shift octaver.
  octaver(5),

  /// Tape-style echo with damped, smearing repeats.
  echo(6),

  /// Schroeder/Freeverb room reverb.
  reverb(7),

  /// The Looper X's generic EQ (#887 part 4).
  eq(9),

  /// The Looper X's compressor (#887 part 5).
  compressor(10),

  /// The Looper X's transient shaper (#887 part 5).
  transient(11),

  /// The Looper X's high-pass gate (#887 part 5).
  hpGate(12),

  /// The Looper X's doubler (#887 part 6).
  doubler(13),

  /// The Looper X's chorus (#887 part 6).
  chorus(14),

  /// The Looper X's wah (#887 part 6).
  wah(15),

  /// The Looper X's overdrive (#887 part 7).
  overdrive(16),

  /// The Looper X's amp simulator as the Studio Rack's Dist (#887 part 7).
  distortion(17),

  /// The Looper X's vinyl (#887 part 7).
  vinyl(18),

  /// The Looper X's degrade (#887 part 7).
  degrade(19),

  /// The Looper X's low-pass filter (#887 part 7).
  lpf(20),

  /// The Looper X's spring reverb (#887 part 8).
  spring(21),

  /// The Looper X's Dub-Verb (#1430).
  dubVerb(22),

  /// The Looper X's Amb-Verb (#1430), which also carries the Dub Rack's
  /// Amb-Dub Mix.
  ambVerb(23);

  const TrackEffectType(this.code);

  /// Whether this is one of the Looper X kinds (#887): a type built to
  /// reproduce a factory module, whose descriptors carry that module's own
  /// scales. The seven built-ins stand in for modules only approximately.
  bool get isRackKind => code >= TrackEffectType.eq.code;

  /// The native `le_fx_type` integer.
  final int code;

  /// Maps a native `le_fx_type` integer back to a [TrackEffectType]; unknown
  /// values fall back to [TrackEffectType.none].
  static TrackEffectType fromCode(int code) =>
      values.firstWhere((t) => t.code == code, orElse: () => none);

  /// The engine type this maps to, for sourcing metadata + boundary mapping.
  engine.TrackEffectType get _engine => engine.TrackEffectType.fromCode(code);

  /// A short human-readable name for menus.
  String get label => _engine.label;

  /// This type's parameters, in order (length `<=` `kTrackEffectParams`).
  List<FxParamInfo> get params => _params[this]!;

  static final Map<TrackEffectType, List<FxParamInfo>> _params = {
    for (final t in values)
      t: List<FxParamInfo>.unmodifiable([
        for (final p in t._engine.params) FxParamInfo._fromEngine(p),
      ]),
  };

  /// The setting each of the `kTrackEffectParams` parameters starts at when
  /// the type is freshly engaged: the descriptors' defaults, padded with 0.
  List<double> get defaultParams => _engine.defaultParams;
}

/// The identity of a hosted plugin in a chain entry. Domain mirror of the
/// engine's `PluginRef`: format + stable id + packed version.
class PluginRef extends Equatable {
  /// Creates a [PluginRef].
  const PluginRef({required this.format, required this.id, this.version = 0});

  /// The plugin format.
  final PluginFormat format;

  /// The stable plugin id (VST3 TUID hex / CLAP descriptor id).
  final String id;

  /// Packed version `major << 16 | minor << 8 | patch`, or `0` if unknown.
  final int version;

  @override
  List<Object?> get props => [format, id, version];
}

/// One entry in an effects chain — a sealed hierarchy of either a built-in DSP
/// effect ([BuiltInEffect]) or a hosted plugin ([PluginEffect]). Domain mirror
/// of the engine's sealed `TrackEffect`.
///
/// The chain is stage-addressed (FX v3) — the recording is always dry and
/// every active, [enabled] entry colors the signal in order. The same model
/// backs all four stages: a hardware input's live-monitor chain, a lane's
/// record-route chain, a track's stereo-bus chain, and the Master insert.
///
/// Each entry also carries a [placement], and a chain that has crossed a
/// repository write is stored with every [FxPlacement.pre] entry ahead of
/// every [FxPlacement.post] one.
sealed class TrackEffect extends Equatable {
  /// Const base constructor for the sealed subtypes.
  const TrackEffect();

  /// The native `le_fx_type` code for this entry.
  int get typeCode;

  /// Whether this entry is audible (R16). A disabled entry stays in the chain
  /// with its settings intact but renders bit-exact passthrough.
  bool get enabled;

  /// The entry's stable per-slot identity (A9): minted at the repository write
  /// boundary, unique within a session, never reused, preserved across edits /
  /// reorders / persist→restore. `null` only before the entry has crossed a
  /// repository write path. Identity, not sound: two entries that sound the
  /// same but carry different ids are different entries (bindings target ids).
  String? get slotId;

  /// Where this entry sits relative to the loop player: [FxPlacement.pre] is
  /// recorded into the loop, [FxPlacement.post] runs downstream of the player
  /// and can ring after Stop.
  FxPlacement get placement;

  /// This entry's channel handling and level.
  FxChannels get channels;

  /// The rack this entry belongs to, or `null` when it is a standalone single
  /// effect. Every module of one rack carries the same [FxRack.id].
  FxRack? get rack;

  /// What the factory catalogue calls this entry, or `null` when it did not
  /// come from the catalogue. The catalogue maps this one name to both the
  /// pedal's display name and its artwork.
  ///
  /// Kept because the engine effect an entry became is not what the player
  /// chose: a pedal this build cannot process becomes a passthrough entry, and
  /// without its own name it would be indistinguishable from every other one.
  String? get module;
}

/// A built-in DSP effect: a [type] with its normalized [params].
class BuiltInEffect extends TrackEffect {
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
  }) : params = engine.canonicalEffectParams(type._engine, params),
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

  /// The effect type.
  final TrackEffectType type;

  /// The normalized parameter values: length `kTrackEffectParams`, the
  /// type's parameters first and 0 after them (`canonicalEffectParams`).
  final List<double> params;

  @override
  final bool enabled;

  @override
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
  /// preset's parameter names.
  ///
  /// Kept whatever this build could do with them: a module this build cannot
  /// process, or can process only partly, still carries everything the player
  /// loaded, so a later build can rebuild it from the same values.
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
  List<Object?> get props => [
    type,
    params,
    enabled,
    slotId,
    placement,
    channels,
    rack,
    module,
    presetId,
    source,
  ];
}

/// A hosted VST3/CLAP plugin in a chain entry, identified by its [ref]. Carries
/// the user-tweaked [paramValues] (persisted) and the live [params] metadata
/// enumerated from the loaded plugin (transient). The opaque state blob lands
/// in a later part.
class PluginEffect extends TrackEffect {
  /// Creates a [PluginEffect] for [ref], optionally seeded with persisted
  /// [paramValues] and live [params] metadata.
  const PluginEffect({
    required this.ref,
    this.paramValues = const {},
    this.params = const [],
    this.name = '',
    this.state = '',
    this.unavailable = false,
    this.unsupported = false,
    this.versionChanged = false,
    this.loading = false,
    this.enabled = true,
    this.slotId,
    this.placement = FxPlacement.post,
    this.channels = FxChannels.defaults,
    this.rack,
    this.module,
  });

  /// The hosted plugin's identity.
  final PluginRef ref;

  /// Persisted plain parameter values keyed by parameter id. Only params the
  /// user has changed are stored; an absent id falls back to the plugin's
  /// default.
  final Map<int, double> paramValues;

  /// The plugin's opaque state, base64-encoded (persisted; D-P1). Empty when
  /// the plugin has no state. The repository decodes it to bytes to restore.
  final String state;

  /// Live parameter metadata enumerated from the loaded plugin, in plugin
  /// order. Transient — never persisted.
  final List<PluginParamInfo> params;

  /// The plugin's user-visible display name, resolved from the scan catalog
  /// when the plugin loads — or, at a bus stage where nothing loads, when the
  /// chain is written. Empty when unresolved, in which case the UI falls back
  /// to the stable id.
  ///
  /// PERSISTED whenever a chain carrying it is written (the wire format
  /// carries any non-empty name), so a plugin uninstalled after that write
  /// still says which one it was — which is what tells the player what to
  /// relink to.
  final String name;

  /// Whether the plugin failed to resolve/load on the running engine
  /// (uninstalled / moved / incompatible — umbrella D-MISS). Transient. A
  /// placeholder card surfaces it, preserving [ref] + [state] for relink; the
  /// entry is never silently dropped.
  final bool unavailable;

  /// Whether the failure is because the plugin is installed but **rejected** —
  /// an instrument / multi-bus / wrong-channel plugin that isn't a supported
  /// stereo effect (D-BUS), as opposed to simply missing. Transient; only
  /// meaningful when [unavailable]. Distinguishes the placeholder's message.
  final bool unsupported;

  /// Whether the installed plugin's version differs from the saved [ref]'s
  /// (same id, different version — D-MISS). Transient; the plugin still loaded,
  /// but the card notes the drift.
  final bool versionChanged;

  /// Whether the plugin is still resolving: it hasn't loaded yet because a
  /// plugin scan is in progress (typically a cold boot, F5), so it is expected
  /// to bind once the scan lands. Transient. Distinct from [unavailable] — a
  /// loading entry renders a "loading…" state (no relink), never the
  /// "unavailable" placeholder, so a still-scanning plugin doesn't read as a
  /// genuine failure.
  final bool loading;

  @override
  final bool enabled;

  @override
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
  int get typeCode => engine.kPluginFxCode;

  /// Returns a copy with the given fields replaced.
  PluginEffect copyWith({
    PluginRef? ref,
    Map<int, double>? paramValues,
    List<PluginParamInfo>? params,
    String? name,
    String? state,
    bool? unavailable,
    bool? unsupported,
    bool? versionChanged,
    bool? loading,
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
    name: name ?? this.name,
    state: state ?? this.state,
    unavailable: unavailable ?? this.unavailable,
    unsupported: unsupported ?? this.unsupported,
    versionChanged: versionChanged ?? this.versionChanged,
    loading: loading ?? this.loading,
    enabled: enabled ?? this.enabled,
    slotId: slotId ?? this.slotId,
    placement: placement ?? this.placement,
    channels: channels ?? this.channels,
    rack: rack ?? this.rack,
    module: module ?? this.module,
  );

  @override
  List<Object?> get props => [
    ref,
    paramValues,
    params,
    name,
    state,
    unavailable,
    unsupported,
    versionChanged,
    loading,
    enabled,
    slotId,
    placement,
    channels,
    rack,
    module,
  ];
}

/// Maps an engine parameter unit to its domain mirror.
FxParamUnit _unitFromEngine(engine.FxParamUnit unit) => switch (unit) {
  engine.FxParamUnit.percent => FxParamUnit.percent,
  engine.FxParamUnit.ms => FxParamUnit.ms,
  engine.FxParamUnit.hz => FxParamUnit.hz,
  engine.FxParamUnit.semitones => FxParamUnit.semitones,
  engine.FxParamUnit.times => FxParamUnit.times,
  engine.FxParamUnit.choice => FxParamUnit.choice,
  engine.FxParamUnit.db => FxParamUnit.db,
  engine.FxParamUnit.q => FxParamUnit.q,
  engine.FxParamUnit.ratio => FxParamUnit.ratio,
  engine.FxParamUnit.seconds => FxParamUnit.seconds,
};

/// Maps an engine parameter curve to its domain mirror.
FxParamCurve _curveFromEngine(engine.FxParamCurve curve) => switch (curve) {
  engine.FxParamCurve.linear => FxParamCurve.linear,
  engine.FxParamCurve.exponential => FxParamCurve.exponential,
  engine.FxParamCurve.reciprocal => FxParamCurve.reciprocal,
  engine.FxParamCurve.reverbTime => FxParamCurve.reverbTime,
};

/// Maps a domain [FxChannels] to the engine value at the boundary.
///
/// Public because the repository hands it straight to the engine's per-entry
/// channel setters; every other domain-to-engine conversion stays private
/// behind the chain codecs.
engine.FxChannels fxChannelsToEngine(FxChannels c) => engine.FxChannels(
  input: switch (c.input) {
    FxChannelInput.stereo => engine.FxChannelInput.stereo,
    FxChannelInput.left => engine.FxChannelInput.left,
    FxChannelInput.right => engine.FxChannelInput.right,
    FxChannelInput.monoSum => engine.FxChannelInput.monoSum,
  },
  output: switch (c.output) {
    FxChannelOutput.stereo => engine.FxChannelOutput.stereo,
    FxChannelOutput.mono => engine.FxChannelOutput.mono,
  },
  placement: c.placement,
  level: c.level,
);

/// Maps an engine `FxChannels` to its domain mirror.
FxChannels _channelsFromEngine(engine.FxChannels c) => FxChannels(
  input: switch (c.input) {
    engine.FxChannelInput.stereo => FxChannelInput.stereo,
    engine.FxChannelInput.left => FxChannelInput.left,
    engine.FxChannelInput.right => FxChannelInput.right,
    engine.FxChannelInput.monoSum => FxChannelInput.monoSum,
  },
  output: switch (c.output) {
    engine.FxChannelOutput.stereo => FxChannelOutput.stereo,
    engine.FxChannelOutput.mono => FxChannelOutput.mono,
  },
  placement: c.placement,
  level: c.level,
);

/// Maps a domain [FxPlacement] to the engine enum at the boundary.
engine.FxPlacement _placementToEngine(FxPlacement placement) =>
    switch (placement) {
      FxPlacement.pre => engine.FxPlacement.pre,
      FxPlacement.post => engine.FxPlacement.post,
    };

/// Maps an engine [engine.FxPlacement] to its domain mirror.
FxPlacement _placementFromEngine(engine.FxPlacement placement) =>
    switch (placement) {
      engine.FxPlacement.pre => FxPlacement.pre,
      engine.FxPlacement.post => FxPlacement.post,
    };

/// Maps a domain [TrackEffectType] to the engine enum at the boundary.
engine.TrackEffectType trackEffectTypeToEngine(TrackEffectType type) =>
    engine.TrackEffectType.fromCode(type.code);

/// Maps a domain [TrackEffect] to its engine counterpart (boundary; internal).
///
/// Named explicitly by the FX-v3 plan (R16): `enabled` and `slotId` MUST
/// thread through both arms — a field silently dropped here round-trips as its
/// default and the bug stays invisible until a stomp un-bypasses a chain.
engine.TrackEffect _trackEffectToEngine(TrackEffect effect) => switch (effect) {
  BuiltInEffect(
    :final type,
    :final params,
    :final enabled,
    :final slotId,
    :final placement,
    :final channels,
    :final rack,
    :final module,
    :final presetId,
    :final source,
  ) =>
    engine.BuiltInEffect(
      type: trackEffectTypeToEngine(type),
      params: params,
      enabled: enabled,
      slotId: slotId,
      placement: _placementToEngine(placement),
      channels: fxChannelsToEngine(channels),
      rack: _rackToEngine(rack),
      module: module,
      presetId: presetId,
      source: source,
    ),
  PluginEffect(
    :final ref,
    :final paramValues,
    :final state,
    :final name,
    :final enabled,
    :final slotId,
    :final placement,
    :final channels,
    :final rack,
    :final module,
  ) =>
    engine.PluginEffect(
      ref: engine.PluginRef(
        format: pluginFormatToEngine(ref.format),
        id: ref.id,
        version: ref.version,
      ),
      paramValues: paramValues,
      state: state,
      name: name,
      enabled: enabled,
      slotId: slotId,
      placement: _placementToEngine(placement),
      channels: fxChannelsToEngine(channels),
      rack: _rackToEngine(rack),
      module: module,
    ),
};

/// Maps a domain [FxRack] to the engine mirror (boundary; internal).
engine.FxRack? _rackToEngine(FxRack? rack) => rack == null
    ? null
    : engine.FxRack(id: rack.id, name: rack.name, art: rack.art);

/// Maps an engine `FxRack` to its domain mirror (boundary; internal).
FxRack? _rackFromEngine(engine.FxRack? rack) =>
    rack == null ? null : FxRack(id: rack.id, name: rack.name, art: rack.art);

/// Maps an ordered domain chain to its engine counterpart, for callers that
/// must hand a chain to another engine-facing repository verbatim rather than
/// persist it (`performance_repository`'s `PerformanceChains`, which embeds
/// the engine models as canonical JSON in the arm snapshot).
///
/// The one public boundary mapper: every other domain↔engine conversion stays
/// private behind [encodeTrackEffects] / [decodeTrackEffects]. Callers never
/// need to name the engine types — and must not re-derive this mapping
/// themselves, or the domain and engine models would silently drift.
List<engine.TrackEffect> trackEffectsToEngine(List<TrackEffect> effects) => [
  for (final e in effects) _trackEffectToEngine(e),
];

/// Maps an engine [TrackEffect] to its domain mirror (boundary; internal).
///
/// Named explicitly by the FX-v3 plan (R16) — `enabled` and `slotId` MUST
/// thread through both arms; see [_trackEffectToEngine].
TrackEffect _trackEffectFromEngine(engine.TrackEffect effect) =>
    switch (effect) {
      engine.BuiltInEffect(
        :final type,
        :final params,
        :final enabled,
        :final slotId,
        :final placement,
        :final channels,
        :final rack,
        :final module,
        :final presetId,
        :final source,
      ) =>
        BuiltInEffect(
          type: TrackEffectType.fromCode(type.code),
          params: params,
          enabled: enabled,
          slotId: slotId,
          placement: _placementFromEngine(placement),
          channels: _channelsFromEngine(channels),
          rack: _rackFromEngine(rack),
          module: module,
          presetId: presetId,
          source: source,
        ),
      engine.PluginEffect(
        :final ref,
        :final paramValues,
        :final state,
        :final name,
        :final enabled,
        :final slotId,
        :final placement,
        :final channels,
        :final rack,
        :final module,
      ) =>
        PluginEffect(
          ref: PluginRef(
            format: pluginFormatFromEngine(ref.format),
            id: ref.id,
            version: ref.version,
          ),
          paramValues: paramValues,
          state: state,
          name: name,
          enabled: enabled,
          slotId: slotId,
          placement: _placementFromEngine(placement),
          channels: _channelsFromEngine(channels),
          rack: _rackFromEngine(rack),
          module: module,
        ),
    };

/// Encodes an ordered effects chain to a JSON string for persistence.
///
/// Delegates to the engine's wire-format serializer so the persisted format
/// stays the single source of truth (no domain/engine drift).
String encodeTrackEffects(List<TrackEffect> effects) =>
    engine.encodeTrackEffects([
      for (final e in effects) _trackEffectToEngine(e),
    ]);

/// Decodes a chain produced by [encodeTrackEffects]; malformed input yields an
/// empty chain. Delegates to the engine serializer, then maps to domain types.
List<TrackEffect> decodeTrackEffects(String? encoded) => [
  for (final e in engine.decodeTrackEffects(encoded)) _trackEffectFromEngine(e),
];

/// An order-sensitive 64-bit fingerprint of [chain], computed with the SAME
/// FNV-1a folding the native engine uses in `le_engine_lane_fx_fingerprint` /
/// `le_engine_monitor_fx_fingerprint`, so the repository's cache hash can be
/// compared to the engine's published-chain hash for divergence detection
/// (F6). Four-stage generic: the same fold keys every stage's chain (input,
/// loop, track, master), whether or not the engine publishes a native twin.
///
/// Fold order (D-FPEMPTY, pinned in lockstep with the C
/// `le_fx_chain_fingerprint`): the [chainEnabled] bit first, but only for a
/// NON-empty chain — an empty chain still yields the FNV-1a offset basis (a
/// chain-disabled empty chain and an enabled empty chain are both dry). Then
/// each entry folds its type code, then its real [TrackEffect.enabled] bit,
/// then (built-ins only) the float bits of the parameters its type reads
/// (`le_fx_param_width`: the cells past them are never heard, so they never
/// fold). A plugin entry contributes its type + enabled
/// bit only — the engine's `a_fx_param` holds no plugin params (they live in
/// the plugin host).
///
/// [TrackEffect.slotId] and [TrackEffect.rack] deliberately do NOT fold: the
/// fingerprint is sound identity, slot ids are entry identity (A9) and a rack
/// is a grouping and a name — folding either would break the wet cache's
/// fingerprint-keyed hits on toggle pairs and identical loads, and renaming a
/// rack would re-render every take it is printed into.
int fxChainFingerprint(List<TrackEffect> chain, {bool chainEnabled = true}) {
  var h = engine.FxFingerprint.offset;
  final n = chain.length > engine.kTrackEffectMax
      ? engine.kTrackEffectMax
      : chain.length;
  if (n > 0) {
    h = engine.FxFingerprint.mixU32(h, chainEnabled ? 1 : 0);
  }
  for (var i = 0; i < n; i++) {
    final fx = chain[i];
    h = engine.FxFingerprint.mixU32(h, fx.typeCode);
    h = engine.FxFingerprint.mixU32(h, fx.enabled ? 1 : 0);
    if (fx is! BuiltInEffect) continue; // plugin: type + enabled bit only
    for (var p = 0; p < fx.type.params.length; p++) {
      h = engine.FxFingerprint.mixU32(
        h,
        engine.FxFingerprint.floatBits(fx.params[p]),
      );
    }
  }
  return h;
}
