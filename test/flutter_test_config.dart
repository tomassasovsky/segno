import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/app/segno_navigator.dart';

/// Runs every test under `test/` with the process-wide asset caches cleared
/// after each one (#1559).
///
/// [rootBundle] and the navigator's factory catalogue live as long as the test
/// process and keep the future of every read. A listener added to a future
/// made on a `testWidgets` fake clock is scheduled on that clock, so a later
/// test that reads the same asset waits on a clock that no longer runs
/// (#1537).
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  tearDown(() {
    rootBundle.clear();
    resetSegnoNavigatorForTest();
  });
  await testMain();
}
