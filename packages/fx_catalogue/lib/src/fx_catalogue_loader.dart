import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:fx_catalogue/src/fx_family.dart';
import 'package:fx_catalogue/src/fx_preset.dart';

/// The loaded factory catalogue: the rack families, in the order the library
/// lists them.
class FxCatalogue {
  /// Creates an [FxCatalogue].
  const FxCatalogue({required this.families});

  /// An empty catalogue — what a build with no bundled assets loads.
  static const FxCatalogue empty = FxCatalogue(families: []);

  /// The families, name-ordered.
  final List<FxFamily> families;

  /// Whether anything was loaded.
  bool get isEmpty => families.isEmpty;

  /// Every preset across every family, in family then name order.
  List<FxPreset> get presets => [
    for (final family in families) ...family.presets,
  ];

  /// The family called [name], or `null`.
  FxFamily? family(String name) {
    for (final family in families) {
      if (family.name == name) return family;
    }
    return null;
  }
}

/// Reads the factory catalogue out of the bundled assets.
///
/// Driven by the asset MANIFEST rather than by a directory walk: a Flutter
/// bundle has no directory listing at runtime, and the manifest is the source
/// import's own record of what it copied, verified byte for byte when it was
/// written.
///
/// What the bundle actually HOLDS is checked against Flutter's own asset
/// manifest before any read, so a build that ships without these assets loads
/// an empty catalogue rather than throwing: `loadString` raises a
/// `FlutterError` for a missing key, and an Error is not a thing to catch.
class FxCatalogueLoader {
  /// Creates an [FxCatalogueLoader] reading through [bundle].
  const FxCatalogueLoader({AssetBundle? bundle}) : _bundle = bundle;

  final AssetBundle? _bundle;

  AssetBundle get _assets => _bundle ?? rootBundle;

  /// The package the assets are bundled under.
  static const String package = 'fx_catalogue';

  /// Resolves an in-package [asset] path to the key the bundle knows it by.
  static String assetKey(String asset) => 'packages/$package/$asset';

  /// Loads the catalogue. Returns [FxCatalogue.empty] when the manifest is
  /// missing or unreadable.
  Future<FxCatalogue> load() async {
    final AssetManifest bundled;
    try {
      bundled = await AssetManifest.loadFromAssetBundle(_assets);
    } on Exception {
      return FxCatalogue.empty;
    }
    final present = bundled.listAssets().toSet();
    final manifestKey = assetKey('assets/manifest.json');
    if (!present.contains(manifestKey)) return FxCatalogue.empty;
    final manifestText = await _assets.loadString(manifestKey);
    final Object? raw;
    try {
      raw = jsonDecode(manifestText);
    } on FormatException {
      return FxCatalogue.empty;
    }
    if (raw is! List) return FxCatalogue.empty;

    final byFamily = <String, List<String>>{};
    for (final entry in raw) {
      if (entry is! Map<String, dynamic>) continue;
      final dest = entry['destination'];
      if (dest is! String || !dest.startsWith('presets/')) continue;
      final parts = dest.split('/');
      if (parts.length != 3) continue;
      byFamily.putIfAbsent(parts[1], () => []).add(dest);
    }

    final families = <FxFamily>[];
    for (final name in byFamily.keys.toList()..sort()) {
      final slug = kFxFamilySlugs[name];
      // A family with no artwork slug is one this build does not know how to
      // draw. Skipped rather than shown blank: the library's whole shape is
      // its artwork.
      if (slug == null) continue;
      final presets = <FxPreset>[];
      for (final dest in byFamily[name]!) {
        final key = assetKey('assets/$dest');
        // A file the import manifest names but this bundle does not hold is
        // skipped, so a partial bundle loads the presets it DOES have rather
        // than failing whole.
        if (!present.contains(key)) continue;
        final preset = FxPreset.tryParse(name, await _assets.loadString(key));
        if (preset != null) presets.add(preset);
      }
      presets.sort((a, b) => a.name.compareTo(b.name));
      families.add(FxFamily(name: name, slug: slug, presets: presets));
    }
    return FxCatalogue(families: families);
  }
}
