import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:pedal_repository/pedal_repository.dart';

/// Whether the capture dialog should remain open.
enum PerformanceCompletionStatus {
  /// The dialog is accepting input.
  active,

  /// A footswitch press requested that the dialog close.
  dismissalRequested,
}

/// Converts pedal input into the capture dialog's one-shot dismissal state.
///
/// Navigation remains in the view; this cubit owns repository subscription and
/// input classification so presentation never interprets raw pedal events.
class PerformanceCompletionCubit extends Cubit<PerformanceCompletionStatus> {
  /// Creates a [PerformanceCompletionCubit] over the shared [pedal] event
  /// stream.
  PerformanceCompletionCubit({required PedalRepository pedal})
    : super(PerformanceCompletionStatus.active) {
    _pedalSubscription = pedal.events.listen(_onPedalEvent);
  }

  late final StreamSubscription<PedalEvent> _pedalSubscription;

  void _onPedalEvent(PedalEvent event) {
    if (state != PerformanceCompletionStatus.active ||
        event is! ButtonPressed) {
      return;
    }
    emit(PerformanceCompletionStatus.dismissalRequested);
  }

  @override
  Future<void> close() async {
    await _pedalSubscription.cancel();
    return super.close();
  }
}
