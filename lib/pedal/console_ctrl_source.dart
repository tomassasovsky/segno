import 'dart:async';

import 'package:controller_repository/controller_repository.dart';
import 'package:pedal_repository/pedal_repository.dart';

/// The console's two CTRL jacks as a [ControllerSource].
///
/// A pedal in a CTRL jack is an assignable control like any other: the same
/// binding set, the same learn capture, the same continuous / discrete
/// choice. Nothing here decides what a jack does — that is the user's, in
/// Settings — so this only translates identity and value.
///
/// The board says whether it sees a footswitch or an expression pedal, and
/// the two are DIFFERENT controls even on the same jack: swapping pedals
/// should not silently drive whatever the other one was bound to.
///
/// Values arrive as `0..255` (an expression pedal's already calibrated by
/// the repository) and leave as `0..127`, the range every binding and every
/// persisted capture already speaks.
///
/// The control number is the jack for the tip, and the jack plus
/// [ringIdOffset] for the ring: the second switch of a two-switch pedal is
/// its own control, and captures made before rings were readable keep their
/// numbers.
class ConsoleCtrlSource implements ControllerSource {
  /// Creates a [ConsoleCtrlSource] over [pedal]'s events.
  ConsoleCtrlSource(PedalRepository pedal) {
    _sub = pedal.events.listen(_onEvent);
  }

  /// What a ring contact adds to its jack's index to make a control number.
  static const ringIdOffset = 2;

  /// The control number for [input].
  static int idFor(PedalCtrlInput input) =>
      input.jack.index +
      (input.contact == PedalCtrlContact.ring ? ringIdOffset : 0);

  final StreamController<RawControllerInput> _inputs =
      StreamController<RawControllerInput>.broadcast();
  late final StreamSubscription<PedalEvent> _sub;

  @override
  Stream<RawControllerInput> get inputs => _inputs.stream;

  void _onEvent(PedalEvent event) {
    if (event is! CtrlChanged) return;
    if (_inputs.isClosed) return;
    // An empty jack is not an input: whatever it drove holds where it was.
    if (event.kind == PedalCtrlKind.none) return;
    _inputs.add(
      RawControllerInput(
        kind: switch (event.kind) {
          PedalCtrlKind.switchPedal => ControllerSourceKind.consoleSwitch,
          PedalCtrlKind.expression => ControllerSourceKind.consoleExpression,
          PedalCtrlKind.none => throw StateError('handled above'),
        },
        id: idFor(event.input),
        // 0..255 down to the 0..127 every binding speaks. A switch's ends
        // stay the ends, so a press still reads as a press.
        value: event.value >> 1,
      ),
    );
  }

  @override
  Future<void> dispose() async {
    await _sub.cancel();
    await _inputs.close();
  }
}
