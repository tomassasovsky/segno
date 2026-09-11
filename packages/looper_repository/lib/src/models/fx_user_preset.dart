import 'dart:convert';

import 'package:equatable/equatable.dart';
import 'package:looper_repository/src/models/track_effect.dart';

/// A sound the player saved for reuse (accepted design, "Save preset").
///
/// A copy of one instance's entries, not a reference to it: renaming or
/// editing the rack it was saved from leaves this alone, and loading it
/// creates a fresh instance that can be edited without touching this. That
/// isolation is the whole point of the accepted rule that replacing a saved
/// definition leaves existing instances unchanged.
///
/// It copies effect parameters and channel settings. It does NOT carry a
/// placement, a pedal rule or a destination: placement belongs to where the
/// sound is used, which the accepted design states in as many words.
class FxUserPreset extends Equatable {
  /// Creates an [FxUserPreset].
  const FxUserPreset({
    required this.id,
    required this.name,
    required this.entries,
    this.art,
  });

  /// Rebuilds an [FxUserPreset] from [toJson] output, or `null` when the map
  /// does not carry what makes one addressable.
  static FxUserPreset? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final name = json['name'];
    if (id is! String || id.isEmpty || name is! String || name.isEmpty) {
      return null;
    }
    final entries = decodeTrackEffects(
      json['chain'] is String ? json['chain'] as String : null,
    );
    if (entries.isEmpty) return null;
    final art = json['art'];
    return FxUserPreset(
      id: id,
      name: name,
      entries: entries,
      art: art is String ? art : null,
    );
  }

  /// Decodes a whole saved list; malformed input yields an empty list, and a
  /// malformed entry inside a good list is dropped rather than taking the
  /// others with it.
  static List<FxUserPreset> decodeAll(String? encoded) {
    if (encoded == null || encoded.isEmpty) return const [];
    final Object? raw;
    try {
      raw = jsonDecode(encoded);
    } on FormatException {
      return const [];
    }
    if (raw is! List) return const [];
    return [
      for (final item in raw) ?FxUserPreset.fromJson(item),
    ];
  }

  /// Encodes a whole saved list.
  static String encodeAll(List<FxUserPreset> presets) =>
      jsonEncode([for (final preset in presets) preset.toJson()]);

  /// The preset's identity, which a rename does not change.
  final String id;

  /// What the player called it.
  final String name;

  /// The entries it recalls, in processing order.
  final List<TrackEffect> entries;

  /// The artwork slug of the rack it was saved from, or `null`.
  final String? art;

  /// Whether this preset was saved from a rack rather than a single effect.
  bool get isRack => entries.length > 1 || entries.first.rack != null;

  /// Returns a copy with the given fields replaced.
  FxUserPreset copyWith({
    String? id,
    String? name,
    List<TrackEffect>? entries,
    String? art,
  }) => FxUserPreset(
    id: id ?? this.id,
    name: name ?? this.name,
    entries: entries ?? this.entries,
    art: art ?? this.art,
  );

  /// A JSON-friendly map for persistence.
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'chain': encodeTrackEffects(entries),
    if (art != null) 'art': art,
  };

  @override
  List<Object?> get props => [id, name, entries, art];
}
