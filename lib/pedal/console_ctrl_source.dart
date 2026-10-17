import 'dart:async';

import 'package:controller_repository/controller_repository.dart';
import 'package:pedal_repository/pedal_repository.dart';

/// Translates the current UART CTRL coordinates without losing raw precision.
/// Configuration and action dispatch belong to ControlCubit.
class ConsoleCtrlSource implements ControllerSource {
  ConsoleCtrlSource(PedalRepository pedal) {
    _sub = pedal.events.listen(_onEvent);
    _statusSub = pedal.statusChanges.listen((status) {
      if (status == PedalLinkStatus.connected) return;
      PedalCtrlJack.values.forEach(_unavailable);
    });
  }

  static const ringIdOffset = 2;
  static int idFor(PedalCtrlInput input) =>
      input.jack.index +
      (input.contact == PedalCtrlContact.ring ? ringIdOffset : 0);

  final _inputs = StreamController<ControllerSourceEvent>.broadcast();
  late final StreamSubscription<PedalEvent> _sub;
  late final StreamSubscription<PedalLinkStatus> _statusSub;
  final Map<PedalCtrlJack, PedalCtrlKind> _kinds = {};

  @override
  Stream<ControllerSourceEvent> get inputs => _inputs.stream;

  void _unavailable(PedalCtrlJack jack) {
    _kinds.remove(jack);
    for (final input in [
      PedalCtrlInput(jack, PedalCtrlContact.tip),
      PedalCtrlInput(jack, PedalCtrlContact.ring),
    ]) {
      _inputs.add(
        ControllerSourceUnavailable(
          MappingTrigger(
            kind: ControllerSourceKind.consoleSwitch,
            id: idFor(input),
          ),
        ),
      );
    }
    _inputs.add(
      ControllerSourceUnavailable(
        MappingTrigger(
          kind: ControllerSourceKind.consoleExpression,
          id: jack.index,
        ),
      ),
    );
  }

  void _onEvent(PedalEvent event) {
    if (event is! CtrlChanged || _inputs.isClosed) return;
    if (event.kind == PedalCtrlKind.none) {
      _unavailable(event.jack);
      return;
    }
    if (event.contact == PedalCtrlContact.tip) {
      final prior = _kinds[event.jack];
      if (prior != null && prior != event.kind) _unavailable(event.jack);
      _kinds[event.jack] = event.kind;
    } else if (_kinds[event.jack] == PedalCtrlKind.expression) {
      return;
    }
    _inputs.add(
      RawControllerInput(
        kind: event.kind == PedalCtrlKind.expression
            ? ControllerSourceKind.consoleExpression
            : ControllerSourceKind.consoleSwitch,
        id: idFor(event.input),
        value: event.raw,
      ),
    );
  }

  @override
  Future<void> dispose() async {
    await _sub.cancel();
    await _statusSub.cancel();
    await _inputs.close();
  }
}
