import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

/// Registers the font files at [paths] under [family] for a screenshot suite.
///
/// The test harness bundles no fonts of its own, so every face a golden shows
/// has to be loaded by hand or it renders as tofu boxes and the golden is
/// worthless.
Future<void> loadScreenshotFont(String family, List<String> paths) async {
  final loader = FontLoader(family);
  for (final p in paths) {
    loader.addFont(File(p).readAsBytes().then((b) => ByteData.view(b.buffer)));
  }
  await loader.load();
}

/// The on-disk path of [asset] inside the pub cache checkout of [package].
///
/// A package font is bundled from the package's pubspec at run time but not
/// by the test harness, so an icon golden has to load it from the resolved
/// package root. Resolved through the package config rather than a guessed
/// pub-cache path: the version is in that path, so hard-coding it would
/// silently stop loading on the next bump and put the tofu back. Read from
/// `package_config.json` rather than `Isolate.resolvePackageUri`, which
/// the test runtime does not implement. Throws rather than returning null
/// when it cannot find the asset: a silent skip here is a golden full of
/// tofu boxes that still passes, which is the exact failure this function
/// exists to prevent.
String packageAssetPath(String package, String asset) {
  final config = File('.dart_tool/package_config.json');
  final packages =
      (jsonDecode(config.readAsStringSync())
              as Map<String, dynamic>)['packages']
          as List<dynamic>;
  for (final entry in packages.cast<Map<String, dynamic>>()) {
    if (entry['name'] != package) continue;
    // The trailing slash matters: without it `resolve` treats the package
    // directory as a FILE and replaces it, so the asset lands one level up in
    // `pub.dev/` and nothing is there.
    final root = entry['rootUri']! as String;
    final path = config.uri
        .resolve(root.endsWith('/') ? root : '$root/')
        .resolve(asset)
        .toFilePath();
    if (File(path).existsSync()) return path;
    throw StateError('$package has no $asset (looked in $path)');
  }
  throw StateError('$package is not in the package config');
}
