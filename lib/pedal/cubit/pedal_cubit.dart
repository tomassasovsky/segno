import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:pedal_repository/pedal_repository.dart';

part 'pedal_state.dart';

/// Read-only link, physical samples and the canonical published LED frame.
/// External configuration and calibration belong to the ControlCubit setup.
class PedalCubit extends Cubit<PedalState> {
  PedalCubit({required PedalRepository pedal})
    : _pedal = pedal,
      super(
        PedalState(
          status: pedal.status,
          firmwareVersion: pedal.firmwareVersion,
          frame: pedal.lastFrame,
        ),
      ) {
    _statusSub = pedal.statusChanges.listen(_onStatus);
    _frameSub = pedal.frames.listen(_onFrame);
    _eventsSub = pedal.events.listen(_onEvent);
  }
  final PedalRepository _pedal;
  late final StreamSubscription<PedalLinkStatus> _statusSub;
  late final StreamSubscription<PedalEvent> _eventsSub;
  late final StreamSubscription<PedalStateFrame> _frameSub;
  bool _closing = false;
  bool get _inactive => _closing || isClosed;

  void _onFrame(PedalStateFrame frame) {
    if (!_inactive) emit(state.copyWith(frame: frame));
  }

  void _onStatus(PedalLinkStatus status) {
    if (_inactive) return;
    emit(
      state.copyWith(
        status: status,
        firmwareVersion: () => _pedal.firmwareVersion,
        ctrl: status == PedalLinkStatus.connected ? null : const {},
      ),
    );
  }

  void _onEvent(PedalEvent event) {
    if (_inactive || event is! CtrlChanged) return;
    final ctrl = {...state.ctrl};
    if (event.kind == PedalCtrlKind.none) {
      ctrl.removeWhere((input, _) => input.jack == event.jack);
    } else {
      if (event.kind == PedalCtrlKind.expression) {
        ctrl.remove(PedalCtrlInput(event.jack, PedalCtrlContact.ring));
      }
      ctrl[event.input] = PedalCtrlReading(kind: event.kind, value: event.raw);
    }
    emit(state.copyWith(ctrl: Map.unmodifiable(ctrl)));
  }

  @override
  Future<void> close() async {
    _closing = true;
    await _statusSub.cancel();
    await _eventsSub.cancel();
    await _frameSub.cancel();
    _pedal.goodbye();
    await _pedal.dispose();
    return super.close();
  }
}
