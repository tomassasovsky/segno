import 'package:flutter/services.dart';

/// The app's assets through a cache of the test's own (#1537).
///
/// `flutter_test_config.dart` clears [rootBundle] between tests. Within one
/// test, a bundle of its own lets the test change what a read returns or hold
/// it, by overriding [load], without touching [rootBundle].
class TestAssetBundle extends CachingAssetBundle {
  /// Reads the bytes through [rootBundle], which does not cache them.
  @override
  Future<ByteData> load(String key) => rootBundle.load(key);
}
