import 'dart:convert';

/// One factory preset, exactly as the source file carries it.
///
/// Nothing here is interpreted. The parameter map is the source's own
/// name-to-value pairs, the [id] and [type] are its own fields, and [version]
/// is the schema string it was written with. The accepted design is explicit
/// that unverified source scales and values are EVIDENCE, not permission to
/// claim factory defaults or invent a schema, so this model carries them and
/// draws no conclusions.
class FxPreset {
  /// Creates an [FxPreset].
  const FxPreset({
    required this.family,
    required this.name,
    required this.id,
    required this.type,
    required this.params,
    this.version,
  });

  /// Parses one `.fxpreset` file's [json] text, filed under [family].
  ///
  /// Returns `null` when the file is not a preset this can read — a malformed
  /// file is a gap in the catalogue, not a crash on the surface reading it.
  static FxPreset? tryParse(String family, String json) {
    final Object? raw;
    try {
      raw = jsonDecode(json);
    } on FormatException {
      return null;
    }
    if (raw is! Map<String, dynamic>) return null;
    final name = raw['name'];
    final id = raw['id'];
    final content = raw['content'];
    if (name is! String || id is! String || content is! String) return null;
    final Object? inner;
    try {
      inner = jsonDecode(content);
    } on FormatException {
      return null;
    }
    if (inner is! Map<String, dynamic>) return null;
    final version = inner.remove('_version');
    return FxPreset(
      family: family,
      name: name,
      id: id,
      type: (raw['type'] as num?)?.toInt() ?? 0,
      version: version is String ? version : null,
      params: {
        for (final e in inner.entries)
          if (e.value is num) e.key: (e.value as num).toDouble(),
      },
    );
  }

  /// The rack family this preset belongs to, which is the folder it is filed
  /// under. NOT [type]: two families share a type value in the source, so the
  /// folder is the only thing that actually separates them.
  final String family;

  /// The preset's own name, kept exactly as written — a source spelling or a
  /// trailing space is not silently corrected.
  final String name;

  /// The source's own identifier for this preset.
  final String id;

  /// The source's own `type` field, retained verbatim. Its meaning is NOT
  /// recovered: two families carry the same value and one family carries two,
  /// so nothing here reads it as a family or a layout.
  final int type;

  /// The schema version string the source file carried, when it had one.
  final String? version;

  /// The preset's parameters, by the source's own names, each a normalized
  /// `0..1` value. Untouched: no renaming, no reordering, no unit applied.
  final Map<String, double> params;

  /// The module names this preset's parameters imply, in first-seen order.
  ///
  /// Derived by splitting each parameter name at its first space, which is how
  /// the design study grouped them to make the catalogue inspectable. It is a
  /// READING of the data, not a recovered signal chain: the source does not
  /// say which modules a rack holds or in what order they run.
  List<String> get moduleNames {
    final seen = <String>{};
    final order = <String>[];
    for (final key in params.keys) {
      final prefix = key.split(' ').first;
      if (seen.add(prefix)) order.add(prefix);
    }
    return order;
  }
}
