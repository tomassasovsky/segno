import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:pedal_repository/pedal_repository.dart';

part 'pedal_state.dart';

/// The pedal LINK feature: whether the console board is talking, and what
/// firmware it announced. Nothing else.
///
/// The pedal's BEHAVIOR — decoding footswitch events into intents and
/// pushing projected LED frames — is `ControlCubit`'s job: both cubits sit
/// on the shared [PedalRepository] (events in / frames out for control,
/// status for this one) and know nothing about each other.
class PedalCubit extends Cubit<PedalState> {
  /// Creates a [PedalCubit].
  PedalCubit({required PedalRepository pedal})
    : _pedal = pedal,
      super(
        PedalState(
          status: pedal.status,
          firmwareVersion: pedal.firmwareVersion,
        ),
      ) {
    _statusSub = _pedal.statusChanges.listen(_onStatus);
    _eventsSub = _pedal.events.listen(_onEvent);
  }

  final PedalRepository _pedal;
  late final StreamSubscription<PedalLinkStatus> _statusSub;
  late final StreamSubscription<PedalEvent> _eventsSub;

  void _onStatus(PedalLinkStatus status) {
    if (isClosed) return;
    emit(
      PedalState(
        status: status,
        firmwareVersion: _pedal.firmwareVersion,
        ctrl: state.ctrl,
      ),
    );
  }

  /// Keeps the last reading from each CTRL jack, so the settings page can show
  /// a pedal moving while it is being bound. Only CTRL events land here: the
  /// footswitches and the encoder are the control cubit's.
  void _onEvent(PedalEvent event) {
    if (isClosed || event is! CtrlChanged) return;
    emit(
      PedalState(
        status: state.status,
        firmwareVersion: state.firmwareVersion,
        ctrl: {
          ...state.ctrl,
          event.jack: PedalCtrlReading(kind: event.kind, value: event.value),
        },
      ),
    );
  }

  @override
  Future<void> close() async {
    await _statusSub.cancel();
    await _eventsSub.cancel();
    // Darken the console on shutdown, then release the link — this cubit is
    // the pedal repository's lifecycle owner.
    _pedal.goodbye();
    await _pedal.dispose();
    return super.close();
  }
}
