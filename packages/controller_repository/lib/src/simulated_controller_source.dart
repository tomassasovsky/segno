import 'dart:async';

import 'package:controller_repository/src/controller_input.dart';
import 'package:controller_repository/src/controller_source.dart';

/// A simple input source for controller fixtures.
///
/// It forwards exact samples and ignores pushes after disposal. Production MIDI
/// capture uses its selected device source and does not register this fixture.
class SimulatedControllerSource implements ControllerSource {
  final StreamController<RawControllerInput> _inputs =
      StreamController<RawControllerInput>.broadcast();

  @override
  Stream<RawControllerInput> get inputs => _inputs.stream;

  /// Pushes [input] into the controller pipeline, in the shape a real CC / note
  /// message arrives in. A no-op once [dispose] has closed the stream, so a
  /// push racing teardown is swallowed rather than throwing.
  void push(RawControllerInput input) {
    if (_inputs.isClosed) return;
    _inputs.add(input);
  }

  @override
  Future<void> dispose() => _inputs.close();
}
