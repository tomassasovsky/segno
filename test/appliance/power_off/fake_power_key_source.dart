import 'dart:async';

import 'package:segno/appliance/power_off/power_key_source.dart';

/// Test double: call [emitPress] to simulate a short press.
final class FakePowerKeySource implements PowerKeySource {
  final StreamController<void> _controller = StreamController<void>.broadcast();

  @override
  Stream<void> get presses => _controller.stream;

  /// Fires one press.
  void emitPress() => _controller.add(null);

  @override
  Future<void> close() => _controller.close();
}
