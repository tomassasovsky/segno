import 'dart:convert';

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

/// The number of normalized (`0..1`) parameters each effect exposes. Mirrors
/// the native `LE_FX_PARAMS`.
const int kTrackEffectParams = 4;

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

  /// Maps a persisted wire name back; anything unrecognized is [stereo].
  static FxChannelInput fromWireName(Object? raw) {
    for (final v in values) {
      if (v.name == raw) return v;
    }
    return FxChannelInput.stereo;
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

  /// Maps a persisted wire name back; anything unrecognized is [stereo].
  static FxChannelOutput fromWireName(Object? raw) =>
      raw == 'mono' ? FxChannelOutput.mono : FxChannelOutput.stereo;
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

  /// Rebuilds an [FxChannels] from its [toJson] map. Wrong-typed and missing
  /// fields decode to the default — this runs on the boot path.
  factory FxChannels.fromJson(Map<String, dynamic> json) {
    final placement = json['placement'];
    final level = json['level'];
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

  /// The entry's own level, applied last. Unity `1`.
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

  /// Maps a persisted wire name back to a placement; anything unrecognized
  /// (including a missing key) is [post], the default.
  static FxPlacement fromWireName(Object? raw) =>
      raw == 'pre' ? FxPlacement.pre : FxPlacement.post;
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
/// normalized parameters differently (see [paramLabels]).
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
  reverb(7, 'Reverb');

  const TrackEffectType(this.code, this.label);

  /// The native `le_fx_type` integer.
  final int code;

  /// A short human-readable name for menus.
  final String label;

  /// Maps a native `le_fx_type` integer back to a [TrackEffectType]; unknown
  /// values fall back to [TrackEffectType.none].
  static TrackEffectType fromCode(int code) =>
      values.firstWhere((t) => t.code == code, orElse: () => none);

  /// This type's parameters, in order. The list length is the number of
  /// parameters the type actually uses (`<=` [kTrackEffectParams]); trailing
  /// unused parameters are omitted. Each entry also carries how it should be
  /// presented (see [TrackEffectParam]) — most are plain continuous controls,
  /// but musical parameters like the octaver's pitch snap to discrete values
  /// and read out in their own units.
  List<TrackEffectParam> get params => switch (this) {
    TrackEffectType.none => const [],
    TrackEffectType.drive => const [
      TrackEffectParam('Drive'),
      TrackEffectParam('Level'),
    ],
    TrackEffectType.filter => const [
      TrackEffectParam('Cutoff'),
      TrackEffectParam('Resonance'),
    ],
    TrackEffectType.delay => const [
      TrackEffectParam('Time'),
      TrackEffectParam('Feedback'),
      TrackEffectParam('Mix'),
    ],
    TrackEffectType.tremolo => const [
      TrackEffectParam('Rate'),
      TrackEffectParam('Depth'),
    ],
    // Shift snaps to whole semitones across the engine's +-2 octave range, with
    // a centre detent at unison, and reads out as a pitch interval. Mode is a
    // two-state toggle (phase vocoder / PSOLA) — stored but inert until the
    // formant-preserving rewrite reads it.
    TrackEffectType.octaver => const [
      TrackEffectParam(
        'Shift',
        divisions: 48,
        readout: ParamReadout.pitchShift,
      ),
      TrackEffectParam('Tone'),
      TrackEffectParam('Mix'),
      TrackEffectParam('Mode', divisions: 1, readout: ParamReadout.octaverMode),
    ],
    TrackEffectType.echo => const [
      TrackEffectParam('Time'),
      TrackEffectParam('Feedback'),
      TrackEffectParam('Mix'),
    ],
    TrackEffectType.reverb => const [
      TrackEffectParam('Size'),
      TrackEffectParam('Damping'),
      TrackEffectParam('Mix'),
    ],
  };

  /// Labels for this type's parameters, in order. A convenience over [params].
  List<String> get paramLabels => [for (final p in params) p.label];

  /// The musical default for each of the [kTrackEffectParams] parameters when
  /// the type is freshly engaged. Mirrors the engine's `le_fx_default_params`
  /// so the UI sliders match what the engine seeds.
  List<double> get defaultParams => switch (this) {
    TrackEffectType.none => const [0, 0, 0, 0],
    TrackEffectType.drive => const [0.5, 0.8, 0, 0],
    TrackEffectType.filter => const [0.5, 0.2, 0, 0],
    TrackEffectType.delay => const [0.35, 0.35, 0.35, 0],
    TrackEffectType.tremolo => const [0.3, 0.7, 0, 0],
    // p3 = mode: 0 selects the phase vocoder (inert until parts 3-4).
    TrackEffectType.octaver => const [0.25, 0.5, 0.5, 0],
    TrackEffectType.echo => const [0.45, 0.5, 0.35, 0],
    TrackEffectType.reverb => const [0.5, 0.5, 0.35, 0],
  };
}

/// How a parameter's `0..1` value is read out in the UI, in its own units, when
/// the bare number isn't meaningful on its own. The UI maps each kind to a
/// localized string; [none] shows no readout.
enum ParamReadout {
  /// No unit readout — the slider alone is enough.
  none,

  /// A pitch interval (e.g. "Unison", "+7 st", "-1 oct").
  pitchShift,

  /// The octaver algorithm mode (phase vocoder / PSOLA).
  octaverMode,
}

/// How one effect parameter should be presented in the UI.
///
/// The value itself is always a normalized `0..1` double (see [TrackEffect]);
/// this only describes the control. [divisions], when set, snaps the slider to
/// that many discrete steps so a musical parameter lands on exact values rather
/// than floating between them. [readout] selects a human-readable unit readout
/// (e.g. a pitch interval) shown live beside the slider.
@immutable
class TrackEffectParam {
  /// Creates a parameter descriptor.
  const TrackEffectParam(
    this.label, {
    this.divisions,
    this.readout = ParamReadout.none,
  });

  /// A short name for the control.
  final String label;

  /// The number of discrete steps the control snaps to, or `null` for a
  /// continuous control.
  final int? divisions;

  /// How the value should be read out in its own units, or [ParamReadout.none].
  final ParamReadout readout;
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
  }) : params = List<double>.unmodifiable(params ?? type.defaultParams);

  /// Rebuilds a [BuiltInEffect] from [toJson] output; unknown codes fall back
  /// to safe defaults. A legacy `stage` key (from the removed pre/post model)
  /// is ignored, so older persisted chains still decode.
  ///
  /// The decoded `params` are normalized to [kTrackEffectParams]: a list saved
  /// by a narrower build is padded with the type's own `defaultParams` (so a
  /// future non-zero default round-trips, and the octaver's new `mode` lands on
  /// phase vocoder), and an over-long list is truncated. A missing `enabled`
  /// decodes `true` (every pre-FX-v3 entry was audible — R15's "migration
  /// defaults every level to enabled"); a missing `slotId` stays null for the
  /// repository write boundary to mint (A9).
  factory BuiltInEffect.fromJson(Map<String, dynamic> json) {
    final type = TrackEffectType.fromCode((json['type'] as num?)?.toInt() ?? 0);
    // `is`-checks, not casts: a wrong-typed field in a corrupt persisted
    // chain must decode to the default, never throw a TypeError past
    // decodeTrackEffects' FormatException-only catch.
    final rawEnabled = json['enabled'];
    final enabled = rawEnabled is! bool || rawEnabled;
    final rawSlotId = json['slotId'];
    final slotId = rawSlotId is String ? rawSlotId : null;
    final placement = FxPlacement.fromWireName(json['placement']);
    final rawChannels = json['channels'];
    final channels = rawChannels is Map<String, dynamic>
        ? FxChannels.fromJson(rawChannels)
        : FxChannels.defaults;
    final rawParams = json['params'];
    if (rawParams is! List) {
      return BuiltInEffect(
        type: type,
        enabled: enabled,
        slotId: slotId,
        placement: placement,
        channels: channels,
      );
    }
    final decoded = [for (final v in rawParams) (v as num).toDouble()];
    final defaults = type.defaultParams;
    return BuiltInEffect(
      type: type,
      params: [
        for (var i = 0; i < kTrackEffectParams; i++)
          if (i < decoded.length) decoded[i] else defaults[i],
      ],
      enabled: enabled,
      slotId: slotId,
      placement: placement,
      channels: channels,
    );
  }

  /// The effect type.
  final TrackEffectType type;

  /// The normalized parameter values (length [kTrackEffectParams]).
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
  int get typeCode => type.code;

  /// Returns a copy with the given fields replaced. [params] is copied.
  BuiltInEffect copyWith({
    TrackEffectType? type,
    List<double>? params,
    bool? enabled,
    String? slotId,
    FxPlacement? placement,
    FxChannels? channels,
  }) => BuiltInEffect(
    type: type ?? this.type,
    params: params ?? this.params,
    enabled: enabled ?? this.enabled,
    slotId: slotId ?? this.slotId,
    placement: placement ?? this.placement,
    channels: channels ?? this.channels,
  );

  @override
  Map<String, dynamic> toJson() => {
    'type': type.code,
    'params': params,
    // Omitted when default so a pre-FX-v3 chain's encoding is byte-unchanged.
    if (!enabled) 'enabled': false,
    if (slotId != null) 'slotId': slotId,
    if (placement != FxPlacement.post) 'placement': placement.wireName,
    if (!channels.isDefault) 'channels': channels.toJson(),
  };

  @override
  bool operator ==(Object other) =>
      other is BuiltInEffect &&
      other.type == type &&
      other.enabled == enabled &&
      other.slotId == slotId &&
      other.placement == placement &&
      other.channels == channels &&
      _listEquals(other.params, params);

  @override
  int get hashCode => Object.hash(
    type,
    enabled,
    slotId,
    placement,
    channels,
    Object.hashAll(params),
  );

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

/// Decodes a chain produced by [encodeTrackEffects]; malformed input yields an
/// empty chain.
List<TrackEffect> decodeTrackEffects(String? encoded) {
  if (encoded == null || encoded.isEmpty) return const [];
  try {
    final raw = jsonDecode(encoded);
    if (raw is! List) return const [];
    return [
      for (final item in raw)
        if (item is Map<String, dynamic>) TrackEffect.fromJson(item),
    ];
  } on FormatException {
    return const [];
  }
}
