@Tags(['fuzz'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:segno_engine/segno_engine.dart';

/// The interface-input calls through the real native library, off the
/// calling isolate (#1646). No interface is attached where these run, so
/// every card reads as having nothing to set. Self-skips when
/// `SEGNO_ENGINE_LIB` is unset; build it first:
///   export SEGNO_ENGINE_LIB="$(bash tool/build_test_lib.sh)"
void main() {
  final lib = Platform.environment['SEGNO_ENGINE_LIB'];
  final skip = lib == null || lib.isEmpty
      ? 'SEGNO_ENGINE_LIB not set — run tool/build_test_lib.sh'
      : null;

  test('a missing card has no switches and refuses a write', () async {
    final engine = NativeAudioEngine();
    addTearDown(engine.dispose);
    for (final id in ['', ':63,0']) {
      final info = await engine.readInterfaceInputs(id);
      expect(info.state, InterfaceInputsState.noControls);
      expect(info.inputs, isEmpty);
      final result = await engine.setInterfaceInput(
        id,
        control: InterfaceControl.phantom,
        index: 0,
        value: 1,
      );
      expect(result.isOk, isFalse);
    }
  }, skip: skip);
}
