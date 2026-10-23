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

/// Where a recipe entry sits in a rack (the native `le_fx_rack_edge` bits).
///
/// A rack's input choice (its FIRST entry's) and output side (the output
/// choice, placement and level its LAST entry carries) are the rack's own:
/// the engine applies them around the rack whatever those entries are, while
/// any entry of the rack is on, and leaves the signal untouched once every
/// entry is off or the chain is. A tail still draining out of the rack keeps
/// the output side it was heard with.
enum FxRackEdge {
  /// Not a rack's first or last entry: inside a rack, or in none.
  none(0),

  /// A rack's first entry, which carries the rack's input choice.
  first(1),

  /// A rack's last entry, which carries the rack's output side.
  last(2),

  /// The only entry of a one-entry rack.
  only(3);

  const FxRackEdge(this.bits);

  /// The native bits.
  final int bits;
}

/// A complete effect instance prepared before structural admission.
class FxRecipeSlot {
  /// Creates a detached, immutable slot description.
  FxRecipeSlot({
    required this.type,
    List<double> params = const [],
    this.enabled = true,
    this.channels = FxChannels.defaults,
    this.rack = FxRackEdge.none,
    this.plugin,
  }) : params = List.unmodifiable(params);

  /// Built-in type; ignored when [plugin] identifies a hosted instance.
  final TrackEffectType type;

  /// Normalized built-in parameters, with omitted trailing cells zeroed.
  final List<double> params;

  /// Whether this instance is engaged.
  final bool enabled;

  /// Per-instance input/output handling and gain. On a rack's [FxRackEdge.last]
  /// entry, the output side is the rack's.
  final FxChannels channels;

  /// Where this entry sits in its rack. Structural, so it rides the recipe
  /// and no granular channel write moves it.
  final FxRackEdge rack;

  /// A retained owner handle or a detached handle prepared by this engine.
  final PluginSlotHandle? plugin;

  /// Whether this slot can be represented faithfully by the native recipe.
  bool get isValid =>
      params.length <= kTrackEffectParams &&
      // The cells the type reads: the only ones the recipe carries.
      params
          .take(type.params.length)
          .every((v) => v.isFinite && v >= 0 && v <= 1) &&
      channels.placement.isFinite &&
      channels.placement >= -1 &&
      channels.placement <= 1 &&
      channels.level.isFinite &&
      channels.level >= 0 &&
      channels.level <= kFxLevelMax;
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
