import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:segno/logging/app_log.dart';

/// The tiles the textured pedal finishes, and the grain over every pedal,
/// are painted with, decoded once.
///
/// Small tiles with the texture in their alpha channel, white except the
/// grain, which is black as the design's grain is; written by
/// `tool/stomp_textures.py`: Flutter has no counterpart of the design's
/// feTurbulence filters, and the appliance's embedder is not known to run
/// fragment shaders. A pedal draws without its texture until they have
/// loaded, then repaints.
class FxStompTextures {
  FxStompTextures._();

  /// The one set of tiles.
  static final FxStompTextures instance = FxStompTextures._();

  /// The tile the grain over every pedal body is painted with.
  static const String grain = 'grain';

  /// The asset each tile is read from, by name: a textured finish's
  /// (`FxStompFinish.name`), and [grain].
  static const Map<String, String> assets = {
    'hammer': 'assets/images/stomp/hammer.png',
    'flake': 'assets/images/stomp/flake.png',
    'brush': 'assets/images/stomp/brush.png',
    'marble': 'assets/images/stomp/marble.png',
    grain: 'assets/images/stomp/grain.png',
  };

  /// How many drawing-space units one pixel of a tile covers, where it is
  /// not 1.
  static const Map<String, double> scales = {'marble': 2};

  /// The decoded tiles, by name: empty until they have loaded.
  final ValueNotifier<Map<String, ui.Image>> images = ValueNotifier(const {});

  Future<void>? _loading;

  /// Decodes the tiles from the app bundle, once: the app starts it at launch,
  /// and a screenshot suite awaits it before drawing. A tile that fails to
  /// load is left out, and its finish draws plain.
  Future<void> load() => _loading ??= _load(rootBundle);

  Future<void> _load(AssetBundle bundle) async {
    final loaded = await Future.wait([
      for (final MapEntry(key: name, value: asset) in assets.entries)
        _decode(bundle, asset).then((image) => (name, image)),
    ]);
    final tiles = {for (final (name, image) in loaded) name: ?image};
    // Nothing loaded is no change: the pedals keep their recordings.
    if (tiles.isNotEmpty) images.value = Map.unmodifiable(tiles);
  }

  /// The tile at [asset], or `null` when it cannot be read: its finish
  /// draws plain for the session, and the failure is logged.
  static Future<ui.Image?> _decode(AssetBundle bundle, String asset) async {
    try {
      final data = await bundle.load(asset);
      return await decodeImageFromList(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      );
    } on Object catch (error) {
      AppLog.error('stomp pedal tile $asset did not load: $error');
      return null;
    }
  }
}
