import 'dart:async';

import 'package:controller_repository/src/controller_input.dart';
import 'package:controller_repository/src/controller_source.dart';

/// A [ControllerSource] the app pushes SYNTHETIC inputs into, so a mapping can
/// prove itself with no controller attached (#519).
///
/// It is a plain source registered alongside the real one in the repository's
/// `sources` list at bootstrap — never a public `simulate()` on the
/// repository. That is the whole point: a pushed input enters through the
/// EXACT seam a real CC delivers on, so the repository's `_onInput` — its learn
/// capture, its smoothing ramps, its `learnIgnore` filtering — cannot tell it
/// from hardware. Nothing downstream of the controller-truth boundary gains a
/// test-only branch.
///
/// The synthetic sequence (a sweep's LO→HI→LO ramp, a switch's press/release)
/// is TIMED by `ControlCubit`, not here: this source is a dumb conduit, so the
/// one place that turns "simulate this row" into a paced series of pushes stays
/// the single control-surface interpreter.
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
