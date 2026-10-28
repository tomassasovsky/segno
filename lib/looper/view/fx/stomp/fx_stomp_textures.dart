import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:segno/looper/view/fx/stomp/fx_stomp_spec.dart';

/// The tiles the textured pedal finishes are painted with, decoded once.
///
/// Small white tiles with the finish in their alpha channel, written by
/// `tool/stomp_textures.py`: Flutter has no counterpart of the design's
/// feTurbulence filters, and the appliance's embedder is not known to run
/// fragment shaders. A pedal draws without its texture until they have
/// loaded, then repaints.
class FxStompTextures {
  FxStompTextures._();

  /// The one set of tiles.
  static final FxStompTextures instance = FxStompTextures._();

  /// The asset each textured finish is painted with.
  static const Map<FxStompFinish, String> assets = {
    FxStompFinish.hammer: 'assets/images/stomp/hammer.png',
    FxStompFinish.flake: 'assets/images/stomp/flake.png',
    FxStompFinish.brush: 'assets/images/stomp/brush.png',
    FxStompFinish.marble: 'assets/images/stomp/marble.png',
  };

  /// How many drawing-space units one pixel of each tile covers.
  static const Map<FxStompFinish, double> scales = {
    FxStompFinish.marble: 2,
  };

  /// The decoded tiles: empty until they have loaded.
  final ValueNotifier<Map<FxStompFinish, ui.Image>> images = ValueNotifier(
    const {},
  );

  Future<void>? _loading;

  /// Decodes the tiles from [bundle], once: the app starts it at launch, and
  /// a screenshot suite awaits it before drawing. A tile that fails to load
  /// is left out, and its finish draws plain.
  Future<void> load([AssetBundle? bundle]) =>
      _loading ??= _load(bundle ?? rootBundle);

  Future<void> _load(AssetBundle bundle) async {
    final loaded = await Future.wait([
      for (final MapEntry(key: finish, value: asset) in assets.entries)
        _decode(bundle, asset).then((image) => (finish, image)),
    ]);
    images.value = Map.unmodifiable({
      for (final (finish, image) in loaded) finish: ?image,
    });
  }

  /// The tile at [asset], or `null` when it cannot be read: its finish
  /// draws plain.
  static Future<ui.Image?> _decode(AssetBundle bundle, String asset) async {
    try {
      final data = await bundle.load(asset);
      final codec = await ui.instantiateImageCodec(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      );
      try {
        return (await codec.getNextFrame()).image;
      } finally {
        codec.dispose();
      }
    } on Object catch (_) {
      return null;
    }
  }
}
