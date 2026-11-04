import 'package:meta/meta.dart';

/// A first-party Segno VST3 plugin's identity for `.als` device-chain
/// emission — deliberately **not** a reuse of `segno_engine`'s third-party
/// `PluginRef` (this package has no dependency on `segno_engine`, and none
/// of the `unavailable`/`unsupported`/`versionChanged` D-MISS machinery a
/// third-party plugin needs applies to Segno's own, permanently-stable-GUID
/// plugins — umbrella Data Model).
@immutable
class SegnoVst3Ref {
  /// Creates a [SegnoVst3Ref].
  const SegnoVst3Ref({
    required this.classId,
    required this.subcategory,
    required this.paramCount,
    this.vendor = 'Segno',
    this.version = 0x010000,
  });

  /// The plugin's permanent class GUID, as 32 uppercase hex characters (no
  /// dashes) — the processor class id minted once in the plugin's own part
  /// (its `kProcessorUID`, umbrella D-GUID; the plugin sources went in #940)
  /// and never changed again. This is the identity Ableton persists in a
  /// `.als`'s device XML to re-resolve the plugin on load.
  final String classId;

  /// The plugin's VST3 processor subcategory (e.g. `Fx|Delay`), as its
  /// factory registered it — informational only (device XML emission
  /// doesn't need it).
  final String subcategory;

  /// How many of a `DawEffect`'s `params` (the cells its type reads, as
  /// the persisted manifest carries them) this plugin's
  /// controller actually registers as a real `RangeParameter`/
  /// `StringListParameter` (Drive/Filter/Tremolo: 2; Delay/Echo/Reverb: 3;
  /// Octaver: 4).
  /// `als_builder.dart`'s `_deviceChainXml` emits only the first
  /// [paramCount] values: anything further doesn't correspond to a real
  /// parameter the plugin registers, so emitting it would write `ParameterId`
  /// values Ableton (or the plugin itself) has no meaning for.
  final int paramCount;

  /// The plugin vendor string every Segno plugin's factory registers —
  /// fixed, never varies per effect.
  final String vendor;

  /// Packed `major << 16 | minor << 8 | patch` — informational only (every
  /// plugin was `1.0.0`).
  final int version;
}

// `TrackEffectType`/native `le_fx_type` codes for the seven built-in
// effects — reproduced here as this package's own constants (no
// `segno_engine` import, matching the same own-input-model rule
// `fx_chains.dart`'s `_kBuiltInEffectNames` already follows) purely to key
// [segnoVst3Plugins].

/// The `le_fx_type` code for "Segno Drive".
const int kFxDrive = 1;

/// The `le_fx_type` code for "Segno Filter".
const int kFxFilter = 2;

/// The `le_fx_type` code for "Segno Delay".
const int kFxDelay = 3;

/// The `le_fx_type` code for "Segno Tremolo".
const int kFxTremolo = 4;

/// The `le_fx_type` code for "Segno Octaver".
const int kFxOctaver = 5;

/// The `le_fx_type` code for "Segno Echo".
const int kFxEcho = 6;

/// The `le_fx_type` code for "Segno Reverb".
const int kFxReverb = 7;

/// One [SegnoVst3Ref] per built-in effect type, keyed by its `LE_FX_*` code
/// — hardcoded constants, not runtime-discovered, since `daw_export` is a
/// pure Dart package with no engine dependency (umbrella Data Model). Class
/// GUIDs, subcategories and `paramCount`s were transcribed from the
/// plugins' own sources, which #940 deleted with the plugin build: these
/// values are frozen, and nothing builds the plugins they name. Removing
/// the device-chain export that still uses them is #1587.
const Map<int, SegnoVst3Ref> segnoVst3Plugins = {
  kFxDelay: SegnoVst3Ref(
    classId: '153409ABA7B2437F83B5A2A6C60EF9B6',
    subcategory: 'Fx|Delay',
    paramCount: 3, // Time, Feedback, Mix
  ),
  kFxReverb: SegnoVst3Ref(
    classId: 'C9C65FCDD0774D838C10B84599FD94C4',
    subcategory: 'Fx|Reverb',
    paramCount: 3, // Size, Damping, Mix
  ),
  kFxEcho: SegnoVst3Ref(
    // Echo is a delay-family effect (matches Ableton's own categorization
    // convention), so its subcategory is "Fx|Delay" too — same as Delay,
    // not a typo.
    classId: 'D771158E80027D4E96FA4568E993192E',
    subcategory: 'Fx|Delay',
    paramCount: 3, // Time, Feedback, Mix
  ),
  kFxDrive: SegnoVst3Ref(
    classId: '4B97C4B2DF150FA1ADF39F6E82E97A25',
    subcategory: 'Fx|Distortion',
    paramCount: 2, // Drive, Level
  ),
  kFxFilter: SegnoVst3Ref(
    classId: 'EDD27869F5C0667F479A338781C80262',
    subcategory: 'Fx|Filter',
    paramCount: 2, // Cutoff, Resonance
  ),
  kFxTremolo: SegnoVst3Ref(
    classId: '2D8D41873BDF80210FE2470FA5D39AA0',
    subcategory: 'Fx|Modulation',
    paramCount: 2, // Rate, Depth
  ),
  kFxOctaver: SegnoVst3Ref(
    classId: '3D52244783390B6415C6CB7A508CE993',
    subcategory: 'Fx|Pitch Shift',
    paramCount: 4, // Shift, Tone, Mix, Mode
  ),
};
