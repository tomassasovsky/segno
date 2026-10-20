import 'dart:math' as math;

import 'package:meta/meta.dart';
import 'package:segno_engine/src/generated/segno_engine_bindings.dart';

/// The number of patches the engine defines, mirroring the native
/// `LE_SYNTH_PATCHES`.
const int kSynthPatches = LE_SYNTH_PATCHES;

/// The parameters every instrument family has, mirroring the native
/// `LE_SYNTH_FAMILY_PARAMS`.
const int kSynthFamilyParams = LE_SYNTH_FAMILY_PARAMS;

/// An instrument family, in catalogue order. Mirrors the native
/// `le_synth_family`; the index is the native code.
enum SynthFamily {
  /// Piano, keys, clav.
  keys,

  /// Organ, reed.
  organs,

  /// Lead, pad, pluck.
  synths,

  /// Bass, synth bass, sub.
  bass,

  /// Strings, violin, cello.
  strings,

  /// Acoustic and electronic kits.
  drums,

  /// Marimba, vibes, bells.
  percussion;

  /// The family for native code [code], or `null` for an unknown code.
  static SynthFamily? fromCode(int code) =>
      code >= 0 && code < values.length ? values[code] : null;
}

/// The unit a family parameter's value is shown in. Mirrors the native
/// `le_synth_param_unit`; the index is the native code.
enum SynthParamUnit {
  /// 0..100 percent.
  percent,

  /// Seconds.
  seconds,

  /// Hertz.
  hertz;

  /// The unit for native code [code], or `null` for an unknown code.
  static SynthParamUnit? fromCode(int code) =>
      code >= 0 && code < values.length ? values[code] : null;
}

/// One synthesis patch: what an instrument slot plays.
@immutable
class SynthPatch {
  /// Creates a [SynthPatch].
  const SynthPatch({
    required this.index,
    required this.id,
    required this.family,
    required this.defaults,
  });

  /// The patch's engine index (what `InstrumentHost.setInstrument` takes).
  final int index;

  /// The stable patch id (`piano`, `synth-bass`, …), the key presentation
  /// and persistence use.
  final String id;

  /// The family, which names the patch's three parameters.
  final SynthFamily family;

  /// The three family parameters' defaults on the 0..100 scale.
  final List<double> defaults;

  @override
  bool operator ==(Object other) =>
      other is SynthPatch &&
      other.index == index &&
      other.id == id &&
      other.family == family &&
      _listEquals(other.defaults, defaults);

  @override
  int get hashCode => Object.hash(index, id, family, Object.hashAll(defaults));

  @override
  String toString() => 'SynthPatch($index, $id, ${family.name}, $defaults)';
}

/// One family parameter. Every surface edits a setting on the 0..100 scale;
/// [valueAt] gives the value the voice uses, in [unit].
@immutable
class SynthParamInfo {
  /// Creates a [SynthParamInfo].
  const SynthParamInfo({
    required this.key,
    required this.unit,
    required this.atMin,
    required this.atMax,
    required this.exponential,
  });

  /// The parameter key (`brightness`, `decay`, `cutoff`, …).
  final String key;

  /// The unit [valueAt] returns.
  final SynthParamUnit unit;

  /// The value at setting 0.
  final double atMin;

  /// The value at setting 100.
  final double atMax;

  /// Whether the mapping is exponential (`atMin * (atMax / atMin) ^ (v/100)`)
  /// rather than linear.
  final bool exponential;

  /// The value setting [setting] (clamped to 0..100) stands for, exactly as
  /// the engine maps it. Drums' decay is the one documented exception: it
  /// names the kit's decay setting, and each piece derives its own hit length
  /// from it (see `le_synth_param_desc`).
  double valueAt(double setting) {
    final v = setting.isNaN ? 0.0 : setting.clamp(0.0, 100.0);
    if (exponential) return atMin * math.pow(atMax / atMin, v / 100.0);
    return atMin + (atMax - atMin) * v / 100.0;
  }

  @override
  bool operator ==(Object other) =>
      other is SynthParamInfo &&
      other.key == key &&
      other.unit == unit &&
      other.atMin == atMin &&
      other.atMax == atMax &&
      other.exponential == exponential;

  @override
  int get hashCode => Object.hash(key, unit, atMin, atMax, exponential);

  @override
  String toString() =>
      'SynthParamInfo($key, ${unit.name}, $atMin..$atMax'
      '${exponential ? ', exponential' : ''})';
}

/// The engine's synthesis catalogue: every patch and every family's
/// parameters. The engine owns the definitions; the app keeps only
/// presentation keyed by [SynthPatch.id].
@immutable
class SynthCatalogue {
  /// Creates a [SynthCatalogue].
  const SynthCatalogue({required this.patches, required this.params});

  /// A catalogue with nothing in it.
  static const SynthCatalogue empty = SynthCatalogue(patches: [], params: {});

  /// The patches in catalogue (index) order.
  final List<SynthPatch> patches;

  /// Each family's three parameters, in order.
  final Map<SynthFamily, List<SynthParamInfo>> params;

  /// The patch with [id], or `null`.
  SynthPatch? byId(String id) {
    for (final patch in patches) {
      if (patch.id == id) return patch;
    }
    return null;
  }

  /// The patch at engine [index], or `null`.
  SynthPatch? byIndex(int index) =>
      index >= 0 && index < patches.length ? patches[index] : null;

  /// [family]'s parameters (empty when the catalogue does not carry it).
  List<SynthParamInfo> paramsOf(SynthFamily family) =>
      params[family] ?? const [];

  @override
  bool operator ==(Object other) {
    if (other is! SynthCatalogue ||
        !_listEquals(other.patches, patches) ||
        other.params.length != params.length) {
      return false;
    }
    for (final entry in params.entries) {
      final theirs = other.params[entry.key];
      if (theirs == null || !_listEquals(theirs, entry.value)) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
    Object.hashAll(patches),
    Object.hashAllUnordered([
      for (final e in params.entries)
        Object.hash(e.key, Object.hashAll(e.value)),
    ]),
  );
}

bool _listEquals<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
