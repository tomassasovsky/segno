@Tags(['fuzz'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:segno_engine/segno_engine.dart';

/// The interface-input calls through the real native library, off the
/// calling isolate (#1646). No interface is attached where these run, so
/// every card reads as having nothing to set.
void main() {
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
  });
}
