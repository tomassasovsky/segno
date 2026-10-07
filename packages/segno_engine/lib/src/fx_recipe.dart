import 'package:segno_engine/src/plugin_descriptor.dart';
import 'package:segno_engine/src/track_effect.dart';

/// The signal stage that owns one atomic structural recipe.
enum FxOwner {
  /// One recorded part.
  lane,

  /// One combined track.
  track,

  /// One live input.
  monitor,

  /// The recorded mix on every destination.
  allTracks,

  /// One output destination; channel is its bus index.
  output,
}

/// A complete effect instance prepared before structural admission.
class FxRecipeSlot {
  /// Creates a detached, immutable slot description.
  FxRecipeSlot({
    required this.type,
    List<double> params = const [],
    this.enabled = true,
    this.channels = FxChannels.defaults,
    this.plugin,
  }) : params = List.unmodifiable(params);

  /// Built-in type; ignored when [plugin] identifies a hosted instance.
  final TrackEffectType type;

  /// Normalized built-in parameters, with omitted trailing cells zeroed.
  final List<double> params;

  /// Whether this instance is engaged.
  final bool enabled;

  /// Per-instance input/output handling and gain.
  final FxChannels channels;

  /// A retained owner handle or a detached handle prepared by this engine.
  final PluginSlotHandle? plugin;

  /// Whether this slot can be represented faithfully by the native recipe.
  bool get isValid =>
      params.length <= kTrackEffectParams &&
      params.every((v) => v.isFinite && v >= 0 && v <= 1) &&
      channels.placement.isFinite &&
      channels.placement >= -1 &&
      channels.placement <= 1 &&
      channels.level.isFinite &&
      channels.level >= 0 &&
      channels.level <= 2;
}

/// One chain replacement, published atomically by the audio callback.
class FxRecipe {
  /// Copies the prepared slots so the caller cannot change an admitted recipe.
  FxRecipe({
    required List<FxRecipeSlot> slots,
    this.preCount = 0,
    this.enabled = true,
  }) : slots = List.unmodifiable(slots);

  /// Instances in processing order, with Pre entries first.
  final List<FxRecipeSlot> slots;

  /// Number of leading Pre entries.
  final int preCount;

  /// Whether the whole chain is engaged.
  final bool enabled;

  /// Whether the complete bounded recipe is valid.
  bool get isValid =>
      slots.length <= kTrackEffectMax &&
      preCount >= 0 &&
      preCount <= slots.length &&
      slots.every((slot) => slot.isValid);
}
