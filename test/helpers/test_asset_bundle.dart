import 'package:flutter/services.dart';

/// The app's assets through a cache of the test's own (#1537).
///
/// [rootBundle] lives as long as the test process and caches the future of
/// every string it reads. A future made on a `testWidgets` fake clock
/// completes its listeners on that clock, so a later test that awaits the
/// cached future waits forever, and a test that finds it already resolved
/// never sees the read in progress. A fresh [TestAssetBundle] per test keeps
/// each read in the test that made it.
class TestAssetBundle extends CachingAssetBundle {
  /// Reads the bytes through [rootBundle], which does not cache them.
  @override
  Future<ByteData> load(String key) => rootBundle.load(key);
}
