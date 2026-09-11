import 'package:fx_catalogue/fx_catalogue.dart';
import 'package:looper_repository/src/models/track_effect.dart';
import 'package:segno_engine/segno_engine.dart' show kTrackEffectParams;

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
  // dropped. Its mode, damping, resonance and ratio controls are Looper X's
  // own shaping and have no engine parameter, which is what makes it partial.
  'Delay': FxModuleBuild(
    type: TrackEffectType.delay,
    params: ['Del Time', 'Del Feedback', 'Del Mix'],
    unmapped: [
      'Del Damp',
      'Del Freq',
      'Del L/R Ratio',
      'Del Mode',
      'Del Res-Freq',
      'Del Reso',
    ],
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

/// What this engine can build for [module].
FxModuleBuild fxModuleBuild(FxModule module) =>
    kFxModuleBuilds[module.name] ?? const FxModuleBuild.unavailable();

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
  final build = fxModuleBuild(module);
  final params = List<double>.filled(kTrackEffectParams, 0);
  final defaults = build.type == null
      ? const <double>[]
      : BuiltInEffect(type: build.type!).params;
  for (var i = 0; i < params.length; i++) {
    params[i] = i < defaults.length ? defaults[i] : 0;
  }
  for (var i = 0; i < build.params.length && i < params.length; i++) {
    final key = build.params[i];
    if (key == null) continue;
    final value = preset.params[key];
    if (value != null) params[i] = value.clamp(0.0, 1.0);
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
    type: build.type ?? TrackEffectType.none,
    params: params,
    enabled: enabled,
  );
}

/// The modules [preset] holds, in the table's order, keeping only those the
/// preset actually names.
///
/// A preset names a module by carrying its power key or any of its
/// parameters — some presets carry a module's controls without its power key
/// and the other way round, so either is enough to say the rack has it.
List<FxModule> fxPresetModules(FxPreset preset) => [
  for (final module in kFxModules)
    if (_names(preset, module)) module,
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
