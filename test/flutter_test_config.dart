import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Runs every test under `test/` with [rootBundle]'s cache cleared after each
/// one (#1559).
///
/// [rootBundle] lives as long as the test process and caches the future of
/// every string it reads. A future made on a `testWidgets` fake clock
/// completes its listeners on that clock, so a later test that reads the same
/// asset awaits a future that never completes (#1537).
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  tearDown(rootBundle.clear);
  await testMain();
}
