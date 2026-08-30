import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:pedal_repository/pedal_repository.dart';

/// Whether the Sessions manager should remain open.
enum SessionsManagerStatus {
  /// The manager is accepting input.
  active,

  /// A footswitch press requested that the manager close.
  dismissalRequested,
}

/// Converts pedal input into the Sessions manager's one-shot dismissal state.
///
/// Navigation remains in the view; this cubit owns repository subscription and
/// input classification so presentation never interprets raw pedal events.
class SessionsManagerCubit extends Cubit<SessionsManagerStatus> {
  /// Creates a [SessionsManagerCubit] over the shared [pedal] event stream.
  SessionsManagerCubit({required PedalRepository pedal})
    : super(SessionsManagerStatus.active) {
    _pedalSubscription = pedal.events.listen(_onPedalEvent);
  }

  late final StreamSubscription<PedalEvent> _pedalSubscription;

  void _onPedalEvent(PedalEvent event) {
    if (state != SessionsManagerStatus.active || event is! ButtonPressed) {
      return;
    }
    emit(SessionsManagerStatus.dismissalRequested);
  }

  @override
  Future<void> close() async {
    await _pedalSubscription.cancel();
    return super.close();
  }
}
